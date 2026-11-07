package engine

import (
	"clashpseudo/native/internal/coreview"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

func strategyConfig(t *testing.T) string {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	t.Cleanup(server.Close)
	return fmt.Sprintf(`mode: rule
find-process-mode: off
proxy-providers:
  fixture:
    type: inline
    payload:
      - {name: provider-node, type: socks5, server: 127.0.0.1, port: 9}
    health-check: {enable: false}
proxy-groups:
  - name: 手动🌐
    type: select
    proxies: [DIRECT, REJECT, 自动]
    use: [fixture]
  - name: 自动
    type: url-test
    proxies: [DIRECT, COMPATIBLE]
    url: %s
    interval: 3600
  - name: 故障转移
    type: fallback
    proxies: [DIRECT, COMPATIBLE]
    url: %s
    interval: 3600
  - name: 均衡
    type: load-balance
    proxies: [DIRECT, COMPATIBLE]
    hidden: true
    url: %s
    interval: 3600
rules:
  - MATCH,手动🌐
`, server.URL, server.URL, server.URL)
}

func readStrategies(t *testing.T, e *Engine) coreview.Strategies {
	t.Helper()
	data, err := e.Strategies()
	if err != nil {
		t.Fatal(err)
	}
	var value coreview.Strategies
	if err := json.Unmarshal([]byte(data), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func choose(kind, name string) Choice { return Choice{Type: kind, Member: &name} }

func TestStrategiesReadSelectionAndLifecycle(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if _, err := e.Strategies(); err == nil {
		t.Fatal("unprepared core returned groups")
	}
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	state := readStrategies(t, &e)
	var names []string
	for _, group := range state.Groups {
		names = append(names, group.Name)
	}
	if !reflect.DeepEqual(names, []string{"手动🌐", "自动", "故障转移", "均衡", "GLOBAL"}) {
		t.Fatal(names)
	}
	members := state.Groups[0].Members
	if members[len(members)-1].Name != "provider-node" || state.GlobalReferenced {
		t.Fatal(state)
	}
	if !state.Groups[3].Hidden || state.Groups[3].Now != "" || state.Groups[3].Fixed != "" {
		t.Fatal("load balance has a fictitious selection")
	}
	cfg, owner := e.cfg, e.owner
	closer := &countedCloser{}
	e.tun = closer
	for _, name := range []string{"provider-node", "REJECT", "DIRECT"} {
		if err := e.SetStrategy("手动🌐", choose("select", name), false); err != nil {
			t.Fatal(err)
		}
		if readStrategies(t, &e).Groups[0].Now != name {
			t.Fatal("selection was not read back")
		}
	}
	for _, tc := range []struct{ group, kind string }{{"自动", "url-test"}, {"故障转移", "fallback"}} {
		if err := e.SetStrategy(tc.group, choose(tc.kind, "COMPATIBLE"), false); err != nil {
			t.Fatal(err)
		}
		for _, group := range readStrategies(t, &e).Groups {
			if group.Name == tc.group && group.Fixed != "COMPATIBLE" {
				t.Fatal(group)
			}
		}
		if err := e.SetStrategy(tc.group, Choice{Type: tc.kind}, false); err != nil {
			t.Fatal(err)
		}
		for _, group := range readStrategies(t, &e).Groups {
			if group.Name == tc.group && group.Fixed != "" {
				t.Fatal(group)
			}
		}
	}
	for _, tc := range []struct {
		name   string
		choice Choice
	}{
		{"missing", choose("select", "DIRECT")},
		{"手动🌐", choose("select", "missing")},
		{"手动🌐", Choice{Type: "select"}},
		{"手动🌐", choose("url-test", "DIRECT")},
		{"均衡", choose("load-balance", "DIRECT")},
	} {
		if e.SetStrategy(tc.name, tc.choice, false) == nil {
			t.Fatal("invalid selection accepted", tc)
		}
	}
	if e.cfg != cfg || e.owner != owner || closer.calls != 0 {
		t.Fatal("strategy selection replaced the session")
	}
	e.Cancel()
	if _, err := e.Strategies(); err == nil || e.SetStrategy("手动🌐", choose("select", "DIRECT"), false) == nil {
		t.Fatal("cancelled context accepted strategy calls")
	}
}

func TestRestoreStrategyReadsActualSelectionWithoutWritingCoreCache(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	choices := []struct {
		name    string
		choice  Choice
		failure string
	}{
		{"手动🌐", choose("select", "provider-node"), ""},
		{"自动", choose("url-test", "COMPATIBLE"), ""},
		{"故障转移", Choice{Type: "fallback"}, ""},
		{"missing", choose("select", "DIRECT"), "group-missing"},
		{"均衡", choose("select", "DIRECT"), "type-changed"},
		{"GLOBAL", choose("select", "missing"), "member-missing"},
	}
	before := cachefile.Cache().SelectedMap()
	for _, item := range choices {
		err := e.SetStrategy(item.name, item.choice, true)
		if item.failure == "" && err != nil || item.failure != "" && (err == nil || err.Error() != item.failure) {
			t.Fatal(item.name, err)
		}
	}
	state := readStrategies(t, &e)
	if state.Groups[0].Now != "provider-node" || state.Groups[1].Fixed != "COMPATIBLE" || state.Groups[2].Fixed != "" || state.Groups[4].Now != "DIRECT" {
		t.Fatal(state)
	}
	if !reflect.DeepEqual(cachefile.Cache().SelectedMap(), before) {
		t.Fatal("strategy restoration rewrote the upstream selected cache")
	}
}

func TestInvalidStrategyChoiceDoesNotClaimContext(t *testing.T) {
	for _, value := range []string{"null", "[]", `{"type":"select"}`, `{"type":"select","member":null}`, `{"type":"load-balance","member":"DIRECT"}`, `{"type":"fallback","member":""}`, `{"type":"fallback","member":3}`} {
		if _, err := DecodeChoice([]byte(value)); err == nil {
			t.Fatal("accepted invalid choice", value)
		}
	}
	if _, err := DecodeChoice([]byte(`{"type":"fallback","member":null}`)); err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := e.SetStrategy("g", Choice{Type: "select"}, false); err == nil || e.owner != nil {
		t.Fatal("invalid choice claimed context")
	}
}

// Use an isolated real upstream singleton cache.
func TestProfileDefaultSelectedCoreCacheAndApplicationChoices(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		for _, name := range []string{"default", "cached", "invalid", "disabled", "reopen"} {
			runEnginePhase(t, home, name)
		}
		if _, err := os.Stat(filepath.Join(home, "cache.db")); err != nil {
			t.Fatalf("normal upstream cache was not used: %v", err)
		}
		return
	}
	body := "profile: {store-selected: true}\nproxy-groups:\n - {name: pick, type: select, proxies: [DIRECT, REJECT], default-selected: REJECT}\nrules: ['MATCH,pick']\n"
	if phase == "disabled" {
		body = strings.Replace(body, "store-selected: true", "store-selected: false", 1)
	}
	var e Engine
	if err := e.Prepare(home, []byte(body), "", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	selected := func() string {
		for _, group := range readStrategies(t, &e).Groups {
			if group.Name == "pick" {
				return group.Now
			}
		}
		t.Fatal("missing group")
		return ""
	}
	switch phase {
	case "default":
		if selected() != "REJECT" {
			t.Fatal("default-selected was replaced by a hard-coded first member")
		}
		if err := e.SetStrategy("pick", choose("select", "DIRECT"), false); err != nil {
			t.Fatal(err)
		}
		if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
			t.Fatal("successful explicit operation was not persisted to the upstream cache")
		}
		if err := e.SetStrategy("pick", choose("select", "missing"), false); err == nil {
			t.Fatal("invalid choice accepted")
		}
		if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
			t.Fatal("failed operation rewrote selection cache")
		}
	case "cached":
		if selected() != "DIRECT" {
			t.Fatal("valid upstream selected cache was not restored")
		}
		if err := e.SetStrategy("pick", choose("select", "REJECT"), true); err != nil {
			t.Fatal(err)
		}
		if selected() != "REJECT" {
			t.Fatal("application choice did not override the core cache")
		}
		if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
			t.Fatal("restoration impersonated a new explicit selection")
		}
		e.cfg.Proxies["pick"].Adapter().(G.SelectAble).ForceSet("missing")
		if err := os.WriteFile(filepath.Join(home, "public-missing"), []byte(selected()), 0600); err != nil {
			t.Fatal(err)
		}
		cachefile.Cache().SetSelected("pick", "missing")
	case "invalid", "reopen":
		want, err := os.ReadFile(filepath.Join(home, "public-missing"))
		if err != nil {
			t.Fatal(err)
		}
		if selected() != string(want) {
			t.Fatal("invalid core cache did not retain the public selector's own result", selected(), string(want))
		}
	case "disabled":
		if selected() != "REJECT" {
			t.Fatal("disabled core cache was restored")
		}
		if err := e.SetStrategy("pick", choose("select", "DIRECT"), false); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatal("unknown cache test phase", phase)
	}
}

func TestStoreFakeIPPersistsNormalPoolStateBeforeStopClearsMapper(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		statePath := filepath.Join(home, "pool-state.json")
		for _, stage := range []string{"save", "disabled", "restore", "flushed"} {
			runEnginePhase(t, home, stage, "PSEUDO_POOL_STATE="+statePath)
		}
		publicHome := t.TempDir()
		data, err := os.ReadFile(filepath.Join(home, "cache.db"))
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(publicHome, "cache.db"), data, 0600); err != nil {
			t.Fatal(err)
		}
		for _, stage := range []string{"public-range", "public-after"} {
			runEnginePhase(t, publicHome, stage, "PSEUDO_POOL_STATE="+statePath)
		}
		for _, stage := range []string{"app-range", "app-after"} {
			runEnginePhase(t, home, stage, "PSEUDO_POOL_STATE="+statePath)
		}
		return
	}
	var state struct {
		First, Second, Next netip.Addr
		Host                string
		Present             bool
		Range               string
	}
	statePath := os.Getenv("PSEUDO_POOL_STATE")
	if phase != "save" {
		data, err := os.ReadFile(statePath)
		if err != nil {
			t.Fatal(err)
		}
		if err = json.Unmarshal(data, &state); err != nil {
			t.Fatal(err)
		}
	}
	save := func() {
		data, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(statePath, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	body := "ipv6: false\nprofile: {store-fake-ip: true}\ndns: {enable: true, enhanced-mode: fake-ip, fake-ip-range: 198.18.0.1/16}\nrules: ['MATCH,DIRECT']\n"
	disabled := strings.Replace(body, "enable: true", "enable: false", 1)
	changedRange := strings.Replace(disabled, "198.18.0.1/16", "198.19.0.1/16", 1)
	if phase == "public-range" {
		var paths Engine
		if _, err := paths.Paths(home); err != nil {
			t.Fatal(err)
		}
		raw, err := config.UnmarshalRawConfig([]byte(changedRange))
		if err != nil {
			t.Fatal(err)
		}
		parsed, err := config.ParseRawConfig(raw)
		if err != nil {
			t.Fatal(err)
		}
		state.Range = parsed.DNS.FakeIPRange.String()
		baseline := Engine{cfg: parsed}
		requireStop(t, &baseline)
		save()
		return
	}
	input := body
	if phase == "disabled" {
		input = disabled
	}
	if phase == "app-range" {
		input = changedRange
	}
	var e Engine
	if err := e.Prepare(home, []byte(input), "", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	pool := e.cfg.DNS.FakeIPPool
	if pool == nil {
		t.Fatal("explicit fake-IP pool was not enabled")
	}
	switch phase {
	case "save":
		state.First, state.Second = pool.Lookup("first.persistence.test"), pool.Lookup("second.persistence.test")
		save()
	case "disabled":
		if e.cfg.DNS.Enable || e.cfg.DNS.EnhancedMode != C.DNSFakeIP || e.cfg.DNS.FakeIPPool6 != nil {
			t.Fatal("disabled DNS did not retain the public parser's explicit fake-IP mode and pool")
		}
		if resolver.DefaultHostMapper != nil || resolver.DefaultService != nil || resolver.DefaultResolver != nil {
			t.Fatal("disabled DNS started a resolver or host mapper")
		}
	case "restore":
		if got := pool.Lookup("first.persistence.test"); got != state.First {
			t.Fatal("persisted mapping changed", got, state.First)
		}
		if host, ok := pool.LookBack(state.Second); !ok || host != "second.persistence.test" {
			t.Fatal("persisted reverse mapping was lost")
		}
		if got := pool.Lookup("third.persistence.test"); got != state.Second.Next() {
			t.Fatal("Stop did not save the allocation offset", got, state.Second)
		}
		if value := dnsObject(t, e.ClearDNSCache()); value["status"] != "completed" {
			t.Fatal(value)
		}
		if host, ok := pool.LookBack(state.Second); !ok || host != "second.persistence.test" {
			t.Fatal("DNS cache clear removed the persistent fake-IP mapping")
		}
		if value := dnsObject(t, e.FlushFakeIP()); value["status"] != "completed" || value["persistent"] != true {
			t.Fatal("fake-IP flush did not report its actual persistent scope", value)
		}
	case "flushed":
		if _, ok := pool.LookBack(state.Second); ok {
			t.Fatal("flushed persistent fake-IP mapping returned after prepare")
		}
		if got := pool.Lookup("after-flush.persistence.test"); got != state.First {
			t.Fatal("flushed persistent allocation offset was not reset", got, state.First)
		}
	case "public-after":
		state.Host, state.Present = pool.LookBack(state.First)
		state.Next = pool.Lookup("after-range-change.persistence.test")
		save()
	case "app-range":
		if e.cfg.DNS.Enable || e.cfg.DNS.EnhancedMode != C.DNSFakeIP || e.cfg.DNS.FakeIPRange.String() != state.Range || resolver.DefaultHostMapper != nil || resolver.DefaultService != nil || resolver.DefaultResolver != nil {
			t.Fatal("inactive range change did not preserve the public parser result")
		}
	case "app-after":
		if host, present := pool.LookBack(state.First); host != state.Host || present != state.Present {
			t.Fatalf("inactive range change altered public cache behavior: %q/%t, want %q/%t", host, present, state.Host, state.Present)
		}
		if got := pool.Lookup("after-range-change.persistence.test"); got != state.Next {
			t.Fatal("inactive range change altered the public allocation offset", got, state.Next)
		}
	default:
		t.Fatal("unknown fake-IP test phase", phase)
	}
}

// Expose the selected-field upstream races through official interfaces under -race.
func TestStrategyConcurrentReads(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	for _, tc := range []struct{ name, kind string }{{"手动🌐", "select"}, {"自动", "url-test"}, {"故障转移", "fallback"}} {
		group := e.cfg.Proxies[tc.name].Adapter().(G.ProxyGroup)
		var readers sync.WaitGroup
		readers.Add(1)
		go func() {
			defer readers.Done()
			for i := 0; i < 2000; i++ {
				group.Now()
			}
		}()
		for i := 0; i < 200; i++ {
			choice := choose(tc.kind, "DIRECT")
			if i%2 == 0 && tc.kind != "select" {
				choice.Member = nil
			}
			if err := e.SetStrategy(tc.name, choice, false); err != nil {
				t.Error(err)
				break
			}
		}
		readers.Wait()
	}
}

func TestStrategyCurrentIdentityUsesTheCapturedProviderGroup(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	original := e.cfg.Proxies["手动🌐"]
	group := original.Adapter().(G.ProxyGroup)
	var expected string
	for _, member := range group.Proxies() {
		if member.Name() == group.Now() {
			expected = delayMemberIdentity(delaySourceIdentity(original), member)
			break
		}
	}
	if expected == "" {
		t.Fatal("missing current member fixture")
	}
	e.cfg.Proxies["手动🌐"] = e.cfg.Proxies["GLOBAL"]
	defer func() { e.cfg.Proxies["手动🌐"] = original }()
	found := false
	for _, state := range readStrategies(t, &e).Groups {
		if state.Name == "手动🌐" {
			found = true
			if state.CurrentIdentity != expected {
				t.Fatal("identity was recomputed from a same-key replacement", state.CurrentIdentity, expected)
			}
		}
	}
	if !found {
		t.Fatal("captured provider group missing")
	}
}
