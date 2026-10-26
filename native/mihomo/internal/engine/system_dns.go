package engine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"

	"github.com/metacubex/mihomo/adapter/outbound"
	C "github.com/metacubex/mihomo/constant"

	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/dns"
	D "github.com/miekg/dns"
)

// Snapshot the underlying non-VPN Android network and honor strict Private DNS
// transport.
type NetworkDNS struct {
	ID         string   `json:"id"`
	Servers    []string `json:"servers"`
	PrivateDNS string   `json:"privateDns"`
}

type resolverSnapshot struct {
	key      string
	resolver resolver.Resolver
	ctx      context.Context
	cancel   context.CancelFunc
	reason   error
	owner    *socketOwner
}

type networkResolver struct {
	value atomic.Pointer[resolverSnapshot]
	mu    sync.Mutex
}

var systemDNS networkResolver

func init() { resolver.SystemResolver = &systemDNS }

func (e *Engine) UpdateNetwork(network NetworkDNS) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return `{"changed":false,"requiresRestart":false}`
	}
	changed := systemDNS.update(network)
	if changed {
		e.networkEpoch.Add(1)
		e.CancelDNSQuery()
	}
	restart := network.key() != e.options.Network.key() && (e.usesSystemDNS || (e.spec != nil && e.spec.UsesSystemDNS))
	if changed && !restart {
		e.options.Network = network
	}
	value, _ := json.Marshal(map[string]bool{"changed": changed, "requiresRestart": restart})
	return string(value)
}

func (n NetworkDNS) addresses() ([]dns.NameServer, error) {
	if n.PrivateDNS == "strict" {
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
			result = append(result, dns.NameServer{Net: "udp", Addr: net.JoinHostPort(addr.String(), "53")})
			seen[addr] = true
		}
	}
	return result, nil
}

func (n NetworkDNS) key() string {
	servers := slices.Clone(n.Servers)
	slices.Sort(servers)
	return n.ID + "|" + n.PrivateDNS + "|" + strings.Join(slices.Compact(servers), ",")
}

// Supply snapshot-bound sockets to the public DNS resolver.
type networkDNSAdapter struct {
	*outbound.Base
	owner   *socketOwner
	network string
}

func newNetworkDNSAdapter(network string) *networkDNSAdapter {
	return &networkDNSAdapter{Base: outbound.NewBase(outbound.BaseOption{Name: "SYSTEM-DNS", Type: C.Direct, UDP: true}), owner: current.Load(), network: network}
}
func (a *networkDNSAdapter) control(_, _ string, raw syscall.RawConn) error {
	owner := a.owner
	if owner == nil || current.Load() != owner || !owner.active.Load() {
		return ErrStopped
	}
	var refused error
	err := raw.Control(func(fd uintptr) {
		if !owner.active.Load() || current.Load() != owner {
			refused = ErrStopped
			return
		}
		accepted := false
		if owner.protectNetwork != nil {
			accepted = owner.protectNetwork(int(fd), a.network)
		} else {
			accepted = owner.protect(int(fd))
		}
		if !accepted {
			owner.refused.Add(1)
			refused = errors.New("snapshot-bound system DNS socket protection was refused")
		} else {
			owner.accepted.Add(1)
		}
	})
	return errors.Join(err, refused)
}
func (a *networkDNSAdapter) DialContext(ctx context.Context, metadata *C.Metadata) (C.Conn, error) {
	if !metadata.Resolved() {
		return nil, errors.New("system DNS transport requires a literal underlying address")
	}
	dialer := net.Dialer{Control: a.control}
	conn, err := dialer.DialContext(ctx, "tcp", metadata.AddrPort().String())
	if err != nil {
		return nil, err
	}
	return outbound.NewConn(conn, a), nil
}
func (a *networkDNSAdapter) ListenPacketContext(ctx context.Context, metadata *C.Metadata) (C.PacketConn, error) {
	if !metadata.Resolved() {
		return nil, errors.New("system DNS transport requires a literal underlying address")
	}
	network, address := "udp4", "0.0.0.0:0"
	if metadata.DstIP.Is6() {
		network, address = "udp6", "[::]:0"
	}
	config := net.ListenConfig{Control: a.control}
	packet, err := config.ListenPacket(ctx, network, address)
	if err != nil {
		return nil, err
	}
	return outbound.NewPacketConn(packet, a), nil
}

func (n NetworkDNS) boundAddresses() ([]dns.NameServer, error) {
	servers, err := n.addresses()
	if err != nil {
		return nil, err
	}
	adapter := newNetworkDNSAdapter(n.ID)
	for i := range servers {
		servers[i].ProxyAdapter = adapter
	}
	return servers, nil
}

func (s *networkResolver) update(network NetworkDNS) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := network.key()
	owner := current.Load()
	if old := s.value.Load(); old != nil && old.key == key && old.owner == owner {
		return false
	}
	servers, err := network.boundAddresses()
	ctx, cancel := context.WithCancel(context.Background())
	next := &resolverSnapshot{key: key, ctx: ctx, cancel: cancel, reason: err, owner: owner}
	if err == nil {
		next.resolver = dns.NewResolver(dns.Config{Main: servers, Default: servers, IPv6: true, IPv6Timeout: 100})
	}
	old := s.value.Swap(next)
	if old != nil {
		old.cancel()
		if old.resolver != nil {
			old.resolver.ResetConnection()
		}
	}
	return true
}

func (s *networkResolver) query(ctx context.Context) (*resolverSnapshot, context.Context, func(), error) {
	value := s.value.Load()
	if value == nil {
		return nil, nil, nil, &PlatformError{Field: "system-dns", Reason: "systemDnsUnavailable"}
	}
	if value.owner != nil && (current.Load() != value.owner || !value.owner.active.Load()) {
		return nil, nil, nil, ErrStopped
	}
	if value.reason != nil {
		return nil, nil, nil, value.reason
	}
	child, cancel := context.WithCancel(ctx)
	stop := context.AfterFunc(value.ctx, cancel)
	return value, child, func() { stop(); cancel() }, nil
}
func (s *networkResolver) fresh(value *resolverSnapshot, err error) error {
	if s.value.Load() != value || value.ctx.Err() != nil ||
		(value.owner != nil && (current.Load() != value.owner || !value.owner.active.Load())) {
		return errors.New("system DNS result belongs to an obsolete network snapshot")
	}
	return err
}
func (s *networkResolver) LookupIP(ctx context.Context, host string) ([]netip.Addr, error) {
	v, ctx, done, err := s.query(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	ips, err := v.resolver.LookupIP(ctx, host)
	if err = s.fresh(v, err); err != nil {
		return nil, err
	}
	return ips, nil
}
func (s *networkResolver) LookupIPv4(ctx context.Context, host string) ([]netip.Addr, error) {
	v, ctx, done, err := s.query(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	ips, err := v.resolver.LookupIPv4(ctx, host)
	if err = s.fresh(v, err); err != nil {
		return nil, err
	}
	return ips, nil
}
func (s *networkResolver) LookupIPv6(ctx context.Context, host string) ([]netip.Addr, error) {
	v, ctx, done, err := s.query(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	ips, err := v.resolver.LookupIPv6(ctx, host)
	if err = s.fresh(v, err); err != nil {
		return nil, err
	}
	return ips, nil
}
func (s *networkResolver) ResolveECH(ctx context.Context, host string) ([]byte, error) {
	v, ctx, done, err := s.query(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	data, err := v.resolver.ResolveECH(ctx, host)
	if err = s.fresh(v, err); err != nil {
		return nil, err
	}
	return data, nil
}
func (s *networkResolver) ExchangeContext(ctx context.Context, message *D.Msg) (*D.Msg, error) {
	v, ctx, done, err := s.query(ctx)
	if err != nil {
		return nil, err
	}
	defer done()
	result, err := v.resolver.ExchangeContext(ctx, message)
	if err = s.fresh(v, err); err != nil {
		return nil, err
	}
	return result, nil
}
func (s *networkResolver) Invalid() bool {
	v := s.value.Load()
	return v != nil && v.reason == nil && v.resolver != nil && v.ctx.Err() == nil &&
		(v.owner == nil || (current.Load() == v.owner && v.owner.active.Load())) && v.resolver.Invalid()
}
func (s *networkResolver) ClearCache() {
	if v := s.value.Load(); v != nil && v.resolver != nil {
		v.resolver.ClearCache()
	}
}
func (s *networkResolver) ResetConnection() {
	if v := s.value.Load(); v != nil && v.resolver != nil {
		v.resolver.ResetConnection()
	}
}

// systemClient reads an unsynchronized upstream global slice. Expand every
// explicit system source into this preparation's immutable network instead of
// calling dns.UpdateSystemDNS or assuming SystemResolver replaces that client.
func expandSystemDNS(c *config.DNS, network NetworkDNS) (bool, error) {
	used := false
	expand := func(input []dns.NameServer) ([]dns.NameServer, error) {
		out := make([]dns.NameServer, 0, len(input))
		for _, ns := range input {
			if ns.Net != "system" {
				out = append(out, ns)
				continue
			}
			used = true
			servers, err := network.addresses()
			if err != nil {
				return nil, fmt.Errorf("explicit system nameserver: %w", err)
			}
			adapter := newNetworkDNSAdapter(network.ID)
			for _, address := range servers {
				item := ns
				item.Net, item.Addr = address.Net, address.Addr
				if item.ProxyAdapter == nil && item.ProxyName == "" {
					item.ProxyAdapter = adapter
				}
				out = append(out, item)
			}
		}
		return out, nil
	}
	for _, list := range []*[]dns.NameServer{&c.NameServer, &c.Fallback, &c.DefaultNameserver, &c.ProxyServerNameserver, &c.DirectNameServer} {
		value, err := expand(*list)
		if err != nil {
			return used, err
		}
		*list = value
	}
	for _, policies := range [][]dns.Policy{c.NameServerPolicy, c.ProxyServerPolicy} {
		for i := range policies {
			value, err := expand(policies[i].NameServers)
			if err != nil {
				return used, err
			}
			policies[i].NameServers = value
		}
	}
	return used, nil
}
