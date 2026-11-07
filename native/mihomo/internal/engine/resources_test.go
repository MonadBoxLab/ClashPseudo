package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreview"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func TestResourcesListProvidersAndGeoWithOriginalSources(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	requested := make(chan struct{}, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		select {
		case requested <- struct{}{}:
		default:
		}
		fmt.Fprintln(w, "proxies: [{name: remote-node, type: direct}]")
	}))
	defer server.Close()
	var e Engine
	body := []byte(fmt.Sprintf(`proxy-providers:
 remote:
  type: http
  url: %s/sub?token=secret
  path: remote.yaml
  interval: 3600
  health-check: {enable: false}
rule-providers:
 inline:
  type: inline
  behavior: domain
  payload: ['+.example.test']
rules:
 - MATCH,DIRECT
`, strings.Replace(server.URL, "http://", "http://secret-user:secret-pass@", 1)))
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	select {
	case <-requested:
	case <-time.After(2 * time.Second):
		t.Fatal("provider did not fetch the controlled loopback source")
	}
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var result coreview.ResourceList
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Resources) != 6 {
		t.Fatalf("resources: %+v", result.Resources)
	}
	geo := 0
	for _, resource := range result.Resources {
		switch resource.Kind {
		case "geo":
			geo++
			if resource.AutoUpdateTarget == nil || resource.FileStatus == "" {
				t.Fatal("geo state was not explicit")
			}
		case "ruleProvider":
			if resource.Name != "inline" || resource.UpdateSupported {
				t.Fatal(resource)
			}
		case "proxyProvider":
			expected := strings.Replace(server.URL, "http://", "http://secret-user:secret-pass@", 1) + "/sub?token=secret"
			if resource.Name != "remote" || resource.Source != expected {
				t.Fatal(resource)
			}
		}
	}
	if geo != 4 {
		t.Fatal(geo)
	}
	if err := e.UpdateResource("ruleProvider", "inline"); err == nil {
		t.Fatal("inline update accepted")
	}
	if err := e.UpdateResource("proxyProvider", "missing"); err == nil {
		t.Fatal("missing provider accepted")
	}
	if err := e.UpdateResource("geo", "Bogus"); err == nil {
		t.Fatal("invalid geo accepted")
	}
}

func TestResourcePathsPreserveHTTPVehiclesAndGeoGetterSnapshots(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/proxy":
			fmt.Fprintln(w, "proxies: [{name: remote-node, type: direct}]")
		case "/rules":
			fmt.Fprintln(w, "payload: ['+.example.test']")
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	home := t.TempDir()
	source := strings.Replace(server.URL, "http://", "http://user:password@", 1)
	body := []byte(fmt.Sprintf(`proxy-providers:
 remote:
  type: http
  url: %s/proxy?token=original
  path: providers/原文🙂-proxy.yaml
  interval: 0
  health-check: {enable: false}
rule-providers:
 remote-rules:
  type: http
  behavior: domain
  format: yaml
  url: %s/rules?token=original
  path: providers/原文🙂-rules.yaml
  interval: 0
rules: ['MATCH,DIRECT']
`, source, source))
	var e Engine
	if err := e.Prepare(home, body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var result coreview.ResourceList
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{
		"proxyProvider/remote":      filepath.Join(home, "providers/原文🙂-proxy.yaml"),
		"ruleProvider/remote-rules": filepath.Join(home, "providers/原文🙂-rules.yaml"),
		"geo/GeoIP":                 e.geoPaths[0],
		"geo/MMDB":                  e.geoPaths[1],
		"geo/ASN":                   e.geoPaths[2],
		"geo/GeoSite":               e.geoPaths[3],
	}
	if len(result.Resources) != len(expected) {
		t.Fatalf("resources: %+v", result.Resources)
	}
	for _, item := range result.Resources {
		key := item.Kind + "/" + item.Name
		path, ok := expected[key]
		if !ok || path == "" || item.Path != path {
			t.Fatalf("%s path = %q, want %q", key, item.Path, path)
		}
		delete(expected, key)
		switch item.Kind {
		case "proxyProvider":
			if item.VehicleType != "HTTP" || item.Source != source+"/proxy?token=original" {
				t.Fatal(item)
			}
		case "ruleProvider":
			if item.VehicleType != "HTTP" || item.Source != source+"/rules?token=original" {
				t.Fatal(item)
			}
		}
	}
	if len(expected) != 0 {
		t.Fatalf("missing resource paths: %v", expected)
	}
}

type emptyResourceProxyProvider struct{ P.ProxyProvider }

func (emptyResourceProxyProvider) VehicleType() P.VehicleType { return P.Inline }
func (emptyResourceProxyProvider) Count() int                 { return 0 }
func (emptyResourceProxyProvider) Version() uint32            { return 0 }
func (emptyResourceProxyProvider) Proxies() []C.Proxy         { return nil }

func TestResourcesKeepKnownZeroProviderCountsWithoutInventingGeoCounts(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rule-providers:\n empty: {type: inline, behavior: domain, payload: []}\nrules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	e.cfg.Providers["empty"] = emptyResourceProxyProvider{}
	defer delete(e.cfg.Providers, "empty")
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Resources []map[string]json.RawMessage `json:"resources"`
	}
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	providers, geo := 0, 0
	for _, item := range result.Resources {
		var kind string
		if err := json.Unmarshal(item["kind"], &kind); err != nil {
			t.Fatal(err)
		}
		count, known := item["count"]
		if kind == "geo" {
			geo++
			if known {
				t.Errorf("Geo acquired an unsupported count: %s", count)
			}
		} else {
			providers++
			if !known || string(count) != "0" {
				t.Errorf("%s known zero count omitted: %s", kind, count)
			}
		}
	}
	if providers != 2 || geo != 4 {
		t.Fatalf("unexpected resource coverage: providers=%d geo=%d", providers, geo)
	}
}

func TestDiagnosticSourceMetadataReleasedOnStop(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	body := []byte(`provider-template: &providers
 z-provider: {type: inline, interval: '3600', payload: [{name: z, type: direct}]}
 a-provider: {type: inline, payload: [{name: a, type: direct}]}
config-template: &config
 rule-providers:
  z-rules: {type: inline, behavior: domain, payload: [z.test]}
  a-rules: {type: inline, behavior: domain, payload: [a.test]}
<<: *config
proxy-providers:
 <<: *providers
 m-provider: {type: inline, payload: [{name: m, type: direct}]}
proxies: [{name: z-top, type: direct}, {name: a-top, type: direct}]
rules: ['MATCH,DIRECT']
`)
	var e Engine
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(e.sources, coreview.DiagnosticSources{}) {
		t.Fatalf("metadata retained after Stop: %+v", e.sources)
	}
}

func TestResourcesAndDiagnosticScopesRetainComposedDeclarationOrder(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	body := []byte(`proxy-template: &proxies
 z-last-alphabetically:
  type: inline
  payload: [{name: same, type: direct}]
 a-first-alphabetically:
  type: inline
  payload: [{name: same, type: direct}]
proxy-providers: *proxies
rule-providers:
 z-rules:
  type: inline
  behavior: domain
  payload: [z.test]
 a-rules:
  type: inline
  behavior: domain
  payload: [a.test]
sub-rules:
 z-sub: ['DOMAIN,z.test,DIRECT']
 a-sub: ['DOMAIN,a.test,DIRECT']
rules: ['MATCH,DIRECT']
`)
	part := configinput.Override{ID: "part", Revision: 1, Mode: "prepend", Body: `proxy-providers:
 m-added: {type: inline, payload: [{name: same, type: direct}]}
rule-providers:
 m-rules: {type: inline, behavior: domain, payload: [m.test]}
sub-rules:
 m-sub: ['DOMAIN,m.test,DIRECT']
`}
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }, part); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var resources coreview.ResourceList
	if err := json.Unmarshal([]byte(value), &resources); err != nil {
		t.Fatal(err)
	}
	var proxies, rules []string
	for _, item := range resources.Resources {
		switch item.Kind {
		case "proxyProvider":
			proxies = append(proxies, item.Name)
		case "ruleProvider":
			rules = append(rules, item.Name)
		}
	}
	if strings.Join(proxies, ",") != "z-last-alphabetically,a-first-alphabetically,m-added" || strings.Join(rules, ",") != "z-rules,a-rules,m-rules" {
		t.Errorf("resource declaration order: proxies=%v rules=%v", proxies, rules)
	}
	page := readRulePage(t, &e, coreview.RuleQuery{Kind: "main"})
	var scopes, subScopes []string
	for _, scope := range page.Scopes {
		if scope.Kind == "provider" {
			scopes = append(scopes, scope.Name)
		} else if scope.Kind == "sub" {
			subScopes = append(subScopes, scope.Name)
		}
	}
	if strings.Join(subScopes, ",") != "z-sub,a-sub,m-sub" {
		t.Errorf("sub-rules declaration order changed: %v", subScopes)
	}
	if strings.Join(scopes, ",") != strings.Join(rules, ",") || strings.Join(scopes, ",") != "z-rules,a-rules,m-rules" {
		t.Errorf("rule scopes lost declaration order: %v", scopes)
	}
	nodes, _, err := readNodeStream(t, &e, nil)
	if err != nil {
		t.Fatal(err)
	}
	var sources []string
	for _, node := range nodes {
		if node.Name != "same" {
			continue
		}
		sources = append(sources, node.Source)
	}
	if strings.Join(sources, ",") != "z-last-alphabetically,a-first-alphabetically,m-added" {
		t.Errorf("node sources lost declaration order: %v", sources)
	}
}

func TestResourcesGeoProjectionSeparatesFileTimeFromUpdateTime(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	// Hold the projection test's update execution until cancellation.
	e.updateMu.Lock()
	defer func() {
		e.Cancel()
		e.updateMu.Unlock()
		requireStop(t, &e)
	}()
	body := []byte("geo-auto-update: true\ngeo-update-interval: 7\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	// File-stat input containing deliberately invalid database bytes.
	path := e.geoPaths[3]
	if err := os.WriteFile(path, []byte("not-a-database"), 0600); err != nil {
		t.Fatal(err)
	}
	mtime := time.Unix(1700000000, 0)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Resources []struct {
			Kind                  string     `json:"kind"`
			Name                  string     `json:"name"`
			AutoUpdate            *bool      `json:"autoUpdate"`
			UpdateIntervalSeconds *int       `json:"updateIntervalSeconds"`
			UpdatedAt             *time.Time `json:"updatedAt"`
			UpdatedAtSource       string     `json:"updatedAtSource"`
			FileModifiedAt        *time.Time `json:"fileModifiedAt"`
			LastAttempt           *time.Time `json:"lastAttempt"`
			LastResult            string     `json:"lastResult"`
			LastSuccessfulCheck   *time.Time `json:"lastSuccessfulCheck"`
		} `json:"resources"`
	}
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	for _, item := range result.Resources {
		if item.Kind != "geo" {
			continue
		}
		if item.AutoUpdate == nil || !*item.AutoUpdate || item.UpdateIntervalSeconds == nil || *item.UpdateIntervalSeconds != 7*3600 {
			t.Errorf("Geo automatic settings absent: %+v", item)
		}
		if item.UpdatedAt != nil || item.UpdatedAtSource != "unknown" {
			t.Errorf("Geo file stat masqueraded as actual update: %+v", item)
		}
		if item.Name == "GeoSite" && (item.FileModifiedAt == nil || !item.FileModifiedAt.Equal(mtime)) {
			t.Errorf("Geo file modification fact absent: %+v", item)
		}
	}
	for _, item := range result.Resources {
		if item.Kind == "geo" && (item.LastAttempt != nil || item.LastResult != "" || item.LastSuccessfulCheck != nil) {
			t.Error("Go retained application Geo history", item)
		}
	}

}

type heldUpdateProvider struct {
	P.ProxyProvider
	started chan struct{}
	release chan struct{}
	closed  chan struct{}
	err     error
}

// Hold an external-provider operation while the inline provider supplies immutable
// cleanup-test nodes.
func (p *heldUpdateProvider) VehicleType() P.VehicleType { return P.HTTP }

func (p *heldUpdateProvider) Update() error {
	close(p.started)
	<-p.release
	return p.err
}

func (p *heldUpdateProvider) Close() error {
	close(p.closed)
	return closeResource(p.ProxyProvider)
}

func TestStopCancelsAndJoinsAcceptedManualProviderUpdate(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for label, outcome := range map[string]error{
		"success": nil,
		"failure": errors.New("https://user:pass@fixture.test/?token=原文🙂\nAuthorization: Bearer fixture"),
	} {
		t.Run(label, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			body := validConfig + "proxy-providers:\n fixture:\n  type: inline\n  payload: [{name: fixture, type: direct}]\n  health-check: {enable: false}\n"
			if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			provider := &heldUpdateProvider{ProxyProvider: e.cfg.Providers["fixture"], err: outcome,
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
			if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
				t.Fatal("new context accepted while manual provider update was still running")
			}
			release.Do(func() { close(provider.release) })
			if err := <-updated; err != outcome {
				t.Fatalf("actual update outcome changed after Stop: got %v want %v", err, outcome)
			}
			if err := <-stopped; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestDecodeResourceUpdateRequiresExplicitStringName(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	if isolateEngineTest(t) {
		return
	}
	body := validConfig + `proxy-providers:
 '': {type: inline, payload: [{name: empty-fixture, type: direct}], health-check: {enable: false}}
 fixture: {type: inline, payload: [{name: fixture, type: direct}], health-check: {enable: false}}
rule-providers:
 '': {type: inline, behavior: domain, payload: ['example.com']}
 fixture: {type: inline, behavior: domain, payload: ['example.org']}
`
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
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
	if isolateEngineTest(t) {
		return
	}
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
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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
	if isolateEngineTest(t) {
		return
	}
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
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
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
