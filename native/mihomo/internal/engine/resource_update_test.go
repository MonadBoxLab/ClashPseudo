package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	P "github.com/metacubex/mihomo/constant/provider"
)

type heldUpdateProvider struct {
	P.ProxyProvider
	started chan struct{}
	release chan struct{}
	closed  chan struct{}
}

// Hold an external-provider operation while the inline provider supplies immutable
// cleanup-test nodes.
func (p *heldUpdateProvider) VehicleType() P.VehicleType { return P.HTTP }

func (p *heldUpdateProvider) Update() error {
	close(p.started)
	<-p.release
	return nil
}

func (p *heldUpdateProvider) Close() error {
	close(p.closed)
	return closeResource(p.ProxyProvider)
}

func TestStopCancelsAndJoinsAcceptedManualProviderUpdate(t *testing.T) {
	var e Engine
	body := validConfig + "proxy-providers:\n fixture:\n  type: inline\n  payload: [{name: fixture, type: direct}]\n  health-check: {enable: false}\n"
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	provider := &heldUpdateProvider{ProxyProvider: e.cfg.Providers["fixture"],
		started: make(chan struct{}), release: make(chan struct{}), closed: make(chan struct{})}
	e.cfg.Providers["fixture"] = provider
	tun := signalTunnel{closed: make(chan struct{})}
	e.tun = tun
	updated := make(chan error, 1)
	stopped := make(chan error, 1)
	var release sync.Once
	t.Cleanup(func() {
		release.Do(func() { close(provider.release) })
		requireStop(t, &e)
	})
	go func() { updated <- e.UpdateResource("proxyProvider", "fixture") }()
	select {
	case <-provider.started:
	case <-time.After(time.Second):
		t.Fatal("manual update did not start")
	}
	go func() { stopped <- e.Stop() }()
	select {
	case <-provider.closed:
	case <-time.After(time.Second):
		t.Fatal("provider cancellation was blocked behind manual I/O")
	}
	select {
	case <-tun.closed:
	case <-time.After(time.Second):
		t.Fatal("TUN was not closed before joining the manual update")
	}
	select {
	case err := <-stopped:
		t.Fatalf("provider Close was incorrectly treated as a join: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err == nil {
		t.Fatal("new context accepted while manual provider update was still running")
	}
	release.Do(func() { close(provider.release) })
	if err := <-updated; !errors.Is(err, ErrStopped) {
		t.Fatalf("late update was reported as current success: %v", err)
	}
	if err := <-stopped; err != nil {
		t.Fatal(err)
	}
}

func TestDecodeResourceUpdateRequiresExplicitStringName(t *testing.T) {
	for _, name := range []string{"", "fixture"} {
		body, err := json.Marshal(map[string]string{"kind": "proxyProvider", "name": name})
		if err != nil {
			t.Fatal(err)
		}
		kind, decoded, err := DecodeResourceUpdate(body)
		if err != nil || kind != "proxyProvider" || decoded != name {
			t.Fatalf("explicit name %q did not survive bridge decoding: %q/%q: %v", name, kind, decoded, err)
		}
	}
	for _, body := range []string{
		`{"kind":"proxyProvider"}`,
		`{"kind":"proxyProvider","name":null}`,
		`{"kind":"proxyProvider","name":0}`,
		`{"kind":"proxyProvider","name":false}`,
		`{"kind":"proxyProvider","name":[]}`,
		`{"kind":"proxyProvider","name":{}}`,
		`{"kind":0,"name":""}`,
		`{"kind":"proxyProvider","name":`,
		`null`, `[]`, ``, strings.Repeat(" ", 4<<10+1),
	} {
		if _, _, err := DecodeResourceUpdate([]byte(body)); err == nil {
			t.Fatalf("invalid bridge update accepted: %q", body)
		}
	}
}

func TestInlineResourcesRejectDirectUpdatesIncludingEmptyNames(t *testing.T) {
	body := validConfig + `proxy-providers:
 '': {type: inline, payload: [{name: empty-fixture, type: direct}], health-check: {enable: false}}
 fixture: {type: inline, payload: [{name: fixture, type: direct}], health-check: {enable: false}}
rule-providers:
 '': {type: inline, behavior: domain, payload: ['example.com']}
 fixture: {type: inline, behavior: domain, payload: ['example.org']}
`
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	for _, kind := range []string{"proxyProvider", "ruleProvider"} {
		for _, name := range []string{"", "fixture"} {
			// Invoke the public native operation directly.
			if err := e.UpdateResource(kind, name); err == nil || !strings.Contains(err.Error(), "no external source") {
				t.Fatalf("direct inline %s/%q update was not rejected: %v", kind, name, err)
			}
		}
	}
}

func TestFileResourcesStillAllowDirectUpdates(t *testing.T) {
	home := t.TempDir()
	proxyPath, rulePath := filepath.Join(home, "local-proxies.yaml"), filepath.Join(home, "local-rules.txt")
	if err := os.WriteFile(proxyPath, []byte("proxies: [{name: fixture, type: direct}]\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(rulePath, []byte("example.com\n"), 0600); err != nil {
		t.Fatal(err)
	}
	body := validConfig + `proxy-providers:
 '': {type: file, path: local-proxies.yaml, health-check: {enable: false}}
rule-providers:
 '': {type: file, path: local-rules.txt, behavior: domain, format: text}
`
	var e Engine
	if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	for _, kind := range []string{"proxyProvider", "ruleProvider"} {
		if err := e.UpdateResource(kind, ""); err != nil {
			t.Fatalf("empty named file %s was rejected as inline: %v", kind, err)
		}
	}
}

func TestEmptyNamedProvidersUpdateOnlyTheirExactResource(t *testing.T) {
	var requests [4]atomic.Int32
	paths := []string{"/proxy-empty", "/proxy-other", "/rule-empty", "/rule-other"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i, path := range paths {
			if r.URL.Path == path {
				requests[i].Add(1)
				if i < 2 {
					_, _ = w.Write([]byte("proxies: [{name: fixture, type: direct}]\n"))
				} else {
					_, _ = w.Write([]byte("example.com\n"))
				}
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer server.Close()
	body := validConfig + fmt.Sprintf(`proxy-providers:
 '': {type: http, url: '%[1]s/proxy-empty', path: proxy-empty.yaml, interval: 0, health-check: {enable: false}}
 other: {type: http, url: '%[1]s/proxy-other', path: proxy-other.yaml, interval: 0, health-check: {enable: false}}
rule-providers:
 '': {type: http, behavior: domain, format: text, url: '%[1]s/rule-empty', path: rule-empty.txt, interval: 0}
 other: {type: http, behavior: domain, format: text, url: '%[1]s/rule-other', path: rule-other.txt, interval: 0}
`, server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if e.cfg.Providers[""] == nil || e.cfg.RuleProviders[""] == nil {
		t.Fatal("empty named providers were not retained by the parsed configuration")
	}
	for _, kind := range []string{"proxyProvider", "ruleProvider"} {
		var before [4]int32
		for i := range requests {
			before[i] = requests[i].Load()
		}
		if err := e.UpdateResource(kind, ""); err != nil {
			t.Fatalf("empty named %s update was rejected: %v", kind, err)
		}
		selected := 0
		if kind == "ruleProvider" {
			selected = 2
		}
		for i := range requests {
			want := before[i]
			if i == selected {
				want++
			}
			if got := requests[i].Load(); got != want {
				t.Fatalf("%s empty name selected wrong resource %s: got %d requests, want %d", kind, paths[i], got, want)
			}
		}
	}
	for _, kind := range []string{"geo", "", "unknown"} {
		if err := e.UpdateResource(kind, ""); err == nil {
			t.Fatalf("empty name unexpectedly enabled bulk or invalid resource kind %q", kind)
		}
	}
	emptyProxy, emptyRule := e.cfg.Providers[""], e.cfg.RuleProviders[""]
	delete(e.cfg.Providers, "")
	delete(e.cfg.RuleProviders, "")
	defer func() {
		e.cfg.Providers[""] = emptyProxy
		e.cfg.RuleProviders[""] = emptyRule
	}()
	// Restore the actual provider map before cleanup and retain exact provider identity.
	for _, kind := range []string{"proxyProvider", "ruleProvider"} {
		if err := e.UpdateResource(kind, ""); err == nil {
			t.Fatalf("absent empty named %s was accepted", kind)
		}
	}
}
