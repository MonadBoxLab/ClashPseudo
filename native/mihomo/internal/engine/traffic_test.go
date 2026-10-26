//go:build linux && !android

package engine

import (
	"encoding/json"
	"testing"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestVPNTrafficBaselinePrecedesFirstSampleAndSurvivesHotModeButNotReconnect(t *testing.T) {
	var e Engine
	home := t.TempDir()
	prepare := func(purpose string) {
		t.Helper()
		if err := e.PrepareWithOptions(home, []byte(validConfig), "", nil, func(int) bool { return true }, PrepareOptions{Purpose: purpose, Generation: 7, Composition: "traffic"}); err != nil {
			t.Fatal(err)
		}
	}
	statistic.DefaultManager.PushUploaded(71)
	statistic.DefaultManager.PushDownloaded(73)
	prepare("PREVIEW")
	if e.traffic != nil {
		t.Fatal("preview allocated a VPN baseline")
	}
	statistic.DefaultManager.PushUploaded(79)
	requireStop(t, &e)
	prepare("VPN")
	defer requireStop(t, &e)
	baseline := *e.traffic
	statistic.DefaultManager.PushUploaded(101)
	statistic.DefaultManager.PushDownloaded(103)
	if err := attachIngressFixture(t, &e); err != nil {
		t.Fatal(err)
	}
	wire, err := e.Connections(ConnectionQuery{Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	var response connectionReply
	if err := json.Unmarshal([]byte(wire), &response); err != nil || response.SessionUpload == nil || response.SessionDownload == nil || *response.SessionUpload != 101 || *response.SessionDownload != 103 {
		t.Fatalf("first production connection response lost session totals: %+v %v", response, err)
	}
	up, down := statistic.DefaultManager.Total()
	u, d := e.traffic.totals(up, down)
	if u == nil || d == nil || *u != 101 || *d != 103 {
		t.Fatalf("first sample lost pre-sampling bytes: %v %v", u, d)
	}
	if err := e.SetMode("direct"); err != nil {
		t.Fatal(err)
	}
	if *e.traffic != baseline {
		t.Fatal("hot mode reset baseline")
	}
	// Verify process-counter reads preserve cumulative values.
	if up < baseline.upload+101 || down < baseline.download+103 {
		t.Fatal("process totals were reset")
	}
	requireStop(t, &e)
	if e.traffic != nil {
		t.Fatal("stopped lease retained totals")
	}
	prepare("VPN")
	up, down = statistic.DefaultManager.Total()
	u, d = e.traffic.totals(up, down)
	if u == nil || d == nil || *u != 0 || *d != 0 {
		t.Fatal("real reconnect inherited previous lease totals")
	}
	for _, values := range [][2]int64{{-1, down}, {up, -1}, {up - 1, down}, {up, down - 1}} {
		if u, d := e.traffic.totals(values[0], values[1]); u != nil || d != nil {
			t.Fatal("invalid/rolled-back counter became zero")
		}
	}
}
