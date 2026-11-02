package engine

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestFileProvidersAutomaticallyWatchSavedFiles(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home := t.TempDir()
	files := []struct{ name, initial, updated string }{
		{"local-proxies.yaml", "proxies: [{name: initial, type: direct}]\n", "proxies: [{name: updated, type: direct}]\n"},
		{"local-rules.txt", "initial.example\n", "updated.example\n"},
	}
	for _, file := range files {
		if err := os.WriteFile(filepath.Join(home, file.name), []byte(file.initial), 0600); err != nil {
			t.Fatal(err)
		}
	}
	body := validConfig + `proxy-providers:
 fixture: {type: file, path: local-proxies.yaml, interval: 0, health-check: {enable: false}}
rule-providers:
 fixture: {type: file, path: local-rules.txt, behavior: domain, format: text, interval: 0}
`
	var e Engine
	t.Cleanup(func() { requireStop(t, &e) })
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	proxy, rule := e.cfg.Providers["fixture"], e.cfg.RuleProviders["fixture"]
	if proxy == nil || rule == nil || proxy.VehicleType() != P.File || rule.VehicleType() != P.File {
		t.Fatal("configuration did not load both file providers")
	}
	proxies := proxy.Proxies()
	if len(proxies) != 1 || proxies[0].Name() != "initial" {
		t.Fatalf("initial proxy file not loaded: %v", proxies)
	}
	initial, updated := &C.Metadata{Host: "initial.example"}, &C.Metadata{Host: "updated.example"}
	if rule.Count() != 1 || !rule.Match(initial, C.RuleMatchHelper{}) || rule.Match(updated, C.RuleMatchHelper{}) {
		t.Fatal("initial rule file matcher not loaded")
	}

	// The public callback synchronizes matcher reads with its replacement;
	// polling RuleProvider.Match would race the upstream strategy assignment.
	ruleUpdated := make(chan P.RuleProvider, 1)
	subscription := tunnel.Tunnel.RuleUpdateCallback().Register(func(provider P.RuleProvider) {
		if provider.Name() == rule.Name() {
			select {
			case ruleUpdated <- provider:
			default:
			}
		}
	})
	defer func() {
		if err := subscription.Close(); err != nil {
			t.Error(err)
		}
	}()

	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	// Save by atomic replacement, as editors do. The real file watcher watches
	// the parent directory and observes the rename's create event on Linux.
	for _, file := range files {
		path := filepath.Join(home, file.name)
		if err := os.WriteFile(path+".next", []byte(file.updated), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(path+".next", path); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case provider := <-ruleUpdated:
		if provider.Count() != 1 || provider.Match(initial, C.RuleMatchHelper{}) || !provider.Match(updated, C.RuleMatchHelper{}) {
			t.Fatal("file watcher did not replace the rule matcher")
		}
	case <-deadline.C:
		t.Fatal("file rule-provider watcher did not reload within 5 seconds")
	}

	poll := time.NewTicker(100 * time.Millisecond)
	defer poll.Stop()
	for {
		proxies = proxy.Proxies()
		if len(proxies) == 1 && proxies[0].Name() == "updated" {
			break
		}
		select {
		case <-poll.C:
		case <-deadline.C:
			t.Fatalf("file proxy-provider watcher did not reload within 5 seconds: %v", proxies)
		}
	}
	requireStop(t, &e)
	if e.cfg != nil || e.owner != nil || current.Load() != nil || e.failed {
		t.Fatal("file provider session was not released cleanly")
	}
}
