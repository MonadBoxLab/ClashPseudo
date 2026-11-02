//go:build linux && !android

package engine

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/metacubex/mihomo/tunnel/statistic"

	"clashpseudo/native/internal/coreview"
)

func TestTrafficBaselinePreservesUnknownZeroAndIndependentCounters(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, test := range []struct {
		name             string
		base             *trafficBaseline
		up, down         int64
		wantUp, wantDown int64
		known            bool
	}{
		{name: "no accepted VPN lease", up: 90, down: 100},
		{name: "negative upload baseline", base: &trafficBaseline{-1, 0}, up: 90, down: 100},
		{name: "negative download baseline", base: &trafficBaseline{0, -1}, up: 90, down: 100},
		{name: "upload rollback", base: &trafficBaseline{91, 100}, up: 90, down: 100},
		{name: "download rollback", base: &trafficBaseline{90, 101}, up: 90, down: 100},
		{name: "accepted zero", base: &trafficBaseline{90, 100}, up: 90, down: 100, known: true},
		{name: "upload only", base: &trafficBaseline{90, 100}, up: 190, down: 100, wantUp: 100, known: true},
		{name: "download only", base: &trafficBaseline{90, 100}, up: 90, down: 300, wantDown: 200, known: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			up, down := test.base.totals(test.up, test.down)
			if !test.known {
				if up != nil || down != nil {
					t.Fatal("unknown counters were fabricated as totals")
				}
				return
			}
			if up == nil || down == nil || *up != test.wantUp || *down != test.wantDown {
				t.Fatalf("totals = %v/%v, want %d/%d", up, down, test.wantUp, test.wantDown)
			}
			// Reading a snapshot must not move the lease baseline.
			againUp, againDown := test.base.totals(test.up, test.down)
			if *againUp != *up || *againDown != *down {
				t.Fatal("reading totals changed the baseline")
			}
		})
	}
}

func TestVPNTrafficBaselinePrecedesFirstSampleAndSurvivesHotModeButNotReconnect(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		for _, stage := range []string{"preview", "running", "reconnect"} {
			runEnginePhase(t, home, stage)
		}
		return
	}
	statistic.DefaultManager.PushUploaded(71)
	statistic.DefaultManager.PushDownloaded(73)
	purpose := "RUNNING"
	if phase == "preview" {
		purpose = "PREVIEW"
	}
	var e Engine
	if err := e.PrepareWithOptions(home, []byte(validConfig), "", func(int) bool { return true }, PrepareOptions{Purpose: purpose, VPNIntent: purpose == "RUNNING", Generation: 7, Composition: "traffic"}); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if phase == "preview" {
		if e.traffic != nil {
			t.Fatal("preview allocated a VPN baseline")
		}
		statistic.DefaultManager.PushUploaded(79)
		return
	}
	baseline := *e.traffic
	if phase == "running" {
		statistic.DefaultManager.PushUploaded(101)
		statistic.DefaultManager.PushDownloaded(103)
		if err := attachIngressFixture(t, &e); err != nil {
			t.Fatal(err)
		}
		wire, err := e.Connections(coreview.ConnectionQuery{Limit: 1})
		if err != nil {
			t.Fatal(err)
		}
		var response struct {
			SessionUpload   *int64 `json:"sessionUploadBytes"`
			SessionDownload *int64 `json:"sessionDownloadBytes"`
		}
		if err := json.Unmarshal([]byte(wire), &response); err != nil || response.SessionUpload == nil || response.SessionDownload == nil || *response.SessionUpload != 101 || *response.SessionDownload != 103 {
			t.Fatalf("first production connection response lost session totals: %+v %v", response, err)
		}
		up, down := statistic.DefaultManager.Total()
		u, d := e.traffic.totals(up, down)
		if u == nil || d == nil || *u != 101 || *d != 103 {
			t.Fatal("first sample lost pre-sampling bytes", u, d)
		}
		if err := e.SetMode("direct"); err != nil {
			t.Fatal(err)
		}
		if *e.traffic != baseline {
			t.Fatal("hot mode reset baseline")
		}
		if up < baseline.upload+101 || down < baseline.download+103 {
			t.Fatal("process totals were reset")
		}
		requireStop(t, &e)
		if e.traffic != nil {
			t.Fatal("stopped lease retained totals")
		}
		return
	}
	up, down := statistic.DefaultManager.Total()
	u, d := e.traffic.totals(up, down)
	if u == nil || d == nil || *u != 0 || *d != 0 {
		t.Fatal("real reconnect inherited previous lease totals")
	}
	for _, values := range [][2]int64{{-1, down}, {up, -1}, {up - 1, down}, {up, down - 1}} {
		if u, d := e.traffic.totals(values[0], values[1]); u != nil || d != nil {
			t.Fatal("invalid/rolled-back counter became zero")
		}
	}
}
