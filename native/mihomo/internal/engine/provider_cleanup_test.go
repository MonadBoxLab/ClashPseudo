package engine

import (
	"os"
	"os/exec"
	"runtime"
	"runtime/debug"
	"strings"
	"testing"
	"time"
)

func wireguardWorkers() int {
	buffer := make([]byte, 4<<20)
	n := runtime.Stack(buffer, true)
	return strings.Count(string(buffer[:n]), "/device.(*Device).RoutineEncryption(")
}

func TestParseFailureClosesAllocatedNodes(t *testing.T) {
	// Isolate unrecoverable allocations so this regression cannot contaminate
	// subsequent worker-count tests, even when upstream cleanup is missing.
	if os.Getenv("CLASH_PSEUDO_PARSE_FAILURE_CHILD") != "1" {
		command := exec.Command(os.Args[0], "-test.run=^TestParseFailureClosesAllocatedNodes$", "-test.v")
		command.Env = append(os.Environ(), "CLASH_PSEUDO_PARSE_FAILURE_CHILD=1")
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("parse-failure subprocess: %v\n%s", err, output)
		}
		return
	}
	// Explicit cleanup must not depend on a later garbage collection cycle.
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
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err == nil {
		requireStop(t, &e)
		t.Fatal("invalid rule was accepted")
	}
	requireStop(t, &e)
	// Allow both newly scheduled workers and asynchronous shutdown to settle.
	time.Sleep(2 * time.Second)
	if got := wireguardWorkers(); got != baseline {
		t.Fatalf("parse failed and Stop returned success, but WireGuard workers = %d, baseline = %d", got, baseline)
	}
}

func TestStopClosesProviderNodes(t *testing.T) {
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
	for round := 0; round < 3; round++ {
		if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		nodes := e.cfg.Providers["wg"].Proxies()
		if len(nodes) != 1 {
			t.Fatal("missing provider node")
		}
		// Retain the node so GC cannot conceal an omitted explicit close. Also
		// release it if the regression fails, to avoid contaminating other tests.
		t.Cleanup(func() { _ = nodes[0].Close() })
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
			t.Fatalf("round %d: workers after Stop = %d, baseline = %d", round, got, baseline)
		}
		runtime.KeepAlive(nodes)
	}
}
