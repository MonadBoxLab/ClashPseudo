package engine

import (
	"encoding/json"
	"errors"
	"sort"

	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	C "github.com/metacubex/mihomo/constant"
)

type Choice struct {
	Type   string  `json:"type"`
	Member *string `json:"member"`
}

func DecodeChoice(data []byte) (Choice, error) {
	var fields map[string]json.RawMessage
	var choice Choice
	if json.Unmarshal(data, &fields) != nil || fields["member"] == nil || json.Unmarshal(data, &choice) != nil || !choice.valid() {
		return Choice{}, errors.New("invalid strategy choice")
	}
	return choice, nil
}

func DecodeChoices(data []byte) (map[string]Choice, error) {
	var fields map[string]json.RawMessage
	if json.Unmarshal(data, &fields) != nil || fields == nil {
		return nil, errors.New("invalid strategy choices")
	}
	choices := make(map[string]Choice, len(fields))
	for name, value := range fields {
		choice, err := DecodeChoice(value)
		if name == "" || err != nil {
			return nil, errors.New("invalid strategy choices")
		}
		choices[name] = choice
	}
	return choices, nil
}

func (c Choice) valid() bool {
	if c.Type != "select" && c.Type != "url-test" && c.Type != "fallback" {
		return false
	}
	return (c.Member == nil && c.Type != "select") || (c.Member != nil && *c.Member != "")
}

type StrategyMember struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type Strategy struct {
	Name    string           `json:"name"`
	Type    string           `json:"type"`
	Hidden  bool             `json:"hidden"`
	Icon    string           `json:"icon"`
	Now     string           `json:"now"`
	Fixed   string           `json:"fixed"`
	Members []StrategyMember `json:"members"`
}

type UnrestoredChoice struct {
	Group  string `json:"group"`
	Reason string `json:"reason"`
}

type Strategies struct {
	Groups           []Strategy         `json:"groups"`
	GlobalReferenced bool               `json:"globalReferenced"`
	Unrestored       []UnrestoredChoice `json:"unrestored"`
}

func strategyType(value C.AdapterType) string {
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

func strategyState(group G.ProxyGroup) (Strategy, error) {
	state := Strategy{
		Name: group.Name(), Type: strategyType(group.Type()), Hidden: group.Hidden(), Icon: group.Icon(),
		Members: make([]StrategyMember, 0),
	}
	for _, member := range group.Proxies() {
		state.Members = append(state.Members, StrategyMember{Name: member.Name(), Type: strategyType(member.Type())})
	}
	switch group.Type() {
	case C.Selector:
		state.Now = group.Now()
	case C.URLTest, C.Fallback:
		// The adapter exposes fixed through JSON, not a public getter. Do not
		// marshal its proxy wrapper, which also probes protocol capabilities.
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

func (e *Engine) Strategies() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	result := Strategies{Groups: make([]Strategy, 0), Unrestored: append([]UnrestoredChoice{}, e.unrestored...)}
	seen := make(map[string]bool)
	appendGroup := func(proxy C.Proxy) error {
		group, ok := proxy.Adapter().(G.ProxyGroup)
		if !ok || seen[group.Name()] {
			return nil
		}
		state, err := strategyState(group)
		if err != nil {
			return err
		}
		seen[group.Name()] = true
		result.Groups = append(result.Groups, state)
		return nil
	}
	if provider := e.cfg.Providers["default"]; provider != nil {
		for _, proxy := range provider.Proxies() {
			if err := appendGroup(proxy); err != nil {
				return "", err
			}
		}
	}
	if global := e.cfg.Proxies["GLOBAL"]; global != nil {
		if err := appendGroup(global); err != nil {
			return "", err
		}
		for _, proxy := range e.cfg.Proxies {
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
	result.GlobalReferenced = result.GlobalReferenced || referencesGlobal(e.cfg.Rules)
	for _, rules := range e.cfg.SubRules {
		result.GlobalReferenced = result.GlobalReferenced || referencesGlobal(rules)
	}
	data, err := json.Marshal(result)
	return string(data), err
}

func (e *Engine) choiceTarget(name string, choice Choice) (G.ProxyGroup, string) {
	proxy := e.cfg.Proxies[name]
	if proxy == nil {
		return nil, "group-missing"
	}
	group, ok := proxy.Adapter().(G.ProxyGroup)
	if !ok || strategyType(group.Type()) != choice.Type {
		return nil, "type-changed"
	}
	if _, ok = group.(G.SelectAble); !ok {
		return nil, "not-selectable"
	}
	if choice.Member != nil {
		for _, member := range group.Proxies() {
			if member.Name() == *choice.Member {
				return group, ""
			}
		}
		return nil, "member-missing"
	}
	return group, ""
}

func (e *Engine) restoreChoices(choices map[string]Choice) {
	e.unrestored = nil
	names := make([]string, 0, len(choices))
	for name := range choices {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		choice := choices[name]
		group, reason := e.choiceTarget(name, choice)
		if reason != "" {
			e.unrestored = append(e.unrestored, UnrestoredChoice{Group: name, Reason: reason})
			continue
		}
		member := ""
		if choice.Member != nil {
			member = *choice.Member
		}
		// Restoration must not invoke Fallback.Set's implicit URL test.
		group.(G.SelectAble).ForceSet(member)
	}
}

func (e *Engine) SetStrategy(name string, choice Choice) error {
	if !choice.valid() {
		return errors.New("invalid strategy choice")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return ErrStopped
	}
	group, reason := e.choiceTarget(name, choice)
	if reason != "" {
		return errors.New(reason)
	}
	selector := group.(G.SelectAble)
	// Serializes our calls, not upstream's unsynchronized traffic-side reads.
	if choice.Member == nil {
		selector.ForceSet("")
	} else if err := selector.Set(*choice.Member); err != nil {
		return err
	}
	actual, err := strategyState(group)
	if err != nil {
		return err
	}
	wanted := ""
	if choice.Member != nil {
		wanted = *choice.Member
	}
	confirmed := actual.Fixed == wanted
	if choice.Type == "select" {
		confirmed = actual.Now == wanted
	}
	if !confirmed || !e.available() {
		return errors.New("strategy application was not confirmed")
	}
	remaining := e.unrestored[:0]
	for _, warning := range e.unrestored {
		if warning.Group != name {
			remaining = append(remaining, warning)
		}
	}
	e.unrestored = remaining
	return nil
}
