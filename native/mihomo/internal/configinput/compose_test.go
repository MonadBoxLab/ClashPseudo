package configinput

import (
	"bytes"
	"go.yaml.in/yaml/v3"
	"strings"
	"testing"
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

func TestComposeRejectsInvalidInput(t *testing.T) {
	for _, body := range []string{
		"", "[]", "dns: {}\n---\ndns: {}", "dns: {a: 1, a: 2}",
		"dns: *missing", "dns: &loop [*loop]", "dns: {1: value}",
		"proxies: [{name: same}, {name: same}]", "proxies: [{}]", "proxies: [{name: 2}]",
		"proxies: null", "dns: " + strings.Repeat("[", 130) + "0" + strings.Repeat("]", 130),
	} {
		if _, err := Compose([]byte("{}"), []Override{overrideFixture("replace", body)}); err == nil {
			t.Errorf("invalid fragment accepted: %q", body)
		}
	}
	if _, err := Compose([]byte("base: &base {}"), []Override{overrideFixture("replace", "dns: *base")}); err == nil {
		t.Fatal("cross-document alias accepted")
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
