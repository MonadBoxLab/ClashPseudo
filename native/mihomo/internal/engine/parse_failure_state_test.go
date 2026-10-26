package engine

import (
	"encoding/json"
	"errors"
	"testing"

	"github.com/metacubex/mihomo/component/dialer"
)

func TestPartialParseDoesNotClaimCleanupOrAllowReuse(t *testing.T) {
	for _, fixture := range []struct {
		name         string
		body         string
		afterRestart bool
	}{
		{"fresh", "rules: [NOT-A-RULE,invalid]\n", false},
		{"after-reusable-decode-failure", "rules:\n  - UNKNOWN,invalid\n", true},
	} {
		t.Run(fixture.name, func(t *testing.T) {
			var e Engine
			home := t.TempDir()
			if fixture.afterRestart {
				// Exercise decode failure, restart and parse failure consecutively on the same
				// Engine.
				if err := e.Prepare(home, []byte("[invalid yaml"), "rule", nil, func(int) bool { return true }); err == nil {
					t.Fatal("malformed YAML accepted")
				}
				if current.Load() != nil || e.owner != nil {
					t.Fatal("failed prepare retained protector")
				}
				requireStop(t, &e)
				if err := e.Prepare(home, []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				requireStop(t, &e)
			}
			if err := e.Prepare(home, []byte(fixture.body), "rule", nil, func(int) bool { return true }); err == nil {
				t.Fatal("invalid rules accepted")
			}
			// After parse-stage ownership loss, retain the uncertain state and reject sockets
			// and reuse.
			for range 2 {
				if current.Load() != nil || e.owner != nil {
					t.Fatal("failed prepare retained protector")
				}
				if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); !errors.Is(err, ErrStopped) {
					t.Fatalf("parse failure accepted a socket: %v", err)
				}
				if err := e.Stop(); err == nil {
					t.Fatal("partial parse cleanup was reported as confirmed")
				}
				var snapshot struct {
					Prepared      bool `json:"prepared"`
					CleanupFailed bool `json:"cleanupFailed"`
				}
				if err := json.Unmarshal([]byte(e.Snapshot()), &snapshot); err != nil {
					t.Fatal(err)
				}
				if snapshot.Prepared || !snapshot.CleanupFailed {
					t.Fatalf("unconfirmed parse cleanup lost: %+v", snapshot)
				}
				if err := e.Prepare(home, []byte(validConfig), "rule", nil, func(int) bool { return true }); err == nil {
					t.Fatal("engine with unconfirmed cleanup reused")
				}
			}
		})
	}
}

func TestDecodeFailureBeforeAllocationRemainsReusable(t *testing.T) {
	for _, body := range []string{"dns: [", "[invalid yaml"} {
		t.Run(body, func(t *testing.T) {
			var e Engine
			home := t.TempDir()
			if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err == nil {
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
			if err := e.Prepare(home, []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			requireStop(t, &e)
		})
	}
}
