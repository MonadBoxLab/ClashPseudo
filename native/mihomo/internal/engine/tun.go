package engine

import (
	"errors"
	"net/netip"
	"slices"
	"syscall"

	"clashpseudo/native/internal/androidnet"
	"clashpseudo/native/internal/ingress"

	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/tunnel"
)

// Attach uses only this finite resource capability. Device and stack factories
// remain inside ingress; session state is not available to the constructor.
type tunResource interface {
	Close() error
}

type tunConstructor func(int, LC.Tun, []netip.AddrPort) (tunResource, error, bool)

func (e *Engine) canAttachLocked(revision uint64) error {
	if e.cfg == nil || e.spec == nil || e.tun != nil || e.owner == nil || !e.owner.active.Load() {
		return ErrStopped
	}
	if e.specError != nil {
		return e.specError
	}
	if revision != e.spec.Revision {
		return errors.New("TUN specification revision changed before descriptor attachment")
	}
	if !e.cfg.General.Tun.Enable || !e.options.VPNIntent {
		return errors.New("TUN is not enabled for this preparation")
	}
	return nil
}

// Attach consumes the descriptor exactly once on success or failure. JNI validates,
// detaches and transfers its raw guard to this contract.
func (e *Engine) Attach(fd int, revision uint64) error {
	return e.attach(fd, revision, func(fd int, options LC.Tun, dnsAddresses []netip.AddrPort) (tunResource, error, bool) {
		return ingress.NewTun(fd, options, dnsAddresses, tunnel.Tunnel)
	})
}
func (e *Engine) attach(fd int, revision uint64, construct tunConstructor) (err error) {
	raw := fd
	defer func() {
		if raw >= 0 {
			err = errors.Join(err, syscall.Close(raw))
		}
	}()
	if fd < 0 {
		return errors.New("invalid TUN descriptor")
	}
	if fd == 0 {
		return errors.New("TUN descriptor zero is reserved by the public external-FD API")
	}
	e.mu.Lock()
	stop := false
	defer func() {
		if stop && e.owner != nil {
			e.owner.active.Store(false)
		}
		e.mu.Unlock()
		if stop {
			// Preparation has already admitted provider/Geo work. Keep its home
			// and session owned until the same real drain as a normal Stop returns.
			err = errors.Join(err, e.Stop())
		}
	}()
	if err := e.canAttachLocked(revision); err != nil {
		return err
	}
	options := e.cfg.General.Tun
	dnsAddresses, err := androidnet.ParseHijack(options.DNSHijack)
	if err != nil {
		return err
	}
	// 公开构造器接收FD并完成Start；应用只登记成功返回的resource。
	raw = -1
	owned, err, cleanupUncertain := construct(fd, options, dnsAddresses)
	if cleanupUncertain {
		e.failed = true
	}
	if err != nil {
		stop = true
		return err
	}
	e.tun = owned
	if !e.owner.active.Load() {
		stop = true
		return ErrStopped
	}
	e.attachedRoutes = slices.Clone(e.spec.Routes)
	if !e.owner.active.Load() {
		stop = true
		return ErrStopped
	}
	return nil
}
