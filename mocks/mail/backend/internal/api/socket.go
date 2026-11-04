package api

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
)

// Listen never removes an existing socket: another daemon may own it.
func Listen(path string) (net.Listener, error) {
	if !filepath.IsAbs(path) {
		return nil, fmt.Errorf("socket path must be absolute")
	}
	if len(path) > 100 {
		return nil, fmt.Errorf("socket path is too long; choose a shorter --socket path")
	}
	dir := filepath.Dir(path)
	if e := os.MkdirAll(dir, 0700); e != nil {
		return nil, e
	}
	info, e := os.Stat(dir)
	if e != nil {
		return nil, e
	}
	if info.Mode().Perm()&0077 != 0 {
		return nil, fmt.Errorf("socket directory must be private (mode 0700)")
	}
	l, e := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if e != nil {
		return nil, e
	}
	if e = os.Chmod(path, 0600); e != nil {
		l.Close()
		return nil, e
	}
	return l, nil
}
