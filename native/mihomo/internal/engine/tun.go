package engine

import (
	"errors"
	"net/netip"
	"syscall"

	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

// Attach consumes fd, including on failure. The cmfa build tag disables Android
// package-file scanning; package filters and native auto-routing are not used.
func (e *Engine) Attach(fd, mtu int, address string, prefixLength int) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if fd < 0 {
		return errors.New("invalid TUN descriptor")
	}
	if fd == 0 {
		return errors.Join(errors.New("TUN descriptor zero is reserved by the kernel API"), syscall.Close(fd))
	}
	if e.cfg == nil || e.tun != nil || e.owner == nil || !e.owner.active.Load() {
		return errors.Join(ErrStopped, syscall.Close(fd))
	}
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() || prefixLength < 0 || prefixLength > 32 || mtu <= 0 {
		return errors.Join(errors.New("invalid IPv4 TUN parameters"), syscall.Close(fd))
	}
	options := LC.Tun{
		Enable:         true,
		Device:         "ClashPseudo",
		Stack:          C.TunSystem,
		MTU:            uint32(mtu),
		Inet4Address:   []netip.Prefix{netip.PrefixFrom(ip, prefixLength)},
		DNSHijack:      []string{"0.0.0.0:53"},
		FileDescriptor: fd,
	}
	// Parameters above are checked before ownership passes to sing-tun.
	// With cmfa and these options, its later failures close fd via Listener.Close.
	listener, err := sing_tun.New(options, tunnel.Tunnel)
	if err != nil {
		return err
	}
	e.tun = listener
	if !e.owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	return nil
}
