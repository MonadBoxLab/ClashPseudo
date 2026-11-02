package coreview

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type RuleReadError string

func (e RuleReadError) Error() string { return string(e) }

type RuleQuery struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

func (q RuleQuery) Validate() error {
	if len(q.Name) > 4096 {
		return errors.New("rule scope name exceeds limit")
	}
	switch q.Kind {
	case "main":
		if q.Name != "" {
			return errors.New("main rule scope has a name")
		}
	case "sub", "provider":
	default:
		return errors.New("invalid rule scope")
	}
	return nil
}

type RuleScope struct {
	Kind       string                            `json:"kind"`
	Name       string                            `json:"name"`
	Count      int                               `json:"count"`
	Behavior   string                            `json:"behavior,omitempty"`
	Provenance *configinput.DefinitionProvenance `json:"provenance,omitempty"`
}
type RuleRow struct {
	Index      int                               `json:"index"`
	Type       string                            `json:"type"`
	Payload    string                            `json:"payload"`
	Target     string                            `json:"target"`
	Providers  []string                          `json:"providers"`
	Resources  []string                          `json:"resources,omitempty"`
	Provenance *configinput.DefinitionProvenance `json:"provenance,omitempty"`
}

func directRuleResources(rule C.Rule) []string {
	switch rule.RuleType() {
	case C.GEOIP, C.SrcGEOIP:
		if strings.EqualFold(rule.Payload(), "lan") {
			return nil
		}
		if geodata.GeodataMode() {
			return []string{"GeoIP"}
		}
		return []string{"MMDB"}
	case C.GEOSITE:
		return []string{"GeoSite"}
	case C.IPASN, C.SrcIPASN:
		return []string{"ASN"}
	default:
		return nil
	}
}
func RuleScopes(cfg *config.Config, p *configinput.Provenance, sources DiagnosticSources) []RuleScope {
	result := []RuleScope{{Kind: "main", Count: len(cfg.Rules)}}
	names := make([]string, 0, len(cfg.SubRules))
	for name := range cfg.SubRules {
		names = append(names, name)
	}
	declaredSourceOrder(names, sources.subRules)
	for _, name := range names {
		result = append(result, RuleScope{Kind: "sub", Name: name, Count: len(cfg.SubRules[name])})
	}
	names = names[:0]
	for name := range cfg.RuleProviders {
		names = append(names, name)
	}
	declaredSourceOrder(names, sources.ruleProviders)
	for _, name := range names {
		rp := cfg.RuleProviders[name]
		result = append(result, RuleScope{Kind: "provider", Name: name, Count: rp.Count(), Behavior: rp.Behavior().String(), Provenance: p.Definition("rule-providers", name)})
	}
	return result
}
func RuleSourceIdentity(cfg *config.Config, q RuleQuery) string {
	rp := cfg.RuleProviders[q.Name]
	var strategy any
	if rp != nil {
		strategy = rp.Strategy()
	}
	hash := sha256.Sum256([]byte(fmt.Sprintf("%p/%s/%s/%p/%p", cfg, q.Kind, q.Name, rp, strategy)))
	return hex.EncodeToString(hash[:])
}
func RuleOrigin(cfg *config.Config, q RuleQuery) string {
	if q.Kind != "provider" {
		return "compiled-rules"
	}
	if rp := cfg.RuleProviders[q.Name]; rp != nil && rp.VehicleType() == P.Inline {
		return "inline-source"
	}
	return "normalized-rules"
}

// StreamRules只读取公开规则、DumpMrs和inline payload，不重读Vehicle.Path。
func StreamRules(cfg *config.Config, p *configinput.Provenance, q RuleQuery, emit func(any) error) (string, error) {
	if err := q.Validate(); err != nil {
		return "", err
	}
	identity := RuleSourceIdentity(cfg, q)
	var rules []C.Rule
	switch q.Kind {
	case "main":
		rules = cfg.Rules
	case "sub":
		var ok bool
		rules, ok = cfg.SubRules[q.Name]
		if !ok {
			return identity, errors.New("sub-rule group is unavailable")
		}
	case "provider":
		rp := cfg.RuleProviders[q.Name]
		if rp == nil {
			return identity, errors.New("rule provider is unavailable")
		}
		strategy := rp.Strategy()
		index := 0
		var readErr error
		emitText := func(text string) error {
			index++
			return emit(RuleRow{Index: index, Type: rp.Behavior().String(), Payload: text, Providers: []string{q.Name}, Provenance: p.Definition("rule-providers", q.Name)})
		}
		if rp.VehicleType() == P.Inline {
			data, err := json.Marshal(rp)
			if err != nil {
				return identity, err
			}
			var payload struct {
				Payload []string `json:"payload"`
			}
			if err = json.Unmarshal(data, &payload); err != nil {
				return identity, err
			}
			for _, text := range payload.Payload {
				if err = emitText(text); err != nil {
					return identity, err
				}
			}
		} else if dump, ok := strategy.(interface{ DumpMrs(func(string) bool) }); ok {
			dump.DumpMrs(func(text string) bool { readErr = emitText(text); return readErr == nil })
		} else {
			return identity, RuleReadError("sourceUnavailable: public classical provider entries are unavailable")
		}
		if readErr != nil {
			return identity, readErr
		}
		if cfg.RuleProviders[q.Name] != rp || rp.Strategy() != strategy {
			return identity, RuleReadError("sourceChanged")
		}
	}
	for index, rule := range rules {
		if err := emit(RuleRow{Index: index + 1, Type: rule.RuleType().String(), Payload: rule.Payload(), Target: rule.Adapter(), Providers: append([]string{}, rule.ProviderNames()...), Resources: directRuleResources(rule), Provenance: p.Rule(q.Name, index)}); err != nil {
			return identity, err
		}
	}
	if RuleSourceIdentity(cfg, q) != identity {
		return identity, RuleReadError("sourceChanged")
	}
	return identity, nil
}
