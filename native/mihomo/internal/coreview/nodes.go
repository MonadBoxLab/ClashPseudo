package coreview

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"

	"clashpseudo/native/internal/configinput"
	G "github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

var ErrNodesChanged = errors.New("proxy provider membership changed")

type proxyStamp struct {
	name     string
	provider P.ProxyProvider
	version  uint32
}

func captureProviders(cfg *config.Config) ([]proxyStamp, string) {
	names := make([]string, 0, len(cfg.Providers))
	for name := range cfg.Providers {
		names = append(names, name)
	}
	slices.Sort(names)
	stamps := make([]proxyStamp, 0, len(names))
	hash := sha256.New()
	fmt.Fprintf(hash, "%p", cfg)
	for _, name := range names {
		p := cfg.Providers[name]
		v := p.Version()
		stamps = append(stamps, proxyStamp{name, p, v})
		fmt.Fprintf(hash, "/%s:%p:%d", name, p, v)
	}
	return stamps, hex.EncodeToString(hash.Sum(nil))
}
func providersCurrent(cfg *config.Config, stamps []proxyStamp) bool {
	if len(cfg.Providers) != len(stamps) {
		return false
	}
	for _, s := range stamps {
		if cfg.Providers[s.name] != s.provider || s.provider.Version() != s.version {
			return false
		}
	}
	return true
}

// StreamNodes exports each node's type, capabilities, and delay history.
func StreamNodes(cfg *config.Config, p *configinput.Provenance, sources DiagnosticSources, source *string, emit func(any) error) (string, error) {
	if source != nil && len(*source) > 4096 {
		return "", errors.New("proxy provider source is too long")
	}
	stamps, identity := captureProviders(cfg)
	appendNode := func(proxy C.Proxy, kind, name string, version uint32) error {
		if _, group := proxy.Adapter().(G.ProxyGroup); group {
			return nil
		}
		raw, err := proxy.MarshalJSON()
		if err != nil {
			return err
		}
		var public struct {
			Type    string                  `json:"type"`
			UDP     *bool                   `json:"udp"`
			UOT     *bool                   `json:"uot"`
			XUDP    *bool                   `json:"xudp"`
			TFO     *bool                   `json:"tfo"`
			MPTCP   *bool                   `json:"mptcp"`
			SMUX    *bool                   `json:"smux"`
			History []C.DelayHistory        `json:"history"`
			Extra   map[string]C.ProxyState `json:"extra"`
		}
		if err := json.Unmarshal(raw, &public); err != nil {
			return err
		}
		row := map[string]any{
			"kind": "node", "name": proxy.Name(), "type": public.Type,
			"sourceKind": kind, "sourceName": name, "sourceVersion": version,
			"history": public.History, "extra": public.Extra,
		}
		for key, capability := range map[string]*bool{
			"udp": public.UDP, "uot": public.UOT, "xudp": public.XUDP,
			"tfo": public.TFO, "mptcp": public.MPTCP, "smux": public.SMUX,
		} {
			if capability != nil {
				row[key] = *capability
			}
		}
		if kind == "proxyProvider" {
			row["providerProvenance"] = p.Definition("proxy-providers", name)
		} else {
			row["provenance"] = p.Definition("proxies", proxy.Name())
		}
		return emit(row)
	}
	if source == nil {
		names := make([]string, 0, len(cfg.Proxies))
		for name := range cfg.Proxies {
			names = append(names, name)
		}
		slices.Sort(names)
		for _, name := range names {
			if err := appendNode(cfg.Proxies[name], "configuration", "", 0); err != nil {
				return identity, err
			}
		}
	}
	found := source == nil
	names := make([]string, 0, len(stamps))
	byName := make(map[string]proxyStamp, len(stamps))
	for _, stamp := range stamps {
		names = append(names, stamp.name)
		byName[stamp.name] = stamp
	}
	declaredSourceOrder(names, sources.proxyProviders)
	for _, name := range names {
		stamp := byName[name]
		if stamp.provider.VehicleType() == P.Compatible {
			continue
		}
		if source != nil && *source != stamp.name {
			continue
		}
		found = true
		for _, proxy := range stamp.provider.Proxies() {
			if err := appendNode(proxy, "proxyProvider", stamp.name, stamp.version); err != nil {
				return identity, err
			}
		}
	}
	if !found {
		return identity, errors.New("proxy provider source is unavailable")
	}
	if !providersCurrent(cfg, stamps) {
		return identity, ErrNodesChanged
	}
	return identity, nil
}

func StreamGroups(cfg *config.Config, p *configinput.Provenance, emit func(any) error) (string, error) {
	stamps, identity := captureProviders(cfg)
	names := make([]string, 0, len(cfg.Proxies))
	for name := range cfg.Proxies {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		proxy := cfg.Proxies[name]
		group, ok := proxy.Adapter().(G.ProxyGroup)
		if !ok {
			continue
		}
		state, err := StrategyState(group)
		if err != nil {
			return identity, err
		}
		sourceIdentity := GroupSourceIdentity(proxy)
		currentIdentity := ""
		members := make([]map[string]string, 0)
		for _, member := range group.Proxies() {
			memberIdentity := MemberIdentity(sourceIdentity, member)
			members = append(members, map[string]string{"name": member.Name(), "type": StrategyType(member.Type()), "identity": memberIdentity})
			if member.Name() == state.Now {
				currentIdentity = memberIdentity
			}
		}
		if err = emit(map[string]any{"kind": "group", "name": name, "type": state.Type, "hidden": state.Hidden, "now": state.Now, "fixed": state.Fixed, "icon": state.Icon, "members": members, "sourceIdentity": sourceIdentity, "currentIdentity": currentIdentity, "provenance": p.Definition("proxy-groups", name)}); err != nil {
			return identity, err
		}
	}
	if !providersCurrent(cfg, stamps) {
		return identity, ErrNodesChanged
	}
	return identity, nil
}

func ProxySourceIdentity(cfg *config.Config) string {
	_, identity := captureProviders(cfg)
	return identity
}

type identityProviderStamp struct {
	provider P.ProxyProvider
	version  uint32
}

// identityProviders reads public identities and versions of nested providers, visiting each provider once.
func identityProviders(proxy C.Proxy) []identityProviderStamp {
	var stamps []identityProviderStamp
	seen := make(map[P.ProxyProvider]bool)
	var visit func(C.Proxy)
	visit = func(member C.Proxy) {
		group, ok := member.Adapter().(interface{ Providers() []P.ProxyProvider })
		if !ok {
			return
		}
		for _, provider := range group.Providers() {
			if seen[provider] {
				continue
			}
			seen[provider] = true
			stamps = append(stamps, identityProviderStamp{provider, provider.Version()})
			for _, child := range provider.Proxies() {
				visit(child)
			}
		}
	}
	visit(proxy)
	return stamps
}

func GroupSourceIdentity(proxy C.Proxy) string {
	hash := sha256.New()
	fmt.Fprintf(hash, "%p", proxy)
	for _, stamp := range identityProviders(proxy) {
		fmt.Fprintf(hash, "/%p:%d", stamp.provider, stamp.version)
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func MemberIdentity(source string, proxy C.Proxy) string {
	// MemberIdentity ties together the current group, provider version, and actual proxy object.
	sum := sha256.Sum256([]byte(fmt.Sprintf("%s/%p/%s/%s", source, proxy, proxy.Name(), proxy.Type())))
	return hex.EncodeToString(sum[:])
}
