package engine

import (
	"context"
	"flag"
	"net/netip"
	"os"
	"os/exec"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"
	"time"

	C "github.com/metacubex/mihomo/constant"
)

func wireguardWorkers() int {
	buffer := make([]byte, 4<<20)
	n := runtime.Stack(buffer, true)
	return strings.Count(string(buffer[:n]), "/device.(*Device).RoutineEncryption(")
}

func TestParseFailureClosesAllocatedNodes(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	// Run unrecoverable allocation regressions in an isolated process.
	if os.Getenv("CLASH_PSEUDO_PARSE_FAILURE_CHILD") != "1" {
		command := exec.Command(os.Args[0], "-test.run=^TestParseFailureClosesAllocatedNodes$", "-test.v")
		if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
			command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
		}
		command.Env = append(os.Environ(), "CLASH_PSEUDO_PARSE_FAILURE_CHILD=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("parse-failure subprocess: %v\n%s", err, output)
		}
		return
	}
	// Observe explicit cleanup before garbage collection.
	debug.SetGCPercent(-1)
	const body = `mode: rule
proxies:
  - name: wg-node
    type: wireguard
    server: 127.0.0.1
    port: 9
    ip: 10.0.0.2
    workers: 1
    private-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
rules:
  - NOT-A-VALID-RULE,invalid
`
	baseline := wireguardWorkers()
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err == nil {
		requireStop(t, &e)
		t.Fatal("invalid rule was accepted")
	}
	stopErr := e.Stop()
	if got := wireguardWorkers(); got != baseline {
		t.Fatalf("parse failure leaked WireGuard workers = %d, baseline = %d; Stop = %v", got, baseline, stopErr)
	}
}

func TestStopClosesProviderNodes(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	const body = `mode: rule
proxy-providers:
  wg:
    type: inline
    payload:
      - name: wg-node
        type: wireguard
        server: 127.0.0.1
        port: 9
        ip: 10.0.0.2
        workers: 1
        private-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
        public-key: AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
    health-check:
      enable: false
rules:
  - MATCH,DIRECT
`
	baseline := wireguardWorkers()
	var e Engine
	t.Cleanup(func() { requireStop(t, &e) })
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	nodes := e.cfg.Providers["wg"].Proxies()
	if len(nodes) != 1 {
		t.Fatal("missing provider node")
	}
	// Retain the node through the explicit-close assertion, then release it on both
	// success and failure.
	t.Cleanup(func() { _ = nodes[0].Close() })
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	packet, err := nodes[0].ListenPacketContext(ctx, &C.Metadata{
		NetWork: C.UDP, DstIP: netip.MustParseAddr("192.0.2.1"), DstPort: 53,
	})
	cancel()
	if err != nil {
		t.Fatal("initialize provider through public UDP use:", err)
	}
	t.Cleanup(func() { _ = packet.Close() })
	deadline := time.Now().Add(2 * time.Second)
	for wireguardWorkers() <= baseline && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if wireguardWorkers() <= baseline {
		t.Fatal("provider worker never started")
	}
	requireStop(t, &e)
	requireStop(t, &e)
	deadline = time.Now().Add(2 * time.Second)
	for wireguardWorkers() > baseline && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := wireguardWorkers(); got != baseline {
		t.Fatalf("workers after Stop = %d, baseline = %d", got, baseline)
	}
	runtime.KeepAlive(nodes)
}

func TestInlineRuleProviderStopsAndNewEngineCanPrepare(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		runEnginePhase(t, home, "first")
		runEnginePhase(t, home, "replacement")
		return
	}
	body := []byte("rule-providers:\n inline:\n  type: inline\n  behavior: classical\n  payload: ['DOMAIN,example.test']\nrules:\n - RULE-SET,inline,DIRECT\n - MATCH,DIRECT\n")
	var e Engine
	if err := e.Prepare(home, body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	requireStop(t, &e)
	if e.failed || e.cfg != nil || e.owner != nil {
		t.Fatal("inline provider left an unconfirmed session")
	}
}
