package engine

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/tunnel"

	"clashpseudo/native/internal/configinput"
)

type countedCloser struct{ calls int }

func (c *countedCloser) Close() error { c.calls++; return nil }

func TestModeOverrideAndLifecycle(t *testing.T) {
	for _, body := range []string{validConfig, strings.ReplaceAll(validConfig, "mode: rule\n", ""), strings.ReplaceAll(validConfig, "mode: rule", "mode: direct")} {
		var e Engine
		if err := e.PrepareWithOptions(t.TempDir(), []byte(body), "", nil, func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", RoutingOverride: "global"}); err != nil {
			t.Fatal(err)
		}
		closer := &countedCloser{}
		e.tun = closer
		cfg, owner := e.cfg, e.owner
		if got := e.Mode(); got != "global" {
			t.Fatal(got)
		}
		for _, mode := range []string{"direct", "rule", "global"} {
			if err := e.SetMode(mode); err != nil {
				t.Fatal(err)
			}
			if e.Mode() != mode || e.cfg.General.Mode.String() != mode {
				t.Fatal("mode not applied")
			}
		}
		if err := e.SetMode("follow"); err == nil || e.Mode() != "global" {
			t.Fatal("invalid mode changed core")
		}
		if closer.calls != 0 || e.cfg != cfg || e.owner != owner {
			t.Fatal("mode change replaced session")
		}
		// Read mode directly from the live tunnel.
		tunnel.SetMode(tunnel.Direct)
		if e.Mode() != "direct" {
			t.Fatal("cached mode returned")
		}
		e.Cancel()
		if e.Mode() != "" || e.SetMode("rule") == nil {
			t.Fatal("cancelled session accepted mode")
		}
		requireStop(t, &e)
		if closer.calls != 1 || e.Mode() != "" || e.SetMode("rule") == nil {
			t.Fatal("stopped session retained mode")
		}
	}
}

func TestModePriorityIncludesComposedExplicitFallbackAndCurrentOperation(t *testing.T) {
	for _, tc := range []struct{ name, body, fallback, operation, override, want string }{
		{"explicit", "mode: direct\n", "global", "", "", "direct"},
		{"saved-fallback", "{}\n", "global", "", "", "global"},
		{"no-fallback", "{}\n", "", "", "", "rule"},
		{"explicit-rule-is-not-missing", "mode: rule\n", "direct", "", "", "rule"},
		{"current-operation", "mode: direct\n", "rule", "global", "", "global"},
		{"plugin-explicit", "mode: direct\n", "rule", "", "mode: global\n", "global"},
		{"operation-over-plugin", "mode: direct\n", "rule", "direct", "mode: global\n", "direct"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var e Engine
			var overrides []configinput.Override
			if tc.override != "" {
				overrides = []configinput.Override{{ID: "fragment", Revision: 1, Mode: "replace", Body: tc.override}}
			}
			if err := e.PrepareWithOptions(t.TempDir(), []byte(tc.body), tc.fallback, nil, func(int) bool { return true }, PrepareOptions{Purpose: "PREVIEW", RoutingOverride: tc.operation}, overrides...); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			if e.Mode() != tc.want || e.cfg.General.Mode.String() != tc.want || readStrategies(t, &e).Mode != tc.want {
				t.Fatalf("effective/strategy mode mismatch: %s %+v", e.Mode(), readStrategies(t, &e))
			}
			if err := e.SetMode("global"); err != nil {
				t.Fatal(err)
			}
			if readStrategies(t, &e).Mode != "global" {
				t.Fatal("strategy snapshot used raw/fallback mode instead of actual mode")
			}
		})
	}
}

func TestInvalidPrepareModeDoesNotClaimSession(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "follow", nil, func(int) bool { return true }); err == nil {
		t.Fatal("invalid mode accepted")
	}
	if e.owner != nil || current.Load() != nil {
		t.Fatal("invalid mode claimed core")
	}
}

// Expose the selected upstream mode race under -race using DNSDialer with RULES on
// loopback.
func TestModeConcurrentRouting(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var accepted sync.WaitGroup
	accepted.Add(1)
	go func() {
		defer accepted.Done()
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			conn.Close()
		}
	}()
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	dial := tunnel.NewDNSDialer(nil, nil, tunnel.DnsRespectRules)
	var routes sync.WaitGroup
	routes.Add(1)
	go func() {
		defer routes.Done()
		for i := 0; i < 100; i++ {
			conn, err := dial.DialContext(ctx, "tcp", listener.Addr().String())
			if err != nil {
				t.Error(err)
				return
			}
			conn.Close()
		}
	}()
	for i := 0; i < 1000; i++ {
		mode := "rule"
		if i%2 == 0 {
			mode = "direct"
		}
		if err := e.SetMode(mode); err != nil {
			t.Error(err)
			break
		}
	}
	routes.Wait()
	listener.Close()
	accepted.Wait()
}
