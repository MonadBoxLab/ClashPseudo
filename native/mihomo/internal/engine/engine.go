// Package engine在一个内核进程中装载一个mihomo上下文。
package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"slices"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/ntp/ntp"
	RP "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"clashpseudo/native/internal/androidnet"
	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreview"
	"clashpseudo/native/internal/ingress"
	"clashpseudo/native/internal/logstream"
)

var Version = "development"
var ErrStopped = errors.New("native session is not accepting sockets")

type socketOwner struct {
	id              uint64
	ctx             context.Context
	cancel          context.CancelFunc
	active          atomic.Bool
	protect         func(int) bool
	protectNetwork  func(int, string) bool
	protectSocket   func(int) error
	protectOutbound func(int, string) error
	network         string
	vpnIntent       bool
	accepted        atomic.Uint64
	refused         atomic.Uint64
}

var current atomic.Pointer[socketOwner]
var socketOwnerSequence atomic.Uint64

func newSocketOwner(protect func(int) bool, network func(int, string) bool) *socketOwner {
	ctx, cancel := context.WithCancel(context.Background())
	o := &socketOwner{id: socketOwnerSequence.Add(1), ctx: ctx, cancel: cancel, protect: protect, protectNetwork: network, vpnIntent: true}
	o.active.Store(true)
	return o
}
func (o *socketOwner) revoke() { o.active.Store(false); o.cancel() }
func (o *socketOwner) socket(fd int, outbound bool) error {
	if !o.active.Load() {
		return ErrStopped
	}
	if !outbound && !o.vpnIntent {
		return nil
	}
	var err error
	switch {
	case outbound && o.protectOutbound != nil:
		err = o.protectOutbound(fd, o.network)
	case !outbound && o.protectSocket != nil:
		err = o.protectSocket(fd)
	case outbound && o.protectNetwork != nil:
		if !o.protectNetwork(fd, o.network) {
			err = errors.New("Android network socket protection was refused")
		}
	case o.protect != nil:
		if !o.protect(fd) {
			err = errors.New("VpnService.protect refused socket")
		}
	default:
		err = errors.New("Android socket callback is unavailable")
	}
	if err != nil {
		o.refused.Add(1)
	} else if o.vpnIntent {
		o.accepted.Add(1)
	}
	return err
}
func init() {
	dialer.DefaultSocketHook = func(_, _ string, raw syscall.RawConn) error {
		o := current.Load()
		if o == nil || !o.active.Load() {
			return ErrStopped
		}
		var protectErr error
		err := raw.Control(func(fd uintptr) { protectErr = o.socket(int(fd), true) })
		return errors.Join(err, protectErr)
	}
}

type Engine struct {
	mu             sync.Mutex
	updateMu       sync.Mutex
	updates        sync.WaitGroup
	used           bool
	cancelled      atomic.Bool
	cancelOwner    atomic.Pointer[socketOwner]
	pathsHome      string
	cachePath      string
	provenance     *configinput.Provenance
	cfg            *config.Config
	tun            io.Closer
	owner          *socketOwner
	failed         bool
	stopError      error
	sources        coreview.DiagnosticSources
	logs           *logstream.Buffer
	geoPaths       [4]string
	spec           *androidnet.VPNSpec
	specError      error
	specChanged    func(uint64, bool)
	routeWatch     io.Closer
	ingress        []io.Closer
	listenerStates ingress.Observer
	options        PrepareOptions
	usesSystemDNS  bool
	attachedRoutes []netip.Prefix
	traffic        *trafficBaseline
	dnsOperation   atomic.Pointer[dnsOperation]
	networkEpoch   atomic.Uint64
	systemDNS      *androidnet.NetworkResolver
}

func (e *Engine) Prepare(home string, body []byte, mode string, protect func(int) bool, overrides ...configinput.Override) error {
	return e.PrepareWithOptions(home, body, mode, protect, PrepareOptions{Purpose: "PREVIEW"}, overrides...)
}
func (e *Engine) PrepareWithOptions(home string, body []byte, mode string, protect func(int) bool, options PrepareOptions, overrides ...configinput.Override) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.used || e.owner != nil || e.failed {
		return errors.New("a core process can load only one context")
	}
	e.used = true
	if protect == nil && options.ProtectSocket == nil {
		return errors.New("socket protector is required")
	}
	if options.Purpose != "PREVIEW" && options.Purpose != "RUNNING" {
		return errors.New("invalid preparation purpose")
	}
	if options.Purpose == "RUNNING" && (options.Generation <= 0 || options.Composition == "") {
		return errors.New("running preparation identity is required")
	}
	if e.logs == nil {
		e.logs = logstream.NewBuffer()
	}
	body, provenance, err := configinput.ComposeWithProvenance(body, overrides, options.MainOrigin)
	if err != nil {
		return err
	}
	raw, presence, err := configinput.Decode(body, mode, options.RoutingOverride, options.VPNIntent)
	if err != nil {
		return err
	}
	if options.VPNIntent {
		if err = androidnet.PlatformRuntime(raw, presence); err != nil {
			return err
		}
	}
	owner := newSocketOwner(protect, options.ProtectNetwork)
	owner.vpnIntent = options.VPNIntent
	owner.protectSocket, owner.protectOutbound, owner.network = options.ProtectSocket, options.ProtectOutbound, options.Network.ID
	if !current.CompareAndSwap(nil, owner) {
		owner.revoke()
		return errors.New("another native session exists")
	}
	e.owner = owner
	e.cancelOwner.Store(owner)
	if e.cancelled.Load() {
		owner.revoke()
		return errors.Join(ErrStopped, e.stopLocked())
	}
	if err = e.capturePathsLocked(home); err != nil {
		return errors.Join(err, e.stopLocked())
	}
	C.Version = Version
	options.Network.Servers = slices.Clone(options.Network.Servers)
	e.options = options
	// 所有解析与provider启动之前安装一次捕获的系统解析和显式system服务器。
	e.systemDNS = androidnet.NewNetworkResolver(options.Network, androidnet.DNSOwner{ID: owner.id, Revoked: owner.ctx, Stopped: ErrStopped, RawQuery: options.SystemDNSQuery, Lookup: options.SystemLookup})
	resolver.SystemResolver = e.systemDNS
	if err = initializeSystemDNS(options.Network); err != nil {
		return errors.Join(err, e.stopLocked())
	}
	if options.SeedGeo != nil {
		seeds, seedErr := geoSeeds(e.geoPaths, presence)
		if seedErr == nil && len(seeds) > 0 {
			seedErr = options.SeedGeo(seeds)
		}
		if seedErr != nil {
			return errors.Join(seedErr, e.stopLocked())
		}
	}
	if !owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	requested6 := slices.Clone(raw.Tun.Inet6Address)
	requestedFake6 := raw.DNS.FakeIPRange6
	cfg, err := config.ParseRawConfig(raw)
	e.cfg = cfg
	if err != nil {
		return errors.Join(err, e.stopLocked())
	}
	if presence.Has("tun.inet6-address") && len(requested6) > 0 && !slices.Equal(requested6, cfg.General.Tun.Inet6Address) {
		return errors.Join(&androidnet.PlatformError{Field: "tun.inet6-address", Reason: "ipv6Unavailable"}, e.stopLocked())
	}
	if presence.Has("dns.fake-ip-range6") && requestedFake6 != "" && !cfg.DNS.FakeIPRange6.IsValid() {
		return errors.Join(&androidnet.PlatformError{Field: "dns.fake-ip-range6", Reason: "ipv6Unavailable"}, e.stopLocked())
	}
	e.usesSystemDNS, err = androidnet.CheckSystemDNS(cfg.DNS, options.Network)
	if err != nil {
		return errors.Join(err, e.stopLocked())
	}
	e.provenance = provenance
	var diagnosticErr error
	e.sources, diagnosticErr = coreview.ReadDiagnosticSources(body, raw)
	if diagnosticErr != nil {
		log.Warnln("配置来源信息读取失败: %v", diagnosticErr)
	}
	if options.Purpose == "RUNNING" {
		up, down := statistic.DefaultManager.Total()
		e.traffic = &trafficBaseline{upload: up, download: down}
	}
	work := workingConfig(cfg, options.Purpose == "PREVIEW")
	if options.Purpose == "RUNNING" {
		if err = ingress.PrepareNamed(work, ingress.Options{Protect: func(fd int) error { return owner.socket(fd, false) }, Observer: &e.listenerStates}); err != nil {
			return errors.Join(err, e.stopLocked())
		}
	}
	// hub同时装载Controller和executor；不再重复Apply或provider.Initial。
	hub.ApplyConfig(work)
	if err = e.listenerStates.Errors(); err != nil {
		return errors.Join(err, e.stopLocked())
	}
	if cfg.General.GeoAutoUpdate {
		updater.RegisterGeoUpdater()
	}
	if options.VPNIntent {
		e.spec, err = makeVPNSpec(cfg, presence, options)
		if err != nil {
			return errors.Join(err, e.stopLocked())
		}
		e.spec.UsesSystemDNS = e.spec.UsesSystemDNS || e.usesSystemDNS
		e.specChanged = options.SpecificationChanged
		e.routeWatch = e.watchRouteSets()
	}
	if options.Purpose == "RUNNING" {
		if err = e.activateIngress(); err != nil {
			return errors.Join(err, e.stopLocked())
		}
	}
	if !owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	return nil
}

func (e *Engine) Cancel() {
	e.cancelled.Store(true)
	e.CancelDNSQuery()
	if owner := e.cancelOwner.Load(); owner != nil {
		owner.revoke()
	}
}
func (e *Engine) Stop() error {
	e.Cancel()
	e.mu.Lock()
	err := e.suspendLocked()
	e.mu.Unlock()
	e.updates.Wait()
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.finishStopLocked(err)
}
func (e *Engine) stopLocked() error {
	if e.owner != nil {
		e.owner.revoke()
	}
	return e.finishStopLocked(e.suspendLocked())
}
func (e *Engine) suspendLocked() error {
	if e.owner == nil {
		return nil
	}
	tunnel.OnSuspend()
	route.ReCreateServer(&route.Config{})
	var errs []error
	if e.routeWatch != nil {
		errs = append(errs, e.routeWatch.Close())
		e.routeWatch = nil
	}
	errs = append(errs, e.listenerStates.CloseAll())
	e.ingress = nil
	if e.tun != nil {
		errs = append(errs, e.tun.Close())
		e.tun = nil
	}
	listener.PatchInboundListeners(nil, tunnel.Tunnel, true)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	ntp.ReCreateNTPService("", 0, "", nil, false)
	if e.cfg != nil {
		for _, p := range e.cfg.Providers {
			errs = append(errs, closeResource(p))
		}
		for _, p := range e.cfg.RuleProviders {
			errs = append(errs, closeResource(p))
		}
	}
	return errors.Join(errs...)
}
func (e *Engine) finishStopLocked(suspendErr error) error {
	e.sources = coreview.DiagnosticSources{}
	e.provenance = nil
	e.spec, e.specError, e.specChanged = nil, nil, nil
	e.attachedRoutes = nil
	e.traffic = nil
	if e.logs != nil {
		defer e.logs.Close()
	}
	errs := []error{suspendErr}
	if e.cfg != nil {
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			if err := c.Close(); err != nil && !errors.Is(err, net.ErrClosed) {
				errs = append(errs, err)
			}
			return true
		})
		for _, p := range e.cfg.Providers {
			for _, proxy := range p.Proxies() {
				errs = append(errs, proxy.Close())
			}
		}
		for _, p := range e.cfg.Proxies {
			errs = append(errs, p.Close())
		}
		dns.ReCreateServer("", nil, nil)
		resolver.StoreFakePoolState()
		resolver.DefaultResolver = nil
		resolver.DefaultHostMapper = nil
		resolver.DefaultService = nil
		resolver.ProxyServerHostResolver = nil
		resolver.DirectHostResolver = nil
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		e.cfg = nil
	}
	if e.owner != nil {
		e.owner.revoke()
		current.CompareAndSwap(e.owner, nil)
		e.owner = nil
	}
	err := errors.Join(errs...)
	if err != nil {
		e.failed = true
		e.stopError = errors.Join(e.stopError, err)
	}
	return e.stopError
}
func closeResource(value any) error {
	if _, ok := value.(*RP.InlineProvider); ok {
		return nil
	}
	closer, ok := value.(io.Closer)
	if !ok {
		return fmt.Errorf("resource %T has no explicit close operation", value)
	}
	return closer.Close()
}
func (e *Engine) Snapshot() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	var protected, refused uint64
	if e.owner != nil {
		protected = e.owner.accepted.Load()
		refused = e.owner.refused.Load()
	}
	up, down := statistic.DefaultManager.Total()
	var sessionUp, sessionDown *int64
	if e.available() && e.traffic != nil {
		sessionUp, sessionDown = e.traffic.totals(up, down)
	}
	data, _ := json.Marshal(map[string]any{"version": Version, "prepared": e.cfg != nil, "attached": e.tun != nil, "cleanupFailed": e.failed, "protected": protected, "refused": refused, "uploadTotal": up, "downloadTotal": down, "sessionUploadBytes": sessionUp, "sessionDownloadBytes": sessionDown, "listeners": e.listenerStates.Snapshot()})
	return string(data)
}
