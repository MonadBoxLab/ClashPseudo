package coreview

import (
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"go.yaml.in/yaml/v3"
)

func TestSourceOrderVisitsDeepAliasesAndCyclicMergesOnce(t *testing.T) {
	key := func(value string) *yaml.Node {
		return &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value}
	}
	root := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
	inherited := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: []*yaml.Node{
		key("first"), {}, key("second"), {},
		{Kind: yaml.ScalarNode, Tag: "!!merge", Value: "<<"}, {Kind: yaml.AliasNode, Alias: root},
	}}
	chain := inherited
	for range 512 {
		chain = &yaml.Node{Kind: yaml.AliasNode, Alias: chain}
	}
	root.Content = []*yaml.Node{
		key("first"), {},
		{Kind: yaml.ScalarNode, Tag: "!!merge", Value: "<<"},
		{Kind: yaml.SequenceNode, Content: []*yaml.Node{chain, chain}},
	}
	names, err := sourceMappingNames(root)
	if err != nil || !reflect.DeepEqual(names, []string{"first", "second"}) {
		t.Fatal("diagnostic ordering imposed a nesting limit or repeated the graph", names, err)
	}
}

type classicalFixture struct {
	P.RuleProvider
	vehicle  P.VehicleType
	strategy any
}

func (p classicalFixture) VehicleType() P.VehicleType { return p.vehicle }
func (p classicalFixture) Vehicle() P.Vehicle         { panic("classical stream must not read Vehicle.Path") }
func (p classicalFixture) Strategy() any              { return p.strategy }
func (p classicalFixture) Behavior() P.RuleBehavior   { return P.Classical }
func (p classicalFixture) Count() int                 { return 1 }
func TestClassicalStreamNeverReadsCacheOrConfigurationFallback(t *testing.T) {
	for _, state := range []string{"missing", "parent-is-file", "invalid-yaml", "empty-file", "second-unconsumed-document", "missing-payload", "unsupported-format", "disappeared", "cache-arrival", "cache-change", "configuration-fallback"} {
		t.Run(state, func(t *testing.T) {
			for _, vehicle := range []P.VehicleType{P.File, P.HTTP} {
				provider := classicalFixture{vehicle: vehicle, strategy: &struct{}{}}
				cfg := &config.Config{RuleProviders: map[string]P.RuleProvider{"classical": provider}}
				_, err := StreamRules(cfg, nil, RuleQuery{Kind: "provider", Name: "classical"}, func(any) error { t.Fatal("non-enumerable classical source produced substitute rules"); return nil })
				var actual RuleReadError
				if !errors.As(err, &actual) || !strings.HasPrefix(actual.Error(), "sourceUnavailable:") {
					t.Fatal("actual non-enumerable state of the public API was not preserved", err)
				}
			}
		})
	}
}
func TestRuleStreamKeepsActualConsumerErrors(t *testing.T) {
	cfg := &config.Config{Rules: []C.Rule{ruleProjectionFixture{kind: C.Domain, payload: "original.test"}}}
	original := errors.New("consumer original cause")
	_, err := StreamRules(cfg, nil, RuleQuery{Kind: "main"}, func(any) error { return original })
	if !errors.Is(err, original) {
		t.Fatal("consumer's original cause was replaced", err)
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
	metadata, err := ReadDiagnosticSources(body, raw)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(metadata.proxyProviders, ",") != "m-provider,z-provider,a-provider" || strings.Join(metadata.ruleProviders, ",") != "z-rules,a-rules" || strings.Join(metadata.proxies, ",") != "z-top,a-top" || metadata.proxyIntervals["z-provider"] != 3600 {
		t.Fatalf("declaration/interval metadata = %+v", metadata)
	}
}

func TestSourceDiagnosticsKeepOtherEntriesAndActualDecoderErrors(t *testing.T) {
	decoder := structure.NewDecoder(structure.Option{TagName: "provider", WeaklyTypedInput: true})
	raw := &config.RawConfig{
		RuleProvider: map[string]map[string]any{
			"retained": {"format": "yaml", "payload": []any{"DOMAIN,retained.test"}},
			"invalid":  {"format": map[string]any{"original": "https://user:pass@fixture.test/?token=原文🙂"}},
		},
		ProxyProvider: map[string]map[string]any{
			"retained": {"interval": 17},
			"invalid":  {"interval": map[string]any{"original": false}},
		},
		Proxy: []map[string]any{
			{"name": "retained"},
			{"name": map[string]any{"original": false}},
		},
	}
	var interval struct {
		Interval int `provider:"interval,omitempty"`
	}
	original := decoder.Decode(raw.ProxyProvider["invalid"], &interval)
	if original == nil {
		t.Fatal("fixture did not fail SDK interval decoding")
	}
	metadata, err := ReadDiagnosticSources([]byte("proxy-providers: {retained: {}, invalid: {}}\nrule-providers: {retained: {}, invalid: {}}\n"), raw)
	if err == nil || !strings.Contains(err.Error(), original.Error()) {
		t.Fatalf("provider interval lost the actual SDK error: %v", err)
	}
	if metadata.proxyIntervals["retained"] != 17 || len(metadata.proxies) != 1 || metadata.proxies[0] != "retained" || len(metadata.proxyProviders) != 2 || metadata.proxyProviders[0] != "retained" || metadata.proxyProviders[1] != "invalid" {
		t.Fatalf("partial diagnostics were discarded: %+v", metadata)
	}
}
