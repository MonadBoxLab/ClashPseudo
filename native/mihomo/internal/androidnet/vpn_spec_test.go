package androidnet

import (
	"net/netip"
	"reflect"
	"slices"
	"testing"

	"github.com/metacubex/mihomo/config"

	LC "github.com/metacubex/mihomo/listener/config"
)

func TestVPNSpecProjectionUsesActualConfigWithoutSessionIdentity(t *testing.T) {
	general := new(config.General)
	general.Tun = LC.Tun{MTU: 1420, AutoRoute: true,
		Inet4Address: []netip.Prefix{netip.MustParsePrefix("198.18.0.1/30")},
		Inet6Address: []netip.Prefix{netip.MustParsePrefix("fd00::1/126")},
		DNSHijack:    []string{"any:53"}, IncludePackage: []string{"fixture.include"}, ExcludePackage: []string{"fixture.exclude"},
		IncludeUID: []uint32{10001}, ExcludeUID: []uint32{10002}, IncludeUIDRange: []string{"10003:10004"},
		ExcludeUIDRange: []string{"10005:10006"}, IncludeAndroidUser: []int{10},
	}
	cfg := &config.Config{General: general, DNS: &config.DNS{Enable: true}}
	spec, err := ProjectVPNSpec(cfg, NetworkDNS{ID: "actual-network"}, true)
	if err != nil {
		t.Fatal(err)
	}
	if spec.MTU != general.Tun.MTU || !slices.Equal(spec.Addresses[:1], general.Tun.Inet4Address) ||
		!slices.Equal(spec.Addresses[1:], general.Tun.Inet6Address) ||
		!slices.Equal(spec.DNSServers, []string{"198.18.0.2", "fd00::2"}) || spec.UsesSystemDNS {
		t.Fatalf("projection did not retain actual addresses, MTU or reachable hijack: %+v", spec)
	}
	if spec.Generation != 0 || spec.Composition != "" || spec.Revision != 0 {
		t.Fatal("network projection manufactured an Engine session identity")
	}
	want := PacketFilter{Configured: true, IncludePackage: []string{"fixture.include"}, ExcludePackage: []string{"fixture.exclude"},
		IncludeUID: []uint32{10001}, ExcludeUID: []uint32{10002}, IncludeUIDRange: []string{"10003:10004"},
		ExcludeUIDRange: []string{"10005:10006"}, IncludeAndroidUser: []int{10}}
	if !reflect.DeepEqual(spec.Filter, want) {
		t.Fatalf("actual packet filters changed: %+v", spec.Filter)
	}
	general.Tun.IncludePackage[0] = "changed.include"
	general.Tun.ExcludePackage[0] = "changed.exclude"
	general.Tun.IncludeUID[0] = 20001
	general.Tun.ExcludeUID[0] = 20002
	general.Tun.IncludeUIDRange[0] = "20003:20004"
	general.Tun.ExcludeUIDRange[0] = "20005:20006"
	general.Tun.IncludeAndroidUser[0] = 20
	general.Tun.Inet4Address[0] = netip.MustParsePrefix("192.0.2.1/30")
	if !reflect.DeepEqual(spec.Filter, want) || spec.Addresses[0] != netip.MustParsePrefix("198.18.0.1/30") {
		t.Fatal("published projection retained mutable config slices")
	}
}

func TestStaticCIDRSubtractionIncludesBothAddressFamiliesWithoutExcludeRouteAPI(t *testing.T) {
	options := LC.Tun{AutoRoute: true, Inet4Address: []netip.Prefix{netip.MustParsePrefix("198.18.0.1/30")}, Inet6Address: []netip.Prefix{netip.MustParsePrefix("fd00::1/126")}, RouteExcludeAddress: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("2001:db8::/32")}}
	routes, err := routePrefixes(options, nil)
	if err != nil {
		t.Fatal(err)
	}
	contains := func(text string) bool {
		for _, prefix := range routes {
			if prefix.Contains(netip.MustParseAddr(text)) {
				return true
			}
		}
		return false
	}
	if contains("10.1.1.1") || contains("2001:db8::53") || !contains("192.0.2.1") || !contains("2001:db9::1") {
		t.Fatal("CIDR set subtraction did not implement both-family exclusions", routes)
	}
}
