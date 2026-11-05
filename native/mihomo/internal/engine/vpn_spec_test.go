package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"

	"clashpseudo/native/internal/androidnet"
	"clashpseudo/native/internal/configinput"
)

func prepareWithVPNOptions(t *testing.T, e *Engine, home, body string, options PrepareOptions) {
	t.Helper()
	options.Purpose, options.VPNIntent = "RUNNING", true
	if options.Generation == 0 {
		options.Generation = 17
	}
	if options.Composition == "" {
		options.Composition = "same-composed-input"
	}
	if err := e.PrepareWithOptions(home, []byte(body), "", func(int) bool { return true }, options); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, e) })
}

func TestVPNSpecUsesSameParsedMTUAddressRoutesAndIdentity(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), `ipv6: false
dns: {fake-ip-range: 10.55.0.1/16}
tun:
  mtu: 1420
  route-address: [10.0.0.0/8, 192.0.2.0/24]
  inet4-route-address: [203.0.113.0/24]
  route-exclude-address: [10.1.0.0/16]
  include-package: []
rules: ["MATCH,DIRECT"]
`, PrepareOptions{Generation: 41, Composition: "generation-and-composition"})
	var spec androidnet.VPNSpec
	if err := json.Unmarshal([]byte(e.VPNSpec()), &spec); err != nil {
		t.Fatal(err)
	}
	if spec.Generation != 41 || spec.Composition != "generation-and-composition" || spec.MTU != e.cfg.General.Tun.MTU || spec.MTU != 1420 || !slices.Equal(spec.Addresses, e.cfg.General.Tun.Inet4Address) {
		t.Fatalf("spec was not derived from this parsed configuration: %+v", spec)
	}
	if spec.Addresses[0].String() != "10.55.0.1/30" {
		t.Fatal("parseTun interface address was masked or replaced", spec.Addresses)
	}
	if !spec.Filter.Configured || len(spec.Filter.IncludePackage) != 0 {
		t.Fatal("explicit empty application layer was lost")
	}
	contains := func(address string) bool {
		addr := netip.MustParseAddr(address)
		for _, prefix := range spec.Routes {
			if prefix.Contains(addr) {
				return true
			}
		}
		return false
	}
	if contains("10.1.1.1") || !contains("10.2.1.1") || !contains("203.0.113.7") || contains("8.8.8.8") {
		t.Fatal("static route subtraction/legacy aliases were not projected", spec.Routes)
	}
	if !slices.Equal(spec.DNSServers, []string{"10.55.0.2"}) {
		t.Fatal("announced DNS is not the effective reachable hijack target", spec.DNSServers)
	}
	if executorCopy := workingConfig(e.cfg, true); executorCopy.General.Tun.Enable || !e.cfg.General.Tun.Enable || executorCopy.General.Tun.MTU != spec.MTU {
		t.Fatal("resource copy replaced the actual TUN configuration")
	}
	requireStop(t, &e)
	if e.VPNSpec() != `{"error":"VPN specification is unavailable"}` {
		t.Fatal("released spec survived its generation")
	}
}

func TestAutoRouteFalseNeverAddsDefaultRoutes(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), "ipv6: false\ntun: {auto-route: false}\nrules: [\"MATCH,DIRECT\"]\n", PrepareOptions{Network: androidnet.NetworkDNS{ID: "underlying", Servers: []string{"192.0.2.53"}}})
	if len(e.spec.Routes) != 0 {
		t.Fatal("auto-route=false gained a default route", e.spec.Routes)
	}
	if !slices.Equal(e.spec.DNSServers, []string{"192.0.2.53"}) {
		t.Fatal("unreachable virtual DNS was announced", e.spec.DNSServers)
	}
}

func TestDNSDisableAndExplicitEmptyHijackAreRealCapabilities(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, tc := range []struct {
		name, dns, tun, purpose string
		enabled                 bool
	}{
		{"disabled-preview", "enable: false, enhanced-mode: fake-ip", "dns-hijack: []", "PREVIEW", false},
		{"disabled-running", "enable: false, enhanced-mode: fake-ip", "", "RUNNING", false},
		{"empty-hijack", "enable: true", "dns-hijack: []", "RUNNING", true},
		{"explicit-conflict", "enable: false", "dns-hijack: ['any:53']", "RUNNING", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			body := "ipv6: false\ndns: {" + tc.dns + "}\ntun: {" + tc.tun + "}\nrules: ['MATCH,DIRECT']\n"
			if tc.purpose == "RUNNING" && !tc.enabled {
				err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 1, Composition: "disabled"})
				var limit *androidnet.PlatformError
				if !errors.As(err, &limit) || limit.Reason != "dnsHijackConflict" || e.cfg != nil || e.owner != nil || e.failed {
					t.Fatalf("DNS关闭与公开TUN邻接DNS冲突未返回实际能力错误: %v", err)
				}
				return
			}
			if tc.enabled {
				prepareWithVPNOptions(t, &e, t.TempDir(), body, PrepareOptions{Network: androidnet.NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53", "2001:db8::53"}}})
			} else {
				if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
			}
			if e.cfg.DNS.Enable != tc.enabled || (resolver.DefaultService != nil) != tc.enabled {
				t.Fatal("DNS enable did not control the internal service")
			}
			if !tc.enabled {
				if e.cfg.DNS.EnhancedMode != C.DNSFakeIP || e.cfg.DNS.FakeIPPool == nil {
					t.Fatal("disabled DNS did not reach the public parser with its original fake-IP mode")
				}
				if resolver.DefaultHostMapper != nil || resolver.DefaultResolver != nil {
					t.Fatal("disabled DNS started a resolver")
				}
			}
			if len(e.cfg.General.Tun.DNSHijack) != 0 {
				t.Fatal("an empty/missing disabled hijack was replaced")
			}
			if tc.enabled && !slices.Equal(e.spec.DNSServers, []string{"198.18.0.2"}) {
				t.Fatal("Builder未投影公开TUN实际使用的邻接DNS", e.spec.DNSServers)
			}
		})
	}
}

func TestExplicitIPv6LossIsReportedRatherThanSilentlyCleared(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, extra := range []string{"tun: {inet6-address: ['fd00::1/126']}", "dns: {fake-ip-range6: 'fd00::1/64'}",
		"tun: {route-address: ['fd00::/64']}"} {
		t.Run(extra, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}

			var e Engine
			err := e.PrepareWithOptions(t.TempDir(), []byte("ipv6: false\n"+extra+"\nrules: [\"MATCH,DIRECT\"]\n"), "", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 1, Composition: "ipv6"})
			var limit *androidnet.PlatformError
			if !errors.As(err, &limit) || limit.Reason != "ipv6Unavailable" {
				t.Fatalf("explicit IPv6 request disappeared without its real limitation: %v", err)
			}
			requireStop(t, &e)
		})
	}
}

func TestVPNSpecRejectsInvalidEffectiveMTUAndParseTunNextAddress(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, body := range []string{"tun: {mtu: 65536}\n", "dns: {fake-ip-range: 10.55.0.3/16}\n"} {
		t.Run(body, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}

			var e Engine
			err := e.PrepareWithOptions(t.TempDir(), []byte("ipv6: false\n"+body), "", func(int) bool { return true }, PrepareOptions{Purpose: "RUNNING", VPNIntent: true, Generation: 1, Composition: "invalid"})
			var limit *androidnet.PlatformError
			if !errors.As(err, &limit) || (limit.Reason != "invalidMtu" && limit.Reason != "invalidAddress") {
				t.Fatalf("invalid effective interface accepted: %v", err)
			}
			requireStop(t, &e)
		})
	}
}

func TestVPNSpecProjectsPublicZeroMTUAs9000(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), "ipv6: false\ntun: {mtu: 0}\nrules: ['MATCH,DIRECT']\n", PrepareOptions{})
	if e.cfg.General.Tun.MTU != 0 || e.spec.MTU != 9000 {
		t.Fatal("显式MTU0未保留或Builder与公开TUN默认值不一致", e.cfg.General.Tun.MTU, e.spec.MTU)
	}
}

func TestGeoSeedEligibilityUsesComposedPerKeyPresenceAndSelectedPaths(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "existing.mmdb"), []byte("existing user bytes"), 0600); err != nil {
		t.Fatal(err)
	}
	paths := [4]string{filepath.Join(home, "GeoIP.dat"), filepath.Join(home, "existing.mmdb"), filepath.Join(home, "ASN.mmdb"), filepath.Join(home, "GeoSite.dat")}
	composed, err := configinput.Compose([]byte("geox-url: {geoip: ''}\n"), []configinput.Override{{ID: "sources", Revision: 1, Mode: "replace", Body: "geox-url: {asn: null}\n"}})
	if err != nil {
		t.Fatal(err)
	}
	_, presence, err := configinput.Decode(composed, "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	requests, err := geoSeeds(paths, presence)
	if err != nil {
		t.Fatal(err)
	}
	if len(requests) != 1 || requests[0].Kind != "geosite" || requests[0].TargetName != "GeoSite.dat" {
		t.Fatalf("existing/explicit empty/null sources were replaced: %+v", requests)
	}
	var e Engine
	called := false
	err = e.PrepareWithOptions(home, []byte("rules: [\"MATCH,DIRECT\"]\n"), "", func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", SeedGeo: func(request []GeoSeed) error {
		called = true
		if e.cfg != nil || e.owner == nil || C.Path.HomeDir() != home {
			t.Fatal("Geo callback did not precede ParseRawConfig under this owner/home")
		}
		for _, item := range request {
			if filepath.Base(item.TargetName) != item.TargetName {
				t.Fatal("unbounded seed target")
			}
		}
		e.Cancel()
		return nil
	}})
	if !called || !errors.Is(err, ErrStopped) || e.cfg != nil || e.owner != nil || e.failed {
		t.Fatalf("cancelled Geo seed continued into parsing: called=%v err=%v", called, err)
	}
}

func TestRouteSetRealUpdatesOnlyRefreshChangedEffectiveRoutesAndInvalidateRevert(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var contents atomic.Value
	contents.Store("10.0.0.0/8\n")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = fmt.Fprint(w, contents.Load().(string)) }))
	defer server.Close()
	type event struct {
		revision uint64
		needed   bool
	}
	events := make(chan event, 8)
	var e Engine
	body := fmt.Sprintf(`ipv6: false
tun: {route-address: [198.18.0.0/16], route-address-set: [routes]}
rule-providers:
  routes: {type: http, behavior: ipcidr, format: text, url: '%s', interval: 0}
rules: ["MATCH,DIRECT"]
`, server.URL)
	prepareWithVPNOptions(t, &e, t.TempDir(), body, PrepareOptions{SpecificationChanged: func(revision uint64, needed bool) { events <- event{revision, needed} }})
	e.mu.Lock()
	e.tun = &countedCloser{}
	e.attachedRoutes = slices.Clone(e.spec.Routes)
	e.mu.Unlock()
	provider := e.cfg.RuleProviders["routes"]
	if err := provider.Update(); err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-events:
		t.Fatalf("identical effective route set refreshed: %+v", update)
	case <-time.After(30 * time.Millisecond):
	}
	contents.Store("10.1.0.0/16\n")
	if err := provider.Update(); err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-events:
		if update.revision != 2 || !update.needed {
			t.Fatal(update)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("real route provider update did not request a refresh")
	}
	contents.Store("10.0.0.0/8\n")
	if err := provider.Update(); err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-events:
		if update.revision != 3 || update.needed {
			t.Fatalf("reverted route set left a stale refresh pending: %+v", update)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("route revert did not invalidate its previous revision")
	}
	contents.Store("fd00::/64\n")
	if err := provider.Update(); err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-events:
		if update.revision != 4 || !update.needed {
			t.Fatal(update)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("unsupported IPv6 route update was not surfaced")
	}
	e.mu.Lock()
	var familyError *androidnet.PlatformError
	if !errors.As(e.specError, &familyError) || familyError.Field != "tun.route-address" || familyError.Reason != "ipv6Unavailable" {
		t.Errorf("route set advertised an uncaptured address family: %v", e.specError)
	}
	e.mu.Unlock()
	// An identical effective error retains the existing revision.
	tunnel.Tunnel.RuleUpdateCallback().Emit(provider)
	select {
	case update := <-events:
		t.Fatalf("identical route-family failure refreshed again: %+v", update)
	case <-time.After(30 * time.Millisecond):
	}
	contents.Store("10.0.0.0/8\n")
	if err := provider.Update(); err != nil {
		t.Fatal(err)
	}
	select {
	case update := <-events:
		if update.revision != 5 || update.needed {
			t.Fatalf("return to attached routes did not clear error refresh: %+v", update)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("valid route-family recovery was not surfaced")
	}
	requireStop(t, &e)
	tunnel.Tunnel.RuleUpdateCallback().Emit(provider)
	select {
	case update := <-events:
		t.Fatalf("released owner accepted a late route update: %+v", update)
	case <-time.After(30 * time.Millisecond):
	}
}

func TestRoutePublicationKeepsWholeValidCandidateAndRecoversDNS(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, withNetwork := range []bool{false, true} {
		t.Run(fmt.Sprint(withNetwork), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var contents atomic.Value
			contents.Store("203.0.113.0/24\n")
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = fmt.Fprint(w, contents.Load().(string))
			}))
			defer server.Close()
			type event struct {
				revision uint64
				needed   bool
			}
			events := make(chan event, 8)
			options := PrepareOptions{SpecificationChanged: func(revision uint64, needed bool) {
				events <- event{revision, needed}
			}}
			if withNetwork {
				options.Network = androidnet.NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53"}}
			}
			var e Engine
			body := fmt.Sprintf(`ipv6: false
tun: {dns-hijack: ['203.0.113.53:53'], route-address-set: [routes]}
rule-providers:
  routes: {type: http, behavior: ipcidr, format: text, url: '%s', interval: 0}
rules: ["MATCH,DIRECT"]
`, server.URL)
			prepareWithVPNOptions(t, &e, t.TempDir(), body, options)
			e.mu.Lock()
			original := *e.spec
			e.tun = &countedCloser{}
			e.attachedRoutes = slices.Clone(e.spec.Routes)
			e.mu.Unlock()
			provider := e.cfg.RuleProviders["routes"]
			update := func(text string, revision uint64, needed bool) {
				t.Helper()
				contents.Store(text)
				if err := provider.Update(); err != nil {
					t.Fatal(err)
				}
				select {
				case actual := <-events:
					if actual != (event{revision, needed}) {
						t.Fatalf("wrong production callback: %+v", actual)
					}
				case <-time.After(2 * time.Second):
					t.Fatal("missing production route callback")
				}
			}
			update("192.0.2.0/24\n", 2, true)
			e.mu.Lock()
			candidate, failure := *e.spec, e.specError
			e.mu.Unlock()
			if withNetwork {
				if failure != nil || !candidate.UsesSystemDNS ||
					!slices.Equal(candidate.DNSServers, []string{"192.0.2.53"}) ||
					!slices.Equal(candidate.Routes, []netip.Prefix{netip.MustParsePrefix("192.0.2.0/24")}) {
					t.Fatalf("route/DNS dependency was not published together: %+v err=%v", candidate, failure)
				}
			} else if failure == nil || !slices.Equal(candidate.Routes, original.Routes) ||
				!slices.Equal(candidate.DNSServers, original.DNSServers) || candidate.UsesSystemDNS != original.UsesSystemDNS {
				t.Fatal("failed DNS projection partially published a candidate", candidate, failure)
			}
			tunnel.Tunnel.RuleUpdateCallback().Emit(provider)
			select {
			case actual := <-events:
				t.Fatal("unchanged candidate/error created a second revision", actual)
			case <-time.After(30 * time.Millisecond):
			}
			update("203.0.113.0/24\n", 3, false)
			e.mu.Lock()
			recovered, failure := *e.spec, e.specError
			e.mu.Unlock()
			if failure != nil || recovered.UsesSystemDNS || !slices.Equal(recovered.Routes, original.Routes) ||
				!slices.Equal(recovered.DNSServers, []string{"203.0.113.53"}) {
				t.Fatal("recovery retained failed or fallback DNS state", recovered, failure)
			}
			requireStop(t, &e)
			tunnel.Tunnel.RuleUpdateCallback().Emit(provider)
			select {
			case actual := <-events:
				t.Fatal("retired subscription published again", actual)
			case <-time.After(30 * time.Millisecond):
			}
		})
	}
}

func TestRouteSetUpdateReprojectsReachableDNSServers(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var contents atomic.Value
	contents.Store("203.0.113.0/24\n")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = fmt.Fprint(w, contents.Load().(string)) }))
	defer server.Close()
	var e Engine
	body := fmt.Sprintf(`ipv6: false
tun: {dns-hijack: ['203.0.113.53:53'], route-address-set: [routes]}
rule-providers:
  routes: {type: http, behavior: ipcidr, format: text, url: '%s', interval: 0}
rules: ["MATCH,DIRECT"]
`, server.URL)
	prepareWithVPNOptions(t, &e, t.TempDir(), body, PrepareOptions{
		Network: androidnet.NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53"}},
	})
	e.mu.Lock()
	if !slices.Equal(e.spec.DNSServers, []string{"203.0.113.53"}) {
		t.Fatalf("initial DNS does not match the effective route set: %v", e.spec.DNSServers)
	}
	e.mu.Unlock()
	contents.Store("192.0.2.0/24\n")
	if err := e.cfg.RuleProviders["routes"].Update(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(2 * time.Second)
	var servers []string
	var usedSystem bool
	var revision uint64
	var err error
	for time.Now().Before(deadline) {
		e.mu.Lock()
		servers, usedSystem, revision, err = slices.Clone(e.spec.DNSServers), e.spec.UsesSystemDNS, e.spec.Revision, e.specError
		e.mu.Unlock()
		if revision == 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil || !slices.Equal(servers, []string{"192.0.2.53"}) || !usedSystem || revision != 2 {
		t.Fatalf("route update left an unreachable hijack DNS or no revision: servers=%v usedSystem=%v revision=%d err=%v",
			servers, usedSystem, revision, err)
	}
}
