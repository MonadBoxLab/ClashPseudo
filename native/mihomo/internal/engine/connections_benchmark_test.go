package engine

import (
	"fmt"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

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
				if _, err := queryConnections(source, nil, q); err != nil {
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
