package coreview

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"

	"clashpseudo/native/internal/configinput"
	"go.yaml.in/yaml/v3"
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
