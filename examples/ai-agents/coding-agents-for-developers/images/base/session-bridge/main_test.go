package main

// Run with `go test ./...` in this folder. Each check is proved both ways: an input it must
// accept and an input it must refuse.

import (
	"bufio"
	"bytes"
	"errors"
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
