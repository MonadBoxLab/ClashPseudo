package engine

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/adapter/inbound"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/listener/sing"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	tun "github.com/metacubex/sing-tun"
	"golang.org/x/sys/unix"
)

type externalTun struct {
	device tun.Tun
	stack  tun.Stack
	cancel context.CancelFunc
	once   sync.Once
	err    error
}

func (t *externalTun) Close() error {
	t.once.Do(func() {
		t.cancel()
		var stackErr, tunErr error
		if t.stack != nil {
			stackErr = t.stack.Close()
		}
		if t.device != nil {
			tunErr = t.device.Close()
		}
		t.err = errors.Join(stackErr, tunErr)
	})
	return t.err
}

type tunFactories struct {
	device func(tun.Options) (tun.Tun, error)
	stack  func(string, tun.StackOptions) (tun.Stack, error)
}

func (e *Engine) CanAttach(revision uint64) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.canAttachLocked(revision)
}
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
	if !e.cfg.General.Tun.Enable || e.options.Purpose != "VPN" {
		return errors.New("TUN is not enabled for this preparation")
	}
	return nil
}

// Attach consumes the descriptor exactly once on success or failure. JNI validates,
// detaches and transfers its raw guard to this contract.
func (e *Engine) Attach(fd int, revision uint64) error {
	return e.attach(fd, revision, tunFactories{tun.New, tun.NewStack})
}
func (e *Engine) attach(fd int, revision uint64, factories tunFactories) (err error) {
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
	defer e.mu.Unlock()
	if err := e.canAttachLocked(revision); err != nil {
		return err
	}
	options := e.cfg.General.Tun
	dnsAddresses, err := parseHijack(options.DNSHijack)
	if err != nil {
		return err
	}
	handler, err := sing.NewListenerHandler(sing.ListenerConfig{Tunnel: tunnel.Tunnel, Type: C.TUN,
		Additions: []inbound.Addition{inbound.WithInName("DEFAULT-TUN"), inbound.WithSpecialRules("")}})
	if err != nil {
		return err
	}
	listener := &sing_tun.ListenerHandler{ListenerHandler: handler, DnsAddrPorts: dnsAddresses,
		Inet4Address: options.Inet4Address, Inet6Address: options.Inet6Address, DisableICMPForwarding: options.DisableICMPForwarding}
	ctx, cancel := context.WithCancel(context.Background())
	owned := &externalTun{cancel: cancel}
	defer func() {
		if err != nil {
			err = errors.Join(err, owned.Close())
			if e.tun == owned {
				e.tun = nil
			}
		}
	}()
	// VpnService.Builder materializes AutoRoute and filters; the external descriptor
	// supplies the selected public stack.
	deviceOptions := tun.Options{FileDescriptor: fd, DNSMode: options.DNSMode, MTU: options.MTU, Inet4Address: options.Inet4Address,
		Inet6Address: options.Inet6Address, EXP_RecvMsgX: options.RecvMsgX, EXP_SendMsgX: options.SendMsgX,
		EXP_ProcessorsPerChannel: options.ProcessorsPerChannel}
	stackName := strings.ToLower(options.Stack.String())
	bindForwarder := runtime.GOOS == "android" && (stackName == "system" || stackName == "mixed")
	if bindForwarder {
		// Return kernel TCP replies through this TUN while preserving the user's application
		// filter.
		request, err := unix.NewIfreq("")
		if err != nil {
			return fmt.Errorf("external TUN interface request: %w", err)
		}
		if err := unix.IoctlIfreq(fd, unix.TUNGETIFF, request); err != nil {
			return fmt.Errorf("external TUN interface query: %w", err)
		}
		deviceOptions.Name = request.Name()
		if deviceOptions.Name == "" {
			return errors.New("external TUN interface name is empty")
		}
	}
	for _, address := range options.LoopbackAddress {
		if address.Is4() {
			deviceOptions.Inet4LoopbackAddress = append(deviceOptions.Inet4LoopbackAddress, address)
		} else {
			deviceOptions.Inet6LoopbackAddress = append(deviceOptions.Inet6LoopbackAddress, address)
		}
	}
	device, err := factories.device(deviceOptions)
	if err != nil {
		return fmt.Errorf("external TUN creation: %w", err)
	}
	owned.device, raw = device, -1
	udpTimeout, icmpTimeout := sing.UDPTimeout, sing.ICMPTimeout
	if options.UDPTimeout != 0 {
		udpTimeout = time.Duration(options.UDPTimeout) * time.Second
	}
	if options.ICMPTimeout != 0 {
		icmpTimeout = time.Duration(options.ICMPTimeout) * time.Second
	}
	stack, err := factories.stack(stackName, tun.StackOptions{Context: ctx, Tun: device,
		TunOptions: deviceOptions, EndpointIndependentNat: options.EndpointIndependentNat, UDPTimeout: udpTimeout,
		ICMPTimeout: icmpTimeout, Handler: listener, Logger: log.SingLogger, TCPCongestionControl: options.CongestionController,
		InterfaceFinder: sing_tun.DefaultInterfaceFinder, ForwarderBindInterface: bindForwarder, EnforceBindInterface: bindForwarder})
	if err != nil {
		return fmt.Errorf("TUN stack construction: %w", err)
	}
	// Register both returned objects before Start. The upstream high-level
	// constructor registers its stack only after Start, leaving that failure gap.
	owned.stack, e.tun = stack, owned
	if err = stack.Start(); err != nil {
		return fmt.Errorf("TUN stack start: %w", err)
	}
	if !e.owner.active.Load() {
		return ErrStopped
	}
	e.attachedRoutes = slices.Clone(e.spec.Routes)
	if err = e.activateIngress(); err != nil {
		return errors.Join(err, e.stopLocked())
	}
	if !e.owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	return nil
}
