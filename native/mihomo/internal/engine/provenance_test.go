package engine

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreview"
)

var provenanceMain = configinput.ConfigOrigin{ID: "main-id", Revision: 7, Name: "Loaded main"}

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

func TestProvenanceEngineQueriesKeepCapturedOriginsAndProviderContentSeparate(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		runEnginePhase(t, home, "composed")
		runEnginePhase(t, home, "fresh")
		return
	}
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
	if phase == "fresh" {
		if err := e.PrepareWithOptions(home, body, "rule", func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", MainOrigin: provenanceMain}); err != nil {
			t.Fatal(err)
		}
		defer requireStop(t, &e)
		requireContributors(t, e.provenance.Definition("proxies", "shared"), "main-id")
		return
	}
	if err := e.PrepareWithOptions(home, body, "rule", func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", MainOrigin: provenanceMain}, part); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	part.Name = "Later disk rename"
	nodes, _, err := readNodeStream(t, &e, nil)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(nodes)
	if err != nil {
		t.Fatal(err)
	}
	value := string(encoded)
	seenDirect, seenProvider := false, false
	for _, node := range nodes {
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
		case node.SourceKind == "configuration":
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
	var resources coreview.ResourceList
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
	main := readRulePage(t, &e, coreview.RuleQuery{Kind: "main"})
	requireContributors(t, main.Rows[0].Provenance, "local")
	requireContributors(t, main.Rows[1].Provenance, "main-id")
	if main.Rows[0].Payload != main.Rows[1].Payload || main.Rows[1].Provenance.Contributors[0].Path != "/rules/0" || main.Rows[1].Index != 2 {
		t.Fatal("duplicate rule used text matching instead of the original index", main)
	}
	sub := readRulePage(t, &e, coreview.RuleQuery{Kind: "sub", Name: "branch"})
	requireContributors(t, sub.Rows[0].Provenance, "local")
	requireContributors(t, sub.Rows[1].Provenance, "main-id")
	var provider ruleStreamSnapshot
	_, err = e.StreamRules(context.Background(), coreview.RuleQuery{Kind: "provider", Name: "file-rules"}, func(value any) error {
		body, err := json.Marshal(value)
		if err != nil {
			return err
		}
		return json.Unmarshal(body, &provider)
	}, func(any) error { t.Error("external classical source exported a substitute parsed record"); return nil })
	if err == nil || !strings.Contains(err.Error(), "sourceUnavailable") {
		t.Fatal(err)
	}
	for _, scope := range provider.Scopes {
		if scope.Kind == "provider" && scope.Name == "file-rules" {
			requireContributors(t, scope.Provenance, "local", "main-id")
		}
	}
	if err := e.Stop(); err != nil || e.provenance != nil {
		t.Fatalf("stopped composition retained origins: %v", err)
	}

}
