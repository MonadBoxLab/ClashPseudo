package engine

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"

	"clashpseudo/native/internal/configinput"
)

func TestResourcesListProvidersAndGeoWithoutSecrets(t *testing.T) {
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
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
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
	if strings.Contains(value, "secret") || strings.Contains(value, "/sub") {
		t.Fatal("resource listing exposed source secrets")
	}
	var result ResourceList
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
			if resource.Name != "remote" || resource.Source != server.URL+"/…" {
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

type emptyResourceProxyProvider struct{ P.ProxyProvider }

func (emptyResourceProxyProvider) VehicleType() P.VehicleType { return P.Inline }
func (emptyResourceProxyProvider) Count() int                 { return 0 }

func TestResourcesKeepKnownZeroProviderCountsWithoutInventingGeoCounts(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rule-providers:\n empty: {type: inline, behavior: domain, payload: []}\nrules: ['MATCH,DIRECT']\n"), "rule", nil, func(int) bool { return true }); err != nil {
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

func TestDiagnosticSourceMetadataPreservesAliasesAndMergeKeys(t *testing.T) {
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
	raw, err := config.UnmarshalRawConfig(body)
	if err != nil {
		t.Fatal(err)
	}
	metadata, err := readDiagnosticSources(body, raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(metadata.proxyProviders, ",") != "m-provider,z-provider,a-provider" || strings.Join(metadata.ruleProviders, ",") != "z-rules,a-rules" || strings.Join(metadata.proxies, ",") != "z-top,a-top" || metadata.proxyIntervals["z-provider"] != 3600 {
		t.Fatalf("declaration/interval metadata = %+v", metadata)
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if len(e.sources.proxyProviders) != 0 || len(e.sources.ruleProviders) != 0 || len(e.sources.proxies) != 0 || len(e.sources.proxyIntervals) != 0 || len(e.sources.ruleIntervals) != 0 {
		t.Fatalf("metadata retained after Stop: %+v", e.sources)
	}
}

func TestProviderUpdatePolicyKeepsConfiguredUnitsAndInlineUnavailable(t *testing.T) {
	for _, fixture := range []struct {
		vehicle P.VehicleType
		seconds int
		auto    bool
	}{
		{P.HTTP, 3600, true}, {P.HTTP, 0, false}, {P.File, 0, true}, {P.Inline, 0, false},
	} {
		var entry Resource
		providerUpdatePolicy(&entry, fixture.vehicle, fixture.seconds)
		if fixture.vehicle == P.Inline {
			if entry.AutoUpdate != nil || entry.UpdateIntervalSeconds != nil {
				t.Fatalf("inline provider advertised an external update policy: %+v", entry)
			}
			continue
		}
		if entry.AutoUpdate == nil || *entry.AutoUpdate != fixture.auto {
			t.Fatalf("configured automatic policy = %+v", entry)
		}
		if fixture.vehicle == P.HTTP && (entry.UpdateIntervalSeconds == nil || *entry.UpdateIntervalSeconds != fixture.seconds) {
			t.Fatalf("HTTP interval not in seconds: %+v", entry)
		}
		if fixture.vehicle == P.File && entry.UpdateIntervalSeconds != nil {
			t.Fatal("file watcher represented as a polling interval")
		}
	}
}

func TestResourcesAndDiagnosticScopesRetainComposedDeclarationOrder(t *testing.T) {
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
rules: ['MATCH,DIRECT']
`)
	part := configinput.Override{ID: "part", Revision: 1, Mode: "prepend", Body: `proxy-providers:
 m-added: {type: inline, payload: [{name: same, type: direct}]}
rule-providers:
 m-rules: {type: inline, behavior: domain, payload: [m.test]}
`}
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }, part); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	value, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var resources ResourceList
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
	page := readRulePage(t, &e, RuleQuery{Kind: "main", Limit: 1})
	var scopes []string
	for _, scope := range page.Scopes {
		if scope.Kind == "provider" {
			scopes = append(scopes, scope.Name)
		}
	}
	if strings.Join(scopes, ",") != strings.Join(rules, ",") || strings.Join(scopes, ",") != "z-rules,a-rules,m-rules" {
		t.Errorf("rule scopes lost declaration order: %v", scopes)
	}
	value, err = e.Nodes(NodeQuery{Limit: 100, Search: "same"})
	if err != nil {
		t.Fatal(err)
	}
	var nodes NodePage
	if err := json.Unmarshal([]byte(value), &nodes); err != nil {
		t.Fatal(err)
	}
	var sources []string
	for _, node := range nodes.Nodes {
		sources = append(sources, node.Source)
	}
	if strings.Join(sources, ",") != "z-last-alphabetically,a-first-alphabetically,m-added" {
		t.Errorf("node sources lost declaration order: %v", sources)
	}
}

func TestResourcesGeoProjectionSeparatesFileTimeFromUpdateTime(t *testing.T) {
	var e Engine
	// Hold the projection test's update execution until cancellation.
	e.updateMu.Lock()
	defer func() {
		e.Cancel()
		e.updateMu.Unlock()
		requireStop(t, &e)
	}()
	body := []byte("geo-auto-update: true\ngeo-update-interval: 7\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
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
	attempt, checked := mtime.Add(time.Hour), mtime.Add(30*time.Minute)
	e.mu.Lock()
	e.geoResults = map[string]geoUpdateState{"GeoSite": {LastAttempt: attempt, LastResult: "failed", LastSuccessfulCheck: checked}}
	e.mu.Unlock()
	value, err = e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(value), &result); err != nil {
		t.Fatal(err)
	}
	for _, item := range result.Resources {
		if item.Kind == "geo" && item.Name == "GeoSite" {
			if item.LastAttempt == nil || !item.LastAttempt.Equal(attempt) || item.LastResult != "failed" || item.LastSuccessfulCheck == nil || !item.LastSuccessfulCheck.Equal(checked) {
				t.Errorf("Geo session result not projected: %+v", item)
			}
			if item.UpdatedAt != nil || item.UpdatedAtSource != "unknown" || item.FileModifiedAt == nil || !item.FileModifiedAt.Equal(mtime) {
				t.Errorf("Geo check time confused with download/file time: %+v", item)
			}
		}
	}
}

func TestRedactSourceNeverKeepsUserInfoOrPath(t *testing.T) {
	if redactSource("") != "" {
		t.Fatal()
	}
	if redactSource("not a url") != "[redacted]" {
		t.Fatal()
	}
	if got := redactSource("https://u:p@host.test/a?b=c"); got != "https://host.test/…" {
		t.Fatal(got)
	}
}
