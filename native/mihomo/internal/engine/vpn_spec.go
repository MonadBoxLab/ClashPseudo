package engine

import (
	"encoding/json"
	"io"
	"net/netip"
	"slices"

	"clashpseudo/native/internal/androidnet"
	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func makeVPNSpec(cfg *config.Config, presence configinput.Presence, options PrepareOptions) (*androidnet.VPNSpec, error) {
	configured := false
	for _, key := range []string{"include-package", "exclude-package", "include-uid", "exclude-uid", "include-uid-range", "exclude-uid-range", "include-android-user"} {
		configured = configured || presence.Has("tun."+key)
	}
	spec, err := androidnet.ProjectVPNSpec(cfg, options.Network, configured)
	if err != nil {
		return nil, err
	}
	spec.Generation, spec.Composition, spec.Revision = options.Generation, options.Composition, 1
	return spec, nil
}

func (e *Engine) VPNSpec() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() || e.spec == nil {
		return `{"error":"VPN specification is unavailable"}`
	}
	data, err := json.Marshal(e.spec)
	if err != nil {
		return `{"error":"VPN specification encoding failed"}`
	}
	return string(data)
}

func (e *Engine) watchRouteSets() io.Closer {
	cfg, owner := e.cfg, e.owner
	options := cfg.General.Tun
	if len(options.RouteAddressSet)+len(options.RouteExcludeAddressSet) == 0 {
		return nil
	}
	return tunnel.Tunnel.RuleUpdateCallback().Register(func(provider P.RuleProvider) {
		if !slices.Contains(options.RouteAddressSet, provider.Name()) && !slices.Contains(options.RouteExcludeAddressSet, provider.Name()) {
			return
		}
		e.mu.Lock()
		if e.owner != owner || e.cfg != cfg || !e.available() || e.spec == nil {
			e.mu.Unlock()
			return
		}
		candidate, err := androidnet.ProjectVPNSpec(cfg, e.options.Network, e.spec.Filter.Configured)
		var routes []netip.Prefix
		var servers []string
		var usedSystem bool
		if err == nil {
			candidate.UsesSystemDNS = candidate.UsesSystemDNS || e.usesSystemDNS
			routes, servers, usedSystem = candidate.Routes, candidate.DNSServers, candidate.UsesSystemDNS
		}
		// Validate routes and DNS as one complete candidate before publication.
		changed := (err == nil) != (e.specError == nil)
		if err != nil && e.specError != nil {
			changed = err.Error() != e.specError.Error()
		} else if err == nil {
			changed = changed || !slices.Equal(routes, e.spec.Routes) ||
				!slices.Equal(servers, e.spec.DNSServers) || usedSystem != e.spec.UsesSystemDNS
		}
		if !changed {
			e.mu.Unlock()
			return
		}
		e.specError = err
		if err == nil {
			e.spec.Routes, e.spec.DNSServers, e.spec.UsesSystemDNS = routes, servers, usedSystem
		}
		e.spec.Revision++
		callback, revision := e.specChanged, e.spec.Revision
		needed := e.tun != nil && (err != nil || !slices.Equal(routes, e.attachedRoutes))
		e.mu.Unlock()
		if callback != nil {
			callback(revision, needed)
		}
	})
}
