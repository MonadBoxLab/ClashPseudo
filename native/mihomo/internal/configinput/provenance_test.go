package configinput

import (
	"bytes"
	"encoding/json"
	"go.yaml.in/yaml/v3"
	"reflect"
	"testing"
)

var provenanceMain = ConfigOrigin{ID: "main-id", Revision: 7, Name: "Loaded main"}

func provenanceFixture(t *testing.T, body string, parts ...Override) (map[string]any, *Provenance) {
	t.Helper()
	text, provenance, err := ComposeWithProvenance([]byte(body), parts, provenanceMain)
	if err != nil {
		t.Fatal(err)
	}
	var value map[string]any
	if err := yaml.Unmarshal(text, &value); err != nil {
		t.Fatal(err)
	}
	return value, provenance
}

func provenancePart(id, mode, body string) Override {
	return Override{ID: id, Revision: 3, Name: "Loaded " + id, Mode: mode, Body: body}
}

func requireContributors(t *testing.T, definition *DefinitionProvenance, ids ...string) {
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

func TestProvenanceNamedPartialFieldsBothModes(t *testing.T) {
	const main = `proxies:
 - {name: retained, type: direct}
 - {name: shared, type: socks5, server: base.test, port: 80, password: retained-secret}
proxy-groups:
 - {name: group, type: select, proxies: [retained]}
`
	const fragment = `proxies:
 - {name: added, type: direct}
 - {name: shared, server: changed.test}
proxy-groups:
 - {name: group, proxies: [added]}
`
	for _, mode := range []string{"prepend", "replace"} {
		t.Run(mode, func(t *testing.T) {
			part := provenancePart("local-id", mode, fragment)
			part.Role = "localCustom"
			value, provenance := provenanceFixture(t, main, part)
			nodes := value["proxies"].([]any)
			for index, name := range []string{"added", "retained", "shared"} {
				if nodes[index].(map[string]any)["name"] != name {
					t.Fatalf("named-list slots changed: %v", nodes)
				}
			}
			shared := nodes[2].(map[string]any)
			if shared["server"] != "changed.test" || shared["type"] != "socks5" || shared["password"] != "retained-secret" {
				t.Fatalf("partial merge changed inherited fields: %v", shared)
			}
			origins := provenance.Definition("proxies", "shared")
			requireContributors(t, origins, "local-id", "main-id")
			if origins.Contributors[0].Path != "/proxies/1" || origins.Contributors[1].Path != "/proxies/1" || origins.Contributors[0].Role != "localCustom" {
				t.Fatalf("original definition indexes/role lost after new object prepended: %+v", origins)
			}
			requireContributors(t, provenance.Definition("proxies", "retained"), "main-id")
			requireContributors(t, provenance.Definition("proxies", "added"), "local-id")
			requireContributors(t, provenance.Definition("proxy-groups", "group"), "local-id", "main-id")
			members := value["proxy-groups"].([]any)[0].(map[string]any)["proxies"].([]any)
			want := 1
			if mode == "prepend" {
				want = 2
			}
			if len(members) != want || members[0] != "added" {
				t.Fatalf("member-list mode changed: %v", members)
			}
			if provenance.Definition("proxies", "DIRECT") != nil || provenance.Definition("proxy-groups", "missing") != nil {
				t.Fatal("builtin or absent definition received invented YAML provenance")
			}
			wire, err := json.Marshal(origins)
			if err != nil || bytes.Contains(wire, []byte("retained-secret")) || bytes.Contains(wire, []byte("fields")) {
				t.Fatalf("wire leaked values or an unused field table: %s %v", wire, err)
			}
		})
	}
}

func TestProvenanceFullReplacementDropsOverwrittenSourcesBothModes(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		t.Run(mode, func(t *testing.T) {
			value, provenance := provenanceFixture(t,
				"proxies: [{name: shared, type: socks5, server: main.test, port: 80}]\n",
				provenancePart("high", mode, "proxies: [{name: shared, type: http, server: high.test, port: 81}]\n"),
				provenancePart("low", mode, "proxies: [{name: shared, server: low.test}]\n"),
			)
			requireContributors(t, provenance.Definition("proxies", "shared"), "high")
			if got := value["proxies"].([]any)[0].(map[string]any); got["type"] != "http" || got["server"] != "high.test" || got["port"] != 81 {
				t.Fatal(got)
			}
			_, partial := provenanceFixture(t,
				"proxies: [{name: shared, type: socks5, server: main.test, port: 80}]\n",
				provenancePart("type-only", mode, "proxies: [{name: shared, type: http}]\n"),
			)
			requireContributors(t, partial.Definition("proxies", "shared"), "type-only", "main-id")
		})
	}
}

func TestProvenancePriorityReorderingUsesIDsAndOnlySurvivingFields(t *testing.T) {
	main := "proxies: [{name: shared, type: socks5, server: base.test, port: 80, password: retained}]\n"
	high := provenancePart("high", "replace", "proxies: [{name: shared, server: high.test, port: 81}]\n")
	middle := provenancePart("middle", "replace", "proxies: [{name: shared, udp: false}]\n")
	low := provenancePart("low", "replace", "proxies: [{name: shared, server: low.test}]\n")
	// Identical display names must neither collapse distinct IDs nor change order.
	high.Name, middle.Name, low.Name = "Same display name", "Same display name", "Same display name"
	value, first := provenanceFixture(t, main, high, middle, low)
	requireContributors(t, first.Definition("proxies", "shared"), "high", "middle", "main-id")
	if value["proxies"].([]any)[0].(map[string]any)["server"] != "high.test" {
		t.Fatal(value)
	}
	value, reordered := provenanceFixture(t, main, low, middle, high)
	requireContributors(t, reordered.Definition("proxies", "shared"), "low", "middle", "high", "main-id")
	if value["proxies"].([]any)[0].(map[string]any)["server"] != "low.test" {
		t.Fatal(value)
	}
	// Loaded composition metadata remains immutable across subsequent compositions.
	requireContributors(t, first.Definition("proxies", "shared"), "high", "middle", "main-id")
}

func TestProvenanceOrdinaryListsAndNestedMappingsBothModes(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		t.Run(mode, func(t *testing.T) {
			const main = `proxy-providers:
 p: {type: inline, payload: [{name: old, type: direct}]}
 nested: {health-check: {enable: true, url: retained}, headers: {X-Test: [old]}}
proxy-groups:
 - {name: group, type: select, proxies: [old]}
`
			const part = `proxy-providers:
 p: {type: inline, payload: [{name: new, type: direct}]}
 nested: {health-check: {enable: false}, headers: {X-Test: [new]}}
proxy-groups:
 - {name: group, type: select, proxies: [new]}
`
			value, provenance := provenanceFixture(t, main, provenancePart("plugin", mode, part))
			want := []string{"plugin"}
			count := 1
			if mode == "prepend" {
				want = append(want, "main-id")
				count = 2
			}
			requireContributors(t, provenance.Definition("proxy-providers", "p"), want...)
			requireContributors(t, provenance.Definition("proxy-groups", "group"), want...)
			requireContributors(t, provenance.Definition("proxy-providers", "nested"), "plugin", "main-id")
			providers := value["proxy-providers"].(map[string]any)
			payload := providers["p"].(map[string]any)["payload"].([]any)
			nested := providers["nested"].(map[string]any)
			if len(payload) != count || payload[0].(map[string]any)["name"] != "new" || nested["health-check"].(map[string]any)["enable"] != false || nested["health-check"].(map[string]any)["url"] != "retained" {
				t.Fatalf("real merge contract changed: %v", value)
			}
		})
	}
}

func TestProvenanceEmptyContainersExplicitValuesAndTypeConflicts(t *testing.T) {
	cases := []struct {
		name, base, part, mode string
		ids                    []string
	}{
		{"empty-prepend-noop", "{payload: []}", "{payload: []}", "prepend", []string{"main-id"}},
		{"empty-replace", "{payload: []}", "{payload: []}", "replace", []string{"plugin"}},
		{"empty-mapping-noop", "{}", "{}", "replace", []string{"main-id"}},
		{"empty-mapping-inherited", "{nested: {}}", "{nested: {}}", "prepend", []string{"main-id"}},
		{"map-to-sequence", "{field: {old: value}}", "{field: []}", "replace", []string{"plugin"}},
		{"sequence-to-map", "{field: [old]}", "{field: {}}", "prepend", []string{"plugin"}},
		{"explicit-null", "{field: {old: value}}", "{field: null}", "replace", []string{"plugin"}},
		{"false-zero-empty-string", "{a: true, b: 1, c: old}", "{a: false, b: 0, c: ''}", "prepend", []string{"plugin"}},
		{"null-definition", "{field: retained}", "null", "replace", []string{"plugin"}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			_, provenance := provenanceFixture(t, "proxy-providers: {p: "+test.base+"}\n",
				provenancePart("plugin", test.mode, "proxy-providers: {p: "+test.part+"}\n"))
			requireContributors(t, provenance.Definition("proxy-providers", "p"), test.ids...)
		})
	}
}

func TestProvenanceRulesKeepDuplicateDeclarationsAndSourceIndexes(t *testing.T) {
	const duplicate = "DOMAIN,same.test,DIRECT"
	main := "rules: ['" + duplicate + "', '" + duplicate + "', 'MATCH,DIRECT']\nsub-rules:\n 'branch/~': ['" + duplicate + "', '" + duplicate + "']\n"
	for _, mode := range []string{"prepend", "replace"} {
		t.Run(mode, func(t *testing.T) {
			high := provenancePart("high", mode, "rules: ['"+duplicate+"', '"+duplicate+"']\nsub-rules:\n 'branch/~': ['"+duplicate+"']\n")
			low := provenancePart("low", mode, "rules: ['"+duplicate+"']\n")
			value, provenance := provenanceFixture(t, main, high, low)
			ids := []string{"high", "high"}
			paths := []string{"/rules/0", "/rules/1"}
			if mode == "prepend" {
				ids = append(ids, "low", "main-id", "main-id", "main-id")
				paths = append(paths, "/rules/0", "/rules/0", "/rules/1", "/rules/2")
			}
			if len(value["rules"].([]any)) != len(ids) {
				t.Fatal("duplicate declarations were discarded", value)
			}
			for index, id := range ids {
				entry := provenance.Rule("", index)
				requireContributors(t, entry, id)
				if entry.Contributors[0].Path != paths[index] {
					t.Fatalf("final position %d was confused with source-local index: %+v", index, entry)
				}
			}
			sub := provenance.Rule("branch/~", 0)
			requireContributors(t, sub, "high")
			if sub.Contributors[0].Path != "/sub-rules/branch~1~0/0" {
				t.Fatal("sub-rule pointer escaping lost", sub)
			}
			if mode == "prepend" {
				requireContributors(t, provenance.Rule("branch/~", 1), "main-id")
				requireContributors(t, provenance.Rule("branch/~", 2), "main-id")
			} else if provenance.Rule("branch/~", 1) != nil {
				t.Fatal("replaced sub-rule still carries an old source")
			}
			if provenance.Rule("", -1) != nil || provenance.Rule("", len(ids)) != nil || provenance.Rule("missing", 0) != nil {
				t.Fatal("out-of-range or unknown rule source fabricated")
			}
		})
	}
	_, reordered := provenanceFixture(t, main,
		provenancePart("low", "prepend", "rules: ['"+duplicate+"']\n"),
		provenancePart("high", "prepend", "rules: ['"+duplicate+"']\n"))
	requireContributors(t, reordered.Rule("", 0), "low")
	requireContributors(t, reordered.Rule("", 1), "high")
}

func TestProvenanceNoEnabledOverridesPreservesRawTextAndLoadedMetadata(t *testing.T) {
	body := []byte("\xef\xbb\xbf# comments and ordering\r\ndefaults: &defaults {type: direct}\r\nproxies:\r\n - {name: aliased, <<: *defaults}\r\nproxy-providers:\r\n z: {type: inline, payload: []}\r\n a: {type: inline, payload: []}\r\nrules: ['MATCH,DIRECT']\r\n")
	before := bytes.Clone(body)
	// Go receives the already filtered list of enabled inputs.
	text, provenance, err := ComposeWithProvenance(body, nil, provenanceMain)
	if err != nil || !bytes.Equal(text, before) || !bytes.Equal(body, before) {
		t.Fatalf("no-enabled-override path serialized or mutated source: %q %v", text, err)
	}
	requireContributors(t, provenance.Definition("proxies", "aliased"), "main-id")
	for _, name := range []string{"z", "a"} {
		requireContributors(t, provenance.Definition("proxy-providers", name), "main-id")
	}
	_, anonymous, err := ComposeWithProvenance(body, nil, ConfigOrigin{})
	if err != nil {
		t.Fatal(err)
	}
	origin := anonymous.Definition("proxies", "aliased").Contributors[0]
	if origin.Kind != "config" || origin.ID != "" || origin.Revision != 0 || origin.Name != "" {
		t.Fatalf("zero ConfigOrigin invented identity: %+v", origin)
	}
	part := provenancePart("p", "replace", "proxies: [{name: aliased, type: http, server: loaded.test, port: 80}]\n")
	part.Role = "localCustom"
	_, loaded := provenanceFixture(t, string(body), part)
	part.Name, part.Role = "Latest disk name", ""
	_, latest := provenanceFixture(t, string(body), part)
	if loaded.Definition("proxies", "aliased").Contributors[0].Name != "Loaded p" || loaded.Definition("proxies", "aliased").Contributors[0].Role != "localCustom" || latest.Definition("proxies", "aliased").Contributors[0].Name != "Latest disk name" {
		t.Fatal("later input metadata replaced a previous composition")
	}
	var absent *Provenance
	if absent.Definition("proxies", "x") != nil || absent.Rule("", 0) != nil {
		t.Fatal("missing composition produced a fake source")
	}
}

func TestProvenanceDoesNotPublishAnIncompleteComposition(t *testing.T) {
	badBodies := []string{"[]", "dns: [", "dns: *missing", "dns: {}\n---\ndns: {}"}
	for _, bad := range badBodies {
		for _, mainBad := range []bool{false, true} {
			body := []byte("rules: ['MATCH,DIRECT']\n")
			part := provenancePart("plugin", "replace", bad)
			if mainBad {
				body, part.Body = []byte(bad), "{}"
			}
			text, provenance, err := ComposeWithProvenance(body, []Override{part}, provenanceMain)
			if err == nil || text != nil || provenance != nil {
				t.Fatalf("invalid input published partial output/origins: main=%t body=%q err=%v", mainBad, bad, err)
			}
		}
	}
	if text, provenance, err := ComposeWithProvenance([]byte("{}"), []Override{{Mode: "unknown", Body: "{}"}}, provenanceMain); err == nil || text != nil || provenance != nil {
		t.Fatal("unknown composition operation published output")
	}
}

func TestProvenanceMetadataDoesNotGateTheInput(t *testing.T) {
	body := []byte("# original\r\nproxies: [{name: retained, type: direct}]\n")
	for _, main := range []ConfigOrigin{{ID: "main", Revision: 0}, {Revision: 1}, {Name: "name without identity"}, {ID: "main", Revision: -1}} {
		text, provenance, err := ComposeWithProvenance(body, nil, main)
		if err != nil || !bytes.Equal(text, body) {
			t.Fatalf("source metadata changed runtime eligibility: %+v: %v", main, err)
		}
		contribution := provenance.Definition("proxies", "retained").Contributors[0]
		if contribution.ID != main.ID || contribution.Revision != main.Revision || contribution.Name != main.Name {
			t.Fatalf("source metadata was invented: %+v", contribution)
		}
	}
	valid := provenancePart("plugin", "prepend", "{}")
	for _, parts := range [][]Override{
		{valid, valid},
		{{ID: "", Revision: 1, Mode: "prepend", Body: "{}"}},
		{{ID: "p", Revision: 0, Mode: "prepend", Body: "{}"}},
	} {
		if _, _, err := ComposeWithProvenance(body, parts, provenanceMain); err != nil {
			t.Fatalf("diagnostic identity rejected composition: %+v: %v", parts, err)
		}
	}
}

func TestUnchangedInputDoesNotDependOnDiagnosticParsing(t *testing.T) {
	for _, input := range []string{"[]", "dns: [", "dns: *missing", "dns: &loop [*loop]", "proxies: null", "proxies: [null, {}, {name: 2}]", "rules: []\n---\nother: value"} {
		body := []byte(input)
		text, _, err := ComposeWithProvenance(body, nil, provenanceMain)
		if err != nil || !bytes.Equal(text, body) {
			t.Fatalf("unchanged core input was rejected or rewritten by diagnostics: %q: %v", text, err)
		}
	}
}
