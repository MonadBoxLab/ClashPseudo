package coreview

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"io"
)

type connectionRow struct {
	ID       string `json:"id"`
	Metadata struct {
		Host string `json:"host"`
	} `json:"metadata"`
	Chains          []string                   `json:"chains"`
	Strategy        *connectionStrategy        `json:"strategy"`
	RuleSuggestions *connectionRuleSuggestions `json:"ruleSuggestions"`
}

type connectionFixture struct {
	C.Connection
	info       *statistic.TrackerInfo
	closeError error
	onClose    func()
	closed     int
}

func (c *connectionFixture) ID() string                   { return c.info.UUID.String() }
func (c *connectionFixture) Info() *statistic.TrackerInfo { return c.info }
func (c *connectionFixture) Close() error {
	c.closed++
	if c.onClose != nil {
		c.onClose()
	}
	return c.closeError
}
func fixtureConnection(index int) *connectionFixture {
	id := uuid.Must(uuid.FromString(fmt.Sprintf("%08x-0000-4000-8000-000000000000", index+1)))
	return &connectionFixture{info: &statistic.TrackerInfo{
		UUID: id, Start: time.Unix(int64(index), 0), Metadata: &C.Metadata{Type: C.TUN},
	}}
}

type connectionFixtures struct {
	rows             []*connectionFixture
	missing          map[string]bool
	upload, download int64
	ranges           int
}

func (s *connectionFixtures) Total() (int64, int64) { return s.upload, s.download }

func (s *connectionFixtures) Range(f func(statistic.Tracker) bool) {
	s.ranges++
	for _, row := range s.rows {
		if !f(row) {
			return
		}
	}
}
func (s *connectionFixtures) Get(id string) statistic.Tracker {
	if s.missing[id] {
		return nil
	}
	for _, row := range s.rows {
		if row.ID() == id {
			return row
		}
	}
	return nil
}
func decodeConnections(t *testing.T, body string, err error) connectionReply {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
	var reply connectionReply
	if err := json.Unmarshal([]byte(body), &reply); err != nil {
		t.Fatal(err)
	}
	return reply
}

func TestConnectionRuleSuggestionsUseIDNAAndPublicSuffixPrivateBoundaries(t *testing.T) {
	for _, test := range []struct {
		host, want, boundary string
	}{
		{"a.b.example.co.uk", "a.b.example.co.uk", "example.co.uk"},
		{"a.tenant.github.io", "a.tenant.github.io", "tenant.github.io"},
		{"a.tenant.blogspot.com", "a.tenant.blogspot.com", "tenant.blogspot.com"},
		{"a.www.ck", "a.www.ck", "www.ck"},
		{"WWW.例子.测试。", "www.xn--fsqu00a.xn--0zwm56d", "xn--fsqu00a.xn--0zwm56d"},
		{"co.uk", "co.uk", ""}, {"LOCALHOST", "localhost", ""},
	} {
		value := connectionSuggestions("observed", &C.Metadata{Host: test.host})
		if value == nil || value.Host == nil || *value.Host != test.want {
			t.Fatalf("%s: %+v", test.host, value)
		}
		if test.boundary == "" {
			if value.SuffixBoundary != nil {
				t.Fatal("exact-only name acquired a suffix boundary", value)
			}
		} else if value.SuffixBoundary == nil || *value.SuffixBoundary != test.boundary {
			t.Fatal("wrong PSL boundary", test.host, value)
		}
		if value.IPCIDR != nil {
			t.Fatal("a host suggestion invented an address")
		}
	}
	for _, host := range []string{"", ".", "a..test", "a.test..", "https://example.test", "example.test:443", "a.test/path", "a\n.test", "a\x00.test", "_srv._tcp.test", "192.0.2.7", "2001:db8::7", "a." + strings.Repeat("x", 64), strings.Repeat("x", 1025), "-bad.test"} {
		value := connectionSuggestions("observed", &C.Metadata{Host: host})
		if value == nil || value.Host != nil || value.SuffixBoundary != nil {
			t.Fatalf("invalid/incomplete/literal host suggested a rule: %q %+v", host, value)
		}
	}
}

func TestConnectionRuleSuggestionsKeepLongestDomain(t *testing.T) {
	row := fixtureConnection(1)
	host := strings.Repeat("a.", 126) + "a"
	row.info.Metadata.Host = host
	row.info.Metadata.DstIP = netip.MustParseAddr("2001:db8::7")
	body, err := projectConnection(nil, row.ID(), row.info)
	if err != nil {
		t.Fatal(err)
	}
	var projected connectionRow
	if err := json.Unmarshal(body, &projected); err != nil {
		t.Fatal(err)
	}
	value := projected.RuleSuggestions
	if value == nil || value.Host == nil || *value.Host != host || value.SuffixBoundary == nil || *value.SuffixBoundary != "a.a" || value.IPCIDR == nil || *value.IPCIDR != "2001:db8::7/128" {
		t.Fatal("complete domain and PSL boundary changed", string(body))
	}
}

func TestConnectionRuleSuggestionsUseOnlyObservedIPAndPublicFakeIPDetection(t *testing.T) {
	old := resolver.DefaultHostMapper
	defer func() { resolver.DefaultHostMapper = old }()
	pool, err := fakeip.New(fakeip.Options{IPNet: netip.MustParsePrefix("203.0.113.1/24"), Size: 10})
	if err != nil {
		t.Fatal(err)
	}
	resolver.DefaultHostMapper = dns.NewEnhancer(dns.EnhancerConfig{EnhancedMode: C.DNSFakeIP, FakeIPPool: pool})
	fake := pool.Lookup("custom-range.test")
	for _, test := range []struct {
		ip   netip.Addr
		want string
	}{
		{fake, ""}, {netip.MustParseAddr("198.18.0.4"), "198.18.0.4/32"},
		{netip.MustParseAddr("::ffff:192.0.2.7"), "192.0.2.7/32"},
		{netip.MustParseAddr("2001:db8::7"), "2001:db8::7/128"},
		{netip.MustParseAddr("fe80::7%wlan0"), ""}, {netip.IPv4Unspecified(), ""}, {netip.Addr{}, ""},
	} {
		value := connectionSuggestions("observed", &C.Metadata{DstIP: test.ip, Host: "real.example.test"})
		if test.want == "" {
			if value.IPCIDR != nil {
				t.Fatal("invalid/fake address was offered", test.ip, *value.IPCIDR)
			}
		} else if value.IPCIDR == nil || *value.IPCIDR != test.want {
			t.Fatal("observed address changed", test.ip, value)
		}
	}
	// Use actual tracker addresses and fake-IP classification.
	value := connectionSuggestions("observed", &C.Metadata{Host: "not-resolved.example.test"})
	if value.IPCIDR != nil {
		t.Fatal("address invented from host")
	}
}

func TestConnectionRuleSuggestionsFollowEachObservedRowAndDetail(t *testing.T) {
	first, latest := fixtureConnection(1), fixtureConnection(2)
	first.info.Metadata.Host = "a.tenant.github.io"
	first.info.Metadata.DstIP = netip.MustParseAddr("192.0.2.7")
	latest.info.Metadata.Host = "unrelated.example.test"
	source := &connectionFixtures{rows: []*connectionFixture{first, latest}, missing: map[string]bool{}}
	body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1})
	value := decodeConnections(t, body, err)
	var row connectionRow
	if err := json.Unmarshal(value.Connections[0], &row); err != nil {
		t.Fatal(err)
	}
	if row.RuleSuggestions == nil || row.RuleSuggestions.Host == nil || *row.RuleSuggestions.Host != "unrelated.example.test" || row.RuleSuggestions.ConnectionID != latest.ID() {
		t.Fatal("ordinary observation lost its complete rule metadata", row)
	}
	body, err = fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	value = decodeConnections(t, body, err)
	if err := json.Unmarshal(value.Detail, &row); err != nil {
		t.Fatal(err)
	}
	suggestions := row.RuleSuggestions
	if suggestions == nil || suggestions.Host == nil || suggestions.IPCIDR == nil || suggestions.ConnectionID != first.ID() || *suggestions.Host != "a.tenant.github.io" || *suggestions.IPCIDR != "192.0.2.7/32" {
		t.Fatal("detail suggestions came from another tracker", suggestions)
	}
	source.missing[first.ID()] = true
	body, err = fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	if value := decodeConnections(t, body, err); value.Detail != nil || value.Presence[first.ID()] {
		t.Fatal("closed tracker was observed as current")
	}
	delete(source.missing, first.ID())
	first.info.Metadata.Type = C.INNER
	body, err = fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	if value := decodeConnections(t, body, err); value.Detail == nil || !value.Presence[first.ID()] {
		t.Fatal("internal tracker was filtered out")
	}
	first.info.Metadata.Type = C.TUN
	first.info.Metadata.Host = strings.Repeat("a.", 600) + "example.test"
	body, err = fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	value = decodeConnections(t, body, err)
	if err := json.Unmarshal(value.Detail, &row); err != nil {
		t.Fatal(err)
	}
	if row.Metadata.Host != first.info.Metadata.Host || row.RuleSuggestions == nil || row.RuleSuggestions.Host != nil || row.RuleSuggestions.SuffixBoundary != nil {
		t.Fatal("invalid rule suggestion changed the raw host", row.RuleSuggestions)
	}
}

func TestConnectionsBoundedSelectionAndPresence(t *testing.T) {
	source := &connectionFixtures{missing: map[string]bool{}, upload: 9000000, download: 17000000}
	for i := 0; i < 2000; i++ {
		source.rows = append(source.rows, fixtureConnection(i))
	}
	inner := fixtureConnection(9999)
	inner.info.Metadata.Type = C.INNER
	source.rows = append(source.rows, inner)
	oldID := source.rows[0].ID()
	missingID := fixtureConnection(9998).ID()
	body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1000,
		PreviousActiveIDs: []string{oldID, missingID}, DetailID: source.rows[1].ID()})
	reply := decodeConnections(t, body, err)
	if reply.ActiveCount != 2001 || reply.UploadTotal != 9000000 || reply.DownloadTotal != 17000000 {
		t.Fatal("global summary was truncated or derived from selected rows")
	}
	if !reply.Complete || !reply.Limited || len(reply.Connections) != 1000 || reply.Detail == nil {
		t.Fatal("selection was not bounded")
	}
	if !reply.Presence[oldID] || reply.Presence[missingID] || len(reply.Presence) != 3 {
		t.Fatal("capacity exclusion was confused with disappearance")
	}
	var first, last connectionRow
	json.Unmarshal(reply.Connections[0], &first)
	json.Unmarshal(reply.Connections[999], &last)
	if first.ID != inner.ID() || last.ID != source.rows[1001].ID() || reply.Omitted != 1000 {
		t.Fatal("latest complete rows or omission count changed")
	}
	if len(body) > maxConnectionResponse {
		t.Fatal("response exceeds limit")
	}
}

func TestConnectionsEmptyGlobalSummary(t *testing.T) {
	source := &connectionFixtures{upload: 12345}
	body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1})
	reply := decodeConnections(t, body, err)
	if reply.ActiveCount != 0 || reply.UploadTotal != 12345 || reply.DownloadTotal != 0 || source.ranges != 1 {
		t.Fatal("empty connection table lost global counters or scanned twice")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(body), &fields); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"activeCount", "uploadTotal", "downloadTotal"} {
		if _, ok := fields[name]; !ok {
			t.Fatalf("missing %s", name)
		}
	}
}

func TestConnectionsStableTieAndDisappearingCandidate(t *testing.T) {
	a, b, c := fixtureConnection(1), fixtureConnection(2), fixtureConnection(3)
	b.info.Start, c.info.Start = a.info.Start, a.info.Start
	source := &connectionFixtures{rows: []*connectionFixture{c, b, a}, missing: map[string]bool{a.ID(): true}}
	body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 2, PreviousActiveIDs: []string{a.ID()}})
	reply := decodeConnections(t, body, err)
	if len(reply.Connections) != 1 || reply.Presence[a.ID()] {
		t.Fatal("candidate vanished but was still returned")
	}
	var row connectionRow
	json.Unmarshal(reply.Connections[0], &row)
	if row.ID != b.ID() {
		t.Fatal("tie order changed")
	}
}

func TestConnectionProjectionKeepsEveryPublicTrackerField(t *testing.T) {
	row := fixtureConnection(1)
	row.info.Metadata.Host = strings.Repeat("目标🌐\x00", 10000)
	row.info.RulePayload = strings.Repeat("\x01", 10000)
	row.info.Rule = "Domain"
	for i := 0; i < 100; i++ {
		row.info.Chain = append(row.info.Chain, strings.Repeat("节点🌐\x02", 1000))
	}
	body, err := projectConnection(nil, row.ID(), row.info)
	if err != nil {
		t.Fatal(err)
	}
	original, err := json.Marshal(row.info)
	if err != nil {
		t.Fatal(err)
	}
	var expected, actual map[string]any
	if err := json.Unmarshal(original, &expected); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &actual); err != nil {
		t.Fatal(err)
	}
	for key, value := range expected {
		if !reflect.DeepEqual(actual[key], value) {
			t.Errorf("public tracker field %s changed", key)
		}
	}
	var result connectionRow
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if result.ID != row.ID() || result.Metadata.Host != row.info.Metadata.Host || !reflect.DeepEqual(result.Chains, []string(row.info.Chain)) {
		t.Fatal("complete identity, metadata or chain changed")
	}
}

func TestConnectionsResponseBudgetIncludesEnvelopeAtExactBoundary(t *testing.T) {
	row := fixtureConnection(1)
	source := &connectionFixtures{rows: []*connectionFixture{row}, upload: 41, download: 97}
	q := ConnectionQuery{Limit: 1, PreviousActiveIDs: []string{row.ID()}, DetailID: row.ID()}
	body, err := fixtureConnectionQuery(source, nil, q)
	decodeConnections(t, body, err)
	row.info.RulePayload = strings.Repeat("x", maxConnectionResponse-len(body))
	body, err = fixtureConnectionQuery(source, nil, q)
	reply := decodeConnections(t, body, err)
	if len(body) != maxConnectionResponse || len(reply.Connections) != 1 || reply.Limited || reply.Omitted != 0 || !reply.Presence[row.ID()] {
		t.Fatalf("exact boundary: bytes=%d rows=%d limited=%v omitted=%d", len(body), len(reply.Connections), reply.Limited, reply.Omitted)
	}
	row.info.RulePayload += "x"
	body, err = fixtureConnectionQuery(source, nil, q)
	reply = decodeConnections(t, body, err)
	if len(body) > maxConnectionResponse || len(reply.Connections) != 0 || reply.Detail != nil || !reply.Limited || reply.Omitted != 1 || !reply.Presence[row.ID()] || reply.ActiveCount != 1 || reply.UploadTotal != 41 || reply.DownloadTotal != 97 {
		t.Fatal("oversized record was shortened, counted twice, or reported absent")
	}
	older := fixtureConnection(0)
	source.rows = append(source.rows, older)
	q.Limit = 2
	body, err = fixtureConnectionQuery(source, nil, q)
	reply = decodeConnections(t, body, err)
	if len(reply.Connections) != 1 || reply.Omitted != 1 || reply.ActiveCount != 2 || !reply.Presence[row.ID()] {
		t.Fatal("oversized latest row displaced a complete smaller row")
	}
	var selected connectionRow
	if err := json.Unmarshal(reply.Connections[0], &selected); err != nil || selected.ID != older.ID() {
		t.Fatal("wrong complete row selected", err)
	}
}

func TestConnectionsBudgetCountsEscapedUTF8AndPreservesPinnedDetail(t *testing.T) {
	for _, text := range []string{"\x00", "&", "🌐"} {
		t.Run(fmt.Sprintf("%x", text), func(t *testing.T) {
			large, small := fixtureConnection(2), fixtureConnection(1)
			encoded, err := json.Marshal(text)
			if err != nil {
				t.Fatal(err)
			}
			large.info.RulePayload = strings.Repeat(text, maxConnectionResponse/(len(encoded)-2)+1)
			source := &connectionFixtures{rows: []*connectionFixture{large, small}, upload: 123, download: 456}
			body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 2, DetailID: large.ID()})
			reply := decodeConnections(t, body, err)
			if len(body) > maxConnectionResponse || len(reply.Connections) != 1 || reply.Detail != nil || reply.Omitted != 1 || !reply.Presence[large.ID()] || !reply.Limited || reply.UploadTotal != 123 || reply.DownloadTotal != 456 {
				t.Fatal("encoded byte budget changed whole-row or presence semantics")
			}
		})
	}
	older, latest := fixtureConnection(1), fixtureConnection(2)
	older.info.RulePayload = strings.Repeat("x", maxConnectionResponse/2)
	latest.info.RulePayload = strings.Repeat("y", maxConnectionResponse/2)
	source := &connectionFixtures{rows: []*connectionFixture{older, latest}}
	body, err := fixtureConnectionQuery(source, nil, ConnectionQuery{Limit: 1, DetailID: older.ID()})
	reply := decodeConnections(t, body, err)
	if len(body) > maxConnectionResponse || reply.Detail == nil || len(reply.Connections) != 0 || !reply.Presence[older.ID()] || reply.Omitted != 1 || !reply.Limited {
		t.Fatal("combined envelope failed to retain the complete pinned detail")
	}
	var detail connectionRow
	if err := json.Unmarshal(reply.Detail, &detail); err != nil || detail.ID != older.ID() {
		t.Fatal("pinned detail changed", err)
	}
}

func TestConnectionQueryRejectsInvalidInputs(t *testing.T) {
	for _, body := range []string{
		`{}`, `{"limit":0}`, `{"limit":1001}`, `{"limit":1,"detailId":""`,
		`{"limit":1,"detailId":"not-an-id"}`, strings.Repeat(" ", MaxConnectionRequest+1),
	} {
		if _, err := DecodeConnectionQuery([]byte(body)); err == nil {
			t.Fatal("invalid query accepted")
		}
	}
	id := fixtureConnection(1).ID()
	q := ConnectionQuery{Limit: 1, PreviousActiveIDs: []string{id, id}}
	if q.Validate() == nil {
		t.Fatal("duplicate ID accepted")
	}
	q.PreviousActiveIDs = make([]string, 1001)
	if q.Validate() == nil {
		t.Fatal("unbounded watch set accepted")
	}
}

func fixtureConnectionQuery(source interface {
	ConnectionSource
	Total() (int64, int64)
}, proxies map[string]C.Proxy, query ConnectionQuery) (string, error) {
	upload, download := source.Total()
	return Connections(source, proxies, query, ConnectionTotals{Upload: upload, Download: download})
}

func connectionConfig(t *testing.T, body string) *config.Config {
	t.Helper()
	cfg, err := executor.ParseWithBytes([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, provider := range cfg.Providers {
			if closer, ok := provider.(io.Closer); ok {
				if err := closer.Close(); err != nil {
					t.Error(err)
				}
			}
		}
		for _, proxy := range cfg.Proxies {
			if err := proxy.Close(); err != nil {
				t.Error(err)
			}
		}
	})
	return cfg
}

func TestConnectionStrategyUsesFullExactChain(t *testing.T) {
	name := strings.Repeat("入口🌐", 80)
	config := "mixed-port: 0\nproxy-groups:\n  - name: '" + name + "'\n    type: select\n    hidden: true\n    icon: https://example.test/icon.svg?token=fixture\n    proxies: [DIRECT]\nrules: ['MATCH,DIRECT']\n"
	cfg := connectionConfig(t, config)
	fixture := fixtureConnection(1)
	fixture.info.Chain = append(fixture.info.Chain, "DIRECT")
	for i := 0; i < 30; i++ {
		fixture.info.Chain = append(fixture.info.Chain, "not-a-group")
	}
	fixture.info.Chain = append(fixture.info.Chain, name)
	body, err := projectConnection(cfg.Proxies, fixture.ID(), fixture.info)
	if err != nil {
		t.Fatal(err)
	}
	var row connectionRow
	if err := json.Unmarshal(body, &row); err != nil {
		t.Fatal(err)
	}
	if row.Strategy == nil || row.Strategy.Type != "select" || row.Strategy.Icon != "https://example.test/icon.svg?token=fixture" {
		t.Fatalf("exact entry group lost: %+v", row.Strategy)
	}
	if len(row.Chains) != len(fixture.info.Chain) || row.Chains[len(row.Chains)-1] != name {
		t.Fatal("complete chain changed")
	}
	observations, err := StrategyGroups(cfg)
	if err != nil {
		t.Fatal(err)
	}
	snapshot := ReadStrategies(cfg, "rule", nil, nil, observations)
	bodyText, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatal(err)
	}
	var groups Strategies
	if err := json.Unmarshal(bodyText, &groups); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, group := range groups.Groups {
		if group.Name == name {
			found = group.Icon == row.Strategy.Icon && group.Hidden
		}
	}
	if !found {
		t.Fatal("strategy icon or hidden metadata missing")
	}
	fixture.info.Chain = []string{"DIRECT", "GLOBAL"}
	body, err = projectConnection(cfg.Proxies, fixture.ID(), fixture.info)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &row); err != nil {
		t.Fatal(err)
	}
	if row.Strategy == nil || row.Strategy.Type != "select" {
		t.Fatal("GLOBAL not resolved as real group")
	}
}

func TestConnectionStrategyKeepsCompleteIconAddresses(t *testing.T) {
	for _, icon := range []string{
		"https://example.test/" + strings.Repeat("a", 1024),
		"https://example.test/" + strings.Repeat("&", 180),
	} {
		config := "mixed-port: 0\nproxy-groups:\n  - name: entry\n    type: select\n    icon: '" + icon + "'\n    proxies: [DIRECT]\nrules: ['MATCH,DIRECT']\n"
		cfg := connectionConfig(t, config)
		connection := fixtureConnection(3)
		connection.info.Chain = []string{"DIRECT", "entry"}
		body, err := projectConnection(cfg.Proxies, connection.ID(), connection.info)
		if err != nil {
			t.Fatal(err)
		}
		var row connectionRow
		if err := json.Unmarshal(body, &row); err != nil {
			t.Fatal(err)
		}
		if row.Strategy == nil || row.Strategy.Type != "select" || row.Strategy.Icon != icon {
			t.Fatal("complete icon address changed")
		}
	}
}

func TestConnectionStrategyFallbackDoesNotGuessNames(t *testing.T) {
	for _, fixture := range []struct{ chain, want string }{
		{"DIRECT", "Direct"}, {"REJECT", "Reject"}, {"REJECT-DROP", "Reject"}, {"node-DIRECT", ""},
	} {
		connection := fixtureConnection(2)
		connection.info.Chain = []string{fixture.chain}
		body, err := projectConnection(nil, connection.ID(), connection.info)
		if err != nil {
			t.Fatal(err)
		}
		var row connectionRow
		if err := json.Unmarshal(body, &row); err != nil {
			t.Fatal(err)
		}
		if fixture.want == "" {
			if row.Strategy != nil {
				t.Fatal("unknown name treated as type")
			}
		} else if row.Strategy == nil || row.Strategy.Type != fixture.want {
			t.Fatal("built-in fallback lost")
		}
	}
}

// Match the manager's indexed lookup instead of timing the test fixture's scan.
type benchmarkConnectionSource struct {
	*connectionFixtures
	byID map[string]statistic.Tracker
}

func (s *benchmarkConnectionSource) Get(id string) statistic.Tracker { return s.byID[id] }

func BenchmarkConnectionQuery(b *testing.B) {
	for _, count := range []int{50, 500, 1000, 2000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			source := &benchmarkConnectionSource{&connectionFixtures{}, make(map[string]statistic.Tracker, count)}
			q := ConnectionQuery{Limit: 1000}
			for i := 0; i < count; i++ {
				row := fixtureConnection(i)
				row.info.Metadata.Host = "fixture.test"
				source.rows = append(source.rows, row)
				source.byID[row.ID()] = row
				if i < 1000 {
					q.PreviousActiveIDs = append(q.PreviousActiveIDs, row.ID())
				}
			}
			b.ReportAllocs()
			b.ResetTimer()
			for b.Loop() {
				if _, err := fixtureConnectionQuery(source, nil, q); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkConnectionLongProjection(b *testing.B) {
	row := fixtureConnection(0)
	row.info.Metadata.Host = strings.Repeat("目标🌐", 1000)
	row.info.RulePayload = strings.Repeat("\x01", 10000)
	for i := 0; i < 100; i++ {
		row.info.Chain = append(row.info.Chain, strings.Repeat("节点🌐", 1000))
	}
	id := row.ID()
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		if _, err := projectConnection(nil, id, row.info); err != nil {
			b.Fatal(err)
		}
	}
}

func TestConnectionsPreserveAlreadyCalculatedSessionTotals(t *testing.T) {
	source := &connectionFixtures{upload: 99999, download: 88888}
	upload, download := int64(21), int64(34)
	body, err := Connections(source, nil, ConnectionQuery{Limit: 1}, ConnectionTotals{
		Upload: 900, Download: 1200, SessionUpload: &upload, SessionDownload: &download,
	})
	reply := decodeConnections(t, body, err)
	if reply.UploadTotal != 900 || reply.DownloadTotal != 1200 || reply.SessionUpload == nil || reply.SessionDownload == nil || *reply.SessionUpload != upload || *reply.SessionDownload != download {
		t.Fatal("projection replaced the captured totals or recalculated the session baseline", reply)
	}
	body, err = Connections(source, nil, ConnectionQuery{Limit: 1}, ConnectionTotals{Upload: 900, Download: 1200})
	reply = decodeConnections(t, body, err)
	if reply.SessionUpload != nil || reply.SessionDownload != nil {
		t.Fatal("missing session deltas acquired process totals", reply)
	}
}
