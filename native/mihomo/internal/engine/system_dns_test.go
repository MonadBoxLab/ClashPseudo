package engine

import (
	"context"
	"errors"
	"net/netip"
	"slices"
	"sync/atomic"
	"testing"

	"clashpseudo/native/internal/androidnet"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/dns"
	MD "github.com/miekg/dns"
)

func TestCapturedSystemResolverCannotBorrowReplacementOwnerOrNetwork(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	var calls atomic.Int64
	options := PrepareOptions{Purpose: "PREVIEW", Network: androidnet.NetworkDNS{ID: "captured", APILevel: 29, Servers: []string{"192.0.2.53"}}, SystemDNSQuery: func(ctx context.Context, wire []byte) ([]byte, error) {
		calls.Add(1)
		var query MD.Msg
		if err := query.Unpack(wire); err != nil {
			return nil, err
		}
		response := new(MD.Msg)
		response.SetReply(&query)
		response.Answer = []MD.RR{&MD.A{Hdr: MD.RR_Header{Name: query.Question[0].Name, Rrtype: MD.TypeA, Class: MD.ClassINET, Ttl: 60}, A: []byte{192, 0, 2, 1}}}
		return response.Pack()
	}}
	if err := e.PrepareWithOptions(t.TempDir(), []byte("dns: {enable: true, nameserver: [system]}\nrules: ['MATCH,DIRECT']\n"), "", func(int) bool { return true }, options); err != nil {
		t.Fatal(err)
	}
	captured := e.systemDNS
	addresses, err := captured.LookupIPv4(context.Background(), "one.test")
	if err != nil || !slices.Equal(addresses, []netip.Addr{netip.MustParseAddr("192.0.2.1")}) {
		t.Fatal(addresses, err)
	}
	requireStop(t, &e)
	if _, err = captured.LookupIPv4(context.Background(), "two.test"); !errors.Is(err, ErrStopped) {
		t.Fatal("旧resolver借用了其他owner", err)
	}
	if calls.Load() != 1 {
		t.Fatal("撤销owner后仍调用Android callback", calls.Load())
	}
}
func TestEngineKeepsExplicitSystemEntriesAndCapturedResolver(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	network := androidnet.NetworkDNS{ID: "physical-a", APILevel: 29, Servers: []string{"192.0.2.53"}}
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
rules: ['MATCH,DIRECT']
`, PrepareOptions{Network: network})
	if resolver.SystemResolver != e.systemDNS {
		t.Fatal("未安装本次捕获resolver")
	}
	for _, list := range [][]dns.NameServer{e.cfg.DNS.NameServer, e.cfg.DNS.Fallback, e.cfg.DNS.DefaultNameserver, e.cfg.DNS.ProxyServerNameserver, e.cfg.DNS.DirectNameServer, e.cfg.DNS.NameServerPolicy[0].NameServers, e.cfg.DNS.ProxyServerPolicy[0].NameServers} {
		if len(list) != 1 || list[0].Net != "system" {
			t.Fatal("应用展开或改写了显式system", list)
		}
	}
	network.Servers[0] = "192.0.2.54"
	if e.options.Network.Servers[0] != "192.0.2.53" {
		t.Fatal("捕获Network引用了外部可变slice")
	}
	if !e.usesSystemDNS || !e.spec.UsesSystemDNS {
		t.Fatal("system依赖未投影")
	}
	captured := resolver.SystemResolver
	requireStop(t, &e)
	if resolver.SystemResolver != captured {
		t.Fatal("Stop替换了已撤销resolver")
	}
}
func TestIndependentExplicitDNSDoesNotRequireSystemServers(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	prepareWithVPNOptions(t, &e, t.TempDir(), "ipv6: false\ndns: {nameserver: ['tls://192.0.2.53:853']}\nrules: ['MATCH,DIRECT']\n", PrepareOptions{Network: androidnet.NetworkDNS{ID: "strict", APILevel: 29, PrivateDNS: "strict"}})
	if e.spec.UsesSystemDNS || e.usesSystemDNS {
		t.Fatal("独立DNS被标记为system依赖")
	}
	if !slices.Equal(e.spec.DNSServers, []string{"198.18.0.2"}) || !netip.MustParsePrefix("198.18.0.1/30").Contains(netip.MustParseAddr(e.spec.DNSServers[0])) {
		t.Fatal(e.spec.DNSServers)
	}
}
