//go:build linux

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestValidateRelativePath(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name     string
		path     string
		allowDot bool
		valid    bool
	}{
		{name: "directory root", path: ".", allowDot: true, valid: true},
		{name: "nested", path: ".openclaw/control", valid: true},
		{name: "absolute", path: "/home/node", valid: false},
		{name: "parent", path: ".openclaw/../outside", valid: false},
		{name: "repeated separator", path: ".openclaw//control", valid: false},
		{name: "file root", path: ".", valid: false},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			err := validateRelativePath(test.path, test.allowDot)
			if test.valid && err != nil {
				t.Fatalf("expected valid path, got %v", err)
			}
			if !test.valid && err == nil {
				t.Fatal("expected invalid path")
			}
		})
	}
}

func TestParseArgsRejectsDuplicatesAndMissingRoot(t *testing.T) {
	t.Parallel()
	if _, err := parseArgs([]string{"--dir", "."}); err == nil {
		t.Fatal("expected missing root to fail")
	}
	if _, err := parseArgs([]string{
		"--root", "/home/node",
		"--dir", ".openclaw",
		"--dir", ".openclaw",
	}); err == nil {
		t.Fatal("expected duplicate directory to fail")
	}
}

func TestRunRepairsOnlyAllowlistedObjects(t *testing.T) {
	requireRoot(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	if err := os.MkdirAll(control, 0o755); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(control, "services.sqlite")
	if err := os.WriteFile(database, []byte("state"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := run(targets{
		root:        root,
		directories: []string{".", ".openclaw", ".openclaw/control"},
		files:       []string{".openclaw/control/services.sqlite"},
	}); err != nil {
		t.Fatalf("repair failed: %v", err)
	}

	assertMetadata(t, control, syscall.S_IFDIR, 0o700, runtimeUID, runtimeGID)
	assertMetadata(t, database, syscall.S_IFREG, 0o600, runtimeUID, runtimeGID)
}

func TestRunRejectsSymlinkedParent(t *testing.T) {
	requireRoot(t)
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, ".openclaw")); err != nil {
		t.Fatal(err)
	}

	if err := run(targets{
		root:        root,
		directories: []string{".openclaw"},
	}); err == nil {
		t.Fatal("expected symlinked parent to fail")
	}
}

func TestRunRejectsSymlinkedFile(t *testing.T) {
	requireRoot(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	if err := os.MkdirAll(control, 0o700); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "outside")
	if err := os.WriteFile(target, []byte("outside"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(control, "services.sqlite")); err != nil {
		t.Fatal(err)
	}

	if err := run(targets{
		root:        root,
		directories: []string{".openclaw/control"},
		files:       []string{".openclaw/control/services.sqlite"},
	}); err == nil {
		t.Fatal("expected symlinked file to fail")
	}
}

func TestRunRejectsMultiplyLinkedFile(t *testing.T) {
	requireRoot(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	if err := os.MkdirAll(control, 0o700); err != nil {
		t.Fatal(err)
	}
	database := filepath.Join(control, "services.sqlite")
	if err := os.WriteFile(database, []byte("state"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(database, filepath.Join(root, "second-link")); err != nil {
		t.Fatal(err)
	}

	if err := run(targets{
		root:        root,
		directories: []string{".openclaw/control"},
		files:       []string{".openclaw/control/services.sqlite"},
	}); err == nil {
		t.Fatal("expected multiply linked file to fail")
	}
}

func TestRunRejectsNonRegularFile(t *testing.T) {
	requireRoot(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	database := filepath.Join(control, "services.sqlite")
	if err := os.MkdirAll(database, 0o700); err != nil {
		t.Fatal(err)
	}

	if err := run(targets{
		root:        root,
		directories: []string{".openclaw/control"},
		files:       []string{".openclaw/control/services.sqlite"},
	}); err == nil {
		t.Fatal("expected non-regular file to fail")
	}
}

func requireRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("requires root to verify ownership repair")
	}
}

func assertMetadata(
	t *testing.T,
	path string,
	expectedType uint32,
	expectedMode os.FileMode,
	expectedUID uint32,
	expectedGID uint32,
) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	stat := info.Sys().(*syscall.Stat_t)
	if stat.Mode&syscall.S_IFMT != expectedType {
		t.Fatalf("%s has type %#o, expected %#o", path, stat.Mode&syscall.S_IFMT, expectedType)
	}
	if info.Mode().Perm() != expectedMode {
		t.Fatalf("%s has mode %o, expected %o", path, info.Mode().Perm(), expectedMode)
	}
	if stat.Uid != expectedUID || stat.Gid != expectedGID {
		t.Fatalf(
			"%s has owner %d:%d, expected %d:%d",
			path,
			stat.Uid,
			stat.Gid,
			expectedUID,
			expectedGID,
		)
	}
}
