package androidnet

import (
	"fmt"
	"net/netip"
	"slices"
	"strings"

	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
	LC "github.com/metacubex/mihomo/listener/config"
	tunlib "github.com/metacubex/sing-tun"
	"go4.org/netipx"
)

type PacketFilter struct {
	Configured         bool     `json:"configured"`
	IncludePackage     []string `json:"includePackage"`
	ExcludePackage     []string `json:"excludePackage"`
	IncludeUID         []uint32 `json:"includeUid"`
	ExcludeUID         []uint32 `json:"excludeUid"`
	IncludeUIDRange    []string `json:"includeUidRange"`
	ExcludeUIDRange    []string `json:"excludeUidRange"`
	IncludeAndroidUser []int    `json:"includeAndroidUser"`
}

type VPNSpec struct {
	Generation    int64          `json:"generation"`
	Composition   string         `json:"composition"`
	Revision      uint64         `json:"revision"`
	MTU           uint32         `json:"mtu"`
	Addresses     []netip.Prefix `json:"addresses"`
	Routes        []netip.Prefix `json:"routes"`
	DNSServers    []string       `json:"dnsServers"`
	Filter        PacketFilter   `json:"filter"`
	UsesSystemDNS bool           `json:"usesSystemDns"`
	NetworkKey    string         `json:"networkKey"`
}

func ParseHijack(values []string) ([]netip.AddrPort, error) {
	result := make([]netip.AddrPort, 0, len(values))
	for _, text := range values {
		if _, after, ok := strings.Cut(text, "://"); ok {
			text = after
		}
		text = strings.Replace(text, "any", "0.0.0.0", 1)
		address, err := netip.ParseAddrPort(text)
		if err != nil {
			return nil, fmt.Errorf("tun.dns-hijack: %w", err)
		}
		result = append(result, address)
	}
	return result, nil
}

func providerPrefixes(providers map[string]P.RuleProvider, names []string) ([]netip.Prefix, error) {
	var prefixes []netip.Prefix
	for _, name := range names {
		provider := providers[name]
		if provider == nil {
			return nil, fmt.Errorf("TUN route set %q was not found", name)
		}
		strategy, ok := provider.Strategy().(interface{ ToIpCidr() *netipx.IPSet })
		if !ok {
			return nil, fmt.Errorf("TUN route set %q does not expose an IP CIDR strategy", name)
		}
		if set := strategy.ToIpCidr(); set != nil {
			prefixes = append(prefixes, set.Prefixes()...)
		}
	}
	return prefixes, nil
}

func routePrefixes(options LC.Tun, providers map[string]P.RuleProvider) ([]netip.Prefix, error) {
	include := slices.Clone(options.RouteAddress)
	include = append(include, options.Inet4RouteAddress...)
	include = append(include, options.Inet6RouteAddress...)
	fromSet, err := providerPrefixes(providers, options.RouteAddressSet)
	if err != nil {
		return nil, err
	}
	include = append(include, fromSet...)
	if err := routeFamilies(include, options); err != nil {
		return nil, err
	}
	exclude := slices.Clone(options.RouteExcludeAddress)
	exclude = append(exclude, options.Inet4RouteExcludeAddress...)
	exclude = append(exclude, options.Inet6RouteExcludeAddress...)
	fromSet, err = providerPrefixes(providers, options.RouteExcludeAddressSet)
	if err != nil {
		return nil, err
	}
	exclude = append(exclude, fromSet...)
	public := tunlib.Options{AutoRoute: options.AutoRoute, Inet4Address: options.Inet4Address, Inet6Address: options.Inet6Address}
	for _, prefix := range include {
		if prefix.Addr().Is4() {
			public.Inet4RouteAddress = append(public.Inet4RouteAddress, prefix)
		} else {
			public.Inet6RouteAddress = append(public.Inet6RouteAddress, prefix)
		}
	}
	for _, prefix := range exclude {
		if prefix.Addr().Is4() {
			public.Inet4RouteExcludeAddress = append(public.Inet4RouteExcludeAddress, prefix)
		} else {
			public.Inet6RouteExcludeAddress = append(public.Inet6RouteExcludeAddress, prefix)
		}
	}
	return public.BuildAutoRouteRanges(false)
}

func routeFamilies(routes []netip.Prefix, options LC.Tun) error {
	for _, route := range routes {
		if route.Addr().Is6() && len(options.Inet6Address) == 0 {
			return &PlatformError{Field: "tun.route-address", Reason: "ipv6Unavailable"}
		}
		if route.Addr().Is4() && len(options.Inet4Address) == 0 {
			return &PlatformError{Field: "tun.route-address", Reason: "invalidAddress"}
		}
	}
	return nil
}

func projectDNSServers(enabled bool, hijack []netip.AddrPort, addresses []netip.Prefix,
	routes []netip.Prefix, network NetworkDNS) (servers []string, usedSystem bool, err error) {
	if enabled && len(hijack) > 0 {
		// Use the public handler's actual wildcard hijack list.
		for _, prefix := range addresses {
			candidate := netip.AddrPortFrom(prefix.Addr().Next(), 53)
			for _, entry := range hijack {
				if entry == candidate || entry.Addr().IsUnspecified() {
					for _, route := range routes {
						if route.Contains(candidate.Addr()) {
							servers = append(servers, candidate.Addr().String())
							break
						}
					}
					break
				}
			}
		}
		if len(servers) == 0 {
			for _, entry := range hijack {
				if entry.Port() == 53 && !entry.Addr().IsUnspecified() {
					for _, route := range routes {
						if route.Contains(entry.Addr()) {
							servers = append(servers, entry.Addr().String())
							break
						}
					}
				}
			}
		}
	}
	if len(servers) == 0 {
		underlying, err := network.addresses()
		if err != nil {
			return nil, false, fmt.Errorf("client DNS without an effective TUN hijack: %w", err)
		}
		for _, server := range underlying {
			addr, err := netip.ParseAddrPort(server.Addr)
			if err != nil {
				return nil, false, err
			}
			for _, prefix := range addresses {
				if prefix.Addr().Is4() == addr.Addr().Is4() {
					servers = append(servers, addr.Addr().String())
					break
				}
			}
		}
		if len(servers) == 0 {
			return nil, false, &PlatformError{Field: "system-dns", Reason: "systemDnsUnavailable"}
		}
		usedSystem = true
	}
	return servers, usedSystem, nil
}

func ProjectVPNSpec(cfg *config.Config, network NetworkDNS, filterConfigured bool) (*VPNSpec, error) {
	tun := cfg.General.Tun
	if !cfg.DNS.Enable && (len(tun.DNSHijack) != 0 || len(tun.Inet4Address) != 0 || len(tun.Inet6Address) != 0) {
		return nil, &PlatformError{Field: "tun.dns-hijack", Reason: "dnsHijackConflict"}
	}
	if tun.MTU == 0 {
		tun.MTU = 9000
	}
	if tun.MTU > 65535 {
		return nil, &PlatformError{Field: "tun.mtu", Reason: "invalidMtu"}
	}
	addresses := append(slices.Clone(tun.Inet4Address), tun.Inet6Address...)
	if len(addresses) == 0 {
		return nil, &PlatformError{Field: "tun", Reason: "invalidAddress"}
	}
	for _, prefix := range addresses {
		addr := prefix.Addr()
		if !prefix.IsValid() || addr.IsUnspecified() || addr.IsMulticast() || !prefix.Contains(addr.Next()) {
			return nil, &PlatformError{Field: "tun", Reason: "invalidAddress"}
		}
		if addr.Is6() && tun.MTU < 1280 {
			return nil, &PlatformError{Field: "tun.mtu", Reason: "invalidMtu"}
		}
	}
	routes, err := routePrefixes(tun, cfg.RuleProviders)
	if err != nil {
		return nil, err
	}
	// Require an effective IPv6 interface address before publishing an explicit IPv6
	// route.
	if err := routeFamilies(routes, tun); err != nil {
		return nil, err
	}
	hijack, err := ParseHijack(tun.DNSHijack)
	if err != nil {
		return nil, err
	}
	for _, prefix := range addresses {
		hijack = append(hijack, netip.AddrPortFrom(prefix.Addr().Next(), 53))
	}
	dnsServers, usedSystem, err := projectDNSServers(cfg.DNS.Enable, hijack, addresses, routes, network)
	if err != nil {
		return nil, err
	}
	return &VPNSpec{MTU: tun.MTU, Addresses: addresses, Routes: routes, DNSServers: dnsServers,
		Filter: PacketFilter{filterConfigured, slices.Clone(tun.IncludePackage), slices.Clone(tun.ExcludePackage), slices.Clone(tun.IncludeUID), slices.Clone(tun.ExcludeUID), slices.Clone(tun.IncludeUIDRange), slices.Clone(tun.ExcludeUIDRange), slices.Clone(tun.IncludeAndroidUser)}, UsesSystemDNS: usedSystem, NetworkKey: network.Key()}, nil
}
