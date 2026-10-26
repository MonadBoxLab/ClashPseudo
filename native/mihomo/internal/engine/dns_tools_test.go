package engine

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

func questionJSON(name, kind string) []byte {
	body, _ := json.Marshal(DNSQuestion{Name: name, Type: kind})
	return body
}
func testDNSPrepare(t *testing.T, e *Engine, config string) {
	t.Helper()
	if err := e.Prepare(t.TempDir(), []byte("ipv6: false\n"+config+"\nrules: ['MATCH,DIRECT']\n"), "", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, e) })
}
func dnsObject(t *testing.T, body string) map[string]any {
	t.Helper()
	var value map[string]any
	if err := json.Unmarshal([]byte(body), &value); err != nil {
		t.Fatal(err, body)
	}
	return value
}

func TestDNSQuestionNormalizationAndBoundaries(t *testing.T) {
	for _, test := range []struct{ name, kind, want string }{
		{"例子.测试", "A", "xn--fsqu00a.xn--0zwm56d."},
		{"_sip._tcp.例子.测试", "SRV", "_sip._tcp.xn--fsqu00a.xn--0zwm56d."},
		{"192.0.2.7", "PTR", "7.2.0.192.in-addr.arpa."},
		{"7.2.0.192.in-addr.arpa", "PTR", "7.2.0.192.in-addr.arpa."},
		{"2001:db8::7", "PTR", "7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa."},
		{"EXAMPLE.TEST.", "https", "example.test."}, {".", "NS", "."},
		{"_dmarc.example.test", "TXT", "_dmarc.example.test."},
		{"_acme-challenge.example.test.", "TXT", "_acme-challenge.example.test."},
		{"_sip._tcp.test", "A", "_sip._tcp.test."},
		{"_sip.tcp.test", "SRV", "_sip.tcp.test."},
		{"_.test", "TXT", "_.test."},
		{"bad.example", "PTR", "bad.example."},
		{"256.2.0.192.in-addr.arpa", "PTR", "256.2.0.192.in-addr.arpa."},
	} {
		q, _, err := normalizeDNSQuestion(questionJSON(test.name, test.kind))
		if err != nil || q.Name != test.want {
			t.Fatalf("%s %s: %+v %v", test.name, test.kind, q, err)
		}
	}
	for _, test := range []DNSQuestion{{Name: "https://example.test", Type: "A"}, {Name: "example.test:53", Type: "A"}, {Name: "example.test/path", Type: "A"}, {Name: "example.test\n", Type: "A"}, {Name: "a..test", Type: "A"}, {Name: strings.Repeat("a", 64) + ".test", Type: "A"}, {Name: strings.Repeat("a", 1025), Type: "A"}, {Name: "example.test", Type: "AXFR"}, {Name: "example.test", Type: "IXFR"}, {Name: "", Type: "A"}} {
		if _, _, err := normalizeDNSQuestion(questionJSON(test.Name, test.Type)); err == nil {
			t.Fatalf("invalid DNS input accepted: %+v", test)
		}
	}
	name := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61) + "."
	if _, _, err := normalizeDNSQuestion(questionJSON(name, "A")); err != nil {
		t.Fatal("255 byte wire name rejected", err)
	}
	if _, _, err := normalizeDNSQuestion(questionJSON(strings.Replace(name, strings.Repeat("d", 61), strings.Repeat("d", 62), 1), "A")); err == nil {
		t.Fatal("256 byte wire name accepted")
	}
	if _, _, err := normalizeDNSQuestion(append(questionJSON("a.test", "A"), make([]byte, 4096)...)); err == nil {
		t.Fatal("oversized request accepted")
	}
}

func TestDNSPublicResolverRealRecordsRcodeCacheAndIndependentFakeIPClear(t *testing.T) {
	packet, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var requests atomic.Int64
	server := &D.Server{PacketConn: packet, Handler: D.HandlerFunc(func(w D.ResponseWriter, q *D.Msg) {
		requests.Add(1)
		r := new(D.Msg).SetReply(q)
		if strings.HasPrefix(q.Question[0].Name, "missing.") {
			r.Rcode = D.RcodeNameError
			_ = w.WriteMsg(r)
			return
		}
		data := map[uint16]string{D.TypeA: "192.0.2.99", D.TypeAAAA: "2001:db8::99", D.TypeCNAME: "alias.test.", D.TypeMX: "10 mail.test.", D.TypeTXT: "\"copyable spaces\"", D.TypeNS: "ns.test.", D.TypeSOA: "ns.test. admin.test. 1 2 3 4 5", D.TypePTR: "host.test.", D.TypeSRV: "10 5 443 target.test.", D.TypeHTTPS: "1 . alpn=h2", D.TypeSVCB: "1 target.test. port=443", D.TypeCAA: "0 issue \"ca.test\""}[q.Question[0].Qtype]
		rr, err := D.NewRR(q.Question[0].Name + " 600 IN " + D.Type(q.Question[0].Qtype).String() + " " + data)
		if err != nil {
			t.Error(err)
			return
		}
		r.Answer = []D.RR{rr}
		_ = w.WriteMsg(r)
	})}
	started := make(chan struct{})
	server.NotifyStartedFunc = func() { close(started) }
	done := make(chan error, 1)
	go func() { done <- server.ActivateAndServe() }()
	<-started
	defer func() { _ = server.Shutdown(); _ = packet.Close(); <-done }()
	var e Engine
	testDNSPrepare(t, &e, fmt.Sprintf("dns:\n  enable: true\n  enhanced-mode: fake-ip\n  nameserver: ['%s']\n  default-nameserver: ['%s']\n", packet.LocalAddr(), packet.LocalAddr()))
	for kind := range dnsTypes {
		name := "record.test"
		if kind == "SRV" {
			name = "_sip._tcp.record.test"
		}
		if kind == "PTR" {
			name = "192.0.2.1"
		}
		value := dnsObject(t, e.DNSQuery(questionJSON(name, kind)))
		if value["error"] != nil || value["rcode"] != float64(0) || len(value["answer"].([]any)) != 1 {
			t.Fatalf("%s: %+v", kind, value)
		}
		rr := value["answer"].([]any)[0].(map[string]any)
		if rr["type"] != kind || rr["class"] != "IN" || rr["ttl"] == nil || rr["data"] == "" {
			t.Fatalf("RR lost data: %+v", rr)
		}
	}
	value := dnsObject(t, e.DNSQuery(questionJSON("missing.test", "A")))
	if value["error"] != nil || value["rcode"] != float64(3) || value["rcodeName"] != "NXDOMAIN" || len(value["answer"].([]any)) != 0 {
		t.Fatal("NXDOMAIN treated as transport failure", value)
	}
	before := requests.Load()
	_ = e.DNSQuery(questionJSON("cache.test", "A"))
	_ = e.DNSQuery(questionJSON("cache.test", "A"))
	if requests.Load() != before+1 {
		t.Fatal("actual resolver cache not used", requests.Load(), before)
	}
	pool := e.cfg.DNS.FakeIPPool
	fake := pool.Lookup("independent.test")
	if value := dnsObject(t, e.ClearDNSCache()); value["status"] != "completed" {
		t.Fatal(value)
	}
	if host, ok := pool.LookBack(fake); !ok || host != "independent.test" {
		t.Fatal("DNS cache clear also removed fake-IP")
	}
	_ = e.DNSQuery(questionJSON("cache.test", "A"))
	if requests.Load() != before+2 {
		t.Fatal("DNS cache clear did not reach public resolver", requests.Load(), before)
	}
	before = requests.Load()
	if value := dnsObject(t, e.FlushFakeIP()); value["status"] != "completed" || value["persistent"] != false {
		t.Fatal(value)
	}
	if _, ok := pool.LookBack(fake); ok {
		t.Fatal("fake-IP flush left old mapping")
	}
	_ = e.DNSQuery(questionJSON("cache.test", "A"))
	if requests.Load() != before {
		t.Fatal("fake-IP flush also cleared DNS resolver cache")
	}
	if next := pool.Lookup("reparsed.test"); !next.IsValid() {
		t.Fatal("new fake-IP allocation failed after flush")
	}
}

type functionDNS struct {
	resolver.Resolver
	exchange func(context.Context, *D.Msg) (*D.Msg, error)
	clear    func()
}

func (d *functionDNS) ExchangeContext(ctx context.Context, q *D.Msg) (*D.Msg, error) {
	return d.exchange(ctx, q)
}
func (*functionDNS) ResetConnection() {}
func (d *functionDNS) ClearCache() {
	if d.clear != nil {
		d.clear()
	}
}
func (*functionDNS) Invalid() bool { return true }

func TestDNSCacheClearCapturesSystemSnapshotBeforeWaitingForPublicCall(t *testing.T) {
	var e Engine
	testDNSPrepare(t, &e, "")
	original := systemDNS.value.Load()
	defer func() { systemDNS.value.Store(original); original.cancel() }()
	entered, release := make(chan struct{}), make(chan struct{})
	var oldClears, newClears atomic.Int64
	old := *original
	old.resolver = &functionDNS{clear: func() { oldClears.Add(1) }}
	old.reason = nil
	systemDNS.value.Store(&old)
	resolver.DefaultResolver = &functionDNS{clear: func() { close(entered); <-release }}
	finished := make(chan string, 1)
	go func() { finished <- e.ClearDNSCache() }()
	<-entered
	e.UpdateNetwork(NetworkDNS{ID: "replacement", Servers: []string{"192.0.2.53"}})
	next := *systemDNS.value.Load()
	next.resolver = &functionDNS{clear: func() { newClears.Add(1) }}
	systemDNS.value.Store(&next)
	defer next.cancel()
	close(release)
	if value := dnsObject(t, <-finished); value["error"] != "obsolete" {
		t.Fatal(value)
	}
	if oldClears.Load() != 1 || newClears.Load() != 0 {
		t.Fatal("old operation cleared replacement network's cache", oldClears.Load(), newClears.Load())
	}
}

func TestStableSystemDNSCannotServeCachedAnswersAfterSessionCancellation(t *testing.T) {
	var e Engine
	testDNSPrepare(t, &e, "")
	original := systemDNS.value.Load()
	defer func() { systemDNS.value.Store(original) }()
	var exchanges atomic.Int64
	owned := *original
	owned.reason = nil
	owned.resolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
		exchanges.Add(1)
		return new(D.Msg).SetReply(q), nil
	}}
	systemDNS.value.Store(&owned)
	q := new(D.Msg).SetQuestion("cached.test.", D.TypeA)
	if _, err := systemDNS.ExchangeContext(context.Background(), q); err != nil {
		t.Fatal(err)
	}
	e.Cancel()
	if owned.ctx.Err() == nil {
		t.Fatal("session cancellation did not cancel captured system context")
	}
	if value, err := systemDNS.ExchangeContext(context.Background(), q); !errors.Is(err, ErrStopped) || value != nil {
		t.Fatal("cancelled owner served a cached answer", value, err)
	}
	if exchanges.Load() != 1 || systemDNS.Invalid() {
		t.Fatal("inactive snapshot remained available", exchanges.Load())
	}
}

func TestDNSQueryRealGateCancellationNetworkIdentityAndStopDrain(t *testing.T) {
	for _, action := range []string{"cancel", "network", "stop"} {
		t.Run(action, func(t *testing.T) {
			var e Engine
			testDNSPrepare(t, &e, "")
			entered, release := make(chan struct{}), make(chan struct{})
			resolver.DefaultResolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
				close(entered)
				<-release
				return new(D.Msg).SetReply(q), nil
			}}
			finished := make(chan string, 1)
			go func() { finished <- e.DNSQuery([]byte(`{"name":"late.test","type":"A","requestId":"123"}`)) }()
			<-entered
			if value := dnsObject(t, e.DNSQuery(questionJSON("second.test", "A"))); value["error"] != "busy" {
				t.Fatal("parallel call entered", value)
			}
			var stopped chan error
			switch action {
			case "cancel":
				e.CancelDNSRequest(123)
			case "network":
				e.UpdateNetwork(NetworkDNS{ID: "changed", Servers: []string{"192.0.2.53"}})
			case "stop":
				e.Cancel()
				stopped = make(chan error, 1)
				go func() { stopped <- e.Stop() }()
			}
			if e.dnsOperation.Load() == nil {
				t.Fatal("cancel/Stop prematurely released real gate")
			}
			if stopped != nil {
				select {
				case err := <-stopped:
					t.Fatal("Stop returned before public call", err)
				default:
				}
			}
			close(release)
			value := dnsObject(t, <-finished)
			want := "obsolete"
			if action == "cancel" {
				want = "cancelled"
			}
			if value["error"] != want {
				t.Fatal("late result not isolated", action, value)
			}
			if stopped != nil {
				if err := <-stopped; err != nil {
					t.Fatal(err)
				}
			}
			if e.dnsOperation.Load() != nil {
				t.Fatal("real completion retained slot")
			}
		})
	}
}

func TestDNSCancellationBeforeEntryCannotCancelANewerRequest(t *testing.T) {
	var e Engine
	testDNSPrepare(t, &e, "")
	var entered atomic.Int64
	resolver.DefaultResolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
		entered.Add(1)
		return new(D.Msg).SetReply(q), nil
	}}
	e.CancelDNSRequest(9)
	if value := dnsObject(t, e.DNSQuery([]byte(`{"name":"test.test","type":"A","requestId":"9"}`))); value["error"] != "cancelled" || entered.Load() != 0 {
		t.Fatal(value, entered.Load())
	}
	if value := dnsObject(t, e.DNSQuery([]byte(`{"name":"test.test","type":"A","requestId":"10"}`))); value["error"] != nil || entered.Load() != 1 {
		t.Fatal("old cancellation affected new request", value, entered.Load())
	}
}

func TestDNSDisabledAndOutputLimitsDoNotOpenAnAlternativeResolver(t *testing.T) {
	var e Engine
	testDNSPrepare(t, &e, "dns: {enable: false}\n")
	if value := dnsObject(t, e.DNSQuery(questionJSON("unavailable.test", "A"))); value["error"] != "unavailable" {
		t.Fatal(value)
	}
	if value := dnsObject(t, e.FlushFakeIP()); value["status"] != "empty" {
		t.Fatal(value)
	}
	requireStop(t, &e)
	testDNSPrepare(t, &e, "")
	for _, mode := range []string{"records", "bytes", "truncated", "timeout"} {
		resolver.DefaultResolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
			r := new(D.Msg).SetReply(q)
			switch mode {
			case "records":
				for i := 0; i < 513; i++ {
					r.Answer = append(r.Answer, &D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET}})
				}
			case "bytes":
				r.Answer = []D.RR{&D.TXT{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET}, Txt: []string{strings.Repeat("x", MaxDNSResult)}}}
			case "truncated":
				r.Truncated = true
			case "timeout":
				<-ctx.Done()
				return nil, ctx.Err()
			}
			return r, nil
		}}
		value := dnsObject(t, e.DNSQuery(questionJSON("limit.test", "A")))
		if mode == "truncated" {
			if value["error"] != nil || value["truncated"] != true {
				t.Fatal(value)
			}
		} else {
			want := "resultTooLarge"
			if mode == "timeout" {
				want = "timeout"
			}
			if value["error"] != want {
				t.Fatal(mode, value)
			}
		}
	}
}

type partialFakeIP struct {
	resolver.Enhancer
	pool *fakeip.Pool
}

func (m *partialFakeIP) FlushFakeIP() error {
	_ = m.pool.FlushFakeIP()
	return errors.New("second family public flush failed")
}

func TestFakeIPBothFamiliesEmptyAndAggregatePartialFailureAreReportedHonestly(t *testing.T) {
	var e Engine
	testDNSPrepare(t, &e, "")
	p4, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("198.18.0.1/16"), Size: 100})
	if err != nil {
		t.Fatal(err)
	}
	p6, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("2001:db8::1/64"), Size: 100})
	if err != nil {
		t.Fatal(err)
	}
	e.cfg.DNS.FakeIPPool, e.cfg.DNS.FakeIPPool6 = p4, p6
	actual := dns.NewEnhancer(dns.EnhancerConfig{IPv6: true, EnhancedMode: C.DNSFakeIP, FakeIPPool: p4, FakeIPPool6: p6})
	resolver.DefaultHostMapper = actual
	a4, a6 := p4.Lookup("v4.test"), p6.Lookup("v6.test")
	if v := dnsObject(t, e.FlushFakeIP()); v["status"] != "completed" {
		t.Fatal(v)
	}
	if _, ok := p4.LookBack(a4); ok {
		t.Fatal("IPv4 not flushed")
	}
	if _, ok := p6.LookBack(a6); ok {
		t.Fatal("IPv6 not flushed")
	}
	a4, a6 = p4.Lookup("new-v4.test"), p6.Lookup("new-v6.test")
	resolver.DefaultHostMapper = &partialFakeIP{Enhancer: actual, pool: p4}
	v := dnsObject(t, e.FlushFakeIP())
	if v["status"] != "partialOrFailed" {
		t.Fatal(v)
	}
	for _, name := range []string{"ipv4", "ipv6"} {
		if v[name].(map[string]any)["outcome"] != "unconfirmed" {
			t.Fatal("aggregate error falsely attributed to a family", v)
		}
	}
	if _, ok := p4.LookBack(a4); ok {
		t.Fatal("partial mutation did not execute")
	}
	if _, ok := p6.LookBack(a6); !ok {
		t.Fatal("fault fixture did not retain second family")
	}
	resolver.DefaultHostMapper = actual
}

func TestFakeIPPublicPersistentBothFamiliesFlushDoesNotRestoreOldMappings(t *testing.T) {
	const child = "PSEUDO_DNS_PERSISTENT_BOTH_FAMILIES"
	if os.Getenv(child) != "1" {
		command := exec.Command(os.Args[0], "-test.run=^TestFakeIPPublicPersistentBothFamiliesFlushDoesNotRestoreOldMappings$", "-test.count=1")
		if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
			command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
		}
		command.Env = append(os.Environ(), child+"=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("isolated persistent pools: %v\n%s", err, output)
		}
		return
	}
	var e Engine
	home := t.TempDir()
	prepare := func() (*fakeip.Pool, *fakeip.Pool) {
		t.Helper()
		if err := e.Prepare(home, []byte("ipv6: false\nprofile: {store-fake-ip: true}\ndns: {enhanced-mode: fake-ip}\nrules: ['MATCH,DIRECT']\n"), "", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		p4 := e.cfg.DNS.FakeIPPool
		// Exercise the public IPv6 persistent pool independently of host network
		// availability.
		p6, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("fd00:7::/64"), Persistence: true})
		if err != nil {
			t.Fatal(err)
		}
		e.cfg.DNS.FakeIPPool6 = p6
		resolver.DefaultHostMapper = dns.NewEnhancer(dns.EnhancerConfig{IPv6: true, EnhancedMode: C.DNSFakeIP, FakeIPPool: p4, FakeIPPool6: p6})
		return p4, p6
	}
	p4, p6 := prepare()
	defer requireStop(t, &e)
	a4, a6 := p4.Lookup("persist-four.test"), p6.Lookup("persist-six.test")
	if value := dnsObject(t, e.ClearDNSCache()); value["status"] != "completed" {
		t.Fatal(value)
	}
	if _, ok := p4.LookBack(a4); !ok {
		t.Fatal("DNS clear flushed persistent IPv4")
	}
	if _, ok := p6.LookBack(a6); !ok {
		t.Fatal("DNS clear flushed persistent IPv6")
	}
	value := dnsObject(t, e.FlushFakeIP())
	if value["status"] != "completed" || value["persistent"] != true || value["ipv4"].(map[string]any)["active"] != true || value["ipv6"].(map[string]any)["active"] != true {
		t.Fatal(value)
	}
	requireStop(t, &e)
	p4, p6 = prepare()
	if _, ok := p4.LookBack(a4); ok {
		t.Fatal("flushed persistent IPv4 returned")
	}
	if _, ok := p6.LookBack(a6); ok {
		t.Fatal("flushed persistent IPv6 returned")
	}
	if p4.Lookup("new-four.test") != a4 || p6.Lookup("new-six.test") != a6 {
		t.Fatal("persistent allocation state was not reset")
	}
}

// Exercise the public API's private-lock boundary under -race to expose upstream
// offset/cycle writes.
func TestFakeIPPublicConcurrentAllocationLookBackAndFlush(t *testing.T) {
	pool, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("198.18.0.1/16"), Size: 1000})
	if err != nil {
		t.Fatal(err)
	}
	old := resolver.DefaultHostMapper
	resolver.DefaultHostMapper = dns.NewEnhancer(dns.EnhancerConfig{EnhancedMode: C.DNSFakeIP, FakeIPPool: pool})
	defer func() { resolver.DefaultHostMapper = old }()
	start := make(chan struct{})
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		<-start
		for i := 0; i < 3000; i++ {
			ip := pool.Lookup(fmt.Sprintf("race-%d.test", i))
			_, _ = pool.LookBack(ip)
		}
	}()
	go func() {
		defer workers.Done()
		<-start
		for i := 0; i < 3000; i++ {
			if err := resolver.FlushFakeIP(); err != nil {
				t.Error(err)
				return
			}
		}
	}()
	close(start)
	workers.Wait()
}
