package engine

import (
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
)

func TestParseFailureKeepsTheErrorAndRequiresANewEngine(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, fixture := range []struct {
		name, body   string
		afterRestart bool
	}{
		{"fresh", "rules: [NOT-A-RULE,invalid]\n", false},
		{"after-decode-failure", "rules:\n - UNKNOWN,invalid\n", true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
			if phase == "" {
				home = t.TempDir()
				if fixture.afterRestart {
					runEnginePhase(t, home, "decode")
					requireFreshEngineProcess(t, home)
				}
				for i := 0; i < 2; i++ {
					runEnginePhase(t, home, "parse")
					requireFreshEngineProcess(t, home)
				}
				return
			}
			var e Engine
			body := fixture.body
			if phase == "decode" {
				body = "[invalid yaml"
			}
			err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true })
			if err == nil {
				t.Fatal("invalid configuration accepted")
			}
			if phase == "parse" && !strings.Contains(err.Error(), "invalid") {
				t.Fatalf("original rule error lost: %v", err)
			}
			if current.Load() != nil || e.owner != nil || e.cfg != nil {
				t.Fatal("failed prepare retained a session")
			}
			if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); !errors.Is(err, ErrStopped) {
				t.Fatalf("parse failure accepted a socket: %v", err)
			}
			if err := e.Stop(); err != nil {
				t.Fatalf("parser rejection was treated as a cleanup failure: %v", err)
			}
			var snapshot struct {
				Prepared      bool `json:"prepared"`
				CleanupFailed bool `json:"cleanupFailed"`
			}
			if err := json.Unmarshal([]byte(e.Snapshot()), &snapshot); err != nil {
				t.Fatal(err)
			}
			if snapshot.Prepared || snapshot.CleanupFailed {
				t.Fatalf("parser rejection poisoned the engine: %+v", snapshot)
			}
			if err := e.Prepare(home, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
				t.Fatal("same Engine loaded again after parsing failed")
			}
		})
	}
}

func TestDecodeFailureBeforeAllocationStillConsumesTheEngine(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, body := range []string{"dns: [", "[invalid yaml"} {
		t.Run(body, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			home := t.TempDir()
			if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err == nil {
				t.Fatal("malformed YAML accepted")
			}
			if current.Load() != nil || e.owner != nil {
				t.Fatal("failed prepare retained protector")
			}
			if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); !errors.Is(err, ErrStopped) {
				t.Fatalf("decode failure accepted a socket: %v", err)
			}
			if err := e.Stop(); err != nil {
				t.Fatalf("decode failure should not poison the engine: %v", err)
			}
			var snapshot struct {
				Prepared      bool `json:"prepared"`
				CleanupFailed bool `json:"cleanupFailed"`
			}
			if err := json.Unmarshal([]byte(e.Snapshot()), &snapshot); err != nil {
				t.Fatal(err)
			}
			if snapshot.Prepared || snapshot.CleanupFailed {
				t.Fatalf("decode failure poisoned the engine: %+v", snapshot)
			}
			if err := e.Prepare(home, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
				t.Fatal("same Engine loaded again after decoding failed")
			}
			requireFreshEngineProcess(t, home)
			requireStop(t, &e)
		})
	}
}
