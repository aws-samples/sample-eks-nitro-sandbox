package main

// Run with `go test ./...` in this folder. Each check is proved both ways: an input it must
// accept and an input it must refuse.

import (
	"bufio"
	"bytes"
	"errors"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestWellFormedCredential(t *testing.T) {
	good := "[session]\naws_access_key_id=AKIAEXAMPLE\naws_secret_access_key=secret\naws_session_token=token\n"
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"the body the app writes", good, true},
		{"no trailing newline", "[session]\naws_access_key_id=a\naws_secret_access_key=b\naws_session_token=c", true},
		{"key id only", "aws_access_key_id=AKIAEXAMPLE\n", false},
		{"no profile header", "aws_access_key_id=a\naws_secret_access_key=b\naws_session_token=c\n", false},
		{"missing session token", "[session]\naws_access_key_id=a\naws_secret_access_key=b\n", false},
		{"empty secret", "[session]\naws_access_key_id=a\naws_secret_access_key=\naws_session_token=c\n", false},
		{"blank secret", "[session]\naws_access_key_id=a\naws_secret_access_key=  \naws_session_token=c\n", false},
		{"empty body", "", false},
	}
	for _, c := range cases {
		if got := wellFormedCredential([]byte(c.body)); got != c.want {
			t.Errorf("%s: wellFormedCredential = %v, want %v", c.name, got, c.want)
		}
	}
}

// frame builds one masked client frame.
func frame(fin bool, op byte, payload []byte) []byte {
	b0 := op
	if fin {
		b0 |= 0x80
	}
	out := []byte{b0}
	switch n := len(payload); {
	case n < 126:
		out = append(out, 0x80|byte(n))
	case n <= 0xFFFF:
		out = append(out, 0x80|126, byte(n>>8), byte(n))
	default:
		panic("test frames stay small")
	}
	mask := []byte{1, 2, 3, 4}
	out = append(out, mask...)
	for i, c := range payload {
		out = append(out, c^mask[i%4])
	}
	return out
}

func TestCloseReplyCode(t *testing.T) {
	cases := []struct {
		name string
		p    []byte
		want uint32
	}{
		{"empty close", nil, 1000},
		{"normal, no reason", []byte{0x03, 0xe8}, 1000},
		{"going away, with a reason", append([]byte{0x03, 0xe9}, "bye"...), 1000},
		{"application code 4000", []byte{0x0f, 0xa0}, 1000},
		{"one-byte payload", []byte{0x03}, 1002},
		{"reserved code 1005", []byte{0x03, 0xed}, 1002},
		{"code 999", []byte{0x03, 0xe7}, 1002},
		{"code 5000", []byte{0x13, 0x88}, 1002},
		{"try again later, 1013", []byte{0x03, 0xf5}, 1000},
		{"bad gateway, 1014", []byte{0x03, 0xf6}, 1000},
		{"reserved 1004", []byte{0x03, 0xec}, 1002},
		{"TLS handshake 1015, never sent", []byte{0x03, 0xf7}, 1002},
		{"reason not UTF-8", []byte{0x03, 0xe8, 0xff, 0xfe}, 1007},
	}
	for _, c := range cases {
		if got := closeReplyCode(c.p); got != c.want {
			t.Errorf("%s: closeReplyCode = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestReadFrame(t *testing.T) {
	cases := []struct {
		name    string
		raw     []byte
		wantErr error
	}{
		{"binary data frame", frame(true, 0x2, []byte("x")), nil},
		{"first fragment of a text frame", frame(false, 0x1, []byte("{")), nil},
		{"ping of 125 bytes", frame(true, 0x9, bytes.Repeat([]byte("p"), 125)), nil},
		{"ping of 126 bytes", frame(true, 0x9, bytes.Repeat([]byte("p"), 126)), errProtocol},
		{"fragmented ping", frame(false, 0x9, []byte("p")), errProtocol},
		{"fragmented close", frame(false, 0x8, nil), errProtocol},
		{"unmasked frame", []byte{0x82, 0x01, 'x'}, errProtocol},
		{"reserved bit set", append([]byte{0xC2}, frame(true, 0x2, []byte("x"))[1:]...), errProtocol},
		{"126 bytes in the 16-bit form", frame(true, 0x2, bytes.Repeat([]byte("x"), 126)), nil},
		{"1 byte in the 16-bit form", []byte{0x82, 0x80 | 126, 0, 1, 1, 2, 3, 4, 'x' ^ 1}, errProtocol},
		{"short payload in the 64-bit form", []byte{0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0, 0x01, 0x00, 1, 2, 3, 4}, errProtocol},
		{"64-bit length with its top bit set", []byte{0x82, 0x80 | 127, 0x80, 0, 0, 0, 0, 1, 0, 0, 1, 2, 3, 4}, errProtocol},
		{"64-bit length past the frame limit", []byte{0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0x20, 0, 0, 1, 2, 3, 4}, errFrameTooLarge},
	}
	for _, c := range cases {
		_, _, _, err := readFrame(bufio.NewReader(bytes.NewReader(c.raw)))
		switch {
		case c.wantErr == nil && err != nil:
			t.Errorf("%s: unexpected error %v", c.name, err)
		case c.wantErr != nil && !errors.Is(err, c.wantErr):
			t.Errorf("%s: error %v, want %v", c.name, err, c.wantErr)
		}
	}
}

func TestPaneTarget(t *testing.T) {
	for _, c := range []struct {
		name string
		in   []string
		want string
		ok   bool
	}{
		{"omitted", nil, "agent", true},
		{"agent", []string{"agent"}, "agent", true},
		{"shell", []string{"shell"}, "shell", true},
		{"empty value", []string{""}, "", false},
		{"repeated", []string{"shell", "agent"}, "", false},
		{"repeated same", []string{"shell", "shell"}, "", false},
		{"case", []string{"Shell"}, "", false},
		{"injection", []string{"agent;id"}, "", false},
		{"path", []string{"../x"}, "", false},
		{"newline", []string{"shell\n"}, "", false},
		{"space", []string{" shell"}, "", false},
	} {
		got, ok := paneTarget(c.in)
		if got != c.want || ok != c.ok {
			t.Errorf("%s: paneTarget(%q) = %q, %v; want %q, %v", c.name, c.in, got, ok, c.want, c.ok)
		}
	}
}

// TestPaneQuery runs the query through the same parse the handler uses, so the values that
// reach paneTarget are the ones a request really produces.
func TestPaneQuery(t *testing.T) {
	for _, c := range []struct {
		raw  string
		want string
		ok   bool
	}{
		{"cols=80", "agent", true},
		{"pane=shell", "shell", true},
		{"pane=%73hell", "shell", true},
		{"pane=", "", false},
		{"pane=shell&pane=agent", "", false},
		{"pane=agent&pane=shell", "", false},
		{"pane=shell;ignored=x", "", false},
		{"pane=shell%0a", "", false},
		{"pane=%20shell", "", false},
	} {
		q, err := url.ParseQuery(c.raw)
		got, ok := paneTarget(q["pane"])
		if err != nil {
			got, ok = "", false // the handler refuses a query that does not parse
		}
		if got != c.want || ok != c.ok {
			t.Errorf("%q: got %q, %v; want %q, %v", c.raw, got, ok, c.want, c.ok)
		}
	}
}

// TestActivityScript runs the real script with a stub tmux that knows which sessions exist
// and what activity each reports, so it covers every combination of the two sessions.
func TestActivityScript(t *testing.T) {
	dir := t.TempDir()
	stub := `#!/bin/sh
# usage: tmux has-session -t S | display-message -p -t S FMT | list-windows -t S -F FMT
case "$1" in
has-session) case " $STUB_SESSIONS " in *" $3 "*) exit 0;; esac; exit 1;;
display-message) eval "echo \$STUB_SESSION_$4";;
list-windows) eval "echo \$STUB_WINDOW_$3";;
esac
`
	if err := os.WriteFile(dir+"/tmux", []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, sessions, want string
		extra                []string // appended to the environment; the last duplicate wins
	}{
		{"both", "agent shell", "1700000999", nil},
		{"agent only", "agent", "1700000200", nil},
		{"shell only keeps the session", "shell", "1700000999", nil},
		{"neither", "", "none", nil},
		// Key input moves session_activity, not window_activity: with the stub's session
		// time the newest value, dropping the display-message call changes the answer.
		{"session_activity is the newest", "agent", "1700000900", []string{"STUB_SESSION_agent=1700000900"}},
	} {
		cmd := exec.Command("/bin/sh", "-c", activityScript)
		cmd.Env = []string{"PATH=" + dir + ":/usr/bin:/bin", "STUB_SESSIONS=" + c.sessions,
			"STUB_SESSION_agent=1700000100", "STUB_WINDOW_agent=1700000200",
			"STUB_SESSION_shell=1700000500", "STUB_WINDOW_shell=1700000999"}
		cmd.Env = append(cmd.Env, c.extra...)
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if got := strings.TrimSpace(string(out)); got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}
