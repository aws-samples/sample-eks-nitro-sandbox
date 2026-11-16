//go:build linux

// ownership-helper repairs a fixed allowlist of OpenClaw state paths without
// following symlinks or re-resolving a checked pathname.
package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const (
	runtimeUID = 1000
	runtimeGID = 1000

	sysOpenat2          = 437
	resolveNoMagiclinks = 0x02
	resolveNoSymlinks   = 0x04
	resolveBeneath      = 0x08
)

type openHow struct {
	flags   uint64
	mode    uint64
	resolve uint64
}

type targets struct {
	root        string
	directories []string
	files       []string
}

func usageError(message string) error {
	return fmt.Errorf("%s; usage: ownership-helper --root /absolute/path [--dir relative/path] [--file relative/path]", message)
}

func validateRelativePath(path string, allowDot bool) error {
	if path == "" || filepath.IsAbs(path) || filepath.Clean(path) != path {
		return fmt.Errorf("path %q must be a canonical relative path", path)
	}
	if path == "." {
		if allowDot {
			return nil
		}
		return fmt.Errorf("path %q is not a file", path)
	}
	for _, component := range strings.Split(path, string(filepath.Separator)) {
		if component == "" || component == "." || component == ".." {
			return fmt.Errorf("path %q contains an unsafe component", path)
		}
	}
	return nil
}

func parseArgs(args []string) (targets, error) {
	var result targets
	seen := make(map[string]struct{})
	for index := 0; index < len(args); index += 2 {
		if index+1 >= len(args) {
			return targets{}, usageError("every option requires a value")
		}
		option, value := args[index], args[index+1]
		switch option {
		case "--root":
			if result.root != "" {
				return targets{}, usageError("--root may be supplied once")
			}
			if !filepath.IsAbs(value) || filepath.Clean(value) != value || value == "/" {
				return targets{}, usageError("--root must be a canonical absolute path below /")
			}
			result.root = value
		case "--dir", "--file":
			if err := validateRelativePath(value, option == "--dir"); err != nil {
				return targets{}, err
			}
			key := option + "\x00" + value
			if _, exists := seen[key]; exists {
				return targets{}, fmt.Errorf("duplicate target %q", value)
			}
			seen[key] = struct{}{}
			if option == "--dir" {
				result.directories = append(result.directories, value)
			} else {
				result.files = append(result.files, value)
			}
		default:
			return targets{}, usageError("unknown option " + option)
		}
	}
	if result.root == "" || len(result.directories) == 0 {
		return targets{}, usageError("--root and at least one --dir are required")
	}
	return result, nil
}

func openAt2(directoryFD int, path string, flags int) (int, error) {
	pathBytes, err := syscall.BytePtrFromString(path)
	if err != nil {
		return -1, err
	}
	how := openHow{
		flags: uint64(flags),
		resolve: resolveBeneath |
			resolveNoMagiclinks |
			resolveNoSymlinks,
	}
	fd, _, errno := syscall.Syscall6(
		sysOpenat2,
		uintptr(directoryFD),
		uintptr(unsafe.Pointer(pathBytes)),
		uintptr(unsafe.Pointer(&how)),
		unsafe.Sizeof(how),
		0,
		0,
	)
	if errno != 0 {
		return -1, errno
	}
	return int(fd), nil
}

func repairFD(fd int, expectedType uint32, mode uint32, requireSingleLink bool) error {
	var info syscall.Stat_t
	if err := syscall.Fstat(fd, &info); err != nil {
		return err
	}
	if info.Mode&syscall.S_IFMT != expectedType {
		return fmt.Errorf("unexpected file type")
	}
	if requireSingleLink && info.Nlink != 1 {
		return fmt.Errorf("regular file has %d links; expected one", info.Nlink)
	}
	if err := syscall.Fchown(fd, runtimeUID, runtimeGID); err != nil {
		return err
	}
	if err := syscall.Fchmod(fd, mode); err != nil {
		return err
	}
	return nil
}

func openRoot(root string) (int, error) {
	baseFD, err := syscall.Open(
		"/",
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
		0,
	)
	if err != nil {
		return -1, err
	}
	defer syscall.Close(baseFD)
	return openAt2(
		baseFD,
		strings.TrimPrefix(root, "/"),
		syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
	)
}

func run(targets targets) error {
	rootFD, err := openRoot(targets.root)
	if err != nil {
		return fmt.Errorf("open root: %w", err)
	}
	defer syscall.Close(rootFD)

	for _, path := range targets.directories {
		fd, err := openAt2(
			rootFD,
			path,
			syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
		)
		if err != nil {
			return fmt.Errorf("open directory %q: %w", path, err)
		}
		err = repairFD(fd, syscall.S_IFDIR, 0o700, false)
		syscall.Close(fd)
		if err != nil {
			return fmt.Errorf("repair directory %q: %w", path, err)
		}
	}

	for _, path := range targets.files {
		fd, err := openAt2(
			rootFD,
			path,
			syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,
		)
		if errors.Is(err, syscall.ENOENT) {
			continue
		}
		if err != nil {
			return fmt.Errorf("open file %q: %w", path, err)
		}
		err = repairFD(fd, syscall.S_IFREG, 0o600, true)
		syscall.Close(fd)
		if err != nil {
			return fmt.Errorf("repair file %q: %w", path, err)
		}
	}
	return nil
}

func main() {
	targets, err := parseArgs(os.Args[1:])
	if err == nil {
		err = run(targets)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "ownership-helper: %v\n", err)
		os.Exit(1)
	}
}
