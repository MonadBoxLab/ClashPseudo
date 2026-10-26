package engine

import (
	"net/netip"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"

	"clashpseudo/native/internal/configinput"
)

// Self-authored examples of the public Dart converter's output, consumed by actual
// Compose.
func TestLoonConvertedFragmentsComposeInBothModes(t *testing.T) {
	const main = "rules:\n  - DOMAIN,keep.test,DIRECT\n  - MATCH,DIRECT\ndns:\n  enable: false\n"
	const zero = "# Loon: compatible [Rule] entries only; other content is inert.\n# [Rule]\n# FINAL,DIRECT\n{}\n"
	const active = "# Loon: compatible [Rule] entries only; other content is inert.\n# [Rule]\nrules:\n  - \"DOMAIN,example.test,DIRECT\"\n  - \"NOT,((IP-CIDR,192.0.2.0/24,no-resolve)),DIRECT\"\n# [Script]\n# script = never-executed\\u0000\n"
	baseRules := []string{"DOMAIN,keep.test,DIRECT", "MATCH,DIRECT"}
	convertedRules := []string{"DOMAIN,example.test,DIRECT", "NOT,((IP-CIDR,192.0.2.0/24,no-resolve)),DIRECT"}
	for _, mode := range []string{"prepend", "replace"} {
		for _, fixture := range []struct {
			name string
			body string
			want []string
		}{
			{"zero", zero, baseRules},
			{"active", active, convertedRules},
		} {
			t.Run(mode+"/"+fixture.name, func(t *testing.T) {
				body, err := configinput.Compose([]byte(main), []configinput.Override{{ID: "loon", Revision: 1, Mode: mode, Body: fixture.body}})
				if err != nil {
					t.Fatal(err)
				}
				raw, err := config.UnmarshalRawConfig(body)
				if err != nil {
					t.Fatal(err)
				}
				want := append([]string(nil), fixture.want...)
				if fixture.name == "active" && mode == "prepend" {
					want = append(want, baseRules...)
				}
				if !reflect.DeepEqual(raw.Rule, want) {
					t.Fatalf("effective rule sequence = %#v, want %#v", raw.Rule, want)
				}
				if raw.DNS.Enable {
					t.Fatal("an inert/Rule-only plugin changed unrelated DNS settings")
				}
			})
		}
	}
}

func TestLoonConvertedNOTUsesOneRealConditionAndNoResolveLeaf(t *testing.T) {
	const converted = "NOT,((IP-CIDR,192.0.2.0/24,no-resolve)),DIRECT"
	tp, payload, target, params := RC.ParseRulePayload(converted, true)
	rule, err := rules.ParseRule(tp, payload, target, params, nil)
	if err != nil {
		t.Fatal(err)
	}
	if rule.RuleType() != C.NOT || rule.Adapter() != "DIRECT" {
		t.Fatal("converted NOT did not retain its rule type and target")
	}
	for _, fixture := range []struct {
		name string
		ip   netip.Addr
		want bool
	}{
		{"matching IP negated", netip.MustParseAddr("192.0.2.7"), false},
		{"other IP", netip.MustParseAddr("198.51.100.7"), true},
		{"missing IP is a nonmatching leaf, not a false NOT", netip.Addr{}, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			metadata := &C.Metadata{Host: "example.test", DstIP: fixture.ip}
			resolves := 0
			matched, adapter := rule.Match(metadata, C.RuleMatchHelper{ResolveIP: func() {
				resolves++
				metadata.DstIP = netip.MustParseAddr("192.0.2.7")
			}})
			if matched != fixture.want || (matched && adapter != "DIRECT") {
				t.Fatalf("match = %v/%q, want %v", matched, adapter, fixture.want)
			}
			if resolves != 0 {
				t.Fatal("no-resolve was not retained on the IP condition")
			}
		})
	}
	// Require a parsed NOT child to distinguish the valid nested form from an accepted
	// empty expression.
	if _, err := rules.ParseRule("NOT", "(IP-CIDR,192.0.2.0/24,no-resolve)", "DIRECT", nil, nil); err == nil {
		t.Fatal("negative-control NOT with no actual child was accepted")
	}
}

func TestLoonConvertedNestedNOTPreservesANDAndPortSemantics(t *testing.T) {
	const converted = "NOT,((AND,((DOMAIN-SUFFIX,example.test),(DST-PORT,443),(IP-CIDR6,2001:db8::/32,no-resolve)))),DIRECT"
	tp, payload, target, params := RC.ParseRulePayload(converted, true)
	rule, err := rules.ParseRule(tp, payload, target, params, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []struct {
		name string
		host string
		port uint16
		ip   netip.Addr
		want bool
	}{
		{"all children match", "api.example.test", 443, netip.MustParseAddr("2001:db8::7"), false},
		{"different port", "api.example.test", 80, netip.MustParseAddr("2001:db8::7"), true},
		{"different domain", "other.test", 443, netip.MustParseAddr("2001:db8::7"), true},
		{"different address family", "api.example.test", 443, netip.MustParseAddr("192.0.2.7"), true},
		{"no destination IP", "api.example.test", 443, netip.Addr{}, true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			metadata := &C.Metadata{Host: fixture.host, DstPort: fixture.port, DstIP: fixture.ip}
			resolves := 0
			matched, _ := rule.Match(metadata, C.RuleMatchHelper{ResolveIP: func() { resolves++ }})
			if matched != fixture.want || resolves != 0 {
				t.Fatalf("match = %v, resolves = %d; want %v and no resolution", matched, resolves, fixture.want)
			}
		})
	}
}
