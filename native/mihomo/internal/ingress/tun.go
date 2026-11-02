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

// NewTun在公开构造器调用前接收FD所有权。构造失败后的内部FD归属由进程退出收尾。
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
	// Android Builder已经处理路由与底层网络，不启动Linux网络监视器。
	options.AutoRoute, options.AutoDetectInterface = false, false
	sing_tun.EnforceBindInterface = true
	listener, err := construct(options, traffic)
	if err != nil {
		return nil, err, true
	}
	return listener, nil, false
}
