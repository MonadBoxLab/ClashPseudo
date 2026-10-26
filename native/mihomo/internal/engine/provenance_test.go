package engine

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"

	"clashpseudo/native/internal/configinput"
)

var provenanceMain = configinput.ConfigOrigin{ID: "main-id", Revision: 7, Name: "Loaded main"}

func provenanceFixture(t *testing.T, body string, parts ...configinput.Override) (map[string]any, *configinput.Provenance) {
	t.Helper()
	text, provenance, err := configinput.ComposeWithProvenance([]byte(body), parts, provenanceMain)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := yaml.Unmarshal(text, &value); err != nil {
		t.Fatal(err)
	}
	return value, provenance
}

func provenancePart(id, mode, body string) configinput.Override {
	return configinput.Override{ID: id, Revision: 3, Name: "Loaded " + id, Mode: mode, Body: body}
}

func requireContributors(t *testing.T, definition *configinput.DefinitionProvenance, ids ...string) {
	t.Helper()
	if definition == nil {
		t.Fatal("missing definition provenance")
	}
	got := make([]string, 0, len(definition.Contributors))
	for _, source := range definition.Contributors {
		got = append(got, source.ID)
		if source.Kind != "config" && source.Kind != "plugin" {
			t.Fatalf("fabricated or missing source kind: %+v", source)
		}
		if source.Path == "" || source.Revision < 1 || source.Name == "" {
			t.Fatalf("loaded input identity/path lost: %+v", source)
		}
	}
	if !reflect.DeepEqual(got, ids) {
		t.Fatalf("contributors = %v, want %v; details=%+v", got, ids, definition.Contributors)
	}
}

func TestProvenanceLargeInlinePayloadHasConstantSummaryWireSize(t *testing.T) {
	var previous []byte
	for _, count := range []int{1, 8192} {
		var body strings.Builder
		body.WriteString("proxy-providers:\n 'provider/~':\n  type: inline\n  payload:\n")
		for index := 0; index < count; index++ {
			fmt.Fprintf(&body, "   - {name: n%d, type: direct, note: do-not-copy-this-payload-%d}\n", index, index)
		}
		body.WriteString("rule-providers:\n rp:\n  type: inline\n  behavior: domain\n  payload:\n")
		for index := 0; index < count; index++ {
			fmt.Fprintf(&body, "   - n%d.example.test\n", index)
		}
		part := provenancePart("plugin", "replace", "proxy-providers: {'provider/~': {health-check: {enable: false}}}\nrule-providers: {rp: {format: yaml}}\n")
		_, provenance := provenanceFixture(t, body.String(), part)
		proxy := provenance.Definition("proxy-providers", "provider/~")
		rules := provenance.Definition("rule-providers", "rp")
		requireContributors(t, proxy, "plugin", "main-id")
		requireContributors(t, rules, "plugin", "main-id")
		if proxy.Contributors[0].Path != "/proxy-providers/provider~1~0" {
			t.Fatal("provider name was not pointer-escaped", proxy)
		}
		wire, err := json.Marshal([]Resource{{Kind: "proxyProvider", Name: "provider/~", Provenance: proxy}, {Kind: "ruleProvider", Name: "rp", Provenance: rules}})
		if err != nil || bytes.Contains(wire, []byte("payload")) || bytes.Contains(wire, []byte("fields")) || bytes.Contains(wire, []byte("paths")) {
			t.Fatalf("summary expands internal leaves: %s %v", wire, err)
		}
		if previous != nil && !bytes.Equal(previous, wire) {
			t.Fatalf("provenance grew with %d inline entries: small=%d large=%d", count, len(previous), len(wire))
		}
		previous = wire
		t.Logf("%d proxy and %d rule payload entries: combined resource-summary wire=%d bytes", count, count, len(wire))
	}
}

func TestProvenanceLargePrependedPayloadStillFindsTheLastInputSource(t *testing.T) {
	const body = "proxy-providers: {p: {type: inline, payload: [{name: last-main, type: direct}]}}\n"
	var previous []byte
	for _, count := range []int{1, 8192} {
		var fragment strings.Builder
		fragment.WriteString("proxy-providers:\n p:\n  type: inline\n  payload:\n")
		for index := 0; index < count; index++ {
			fmt.Fprintf(&fragment, "   - {name: prefix%d, type: direct}\n", index)
		}
		value, provenance := provenanceFixture(t, body, provenancePart("plugin", "prepend", fragment.String()))
		payload := value["proxy-providers"].(map[string]any)["p"].(map[string]any)["payload"].([]any)
		if len(payload) != count+1 || payload[count].(map[string]any)["name"] != "last-main" {
			t.Fatal("real prepend dropped the last item")
		}
		// Every earlier value, including type, is plugin-owned. The main input
		// contributes only the final payload item, beyond any first-N shortcut.
		definition := provenance.Definition("proxy-providers", "p")
		requireContributors(t, definition, "plugin", "main-id")
		wire, err := json.Marshal(definition)
		if err != nil || (previous != nil && !bytes.Equal(previous, wire)) {
			t.Fatalf("large prepend expanded or truncated attribution: count=%d bytes=%d err=%v", count, len(wire), err)
		}
		previous = wire
		t.Logf("%d prepended items plus last main-only contribution: provenance=%d bytes", count, len(wire))
	}
}

func TestProvenanceEngineQueriesKeepCapturedOriginsAndProviderContentSeparate(t *testing.T) {
	home := t.TempDir()
	for name, body := range map[string]string{
		"nodes.yaml": "proxies: [{name: shared, type: direct}]\n",
		"rules.yaml": "payload: ['DOMAIN,provider.test']\n",
	} {
		if err := os.WriteFile(filepath.Join(home, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	body := []byte(`dns: {enable: false}
proxies:
 - {name: shared, type: socks5, server: 127.0.0.1, port: 9, password: source-secret}
proxy-providers:
 file-nodes: {type: file, path: nodes.yaml, health-check: {enable: false}}
rule-providers:
 file-rules: {type: file, behavior: classical, path: rules.yaml}
sub-rules:
 branch: ['DOMAIN,sub.test,DIRECT']
rules: ['DOMAIN,same.test,DIRECT', 'DOMAIN,same.test,DIRECT', 'MATCH,DIRECT']
`)
	part := provenancePart("local", "prepend", `proxies:
 - {name: shared, server: 127.0.0.2}
proxy-providers:
 file-nodes: {filter: shared}
rule-providers:
 file-rules: {format: yaml}
sub-rules:
 branch: ['DOMAIN,sub.test,DIRECT']
rules: ['DOMAIN,same.test,DIRECT']
`)
	part.Role = "localCustom"
	var e Engine
	if err := e.PrepareWithOptions(home, body, "rule", nil, func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", MainOrigin: provenanceMain}, part); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	part.Name = "Later disk rename"
	value, err := e.Nodes(NodeQuery{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	var nodes NodePage
	if err := json.Unmarshal([]byte(value), &nodes); err != nil {
		t.Fatal(err)
	}
	seenDirect, seenProvider := false, false
	for _, node := range nodes.Nodes {
		switch {
		case node.Name == "shared" && node.SourceKind == "configuration":
			seenDirect = true
			requireContributors(t, node.Provenance, "local", "main-id")
			if node.Provenance.Contributors[0].Name != "Loaded local" || node.ProviderProvenance != nil {
				t.Fatal("direct definition used current metadata/provider origin", node)
			}
		case node.Name == "shared" && node.SourceKind == "proxyProvider":
			seenProvider = true
			if node.Provenance != nil || node.Source != "file-nodes" {
				t.Fatal("downloaded/file content was attributed as direct plugin definition", node)
			}
			requireContributors(t, node.ProviderProvenance, "local", "main-id")
		case node.Builtin:
			if node.Provenance != nil || node.ProviderProvenance != nil {
				t.Fatal("builtin given source provenance", node)
			}
		}
	}
	if !seenDirect || !seenProvider || strings.Contains(value, "source-secret") {
		t.Fatalf("missing nodes or source value leakage: %s", value)
	}
	resourcesText, err := e.Resources()
	if err != nil {
		t.Fatal(err)
	}
	var resources ResourceList
	if err := json.Unmarshal([]byte(resourcesText), &resources); err != nil {
		t.Fatal(err)
	}
	providers := 0
	for _, resource := range resources.Resources {
		if resource.Kind == "proxyProvider" || resource.Kind == "ruleProvider" {
			providers++
			requireContributors(t, resource.Provenance, "local", "main-id")
		}
	}
	if providers != 2 {
		t.Fatal(resources)
	}
	main := readRulePage(t, &e, RuleQuery{Kind: "main", Limit: 1})
	requireContributors(t, main.Rows[0].Provenance, "local")
	next := readRulePage(t, &e, RuleQuery{Kind: "main", Offset: 1, Limit: 1, Token: main.Token})
	requireContributors(t, next.Rows[0].Provenance, "main-id")
	if main.Rows[0].Payload != next.Rows[0].Payload || next.Rows[0].Provenance.Contributors[0].Path != "/rules/0" || next.Rows[0].Index != 2 {
		t.Fatal("duplicate rules were looked up by text or paged index", main, next)
	}
	sub := readRulePage(t, &e, RuleQuery{Kind: "sub", Name: "branch", Limit: 100})
	requireContributors(t, sub.Rows[0].Provenance, "local")
	requireContributors(t, sub.Rows[1].Provenance, "main-id")
	provider := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "file-rules", Limit: 100})
	requireContributors(t, provider.ProviderProvenance, "local", "main-id")
	if provider.Origin != "cache-source" || len(provider.Rows) != 1 || provider.Rows[0].Provenance != nil {
		t.Fatal("provider definition and file content provenance were conflated", provider)
	}
	for _, scope := range provider.Scopes {
		if scope.Kind == "provider" && scope.Name == "file-rules" {
			requireContributors(t, scope.Provenance, "local", "main-id")
		}
	}
	if err := e.Stop(); err != nil || e.provenance != nil {
		t.Fatalf("stopped composition retained origins: %v", err)
	}
	if err := e.PrepareWithOptions(home, body, "rule", nil, func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", MainOrigin: provenanceMain}); err != nil {
		t.Fatal(err)
	}
	requireContributors(t, e.provenance.Definition("proxies", "shared"), "main-id")
}
