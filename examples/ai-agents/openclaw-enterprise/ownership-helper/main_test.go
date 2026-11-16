//go:build linux

package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
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

func TestParseArgsAcceptsOptionalDirectory(t *testing.T) {
	t.Parallel()
	if _, err := parseArgs([]string{
		"--root", "/home/node",
		"--dir", ".",
		"--optional-dir", ".openclaw/control",
	}); err != nil {
		t.Fatalf("expected optional directory to parse: %v", err)
	}
}

func TestRunSkipsMissingOptionalDirectory(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".openclaw"), 0o700); err != nil {
		t.Fatal(err)
	}

	if err := runArgs(
		"--root", root,
		"--dir", ".",
		"--dir", ".openclaw",
		"--optional-dir", ".openclaw/control",
	); err != nil {
		t.Fatalf("missing optional directory should be skipped: %v", err)
	}
}

func TestRunStillRejectsMissingMandatoryDirectory(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()

	err := runArgs(
		"--root", root,
		"--dir", ".",
		"--dir", ".openclaw/control",
	)
	if !errors.Is(err, syscall.ENOENT) {
		t.Fatalf("expected missing mandatory directory to fail with ENOENT, got %v", err)
	}
}

func TestRunRepairsExistingOptionalDirectory(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	if err := os.MkdirAll(control, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := runArgs(
		"--root", root,
		"--dir", ".",
		"--dir", ".openclaw",
		"--optional-dir", ".openclaw/control",
	); err != nil {
		t.Fatalf("existing optional directory should be repaired: %v", err)
	}

	assertMetadata(t, control, syscall.S_IFDIR, 0o700, runtimeUID, runtimeGID)
}

func TestRunRejectsSymlinkedOptionalDirectory(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, ".openclaw"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(
		t.TempDir(),
		filepath.Join(root, ".openclaw", "control"),
	); err != nil {
		t.Fatal(err)
	}

	err := runArgs(
		"--root", root,
		"--dir", ".",
		"--dir", ".openclaw",
		"--optional-dir", ".openclaw/control",
	)
	if !errors.Is(err, syscall.ELOOP) {
		t.Fatalf("expected symlinked optional directory to fail with ELOOP, got %v", err)
	}
}

func TestRunRejectsNonDirectoryOptionalTarget(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()
	control := filepath.Join(root, ".openclaw", "control")
	if err := os.Mkdir(filepath.Dir(control), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(control, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}

	err := runArgs(
		"--root", root,
		"--dir", ".",
		"--dir", ".openclaw",
		"--optional-dir", ".openclaw/control",
	)
	if !errors.Is(err, syscall.ENOTDIR) {
		t.Fatalf("expected non-directory optional target to fail with ENOTDIR, got %v", err)
	}
}

func TestRunRejectsOptionalDirectoryLookupErrors(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
	root := t.TempDir()
	tooLong := strings.Repeat("x", 256)

	err := runArgs(
		"--root", root,
		"--dir", ".",
		"--optional-dir", tooLong,
	)
	if !errors.Is(err, syscall.ENAMETOOLONG) {
		t.Fatalf("expected optional directory lookup error to be preserved, got %v", err)
	}
}

func TestRunRepairsOnlyAllowlistedObjects(t *testing.T) {
	requireRoot(t)
	requireOpenat2(t)
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
	requireOpenat2(t)
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
	requireOpenat2(t)
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
	requireOpenat2(t)
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
	requireOpenat2(t)
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

func runArgs(args ...string) error {
	parsed, err := parseArgs(args)
	if err != nil {
		return err
	}
	return run(parsed)
}

func requireRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("requires root to verify ownership repair")
	}
}

func requireOpenat2(t *testing.T) {
	t.Helper()
	root := t.TempDir()
	fd, err := openRoot(root)
	if errors.Is(err, syscall.ENOSYS) {
		t.Skip("openat2 is blocked by the container runtime")
	}
	if err != nil {
		t.Fatalf("probe openat2: %v", err)
	}
	if err := syscall.Close(fd); err != nil {
		t.Fatalf("close openat2 probe: %v", err)
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
