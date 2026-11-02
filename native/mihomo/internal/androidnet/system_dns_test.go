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
				t.Fatal("显式system或其他DNS参数被改写", err)
			}
			for _, network := range []NetworkDNS{{PrivateDNS: "strict"}, {PrivateDNSActive: true}, {PrivateDNSHostname: "dns.example.test"}} {
				used, err = CheckSystemDNS(cfg, network)
				var limit *PlatformError
				if !used || !errors.As(err, &limit) || limit.Field != tc.field || limit.Reason != "privateDnsUnavailable" {
					t.Fatal("私人DNS组合缺少准确字段错误", err)
				}
			}
			cfg.Enable = false
			if used, err = CheckSystemDNS(cfg, NetworkDNS{PrivateDNS: "strict"}); err != nil || used {
				t.Fatal("禁用DNS仍拒绝未使用的system", err)
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
			t.Fatal("未报告raw-message能力错误", err)
		}
		servers, err := network.SystemServers()
		if err != nil || servers != nil {
			t.Fatal("无系统服务器时没有向上游传nil", servers, err)
		}
	}
	network := NetworkDNS{ID: "physical", Servers: []string{"192.0.2.53", "2001:db8::53", "192.0.2.53"}}
	servers, err := network.SystemServers()
	if err != nil || !reflect.DeepEqual(servers, []string{"192.0.2.53:53", "[2001:db8::53]:53"}) {
		t.Fatal(servers, err)
	}
	cfg := &config.DNS{Enable: true, NameServer: []dns.NameServer{{Net: "tls", Addr: "192.0.2.53:853"}}}
	if used, err := CheckSystemDNS(cfg, NetworkDNS{PrivateDNS: "strict"}); used || err != nil {
		t.Fatal("独立安全DNS被拒绝", err)
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
		t.Fatal("resolver的捕获网络被外部修改")
	}
	revoke()
	if local.Invalid() {
		t.Fatal("已撤销owner仍可用")
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
		t.Fatal("nil resolver给出cache能力")
	}
	first, second := &capturedCacheDNS{}, &capturedCacheDNS{}
	local := &NetworkResolver{owner: DNSOwner{ID: 41}, actual: first}
	captured := local.CaptureCache(41)
	if captured == nil || local.CaptureCache(42) != nil {
		t.Fatal("cache能力借用了其他owner")
	}
	local.actual = second
	captured()
	if first.cleared.Load() != 1 || second.cleared.Load() != 0 {
		t.Fatal("捕获cache操作改到了另一个resolver")
	}
	local.actual = nil
	if local.CaptureCache(41) != nil {
		t.Fatal("不存在实际resolver仍给出cache能力")
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
		t.Fatal("撤销owner后仍交付cache或进入callback", value, err)
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
		t.Fatal("原始消息或cause丢失", value, err)
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
				t.Error("Lookup参数改变")
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
			t.Fatal("Lookup实际返回前释放了调用")
		case <-time.After(30 * time.Millisecond):
		}
		close(release)
		<-done
		if len(values) != 1 || values[0] != ip || !errors.Is(err, original) || !errors.Is(err, context.Canceled) {
			t.Fatal("实际结果或取消cause丢失", values, err)
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
		t.Fatal("原始callback实际返回前完成")
	case <-time.After(30 * time.Millisecond):
	}
	close(release)
	<-done
	if err != nil || answer == nil {
		t.Fatal("丢失实际成功结果", answer, err)
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
		t.Fatal("未使用公开resolver的cache", calls.Load())
	}
	local.CaptureCache(41)()
	if _, err := local.ExchangeContext(context.Background(), question); err != nil || calls.Load() != 2 {
		t.Fatal("未清除实际公开cache", err, calls.Load())
	}
	legacy := NewNetworkResolver(NetworkDNS{ID: "captured", APILevel: 28}, DNSOwner{})
	if _, err := legacy.ResolveECH(context.Background(), "ech.test"); err == nil {
		t.Fatal("API24—28没有报告ECH能力错误")
	}
}
func TestPublicResolverExitDoesNotClaimInternalRawQueryExit(t *testing.T) {
	// mihomo v1.19.33 dns/resolver.go:152—242使用background context和singleflight；公开返回不等内部任务全部退出。
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
		t.Fatal("公开调用没有按其context返回")
	}
	select {
	case <-actualExit:
		close(release)
		t.Fatal("测试callback提前退出")
	default:
	}
	close(release)
	select {
	case <-actualExit:
	case <-time.After(time.Second):
		t.Fatal("原始callback未实际退出")
	}
}
