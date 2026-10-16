package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gofrs/uuid/v5"
	C "github.com/metacubex/mihomo/constant"
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
	rows    []*connectionFixture
	missing map[string]bool
}

func (s *connectionFixtures) Range(f func(statistic.Tracker) bool) {
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

func TestConnectionsBoundedSelectionAndPresence(t *testing.T) {
	source := &connectionFixtures{missing: map[string]bool{}}
	for i := 0; i < 2000; i++ {
		source.rows = append(source.rows, fixtureConnection(i))
	}
	inner := fixtureConnection(9999)
	inner.info.Metadata.Type = C.INNER
	source.rows = append(source.rows, inner)
	oldID := source.rows[0].ID()
	missingID := fixtureConnection(9998).ID()
	body, err := queryConnections(source, ConnectionQuery{Limit: 1000,
		PreviousActiveIDs: []string{oldID, missingID}, DetailID: source.rows[1].ID()})
	reply := decodeConnections(t, body, err)
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

func TestConnectionsStableTieAndDisappearingCandidate(t *testing.T) {
	a, b, c := fixtureConnection(1), fixtureConnection(2), fixtureConnection(3)
	b.info.Start, c.info.Start = a.info.Start, a.info.Start
	source := &connectionFixtures{rows: []*connectionFixture{c, b, a}, missing: map[string]bool{a.ID(): true}}
	body, err := queryConnections(source, ConnectionQuery{Limit: 2, PreviousActiveIDs: []string{a.ID()}})
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
	body, err := projectConnection(row.ID(), row.info)
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
