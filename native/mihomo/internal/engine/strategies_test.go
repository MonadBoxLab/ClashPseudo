package engine

import (
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"

	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/component/resolver"
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

func readStrategies(t *testing.T, e *Engine) Strategies {
	t.Helper()
	data, err := e.Strategies()
	if err != nil {
		t.Fatal(err)
	}
	var value Strategies
	if err := json.Unmarshal([]byte(data), &value); err != nil {
		t.Fatal(err)
	}
	return value
}

func choose(kind, name string) Choice { return Choice{Type: kind, Member: &name} }

func TestStrategiesReadSelectionAndLifecycle(t *testing.T) {
	var e Engine
	if _, err := e.Strategies(); err == nil {
		t.Fatal("unprepared core returned groups")
	}
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", nil, func(int) bool { return true }); err != nil {
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
		if err := e.SetStrategy("手动🌐", choose("select", name)); err != nil {
			t.Fatal(err)
		}
		if readStrategies(t, &e).Groups[0].Now != name {
			t.Fatal("selection was not read back")
		}
	}
	for _, tc := range []struct{ group, kind string }{{"自动", "url-test"}, {"故障转移", "fallback"}} {
		if err := e.SetStrategy(tc.group, choose(tc.kind, "COMPATIBLE")); err != nil {
			t.Fatal(err)
		}
		for _, group := range readStrategies(t, &e).Groups {
			if group.Name == tc.group && group.Fixed != "COMPATIBLE" {
				t.Fatal(group)
			}
		}
		if err := e.SetStrategy(tc.group, Choice{Type: tc.kind}); err != nil {
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
		if e.SetStrategy(tc.name, tc.choice) == nil {
			t.Fatal("invalid selection accepted", tc)
		}
	}
	if e.cfg != cfg || e.owner != owner || closer.calls != 0 {
		t.Fatal("strategy selection replaced the session")
	}
	e.Cancel()
	if _, err := e.Strategies(); err == nil || e.SetStrategy("手动🌐", choose("select", "DIRECT")) == nil {
		t.Fatal("cancelled context accepted strategy calls")
	}
}

func TestStrategyRestorationAndMissingChoices(t *testing.T) {
	choices := map[string]Choice{
		"手动🌐":     choose("select", "provider-node"),
		"自动":      choose("url-test", "COMPATIBLE"),
		"故障转移":    {Type: "fallback"},
		"missing": choose("select", "DIRECT"),
		"均衡":      choose("select", "DIRECT"),
		"GLOBAL":  choose("select", "missing"),
	}
	var e Engine
	body := strategyConfig(t)
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", choices, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	state := readStrategies(t, &e)
	if state.Groups[0].Now != "provider-node" || state.Groups[1].Fixed != "COMPATIBLE" || state.Groups[2].Fixed != "" {
		t.Fatal(state)
	}
	if len(state.Unrestored) != 3 || state.Groups[4].Now != "DIRECT" {
		t.Fatal(state)
	}
	if err := e.SetStrategy("GLOBAL", choose("select", "DIRECT")); err != nil {
		t.Fatal(err)
	}
	if len(readStrategies(t, &e).Unrestored) != 2 {
		t.Fatal("confirmed new choice retained old warning")
	}
	requireStop(t, &e)
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if fresh := readStrategies(t, &e); fresh.Groups[0].Now != "DIRECT" || len(fresh.Unrestored) != 0 {
		t.Fatal("previous configuration's choices leaked", fresh)
	}
}

func TestGlobalDefinitionReferences(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       bool
	}{
		{"unreferenced", validConfig, false},
		{"rule", strings.ReplaceAll(validConfig, "MATCH,DIRECT", "MATCH,GLOBAL"), true},
		{"hidden-group", `proxy-groups:
  - {name: hidden, type: select, hidden: true, proxies: [GLOBAL]}
  - {name: GLOBAL, type: select, proxies: [DIRECT]}
rules: ['MATCH,DIRECT']
`, true},
		{"subrule-name", `sub-rules:
  GLOBAL:
    - MATCH,DIRECT
rules:
  - SUB-RULE,(NETWORK,TCP),GLOBAL
  - MATCH,DIRECT
`, false},
		{"unused-subrule-target", `sub-rules:
  unused:
    - MATCH,GLOBAL
rules:
  - MATCH,DIRECT
`, true},
		{"provider-node-named-global", `proxy-providers:
  fixture:
    type: inline
    payload:
      - {name: GLOBAL, type: socks5, server: 127.0.0.1, port: 9}
    health-check: {enable: false}
proxy-groups:
  - {name: choose, type: select, use: [fixture]}
rules:
  - MATCH,DIRECT
`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var e Engine
			if err := e.Prepare(t.TempDir(), []byte(tc.body), "rule", nil, func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			if got := readStrategies(t, &e).GlobalReferenced; got != tc.want {
				t.Fatalf("referenced=%v, want=%v", got, tc.want)
			}
		})
	}
}

func TestInvalidStrategyChoices(t *testing.T) {
	for _, value := range []string{"null", "[]", `{"":{"type":"select","member":"DIRECT"}}`, `{"g":{"type":"select"}}`, `{"g":{"type":"select","member":null}}`, `{"g":{"type":"load-balance","member":"DIRECT"}}`, `{"g":{"type":"fallback","member":""}}`, `{"g":{"type":"fallback","member":3}}`} {
		if _, err := DecodeChoices([]byte(value)); err == nil {
			t.Fatal("accepted invalid choices", value)
		}
	}
	if _, err := DecodeChoices([]byte(`{"组🌐":{"type":"fallback","member":null}}`)); err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", map[string]Choice{"g": {Type: "select"}}, func(int) bool { return true }); err == nil || e.owner != nil {
		t.Fatal("invalid choices claimed context")
	}
}

// Use an isolated real upstream singleton cache.
func TestProfileDefaultSelectedCoreCacheAndApplicationChoices(t *testing.T) {
	if os.Getenv("CLASH_PROFILE_CACHE_CHILD") != "1" {
		command := exec.Command(os.Args[0], "-test.run=^TestProfileDefaultSelectedCoreCacheAndApplicationChoices$", "-test.v")
		if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
			command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
		}
		command.Env = append(os.Environ(), "CLASH_PROFILE_CACHE_CHILD=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("profile cache subprocess: %v\n%s", err, output)
		}
		return
	}
	home := t.TempDir()
	body := `profile: {store-selected: true}
proxy-groups:
  - {name: pick, type: select, proxies: [DIRECT, REJECT], default-selected: REJECT}
rules: ["MATCH,pick"]
`
	var e Engine
	prepare := func(text string, choices map[string]Choice) {
		t.Helper()
		if err := e.Prepare(home, []byte(text), "", choices, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
	}
	selected := func() string {
		t.Helper()
		for _, g := range readStrategies(t, &e).Groups {
			if g.Name == "pick" {
				return g.Now
			}
		}
		t.Fatal("missing group")
		return ""
	}
	prepare(body, nil)
	if selected() != "REJECT" {
		t.Fatal("default-selected was replaced by a hard-coded first member")
	}
	if err := e.SetStrategy("pick", choose("select", "DIRECT")); err != nil {
		t.Fatal(err)
	}
	if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
		t.Fatal("successful explicit operation was not persisted to the upstream cache")
	}
	if err := e.SetStrategy("pick", choose("select", "missing")); err == nil {
		t.Fatal("invalid choice accepted")
	}
	if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
		t.Fatal("failed operation rewrote selection cache")
	}
	requireStop(t, &e)
	prepare(body, nil)
	if selected() != "DIRECT" {
		t.Fatal("valid upstream selected cache was not restored")
	}
	requireStop(t, &e)
	prepare(body, map[string]Choice{"pick": choose("select", "REJECT")})
	if selected() != "REJECT" {
		t.Fatal("application choice did not override the core cache")
	}
	if cachefile.Cache().SelectedMap()["pick"] != "DIRECT" {
		t.Fatal("restoration impersonated a new explicit selection")
	}
	cachefile.Cache().SetSelected("pick", "missing")
	requireStop(t, &e)
	prepare(body, nil)
	if selected() != "REJECT" {
		t.Fatal("invalid core cache displaced the file's initial default")
	}
	requireStop(t, &e)
	prepare(strings.Replace(body, "store-selected: true", "store-selected: false", 1), nil)
	if selected() != "REJECT" {
		t.Fatal("disabled core cache was restored")
	}
	if err := e.SetStrategy("pick", choose("select", "DIRECT")); err != nil {
		t.Fatal(err)
	}
	requireStop(t, &e)
	prepare(body, nil)
	if selected() != "REJECT" {
		t.Fatal("store-selected=false still wrote the disabled choice")
	}
	requireStop(t, &e)
	if _, err := os.Stat(filepath.Join(home, "cache.db")); err != nil {
		t.Fatalf("normal upstream cache was not used: %v", err)
	}
}

func TestStoreFakeIPPersistsNormalPoolStateBeforeStopClearsMapper(t *testing.T) {
	if os.Getenv("CLASH_FAKE_POOL_CHILD") != "1" {
		command := exec.Command(os.Args[0], "-test.run=^TestStoreFakeIPPersistsNormalPoolStateBeforeStopClearsMapper$", "-test.v")
		if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
			command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
		}
		command.Env = append(os.Environ(), "CLASH_FAKE_POOL_CHILD=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("fake-IP persistence subprocess: %v\n%s", err, output)
		}
		return
	}
	home := t.TempDir()
	body := "ipv6: false\nprofile: {store-fake-ip: true}\ndns: {enhanced-mode: fake-ip, fake-ip-range: 198.18.0.1/16}\nrules: [\"MATCH,DIRECT\"]\n"
	var e Engine
	prepare := func() {
		t.Helper()
		if err := e.Prepare(home, []byte(body), "", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
	}
	prepare()
	pool := e.cfg.DNS.FakeIPPool
	if pool == nil {
		t.Fatal("explicit fake-IP pool was not enabled")
	}
	first, second := pool.Lookup("first.persistence.test"), pool.Lookup("second.persistence.test")
	requireStop(t, &e)
	disabled := strings.Replace(body, "dns: {enhanced-mode", "dns: {enable: false, enhanced-mode", 1)
	disabled = strings.Replace(disabled, "198.18.0.1/16", "198.19.0.1/16", 1)
	if err := e.Prepare(home, []byte(disabled), "", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if e.cfg.DNS.Enable || e.cfg.DNS.EnhancedMode != C.DNSFakeIP || e.cfg.DNS.FakeIPPool != nil || e.cfg.DNS.FakeIPPool6 != nil || resolver.DefaultHostMapper != nil || resolver.DefaultService != nil || resolver.DefaultResolver != nil {
		t.Fatal("disabled DNS created a fake-IP pool/service or erased the explicit inactive mode")
	}
	requireStop(t, &e)
	prepare()
	pool = e.cfg.DNS.FakeIPPool
	if got := pool.Lookup("first.persistence.test"); got != first {
		t.Fatalf("persisted mapping changed from %v to %v", first, got)
	}
	if host, ok := pool.LookBack(second); !ok || host != "second.persistence.test" {
		t.Fatal("persisted reverse mapping was lost")
	}
	if got := pool.Lookup("third.persistence.test"); got != second.Next() {
		t.Fatalf("Stop did not save the allocation offset: %v after %v", got, second)
	}
	if value := dnsObject(t, e.ClearDNSCache()); value["status"] != "completed" {
		t.Fatal(value)
	}
	if host, ok := pool.LookBack(second); !ok || host != "second.persistence.test" {
		t.Fatal("DNS cache clear removed the persistent fake-IP mapping")
	}
	if value := dnsObject(t, e.FlushFakeIP()); value["status"] != "completed" || value["persistent"] != true {
		t.Fatal("fake-IP flush did not report its actual persistent scope", value)
	}
	requireStop(t, &e)
	prepare()
	pool = e.cfg.DNS.FakeIPPool
	if _, ok := pool.LookBack(second); ok {
		t.Fatal("flushed persistent fake-IP mapping returned after prepare")
	}
	if got := pool.Lookup("after-flush.persistence.test"); got != first {
		t.Fatal("flushed persistent allocation offset was not reset", got, first)
	}
	requireStop(t, &e)
}

// Expose the selected-field upstream races through official interfaces under -race.
func TestStrategyConcurrentReads(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(strategyConfig(t)), "rule", nil, func(int) bool { return true }); err != nil {
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
			if err := e.SetStrategy(tc.name, choice); err != nil {
				t.Error(err)
				break
			}
		}
		readers.Wait()
	}
}
