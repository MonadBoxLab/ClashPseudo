package engine

import (
	"bytes"
	"encoding/json"
	"net/netip"
	"os"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	PP "github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/structure"
	"github.com/metacubex/mihomo/common/yaml"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/geodata/router"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/rules"
	RC "github.com/metacubex/mihomo/rules/common"
	RP "github.com/metacubex/mihomo/rules/provider"
	"google.golang.org/protobuf/proto"

	"clashpseudo/native/internal/configinput"
)

// DEFINITION_FORMS_GENERATED points to the successful Flutter widget/writer run.
// Exercise public constructors with uninitialized compatible providers and REJECT
// members; retain available Close calls.
func TestDefinitionFormsPublicParserContract(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	path := os.Getenv("DEFINITION_FORMS_GENERATED")
	if path == "" {
		t.Skip("run definition_forms_test.dart with DEFINITION_FORMS_OUTPUT, then set DEFINITION_FORMS_GENERATED")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var output map[string]struct {
		Definition map[string]any `json:"definition"`
		Name       string         `json:"name"`
		YAML       string         `json:"yaml"`
		Rule       string         `json:"rule"`
		Type       string         `json:"type"`
		Payload    string         `json:"payload"`
		Target     string         `json:"target"`
		Params     []string       `json:"params"`
	}
	if err := json.Unmarshal(data, &output); err != nil {
		t.Fatal(err)
	}
	if len(output) != 69 {
		t.Fatalf("incomplete actual GUI output: %d records, want 69", len(output))
	}
	oldHome := C.Path.HomeDir()
	home := t.TempDir()
	C.SetHomeDir(home)
	t.Cleanup(func() { C.SetHomeDir(oldHome) })
	// Resource-backed constructors receive valid local databases before parsing.
	// Empty download URLs also prevent an unexpected fallback from reaching a host.
	oldSiteURL, oldASNURL := geodata.GeoSiteUrl(), geodata.ASNUrl()
	geodata.SetGeoSiteUrl("")
	geodata.SetASNUrl("")
	geodata.ClearGeoSiteCache()
	t.Cleanup(func() {
		geodata.ClearGeoSiteCache()
		geodata.SetGeoSiteUrl(oldSiteURL)
		geodata.SetASNUrl(oldASNURL)
	})
	sites, err := proto.Marshal(&router.GeoSiteList{Entry: []*router.GeoSite{
		{CountryCode: "cn", Domain: []*router.Domain{{Value: "example.test"}}},
		{CountryCode: "fixture", Domain: []*router.Domain{{Value: "example.test"}}},
	}})
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{C.Path.GeoSite(): sites, C.Path.ASN(): minimalMMDB()}
	for path, data := range files {
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := geodata.Verify(C.GeositeName); err != nil {
		t.Fatal(err)
	}
	if !mmdb.Verify(C.Path.ASN()) {
		t.Fatal("local ASN database is invalid")
	}
	ids := make([]string, 0, len(output))
	for id := range output {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	seenTypes := map[string]bool{}
	parsedTypes := map[string]bool{}
	for _, id := range ids {
		for _, mode := range []string{"prepend", "replace"} {
			t.Run(id+"/"+mode, func(t *testing.T) {
				item := output[id]
				if item.YAML == "" {
					t.Fatal("actual GUI output has no saved YAML")
				}
				composed, err := configinput.Compose([]byte("{}\n"), []configinput.Override{
					{ID: "gui-definition", Revision: 1, Mode: mode, Body: item.YAML},
				})
				if err != nil {
					t.Fatal(err)
				}
				if strings.HasPrefix(id, "rule/") {
					var body map[string]any
					if err := yaml.Unmarshal(composed, &body); err != nil {
						t.Fatal(err)
					}
					sequence, ok := body["rules"].([]any)
					if !ok || len(sequence) != 2 || sequence[0] != item.Rule || sequence[1] != "MATCH,DIRECT" {
						t.Fatal("native YAML changed the rule or its prepend position")
					}
					tp, payload, target, params := RC.ParseRulePayload(item.Rule, true)
					if tp != item.Type || payload != item.Payload || target != item.Target || !reflect.DeepEqual(params, item.Params) {
						t.Fatalf("native delimiter round trip differs: type=%q payload=%q target=%q params=%v", tp, payload, target, params)
					}
					seenTypes[tp] = true
					rule, err := rules.ParseRule(tp, payload, target, params, map[string][]C.Rule{"child-set": {RC.NewMatch("REJECT")}})
					if err != nil {
						t.Fatal(err)
					}
					parsedTypes[tp] = true
					if rule.Adapter() != target {
						t.Fatal("native target namespace changed")
					}
					if tp == "RULE-SET" && !reflect.DeepEqual(rule.ProviderNames(), []string{payload}) {
						t.Fatal("RULE-SET lost provider name")
					}
					if id == "rule/flags" {
						resolves := 0
						metadata := &C.Metadata{SrcIP: netip.MustParseAddr("192.0.2.9"), DstIP: netip.MustParseAddr("198.51.100.7")}
						matched, actualTarget := rule.Match(metadata, C.RuleMatchHelper{ResolveIP: func() { resolves++ }})
						if !matched || actualTarget != target || resolves != 0 {
							t.Fatal("src/no-resolve did not affect the actual native matcher")
						}
					}
					return
				}
				// Decode actual writer output through the native YAML implementation and public
				// Option decoder.
				var body map[string]any
				if err := yaml.Unmarshal(composed, &body); err != nil {
					t.Fatal(err)
				}
				var definition map[string]any
				switch {
				case strings.HasPrefix(id, "group/"):
					definition = body["proxy-groups"].([]any)[0].(map[string]any)
				case strings.HasPrefix(id, "proxy-provider/"):
					definition = body["proxy-providers"].(map[string]any)[item.Name].(map[string]any)
				case strings.HasPrefix(id, "rule-provider/"):
					if _, exists := body["rules"]; exists {
						t.Fatal("provider form invented a RULE-SET")
					}
					definition = body["rule-providers"].(map[string]any)[item.Name].(map[string]any)
				default:
					t.Fatal("unexpected GUI output record")
				}
				actualJSON, err := json.Marshal(definition)
				if err != nil {
					t.Fatal(err)
				}
				guiJSON, err := json.Marshal(item.Definition)
				if err != nil {
					t.Fatal(err)
				}
				if !bytes.Equal(actualJSON, guiJSON) {
					t.Fatal("native YAML parsing changed the actual GUI definition")
				}
				switch {
				case strings.HasPrefix(id, "group/"):
					definitionFormGroupContract(t, definition)
				case strings.HasPrefix(id, "proxy-provider/"):
					provider, err := PP.ParseProxyProvider(item.Name, definition, nil)
					if err != nil {
						t.Fatal(err)
					}
					t.Cleanup(func() {
						if err := provider.(interface{ Close() error }).Close(); err != nil {
							t.Error(err)
						}
					})
					if provider.Name() != item.Name || provider.Count() != len(definition["payload"].([]any)) {
						t.Fatal("fallback/inline payload was not parsed")
					}
					proxy := provider.Proxies()[0]
					if proxy.Name() != "pre-base-post-expr" {
						t.Fatal("rename/prefix/suffix/native-expression order changed")
					}
					hc := reflect.ValueOf(provider).Elem().FieldByName("healthCheck").Elem()
					health := definition["health-check"].(map[string]any)
					if hc.FieldByName("timeout").Int() != int64(time.Duration(health["timeout"].(int))*time.Millisecond) ||
						hc.FieldByName("interval").Int() != 0 || hc.FieldByName("lazy").Bool() != health["lazy"].(bool) ||
						provider.HealthCheckURL() != health["url"] {
						t.Fatal("health-check units/false/default behavior changed")
					}
					if definition["type"] != "inline" {
						definitionFormVehicleContract(t, provider.(interface{ Vehicle() P.Vehicle }).Vehicle(), definition)
					}
				case strings.HasPrefix(id, "rule-provider/"):
					requestedBundle := ""
					provider, err := RP.ParseRuleProvider(item.Name, definition, rules.ParseRule, func(path string) resource.BundleFile {
						requestedBundle = path
						return nil // Construction only; no bundle or vehicle is read.
					})
					if err != nil {
						t.Fatal(err)
					}
					if closer, ok := provider.(interface{ Close() error }); ok {
						t.Cleanup(func() {
							if err := closer.Close(); err != nil {
								t.Error(err)
							}
						})
					}
					if strings.ToLower(provider.Behavior().String()) != definition["behavior"] || provider.Count() != len(definition["payload"].([]any)) {
						t.Fatal("native behavior or fallback/inline content differs")
					}
					if definition["type"] != "inline" {
						if requestedBundle != definition["path-in-bundle"] {
							t.Fatal("path-in-bundle was not consumed")
						}
						encoded, err := json.Marshal(provider)
						if err != nil {
							t.Fatal(err)
						}
						var status map[string]any
						if err := json.Unmarshal(encoded, &status); err != nil {
							t.Fatal(err)
						}
						format, err := P.ParseRuleFormat(definition["format"].(string))
						if err != nil {
							t.Fatal(err)
						}
						if status["format"] != format.String() {
							t.Fatal("native external provider format differs")
						}
					}
				}
			})
		}
	}
	if len(seenTypes) != 37 {
		t.Fatalf("actual GUI covered %d raw rule types, want 37", len(seenTypes))
	}
	if len(parsedTypes) != 37 {
		t.Fatalf("actual GUI reached %d native rule constructors, want 37", len(parsedTypes))
	}
	entries, err := os.ReadDir(home)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(files) {
		t.Fatal("constructor-only contract unexpectedly created runtime resources")
	}
	for path, expected := range files {
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, expected) {
			t.Fatalf("constructor changed the local database: %s: %v", path, err)
		}
	}
}

func definitionFormVehicleContract(t *testing.T, vehicle P.Vehicle, definition map[string]any) {
	t.Helper()
	if vehicle.Path() != C.Path.Resolve(definition["path"].(string)) {
		t.Fatal("explicit managed cache path was replaced")
	}
	if definition["type"] != "http" {
		return
	}
	if vehicle.Url() != definition["url"] || vehicle.Proxy() != definition["proxy"] {
		t.Fatal("download URL/proxy were not retained")
	}
	value := reflect.ValueOf(vehicle).Elem()
	if value.FieldByName("sizeLimit").Int() != int64(definition["size-limit"].(int)) {
		t.Fatal("size-limit byte count changed")
	}
	header := value.FieldByName("header")
	wanted := definition["header"].(map[string]any)
	if header.Len() != len(wanted) {
		t.Fatal("header mapping differs")
	}
	for key, raw := range wanted {
		values := header.MapIndex(reflect.ValueOf(key))
		list := raw.([]any)
		if !values.IsValid() || values.Len() != len(list) {
			t.Fatal("header lost its string-list shape")
		}
		for index, item := range list {
			if values.Index(index).String() != item {
				t.Fatal("header values/order differ")
			}
		}
	}
}

func definitionFormGroupContract(t *testing.T, definition map[string]any) {
	t.Helper()
	decoder := structure.NewDecoder(structure.Option{TagName: "group", WeaklyTypedInput: true})
	var common outboundgroup.GroupCommonOption
	if err := decoder.Decode(definition, &common); err != nil {
		t.Fatal(err)
	}
	tags := map[string]bool{}
	types := []reflect.Type{reflect.TypeFor[outboundgroup.GroupCommonOption]()}
	switch common.Type {
	case "select":
		types = append(types, reflect.TypeFor[outboundgroup.SelectorOption]())
	case "url-test":
		types = append(types, reflect.TypeFor[outboundgroup.URLTestOption]())
	case "fallback":
		types = append(types, reflect.TypeFor[outboundgroup.FallbackOption]())
	case "load-balance":
		types = append(types, reflect.TypeFor[outboundgroup.LoadBalanceOption]())
	default:
		t.Fatal("unknown GUI group type")
	}
	for _, typ := range types {
		for i := 0; i < typ.NumField(); i++ {
			tag := typ.Field(i).Tag.Get("group")
			if tag == "" {
				t.Fatalf("public group Option field %s has no fixed tag", typ.Field(i).Name)
			}
			tags[strings.Split(tag, ",")[0]] = true
		}
	}
	if len(tags) != len(definition) {
		t.Fatal("GUI fixture does not cover the complete public group Option fields")
	}
	for key := range definition {
		if !tags[key] {
			t.Fatalf("GUI key %q is not a fixed public group Option", key)
		}
	}
	reject := adapter.NewProxy(outbound.NewReject())
	pd, err := PP.ParseProxyProvider("fixture-provider", map[string]any{
		"type": "inline", "payload": []map[string]any{{"type": "reject", "name": "fixture-member"}},
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	providers := map[string]P.ProxyProvider{"fixture-provider": pd}
	t.Cleanup(func() {
		for _, provider := range providers {
			if err := provider.(interface{ Close() error }).Close(); err != nil {
				t.Error(err)
			}
		}
	})
	group, err := outboundgroup.ParseProxyGroup(definition, map[string]C.Proxy{"REJECT": reject}, providers, []string{"REJECT"}, []string{"fixture-provider"})
	if err != nil {
		t.Fatal(err)
	}
	if group.Name() != common.Name || group.Hidden() != common.Hidden || group.Icon() != common.Icon {
		t.Fatal("group metadata differs")
	}
	value := reflect.ValueOf(group).Elem()
	if value.FieldByName("testTimeout").Int() != int64(common.TestTimeout) ||
		value.FieldByName("maxFailedTimes").Int() != int64(common.MaxFailedTimes) {
		t.Fatal("group timeout/failure count consumer differs")
	}
	switch common.Type {
	case "select":
		if value.FieldByName("selected").String() != definition["default-selected"] {
			t.Fatal("default-selected was not consumed")
		}
	case "url-test":
		if value.FieldByName("tolerance").Uint() != uint64(definition["tolerance"].(int)) {
			t.Fatal("tolerance was not consumed")
		}
	}
	virtual := providers[common.Name]
	health := reflect.ValueOf(virtual).Elem().FieldByName("healthCheck").Elem()
	interval := common.Interval
	if interval == 0 && common.Type != "select" {
		interval = 300
	}
	if health.FieldByName("interval").Int() != int64(time.Duration(interval)*time.Second) ||
		health.FieldByName("timeout").Int() != int64(time.Duration(common.TestTimeout)*time.Millisecond) {
		t.Fatal("group health-check units/default changed")
	}
	// Negative controls use constraints the fixed parser actually enforces.
	// Unknown keys are intentionally accepted by its weakly typed decoder and
	// are therefore covered by the exact Option-field inventory above instead.
	missing := make(map[string]any, len(definition))
	for key, item := range definition {
		missing[key] = item
	}
	missing["use"] = []any{"missing-provider"}
	if _, err := outboundgroup.ParseProxyGroup(missing, map[string]C.Proxy{"REJECT": reject}, providers, []string{"REJECT"}, []string{"fixture-provider"}); err == nil {
		t.Fatal("the fixed parser accepted an unresolved provider reference")
	}
	typo := make(map[string]any, len(definition))
	for key, item := range definition {
		typo[key] = item
	}
	typo["expected-status"] = "not-a-range"
	if _, err := outboundgroup.ParseProxyGroup(typo, map[string]C.Proxy{"REJECT": reject}, providers, []string{"REJECT"}, []string{"fixture-provider"}); err == nil {
		t.Fatal("the fixed parser accepted an invalid expected-status range")
	}
}
