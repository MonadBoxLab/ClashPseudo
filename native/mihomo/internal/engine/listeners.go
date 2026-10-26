package engine

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	A "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/ca"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/http"
	IN "github.com/metacubex/mihomo/listener/inbound"
	"github.com/metacubex/mihomo/listener/mixed"
	"github.com/metacubex/mihomo/listener/shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_vmess"
	"github.com/metacubex/mihomo/listener/socks"
	"github.com/metacubex/mihomo/listener/tuic"
	LT "github.com/metacubex/mihomo/listener/tunnel"
	"github.com/metacubex/mihomo/ntp/ntp"
	"github.com/metacubex/mihomo/tunnel"
	D "github.com/miekg/dns"
)

// Use this copy for resource preparation. Start external ingress synchronously after
// Attach, retaining the effective configuration and VPN specification separately.
func resourceConfig(cfg *config.Config) *config.Config {
	copy := *cfg
	general := *cfg.General
	general.Port, general.SocksPort, general.MixedPort, general.RedirPort, general.TProxyPort = 0, 0, 0, 0, 0
	general.ShadowSocksConfig, general.VmessConfig = "", ""
	general.TuicServer.Enable, general.Tun.Enable = false, false
	copy.General = &general
	dnsConfig := *cfg.DNS
	dnsConfig.Listen = ""
	copy.DNS = &dnsConfig
	ntpConfig := *cfg.NTP
	ntpConfig.Enable = false
	copy.NTP = &ntpConfig
	profile := *cfg.Profile
	profile.StoreSelected = false
	copy.Profile = &profile
	controller := *cfg.Controller
	controller.ExternalUI, controller.ExternalUIURL, controller.ExternalUIName = "", "", ""
	copy.Controller = &controller
	copy.Listeners, copy.Tunnels = nil, nil
	// The process default pool was provided explicitly by Android before Prepare.
	// Keep per-configuration custom certificates in cfg.TLS for ApplyConfig.
	ca.DisableEmbedCa, ca.DisableSystemCa = true, false
	return &copy
}

// Capture actual net objects at public ListenConfig handoff. Close these idempotent
// objects during rollback; successful protocol listeners take sole ownership.
type listenAllocationGuard struct {
	C.InboundListenConfig
	mu        sync.Mutex
	resources []io.Closer
	state     int
}

func (g *listenAllocationGuard) accept(l io.Closer) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.state == 2 {
		_ = l.Close()
		return false
	}
	if g.state == 0 {
		g.resources = append(g.resources, l)
	}
	return true
}
func (g *listenAllocationGuard) Listen(ctx context.Context, network, address string) (net.Listener, error) {
	l, err := g.InboundListenConfig.Listen(ctx, network, address)
	if err == nil && !g.accept(l) {
		return nil, ErrStopped
	}
	return l, err
}
func (g *listenAllocationGuard) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	l, err := g.InboundListenConfig.ListenPacket(ctx, network, address)
	if err == nil && !g.accept(l) {
		return nil, ErrStopped
	}
	return l, err
}
func (g *listenAllocationGuard) disarm() {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.state = 1
	g.resources = nil
}
func (g *listenAllocationGuard) allocated() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.resources) > 0
}
func (g *listenAllocationGuard) rollback() error {
	g.mu.Lock()
	g.state = 2
	resources := g.resources
	g.resources = nil
	g.mu.Unlock()
	var errs []error
	for i := len(resources) - 1; i >= 0; i-- {
		if err := resources[i].Close(); err != nil && !errors.Is(err, net.ErrClosed) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// Use exported parser Option types and set BaseOption.ListenConfigForAPI before
// Listen.
func listenerBase(config C.InboundConfig) *IN.BaseOption {
	switch c := config.(type) {
	case *IN.SocksOption:
		return &c.BaseOption
	case *IN.HTTPOption:
		return &c.BaseOption
	case *IN.MixedOption:
		return &c.BaseOption
	case *IN.TunnelOption:
		return &c.BaseOption
	case *IN.ShadowSocksOption:
		return &c.BaseOption
	case *IN.SnellOption:
		return &c.BaseOption
	case *IN.VmessOption:
		return &c.BaseOption
	case *IN.VlessOption:
		return &c.BaseOption
	case *IN.TrojanOption:
		return &c.BaseOption
	case *IN.Hysteria2Option:
		return &c.BaseOption
	case *IN.Hysteria2RealmServerOption:
		return &c.BaseOption
	case *IN.TuicOption:
		return &c.BaseOption
	case *IN.ShadowQuicOption:
		return &c.BaseOption
	case *IN.AnyTLSOption:
		return &c.BaseOption
	case *IN.MieruOption:
		return &c.BaseOption
	case *IN.SudokuOption:
		return &c.BaseOption
	case *IN.TrustTunnelOption:
		return &c.BaseOption
	default:
		return nil
	}
}

func partialListenerClose(l C.InboundListener) (safe bool, err error) {
	switch l.(type) {
	case *IN.HTTP, *IN.Socks, *IN.Mixed, *IN.Tunnel, *IN.Sudoku, *IN.ShadowQuic, *IN.Mieru:
		return true, l.Close()
	default:
		// A failed single-object constructor may dereference its nil listener and retain an
		// unreturned object. Roll back owned sockets and retain uncertain cleanup state.
		return false, nil
	}
}

func (e *Engine) activateIngress() error {
	cfg := e.cfg
	general := cfg.General
	A.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	A.SetAllowedIPs(general.LanAllowedIPs)
	A.SetDisAllowedIPs(general.LanDisAllowedIPs)
	address := func(port int) string {
		host := "127.0.0.1"
		if general.AllowLan {
			host = general.BindAddress
			if host == "*" {
				host = ""
			}
		}
		return net.JoinHostPort(host, strconv.Itoa(port))
	}
	add := func(name string, closer io.Closer, err error) error {
		// Store the protocol interface only after its public constructor returns a non-nil
		// pointer.
		if err != nil {
			return fmt.Errorf("%s listener startup failed: %w", name, err)
		}
		if closer != nil {
			e.ingress = append(e.ingress, closer)
		}
		return nil
	}
	if general.Port != 0 {
		l, err := http.New(address(general.Port), tunnel.Tunnel)
		if err := add("port", l, err); err != nil {
			return err
		}
	}
	if general.SocksPort != 0 {
		l, err := socks.New(address(general.SocksPort), tunnel.Tunnel)
		if err := add("socks-port TCP", l, err); err != nil {
			return err
		}
		u, err := socks.NewUDP(address(general.SocksPort), tunnel.Tunnel)
		if err := add("socks-port UDP", u, err); err != nil {
			return err
		}
	}
	if general.MixedPort != 0 {
		l, err := mixed.New(address(general.MixedPort), tunnel.Tunnel)
		if err := add("mixed-port TCP", l, err); err != nil {
			return err
		}
		u, err := socks.NewUDP(address(general.MixedPort), tunnel.Tunnel)
		if err := add("mixed-port UDP", u, err); err != nil {
			return err
		}
	}
	lc := A.NewListenConfig()
	construct := func(name string, create func(C.InboundListenConfig) (io.Closer, error)) error {
		guard := &listenAllocationGuard{InboundListenConfig: lc}
		value, err := create(guard)
		if err != nil {
			// Close captured raw socket objects; retain uncertain cleanup for protocol objects
			// lost inside their constructors.
			if guard.allocated() {
				e.failed = true
			}
			return errors.Join(fmt.Errorf("%s listener construction failed: %w", name, err), guard.rollback())
		}
		guard.disarm()
		e.ingress = append(e.ingress, value)
		return nil
	}
	if general.ShadowSocksConfig != "" {
		addr, cipher, password, err := shadowsocks.ParseSSURL(general.ShadowSocksConfig)
		if err != nil {
			return errors.New("ss-config: invalid Shadowsocks listener URL")
		}
		if err := construct("ss-config", func(owned C.InboundListenConfig) (io.Closer, error) {
			return sing_shadowsocks.New(LC.ShadowsocksServer{Enable: true, Listen: addr, Cipher: cipher, Password: password, Udp: true}, owned, tunnel.Tunnel)
		}); err != nil {
			return err
		}
	}
	if general.VmessConfig != "" {
		addr, username, uuid, err := sing_vmess.ParseVmessURL(general.VmessConfig)
		if err != nil {
			return errors.New("vmess-config: invalid VMess listener URL")
		}
		if err := construct("vmess-config", func(owned C.InboundListenConfig) (io.Closer, error) {
			return sing_vmess.New(LC.VmessServer{Enable: true, Listen: addr, Users: []LC.VmessUser{{Username: username, UUID: uuid, AlterID: 1}}}, owned, tunnel.Tunnel)
		}); err != nil {
			return err
		}
	}
	if general.TuicServer.Enable {
		if err := construct("tuic-server", func(owned C.InboundListenConfig) (io.Closer, error) {
			return tuic.New(general.TuicServer, owned, tunnel.Tunnel)
		}); err != nil {
			return err
		}
	}
	names := make([]string, 0, len(cfg.Listeners))
	for name := range cfg.Listeners {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		l := cfg.Listeners[name]
		base := listenerBase(l.Config())
		if base == nil {
			return &PlatformError{Field: "listeners.type", Reason: "rootRedirection"}
		}
		guard := &listenAllocationGuard{InboundListenConfig: base.ListenConfig()}
		base.ListenConfigForAPI = guard
		if err := l.Listen(tunnel.Tunnel); err != nil {
			safe, closeErr := partialListenerClose(l)
			if !safe {
				e.failed = true
			}
			return errors.Join(fmt.Errorf("named listener %q startup failed: %w", name, err), closeErr, guard.rollback())
		}
		// The returned protocol listener owns all constructed sockets and handles normal
		// Stop through Close.
		guard.disarm()
		e.ingress = append(e.ingress, l)
	}
	for _, forward := range cfg.Tunnels {
		for _, protocol := range forward.Network {
			switch protocol {
			case "tcp":
				l, err := LT.New(forward.Address, forward.Target, forward.Proxy, lc, tunnel.Tunnel)
				if err := add("tunnels TCP", l, err); err != nil {
					return err
				}
			case "udp":
				l, err := LT.NewUDP(forward.Address, forward.Target, forward.Proxy, lc, tunnel.Tunnel)
				if err := add("tunnels UDP", l, err); err != nil {
					return err
				}
			default:
				return errors.New("tunnels: unsupported network")
			}
		}
	}
	if cfg.DNS.Enable && cfg.DNS.Listen != "" {
		_, port, err := net.SplitHostPort(cfg.DNS.Listen)
		if err != nil {
			return errors.New("dns.listen: invalid listener address")
		}
		if port != "0" {
			l, err := startDNSListener(cfg.DNS.Listen)
			if err := add("dns.listen", l, err); err != nil {
				return err
			}
		}
	}
	if cfg.NTP.Enable {
		if cfg.NTP.Interval <= 0 || cfg.NTP.Port <= 0 || cfg.NTP.Port > 65535 || strings.TrimSpace(cfg.NTP.Server) == "" {
			return errors.New("ntp: invalid server, port or interval")
		}
		// Public Stop cancels its context; detached upstream tasks retain their completion
		// lifetime.
		ntp.ReCreateNTPService(net.JoinHostPort(cfg.NTP.Server, strconv.Itoa(cfg.NTP.Port)), time.Duration(cfg.NTP.Interval), cfg.NTP.DialerProxy, tunnel.Tunnel, false)
	}
	return nil
}

type dnsListener struct {
	ctx     context.Context
	cancel  context.CancelFunc
	service resolver.Service
	raw     []io.Closer
	servers []*D.Server
	done    []chan error
	once    sync.Once
	err     error
}

func (l *dnsListener) ServeMsg(ctx context.Context, message *D.Msg) (*D.Msg, error) {
	child, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(l.ctx, cancel)
	defer func() { stop(); cancel() }()
	return l.service.ServeMsg(child, message)
}

func (l *dnsListener) Close() error {
	l.once.Do(func() {
		if l.cancel != nil {
			l.cancel()
		}
		var errs []error
		for _, raw := range l.raw {
			if err := raw.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
				errs = append(errs, err)
			}
		}
		for _, server := range l.servers {
			_ = server.Shutdown()
		}
		for _, done := range l.done {
			err := <-done
			if err != nil && !errors.Is(err, net.ErrClosed) && !strings.Contains(err.Error(), "closed network connection") {
				errs = append(errs, err)
			}
		}
		l.err = errors.Join(errs...)
	})
	return l.err
}
func startDNSListener(address string) (_ *dnsListener, err error) {
	if resolver.DefaultService == nil {
		return nil, errors.New("DNS service is disabled")
	}
	l := &dnsListener{service: resolver.DefaultService}
	l.ctx, l.cancel = context.WithCancel(context.Background())
	defer func() {
		if err != nil {
			err = errors.Join(err, l.Close())
		}
	}()
	lc := A.NewListenConfig()
	tcp, err := lc.Listen(context.Background(), "tcp", address)
	if err != nil {
		return nil, err
	}
	l.raw = append(l.raw, tcp)
	udp, err := lc.ListenPacket(context.Background(), "udp", address)
	if err != nil {
		return nil, err
	}
	l.raw = append(l.raw, udp)
	service := &dns.Server{}
	service.SetService(l)
	for _, server := range []*D.Server{{Listener: tcp, Handler: service.TCPHandler()}, {PacketConn: udp, Handler: service.UDPHandler()}} {
		started := make(chan struct{})
		server.NotifyStartedFunc = func() { close(started) }
		done := make(chan error, 1)
		l.servers = append(l.servers, server)
		l.done = append(l.done, done)
		go func() { done <- server.ActivateAndServe() }()
		select {
		case <-started:
		case err = <-done:
			done <- err
			return nil, err
		}
	}
	return l, nil
}
