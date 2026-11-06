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
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"

	"clashpseudo/native/internal/coreview"
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
	// 测试通过公开Base/NewConn提供loopback socket，由上游执行URLTest、deadline及history。
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
	G.ProxyGroup
	members []C.Proxy
}

func (g *delayGroupFixture) Providers() []P.ProxyProvider { return nil }
func (g *delayGroupFixture) Name() string                 { return "group" }
func (g *delayGroupFixture) Proxies() []C.Proxy           { return g.members }

func delayEngineFixture(members ...C.Proxy) (*Engine, *delayGroupFixture) {
	group := &delayGroupFixture{members: members}
	owner := newSocketOwner(nil, nil)
	return &Engine{owner: owner, cfg: &config.Config{Proxies: map[string]C.Proxy{
		"group": &delayProxyFixture{name: "group", adapter: group},
	}}}, group
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

func delayFixtureIdentity(e *Engine, member C.Proxy) string {
	return coreview.MemberIdentity(coreview.GroupSourceIdentity(e.cfg.Proxies["group"]), member)
}

func TestDelayProjectionUsesPublicURLTestWithoutAddingStatusFailurePolicy(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
					t.Error("应用改变了公开URLTest参数")
				}
				return actual.URLTest(ctx, server.URL, expected)
			}}
			e, _ := delayEngineFixture(proxy)
			delay, err := e.URLTest(context.Background(), "group", proxy.Name(), delayFixtureIdentity(e, proxy), "", 0)
			history := actual.DelayHistory()
			if err != nil || len(history) != 1 || delay != history[0].Delay {
				t.Fatal("应用改变了公开测量结果", delay, err, history)
			}
			assertPublicDelayHistory(t, actual, server.URL, delay, true, status == 204)
		})
	}
}

func TestDelayProjectionPreservesPublicSuccessAfterUnifiedSecondTimeout(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	delay, err := e.URLTest(context.Background(), "group", proxy.Name(), delayFixtureIdentity(e, proxy), "", 0)
	history := actual.DelayHistory()
	if err != nil || requests.Load() < 2 || len(history) != 1 || delay != history[0].Delay || delay < uint16(delayTestTimeout/time.Millisecond) {
		t.Fatal("公开unified timeout结果改变", requests.Load(), delay, err, history)
	}
	assertPublicDelayHistory(t, actual, server.URL, delay, true, true)
}

func TestDelayMemberKeepsNilErrorMeasurementAfterDeadline(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var elapsed time.Duration
	proxy := &delayProxyFixture{name: "member", probe: func(ctx context.Context) (uint16, error) {
		start := time.Now()
		<-ctx.Done()
		elapsed = time.Since(start)
		return 12, nil
	}}
	e, _ := delayEngineFixture(proxy)
	delay, err := e.URLTest(context.Background(), "group", proxy.Name(), delayFixtureIdentity(e, proxy), "", 0)
	if err != nil || delay != 12 || elapsed < delayTestTimeout {
		t.Fatal("应用重分类了nil error测量结果", elapsed, delay, err)
	}
}

func TestDelaySingleCallPreservesZeroValueOriginalErrorAndArguments(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	original := errors.New("URLTest原始错误 https://fixture.test/?token=fixture")
	for _, failure := range []error{nil, original, errors.Join(original, context.DeadlineExceeded)} {
		calls := 0
		proxy := &delayProxyFixture{name: "member", publicProbe: func(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
			calls++
			deadline, ok := ctx.Deadline()
			if target != "https://fixture.test/probe" || !reflect.DeepEqual(expected, delayExpected) || !ok || time.Until(deadline) > time.Second {
				t.Error("公开URLTest参数改变")
			}
			return 0, failure
		}}
		e, _ := delayEngineFixture(proxy)
		delay, err := e.URLTest(context.Background(), "group", proxy.Name(), delayFixtureIdentity(e, proxy), "https://fixture.test/probe", time.Second)
		if delay != 0 || err != failure || calls != 1 {
			t.Fatal("公开结果或调用次数改变", delay, err, calls)
		}
	}
}

func TestDelayResultKeepsCapturedProxyAndRejectsSameNameReplacement(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, failure := range []error{nil, errors.New("原始公开失败"), context.DeadlineExceeded} {
		entered, release := make(chan struct{}), make(chan struct{})
		old := &delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) { close(entered); <-release; return 17, failure }}
		e, group := delayEngineFixture(old)
		identity := delayFixtureIdentity(e, old)
		result := make(chan struct {
			delay uint16
			err   error
		}, 1)
		go func() {
			delay, err := e.URLTest(context.Background(), "group", "same", identity, "", 0)
			result <- struct {
				delay uint16
				err   error
			}{delay, err}
		}()
		<-entered
		e.mu.Lock()
		group.members = []C.Proxy{&delayProxyFixture{name: "same", probe: func(context.Context) (uint16, error) { t.Error("调用了替换对象"); return 0, nil }}}
		e.mu.Unlock()
		if _, err := e.URLTest(context.Background(), "group", "same", identity, "", 0); !errors.Is(err, coreview.ErrNodesChanged) {
			t.Error("旧identity取得替换节点", err)
		}
		close(release)
		got := <-result
		if got.delay != 17 || got.err != failure {
			t.Fatal("来源退役改变了真实迟到结果", got)
		}
	}
}

func TestDelayCancellationWaitsForActualPublicCallReturn(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	entered, cancelled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	proxy := &delayProxyFixture{name: "member", probe: func(ctx context.Context) (uint16, error) {
		close(entered)
		<-ctx.Done()
		close(cancelled)
		<-release
		return 19, ctx.Err()
	}}
	e, _ := delayEngineFixture(proxy)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	identity := delayFixtureIdentity(e, proxy)
	go func() {
		delay, err := e.URLTest(ctx, "group", "member", identity, "", 0)
		if delay != 19 {
			t.Error("取消改变了实际值", delay)
		}
		done <- err
	}()
	<-entered
	cancel()
	<-cancelled
	select {
	case err := <-done:
		t.Fatal("取消信号被当成公开调用退出", err)
	default:
	}
	close(release)
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	e.owner.revoke()
	if _, err := e.URLTest(context.Background(), "group", "member", identity, "", 0); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}

func TestDelayStopWaitsForActualProbeExit(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	if err := e.Prepare(t.TempDir(), []byte("rules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer func() { release(); requireStop(t, &e) }()
	var proxyCloseOnce sync.Once
	proxyClosed := make(chan struct{})
	proxy := &delayProxyFixture{Proxy: actual, name: "member", adapter: actual.Adapter(), publicProbe: func(ctx context.Context, target string, expected utils.IntRanges[uint16]) (uint16, error) {
		return actual.URLTest(ctx, server.URL, expected)
	}, onClose: func() error { proxyCloseOnce.Do(func() { close(proxyClosed) }); return actual.Close() }}
	e.mu.Lock()
	e.cfg.Proxies["member"] = proxy
	e.cfg.Proxies["group"] = &delayProxyFixture{name: "group", adapter: &delayGroupFixture{members: []C.Proxy{proxy}}}
	e.mu.Unlock()
	identity := delayFixtureIdentity(&e, proxy)
	done := make(chan error, 1)
	go func() { _, err := e.URLTest(context.Background(), "group", "member", identity, "", 0); done <- err }()
	select {
	case <-requestEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("公开URLTest未进入HTTP peer")
	}
	stopped := make(chan error, 1)
	go func() { stopped <- e.Stop() }()
	select {
	case <-closeEntered:
	case <-time.After(2 * time.Second):
		t.Fatal("Stop未取消真实HTTP transport")
	}
	select {
	case err := <-stopped:
		t.Fatal("Stop提前返回", err)
	case <-time.After(30 * time.Millisecond):
	}
	select {
	case <-proxyClosed:
		t.Fatal("真实调用退出前关闭了proxy")
	default:
	}
	release()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("公开调用退出后Stop未返回")
	}
	if err := <-done; err == nil {
		t.Fatal("真实取消错误丢失")
	}
	select {
	case <-proxyClosed:
	default:
		t.Fatal("Stop未关闭proxy")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
		t.Fatal("同一Engine停止后再次装载")
	}
}

func TestStrategyCurrentDelayIdentityMatchesSingleCallAndSurvivesCompletion(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("proxy-groups:\n - {name: choice, type: select, proxies: [REJECT, DIRECT]}\nrules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	read := func() (string, string) {
		t.Helper()
		current, identity := "", ""
		_, err := e.StreamStrategies(context.Background(), func(any) error { return nil }, func(value any) error {
			body, err := json.Marshal(value)
			if err != nil {
				return err
			}
			var row struct {
				Name            string `json:"name"`
				CurrentIdentity string `json:"currentIdentity"`
				Now             string `json:"now"`
			}
			if err = json.Unmarshal(body, &row); err != nil {
				return err
			}
			if row.Name == "choice" {
				current, identity = row.Now, row.CurrentIdentity
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
		return current, identity
	}
	now, before := read()
	if now != "REJECT" || len(before) != 64 {
		t.Fatal(now, before)
	}
	_, _ = e.URLTest(context.Background(), "choice", "REJECT", before, "", 0)
	_, after := read()
	if after != before {
		t.Fatal("调用完成改变了identity")
	}
	direct := "DIRECT"
	if err := e.SetStrategy("choice", Choice{Type: "select", Member: &direct}, false); err != nil {
		t.Fatal(err)
	}
	_, after = read()
	if after == before {
		t.Fatal("不同当前节点沿用了identity")
	}
}
func TestDelayObservationIdentityTracksProviderVersionAndSameNameObjects(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	leaf := &delayProxyFixture{name: "same"}
	provider := &delayProviderFixture{version: 1, members: []C.Proxy{leaf}}
	group := &delayProviderGroupFixture{providers: []P.ProxyProvider{provider}}
	root := &delayProxyFixture{name: "group", adapter: group}
	identity := func(member C.Proxy) string { return delayMemberIdentity(delaySourceIdentity(root), member) }
	first := identity(leaf)
	if len(first) != 64 || identity(leaf) != first {
		t.Fatal("stable sources need stable opaque identities")
	}
	provider.version++
	second := identity(leaf)
	if second == first {
		t.Fatal("provider version update retained the old observation")
	}
	group.providers = []P.ProxyProvider{&delayProviderFixture{version: 2, members: []C.Proxy{leaf}}}
	third := identity(leaf)
	if third == second {
		t.Fatal("same-version provider replacement retained the old observation")
	}
	if identity(&delayProxyFixture{name: "same"}) == third {
		t.Fatal("same-name member replacement retained the old observation")
	}
}
