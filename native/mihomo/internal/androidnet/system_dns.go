package androidnet

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strings"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

// NetworkDNS is an underlying network snapshot captured before loading and never replaced afterward.
type NetworkDNS struct {
	ID                 string   `json:"id"`
	Servers            []string `json:"servers"`
	PrivateDNS         string   `json:"privateDns"`
	PrivateDNSHostname string   `json:"privateDnsServerName"`
	PrivateDNSActive   bool     `json:"isPrivateDnsActive"`
	SnapshotKey        string   `json:"key"`
	Revision           int64    `json:"revision"`
	APILevel           int      `json:"apiLevel"`
}

type DNSOwner struct {
	ID       uint64
	Revoked  context.Context
	Stopped  error
	RawQuery func(context.Context, []byte) ([]byte, error)
	Lookup   func(context.Context, string, int) ([]netip.Addr, error)
}

func (o DNSOwner) stopped() error {
	if o.Stopped != nil {
		return o.Stopped
	}
	return errors.New("native session is not accepting DNS queries")
}

func (n NetworkDNS) Private() bool {
	return n.PrivateDNSActive || n.PrivateDNSHostname != "" || n.PrivateDNS == "strict" || n.PrivateDNS == "active"
}

func (n NetworkDNS) addresses() ([]dns.NameServer, error) {
	if n.Private() {
		return nil, &PlatformError{Field: "system-dns", Reason: "privateDnsUnavailable"}
	}
	if n.ID == "" || len(n.Servers) == 0 {
		return nil, &PlatformError{Field: "system-dns", Reason: "systemDnsUnavailable"}
	}
	result := make([]dns.NameServer, 0, len(n.Servers))
	seen := map[netip.Addr]bool{}
	for _, text := range n.Servers {
		addr, err := netip.ParseAddr(text)
		if err != nil || addr.IsUnspecified() || addr.IsMulticast() {
			return nil, &PlatformError{Field: "system-dns", Reason: "invalidAddress"}
		}
		if !seen[addr] {
			result = append(result, dns.NameServer{Addr: net.JoinHostPort(addr.String(), "53")})
			seen[addr] = true
		}
	}
	return result, nil
}

// SystemServers is only used to configure the upstream explicit system client during process initialization.
func (n NetworkDNS) SystemServers() ([]string, error) {
	if n.ID == "" || n.Private() || len(n.Servers) == 0 {
		return nil, nil
	}
	servers, err := n.addresses()
	if err != nil {
		return nil, err
	}
	result := make([]string, len(servers))
	for i, server := range servers {
		result[i] = server.Addr
	}
	return result, nil
}

func (n NetworkDNS) Key() string {
	if n.SnapshotKey != "" {
		return n.SnapshotKey
	}
	servers := slices.Clone(n.Servers)
	slices.Sort(servers)
	return fmt.Sprintf("%s|%s|%t|%s|%d|%s", n.ID, n.PrivateDNS, n.PrivateDNSActive, n.PrivateDNSHostname, n.Revision, strings.Join(slices.Compact(servers), ","))
}

// NetworkResolver only uses public Android callbacks; it creates no UDP client or fallback DNS.
type NetworkResolver struct {
	owner   DNSOwner
	actual  resolver.Resolver
	network NetworkDNS
}

func NewNetworkResolver(network NetworkDNS, owner DNSOwner) *NetworkResolver {
	network.Servers = slices.Clone(network.Servers)
	r := &NetworkResolver{owner: owner, network: network}
	if network.APILevel >= 29 && owner.RawQuery != nil {
		r.actual = dns.NewResolverFromClient(&rawDNSClient{owner: owner, network: network.ID})
	}
	return r
}

func (r *NetworkResolver) check() error {
	if r.owner.Revoked != nil && r.owner.Revoked.Err() != nil {
		return r.owner.stopped()
	}
	if r.network.ID == "" {
		return &PlatformError{Field: "system-dns", Reason: "systemDnsUnavailable"}
	}
	return nil
}

func (r *NetworkResolver) lookup(ctx context.Context, host string, family int) ([]netip.Addr, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	if r.actual != nil {
		switch family {
		case 4:
			return r.actual.LookupIPv4(ctx, host)
		case 6:
			return r.actual.LookupIPv6(ctx, host)
		default:
			return r.actual.LookupIP(ctx, host)
		}
	}
	if r.owner.Lookup == nil {
		return nil, &PlatformError{Field: "system-dns", Reason: "systemDnsUnavailable"}
	}
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	if r.owner.Revoked != nil {
		stop := context.AfterFunc(r.owner.Revoked, cancel)
		defer stop()
	}
	ips, err := r.owner.Lookup(child, host, family)
	// getAllByName has no cancellation API; this call completes only after the callback returns.
	if child.Err() != nil {
		return ips, errors.Join(err, child.Err())
	}
	return ips, err
}
func (r *NetworkResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	return r.lookup(ctx, host, 0)
}
func (r *NetworkResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	return r.lookup(ctx, host, 4)
}
func (r *NetworkResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	return r.lookup(ctx, host, 6)
}
func (r *NetworkResolver) ExchangeContext(ctx context.Context, m *D.Msg) (*D.Msg, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	if r.actual == nil {
		return nil, &PlatformError{Field: "system-dns.raw-message", Reason: "systemDnsRawUnavailable"}
	}
	return r.actual.ExchangeContext(ctx, m)
}
func (r *NetworkResolver) ResolveECH(ctx context.Context, host string) ([]byte, error) {
	if err := r.check(); err != nil {
		return nil, err
	}
	if r.actual == nil {
		return nil, &PlatformError{Field: "system-dns.ech", Reason: "systemDnsRawUnavailable"}
	}
	return r.actual.ResolveECH(ctx, host)
}
func (r *NetworkResolver) Invalid() bool { return r.check() == nil }
func (r *NetworkResolver) ClearCache() {
	if r.actual != nil {
		r.actual.ClearCache()
	}
}
func (r *NetworkResolver) ResetConnection() {
	if r.actual != nil {
		r.actual.ResetConnection()
	}
}
func (r *NetworkResolver) CaptureCache(id uint64) func() {
	if r == nil || r.owner.ID != id || r.actual == nil {
		return nil
	}
	return r.actual.ClearCache
}

type rawDNSClient struct {
	owner   DNSOwner
	network string
}

func (c *rawDNSClient) Address() string  { return "android://" + c.network }
func (c *rawDNSClient) ResetConnection() {}
func (c *rawDNSClient) ExchangeContext(ctx context.Context, m *D.Msg) (*D.Msg, error) {
	if c.owner.Revoked != nil && c.owner.Revoked.Err() != nil {
		return nil, c.owner.stopped()
	}
	wire, err := m.Pack()
	if err != nil {
		return nil, err
	}
	child, cancel := context.WithCancel(ctx)
	defer cancel()
	if c.owner.Revoked != nil {
		stop := context.AfterFunc(c.owner.Revoked, cancel)
		defer stop()
	}
	response, callErr := c.owner.RawQuery(child, wire)
	if len(response) == 0 {
		if callErr == nil {
			callErr = errors.New("Android rawQuery returned no DNS message")
		}
		return nil, callErr
	}
	message := new(D.Msg)
	if err := message.Unpack(response); err != nil {
		return nil, errors.Join(callErr, err)
	}
	return message, callErr
}

// CheckSystemDNS only checks the combination of Private DNS and the upstream standalone system client; it does not change resolution results.
func CheckSystemDNS(c *config.DNS, network NetworkDNS) (bool, error) {
	if !c.Enable {
		return false, nil
	}
	used := false
	check := func(field string, values []dns.NameServer) error {
		for _, value := range values {
			if value.Net != "system" {
				continue
			}
			used = true
			if network.Private() {
				return &PlatformError{Field: field, Reason: "privateDnsUnavailable"}
			}
		}
		return nil
	}
	for _, list := range []struct {
		field  string
		values []dns.NameServer
	}{
		{"dns.nameserver", c.NameServer}, {"dns.fallback", c.Fallback}, {"dns.default-nameserver", c.DefaultNameserver},
		{"dns.proxy-server-nameserver", c.ProxyServerNameserver}, {"dns.direct-nameserver", c.DirectNameServer},
	} {
		if err := check(list.field, list.values); err != nil {
			return used, err
		}
	}
	for _, policies := range []struct {
		field  string
		values []dns.Policy
	}{
		{"dns.nameserver-policy", c.NameServerPolicy}, {"dns.proxy-server-nameserver-policy", c.ProxyServerPolicy},
	} {
		for _, policy := range policies.values {
			if err := check(policies.field, policy.NameServers); err != nil {
				return used, err
			}
		}
	}
	return used, nil
}
