package engine

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"clashpseudo/native/internal/coreview"
	"github.com/gofrs/uuid/v5"
	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

type closingConnectionFixture struct {
	C.Connection
	info       *statistic.TrackerInfo
	closeError error
	onClose    func()
	closed     int
}

func (c *closingConnectionFixture) ID() string                   { return c.info.UUID.String() }
func (c *closingConnectionFixture) Info() *statistic.TrackerInfo { return c.info }
func (c *closingConnectionFixture) Close() error {
	c.closed++
	if c.onClose != nil {
		c.onClose()
	}
	return c.closeError
}
func fixtureClosingConnection(index int) *closingConnectionFixture {
	id := uuid.Must(uuid.FromString(fmt.Sprintf("%08x-0000-4000-8000-000000000000", index+1)))
	return &closingConnectionFixture{info: &statistic.TrackerInfo{
		UUID: id, Start: time.Unix(int64(index), 0), Metadata: &C.Metadata{Type: C.TUN},
	}}
}

type closingConnectionFixtures struct {
	rows             []*closingConnectionFixture
	missing          map[string]bool
	upload, download int64
	ranges           int
}

func (s *closingConnectionFixtures) Get(id string) statistic.Tracker {
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
func TestCloseConnectionDoesNotConvertCloseErrorToSuccess(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	row := fixtureClosingConnection(1)
	source := &closingConnectionFixtures{rows: []*closingConnectionFixture{row}, missing: map[string]bool{}}
	row.closeError = errors.New("private endpoint error")
	row.onClose = func() { source.missing[row.ID()] = true }
	if status, err := closeConnection(source, row.ID()); err != row.closeError || status != "" {
		t.Fatal("underlying close error changed", err)
	}
	if status, err := closeConnection(source, row.ID()); err != nil || status != "absent" {
		t.Fatal("absence is not a second successful close")
	}
	if row.closed != 1 {
		t.Fatal("closed twice")
	}
}

func TestConnectionEngineAvailabilityAndSingleClose(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}

	for _, purpose := range []string{"PREVIEW", "RUNNING"} {
		t.Run(fmt.Sprint(purpose), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			q := coreview.ConnectionQuery{Limit: 1000}
			if _, err := e.Connections(q); err == nil {
				t.Fatal("stopped query accepted")
			}
			options := PrepareOptions{Purpose: purpose, LANIntent: purpose == "RUNNING", Generation: 1, Composition: "connections"}
			if err := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }, options); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			if purpose == "PREVIEW" {
				if _, err := e.Connections(q); err == nil {
					t.Fatal("preview query accepted")
				}
				return
			}
			closer := &countedCloser{}
			e.tun = closer
			a, b := fixtureClosingConnection(1), fixtureClosingConnection(2)
			a.onClose = func() { statistic.DefaultManager.Leave(a) }
			b.onClose = func() { statistic.DefaultManager.Leave(b) }
			statistic.DefaultManager.Join(a)
			statistic.DefaultManager.Join(b)
			if _, err := e.CloseConnection("one"); err == nil {
				t.Fatal("invalid ID must not be accepted while trackers are active")
			}
			if a.closed != 0 || b.closed != 0 || closer.calls != 0 || !e.available() {
				t.Fatal("invalid ID changed active connections or TUN state")
			}
			if statistic.DefaultManager.Get(a.ID()) != a || statistic.DefaultManager.Get(b.ID()) != b {
				t.Fatal("invalid ID removed an active tracker")
			}
			if status, err := e.CloseConnection(a.ID()); err != nil || status != "closed" {
				t.Fatal(status, err)
			}
			if a.closed != 1 || statistic.DefaultManager.Get(a.ID()) != nil || statistic.DefaultManager.Get(b.ID()) != b {
				t.Fatal("valid ID must close and remove only the specified tracker, exactly once")
			}
			if b.closed != 0 || closer.calls != 0 || !e.available() {
				t.Fatal("single close disturbed other resources")
			}
			b.info.Metadata.Type = C.INNER
			if status, err := e.CloseConnection(b.ID()); err != nil || status != "closed" || b.closed != 1 || closer.calls != 0 || !e.available() {
				t.Fatal("internal tracker close changed ownership", status, err)
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

		})
	}
}
