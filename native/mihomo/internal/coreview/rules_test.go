package coreview

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

type ruleProjectionFixture struct {
	C.Rule
	kind    C.RuleType
	payload string
}

func (r ruleProjectionFixture) RuleType() C.RuleType    { return r.kind }
func (r ruleProjectionFixture) Payload() string         { return r.payload }
func (r ruleProjectionFixture) Adapter() string         { return "DIRECT" }
func (r ruleProjectionFixture) ProviderNames() []string { return nil }

func TestRulesProjectOnlyPublicDirectGeoReferences(t *testing.T) {
	cfg := &config.Config{}
	originalMode := geodata.GeodataMode()
	defer geodata.SetGeodataMode(originalMode)
	for _, mode := range []bool{false, true} {
		geodata.SetGeodataMode(mode)
		geoIP := "MMDB"
		if mode {
			geoIP = "GeoIP"
		}
		for _, fixture := range []struct {
			kind    C.RuleType
			payload string
			want    string
		}{
			{C.GEOIP, "cn", geoIP}, {C.SrcGEOIP, "us", geoIP},
			{C.GEOSITE, "example", "GeoSite"},
			{C.IPASN, "64500", "ASN"}, {C.SrcIPASN, "64501", "ASN"},
			{C.GEOIP, "LAN", ""}, {C.SrcGEOIP, "lan", ""},
			{C.Domain, "geosite.example", ""},
			{C.AND, "((GEOIP,cn),(GEOSITE,example))", ""},
		} {
			cfg.Rules = []C.Rule{ruleProjectionFixture{kind: fixture.kind, payload: fixture.payload}}
			var rows []RuleRow
			_, err := StreamRules(cfg, nil, RuleQuery{Kind: "main"}, func(value any) error { rows = append(rows, value.(RuleRow)); return nil })
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 1 {
				t.Fatal("actual rules were not exported one at a time")
			}
			got := strings.Join(rows[0].Resources, ",")
			if got != fixture.want {
				t.Errorf("mode=%t type=%v payload=%q resource=%q want=%q", mode, fixture.kind, fixture.payload, got, fixture.want)
			}
		}
	}
}

type diagnosticDumpStrategy interface {
	Reset()
	Insert(string)
	FinishInsert()
	Count() int
	DumpMrs(func(string) bool)
}

type diagnosticDumpProvider struct {
	P.RuleProvider
	behavior P.RuleBehavior
	strategy diagnosticDumpStrategy
}

func (p diagnosticDumpProvider) Behavior() P.RuleBehavior { return p.behavior }
func (p diagnosticDumpProvider) Count() int               { return p.strategy.Count() }
func (p diagnosticDumpProvider) Strategy() any            { return p.strategy }

// Each benchmark runs in a separate process with benchtime=1x; RSS includes input construction, and query heap usage is sampled every 1 ms.
func BenchmarkRulesStream(b *testing.B) {
	for _, behavior := range []P.RuleBehavior{P.Domain, P.IPCIDR} {
		b.Run(behavior.String(), func(b *testing.B) {
			for _, count := range []int{100000, 1000000} {
				b.Run(strconv.Itoa(count), func(b *testing.B) {
					var strategy diagnosticDumpStrategy
					if behavior == P.Domain {
						strategy = RP.NewDomainStrategy()
					} else {
						strategy = RP.NewIPCidrStrategy()
					}
					strategy.Reset()
					for index := 0; index < count; index++ {
						if behavior == P.Domain {
							strategy.Insert(fmt.Sprintf("n%07d.fixture.test", index))
						} else {
							// Use sparse addresses so CIDR merging does not change the input count.
							strategy.Insert(fmt.Sprintf("2001:db8::%x:%x/128", index>>15, (index&0x7fff)*2))
						}
					}
					strategy.FinishInsert()
					cfg := &config.Config{RuleProviders: map[string]P.RuleProvider{
						"large": diagnosticDumpProvider{behavior: behavior, strategy: strategy},
					}}
					runtime.GC()
					var baseline runtime.MemStats
					runtime.ReadMemStats(&baseline)
					rssBefore, rssPeakBefore := diagnosticRSS()
					stop, peaks := make(chan struct{}), make(chan uint64, 1)
					go func() {
						ticker := time.NewTicker(time.Millisecond)
						defer ticker.Stop()
						peak := baseline.HeapAlloc
						for {
							var sample runtime.MemStats
							runtime.ReadMemStats(&sample)
							if sample.HeapAlloc > peak {
								peak = sample.HeapAlloc
							}
							select {
							case <-stop:
								peaks <- peak
								return
							case <-ticker.C:
							}
						}
					}()
					b.ReportAllocs()
					b.ResetTimer()
					var emitted int
					var err error
					for index := 0; index < b.N; index++ {
						emitted = 0
						_, err = StreamRules(cfg, nil, RuleQuery{Kind: "provider", Name: "large"}, func(any) error { emitted++; return nil })
						if err != nil {
							break
						}
					}
					b.StopTimer()
					close(stop)
					peakHeap := <-peaks
					_, rssPeakAfter := diagnosticRSS()
					b.ReportMetric(float64(peakHeap), "sampled_heap_peak_B")
					b.ReportMetric(float64(peakHeap-baseline.HeapAlloc), "sampled_heap_growth_B")
					b.ReportMetric(float64(rssBefore), "rss_before_B")
					b.ReportMetric(float64(rssPeakBefore), "rss_peak_before_B")
					b.ReportMetric(float64(rssPeakAfter), "rss_peak_after_B")
					if err != nil {
						b.Fatal(err)
					}
					if emitted != count {
						b.Fatalf("exported record count=%d, want %d", emitted, count)
					}
					runtime.KeepAlive(strategy)
				})
			}
		})
	}
}

func diagnosticRSS() (resident, peak uint64) {
	data, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return 0, 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		value, _ := strconv.ParseUint(fields[1], 10, 64)
		switch fields[0] {
		case "VmRSS:":
			resident = value * 1024
		case "VmHWM:":
			peak = value * 1024
		}
	}
	return resident, peak
}
