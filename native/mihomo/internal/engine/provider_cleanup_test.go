package engine

import (
	"runtime"
	"strings"
	"testing"
	"time"
)

func wireguardWorkers() int {
	buffer := make([]byte, 4<<20)
	n := runtime.Stack(buffer, true)
	return strings.Count(string(buffer[:n]), "/device.(*Device).RoutineEncryption(")
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
		if err := e.Prepare(t.TempDir(), []byte(body), func(int) bool { return true }); err != nil {
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
