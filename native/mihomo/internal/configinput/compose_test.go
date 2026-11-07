package configinput

import (
	"bytes"
	"fmt"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

func composeFixture(t *testing.T, body string, parts ...Override) map[string]any {
	t.Helper()
	text, err := Compose([]byte(body), parts)
	if err != nil {
		t.Fatal(err)
	}
	var result map[string]any
	if err := yaml.Unmarshal(text, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func overrideFixture(mode, body string) Override {
	return Override{ID: "fragment", Revision: 1, Mode: mode, Body: body}
}

func TestComposeRecursiveMappingsAndListModes(t *testing.T) {
	const base = "dns:\n  enable: true\n  nameserver: [old]\n  fallback: [retained]\n  nested: {a: 1, b: 2}\nrules: [old-rule]\n"
	const fragment = "dns:\n  nameserver: [new]\n  nested: {a: 0, c: false}\nrules: [new-rule]\n"
	for _, mode := range []string{"prepend", "replace"} {
		t.Run(mode, func(t *testing.T) {
			result := composeFixture(t, base, overrideFixture(mode, fragment))
			dns := result["dns"].(map[string]any)
			if dns["enable"] != true || dns["fallback"].([]any)[0] != "retained" {
				t.Fatal("omitted DNS fields were not inherited", dns)
			}
			nested := dns["nested"].(map[string]any)
			if nested["a"] != 0 || nested["b"] != 2 || nested["c"] != false {
				t.Fatal("recursive scalar override failed", nested)
			}
			want := 1
			if mode == "prepend" {
				want = 2
			}
			if got := dns["nameserver"].([]any); len(got) != want || got[0] != "new" {
				t.Fatal("incorrect nameserver list", got)
			}
			if got := result["rules"].([]any); len(got) != want || got[0] != "new-rule" {
				t.Fatal("incorrect rule ordering", got)
			}
		})
	}
}

func TestComposeNamedObjectsAndNestedMemberLists(t *testing.T) {
	const base = "proxies:\n - {name: retained, type: direct}\n - {name: changed, type: ss, server: old, port: 80}\nproxy-groups:\n - {name: group, type: select, proxies: [retained]}\n"
	const part = "proxies:\n - {name: added, type: direct}\n - {name: changed, server: new}\nproxy-groups:\n - {name: group, proxies: [added]}\n"
	for _, mode := range []string{"prepend", "replace"} {
		result := composeFixture(t, base, overrideFixture(mode, part))
		nodes := result["proxies"].([]any)
		if len(nodes) != 3 {
			t.Fatal("objects were removed or duplicated", nodes)
		}
		for i, name := range []string{"added", "retained", "changed"} {
			if nodes[i].(map[string]any)["name"] != name {
				t.Fatal("object ordering", nodes)
			}
		}
		changed := nodes[2].(map[string]any)
		if changed["server"] != "new" || changed["port"] != 80 || changed["type"] != "ss" {
			t.Fatal("same-name object inheritance", changed)
		}
		members := result["proxy-groups"].([]any)[0].(map[string]any)["proxies"].([]any)
		want := 1
		if mode == "prepend" {
			want = 2
		}
		if len(members) != want || members[0] != "added" {
			t.Fatal("member list treated as object list", members)
		}
	}
}

func TestComposePriorityAliasesAndEmptyValues(t *testing.T) {
	result := composeFixture(t, "dns: {enable: true, nameserver: [base]}\nrules: [base]\nproxies: [{name: keep, type: direct}]\n",
		Override{ID: "first", Revision: 1, Mode: "replace", Body: "dns: {enable: false, nameserver: []}\nrules: []\nproxies: []\n"},
		Override{ID: "second", Revision: 1, Mode: "prepend", Body: "dns: &dns {nameserver: [second]}\ncopy: *dns\n"},
	)
	dns := result["dns"].(map[string]any)
	if dns["enable"] != false || len(dns["nameserver"].([]any)) != 0 || len(result["rules"].([]any)) != 0 {
		t.Fatal("empty values or priority lost", result)
	}
	if len(result["proxies"].([]any)) != 1 {
		t.Fatal("empty named list removed existing object")
	}
	result = composeFixture(t, "dns: {fallback: [kept]}\n", overrideFixture("replace", "base: &base {enable: true, nameserver: [base]}\ndns: {<<: *base, nameserver: [new]}\n"))
	dns = result["dns"].(map[string]any)
	if dns["enable"] != true || dns["nameserver"].([]any)[0] != "new" || dns["fallback"].([]any)[0] != "kept" {
		t.Fatal("document-local YAML merge failed", result)
	}
}

func TestComposeReportsActualSyntaxAndReferenceErrors(t *testing.T) {
	for _, body := range []string{
		"", "[]", "dns: {}\n---\ndns: {}", "dns: [",
		"dns: *missing",
	} {
		if _, err := Compose([]byte("{}"), []Override{overrideFixture("replace", body)}); err == nil {
			t.Errorf("invalid composition accepted: %q", body)
		}
	}
	if _, err := Compose([]byte("base: &base {}"), []Override{overrideFixture("replace", "dns: *base")}); err == nil {
		t.Fatal("cross-document alias accepted")
	}
}

func TestComposeLeavesNamesValueTypesAndDepthToTheCore(t *testing.T) {
	for _, body := range []string{
		"dns: {a: 1, a: 2}", "dns: {1: value}",
		"proxies: [{name: same}, {name: same}]", "proxies: [{}]", "proxies: [{name: 2}]",
		"proxies: null", "dns: " + strings.Repeat("[", 130) + "0" + strings.Repeat("]", 130),
	} {
		for _, mode := range []string{"prepend", "replace"} {
			output, err := Compose([]byte("{}"), []Override{overrideFixture(mode, body)})
			if err != nil {
				t.Fatalf("composition prevalidated core fields: %q: %v", body, err)
			}
			var original, actual yaml.Node
			if err := yaml.Unmarshal([]byte(body), &original); err != nil {
				t.Fatal(err)
			}
			if err := yaml.Unmarshal(output, &actual); err != nil {
				t.Fatal(err)
			}
			if yamlShape(original.Content[0]) != yamlShape(actual.Content[0]) {
				t.Fatalf("core input was normalized: %q -> %q", body, output)
			}
		}
	}
}

func yamlShape(node *yaml.Node) string {
	var result strings.Builder
	value := node.Value
	if node.Kind == yaml.AliasNode {
		value = "" // Anchor spelling is encoding, not a field value.
	}
	fmt.Fprintf(&result, "(%d,%q,%q", node.Kind, node.Tag, value)
	if node.Kind == yaml.ScalarNode {
		fmt.Fprintf(&result, ",%d", node.Style&^yaml.TaggedStyle)
	}
	for _, child := range node.Content {
		result.WriteString(yamlShape(child))
	}
	result.WriteByte(')')
	return result.String()
}

func TestComposeMergesNumericMappingKeysWithoutChangingTheirType(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		output, err := Compose([]byte("unknown: {1: {changed: old, retained: value}, '1': separate}\n"), []Override{overrideFixture(mode, "unknown: {1: {changed: new}}\n")})
		if err != nil {
			t.Fatal(err)
		}
		var actual, expected yaml.Node
		if err := yaml.Unmarshal(output, &actual); err != nil {
			t.Fatal(err)
		}
		if err := yaml.Unmarshal([]byte("unknown: {1: {changed: new, retained: value}, '1': separate}\n"), &expected); err != nil {
			t.Fatal(err)
		}
		if yamlShape(&actual) != yamlShape(&expected) {
			t.Fatalf("numeric or string mapping keys, values or order changed: %q", output)
		}
	}
}

func TestComposeDoesNotCollapseAmbiguousNamedRows(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		value := composeFixture(t, "proxies: [{name: same, type: direct}, {name: same, type: reject}]\n", overrideFixture(mode, "proxies: [{name: same, icon: original}]\n"))
		rows := value["proxies"].([]any)
		if len(rows) != 3 || rows[0].(map[string]any)["icon"] != "original" || rows[1].(map[string]any)["type"] != "direct" || rows[2].(map[string]any)["type"] != "reject" {
			t.Fatal("composition removed ambiguous rows instead of leaving them for the core", rows)
		}
	}
}

func TestComposePreservesUntouchedScalarsAndIndependentAnchorScopes(t *testing.T) {
	const body = `unknown: &same
  quoted: "001"
  integer: 0x0f
  float: 1.2300
  timestamp: 2001-12-15T02:59:43.123456789Z
  binary: !!binary SGVsbG8=
  tagged: !application-value original
  empty: ~
  3: numeric key
unknown-copy: *same
rules: [old]
`
	const fragment = `fragment: &same {quoted: "002", tagged: !application-value other}
fragment-copy: *same
rules: [new]
`
	for _, mode := range []string{"prepend", "replace"} {
		output, err := Compose([]byte(body), []Override{overrideFixture(mode, fragment)})
		if err != nil {
			t.Fatal(err)
		}
		var before, after, part map[string]yaml.Node
		for input, target := range map[string]*map[string]yaml.Node{body: &before, string(output): &after, fragment: &part} {
			if err := yaml.Unmarshal([]byte(input), target); err != nil {
				t.Fatal(err)
			}
		}
		original, changed := before["unknown"], after["unknown"]
		copy := after["unknown-copy"]
		if yamlShape(&original) != yamlShape(&changed) || yamlShape(&original) != yamlShape(configValue(&copy)) {
			t.Fatalf("unrelated field types, values or order changed: %q", output)
		}
		original, changed = part["fragment"], after["fragment-copy"]
		if yamlShape(&original) != yamlShape(configValue(&changed)) {
			t.Fatalf("fragment alias borrowed the main document's anchor: %q", output)
		}
	}
}

func TestComposeLeavesInvalidValuesToThePublicParser(t *testing.T) {
	for _, body := range []string{"dns: &loop [*loop]", "dns: {<<: 3}"} {
		output, err := Compose([]byte("{}"), []Override{overrideFixture("replace", body)})
		if err != nil {
			t.Fatalf("composition prevalidated a core field: %v", err)
		}
		if _, err := config.UnmarshalRawConfig(output); err == nil {
			t.Fatalf("invalid field no longer reaches the public parser: %q", output)
		}
	}
}

func TestComposeDoesNotInspectUntouchedUnknownValues(t *testing.T) {
	for _, field := range []string{
		"unknown: &loop [*loop]\n",
		"unknown: &same {duplicate: one, duplicate: two}\nunknown-copy: *same\n",
		"unknown: {<<: 3}\n",
		"unknown: {? [one, two]: value}\n",
	} {
		body := field + "rules: ['MATCH,DIRECT']\n"
		if _, err := config.UnmarshalRawConfig([]byte(body)); err != nil {
			t.Fatalf("fixture is not accepted by the public parser: %v", err)
		}
		for _, mode := range []string{"prepend", "replace"} {
			output, err := Compose([]byte(body), []Override{overrideFixture(mode, "rules: ['DOMAIN,fixture.test,DIRECT']\n")})
			if err != nil {
				t.Fatalf("unrelated unknown value blocked composition: %q: %v", field, err)
			}
			if _, err := config.UnmarshalRawConfig(output); err != nil {
				t.Fatalf("composition broke a core-accepted unknown value: %v", err)
			}
			var before, after map[string]yaml.Node
			if err := yaml.Unmarshal([]byte(body), &before); err != nil {
				t.Fatal(err)
			}
			if err := yaml.Unmarshal(output, &after); err != nil {
				t.Fatal(err)
			}
			original, actual := before["unknown"], after["unknown"]
			if yamlShape(&original) != yamlShape(&actual) {
				t.Fatalf("unrelated unknown value changed: %q", output)
			}
			if actual.Kind == yaml.SequenceNode {
				target := actual.Content[0].Alias
				if target == nil || len(target.Content) != 1 || target.Content[0].Alias != target {
					t.Fatal("cyclic alias changed its target")
				}
			}
		}
	}
}

func TestComposeKeepsAliasTargetsWhenTheirAnchorIsEditedOrRemoved(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		value := composeFixture(t,
			"dns: &dns {enable: true, nameserver: [original]}\ncopy: *dns\nmode: &mode rule\nmode-copy: *mode\n",
			overrideFixture(mode, "dns: {nameserver: [changed]}\nmode: global\n"))
		if value["mode"] != "global" || value["mode-copy"] != "rule" {
			t.Fatal("changing a field also changed an unrelated alias", value)
		}
		copy := value["copy"].(map[string]any)
		if copy["enable"] != true || len(copy["nameserver"].([]any)) != 1 || copy["nameserver"].([]any)[0] != "original" {
			t.Fatal("replaced anchor lost its original alias target", copy)
		}
		dns := value["dns"].(map[string]any)
		if dns["enable"] != true || dns["nameserver"].([]any)[0] != "changed" {
			t.Fatal("requested mapping change was not applied", dns)
		}
	}
}

func TestComposePreservesSourceAndProviderOrder(t *testing.T) {
	body := []byte("\xef\xbb\xbfrules:\r\n - MATCH,DIRECT\r\n")
	original := bytes.Clone(body)
	unchanged, err := Compose(body, nil)
	if err != nil || !bytes.Equal(unchanged, original) {
		t.Fatal("no-override path changed source", err)
	}
	if _, err = Compose(body, []Override{overrideFixture("replace", "dns: {enable: true}")}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(body, original) {
		t.Fatal("composition mutated input")
	}
	output, err := Compose([]byte("proxy-providers:\n  z: {type: file}\n  a: {type: file}\n"), []Override{overrideFixture("replace", "dns: {}")})
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Index(output, []byte("z:")) > bytes.Index(output, []byte("a:")) {
		t.Fatal("provider declaration order was lost")
	}
}

func TestComposeRejectsActiveMappingPairs(t *testing.T) {
	for _, fixture := range []struct{ name, body string }{
		{"direct", "unknown: &loop {next: *loop}\n"},
		{"expanded", "defaults: &defaults {kept: true}\nunknown: &loop {<<: *defaults, next: *loop}\n"},
		{"mutual", "unknown: &outer {next: &inner {next: *outer}}\n"},
		{"named", "proxies: [&loop {name: shared, next: *loop}]\n"},
	} {
		for _, mode := range []string{"prepend", "replace"} {
			t.Run(fixture.name+"/"+mode, func(t *testing.T) {
				output, provenance, err := ComposeWithProvenance([]byte(fixture.body),
					[]Override{overrideFixture(mode, fixture.body)}, ConfigOrigin{})
				if err == nil || !strings.Contains(err.Error(), "cyclic mapping merge") {
					t.Fatalf("expected cyclic mapping merge error, got %v", err)
				}
				if output != nil || provenance != nil {
					t.Fatal("failed composition published partial output or provenance")
				}
			})
		}
	}
}

func TestComposeAllowsSharedMappingPairs(t *testing.T) {
	for _, mode := range []string{"prepend", "replace"} {
		result := composeFixture(t,
			"first: &shared {retained: true, changed: old}\nsecond: *shared\n",
			overrideFixture(mode, "first: &shared {changed: new}\nsecond: *shared\n"))
		for _, key := range []string{"first", "second"} {
			value := result[key].(map[string]any)
			if value["retained"] != true || value["changed"] != "new" {
				t.Fatalf("shared mapping was not merged independently: %v", result)
			}
		}
	}
}

func TestComposeAllowsFiniteMergeWithOneCyclicSide(t *testing.T) {
	const cycle = "unknown: &loop {next: *loop}\n"
	const finite = "unknown: {next: {added: true}}\n"
	for _, fixture := range []struct{ base, part string }{{cycle, finite}, {finite, cycle}} {
		for _, mode := range []string{"prepend", "replace"} {
			output, err := Compose([]byte(fixture.base), []Override{overrideFixture(mode, fixture.part)})
			if err != nil {
				t.Fatal(err)
			}
			root, err := configurationMapping(output)
			if err != nil {
				t.Fatal(err)
			}
			value := root.Content[mappingIndex(root)["unknown"]+1]
			nested := value.Content[mappingIndex(value)["next"]+1]
			position, exists := mappingIndex(nested)["added"]
			if !exists || nested.Content[position+1].Value != "true" {
				t.Fatalf("finite merge lost the nested field: %q", output)
			}
		}
	}
}

func TestComposePreservesUnmergedMappingCycles(t *testing.T) {
	const cycle = "unknown: &loop {next: *loop}\n"
	for _, fixture := range []struct{ name, base, part string }{
		{"untouched", cycle, "other: true\n"},
		{"added", "other: true\n", cycle},
		{"replaced", "unknown: old\n", cycle},
		{"finite-merge", cycle, "unknown: {added: true}\n"},
	} {
		for _, mode := range []string{"prepend", "replace"} {
			t.Run(fixture.name+"/"+mode, func(t *testing.T) {
				output, err := Compose([]byte(fixture.base), []Override{overrideFixture(mode, fixture.part)})
				if err != nil {
					t.Fatal(err)
				}
				root, err := configurationMapping(output)
				if err != nil {
					t.Fatal(err)
				}
				value := root.Content[mappingIndex(root)["unknown"]+1]
				target := configValue(value.Content[mappingIndex(value)["next"]+1])
				if configValue(target.Content[mappingIndex(target)["next"]+1]) != target {
					t.Fatal("unmerged cycle lost its alias target")
				}
			})
		}
	}
	output, err := Compose([]byte(cycle), nil)
	if err != nil || string(output) != cycle {
		t.Fatalf("unchanged cyclic input was not preserved: %q, %v", output, err)
	}
}

func TestComposeLimits(t *testing.T) {
	body := []byte("#" + strings.Repeat("x", MaxConfigText-1))
	if _, err := Compose(body, nil); err != nil {
		t.Fatal("exact limit rejected")
	}
	if _, err := Compose(append(body, 'x'), nil); err == nil {
		t.Fatal("oversize main accepted")
	}
	if _, err := Compose([]byte("{}"), []Override{overrideFixture("replace", string(body)+"x")}); err == nil {
		t.Fatal("oversize fragment accepted")
	}
	large := strings.Repeat("x", MaxConfigText/2)
	if _, err := Compose([]byte("first: "+large), []Override{overrideFixture("replace", "second: "+large)}); err == nil {
		t.Fatal("oversize composed text accepted")
	}
}
