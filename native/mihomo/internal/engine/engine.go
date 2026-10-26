// Package engine owns one embedded mihomo session. Calls that mutate it are serialized.
package engine

import (
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
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/ntp/ntp"
	RP "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"

	"clashpseudo/native/internal/configinput"
)

// Android builds inject the version resolved from go.mod.
var Version = "development"

var ErrStopped = errors.New("native session is not accepting sockets")

type socketOwner struct {
	active         atomic.Bool
	protect        func(int) bool
	protectNetwork func(int, string) bool
	accepted       atomic.Uint64
	refused        atomic.Uint64
}

var current atomic.Pointer[socketOwner]

func init() {
	// Keep the concurrent dialer hook stable and switch its owner atomically.
	dialer.DefaultSocketHook = func(_, _ string, raw syscall.RawConn) error {
		owner := current.Load()
		if owner == nil || !owner.active.Load() {
			return ErrStopped
		}
		var protectErr error
		err := raw.Control(func(fd uintptr) {
			if !owner.active.Load() || !owner.protect(int(fd)) {
				owner.refused.Add(1)
				protectErr = errors.New("VpnService.protect refused socket")
				return
			}
			owner.accepted.Add(1)
		})
		return errors.Join(err, protectErr)
	}
}

type Engine struct {
	mu             sync.Mutex
	geoMu          sync.Mutex
	updateMu       sync.Mutex
	updates        sync.WaitGroup
	provenance     *configinput.Provenance
	cfg            *config.Config
	tun            io.Closer
	owner          *socketOwner
	failed         bool
	unrestored     []UnrestoredChoice
	ruleSources    map[string]ruleSource
	sources        diagnosticSources
	logs           *logBuffer
	delays         map[string]*delayBatch
	delaySeq       int
	geo            *geoUpdater
	geoPaths       [4]string
	geoResults     map[string]geoUpdateState
	spec           *VPNSpec
	specError      error
	specChanged    func(uint64, bool)
	routeWatch     io.Closer
	ingress        []io.Closer
	options        PrepareOptions
	usesSystemDNS  bool
	attachedRoutes []netip.Prefix
	traffic        *trafficBaseline
	dnsOperation   atomic.Pointer[dnsOperation]
	cancelledDNS   atomic.Uint64
	networkEpoch   atomic.Uint64
}

func (e *Engine) Prepare(home string, body []byte, mode string, choices map[string]Choice, protect func(int) bool, overrides ...configinput.Override) error {
	return e.PrepareWithOptions(home, body, mode, choices, protect, PrepareOptions{Purpose: "PREVIEW"}, overrides...)
}

func (e *Engine) PrepareWithOptions(home string, body []byte, mode string, choices map[string]Choice, protect func(int) bool, options PrepareOptions, overrides ...configinput.Override) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.owner != nil || e.failed {
		return errors.New("native session is busy or cleanup is unconfirmed")
	}
	if protect == nil {
		return errors.New("socket protector is required")
	}
	for name, choice := range choices {
		if name == "" || !choice.valid() {
			return errors.New("invalid strategy choices")
		}
	}
	if options.Purpose != "VPN" && options.Purpose != "PREVIEW" {
		return errors.New("invalid preparation purpose")
	}
	if mode != "" {
		if _, err := configinput.ParseMode(mode); err != nil {
			return err
		}
	}
	if options.Purpose == "VPN" && (options.Generation <= 0 || options.Composition == "") {
		return errors.New("VPN preparation identity is required")
	}
	// Subscribe before parsing; closing a subscription retains this single
	// bounded window until another real preparation replaces it.
	if e.logs != nil {
		e.logs.close()
	}
	buffer := newLogBuffer()
	e.logs = buffer
	fail := func(err error) error {
		buffer.close()
		return err
	}
	var err error
	var provenance *configinput.Provenance
	body, provenance, err = configinput.ComposeWithProvenance(body, overrides, options.MainOrigin)
	if err != nil {
		return fail(err)
	}
	body, presence, err := configinput.RunningDefaults(body, mode, options.RoutingOverride)
	if err != nil {
		return fail(err)
	}
	raw, err := config.UnmarshalRawConfig(body)
	if err != nil {
		return fail(err)
	}
	sources, err := readRuleSources(raw)
	if err != nil {
		return fail(err)
	}
	metadata, err := readDiagnosticSources(body, raw)
	if err != nil {
		return fail(err)
	}
	if options.Purpose == "VPN" {
		if err := platformRuntime(raw, presence); err != nil {
			return fail(err)
		}
	}
	// Android handles system integration while Geo refresh follows user configuration.
	geoAuto, geoHours := raw.GeoAutoUpdate, raw.GeoUpdateInterval
	if err = configurePlatform(raw, home); err != nil {
		return fail(err)
	}
	owner := &socketOwner{protect: protect, protectNetwork: options.ProtectNetwork}
	owner.active.Store(true)
	if !current.CompareAndSwap(nil, owner) {
		return fail(errors.New("another native session exists"))
	}
	e.owner = owner
	C.SetHomeDir(home)
	C.Version = Version
	// Public Geo path getters also write global database names. Capture them
	// before parsing can start providers and before any session consumers run.
	e.geoPaths = geoFiles()
	e.options = options
	systemDNS.update(options.Network)
	if options.SeedGeo != nil {
		seeds, err := geoSeeds(e.geoPaths, presence)
		if err == nil && len(seeds) > 0 {
			err = options.SeedGeo(seeds)
		}
		if err != nil {
			return errors.Join(err, e.stopLocked())
		}
	}
	if !owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	requested6 := append([]netip.Prefix(nil), raw.Tun.Inet6Address...)
	requestedFake6 := raw.DNS.FakeIPRange6
	parseRaw := raw
	disabledFakeIP := !raw.DNS.Enable && raw.DNS.EnhancedMode == C.DNSFakeIP
	if disabledFakeIP {
		// The fixed public parser otherwise allocates/restores persistent fake
		// pools even with Enable=false. Suppress only that inactive allocation
		// branch; keep the original composed values and restore its mode below.
		copy := *raw
		copy.DNS.EnhancedMode = C.DNSMapping
		parseRaw = &copy
	}
	cfg, err := config.ParseRawConfig(parseRaw)
	if err != nil {
		// Parse failure may leave upstream allocations outside returned ownership; retain
		// the uncertain cleanup state.
		e.failed = true
		e.geoPaths = [4]string{}
		buffer.close()
		owner.active.Store(false)
		current.CompareAndSwap(owner, nil)
		e.owner = nil
		return err
	}
	e.cfg = cfg
	if disabledFakeIP {
		cfg.DNS.EnhancedMode = raw.DNS.EnhancedMode
	}
	if presence.Has("tun.inet6-address") && len(requested6) > 0 && !slices.Equal(requested6, cfg.General.Tun.Inet6Address) {
		return errors.Join(&PlatformError{Field: "tun.inet6-address", Reason: "ipv6Unavailable"}, e.stopLocked())
	}
	if presence.Has("dns.fake-ip-range6") && requestedFake6 != "" && !cfg.DNS.FakeIPRange6.IsValid() {
		return errors.Join(&PlatformError{Field: "dns.fake-ip-range6", Reason: "ipv6Unavailable"}, e.stopLocked())
	}
	usedSystem, err := expandSystemDNS(cfg.DNS, options.Network)
	e.usesSystemDNS = usedSystem
	if err != nil {
		return errors.Join(err, e.stopLocked())
	}
	e.ruleSources = sources
	if options.Purpose == "VPN" {
		if err := platformParsed(cfg); err != nil {
			return errors.Join(err, e.stopLocked())
		}
	}
	e.sources = metadata
	e.provenance = provenance
	e.geoResults = nil
	e.delays = make(map[string]*delayBatch)
	if options.Purpose == "VPN" {
		up, down := statistic.DefaultManager.Total()
		e.traffic = &trafficBaseline{upload: up, download: down}
	}
	executor.ApplyConfig(resourceConfig(cfg), true)
	if options.Purpose == "VPN" {
		if err := platformParsed(cfg); err != nil {
			return errors.Join(err, e.stopLocked())
		}
	}

	if options.Purpose == "VPN" {
		e.spec, err = makeVPNSpec(cfg, presence, options, usedSystem)
		if err != nil {
			return errors.Join(err, e.stopLocked())
		}
		e.specChanged = options.SpecificationChanged
		e.routeWatch = e.watchRouteSets()
	}
	e.restoreCoreCache()
	if !owner.active.Load() {
		return errors.Join(ErrStopped, e.stopLocked())
	}
	e.restoreChoices(choices)
	e.startGeo(geoAuto, geoHours)
	return nil
}

// Cancel revokes preparation authority immediately. Stop must then complete before the
// next start.
func (e *Engine) Cancel() {
	e.CancelDNSQuery()
	if owner := current.Load(); owner != nil {
		owner.active.Store(false)
		if snapshot := systemDNS.value.Load(); snapshot != nil && snapshot.owner == owner {
			snapshot.cancel()
		}
	}
}

func (e *Engine) Stop() error {
	e.Cancel()
	// Retain ownership through every accepted update's actual return.
	e.geoMu.Lock()
	defer e.geoMu.Unlock()
	e.mu.Lock()
	geo := e.takeGeo()
	if geo != nil {
		geo.cancelUpdates()
	}
	// Close TUN and cancel provider requests before waiting for outstanding I/O,
	// including Geo writes.
	err := e.suspendLocked()
	e.mu.Unlock()
	if geo != nil {
		geo.stop()
	}
	e.updates.Wait()
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.finishStopLocked(err)
}

func (e *Engine) stopLocked() error {
	return e.finishStopLocked(e.suspendLocked())
}

func (e *Engine) suspendLocked() error {
	tunnel.OnSuspend()
	var errs []error
	if e.routeWatch != nil {
		errs = append(errs, e.routeWatch.Close())
		e.routeWatch = nil
	}
	for i := len(e.ingress) - 1; i >= 0; i-- {
		errs = append(errs, e.ingress[i].Close())
	}
	e.ingress = nil
	if e.options.Purpose == "VPN" {
		ntp.ReCreateNTPService("", 0, "", nil, false)
	}
	if e.tun != nil {
		errs = append(errs, e.tun.Close())
		e.tun = nil
	}
	if e.cfg != nil {
		// Provider Close signals background cancellation; goroutine completion has its own
		// lifetime.
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
	e.unrestored = nil
	e.ruleSources = nil
	e.sources = diagnosticSources{}
	e.provenance = nil
	e.geoPaths = [4]string{}
	e.geoResults = nil
	e.spec, e.specError, e.specChanged = nil, nil, nil
	e.options = PrepareOptions{}
	e.usesSystemDNS = false
	e.attachedRoutes = nil
	e.traffic = nil
	e.stopDelays()
	if e.logs != nil {
		// Capture cleanup events, then unsubscribe while retaining the current/recent
		// window.
		defer e.logs.close()
	}
	errs := []error{suspendErr}
	if e.cfg != nil {
		statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
			err := c.Close()
			if err != nil && !errors.Is(err, net.ErrClosed) {
				errs = append(errs, err)
			}
			return true
		})
		// Close provider refresh/health checks and parsed nodes separately. Shared nodes use
		// upstream's once-only Close wrapper; background tasks retain their own completion
		// lifetime.
		for _, provider := range e.cfg.Providers {
			for _, p := range provider.Proxies() {
				errs = append(errs, p.Close())
			}
		}
		for _, p := range e.cfg.Proxies {
			errs = append(errs, p.Close())
		}
		dns.ReCreateServer("", nil, nil)
		resolver.ResetConnection()
		resolver.StoreFakePoolState()
		resolver.DefaultResolver = nil
		resolver.DefaultHostMapper = nil
		resolver.DefaultService = nil
		resolver.ProxyServerHostResolver = nil
		resolver.DirectHostResolver = nil
		// Release session-owned state while retaining mihomo's process-wide runtime.
		tunnel.UpdateProxies(nil, nil)
		tunnel.UpdateRules(nil, nil, nil)
		e.cfg = nil
	}
	if e.owner != nil {
		current.CompareAndSwap(e.owner, nil)
		e.owner = nil
	}
	err := errors.Join(errs...)
	if e.failed && err == nil {
		err = errors.New("previous native cleanup is still unconfirmed")
	}
	if err != nil {
		e.failed = true
	}
	return err
}

func closeResource(value any) error {
	// The selected inline rule provider owns immutable rules and has an empty Initial
	// operation.
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
	upload, download := statistic.DefaultManager.Total()
	var sessionUpload, sessionDownload *int64
	if e.available() && e.tun != nil {
		sessionUpload, sessionDownload = e.traffic.totals(upload, download)
	}
	data, _ := json.Marshal(struct {
		Version         string `json:"version"`
		Prepared        bool   `json:"prepared"`
		Attached        bool   `json:"attached"`
		CleanupFailed   bool   `json:"cleanupFailed"`
		Protected       uint64 `json:"protected"`
		Refused         uint64 `json:"refused"`
		UploadTotal     int64  `json:"uploadTotal"`
		DownloadTotal   int64  `json:"downloadTotal"`
		SessionUpload   *int64 `json:"sessionUploadBytes"`
		SessionDownload *int64 `json:"sessionDownloadBytes"`
	}{Version, e.cfg != nil, e.tun != nil, e.failed, protected, refused, upload, download, sessionUpload, sessionDownload})
	return string(data)
}
