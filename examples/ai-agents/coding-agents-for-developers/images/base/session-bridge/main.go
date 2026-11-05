// session-bridge serves a session pod's terminal, activity time and mount credential to the
// web app over the pod network, so none of that traffic goes through the Kubernetes API.
//
// The session entrypoint starts it as root when the app claims the pod, after writing a
// per-session token to a root-only file. It then:
//
//   - makes a fresh TLS key and a self-signed certificate in memory, binds its port, and
//     writes only the certificate to a root-only file, which the app reads once over exec
//     and pins. The key never leaves this process.
//   - answers three requests, each carrying the token as a bearer token:
//     GET /v1/terminal    a WebSocket: a PTY running `tmux attach` as the dev user. Binary
//     frames are input; a text frame {"resize":[cols,rows]} resizes the PTY.
//     GET /v1/activity    the last time the terminal had input or output, as an epoch.
//     PUT /v1/credential  replaces the session's mount credential file.
//
// The Go standard library only: no third-party code runs in the sandbox.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha1"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	sessionDir = "/dev/shm/session"
	credFile   = sessionDir + "/credentials"
	tokenFile  = sessionDir + "/bridge-token"
	certFile   = sessionDir + "/bridge.crt"
	serverName = "session-bridge" // the name the app checks the certificate against
	maxFrame   = 1 << 20
	maxCred    = 16 << 10
	wsGUID     = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
)

// Commands for the dev user run with a clean environment: the bridge's own environment is
// root's, and nothing in it is for the CLI.
var (
	cleanEnv = []string{"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}
	asDev    = []string{"/usr/bin/setpriv", "--reuid=1000", "--regid=1000", "--init-groups", "--inh-caps=-all",
		"env", "HOME=/workspace/home", "TERM=xterm-256color", "LANG=C.UTF-8", "LC_ALL=C.UTF-8"}
)

type bridge struct{ token []byte }

func main() {
	addr := flag.String("listen", ":7681", "address to listen on")
	flag.Parse()
	log.SetFlags(log.LstdFlags | log.LUTC)

	tok, err := os.ReadFile(tokenFile)
	if err != nil {
		log.Fatalf("read token: %v", err)
	}
	tok = bytes.TrimSpace(tok)
	if len(tok) < 32 {
		log.Fatalf("token in %s is too short", tokenFile)
	}
	b := &bridge{token: tok}

	cert, certPEM, err := selfSigned()
	if err != nil {
		log.Fatalf("certificate: %v", err)
	}
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	// The certificate is written only once the port is ours, so the entrypoint's wait for
	// this file is also a wait for the listener.
	if err := writeFile(certFile, certPEM, 0o600); err != nil {
		log.Fatalf("write certificate: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/terminal", b.auth(b.terminal))
	mux.HandleFunc("GET /v1/activity", b.auth(b.activity))
	mux.HandleFunc("PUT /v1/credential", b.auth(b.credential))
	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		TLSConfig:         &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS13},
	}
	log.Printf("session-bridge listening on %s", *addr)
	log.Fatal(srv.ServeTLS(ln, "", ""))
}

func selfSigned() (tls.Certificate, []byte, error) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 127))
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	tmpl := &x509.Certificate{
		SerialNumber:          serial,
		Subject:               pkix.Name{CommonName: serverName},
		DNSNames:              []string{serverName},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(1, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true, // self-signed: the app trusts exactly this certificate
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, nil, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key},
		pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), nil
}

// writeFile replaces path atomically, so a reader never sees a partial file.
func writeFile(path string, data []byte, mode os.FileMode) error {
	tmp := path + ".new"
	_ = os.Remove(tmp)
	if err := os.WriteFile(tmp, data, mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (b *bridge) auth(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok || subtle.ConstantTimeCompare([]byte(got), b.token) != 1 {
			log.Printf("refused %s %s from %s", r.Method, r.URL.Path, r.RemoteAddr)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		h(w, r)
	}
}

// --- activity ---

// The newest of tmux's session_activity (moves on key input) and each window's
// window_activity (moves when the pane prints), or "none" when the session is gone.
// Reading session_activity alone released an agent that was still working on its own:
// with a pane printing every 15 s and no keys, it aged past ten minutes while
// window_activity stayed under five seconds. A CLI waiting at its prompt prints nothing,
// so it still goes idle.
const activityScript = `if tmux has-session -t agent 2>/dev/null; then ` +
	`{ tmux display-message -p -t agent '#{session_activity}'; tmux list-windows -t agent -F '#{window_activity}'; } | sort -n | tail -1; ` +
	`else echo none; fi`

var epochRE = regexp.MustCompile(`^[0-9]{9,11}$`)

func (b *bridge) activity(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, asDev[0], append(asDev[1:], "/bin/sh", "-c", activityScript)...)
	cmd.Env, cmd.Dir = cleanEnv, "/"
	// The container has no CAP_KILL, so root cannot kill a uid 1000 process on timeout.
	// WaitDelay makes Wait return anyway instead of blocking on it.
	cmd.WaitDelay = time.Second
	out, err := cmd.Output()
	v := strings.TrimSpace(string(out))
	var epoch int64
	switch {
	case err != nil:
		http.Error(w, fmt.Sprintf("activity: %v", err), http.StatusInternalServerError)
		return
	case v == "none":
		epoch = 0
	case epochRE.MatchString(v):
		epoch, _ = strconv.ParseInt(v, 10, 64)
	default:
		// An unreadable time must never read as idle and release a live session.
		http.Error(w, "activity: unexpected tmux output", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]int64{"activity": epoch})
}

// --- credential ---

func (b *bridge) credential(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxCred))
	if err != nil {
		http.Error(w, "credential: body too large or unreadable", http.StatusBadRequest)
		return
	}
	// Fail closed: the live file is replaced only by a well-formed credential, so a bad
	// request leaves the running mount's credential as it was.
	wellFormed := false
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "aws_access_key_id") {
			wellFormed = true
			break
		}
	}
	if !wellFormed {
		http.Error(w, "credential: malformed", http.StatusBadRequest)
		return
	}
	if err := writeFile(credFile, body, 0o600); err != nil {
		http.Error(w, fmt.Sprintf("credential: %v", err), http.StatusInternalServerError)
		return
	}
	log.Printf("mount credential replaced")
	w.WriteHeader(http.StatusNoContent)
}

// --- terminal ---

func (b *bridge) terminal(w http.ResponseWriter, r *http.Request) {
	if !headerHas(r.Header, "Connection", "upgrade") || !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		r.Header.Get("Sec-WebSocket-Version") != "13" || r.Header.Get("Sec-WebSocket-Key") == "" {
		http.Error(w, "expected a WebSocket upgrade", http.StatusBadRequest)
		return
	}
	cols, rows := dim(r.URL.Query().Get("cols"), 200), dim(r.URL.Query().Get("rows"), 50)

	// Start the PTY before upgrading, so a failure is an HTTP error the app can report.
	master, cmd, err := startTmuxAttach(cols, rows)
	if err != nil {
		http.Error(w, fmt.Sprintf("terminal: %v", err), http.StatusInternalServerError)
		return
	}
	hj, ok := w.(http.Hijacker)
	if !ok {
		master.Close()
		http.Error(w, "terminal: cannot upgrade", http.StatusInternalServerError)
		return
	}
	conn, rw, err := hj.Hijack()
	if err != nil {
		master.Close()
		return
	}
	sum := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + wsGUID))
	fmt.Fprintf(rw, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		base64.StdEncoding.EncodeToString(sum[:]))
	if err := rw.Flush(); err != nil {
		conn.Close()
		master.Close()
		return
	}
	log.Printf("terminal attached for %s (%dx%d)", r.RemoteAddr, cols, rows)

	var wmu sync.Mutex
	send := func(op byte, p []byte) error {
		wmu.Lock()
		defer wmu.Unlock()
		return writeFrame(rw.Writer, op, p)
	}
	var once sync.Once
	done := func() {
		once.Do(func() {
			_ = send(0x8, []byte{0x03, 0xe8}) // close, 1000 normal
			conn.Close()
			// Closing the master hangs up the PTY, which ends the tmux client: root cannot
			// signal the dev user's process here (no CAP_KILL), and does not need to.
			master.Close()
			_ = cmd.Wait()
			log.Printf("terminal detached for %s", r.RemoteAddr)
		})
	}

	// PTY -> WebSocket.
	go func() {
		defer done()
		buf := make([]byte, 32<<10)
		for {
			n, err := master.Read(buf)
			if n > 0 && send(0x2, buf[:n]) != nil {
				return
			}
			if err != nil {
				return // EIO once tmux exits and the PTY's last slave closes
			}
		}
	}()

	// WebSocket -> PTY.
	defer done()
	var msgOp byte
	var msg []byte
	for {
		fin, op, payload, err := readFrame(rw.Reader)
		if err != nil {
			return
		}
		switch op {
		case 0x8: // close
			return
		case 0x9: // ping
			if send(0xA, payload) != nil {
				return
			}
			continue
		case 0xA: // pong
			continue
		case 0x1, 0x2:
			msgOp, msg = op, payload
		case 0x0:
			if len(msg)+len(payload) > maxFrame {
				return
			}
			msg = append(msg, payload...)
		default:
			return
		}
		if !fin {
			continue
		}
		if msgOp == 0x2 {
			if _, err := master.Write(msg); err != nil {
				return
			}
		} else { // text frames carry control messages only
			var c struct {
				Resize []int `json:"resize"`
			}
			if json.Unmarshal(msg, &c) == nil && len(c.Resize) == 2 {
				_ = setSize(master, dim(strconv.Itoa(c.Resize[0]), 200), dim(strconv.Itoa(c.Resize[1]), 50))
			}
		}
		msg = nil
	}
}

func dim(s string, def int) int {
	n, err := strconv.Atoi(s)
	if err != nil || n < 1 || n > 1000 {
		return def
	}
	return n
}

func headerHas(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, part := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(part), token) {
				return true
			}
		}
	}
	return false
}

// readFrame reads one client frame. Clients must mask, and no extensions are agreed.
func readFrame(r *bufio.Reader) (fin bool, op byte, payload []byte, err error) {
	var h [2]byte
	if _, err = io.ReadFull(r, h[:]); err != nil {
		return
	}
	fin, op = h[0]&0x80 != 0, h[0]&0x0F
	if h[0]&0x70 != 0 || h[1]&0x80 == 0 {
		return false, 0, nil, errors.New("reserved bits set or frame not masked")
	}
	n := uint64(h[1] & 0x7F)
	switch n {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return
		}
		n = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(r, ext[:]); err != nil {
			return
		}
		n = binary.BigEndian.Uint64(ext[:])
	}
	if n > maxFrame {
		return false, 0, nil, errors.New("frame too large")
	}
	var mask [4]byte
	if _, err = io.ReadFull(r, mask[:]); err != nil {
		return
	}
	payload = make([]byte, n)
	if _, err = io.ReadFull(r, payload); err != nil {
		return
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return
}

// writeFrame writes one unmasked, unfragmented server frame.
func writeFrame(w *bufio.Writer, op byte, p []byte) error {
	hdr := []byte{0x80 | op}
	switch n := len(p); {
	case n < 126:
		hdr = append(hdr, byte(n))
	case n <= 0xFFFF:
		hdr = append(hdr, 126, byte(n>>8), byte(n))
	default:
		hdr = binary.BigEndian.AppendUint64(append(hdr, 127), uint64(n))
	}
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	if _, err := w.Write(p); err != nil {
		return err
	}
	return w.Flush()
}

// --- PTY ---

func ioctl(f *os.File, req uintptr, arg unsafe.Pointer) error {
	rc, err := f.SyscallConn()
	if err != nil {
		return err
	}
	var errno syscall.Errno
	if err := rc.Control(func(fd uintptr) {
		_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, fd, req, uintptr(arg))
	}); err != nil {
		return err
	}
	if errno != 0 {
		return errno
	}
	return nil
}

func setSize(f *os.File, cols, rows int) error {
	ws := struct{ Row, Col, X, Y uint16 }{uint16(rows), uint16(cols), 0, 0}
	return ioctl(f, syscall.TIOCSWINSZ, unsafe.Pointer(&ws))
}

// startTmuxAttach opens a PTY pair and runs `tmux -u attach -t agent` on it as the dev user,
// the identity whose tmux server the entrypoint started (root's tmux looks at a different
// socket and reports "no sessions"). The UTF-8 locale and `-u` matter: tmux decides at
// attach time whether the client takes UTF-8, and without them it downgrades every
// box-drawing, status and smart-quote glyph the agent TUIs draw to `_`.
func startTmuxAttach(cols, rows int) (*os.File, *exec.Cmd, error) {
	master, err := os.OpenFile("/dev/ptmx", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, err
	}
	var unlock int32
	var n uint32
	if err := ioctl(master, syscall.TIOCSPTLCK, unsafe.Pointer(&unlock)); err != nil {
		master.Close()
		return nil, nil, err
	}
	if err := ioctl(master, syscall.TIOCGPTN, unsafe.Pointer(&n)); err != nil {
		master.Close()
		return nil, nil, err
	}
	if err := setSize(master, cols, rows); err != nil {
		master.Close()
		return nil, nil, err
	}
	slave, err := os.OpenFile("/dev/pts/"+strconv.Itoa(int(n)), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		master.Close()
		return nil, nil, err
	}
	defer slave.Close()
	cmd := exec.Command(asDev[0], append(asDev[1:], "tmux", "-u", "attach", "-t", "agent")...)
	cmd.Env, cmd.Dir = cleanEnv, "/"
	cmd.Stdin, cmd.Stdout, cmd.Stderr = slave, slave, slave
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}
	cmd.WaitDelay = 2 * time.Second
	if err := cmd.Start(); err != nil {
		master.Close()
		return nil, nil, err
	}
	return master, cmd, nil
}
