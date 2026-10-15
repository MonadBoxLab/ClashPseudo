//go:build linux && !android

package engine

import (
	"errors"
	"syscall"
	"testing"
)

func TestInvalidTunParametersConsumeDescriptor(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	for _, tc := range []struct {
		name         string
		mtu          int
		address      string
		prefixLength int
	}{
		{"address", 1400, "invalid", 30},
		{"ipv6", 1400, "::1", 30},
		{"prefix", 1400, "192.0.2.1", 33},
		{"mtu", 0, "192.0.2.1", 30},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			if err := e.Attach(fd, tc.mtu, tc.address, tc.prefixLength); err == nil {
				t.Fatal("invalid TUN parameters accepted")
			}
			var stat syscall.Stat_t
			if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
				t.Fatalf("descriptor was not consumed: %v", err)
			}
		})
	}
}

func TestAttachWithoutSessionConsumesDescriptor(t *testing.T) {
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := e.Attach(fd, 1400, "192.0.2.1", 30); !errors.Is(err, ErrStopped) {
		t.Fatalf("unexpected attach result: %v", err)
	}
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
		t.Fatalf("descriptor was not consumed: %v", err)
	}
}
