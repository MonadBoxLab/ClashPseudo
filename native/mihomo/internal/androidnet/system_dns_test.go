package androidnet

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func TestExplicitSystemDNSKeepsAllSevenPublicFieldsAndParameters(t *testing.T) {
	system := dns.NameServer{Net: "system", ProxyName: "kept-proxy", Params: map[string]string{"ecs": "192.0.2.0/24", "h3": "true"}, PreferH3: true}
	other := dns.NameServer{Net: "https", Addr: "https://explicit.test/dns-query", Params: map[string]string{"test": "kept"}}
	for _, tc := range []struct {
		field string
		set   func(*config.DNS, []dns.NameServer)
	}{
		{"dns.nameserver", func(c *config.DNS, v []dns.NameServer) { c.NameServer = v }},
		{"dns.fallback", func(c *config.DNS, v []dns.NameServer) { c.Fallback = v }},
		{"dns.default-nameserver", func(c *config.DNS, v []dns.NameServer) { c.DefaultNameserver = v }},
		{"dns.proxy-server-nameserver", func(c *config.DNS, v []dns.NameServer) { c.ProxyServerNameserver = v }},
		{"dns.direct-nameserver", func(c *config.DNS, v []dns.NameServer) { c.DirectNameServer = v }},
		{"dns.nameserver-policy", func(c *config.DNS, v []dns.NameServer) {
			c.NameServerPolicy = []dns.Policy{{Domain: "a.test", NameServers: v}}
		}},
		{"dns.proxy-server-nameserver-policy", func(c *config.DNS, v []dns.NameServer) {
			c.ProxyServerPolicy = []dns.Policy{{Domain: "b.test", NameServers: v}}
		}},
	} {
		t.Run(tc.field, func(t *testing.T) {
			cfg := &config.DNS{Enable: true}
			tc.set(cfg, []dns.NameServer{system, other})
			before, _ := json.Marshal(cfg)
			used, err := CheckSystemDNS(cfg, NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53", "2001:db8::53"}})
			after, _ := json.Marshal(cfg)
			if err != nil || !used || !bytes.Equal(before, after) {
				t.Fatal("explicit system or other DNS parameters were changed", err)
			}
			for _, network := range []NetworkDNS{{PrivateDNS: "strict"}, {PrivateDNSActive: true}, {PrivateDNSHostname: "dns.example.test"}} {
				used, err = CheckSystemDNS(cfg, network)
				var limit *PlatformError
				if !used || !errors.As(err, &limit) || limit.Field != tc.field || limit.Reason != "privateDnsUnavailable" {
					t.Fatal("Private DNS combination is missing the error for the specific field", err)
				}
			}
			cfg.Enable = false
			if used, err = CheckSystemDNS(cfg, NetworkDNS{PrivateDNS: "strict"}); err != nil || used {
				t.Fatal("disabled DNS still rejected an unused system client", err)
			}
		})
	}
}
func TestSystemDNSUnavailableNeverFallsBackAndStrictPrivateDNSIsNotDowngraded(t *testing.T) {
	for _, network := range []NetworkDNS{{}, {ID: "physical"}, {ID: "physical", PrivateDNS: "strict"}} {
		local := NewNetworkResolver(network, DNSOwner{})
		question := new(D.Msg).SetQuestion("no-fallback.test.", D.TypeA)
		_, err := local.ExchangeContext(context.Background(), question)
		var limit *PlatformError
		if !errors.As(err, &limit) {
			t.Fatal("raw-message capability error was not reported", err)
		}
		servers, err := network.SystemServers()
		if err != nil || servers != nil {
			t.Fatal("nil was not passed upstream when no system servers were available", servers, err)
		}
	}
	network := NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53", "2001:db8::53", "192.0.2.53"}}
	servers, err := network.SystemServers()
	if err != nil || !reflect.DeepEqual(servers, []string{"192.0.2.53:53", "[2001:db8::53]:53"}) {
		t.Fatal(servers, err)
	}
	cfg := &config.DNS{Enable: true, NameServer: []dns.NameServer{{Net: "tls", Addr: "192.0.2.53:853"}}}
	if used, err := CheckSystemDNS(cfg, NetworkDNS{PrivateDNS: "strict"}); used || err != nil {
		t.Fatal("standalone secure DNS was rejected", err)
	}
}
func TestSystemDNSOwnerCannotBorrowAnotherCapturedNetwork(t *testing.T) {
	ctx, revoke := context.WithCancel(context.Background())
	defer revoke()
	original := NetworkDNS{ID: "captured", Servers: []string{"192.0.2.53"}, Revision: 3, SnapshotKey: "exact-key"}
	local := NewNetworkResolver(original, DNSOwner{ID: 41, Revoked: ctx})
	original.ID = "replacement"
	original.Servers[0] = "192.0.2.54"
	if local.network.ID != "captured" || local.network.Servers[0] != "192.0.2.53" || local.network.Key() != "exact-key" {
		t.Fatal("resolver's captured network was modified externally")
	}
	revoke()
	if local.Invalid() {
		t.Fatal("revoked owner is still available")
	}
}

type capturedCacheDNS struct {
	resolver.Resolver
	cleared atomic.Int64
	resets  atomic.Int64
}

func (r *capturedCacheDNS) ClearCache()      { r.cleared.Add(1) }
func (r *capturedCacheDNS) ResetConnection() { r.resets.Add(1) }
func TestCaptureCacheRetainsActualResolverAndRejectsUnavailableOwners(t *testing.T) {
	var absent *NetworkResolver
	if absent.CaptureCache(41) != nil {
		t.Fatal("nil resolver exposed a cache capability")
	}
	first, second := &capturedCacheDNS{}, &capturedCacheDNS{}
	local := &NetworkResolver{owner: DNSOwner{ID: 41}, actual: first}
	captured := local.CaptureCache(41)
	if captured == nil || local.CaptureCache(42) != nil {
		t.Fatal("cache capability used another owner")
	}
	local.actual = second
	captured()
	if first.cleared.Load() != 1 || second.cleared.Load() != 0 {
		t.Fatal("captured cache operation affected another resolver")
	}
	local.actual = nil
	if local.CaptureCache(41) != nil {
		t.Fatal("cache capability was exposed without an actual resolver")
	}
}
func TestStableSystemDNSCannotServeCachedAnswersAfterSessionCancellation(t *testing.T) {
	ctx, revoke := context.WithCancel(context.Background())
	defer revoke()
	var calls atomic.Int64
	local := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 29}, DNSOwner{ID: 41, Revoked: ctx, RawQuery: func(_ context.Context, wire []byte) ([]byte, error) { calls.Add(1); return answerWire(wire) }})
	question := new(D.Msg).SetQuestion("cached.test.", D.TypeA)
	if _, err := local.ExchangeContext(context.Background(), question); err != nil {
		t.Fatal(err)
	}
	before := calls.Load()
	revoke()
	if value, err := local.ExchangeContext(context.Background(), question); err == nil || value != nil || calls.Load() != before {
		t.Fatal("cache was delivered or callback entered after owner revocation", value, err)
	}
}
func TestSystemDNSRawCallbackKeepsOriginalErrorAndMessage(t *testing.T) {
	original := errors.New("Android rawQuery original cause")
	client := &rawDNSClient{network: "captured", owner: DNSOwner{RawQuery: func(_ context.Context, wire []byte) ([]byte, error) {
		value, err := answerWire(wire)
		return value, errors.Join(original, err)
	}}}
	question := new(D.Msg).SetQuestion("actual.test.", D.TypeA)
	value, err := client.ExchangeContext(context.Background(), question)
	if value == nil || len(value.Answer) != 1 || !errors.Is(err, original) || client.Address() != "android://captured" {
		t.Fatal("original message or cause was lost", value, err)
	}
}
func TestLegacySystemDNSKeepsActualResultUntilLookupReturns(t *testing.T) {
	for _, family := range []int{0, 4, 6} {
		entered, release := make(chan struct{}), make(chan struct{})
		ctx, cancel := context.WithCancel(context.Background())
		original := errors.New("getAllByName original cause")
		ip := netip.MustParseAddr("192.0.2.7")
		local := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 28}, DNSOwner{Lookup: func(child context.Context, host string, got int) ([]netip.Addr, error) {
			if got != family || host != "legacy.test" {
				t.Error("Lookup parameters changed")
			}
			close(entered)
			<-child.Done()
			<-release
			return []netip.Addr{ip}, original
		}})
		done := make(chan struct{})
		var values []netip.Addr
		var err error
		go func() { values, err = local.lookup(ctx, "legacy.test", family); close(done) }()
		<-entered
		cancel()
		select {
		case <-done:
			t.Fatal("call was released before Lookup returned")
		case <-time.After(30 * time.Millisecond):
		}
		close(release)
		<-done
		if len(values) != 1 || values[0] != ip || !errors.Is(err, original) || !errors.Is(err, context.Canceled) {
			t.Fatal("actual result or cancellation cause was lost", values, err)
		}
	}
}
func TestSystemDNSPublicCallsKeepActualValuesAndErrorsAfterInterruption(t *testing.T) {
	ctx, revoke := context.WithCancel(context.Background())
	defer revoke()
	entered, release := make(chan struct{}), make(chan struct{})
	client := &rawDNSClient{owner: DNSOwner{Revoked: ctx, RawQuery: func(child context.Context, wire []byte) ([]byte, error) {
		close(entered)
		<-child.Done()
		<-release
		return answerWire(wire)
	}}}
	done := make(chan struct{})
	var answer *D.Msg
	var err error
	go func() {
		answer, err = client.ExchangeContext(context.Background(), new(D.Msg).SetQuestion("actual.test.", D.TypeA))
		close(done)
	}()
	<-entered
	revoke()
	select {
	case <-done:
		t.Fatal("completed before the original callback returned")
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	<-done
	if err != nil || answer == nil {
		t.Fatal("actual successful result was lost", answer, err)
	}
}
func answerWire(wire []byte) ([]byte, error) {
	question := new(D.Msg)
	if err := question.Unpack(wire); err != nil {
		return nil, err
	}
	answer := new(D.Msg).SetReply(question)
	rr, err := D.NewRR(question.Question[0].Name + " 60 IN A 192.0.2.7")
	if err != nil {
		return nil, err
	}
	answer.Answer = []D.RR{rr}
	return answer.Pack()
}
func TestStableSystemDNSUsesPublicResolverForRealExchangeAndCacheClear(t *testing.T) {
	var calls atomic.Int64
	local := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 29, PrivateDNS: "strict"}, DNSOwner{ID: 41, RawQuery: func(_ context.Context, wire []byte) ([]byte, error) { calls.Add(1); return answerWire(wire) }})
	question := new(D.Msg).SetQuestion("public-cache.test.", D.TypeA)
	for i := 0; i < 2; i++ {
		answer, err := local.ExchangeContext(context.Background(), question)
		if err != nil || len(answer.Answer) != 1 {
			t.Fatal(answer, err)
		}
	}
	if calls.Load() != 1 {
		t.Fatal("public resolver cache was not used", calls.Load())
	}
	local.CaptureCache(41)()
	if _, err := local.ExchangeContext(context.Background(), question); err != nil || calls.Load() != 2 {
		t.Fatal("actual public cache was not cleared", err, calls.Load())
	}
	legacy := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 28}, DNSOwner{})
	if _, err := legacy.ResolveECH(context.Background(), "ech.test"); err == nil {
		t.Fatal("API 24–28 did not report an ECH capability error")
	}
}
func TestPublicResolverExitDoesNotClaimInternalRawQueryExit(t *testing.T) {
	// mihomo v1.19.33 dns/resolver.go:152–242 uses a background context and singleflight; the public call returns without waiting for all internal tasks to exit.
	owner, revoke := context.WithCancel(context.Background())
	defer revoke()
	entered, release, actualExit := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var begin, end sync.Once
	local := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 29}, DNSOwner{Revoked: owner, RawQuery: func(_ context.Context, wire []byte) ([]byte, error) {
		begin.Do(func() { close(entered) })
		<-release
		defer end.Do(func() { close(actualExit) })
		return answerWire(wire)
	}})
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() {
		_, err := local.ExchangeContext(ctx, new(D.Msg).SetQuestion("public-exit.test.", D.TypeA))
		result <- err
	}()
	<-entered
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		close(release)
		t.Fatal("public call did not return according to its context")
	}
	select {
	case <-actualExit:
		close(release)
		t.Fatal("test callback exited early")
	default:
	}
	close(release)
	select {
	case <-actualExit:
	case <-time.After(time.Second):
		t.Fatal("original callback did not exit")
	}
}
