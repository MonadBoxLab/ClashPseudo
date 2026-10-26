package engine

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"reflect"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func TestExplicitSystemDNSExpandsAllPublicListsAndPoliciesWithoutLosingParameters(t *testing.T) {
	system := dns.NameServer{Net: "system", ProxyName: "kept-proxy", Params: map[string]string{"ecs": "192.0.2.0/24", "h3": "true"}, PreferH3: true}
	other := dns.NameServer{Net: "https", Addr: "https://explicit.test/dns-query", Params: map[string]string{"test": "kept"}}
	list := func() []dns.NameServer { return []dns.NameServer{system, other} }
	cfg := &config.DNS{NameServer: list(), Fallback: list(), DefaultNameserver: list(), ProxyServerNameserver: list(), DirectNameServer: list(),
		NameServerPolicy: []dns.Policy{{Domain: "a.test", NameServers: list()}}, ProxyServerPolicy: []dns.Policy{{Domain: "b.test", NameServers: list()}}}
	used, err := expandSystemDNS(cfg, NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53", "2001:db8::53", "192.0.2.53"}})
	if err != nil || !used {
		t.Fatalf("system expansion failed: used=%v %v", used, err)
	}
	for _, values := range [][]dns.NameServer{cfg.NameServer, cfg.Fallback, cfg.DefaultNameserver, cfg.ProxyServerNameserver, cfg.DirectNameServer, cfg.NameServerPolicy[0].NameServers, cfg.ProxyServerPolicy[0].NameServers} {
		if len(values) != 3 || values[0].Addr != "192.0.2.53:53" || values[1].Addr != "[2001:db8::53]:53" || !values[2].Equal(other) {
			t.Fatal("a public system source was left unexpanded or another source changed", values)
		}
		for _, value := range values[:2] {
			if value.Net != "udp" || value.ProxyName != system.ProxyName || !reflect.DeepEqual(value.Params, system.Params) || value.PreferH3 != system.PreferH3 {
				t.Fatal("applicable system source parameters were lost", value)
			}
		}
	}
}

func TestSystemDNSUnavailableNeverFallsBackAndStrictPrivateDNSIsNotDowngraded(t *testing.T) {
	for _, network := range []NetworkDNS{{}, {ID: "physical"}, {ID: "physical", Servers: []string{"192.0.2.53"}, PrivateDNS: "strict"}} {
		var local networkResolver
		local.update(network)
		if local.Invalid() {
			t.Fatal("unavailable system DNS advertised a usable resolver")
		}
		question := new(D.Msg)
		question.SetQuestion("no-fallback.test.", D.TypeA)
		_, err := local.ExchangeContext(context.Background(), question)
		var limit *PlatformError
		if !errors.As(err, &limit) {
			t.Fatalf("missing explicit system-DNS failure: %v", err)
		}
		want := "systemDnsUnavailable"
		if network.PrivateDNS == "strict" {
			want = "privateDnsUnavailable"
		}
		if limit.Reason != want {
			t.Fatal(limit)
		}
		cfg := &config.DNS{NameServer: []dns.NameServer{{Net: "system"}}}
		if _, err := expandSystemDNS(cfg, network); err == nil {
			t.Fatal("explicit system client bypassed unavailable/strict snapshot")
		}
		value := local.value.Load()
		value.cancel()
	}
	cfg := &config.DNS{NameServer: []dns.NameServer{{Net: "tls", Addr: "192.0.2.53:853"}}}
	if used, err := expandSystemDNS(cfg, NetworkDNS{PrivateDNS: "strict"}); used || err != nil {
		t.Fatal("independent explicit secure DNS was rejected", used, err)
	}
}

type uncancellableDNS struct {
	resolver.Resolver
	entered, release chan struct{}
	resets           atomic.Int64
}

func (r *uncancellableDNS) ExchangeContext(_ context.Context, message *D.Msg) (*D.Msg, error) {
	close(r.entered)
	<-r.release
	return new(D.Msg).SetReply(message), nil
}
func (r *uncancellableDNS) ResetConnection() { r.resets.Add(1) }
func (r *uncancellableDNS) ClearCache()      {}
func (r *uncancellableDNS) Invalid() bool    { return true }

func TestStableSystemDNSDiscardsLateResultsFromOldAtomicNetworkSnapshot(t *testing.T) {
	var local networkResolver
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	oldResolver := &uncancellableDNS{entered: make(chan struct{}), release: make(chan struct{})}
	old := &resolverSnapshot{key: "old", resolver: oldResolver, ctx: ctx, cancel: cancel}
	local.value.Store(old)
	question := new(D.Msg)
	question.SetQuestion("late.test.", D.TypeA)
	finished := make(chan error, 1)
	go func() {
		response, err := local.ExchangeContext(context.Background(), question)
		if response != nil {
			finished <- errors.New("late response was published")
			return
		}
		finished <- err
	}()
	select {
	case <-oldResolver.entered:
	case <-time.After(time.Second):
		t.Fatal("old DNS query did not enter")
	}
	if !local.update(NetworkDNS{ID: "new-physical", Servers: []string{"192.0.2.53"}}) {
		t.Fatal("actual network change was ignored")
	}
	close(oldResolver.release)
	select {
	case err := <-finished:
		if err == nil || !strings.Contains(err.Error(), "obsolete network") {
			t.Fatalf("old uncancellable DNS result accepted: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("obsolete query wrapper did not complete")
	}
	if oldResolver.resets.Load() != 1 || old.ctx.Err() == nil {
		t.Fatal("old snapshot was not cancelled/reset")
	}
	next := local.value.Load()
	defer next.cancel()
	if local.update(NetworkDNS{ID: "new-physical", Servers: []string{"192.0.2.53", "192.0.2.53"}}) || local.value.Load() != next || next.ctx.Err() != nil {
		t.Fatal("unchanged normalized network replaced the resolver")
	}
}

func TestStableSystemDNSUsesPublicResolverForRealExchangeAndCacheClear(t *testing.T) {
	var engine Engine
	var bound atomic.Int64
	if err := engine.PrepareWithOptions(t.TempDir(), []byte(validConfig), "", nil, func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", ProtectNetwork: func(fd int, handle string) bool {
		if fd < 0 || handle != "real-physical" {
			return false
		}
		bound.Add(1)
		return true
	}}); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &engine)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int64
	started := make(chan struct{})
	server := &D.Server{PacketConn: packet, NotifyStartedFunc: func() { close(started) }, Handler: D.HandlerFunc(func(w D.ResponseWriter, request *D.Msg) {
		requests.Add(1)
		response := new(D.Msg).SetReply(request)
		response.Answer = []D.RR{&D.A{Hdr: D.RR_Header{Name: request.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET, Ttl: 600}, A: net.ParseIP("192.0.2.99")}}
		_ = w.WriteMsg(response)
	})}
	done := make(chan error, 1)
	go func() { done <- server.ActivateAndServe() }()
	select {
	case <-started:
	case err := <-done:
		t.Fatal(err)
	case <-time.After(time.Second):
		t.Fatal("DNS test service did not start")
	}
	defer func() { _ = server.Shutdown(); _ = packet.Close(); <-done }()
	nameserver := dns.NameServer{Net: "udp", Addr: packet.LocalAddr().String(), ProxyAdapter: newNetworkDNSAdapter("real-physical")}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var local networkResolver
	local.value.Store(&resolverSnapshot{key: "real-physical", ctx: ctx, cancel: cancel, resolver: dns.NewResolver(dns.Config{Main: []dns.NameServer{nameserver}, Default: []dns.NameServer{nameserver}})})
	question := new(D.Msg)
	question.SetQuestion("actually-resolved.test.", D.TypeA)
	for i := 0; i < 2; i++ {
		response, err := local.ExchangeContext(context.Background(), question)
		if err != nil || len(response.Answer) != 1 || response.Answer[0].(*D.A).A.String() != "192.0.2.99" {
			t.Fatalf("public resolver failed: %+v %v", response, err)
		}
	}
	if requests.Load() != 1 {
		t.Fatal("real public DNS cache was not used", requests.Load())
	}
	local.ClearCache()
	if _, err := local.ExchangeContext(context.Background(), question); err != nil {
		t.Fatal(err)
	}
	if requests.Load() != 2 || bound.Load() != 2 {
		t.Fatal("synchronous cache clear or captured-network socket binding did not reach the actual public DNS transport", requests.Load(), bound.Load())
	}
}

func TestSystemDNSSocketAdapterCannotBorrowReplacementOwnerOrNetwork(t *testing.T) {
	var e Engine
	var accepted atomic.Int64
	options := PrepareOptions{Purpose: "PREVIEW", Network: NetworkDNS{ID: "captured", Servers: []string{"192.0.2.53"}}, ProtectNetwork: func(_ int, handle string) bool {
		if handle != "captured" {
			return false
		}
		accepted.Add(1)
		return true
	}}
	home := t.TempDir()
	if err := e.PrepareWithOptions(home, []byte(validConfig), "", nil, func(int) bool { return true }, options); err != nil {
		t.Fatal(err)
	}
	oldSnapshot := systemDNS.value.Load()
	adapter := newNetworkDNSAdapter("captured")
	metadata := &C.Metadata{DstIP: netip.MustParseAddr("127.0.0.1"), DstPort: 53, NetWork: C.UDP}
	packet, err := adapter.ListenPacketContext(context.Background(), metadata)
	if err != nil {
		t.Fatal(err)
	}
	if err := packet.Close(); err != nil {
		t.Fatal(err)
	}
	if accepted.Load() != 1 {
		t.Fatal("captured network protector was not used")
	}
	requireStop(t, &e)
	if err := e.PrepareWithOptions(home, []byte(validConfig), "", nil, func(int) bool { return true }, options); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if systemDNS.value.Load() == oldSnapshot || oldSnapshot.ctx.Err() == nil {
		t.Fatal("same network reused the previous session's resolver/owner")
	}
	if _, err := adapter.ListenPacketContext(context.Background(), metadata); !errors.Is(err, ErrStopped) {
		t.Fatalf("old adapter borrowed a new session owner: %v", err)
	}
	if accepted.Load() != 1 {
		t.Fatal("old owner reached the replacement network protector")
	}
	wrongNetwork := newNetworkDNSAdapter("other-network")
	if _, err := wrongNetwork.ListenPacketContext(context.Background(), metadata); err == nil {
		t.Fatal("captured network identity was silently replaced")
	}
}

func TestEngineSystemDNSSourcesRequireSameInputRefreshOnlyForActualChange(t *testing.T) {
	original := resolver.SystemResolver
	network := NetworkDNS{ID: "physical-a", Servers: []string{"192.0.2.53"}}
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), `ipv6: false
dns:
  nameserver: [system]
  default-nameserver: [system]
  fallback: [system]
  fallback-filter: {geoip: false}
  proxy-server-nameserver: [system]
  direct-nameserver: [system]
  nameserver-policy: {'policy.test': system}
  proxy-server-nameserver-policy: {'proxy-policy.test': system}
rules: ["MATCH,DIRECT"]
`, PrepareOptions{Network: network})
	if resolver.SystemResolver != original || original != &systemDNS {
		t.Fatal("prepare replaced the process-stable resolver pointer")
	}
	for _, list := range [][]dns.NameServer{e.cfg.DNS.NameServer, e.cfg.DNS.Fallback, e.cfg.DNS.DefaultNameserver, e.cfg.DNS.ProxyServerNameserver, e.cfg.DNS.DirectNameServer, e.cfg.DNS.NameServerPolicy[0].NameServers, e.cfg.DNS.ProxyServerPolicy[0].NameServers} {
		if len(list) != 1 || list[0].Net != "udp" || list[0].Addr != "192.0.2.53:53" {
			t.Fatal("actual parsed explicit system source was not expanded before Apply", list)
		}
	}
	read := func(value string) map[string]bool {
		t.Helper()
		var result map[string]bool
		if json.Unmarshal([]byte(value), &result) != nil {
			t.Fatal(value)
		}
		return result
	}
	if result := read(e.UpdateNetwork(network)); result["changed"] || result["requiresRestart"] {
		t.Fatal("identical network triggered a reconnect", result)
	}
	changed := NetworkDNS{ID: "physical-b", Servers: []string{"192.0.2.54"}}
	if result := read(e.UpdateNetwork(changed)); !result["changed"] || !result["requiresRestart"] {
		t.Fatal("system sources were not marked for same-input rebuild", result)
	}
	if e.cfg.DNS.NameServer[0].Addr != "192.0.2.53:53" {
		t.Fatal("unrebuilt explicit system config was silently advertised as updated")
	}
	if result := read(e.UpdateNetwork(network)); result["requiresRestart"] {
		t.Fatal("network reverted to prepared values but a stale refresh remained")
	}
	requireStop(t, &e)
	if resolver.SystemResolver != original {
		t.Fatal("Stop replaced the process-stable resolver pointer")
	}
}

func TestIndependentExplicitDNSDoesNotReconnectForSystemNetworkNotifications(t *testing.T) {
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), "ipv6: false\ndns: {nameserver: ['tls://192.0.2.53:853']}\nrules: [\"MATCH,DIRECT\"]\n", PrepareOptions{Network: NetworkDNS{ID: "strict", Servers: []string{"192.0.2.54"}, PrivateDNS: "strict"}})
	if e.spec.UsesSystemDNS {
		t.Fatal("explicit independent DNS was labelled as a system dependency")
	}
	var result map[string]bool
	if json.Unmarshal([]byte(e.UpdateNetwork(NetworkDNS{ID: "new", Servers: []string{"192.0.2.55"}})), &result) != nil || result["requiresRestart"] {
		t.Fatal("network callback indiscriminately reconnected independent DNS", result)
	}
	if !slices.Equal(e.spec.DNSServers, []string{"198.18.0.2"}) {
		t.Fatal(e.spec.DNSServers)
	}
	if !netip.MustParsePrefix("198.18.0.1/30").Contains(netip.MustParseAddr(e.spec.DNSServers[0])) {
		t.Fatal("invalid same-family announcement")
	}
}
