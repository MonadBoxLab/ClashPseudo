package engine

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"sort"
	"strings"

	"github.com/metacubex/mihomo/component/geodata"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"

	"clashpseudo/native/internal/configinput"
)

type RuleQuery struct {
	Kind   string `json:"kind"`
	Name   string `json:"name"`
	Offset int    `json:"offset"`
	Limit  int    `json:"limit"`
	Search string `json:"search"`
	Token  string `json:"token"`
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

// Identify databases from direct public rule types. LAN GeoIP uses its own matching
// path.
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

type RulePage struct {
	Scopes      []RuleScope `json:"scopes"`
	Rows        []RuleRow   `json:"rows"`
	Origin      string      `json:"origin"`
	Total       int         `json:"total"`
	NextOffset  int         `json:"nextOffset"`
	Token       string      `json:"token"`
	SourceToken string      `json:"sourceToken"`
	// Definition metadata is separate from provider payload/normalized rows.
	ProviderProvenance *configinput.DefinitionProvenance `json:"providerProvenance,omitempty"`
}

func (e *Engine) Rules(query RuleQuery) (string, error) {
	if query.Offset < 0 || query.Limit < 1 || query.Limit > 100 || len(query.Search) > 4096 ||
		len(query.Name) > 4096 || (query.Offset > 0 && len(query.Token) != 64) {
		return "", errors.New("invalid rule query")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	page := RulePage{Rows: make([]RuleRow, 0, query.Limit), Origin: "compiled-rules", NextOffset: -1,
		Scopes: []RuleScope{{Kind: "main", Count: len(e.cfg.Rules)}}}
	subs := make([]string, 0, len(e.cfg.SubRules))
	for name := range e.cfg.SubRules {
		subs = append(subs, name)
	}
	sort.Strings(subs)
	for _, name := range subs {
		page.Scopes = append(page.Scopes, RuleScope{Kind: "sub", Name: name, Count: len(e.cfg.SubRules[name])})
	}
	providers := make([]string, 0, len(e.cfg.RuleProviders))
	for name := range e.cfg.RuleProviders {
		providers = append(providers, name)
	}
	declaredSourceOrder(providers, e.sources.ruleProviders)
	for _, name := range providers {
		provider := e.cfg.RuleProviders[name]
		page.Scopes = append(page.Scopes, RuleScope{Kind: "provider", Name: name, Count: provider.Count(), Behavior: provider.Behavior().String(),
			Provenance: e.provenance.Definition("rule-providers", name)})
	}

	sourceHash := sha256.New()
	encoder := json.NewEncoder(sourceHash)
	if err := encoder.Encode([]string{query.Kind, query.Name}); err != nil {
		return "", err
	}
	search := strings.ToLower(strings.TrimSpace(query.Search))
	emit := func(row RuleRow) error {
		if !e.available() {
			return ErrStopped
		}
		if err := encoder.Encode(row); err != nil {
			return err
		}
		if !strings.Contains(strings.ToLower(row.Type), search) &&
			!strings.Contains(strings.ToLower(row.Payload), search) &&
			!strings.Contains(strings.ToLower(row.Target), search) {
			return nil
		}
		index := page.Total
		page.Total++
		if index >= query.Offset && len(page.Rows) < query.Limit {
			page.Rows = append(page.Rows, row)
		}
		return nil
	}
	var rules []C.Rule
	switch query.Kind {
	case "main":
		if query.Name != "" {
			return "", errors.New("main rule query has a name")
		}
		rules = e.cfg.Rules
	case "sub":
		var exists bool
		rules, exists = e.cfg.SubRules[query.Name]
		if !exists {
			return "", errors.New("sub-rule group is unavailable")
		}
	case "provider":
		provider := e.cfg.RuleProviders[query.Name]
		if provider == nil {
			return "", errors.New("rule provider is unavailable")
		}
		page.ProviderProvenance = e.provenance.Definition("rule-providers", query.Name)
		strategy := provider.Strategy()
		index := 0
		var readErr error
		emitText := func(text string) error {
			index++
			return emit(RuleRow{Index: index, Type: provider.Behavior().String(), Payload: text, Providers: []string{query.Name}})
		}
		if provider.Behavior() == P.Classical {
			page.Origin, readErr = classicalSource(provider, e.ruleSources[query.Name], emitText)
		} else if dump, ok := strategy.(interface{ DumpMrs(func(string) bool) }); ok {
			page.Origin = "normalized-rules"
			// Domain DumpMrs collects and sorts the full upstream set before the adapter
			// selects a page.
			dump.DumpMrs(func(text string) bool { readErr = emitText(text); return readErr == nil })
		} else {
			return "", errors.New("rule provider does not expose entries")
		}
		if readErr != nil {
			return "", readErr
		}
		if strategy != provider.Strategy() {
			return "", errors.New("rule provider changed during reading")
		}
	default:
		return "", errors.New("invalid rule scope")
	}
	for index, rule := range rules {
		if err := emit(RuleRow{Index: index + 1, Type: rule.RuleType().String(), Payload: rule.Payload(),
			Target: rule.Adapter(), Providers: append([]string{}, rule.ProviderNames()...), Resources: directRuleResources(rule),
			Provenance: e.provenance.Rule(query.Name, index)}); err != nil {
			return "", err
		}
	}
	if err := encoder.Encode(page.Origin); err != nil {
		return "", err
	}
	page.SourceToken = hex.EncodeToString(sourceHash.Sum(nil))
	queryIdentity, err := json.Marshal([]string{page.SourceToken, query.Search})
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(queryIdentity)
	page.Token = hex.EncodeToString(hash[:])
	if query.Token != "" && query.Token != page.Token {
		return "", RuleReadError("sourceChanged")
	}
	if query.Offset > page.Total {
		return "", errors.New("rule page is out of range")
	}
	if query.Offset+len(page.Rows) < page.Total {
		page.NextOffset = query.Offset + len(page.Rows)
	}
	data, err := json.Marshal(page)
	if err != nil {
		return "", err
	}
	if len(data) > 8<<20 {
		return "", errors.New("rule page exceeds response budget")
	}
	return string(data), nil
}
