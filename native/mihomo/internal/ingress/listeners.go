package ingress

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"

	A "github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/listener/auth"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/http"
	"github.com/metacubex/mihomo/listener/mixed"
	"github.com/metacubex/mihomo/listener/shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_shadowsocks"
	"github.com/metacubex/mihomo/listener/sing_vmess"
	"github.com/metacubex/mihomo/listener/socks"
	"github.com/metacubex/mihomo/listener/tuic"
	LT "github.com/metacubex/mihomo/listener/tunnel"
)

type Result struct {
	Resources        []io.Closer
	Err              error
	CleanupUncertain bool
}

// SocketState only reports actual socket creation and closure, without inferring protocol service readiness.
type SocketState struct {
	Name    string `json:"name"`
	Network string `json:"network"`
	Address string `json:"address"`
	State   string `json:"state"`
	Error   string `json:"error,omitempty"`
}

type Observer struct {
	mu       sync.Mutex
	states   map[[3]string]SocketState
	owned    map[string]*ownedResource
	order    []string
	failures map[string]error
}

func (o *Observer) record(state SocketState) {
	if o == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.states == nil {
		o.states = make(map[[3]string]SocketState)
	}
	o.states[[3]string{state.Name, state.Network, state.Address}] = state
}
func (o *Observer) Snapshot() []SocketState {
	if o == nil {
		return nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	result := make([]SocketState, 0, len(o.states))
	for _, state := range o.states {
		result = append(result, state)
	}
	slices.SortFunc(result, func(a, b SocketState) int {
		return strings.Compare(a.Name+"\x00"+a.Network+"\x00"+a.Address, b.Name+"\x00"+b.Network+"\x00"+b.Address)
	})
	return result
}

type ownedResource struct {
	resources []io.Closer
	once      sync.Once
	err       error
}

func (r *ownedResource) Close() error {
	r.once.Do(func() { r.err = Close(r.resources) })
	return r.err
}
func (o *Observer) register(name string, resources ...io.Closer) (*ownedResource, error) {
	r := &ownedResource{resources: resources}
	if o == nil {
		return r, nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.owned == nil {
		o.owned = make(map[string]*ownedResource)
	}
	if o.owned[name] != nil {
		return nil, fmt.Errorf("listener ownership name %q is already registered", name)
	}
	o.owned[name] = r
	o.order = append(o.order, name)
	return r, nil
}
func (o *Observer) failed(name string, err error) {
	if o == nil || err == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.failures == nil {
		o.failures = make(map[string]error)
	}
	o.failures[name] = err
}
func (o *Observer) Errors() error {
	if o == nil {
		return nil
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	errs := make([]error, 0, len(o.failures))
	for _, err := range o.failures {
		errs = append(errs, err)
	}
	return errors.Join(errs...)
}
func (o *Observer) CloseListener(name string) error {
	if o == nil {
		return fmt.Errorf("listener %q is not owned by this context", name)
	}
	o.mu.Lock()
	r := o.owned[name]
	o.mu.Unlock()
	if r == nil {
		return fmt.Errorf("listener %q is not owned by this context", name)
	}
	return r.Close()
}

func (o *Observer) CloseAll() error {
	if o == nil {
		return nil
	}
	o.mu.Lock()
	resources := make([]io.Closer, 0, len(o.order))
	for _, name := range o.order {
		resources = append(resources, o.owned[name])
	}
	o.mu.Unlock()
	return Close(resources)
}

type Options struct {
	Protect  func(int) error
	Observer *Observer
}

// listenConfig only forwards sockets created upstream and applies protect; it does not bind them to the default upstream Network.
type listenConfig struct {
	C.InboundListenConfig
	name      string
	options   Options
	mu        sync.Mutex
	resources []io.Closer
	closed    bool
	bound     chan error
}

func newListenConfig(name string, base C.InboundListenConfig, options Options) *listenConfig {
	return &listenConfig{InboundListenConfig: base, name: name, options: options}
}
func (l *listenConfig) capture(network, address string, resource io.Closer, err error) error {
	if err == nil && l.options.Protect != nil {
		rawObject, ok := resource.(interface {
			SyscallConn() (syscall.RawConn, error)
		})
		if !ok {
			err = fmt.Errorf("%T does not expose its socket descriptor", resource)
		} else {
			raw, rawErr := rawObject.SyscallConn()
			err = rawErr
			if err == nil {
				var protectErr error
				err = raw.Control(func(fd uintptr) { protectErr = l.options.Protect(int(fd)) })
				err = errors.Join(err, protectErr)
			}
		}
	}
	l.mu.Lock()
	if err == nil && l.closed {
		err = net.ErrClosed
	}
	if err == nil {
		l.resources = append(l.resources, resource)
	}
	l.mu.Unlock()
	state := SocketState{Name: l.name, Network: network, Address: address, State: "bound"}
	if err != nil {
		if resource != nil {
			err = errors.Join(err, resource.Close())
		}
		state.State, state.Error = "failed", err.Error()
	}
	l.options.Observer.record(state)
	if l.bound != nil {
		l.bound <- err
	}
	return err
}
func (l *listenConfig) Listen(ctx context.Context, network, address string) (net.Listener, error) {
	value, err := l.InboundListenConfig.Listen(ctx, network, address)
	if err != nil {
		return nil, l.capture(network, address, nil, err)
	}
	observed := &observedListener{Listener: value, name: l.name, network: network, address: value.Addr().String(), observer: l.options.Observer}
	if err = l.capture(network, observed.address, observed, nil); err != nil {
		return nil, err
	}
	return observed, nil
}
func (l *listenConfig) ListenPacket(ctx context.Context, network, address string) (net.PacketConn, error) {
	value, err := l.InboundListenConfig.ListenPacket(ctx, network, address)
	if err != nil {
		return nil, l.capture(network, address, nil, err)
	}
	observed := &observedPacket{PacketConn: value, name: l.name, network: network, address: value.LocalAddr().String(), observer: l.options.Observer}
	if err = l.capture(network, observed.address, observed, nil); err != nil {
		return nil, err
	}
	return observed, nil
}
func (l *listenConfig) Close() error {
	l.mu.Lock()
	l.closed = true
	resources := l.resources
	l.resources = nil
	l.mu.Unlock()
	return Close(resources)
}

type observedListener struct {
	net.Listener
	name, network, address string
	observer               *Observer
	once                   sync.Once
	err                    error
}

func (l *observedListener) SyscallConn() (syscall.RawConn, error) {
	if raw, ok := l.Listener.(syscall.Conn); ok {
		return raw.SyscallConn()
	}
	return nil, fmt.Errorf("listener %q has no public descriptor", l.name)
}
func (l *observedListener) Close() error {
	l.once.Do(func() { l.err = l.Listener.Close(); recordClose(l.observer, l.name, l.network, l.address, l.err) })
	return l.err
}

type observedPacket struct {
	net.PacketConn
	name, network, address string
	observer               *Observer
	once                   sync.Once
	err                    error
}

func (l *observedPacket) SyscallConn() (syscall.RawConn, error) {
	if raw, ok := l.PacketConn.(syscall.Conn); ok {
		return raw.SyscallConn()
	}
	return nil, fmt.Errorf("packet listener %q has no public descriptor", l.name)
}
func (l *observedPacket) Close() error {
	l.once.Do(func() { l.err = l.PacketConn.Close(); recordClose(l.observer, l.name, l.network, l.address, l.err) })
	return l.err
}
func recordClose(o *Observer, name, network, address string, err error) {
	state := SocketState{Name: name, Network: network, Address: address, State: "closed"}
	if err != nil {
		state.State, state.Error = "closeFailed", err.Error()
	}
	o.record(state)
}

// observedInbound.Listen is called only once by this hub.ApplyConfig invocation.
type observedInbound struct {
	C.InboundListener
	config   *listenConfig
	observer *Observer
	owned    *ownedResource
}

func (l *observedInbound) Listen(t C.Tunnel) error {
	err := l.InboundListener.Listen(t)
	if err == nil {
		l.owned, err = l.observer.register(l.Name(), l.config, l.InboundListener)
	}
	if err != nil {
		if l.config != nil {
			err = errors.Join(err, l.config.Close())
		}
		l.observer.failed(l.Name(), err)
		l.observer.record(SocketState{Name: l.Name(), Address: l.RawAddress(), State: "failed", Error: err.Error()})
	}
	return err
}
func (l *observedInbound) Close() error {
	if l.owned != nil {
		return l.owned.Close()
	}
	return l.config.Close()
}

// PrepareNamed injects ListenConfigForAPI into the public BaseOption without a protocol type allowlist.
func PrepareNamed(cfg *config.Config, options Options) error {
	for name, listener := range cfg.Listeners {
		var wrapped *listenConfig
		value := reflect.ValueOf(listener.Config())
		if value.Kind() == reflect.Pointer && !value.IsNil() {
			field := value.Elem().FieldByName("ListenConfigForAPI")
			if field.IsValid() && field.CanSet() {
				if base, ok := listener.Config().(interface{ ListenConfig() C.InboundListenConfig }); ok {
					wrapped = newListenConfig(name, base.ListenConfig(), options)
					field.Set(reflect.ValueOf(wrapped))
				}
			}
		}
		if wrapped == nil {
			return fmt.Errorf("listener %q does not expose ListenConfigForAPI", name)
		}
		cfg.Listeners[name] = &observedInbound{InboundListener: listener, config: wrapped, observer: options.Observer}
	}
	return nil
}

// Activate only creates deferred ingress resources; hub still loads named listeners and NTP.
func Activate(cfg *config.Config, traffic C.Tunnel, opts ...Options) (result Result) {
	var options Options
	if len(opts) != 0 {
		options = opts[0]
	}
	result.Err = activate(cfg, traffic, options, &result)
	if result.Err != nil {
		cleanupErr := Close(result.Resources)
		result.CleanupUncertain = result.CleanupUncertain || cleanupErr != nil
		result.Err = errors.Join(result.Err, cleanupErr)
		result.Resources = nil
	}
	return result
}
func Close(resources []io.Closer) error {
	var errs []error
	for i := len(resources) - 1; i >= 0; i-- {
		if err := resources[i].Close(); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
func activate(cfg *config.Config, traffic C.Tunnel, options Options, result *Result) error {
	general := cfg.General
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
	construct := func(name string, create func(C.InboundListenConfig) (io.Closer, error)) error {
		lc := newListenConfig(name, A.NewListenConfig(), options)
		value, err := create(lc)
		if err != nil {
			return errors.Join(err, lc.Close())
		}
		resource, ownErr := options.Observer.register(name, lc, value)
		if ownErr != nil {
			return errors.Join(ownErr, Close([]io.Closer{lc, value}))
		}
		result.Resources = append(result.Resources, resource)
		return nil
	}
	for _, entry := range []struct {
		name   string
		port   int
		create func(LC.AuthServer, C.InboundListenConfig, C.Tunnel) (io.Closer, error)
		udp    bool
	}{
		{"port", general.Port, func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return http.NewWithConfig(c, l, t)
		}, false},
		{"socks-port", general.SocksPort, func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return socks.NewWithConfig(c, l, t)
		}, true},
		{"mixed-port", general.MixedPort, func(c LC.AuthServer, l C.InboundListenConfig, t C.Tunnel) (io.Closer, error) {
			return mixed.NewWithConfig(c, l, t)
		}, true},
	} {
		if entry.port == 0 {
			continue
		}
		c := LC.AuthServer{Enable: true, Listen: address(entry.port), AuthStore: auth.Default}
		if err := construct(entry.name, func(l C.InboundListenConfig) (io.Closer, error) { return entry.create(c, l, traffic) }); err != nil {
			return err
		}
		if entry.udp {
			if err := construct(entry.name+" UDP", func(l C.InboundListenConfig) (io.Closer, error) { return socks.NewUDPWithConfig(c, l, traffic) }); err != nil {
				return err
			}
		}
	}
	if general.ShadowSocksConfig != "" {
		addr, cipher, password, err := shadowsocks.ParseSSURL(general.ShadowSocksConfig)
		if err != nil {
			return err
		}
		if err = construct("ss-config", func(l C.InboundListenConfig) (io.Closer, error) {
			return sing_shadowsocks.New(LC.ShadowsocksServer{Enable: true, Listen: addr, Cipher: cipher, Password: password, Udp: true}, l, traffic)
		}); err != nil {
			return err
		}
	}
	if general.VmessConfig != "" {
		addr, username, uuid, err := sing_vmess.ParseVmessURL(general.VmessConfig)
		if err != nil {
			return err
		}
		if err = construct("vmess-config", func(l C.InboundListenConfig) (io.Closer, error) {
			return sing_vmess.New(LC.VmessServer{Enable: true, Listen: addr, Users: []LC.VmessUser{{Username: username, UUID: uuid, AlterID: 1}}}, l, traffic)
		}); err != nil {
			return err
		}
	}
	if general.TuicServer.Enable {
		if err := construct("tuic-server", func(l C.InboundListenConfig) (io.Closer, error) { return tuic.New(general.TuicServer, l, traffic) }); err != nil {
			return err
		}
	}
	for index, forward := range cfg.Tunnels {
		for _, protocol := range forward.Network {
			if err := construct("tunnels."+strconv.Itoa(index)+"."+protocol, func(l C.InboundListenConfig) (io.Closer, error) {
				switch protocol {
				case "tcp":
					return LT.New(forward.Address, forward.Target, forward.Proxy, l, traffic)
				case "udp":
					return LT.NewUDP(forward.Address, forward.Target, forward.Proxy, l, traffic)
				default:
					return nil, fmt.Errorf("tunnels: unknown network %q", protocol)
				}
			}); err != nil {
				return err
			}
		}
	}
	if cfg.DNS.Enable && cfg.DNS.Listen != "" {
		_, port, err := net.SplitHostPort(cfg.DNS.Listen)
		if err != nil {
			return err
		}
		if port != "0" && port != "" {
			base := A.NewListenConfig()
			base.SetRouteMark(cfg.DNS.ListenRoutingMark)
			lc := newListenConfig("dns.listen", base, options)
			lc.bound = make(chan error, 2)
			result.Resources = append(result.Resources, lc)
			dns.ReCreateServer(cfg.DNS.Listen, lc, resolver.DefaultService)
			// Wait only for the public constructor's two bind/protect results, not for a Serve readiness acknowledgment.
			if resolver.DefaultService == nil {
				return errors.New("DNS service is disabled")
			}
			err = errors.Join(<-lc.bound, <-lc.bound)
			if err != nil {
				return err
			}
			owned, ownErr := options.Observer.register("dns.listen", lc)
			if ownErr != nil {
				return ownErr
			}
			result.Resources[len(result.Resources)-1] = owned
		}
	}
	return nil
}
