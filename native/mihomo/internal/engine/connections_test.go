package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gofrs/uuid/v5"
	"github.com/metacubex/mihomo/component/fakeip"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

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

func TestConnectionRuleSuggestionsFitLongestDomainInRowBudget(t *testing.T) {
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
	if len(body) > maxConnectionRowBytes || value == nil || value.Host == nil || *value.Host != host || value.SuffixBoundary == nil || *value.SuffixBoundary != "a.a" || value.IPCIDR == nil || *value.IPCIDR != "2001:db8::7/128" {
		t.Fatal("complete domain and PSL boundary must fit the existing row budget", string(body))
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
	body, err := queryConnections(source, nil, ConnectionQuery{Limit: 1})
	value := decodeConnections(t, body, err)
	var row connectionRow
	if err := json.Unmarshal(value.Connections[0], &row); err != nil {
		t.Fatal(err)
	}
	if row.RuleSuggestions == nil || row.RuleSuggestions.Host == nil || *row.RuleSuggestions.Host != "unrelated.example.test" || row.RuleSuggestions.ConnectionID != latest.ID() {
		t.Fatal("ordinary observation lost its complete rule metadata", row)
	}
	body, err = queryConnections(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	value = decodeConnections(t, body, err)
	if err := json.Unmarshal(value.Detail, &row); err != nil {
		t.Fatal(err)
	}
	suggestions := row.RuleSuggestions
	if suggestions == nil || suggestions.Host == nil || suggestions.IPCIDR == nil || suggestions.ConnectionID != first.ID() || *suggestions.Host != "a.tenant.github.io" || *suggestions.IPCIDR != "192.0.2.7/32" {
		t.Fatal("detail suggestions came from another tracker", suggestions)
	}
	source.missing[first.ID()] = true
	body, err = queryConnections(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	if value := decodeConnections(t, body, err); value.Detail != nil || value.Presence[first.ID()] {
		t.Fatal("closed tracker was observed as current")
	}
	delete(source.missing, first.ID())
	first.info.Metadata.Type = C.INNER
	body, err = queryConnections(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	if value := decodeConnections(t, body, err); value.Detail != nil || value.Presence[first.ID()] {
		t.Fatal("internal tracker offered a rule")
	}
	first.info.Metadata.Type = C.TUN
	first.info.Metadata.Host = strings.Repeat("a.", 600) + "example.test"
	body, err = queryConnections(source, nil, ConnectionQuery{Limit: 1, DetailID: first.ID()})
	value = decodeConnections(t, body, err)
	if err := json.Unmarshal(value.Detail, &row); err != nil {
		t.Fatal(err)
	}
	if !row.Truncated || row.Metadata.Host == "" || row.RuleSuggestions == nil || row.RuleSuggestions.Host != nil || row.RuleSuggestions.SuffixBoundary != nil {
		t.Fatal("truncated display host was used as a complete rule name", row.RuleSuggestions)
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
	body, err := queryConnections(source, nil, ConnectionQuery{Limit: 1000,
		PreviousActiveIDs: []string{oldID, missingID}, DetailID: source.rows[1].ID()})
	reply := decodeConnections(t, body, err)
	if reply.ActiveCount != 2000 || reply.UploadTotal != 9000000 || reply.DownloadTotal != 17000000 {
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
	if first.ID != source.rows[1999].ID() || last.ID != source.rows[1000].ID() {
		t.Fatal("not the latest connections")
	}
	if len(body) > maxConnectionResponse {
		t.Fatal("response exceeds limit")
	}
}

func TestConnectionsEmptyGlobalSummary(t *testing.T) {
	source := &connectionFixtures{upload: 12345}
	body, err := queryConnections(source, nil, ConnectionQuery{Limit: 1})
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
	body, err := queryConnections(source, nil, ConnectionQuery{Limit: 2, PreviousActiveIDs: []string{a.ID()}})
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

func TestConnectionProjectionBoundsTextBeforeEncoding(t *testing.T) {
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
	var result connectionRow
	if err := json.Unmarshal(body, &result); err != nil {
		t.Fatal(err)
	}
	if len(body) > maxConnectionRowBytes || !result.Truncated || len(result.Chains) > 16 ||
		result.ID != row.ID() || !utf8.ValidString(result.Metadata.Host) {
		t.Fatal("field budget or exact identity lost")
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
	if q.validate() == nil {
		t.Fatal("duplicate ID accepted")
	}
	q.PreviousActiveIDs = make([]string, 1001)
	if q.validate() == nil {
		t.Fatal("unbounded watch set accepted")
	}
}

func TestCloseConnectionDoesNotConvertCloseErrorToSuccess(t *testing.T) {
	row := fixtureConnection(1)
	source := &connectionFixtures{rows: []*connectionFixture{row}, missing: map[string]bool{}}
	row.closeError = errors.New("private endpoint error")
	row.onClose = func() { source.missing[row.ID()] = true }
	if status, err := closeConnection(source, row.ID()); err == nil || status != "" || strings.Contains(err.Error(), "private") {
		t.Fatal("close error was hidden or leaked")
	}
	if status, err := closeConnection(source, row.ID()); err != nil || status != "absent" {
		t.Fatal("absence is not a second successful close")
	}
	if row.closed != 1 {
		t.Fatal("closed twice")
	}
}

func TestConnectionEngineAvailabilityAndSingleClose(t *testing.T) {
	var e Engine
	q := ConnectionQuery{Limit: 1000}
	if _, err := e.Connections(q); err == nil {
		t.Fatal("stopped query accepted")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if _, err := e.Connections(q); err == nil {
		t.Fatal("preview query accepted")
	}
	closer := &countedCloser{}
	e.tun = closer
	a, b := fixtureConnection(1), fixtureConnection(2)
	a.onClose = func() { statistic.DefaultManager.Leave(a) }
	b.onClose = func() { statistic.DefaultManager.Leave(b) }
	statistic.DefaultManager.Join(a)
	statistic.DefaultManager.Join(b)
	if status, err := e.CloseConnection(a.ID()); err != nil || status != "closed" {
		t.Fatal(status, err)
	}
	if b.closed != 0 || closer.calls != 0 || !e.available() {
		t.Fatal("single close disturbed other resources")
	}
	b.info.Metadata.Type = C.INNER
	if _, err := e.CloseConnection(b.ID()); err == nil {
		t.Fatal("Inner closed")
	}
	if _, err := e.CloseConnection("invalid"); err == nil {
		t.Fatal("invalid ID accepted")
	}
	if strings.Contains(e.Snapshot(), "connections") {
		t.Fatal("summary retained full connection data")
	}
	e.Cancel()
	if _, err := e.CloseConnection(b.ID()); err == nil {
		t.Fatal("cancelled close accepted")
	}
}
