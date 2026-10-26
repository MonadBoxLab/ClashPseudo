package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type delayLoopbackDialer struct{ wrap func(net.Conn) net.Conn }

func (d *delayLoopbackDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil || !ip.IsLoopback() {
		return nil, errors.New("probe fixture refuses non-loopback transport")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, network, address)
	if err == nil && d.wrap != nil {
		conn = d.wrap(conn)
	}
	return conn, err
}
func (*delayLoopbackDialer) ListenPacket(context.Context, string, string, netip.AddrPort) (net.PacketConn, error) {
	return nil, errors.New("HEAD probe fixture does not use UDP")
}

type delayLoopbackAdapter struct {
	*outbound.Base
	dialer *delayLoopbackDialer
}

func (a *delayLoopbackAdapter) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	conn, err := a.dialer.DialContext(ctx, "tcp", metadata.RemoteAddress())
	if err != nil {
		return nil, err
	}
	return outbound.NewConn(conn, a), nil
}
func publicDelayProxy(t *testing.T, dialer *delayLoopbackDialer) C.Proxy {
	t.Helper()
	// Supply loopback sockets through public Base/NewConn; upstream performs URLTest
	// HTTP, deadlines and history.
	proxy := adapter.NewProxy(&delayLoopbackAdapter{Base: outbound.NewBase(outbound.BaseOption{Name: "member", Type: C.Direct}), dialer: dialer})
	t.Cleanup(func() {
		if err := proxy.Close(); err != nil {
			t.Error(err)
		}
	})
	return proxy
}
func assertPublicDelayHistory(t *testing.T, p C.Proxy, target string, delay uint16, globalAlive, urlAlive bool) {
	t.Helper()
	global, perURL := p.DelayHistory(), p.ExtraDelayHistories()[target].History
	if len(global) != 1 || len(perURL) != 1 {
		t.Fatal("public history missing", global, perURL)
	}
	wantGlobal, wantURL := delay, delay
	if !globalAlive {
		wantGlobal = 0
	}
	if !urlAlive {
		wantURL = 0
	}
	if global[0].Delay != wantGlobal || perURL[0].Delay != wantURL || p.AliveForTestUrl("") != globalAlive || p.AliveForTestUrl(target) != urlAlive {
		t.Fatalf("public global and URL-specific histories were conflated: global=%+v url=%+v alive=%v/%v", global, perURL, p.AliveForTestUrl(""), p.AliveForTestUrl(target))
	}
}

func TestPublicURLTestHTTPStatusRedirectAndHistoryContract(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(false)
	defer adapter.UnifiedDelay.Store(old)
	for _, test := range []struct {
		name     string
		status   int
		expected utils.IntRanges[uint16]
		urlAlive bool
	}{
		{"204", 204, delayExpected, true}, {"non204", 200, delayExpected, false}, {"non204-unrestricted", 500, nil, true}, {"redirect", 302, delayExpected, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			var redirected atomic.Int64
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path == "/followed" {
					redirected.Add(1)
					w.WriteHeader(204)
					return
				}
				if r.Method != "HEAD" {
					t.Errorf("public probe method %s", r.Method)
				}
				w.Header().Set("Location", "/followed")
				w.WriteHeader(test.status)
			}))
			defer server.Close()
			proxy := publicDelayProxy(t, &delayLoopbackDialer{})
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			delay, err := proxy.URLTest(ctx, server.URL, test.expected)
			if err != nil {
				t.Fatal("HTTP response status is not a transport error", err)
			}
			if redirected.Load() != 0 {
				t.Fatal("public probe unexpectedly followed redirects")
			}
			assertPublicDelayHistory(t, proxy, server.URL, delay, true, test.urlAlive)
		})
	}
}

func TestPublicURLTestDeadlineRecordsFailure(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(false)
	defer adapter.UnifiedDelay.Store(old)
	entered := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(entered); <-r.Context().Done() }))
	defer server.Close()
	proxy := publicDelayProxy(t, &delayLoopbackDialer{})
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	delay, err := proxy.URLTest(ctx, server.URL, delayExpected)
	select {
	case <-entered:
	default:
		t.Fatal("deadline did not hold a real HTTP request")
	}
	if err == nil || !errors.Is(ctx.Err(), context.DeadlineExceeded) {
		t.Fatal("public request deadline was lost", delay, err, ctx.Err())
	}
	assertPublicDelayHistory(t, proxy, server.URL, delay, false, false)
}

func TestPublicURLTestUnifiedSecondFailurePreservesActualHistoryContract(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(true)
	defer adapter.UnifiedDelay.Store(old)
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.WriteHeader(204)
			return
		}
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		_ = conn.Close()
	}))
	defer server.Close()
	proxy := publicDelayProxy(t, &delayLoopbackDialer{})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	delay, err := proxy.URLTest(ctx, server.URL, delayExpected)
	if requests.Load() < 2 || err != nil || ctx.Err() != nil {
		t.Fatal("fixed public unified second-failure premise changed", requests.Load(), delay, err, ctx.Err())
	}
	// v1.19.32 ignores that second transport error and retains its first 204.
	assertPublicDelayHistory(t, proxy, server.URL, delay, true, true)
}

func TestDelayProjectionUsesPublicURLTestWithoutAddingStatusFailurePolicy(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(false)
	defer adapter.UnifiedDelay.Store(old)
	for _, status := range []int{204, 200, 302} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Location", "/other")
				w.WriteHeader(status)
			}))
			defer server.Close()
			actual := publicDelayProxy(t, &delayLoopbackDialer{})
			proxy := &delayProxyFixture{Proxy: actual, name: "member", adapter: actual.Adapter(), publicProbe: func(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
				if target != C.DefaultTestURL || !reflect.DeepEqual(expected, delayExpected) {
					t.Error("application changed the public probe arguments")
				}
				return actual.URLTest(ctx, server.URL, expected)
			}}
			e, _ := delayEngineFixture(proxy)
			id, err := e.StartDelayTest("group", nil)
			if err != nil {
				t.Fatal(err)
			}
			awaitDelayFixture(t, e.delays[id])
			value := readDelayFixture(t, e, id)
			if value.Members[0].Status != "success" {
				t.Fatal("application invented a non-204 failure policy", status, value)
			}
			history := actual.DelayHistory()
			if len(history) != 1 || value.Members[0].Delay != int(history[0].Delay) {
				t.Fatal("projection is not the actual public measurement", value, history)
			}
			assertPublicDelayHistory(t, actual, server.URL, history[0].Delay, true, status == 204)
		})
	}
}

func TestDelayProjectionDeadlineWinsOverRealUnifiedSecondTimeout(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(true)
	defer adapter.UnifiedDelay.Store(old)
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			w.WriteHeader(204)
			return
		}
		<-r.Context().Done()
	}))
	defer server.Close()
	actual := publicDelayProxy(t, &delayLoopbackDialer{})
	proxy := &delayProxyFixture{Proxy: actual, name: "member", adapter: actual.Adapter(), publicProbe: func(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
		return actual.URLTest(ctx, server.URL, expected)
	}}
	e, _ := delayEngineFixture(proxy)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-e.delays[id].done:
	case <-time.After(delayTestTimeout + 3*time.Second):
		t.Fatal("real unified second deadline did not drain")
	}
	value := readDelayFixture(t, e, id)
	if requests.Load() < 2 || value.Members[0].Status != "timeout" || value.Members[0].Delay != 0 {
		t.Fatal("public nil-error first response defeated application deadline", requests.Load(), value)
	}
	history := actual.DelayHistory()
	if len(history) != 1 || history[0].Delay < uint16(delayTestTimeout/time.Millisecond) {
		t.Fatal("controlled public unified timeout did not occur", history)
	}
	assertPublicDelayHistory(t, actual, server.URL, history[0].Delay, true, true)
}

func TestDelayBatchStopsWithSession(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("proxy-groups:\n - {name: stop-fixture, type: select, proxies: [REJECT]}\nrules:\n - MATCH,DIRECT\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	id, err := e.StartDelayTest("stop-fixture", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.DelayTest("missing"); err == nil {
		t.Fatal("unknown batch accepted")
	}
	e.CancelDelayTest(id)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if _, err := e.StartDelayTest("GLOBAL", nil); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}

func TestDelayBatchSnapshotIsIsolated(t *testing.T) {
	batch := &delayBatch{id: "x", group: "g", state: "running", started: time.Now(),
		done: make(chan struct{}), members: []DelayMember{{Name: "a", Status: "pending"}},
		results: []delayResult{{status: "pending"}}}
	snapshot := batch.snapshot()
	if snapshot.Members[0].Status != "pending" || snapshot.Target == "" {
		t.Fatal(snapshot)
	}
	batch.set(0, "success", 42)
	updated := batch.snapshot()
	if updated.Members[0].Status != "success" || updated.Members[0].Delay != 42 {
		t.Fatal(updated)
	}
	if snapshot.Members[0].Status != "pending" {
		t.Fatal("earlier snapshot mutated")
	}
	batch.finish(true)
	if batch.snapshot().State != "cancelled" {
		t.Fatal("cancel not reflected")
	}
}

// A worker publishes "running" before probing; the settled result must still
// replace it, or every member stays "Testing" after the batch reports done.
func TestDelayBatchAcceptsResultAfterRunning(t *testing.T) {
	batch := &delayBatch{id: "x", group: "g", state: "running", started: time.Now(),
		done: make(chan struct{}), members: []DelayMember{{Name: "a", Status: "pending"}},
		results: []delayResult{{status: "pending"}}}
	batch.mu.Lock()
	batch.results[0].status = "running"
	batch.mu.Unlock()
	batch.set(0, "timeout", 0)
	batch.finish(false)
	snapshot := batch.snapshot()
	if snapshot.State != "done" || snapshot.Members[0].Status != "timeout" {
		t.Fatal(snapshot)
	}
	batch.set(0, "success", 7)
	if again := batch.snapshot(); again.Members[0].Status != "timeout" {
		t.Fatal("settled result overwritten")
	}
}

type delayProxyFixture struct {
	C.Proxy
	name        string
	probe       func(context.Context) (uint16, error)
	publicProbe func(context.Context, string, utils.IntRanges[uint16]) (uint16, error)
	onClose     func() error
	adapter     C.ProxyAdapter
}

func (p *delayProxyFixture) Name() string            { return p.name }
func (p *delayProxyFixture) Type() C.AdapterType     { return C.Direct }
func (p *delayProxyFixture) Adapter() C.ProxyAdapter { return p.adapter }
func (p *delayProxyFixture) URLTest(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
	if p.publicProbe != nil {
		return p.publicProbe(ctx, target, expected)
	}
	return p.probe(ctx)
}
func (p *delayProxyFixture) Close() error {
	if p.onClose != nil {
		return p.onClose()
	}
	if p.Proxy != nil {
		return p.Proxy.Close()
	}
	return nil
}

type delayGroupFixture struct {
	C.ProxyAdapter
	members []C.Proxy
}

func (g *delayGroupFixture) Name() string       { return "group" }
func (g *delayGroupFixture) Proxies() []C.Proxy { return g.members }

func delayEngineFixture(members ...C.Proxy) (*Engine, *delayGroupFixture) {
	group := &delayGroupFixture{members: members}
	owner := &socketOwner{}
	owner.active.Store(true)
	return &Engine{owner: owner, cfg: &config.Config{Proxies: map[string]C.Proxy{
		"group": &delayProxyFixture{name: "group", adapter: group},
	}}, delays: make(map[string]*delayBatch)}, group
}

func readDelayFixture(t *testing.T, e *Engine, id string) DelayBatch {
	t.Helper()
	body, err := e.DelayTest(id)
	if err != nil {
		t.Fatal(err)
	}
	var value DelayBatch
	if err = json.Unmarshal([]byte(body), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func awaitDelayFixture(t *testing.T, batch *delayBatch) {
	t.Helper()
	select {
	case <-batch.done:
	case <-time.After(time.Second):
		t.Fatal("batch did not finish")
	}
}

func TestDelayRejectsOverlappingBatchUntilCancelledProbeExits(t *testing.T) {
	entered, release := make(chan struct{}, 8), make(chan struct{})
	proxy := &delayProxyFixture{name: "member", probe: func(context.Context) (uint16, error) {
		entered <- struct{}{}
		<-release
		return 12, nil
	}}
	e, _ := delayEngineFixture(proxy)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	batch := e.delays[id]
	defer func() { close(release); awaitDelayFixture(t, batch) }()
	<-entered
	if _, err := e.StartDelayTest("group", nil); err == nil {
		t.Error("overlapping batch accepted")
	}
	e.CancelDelayTest(id)
	if _, err := e.StartDelayTest("group", nil); err == nil {
		t.Error("new batch accepted before cancelled probe exits")
	}
}

func TestDelayResultKeepsProxyIdentityAndExpiresSameNameReplacement(t *testing.T) {
	old := &delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) { return 12, nil }}
	e, group := delayEngineFixture(old)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	batch := e.delays[id]
	awaitDelayFixture(t, batch)
	if got := readDelayFixture(t, e, id); got.Members[0].Status != "success" {
		t.Fatal(got)
	}
	batch.mu.Lock()
	identity := batch.results[0].proxy
	batch.mu.Unlock()
	if identity != old {
		t.Error("settled result lost its proxy identity")
	}
	group.members = []C.Proxy{&delayProxyFixture{name: "same", probe: old.probe}}
	got := readDelayFixture(t, e, id)
	if got.State != "expired" || got.Members[0].Status != "expired" || got.Members[0].Delay != 0 {
		t.Fatalf("old result attached to replacement: %+v", got)
	}
}

func TestDelayBatchDeduplicatesSameNameMembers(t *testing.T) {
	var calls atomic.Int32
	proxy := &delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) { calls.Add(1); return 1, nil }}
	e, _ := delayEngineFixture(proxy, proxy)
	id, err := e.StartDelayTest("group", []string{"same"})
	if err != nil {
		t.Fatal(err)
	}
	awaitDelayFixture(t, e.delays[id])
	if got := readDelayFixture(t, e, id); len(got.Members) != 1 || calls.Load() != 1 {
		t.Fatal(got, calls.Load())
	}
}

func TestDelayBatchDeadlineMapsUnfinishedMembersToTimeout(t *testing.T) {
	ctx, cancel := context.WithDeadline(context.Background(), time.Now().Add(-time.Second))
	defer cancel()
	batch := &delayBatch{id: "x", state: "running", done: make(chan struct{}),
		members: []DelayMember{{Name: "a"}}, results: []delayResult{{status: "pending"}}}
	runDelayBatch(ctx, batch)
	got := batch.snapshot()
	if got.State != "done" || got.Members[0].Status != "timeout" {
		t.Fatal(got)
	}
}

func TestDelayMemberDeadlineWinsOverNilProbeError(t *testing.T) {
	var elapsed time.Duration
	proxy := &delayProxyFixture{name: "member", probe: func(ctx context.Context) (uint16, error) {
		started := time.Now()
		<-ctx.Done()
		elapsed = time.Since(started)
		// v1.19.32 unified-delay can ignore the second request's error.
		return 12, nil
	}}
	e, _ := delayEngineFixture(proxy)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-e.delays[id].done:
	case <-time.After(7 * time.Second):
		t.Fatal("five-second member deadline did not finish")
	}
	got := readDelayFixture(t, e, id)
	if elapsed < delayTestTimeout || got.State != "done" || got.Members[0].Status != "timeout" || got.Members[0].Delay != 0 {
		t.Fatalf("deadline accepted nil-error delay after %s: %+v", elapsed, got)
	}
}

type delayProviderFixture struct {
	P.ProxyProvider
	version uint32
	members []C.Proxy
}

func (p *delayProviderFixture) Version() uint32    { return p.version }
func (p *delayProviderFixture) Proxies() []C.Proxy { return p.members }

type delayProviderGroupFixture struct {
	C.ProxyAdapter
	providers []P.ProxyProvider
}

func (g *delayProviderGroupFixture) Providers() []P.ProxyProvider { return g.providers }

func TestDelaySubgroupProviderChangesExpireRunningDoneAndLateResults(t *testing.T) {
	for _, state := range []string{"running", "done", "late"} {
		for _, replacement := range []string{"version", "identity"} {
			t.Run(state+"/"+replacement, func(t *testing.T) {
				entered, release := make(chan struct{}), make(chan struct{})
				var calls atomic.Int32
				leaf := &delayProxyFixture{name: "same"}
				provider := &delayProviderFixture{version: 1, members: []C.Proxy{leaf}}
				childGroup := &delayProviderGroupFixture{providers: []P.ProxyProvider{provider}}
				// A second subgroup covers transitive public-provider dependencies.
				child := &delayProxyFixture{name: "child", adapter: childGroup}
				outerProvider := &delayProviderFixture{version: 1, members: []C.Proxy{child}}
				member := &delayProxyFixture{name: "subgroup", adapter: &delayProviderGroupFixture{providers: []P.ProxyProvider{outerProvider}}, probe: func(context.Context) (uint16, error) {
					calls.Add(1)
					close(entered)
					<-release
					return 17, nil
				}}
				e, _ := delayEngineFixture(member)
				id, err := e.StartDelayTest("group", nil)
				if err != nil {
					t.Fatal(err)
				}
				batch := e.delays[id]
				<-entered
				if state == "done" {
					close(release)
					awaitDelayFixture(t, batch)
				}
				if replacement == "identity" {
					childGroup.providers = []P.ProxyProvider{&delayProviderFixture{version: 1, members: []C.Proxy{leaf}}}
				} else {
					provider.version++
					provider.members = []C.Proxy{&delayProxyFixture{name: "same"}}
				}
				if state == "late" {
					close(release)
					awaitDelayFixture(t, batch)
				}
				got := readDelayFixture(t, e, id)
				if state == "running" {
					close(release)
					awaitDelayFixture(t, batch)
				}
				if got.State != "expired" || got.Members[0].Status != "expired" || got.Members[0].Delay != 0 {
					t.Errorf("subgroup retained stale provider result: %+v", got)
				}
				if again := readDelayFixture(t, e, id); again.State != "expired" || again.Members[0].Delay != 0 {
					t.Errorf("late reply revived expired subgroup: %+v", again)
				}
				if calls.Load() != 1 {
					t.Errorf("recursive probes were started: %d", calls.Load())
				}
			})
		}
	}
}

func TestDelayCancelReleasesCompletedBatch(t *testing.T) {
	proxy := &delayProxyFixture{name: "member", probe: func(context.Context) (uint16, error) { return 1, nil }}
	e, _ := delayEngineFixture(proxy)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	awaitDelayFixture(t, e.delays[id])
	e.CancelDelayTest(id)
	if _, err := e.DelayTest(id); err == nil {
		t.Fatal("cancelled completed batch retained")
	}
}

type delayCloseBarrierConn struct {
	net.Conn
	entered chan struct{}
	release chan struct{}
	once    sync.Once
	err     error
}

func (c *delayCloseBarrierConn) Close() error {
	c.once.Do(func() { close(c.entered); <-c.release; c.err = c.Conn.Close() })
	return c.err
}

func TestDelayStopWaitsForActualProbeExit(t *testing.T) {
	old := adapter.UnifiedDelay.Load()
	adapter.UnifiedDelay.Store(false)
	defer adapter.UnifiedDelay.Store(old)
	requestEntered, closeEntered, releaseClose := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseClose) }) }
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { close(requestEntered); <-r.Context().Done() }))
	defer server.Close()
	actual := publicDelayProxy(t, &delayLoopbackDialer{wrap: func(conn net.Conn) net.Conn {
		return &delayCloseBarrierConn{Conn: conn, entered: closeEntered, release: releaseClose}
	}})
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rules: ['MATCH,DIRECT']\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer func() { release(); requireStop(t, &e) }()
	proxyClosed := make(chan struct{})
	proxy := &delayProxyFixture{Proxy: actual, name: "member", adapter: actual.Adapter(), publicProbe: func(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
		if target != C.DefaultTestURL || !reflect.DeepEqual(expected, delayExpected) {
			t.Error("application probe arguments changed")
		}
		return actual.URLTest(ctx, server.URL, expected)
	}, onClose: func() error { close(proxyClosed); return actual.Close() }}
	e.mu.Lock()
	e.cfg.Proxies["member"] = proxy
	e.cfg.Proxies["group"] = &delayProxyFixture{name: "group", adapter: &delayGroupFixture{members: []C.Proxy{proxy}}}
	e.mu.Unlock()
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	e.mu.Lock()
	batch := e.delays[id]
	e.mu.Unlock()
	select {
	case <-requestEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("public URLTest never entered its real HTTP peer")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- e.Stop() }() // production public Stop, not stopDelays
	select {
	case <-closeEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("Stop did not cancel the real HTTP transport")
	}
	select {
	case err := <-stopped:
		t.Fatal("Stop returned before public URLTest's real connection Close", err)
	case <-time.After(30 * time.Millisecond):
	}
	select {
	case <-proxyClosed:
		t.Fatal("node resources closed before the real probe drained")
	default:
	}
	release()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("actual public call completion did not release Stop")
	}
	select {
	case <-proxyClosed:
	default:
		t.Fatal("Stop did not close the owned node after joining its probe")
	}
	if value := batch.snapshot(); value.State != "cancelled" || value.Members[0].Status != "cancelled" || value.Members[0].Delay != 0 {
		t.Fatal("stopped probe published a late result", value)
	}
	if _, err := e.DelayTest(id); err == nil {
		t.Fatal("old batch still readable after public Stop")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal("joined Stop did not permit a new owner", err)
	}
	batch.set(0, "success", 42)
	if batch.snapshot().Members[0].Status != "cancelled" {
		t.Fatal("old completion affected the replacement context")
	}
}

func TestDelayRunningBatchExpiresBeforeLateProbeReply(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	old := &delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) {
		close(entered)
		<-release
		return 12, nil
	}}
	e, group := delayEngineFixture(old)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	batch := e.delays[id]
	defer func() { close(release); awaitDelayFixture(t, batch) }()
	<-entered
	group.members = []C.Proxy{&delayProxyFixture{name: "same", probe: old.probe}}
	if got := readDelayFixture(t, e, id); got.State != "expired" {
		t.Fatal(got)
	}
	batch.set(0, "success", 12)
	if got := batch.snapshot(); got.Members[0].Status != "expired" {
		t.Fatal(got)
	}
}

func TestDelayCancelReleasesExpiredBatchAfterProbeExit(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	old := &delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) {
		close(entered)
		<-release
		return 12, nil
	}}
	e, group := delayEngineFixture(old)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	batch := e.delays[id]
	released := false
	defer func() {
		if !released {
			close(release)
		}
		awaitDelayFixture(t, batch)
	}()
	<-entered
	group.members = []C.Proxy{&delayProxyFixture{name: "same", probe: old.probe}}
	if got := readDelayFixture(t, e, id); got.State != "expired" {
		t.Fatal(got)
	}
	e.CancelDelayTest(id)
	close(release)
	released = true
	awaitDelayFixture(t, batch)
	deadline := time.Now().Add(time.Second)
	for {
		e.mu.Lock()
		_, retained := e.delays[id]
		e.mu.Unlock()
		if !retained {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("released expired batch retained after its probe exited")
		}
		time.Sleep(time.Millisecond)
	}
}

func TestDelayWorkerPoolIsSessionBounded(t *testing.T) {
	entered := make(chan struct{}, 12)
	var active, peak atomic.Int32
	members := make([]C.Proxy, 12)
	for i := range members {
		members[i] = &delayProxyFixture{name: string(rune('A' + i)), probe: func(ctx context.Context) (uint16, error) {
			n := active.Add(1)
			defer active.Add(-1)
			for old := peak.Load(); n > old && !peak.CompareAndSwap(old, n); old = peak.Load() {
			}
			entered <- struct{}{}
			<-ctx.Done()
			return 0, ctx.Err()
		}}
	}
	e, _ := delayEngineFixture(members...)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	batch := e.delays[id]
	defer e.CancelDelayTest(id)
	for i := 0; i < delayTestWorkers; i++ {
		select {
		case <-entered:
		case <-time.After(time.Second):
			t.Fatal("worker did not start")
		}
	}
	select {
	case <-entered:
		t.Fatal("more than four simultaneous probes")
	case <-time.After(10 * time.Millisecond):
	}
	e.CancelDelayTest(id)
	awaitDelayFixture(t, batch)
	if peak.Load() != delayTestWorkers || active.Load() != 0 {
		t.Fatal(peak.Load(), active.Load())
	}
}

func TestDelayZeroSuccessIsNotOmittedFromJSON(t *testing.T) {
	proxy := &delayProxyFixture{name: "member", probe: func(context.Context) (uint16, error) { return 0, nil }}
	e, _ := delayEngineFixture(proxy)
	id, err := e.StartDelayTest("group", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer e.CancelDelayTest(id)
	awaitDelayFixture(t, e.delays[id])
	body, err := e.DelayTest(id)
	if err != nil {
		t.Fatal(err)
	}
	var value struct {
		Members []map[string]any `json:"members"`
	}
	if err := json.Unmarshal([]byte(body), &value); err != nil {
		t.Fatal(err)
	}
	if delay, ok := value.Members[0]["delay"]; !ok || delay != float64(0) {
		t.Fatalf("real zero result omitted: %s", body)
	}
}

// Preserve the settled member result when cancellation follows completion.
func TestDelayBatchCancelKeepsSettledResults(t *testing.T) {
	batch := &delayBatch{id: "x", group: "g", state: "running", started: time.Now(),
		done: make(chan struct{}), members: []DelayMember{{Name: "a"}, {Name: "b"}},
		results: []delayResult{{status: "success", delay: 12}, {status: "running"}}}
	batch.finish(true)
	snapshot := batch.snapshot()
	if snapshot.Members[0].Status != "success" || snapshot.Members[1].Status != "cancelled" {
		t.Fatal(snapshot)
	}
}
