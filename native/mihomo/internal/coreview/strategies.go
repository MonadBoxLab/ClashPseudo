package coreview

import (
	"encoding/json"

	"clashpseudo/native/internal/configinput"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

type StrategyMember struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type Strategy struct {
	Name            string                            `json:"name"`
	Type            string                            `json:"type"`
	Hidden          bool                              `json:"hidden"`
	Icon            string                            `json:"icon"`
	Now             string                            `json:"now"`
	CurrentIdentity string                            `json:"currentIdentity"`
	Fixed           string                            `json:"fixed"`
	Provenance      *configinput.DefinitionProvenance `json:"provenance,omitempty"`
	Members         []StrategyMember                  `json:"members"`
}

type UnrestoredChoice struct {
	Group  string `json:"group"`
	Reason string `json:"reason"`
}

type Strategies struct {
	Mode             string             `json:"mode"`
	Groups           []Strategy         `json:"groups"`
	GlobalReferenced bool               `json:"globalReferenced"`
	Unrestored       []UnrestoredChoice `json:"unrestored"`
}

func StrategyType(value C.AdapterType) string {
	switch value {
	case C.Selector:
		return "select"
	case C.URLTest:
		return "url-test"
	case C.Fallback:
		return "fallback"
	case C.LoadBalance:
		return "load-balance"
	default:
		return value.String()
	}
}

func StrategyState(group G.ProxyGroup) (Strategy, error) {
	state := Strategy{
		Name: group.Name(), Type: StrategyType(group.Type()), Hidden: group.Hidden(), Icon: group.Icon(),
		Members: make([]StrategyMember, 0),
	}
	for _, member := range group.Proxies() {
		state.Members = append(state.Members, StrategyMember{Name: member.Name(), Type: StrategyType(member.Type())})
	}
	switch group.Type() {
	case C.Selector:
		state.Now = group.Now()
	case C.URLTest, C.Fallback:
		// Read the adapter's fixed field through its own JSON projection.
		data, err := group.MarshalJSON()
		if err != nil {
			return Strategy{}, err
		}
		var selection struct {
			Now   string `json:"now"`
			Fixed string `json:"fixed"`
		}
		if err = json.Unmarshal(data, &selection); err != nil {
			return Strategy{}, err
		}
		state.Now, state.Fixed = selection.Now, selection.Fixed
	}
	return state, nil
}

// StrategyObservation binds public group state to the exact captured proxy.
// The session fills CurrentIdentity before passing observations to ReadStrategies.
type StrategyObservation struct {
	Proxy C.Proxy
	State Strategy
}

func StrategyGroups(cfg *config.Config) ([]StrategyObservation, error) {
	result := make([]StrategyObservation, 0)
	seen := make(map[string]bool)
	appendGroup := func(proxy C.Proxy) error {
		group, ok := proxy.Adapter().(G.ProxyGroup)
		if !ok || seen[group.Name()] {
			return nil
		}
		state, err := StrategyState(group)
		if err != nil {
			return err
		}
		seen[group.Name()] = true
		result = append(result, StrategyObservation{Proxy: proxy, State: state})
		return nil
	}
	if provider := cfg.Providers["default"]; provider != nil {
		for _, proxy := range provider.Proxies() {
			if err := appendGroup(proxy); err != nil {
				return nil, err
			}
		}
	}
	if global := cfg.Proxies["GLOBAL"]; global != nil {
		if err := appendGroup(global); err != nil {
			return nil, err
		}
	}
	return result, nil
}

func ReadStrategies(cfg *config.Config, mode string, provenance *configinput.Provenance, unrestored []UnrestoredChoice, observations []StrategyObservation) Strategies {
	result := Strategies{Mode: mode, Groups: make([]Strategy, 0, len(observations)), Unrestored: append([]UnrestoredChoice{}, unrestored...)}
	for _, observation := range observations {
		state := observation.State
		state.Provenance = provenance.Definition("proxy-groups", state.Name)
		result.Groups = append(result.Groups, state)
	}
	if global := cfg.Proxies["GLOBAL"]; global != nil {
		for _, proxy := range cfg.Proxies {
			group, ok := proxy.Adapter().(G.ProxyGroup)
			if !ok || proxy == global {
				continue
			}
			for _, member := range group.Proxies() {
				if member.Adapter() == global.Adapter() {
					result.GlobalReferenced = true
				}
			}
		}
	}
	referencesGlobal := func(rules []C.Rule) bool {
		for _, rule := range rules {
			if rule.RuleType() != C.SubRules && rule.Adapter() == "GLOBAL" {
				return true
			}
		}
		return false
	}
	result.GlobalReferenced = result.GlobalReferenced || referencesGlobal(cfg.Rules)
	for _, rules := range cfg.SubRules {
		result.GlobalReferenced = result.GlobalReferenced || referencesGlobal(rules)
	}
	return result
}

func GlobalReferenced(cfg *config.Config) bool {
	return ReadStrategies(cfg, "", nil, nil, nil).GlobalReferenced
}
