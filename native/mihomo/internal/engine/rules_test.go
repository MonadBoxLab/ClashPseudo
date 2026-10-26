package engine

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

func readRulePage(t *testing.T, e *Engine, query RuleQuery) RulePage {
	t.Helper()
	value, err := e.Rules(query)
	if err != nil {
		t.Fatal(err)
	}
	var page RulePage
	if err := json.Unmarshal([]byte(value), &page); err != nil {
		t.Fatal(err)
	}
	return page
}

func TestRulesExposeMainSubrulesAndAllProviderBehaviors(t *testing.T) {
	var e Engine
	body := []byte(`rule-providers:
 domains:
  type: inline
  behavior: domain
  payload: ['+.example.test', exact.test]
 networks:
  type: inline
  behavior: ipcidr
  payload: [192.0.2.0/24, '2001:db8::/32']
 classical:
  type: inline
  behavior: classical
  payload: ['DOMAIN-SUFFIX,example.test', 'NETWORK,UDP']
sub-rules:
 branch:
  - DOMAIN,sub.test,DIRECT
rules:
 - RULE-SET,domains,DIRECT
 - MATCH,DIRECT
`)
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	main := readRulePage(t, &e, RuleQuery{Kind: "main", Limit: 1})
	if main.Total != 2 || main.NextOffset != 1 || len(main.Scopes) != 5 || main.Rows[0].Index != 1 || main.Rows[0].Providers[0] != "domains" {
		t.Fatalf("unexpected main page: %+v", main)
	}
	next := readRulePage(t, &e, RuleQuery{Kind: "main", Limit: 1, Offset: 1, Token: main.Token})
	if next.Rows[0].Index != 2 || next.NextOffset != -1 {
		t.Fatal(next)
	}
	sub := readRulePage(t, &e, RuleQuery{Kind: "sub", Name: "branch", Limit: 100})
	if sub.Rows[0].Payload != "sub.test" || sub.Rows[0].Target != "DIRECT" {
		t.Fatal(sub)
	}
	for _, name := range []string{"domains", "networks", "classical"} {
		page := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: name, Limit: 100})
		if page.Total != 2 {
			t.Fatalf("%s: %+v", name, page)
		}
		origin := "normalized-rules"
		if name == "classical" {
			origin = "inline-source"
		}
		if page.Origin != origin {
			t.Fatal(page.Origin)
		}
	}
	filtered := readRulePage(t, &e, RuleQuery{Kind: "main", Limit: 100, Search: "match"})
	if filtered.Total != 1 || filtered.Rows[0].Index != 2 {
		t.Fatal(filtered)
	}
	if len(main.SourceToken) != 64 || next.SourceToken != main.SourceToken || filtered.SourceToken != main.SourceToken || filtered.Token == main.Token || sub.SourceToken == main.SourceToken {
		t.Fatal("rule source identity must survive search and paging while remaining scope-specific")
	}
	if _, err := e.Rules(RuleQuery{Kind: "main", Limit: 1, Offset: 1, Token: strings.Repeat("x", 64)}); err == nil {
		t.Fatal("changed token accepted")
	}
}

func TestRulesExpandFileMrsThroughPublicDump(t *testing.T) {
	for _, behavior := range []P.RuleBehavior{P.Domain, P.IPCIDR} {
		t.Run(behavior.String(), func(t *testing.T) {
			home := t.TempDir()
			text := []byte("+.example.test\nexact.test\n")
			if behavior == P.IPCIDR {
				text = []byte("192.0.2.0/24\n2001:db8::/32\n")
			}
			var mrs bytes.Buffer
			if err := RP.ConvertToMrs(text, behavior, P.TextRule, &mrs); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(home, "fixture.mrs"), mrs.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			body := []byte("rule-providers:\n fixture:\n  type: file\n  behavior: " + strings.ToLower(behavior.String()) + "\n  format: mrs\n  path: fixture.mrs\nrules:\n - RULE-SET,fixture,DIRECT\n - MATCH,DIRECT\n")
			var e Engine
			if err := e.Prepare(home, body, "rule", nil, func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			page := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "fixture", Limit: 100})
			if page.Total != 2 || page.Origin != "normalized-rules" {
				t.Fatal(page)
			}
		})
	}
}

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
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("rules: ['MATCH,DIRECT']\n"), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
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
			e.cfg.Rules = []C.Rule{ruleProjectionFixture{kind: fixture.kind, payload: fixture.payload}}
			value, err := e.Rules(RuleQuery{Kind: "main", Limit: 1})
			if err != nil {
				t.Fatal(err)
			}
			var page struct {
				Rows []struct {
					Resources []string `json:"resources"`
				} `json:"rows"`
			}
			if err := json.Unmarshal([]byte(value), &page); err != nil {
				t.Fatal(err)
			}
			got := strings.Join(page.Rows[0].Resources, ",")
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

// Run each host sub-benchmark in a fresh process with benchtime=1x. Report RSS
// high-water including input construction and query heap samples every 1ms separately.
func BenchmarkRulesFirstPage(b *testing.B) {
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
							// Sparse addresses prevent CIDR merging from reducing this
							// large input to a handful of contiguous prefixes.
							strategy.Insert(fmt.Sprintf("2001:db8::%x:%x/128", index>>15, (index&0x7fff)*2))
						}
					}
					strategy.FinishInsert()
					owner := &socketOwner{}
					owner.active.Store(true)
					e := &Engine{owner: owner, cfg: &config.Config{RuleProviders: map[string]P.RuleProvider{
						"large": diagnosticDumpProvider{behavior: behavior, strategy: strategy},
					}}}
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
					var value string
					var err error
					for index := 0; index < b.N; index++ {
						value, err = e.Rules(RuleQuery{Kind: "provider", Name: "large", Limit: 100})
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
					var page RulePage
					if err := json.Unmarshal([]byte(value), &page); err != nil || page.Total != count || len(page.Rows) != 100 || page.NextOffset != 100 {
						b.Fatalf("large first page total=%d rows=%d next=%d err=%v", page.Total, len(page.Rows), page.NextOffset, err)
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

type classicalFixture struct {
	P.RuleProvider
	vehicle P.Vehicle
}

func (p classicalFixture) VehicleType() P.VehicleType { return P.File }
func (p classicalFixture) Vehicle() P.Vehicle         { return p.vehicle }

func TestClassicalFallbackRejectsCacheArrivalDuringReading(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.txt")
	provider := classicalFixture{vehicle: resource.NewFileVehicle(path)}
	_, err := classicalSource(provider, ruleSource{Payload: []string{"DOMAIN,fallback.test"}}, func(string) error {
		return os.WriteFile(path, []byte("DOMAIN,new-cache.test\n"), 0600)
	})
	if err != RuleReadError("sourceChanged") {
		t.Fatalf("cache appeared during fallback read without invalidation: %v", err)
	}
}

func TestRulesEmptyProviderNameRemainsAnExactScope(t *testing.T) {
	var e Engine
	body := []byte("rule-providers:\n '': {type: inline, behavior: classical, payload: ['DOMAIN,empty-provider.test']}\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	page := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "", Limit: 1})
	if page.Origin != "inline-source" || page.Total != 1 || len(page.Rows) != 1 || page.Rows[0].Payload != "DOMAIN,empty-provider.test" {
		t.Fatalf("empty-name provider read as main scope: %+v", page)
	}
}

func TestRulesClassicalPaginationRejectsOriginAndUnseenRowChanges(t *testing.T) {
	home := t.TempDir()
	path := filepath.Join(home, "rules.txt")
	original := []byte("DOMAIN,one.test\nDOMAIN,two.test\n")
	if err := os.WriteFile(path, original, 0600); err != nil {
		t.Fatal(err)
	}
	var e Engine
	body := []byte("rule-providers:\n fixture:\n  type: file\n  behavior: classical\n  format: text\n  path: rules.txt\n  payload: ['DOMAIN,one.test', 'DOMAIN,two.test']\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(home, body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	first := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "fixture", Limit: 1})
	if first.Origin != "cache-source" || first.Total != 2 || first.NextOffset != 1 || first.Rows[0].Index != 1 {
		t.Fatalf("initial cache page: %+v", first)
	}
	// A row outside the retained first page still belongs to its token.
	if err := os.WriteFile(path, []byte("DOMAIN,one.test\nDOMAIN,changed.test\n"), 0600); err != nil {
		t.Fatal(err)
	}
	query := RuleQuery{Kind: "provider", Name: "fixture", Limit: 1, Offset: 1, Token: first.Token}
	if _, err := e.Rules(query); err != RuleReadError("sourceChanged") {
		t.Fatalf("unseen source row change accepted: %v", err)
	}
	changed := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "fixture", Limit: 1})
	if changed.SourceToken == first.SourceToken {
		t.Fatal("an unseen source row change retained the detail identity")
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	// Expire the cache page when provenance changes, even with identical row contents.
	fallback := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "fixture", Limit: 1})
	if fallback.Origin != "configuration-fallback-source" || fallback.Total != 2 || fallback.Token == first.Token || fallback.SourceToken == first.SourceToken {
		t.Fatalf("fallback origin not part of pagination identity: %+v", fallback)
	}
	if _, err := e.Rules(query); err != RuleReadError("sourceChanged") {
		t.Fatalf("cache token accepted for fallback: %v", err)
	}
	query.Token = fallback.Token
	next := readRulePage(t, &e, query)
	if next.Rows[0].Index != 2 || next.Rows[0].Payload != "DOMAIN,two.test" || next.NextOffset != -1 {
		t.Fatalf("fallback continuation: %+v", next)
	}
	filtered := readRulePage(t, &e, RuleQuery{Kind: "provider", Name: "fixture", Limit: 1, Search: "two.test"})
	if filtered.Total != 1 || filtered.Rows[0].Index != 2 || filtered.NextOffset != -1 {
		t.Fatalf("filtered source count/index: %+v", filtered)
	}
}

func TestClassicalSourceDistinguishesCacheFallbackAndConcurrentChanges(t *testing.T) {
	path := filepath.Join(t.TempDir(), "rules.txt")
	provider := classicalFixture{vehicle: resource.NewFileVehicle(path)}
	var entries []string
	emit := func(value string) error { entries = append(entries, value); return nil }
	origin, err := classicalSource(provider, ruleSource{Payload: []string{"DOMAIN,fallback.test"}}, emit)
	if err != nil || origin != "configuration-fallback-source" || len(entries) != 1 {
		t.Fatal(origin, err, entries)
	}
	for _, fixture := range []struct{ format, body string }{
		{"text", "# comment\n// comment\nDOMAIN,one.test\nDOMAIN,two.test\n"},
		{"yaml", "payload:\n - DOMAIN,one.test\n - DOMAIN,two.test\n"},
	} {
		if err := os.WriteFile(path, []byte(fixture.body), 0600); err != nil {
			t.Fatal(err)
		}
		entries = nil
		origin, err = classicalSource(provider, ruleSource{Format: fixture.format}, emit)
		if err != nil || origin != "cache-source" || len(entries) != 2 {
			t.Fatal(origin, err, entries)
		}
	}
	changed := false
	_, err = classicalSource(provider, ruleSource{Format: "yaml"}, func(string) error {
		if !changed {
			changed = true
			return os.WriteFile(path, []byte("payload: []\n"), 0600)
		}
		return nil
	})
	if err == nil {
		t.Fatal("concurrent cache change accepted")
	}
	if err := os.WriteFile(path, []byte("payload: ["), 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := classicalSource(provider, ruleSource{Payload: []string{"DOMAIN,fallback.test"}}, emit); err == nil {
		t.Fatal("invalid cache silently replaced by fallback")
	}
}
