package ingress

import (
	"errors"
	"net/netip"
	"syscall"

	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
)

type Tun = sing_tun.Listener

// NewTun takes FD ownership before calling the public constructor. Process exit resolves internal FD ownership after construction failure.
func NewTun(fd int, options LC.Tun, _ []netip.AddrPort, traffic C.Tunnel) (*Tun, error, bool) {
	return newTun(fd, options, traffic, func(options LC.Tun, traffic C.Tunnel) (*Tun, error) { return sing_tun.New(options, traffic) })
}
func newTun(fd int, options LC.Tun, traffic C.Tunnel, construct func(LC.Tun, C.Tunnel) (*Tun, error)) (*Tun, error, bool) {
	if fd <= 0 {
		err := errors.New("TUN descriptor must be positive")
		if fd == 0 {
			err = errors.Join(err, syscall.Close(fd))
		}
		return nil, err, false
	}
	options.FileDescriptor = fd
	// Android Builder already handles routes and the underlying network; do not start the Linux network monitor.
	options.AutoRoute, options.AutoDetectInterface = false, false
	sing_tun.EnforceBindInterface = true
	listener, err := construct(options, traffic)
	if err != nil {
		return nil, err, true
	}
	return listener, nil, false
}
