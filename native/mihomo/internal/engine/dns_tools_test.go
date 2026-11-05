package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"

	"clashpseudo/native/internal/androidnet"
)

func questionJSON(name, kind string) []byte {
	body, _ := json.Marshal(DNSQuestion{Name: name, Type: kind})
	return body
}
func testDNSPrepare(t *testing.T, e *Engine, config string) {
	t.Helper()
	if config == "" {
		config = "dns: {enable: true, nameserver: [192.0.2.53]}\n"
	}
	if err := e.Prepare(t.TempDir(), []byte("ipv6: false\n"+config+"\nrules: ['MATCH,DIRECT']\n"), "", func(int) bool { return true }); err != nil {
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
	if isolateEngineTest(t) {
		return
	}
	for _, test := range []struct{ name, kind, want string }{
		{"例子.测试", "A", "xn--fsqu00a.xn--0zwm56d."},
		{"_sip._tcp.例子.测试", "SRV", "_sip._tcp.xn--fsqu00a.xn--0zwm56d."},
		{"192.0.2.7", "PTR", "7.2.0.192.in-addr.arpa."},
		{"7.2.0.192.in-addr.arpa", "PTR", "7.2.0.192.in-addr.arpa."},
		{"2001:db8::7", "PTR", "7.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa."},
		{"EXAMPLE.TEST.", "https", "EXAMPLE.TEST."}, {".", "NS", "."},
		{"_dmarc.example.test", "TXT", "_dmarc.example.test."},
		{"_acme-challenge.example.test.", "TXT", "_acme-challenge.example.test."},
		{"_sip._tcp.test", "A", "_sip._tcp.test."},
		{"_sip.tcp.test", "SRV", "_sip.tcp.test."},
		{"_.test", "TXT", "_.test."},
		{"bad.example", "PTR", "bad.example."},
		{"256.2.0.192.in-addr.arpa", "PTR", "256.2.0.192.in-addr.arpa."},
		{"https://example.test", "A", "https://example.test."},
		{"example.test:53", "A", "example.test:53."},
		{"example.test/path", "A", "example.test/path."},
		{"a@example.test", "A", "a@example.test."},
		{" example.test", "A", " example.test."},
		{"example.test\n", "A", "example.test\n."},
		{"example.test\x00", "A", "example.test\x00."},
	} {
		q, _, err := normalizeDNSQuestion(questionJSON(test.name, test.kind))
		if err != nil || q.Name != test.want {
			t.Fatalf("%s %s: %+v %v", test.name, test.kind, q, err)
		}
	}
	for _, test := range []DNSQuestion{{Name: "a..test", Type: "A"}, {Name: strings.Repeat("a", 64) + ".test", Type: "A"}, {Name: strings.Repeat("a", 1025), Type: "A"}, {Name: "example.test", Type: "AXFR"}, {Name: "example.test", Type: "IXFR"}, {Name: "", Type: "A"}} {
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
	if isolateEngineTest(t) {
		return
	}
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
		value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON(name, kind)))
		if value["error"] != nil || value["rcode"] != float64(0) || len(value["answer"].([]any)) != 1 {
			t.Fatalf("%s: %+v", kind, value)
		}
		rr := value["answer"].([]any)[0].(map[string]any)
		if rr["type"] != kind || rr["class"] != "IN" || rr["ttl"] == nil || rr["data"] == "" {
			t.Fatalf("RR lost data: %+v", rr)
		}
	}
	value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("missing.test", "A")))
	if value["error"] != nil || value["rcode"] != float64(3) || value["rcodeName"] != "NXDOMAIN" || len(value["answer"].([]any)) != 0 {
		t.Fatal("NXDOMAIN treated as transport failure", value)
	}
	before := requests.Load()
	_ = e.DNSQueryContext(context.Background(), questionJSON("cache.test", "A"))
	_ = e.DNSQueryContext(context.Background(), questionJSON("cache.test", "A"))
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
	_ = e.DNSQueryContext(context.Background(), questionJSON("cache.test", "A"))
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
	_ = e.DNSQueryContext(context.Background(), questionJSON("cache.test", "A"))
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
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	testDNSPrepare(t, &e, "")
	e.systemDNS = androidnet.NewNetworkResolver(androidnet.NetworkDNS{ID: "original", APILevel: 29}, androidnet.DNSOwner{ID: e.owner.id, Revoked: e.owner.ctx, Stopped: ErrStopped, RawQuery: func(context.Context, []byte) ([]byte, error) { return nil, errors.New("cache-only fixture") }})
	if e.systemDNS.CaptureCache(e.owner.id) == nil {
		t.Fatal("original network did not expose its actual cache operation")
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }) })
	resolver.DefaultResolver = &functionDNS{clear: func() { close(entered); <-release }}
	finished := make(chan string, 1)
	go func() { finished <- e.ClearDNSCache() }()
	<-entered
	// Network变化由平台撤销本次owner；已受理cache调用仍等待其捕获的公开调用返回。
	e.Cancel()
	releaseOnce.Do(func() { close(release) })
	if value := dnsObject(t, <-finished); value["error"] != nil || value["status"] != "completed" || value["stale"] != true || value["resolverActive"] != true || value["systemResolverActive"] != true {
		t.Fatal("actual cache clears were replaced by a network identity error", value)
	}
}

func TestDNSQueryRealGateCancellationNetworkIdentityAndStopDrain(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, action := range []string{"cancel", "network", "stop"} {
		t.Run(action, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			testDNSPrepare(t, &e, "")
			entered, release := make(chan struct{}), make(chan struct{})
			resolver.DefaultResolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
				close(entered)
				<-release
				return new(D.Msg).SetReply(q), nil
			}}
			finished := make(chan string, 1)
			go func() {
				finished <- e.DNSQueryContext(context.Background(), []byte(`{"name":"late.test","type":"A","requestId":"123"}`))
			}()
			<-entered
			if value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("second.test", "A"))); value["error"] != "busy" {
				t.Fatal("parallel call entered", value)
			}
			var stopped chan error
			switch action {
			case "cancel":
				e.CancelDNSRequest(123)
			case "network":
				e.Cancel()
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
			if value["error"] != nil || value["rcode"] != float64(0) {
				t.Fatal("actual resolver success was replaced after interruption", action, value)
			}
			if (value["stale"] == true) != (action != "cancel") {
				t.Fatal("source identity was not reported separately", action, value)
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

func TestDNSActualErrorsSurviveCancellationNetworkChangesAndStop(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	const original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
	for _, action := range []string{"none", "cancel", "network", "stop"} {
		for _, failure := range []error{errors.New(original), fmt.Errorf("%s: %w", original, context.Canceled), fmt.Errorf("%s: %w", original, context.DeadlineExceeded)} {
			t.Run(action+failure.Error(), func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}
				var e Engine
				testDNSPrepare(t, &e, "")
				entered, release := make(chan struct{}), make(chan struct{})
				resolver.DefaultResolver = &functionDNS{exchange: func(context.Context, *D.Msg) (*D.Msg, error) {
					close(entered)
					<-release
					return nil, failure
				}}
				finished := make(chan string, 1)
				go func() {
					finished <- e.DNSQueryContext(context.Background(), []byte(`{"name":"late.test","type":"A","requestId":"123"}`))
				}()
				<-entered
				var stopped chan error
				switch action {
				case "cancel":
					e.CancelDNSRequest(123)
				case "network":
					e.Cancel()
				case "stop":
					e.Cancel()
					stopped = make(chan error, 1)
					go func() { stopped <- e.Stop() }()
				}
				if e.dnsOperation.Load() == nil {
					t.Fatal("interruption released the actual resolver gate")
				}
				close(release)
				value := dnsObject(t, <-finished)
				want := "queryFailed"
				if errors.Is(failure, context.Canceled) {
					want = "cancelled"
				} else if errors.Is(failure, context.DeadlineExceeded) {
					want = "timeout"
				}
				if value["error"] != want || value["detail"] != failure.Error() {
					t.Fatal("actual resolver error was replaced", value)
				}
				if stopped != nil {
					if err := <-stopped; err != nil {
						t.Fatal(err)
					}
				}
				if e.dnsOperation.Load() != nil {
					t.Fatal("actual completion retained the resolver gate")
				}
			})
		}
	}
}

func TestDNSProjectsRecordsAndKeepsQuestionCase(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	testDNSPrepare(t, &e, "")
	var returned *D.Msg
	resolver.DefaultResolver = &functionDNS{exchange: func(_ context.Context, question *D.Msg) (*D.Msg, error) {
		returned = new(D.Msg).SetReply(question)
		returned.Id = 0xbeef
		returned.Authoritative = true
		returned.AuthenticatedData = true
		returned.CheckingDisabled = true
		returned.RecursionAvailable = true
		returned.Answer = []D.RR{&D.TXT{Hdr: D.RR_Header{Name: question.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET, Ttl: 0xffffffff},
			Txt: []string{"https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"}}}
		return returned, nil
	}}
	value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("MiXeD.example", "TXT")))
	if value["error"] != nil || value["question"].(map[string]any)["name"] != "MiXeD.example." {
		t.Fatal("DNS question was rewritten", value)
	}
	answer := value["answer"].([]any)[0].(map[string]any)
	rr := returned.Answer[0]
	if answer["name"] != rr.Header().Name || answer["type"] != "TXT" || answer["class"] != "IN" || answer["ttl"] != float64(0xffffffff) || answer["data"] != strings.TrimPrefix(rr.String(), rr.Header().String()) {
		t.Fatal("DNS record fields were lost", answer)
	}
	if _, ok := value["message"]; ok {
		t.Fatal("complete DNS message was retained")
	}
}

func TestDNSPartialMessageAndActualErrorAreBothRetained(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	const original = "https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"
	for _, cause := range []error{errors.New(original), fmt.Errorf("%s: %w", original, context.Canceled), fmt.Errorf("%s: %w", original, context.DeadlineExceeded)} {
		var e Engine
		testDNSPrepare(t, &e, "")
		var returned D.RR
		resolver.DefaultResolver = &functionDNS{exchange: func(_ context.Context, question *D.Msg) (*D.Msg, error) {
			message := new(D.Msg).SetReply(question)
			message.Truncated = true
			returned = &D.TXT{Hdr: D.RR_Header{Name: question.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET, Ttl: 60}, Txt: []string{original}}
			message.Answer = []D.RR{returned}
			return message, cause
		}}
		value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("Partial.Example", "TXT")))
		want := "queryFailed"
		if errors.Is(cause, context.Canceled) {
			want = "cancelled"
		}
		if errors.Is(cause, context.DeadlineExceeded) {
			want = "timeout"
		}
		if value["error"] != want || value["detail"] != cause.Error() || value["truncated"] != true {
			t.Fatal("partial DNS message replaced its actual error", value)
		}
		answer := value["answer"].([]any)[0].(map[string]any)
		if answer["name"] != "Partial.Example." || answer["type"] != "TXT" || answer["class"] != "IN" || answer["ttl"] != float64(60) || answer["data"] != strings.TrimPrefix(returned.String(), returned.Header().String()) {
			t.Fatal("partial DNS record fields were lost", answer)
		}
		if _, ok := value["message"]; ok {
			t.Fatal("complete partial DNS message was retained")
		}
		requireStop(t, &e)
	}
}

func TestDNSResultRejectionKeepsOriginalCauseWithoutRetainingOversizedMessage(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	testDNSPrepare(t, &e, "")
	for _, mode := range []string{"records", "bytes", "oversizedCause"} {
		t.Run(mode, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			detail := "resolver failed\nCaused by: original transport\nSuppressed: close failed"
			if mode == "oversizedCause" {
				detail += strings.Repeat("域名解析失败🙂", MaxDNSResult/4)
			}
			cause := errors.New(detail)
			resolver.DefaultResolver = &functionDNS{exchange: func(_ context.Context, q *D.Msg) (*D.Msg, error) {
				message := new(D.Msg).SetReply(q)
				if mode == "records" {
					for index := 0; index < MaxDNSRecords+1; index++ {
						rr := &D.A{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeA, Class: D.ClassINET}}
						switch index % 3 {
						case 0:
							message.Answer = append(message.Answer, rr)
						case 1:
							message.Ns = append(message.Ns, rr)
						case 2:
							message.Extra = append(message.Extra, rr)
						}
					}
				} else if mode == "bytes" {
					message.Answer = []D.RR{&D.TXT{Hdr: D.RR_Header{Name: q.Question[0].Name, Rrtype: D.TypeTXT, Class: D.ClassINET}, Txt: []string{strings.Repeat("x", MaxDNSResult)}}}
				}
				return message, cause
			}}
			wire := e.DNSQueryContext(context.Background(), questionJSON("limit.test", "TXT"))
			value := dnsObject(t, wire)
			if value["error"] != "resultTooLarge" || value["detail"] != detail {
				t.Fatal("result rejection changed or dropped the original cause")
			}
			for _, field := range []string{"message", "answer", "authority", "additional"} {
				if _, ok := value[field]; ok {
					t.Fatalf("rejected result retained %s", field)
				}
			}
			if mode == "oversizedCause" && len(wire) <= MaxDNSResult {
				t.Fatal("oversized native diagnostic was truncated instead of passed to bridge rejection")
			}
		})
	}
}

func TestDNSCancellationBeforeEntryCannotCancelANewerRequest(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	testDNSPrepare(t, &e, "")
	var entered atomic.Int64
	resolver.DefaultResolver = &functionDNS{exchange: func(ctx context.Context, q *D.Msg) (*D.Msg, error) {
		entered.Add(1)
		return new(D.Msg).SetReply(q), nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	e.CancelDNSRequest(9)
	if value := dnsObject(t, e.DNSQueryContext(ctx, []byte(`{"name":"test.test","type":"A","requestId":"9"}`))); value["error"] != "cancelled" || entered.Load() != 0 {
		t.Fatal(value, entered.Load())
	}
	if value := dnsObject(t, e.DNSQueryContext(context.Background(), []byte(`{"name":"test.test","type":"A","requestId":"8"}`))); value["error"] != nil || entered.Load() != 1 {
		t.Fatal("old cancellation affected new request", value, entered.Load())
	}
}

func TestDNSDisabledAndOutputLimitsDoNotOpenAnAlternativeResolver(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, mode := range []string{"disabled", "records", "bytes", "truncated", "timeout"} {
		t.Run(mode, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			if mode == "disabled" {
				testDNSPrepare(t, &e, "dns: {enable: false}\n")
				if value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("unavailable.test", "A"))); value["error"] != "unavailable" {
					t.Fatal(value)
				}
				if value := dnsObject(t, e.FlushFakeIP()); value["status"] != "empty" {
					t.Fatal(value)
				}
				return
			}
			testDNSPrepare(t, &e, "")
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
			value := dnsObject(t, e.DNSQueryContext(context.Background(), questionJSON("limit.test", "A")))
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
		})
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
	if isolateEngineTest(t) {
		return
	}
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
	if v["status"] != "partialOrFailed" || v["detail"] != "second family public flush failed" {
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
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		runEnginePhase(t, home, "flush")
		runEnginePhase(t, home, "reopen")
		return
	}
	var e Engine
	if err := e.Prepare(home, []byte("ipv6: false\nprofile: {store-fake-ip: true}\ndns: {enable: true, enhanced-mode: fake-ip}\nrules: ['MATCH,DIRECT']\n"), "", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	p4 := e.cfg.DNS.FakeIPPool
	p6, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("fd00:7::/64"), Persistence: true})
	if err != nil {
		t.Fatal(err)
	}
	e.cfg.DNS.FakeIPPool6 = p6
	resolver.DefaultHostMapper = dns.NewEnhancer(dns.EnhancerConfig{IPv6: true, EnhancedMode: C.DNSFakeIP, FakeIPPool: p4, FakeIPPool6: p6})
	var state struct{ IPv4, IPv6 netip.Addr }
	path := filepath.Join(home, "both-families.json")
	if phase == "flush" {
		state.IPv4, state.IPv6 = p4.Lookup("persist-four.test"), p6.Lookup("persist-six.test")
		if value := dnsObject(t, e.ClearDNSCache()); value["status"] != "completed" {
			t.Fatal(value)
		}
		if _, ok := p4.LookBack(state.IPv4); !ok {
			t.Fatal("DNS clear flushed persistent IPv4")
		}
		if _, ok := p6.LookBack(state.IPv6); !ok {
			t.Fatal("DNS clear flushed persistent IPv6")
		}
		value := dnsObject(t, e.FlushFakeIP())
		if value["status"] != "completed" || value["persistent"] != true || value["ipv4"].(map[string]any)["active"] != true || value["ipv6"].(map[string]any)["active"] != true {
			t.Fatal(value)
		}
		data, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(data, &state); err != nil {
		t.Fatal(err)
	}
	if _, ok := p4.LookBack(state.IPv4); ok {
		t.Fatal("flushed persistent IPv4 returned")
	}
	if _, ok := p6.LookBack(state.IPv6); ok {
		t.Fatal("flushed persistent IPv6 returned")
	}
	if p4.Lookup("new-four.test") != state.IPv4 || p6.Lookup("new-six.test") != state.IPv6 {
		t.Fatal("persistent allocation state was not reset")
	}
}

// Exercise the public API's private-lock boundary under -race to expose upstream
// offset/cycle writes.
func TestFakeIPPublicConcurrentAllocationLookBackAndFlush(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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

func TestDNSOwnerNamesUseDNSGrammarAcrossRecordTypes(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, kind := range []string{"A", "AAAA", "CNAME", "MX", "TXT", "NS", "SOA", "PTR", "SRV", "HTTPS", "SVCB", "CAA"} {
		for _, name := range []string{"_", "__owner", "some_owner.example", "_service._tcp._zone.example", "-owner.example", "owner-.example", "*.example", "."} {
			t.Run(kind+"/"+name, func(t *testing.T) {
				q, code, err := normalizeDNSQuestion(questionJSON(name, strings.ToLower(kind)))
				if err != nil || q.Type != kind || code != dnsTypes[kind] || q.Name != D.Fqdn(name) {
					t.Fatalf("a valid owner was restricted as a host: type=%s name=%q err=%v", kind, name, err)
				}
				msg := new(D.Msg)
				msg.SetQuestion(q.Name, code)
				wire, err := msg.Pack()
				if err != nil {
					t.Fatal(err)
				}
				var decoded D.Msg
				if decoded.Unpack(wire) != nil || len(decoded.Question) != 1 || decoded.Question[0].Name != q.Name {
					t.Fatal("the actual DNS question was changed during wire packing")
				}
			})
		}
	}
}

func TestDNSNamesKeepLookupIDNAOriginalCaseAndExplicitEscapes(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, item := range []struct{ name, kind, expected string }{
		{"BÜCHER。Example", "A", "xn--bcher-kva.Example."},
		{"_service.BÜCHER.example", "SRV", "_service.xn--bcher-kva.example."},
		{`one\.label.Example`, "TXT", `one\.label.Example.`},
		{`one\046label.Example`, "TXT", `one\046label.Example.`},
		{"192.0.2.1", "PTR", "1.2.0.192.in-addr.arpa."},
		{"_services._dns-sd._udp.local", "PTR", "_services._dns-sd._udp.local."},
		{"32-63.2.0.192.in-addr.arpa", "PTR", "32-63.2.0.192.in-addr.arpa."},
	} {
		t.Run(item.name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			q, _, err := normalizeDNSQuestion(questionJSON(item.name, item.kind))
			if err != nil || q.Name != item.expected {
				t.Fatalf("normalization: got=%q want=%q err=%v", q.Name, item.expected, err)
			}
		})
	}
	name := strings.Repeat("ä", 40) + ".example"
	if _, _, err := normalizeDNSQuestion(questionJSON(name, "A")); err != nil {
		t.Fatal("UTF-8 label length must not reject a valid shorter IDNA wire name")
	}
}

func TestDNSOwnerWireAndInputBudgetsAreIndependent(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	maximum := strings.Repeat("a", 63) + "." + strings.Repeat("b", 63) + "." + strings.Repeat("c", 63) + "." + strings.Repeat("d", 61)
	q, _, err := normalizeDNSQuestion(questionJSON(maximum, "TXT"))
	if err != nil {
		t.Fatal(err)
	}
	var wire [256]byte
	length, err := D.PackDomainName(q.Name, wire[:], 0, nil, false)
	if err != nil || length != 255 {
		t.Fatal("the actual maximum wire name was not accepted")
	}
	for _, name := range []string{maximum + "d", strings.Repeat("a", 64) + ".example", strings.Repeat("a", 1025)} {
		if _, _, err := normalizeDNSQuestion(questionJSON(name, "TXT")); err == nil {
			t.Fatal("a raw or wire name overflow was accepted")
		}
	}
	body := questionJSON("owner.example", "TXT")
	body = append(body, []byte(strings.Repeat(" ", MaxDNSRequest+1-len(body)))...)
	if !json.Valid(body) {
		t.Fatal("request overflow fixture must remain valid JSON")
	}
	if _, _, err := normalizeDNSQuestion(body); err == nil {
		t.Fatal("raw request budget was not enforced")
	}
}

func TestDNSOwnerBadWireLabelsAndUnrepresentableEncodingRemainRejected(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"", ".owner.example", "one..example", "owner..", `trailing\`, `bad\999.example`, `bad\256.example`, `bad\12.example`, `bad\12x.example`} {
		if _, _, err := normalizeDNSQuestion(questionJSON(name, "TXT")); err == nil {
			t.Errorf("invalid owner was accepted: %q", name)
		}
	}
	invalid := append([]byte(`{"name":"`), 0xff)
	invalid = append(invalid, []byte(`","type":"A"}`)...)
	if _, _, err := normalizeDNSQuestion(invalid); err == nil {
		t.Fatal("invalid UTF-8 was accepted")
	}
	if _, _, err := normalizeDNSQuestion(questionJSON("owner.example", "AXFR")); err == nil {
		t.Fatal("unsupported record type was accepted")
	}
}
