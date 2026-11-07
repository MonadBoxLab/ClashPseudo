package engine

import (
	"encoding/json"
	"errors"

	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/profile/cachefile"
	"github.com/metacubex/mihomo/tunnel"

	"clashpseudo/native/internal/coreview"
)

func (e *Engine) Strategies() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	observations, err := coreview.StrategyGroups(e.cfg)
	if err != nil {
		return "", err
	}
	// The session computes opaque identities through the same functions used by
	// delay batches. The read projection does not own delay or provider identity.
	for i := range observations {
		state := &observations[i].State
		if state.Now == "" {
			continue
		}
		proxy := observations[i].Proxy
		group, ok := proxy.Adapter().(G.ProxyGroup)
		if !ok {
			continue
		}
		for _, member := range group.Proxies() {
			if member.Name() == state.Now {
				state.CurrentIdentity = delayMemberIdentity(delaySourceIdentity(proxy), member)
				break
			}
		}
	}
	result := coreview.ReadStrategies(e.cfg, tunnel.Mode().String(), e.provenance, nil, observations)
	data, err := json.Marshal(result)
	return string(data), err
}

func (e *Engine) choiceTarget(name string, choice Choice) (G.ProxyGroup, string) {
	proxy := e.cfg.Proxies[name]
	if proxy == nil {
		return nil, "group-missing"
	}
	group, ok := proxy.Adapter().(G.ProxyGroup)
	if !ok || coreview.StrategyType(group.Type()) != choice.Type {
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

func (e *Engine) SetStrategy(name string, choice Choice, restore bool) error {
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
	// Serialize application API calls; upstream routing synchronization remains separate.
	if choice.Member == nil {
		selector.ForceSet("")
	} else if err := selector.Set(*choice.Member); err != nil {
		return err
	}
	actual, err := coreview.StrategyState(group)
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
	// Only confirmed explicit operations write to the upstream cache; AppRuntime restoration is not a user selection.
	if !restore && e.cfg.Profile.StoreSelected {
		cachefile.Cache().SetSelected(name, wanted)
	}
	return nil
}
