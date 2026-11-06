package engine

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"

	"clashpseudo/native/internal/configinput"
)

const validConfig = "mode: rule\nfind-process-mode: off\nrules:\n  - MATCH,DIRECT\n"

type signalTunnel struct {
	closed chan struct{}
}

func (s signalTunnel) Close() error {
	close(s.closed)
	return nil
}

type rawSocket struct{}

func (rawSocket) Control(f func(uintptr)) error  { f(42); return nil }
func (rawSocket) Read(func(uintptr) bool) error  { return nil }
func (rawSocket) Write(func(uintptr) bool) error { return nil }

// isolateEngineTest让每个装载测试使用独立的mihomo全局状态；父进程串行等待实际退出。
func isolateEngineTest(t *testing.T) bool {
	t.Helper()
	const key = "PSEUDO_ENGINE_TEST"
	selected := os.Getenv(key)
	if selected == t.Name() || strings.HasPrefix(selected, t.Name()+"/") {
		return false
	}
	runEngineProcess(t, key+"="+t.Name())
	return true
}

func runEngineProcess(t *testing.T, environment ...string) {
	t.Helper()
	runEngineProcessNamed(t, t.Name(), environment...)
}

func runEngineProcessNamed(t *testing.T, name string, environment ...string) {
	t.Helper()
	parts := strings.Split(name, "/")
	for i := range parts {
		parts[i] = "^" + regexp.QuoteMeta(parts[i]) + "$"
	}
	deadline := time.Now().Add(90 * time.Second)
	if end, ok := t.Deadline(); ok && end.Before(deadline) {
		deadline = end
	}
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	command := exec.CommandContext(ctx, os.Args[0], "-test.run="+strings.Join(parts, "/"), "-test.count=1", "-test.timeout="+time.Until(deadline).String())
	if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
		command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
	}
	replaced := map[string]bool{}
	for _, value := range environment {
		replaced[strings.SplitN(value, "=", 2)[0]] = true
	}
	for _, value := range os.Environ() {
		if !replaced[strings.SplitN(value, "=", 2)[0]] {
			command.Env = append(command.Env, value)
		}
	}
	command.Env = append(command.Env, environment...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("独立core测试失败: %v; context=%v\n%s", err, ctx.Err(), output)
	}
	t.Logf("独立core测试输出\n%s", output)
}

func runEnginePhase(t *testing.T, home, phase string, environment ...string) {
	t.Helper()
	runEngineProcess(t, append(environment, "PSEUDO_ENGINE_TEST="+t.Name(), "PSEUDO_ENGINE_HOME="+home, "PSEUDO_ENGINE_PHASE="+phase)...)
}

func requireFreshEngineProcess(t *testing.T, home string) {
	t.Helper()
	runEngineProcessNamed(t, "TestPrepareStopRestart", "PSEUDO_ENGINE_TEST=TestPrepareStopRestart", "PSEUDO_ENGINE_HOME="+home, "PSEUDO_ENGINE_PHASE=fresh")
}

func requireStop(t *testing.T, e *Engine) {
	t.Helper()
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestPrepareStopRestart(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		for i := 0; i < 3; i++ {
			runEnginePhase(t, home, fmt.Sprint(i))
		}
		return
	}
	{
		var e Engine
		if err := e.Prepare(home, []byte(validConfig), "rule", func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		if err := e.Prepare(home, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
			t.Fatal("duplicate prepare accepted")
		}
		var snapshot map[string]any
		if err := json.Unmarshal([]byte(e.Snapshot()), &snapshot); err != nil {
			t.Fatal(err)
		}
		if snapshot["prepared"] != true || snapshot["attached"] != false {
			t.Fatal(snapshot)
		}
		requireStop(t, &e)
		requireStop(t, &e)
		if err := e.Prepare(home, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
			t.Fatal("同一core context在Stop后重新装载")
		}
		if e.cfg != nil || e.owner != nil || current.Load() != nil {
			t.Fatal("session references retained")
		}
	}
}

func TestProtectAndCancellation(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	var accepted atomic.Bool
	accepted.Store(true)
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return accepted.Load() }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); err != nil {
		t.Fatal(err)
	}
	accepted.Store(false)
	if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); err == nil {
		t.Fatal("protect refusal ignored")
	}
	e.Cancel()
	if err := dialer.DefaultSocketHook("tcp", "unused", rawSocket{}); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
}

func TestUnknownResourceCannotReportSuccessfulClose(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	if err := closeResource(struct{}{}); err == nil {
		t.Fatal("resource without close was accepted")
	}
}

type failedCloser struct{}

func (failedCloser) Close() error { return errors.New("injected cleanup failure") }

func TestCleanupFailureCannotBecomeSuccess(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	e.tun = failedCloser{}
	for i := 0; i < 2; i++ {
		if err := e.Stop(); err == nil {
			t.Fatal("unconfirmed cleanup reported success")
		}
	}
	if !strings.Contains(e.Snapshot(), `"cleanupFailed":true`) {
		t.Fatal(e.Snapshot())
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
		t.Fatal("restart accepted after cleanup failure")
	}
}

func TestProviderStopsUpdating(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprintln(w, "proxies:\n  - {name: fixture, type: socks5, server: 127.0.0.1, port: 9}")
	}))
	defer server.Close()
	body := validConfig + fmt.Sprintf("proxy-providers:\n  fixture:\n    type: http\n    url: %s\n    path: ./provider.yaml\n    interval: 1\n    health-check: {enable: false}\n", server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	deadline := time.Now().Add(4 * time.Second)
	for requests.Load() < 2 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if requests.Load() < 2 {
		t.Fatal("provider never updated")
	}
	requireStop(t, &e)
	stoppedAt := requests.Load()
	time.Sleep(2200 * time.Millisecond)
	if requests.Load() != stoppedAt {
		t.Fatal("provider requested after stop")
	}
}

func TestStopCancelsInflightProviderUpdate(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var requests atomic.Int64
	started := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 1 {
			fmt.Fprintln(w, "proxies:\n  - {name: fixture, type: socks5, server: 127.0.0.1, port: 9}")
			return
		}
		close(started)
		select {
		case <-r.Context().Done():
			close(cancelled)
		case <-release:
		}
	}))
	defer server.Close()
	defer close(release)
	body := validConfig + fmt.Sprintf("proxy-providers:\n  fixture:\n    type: http\n    url: %s\n    path: ./provider.yaml\n    interval: 1\n    health-check: {enable: false}\n", server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, &e) })
	select {
	case <-started:
	case <-time.After(4 * time.Second):
		t.Fatal("provider update did not start")
	}
	requireStop(t, &e)
	select {
	case <-cancelled:
	case <-time.After(2 * time.Second):
		t.Fatal("in-flight provider request was not cancelled")
	}
}

func TestLateProviderResponseCannotReplaceNewContext(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home = t.TempDir()
		var requests atomic.Int64
		release := make(chan struct{})
		done := make(chan struct{})
		var once sync.Once
		defer once.Do(func() { close(release) })
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			name := "fresh"
			switch requests.Add(1) {
			case 1:
				name = "initial"
			case 2:
				if err := os.WriteFile(filepath.Join(home, "started"), []byte("started"), 0600); err != nil {
					t.Error(err)
					return
				}
				<-release
				name = "stale"
				defer func() {
					if err := os.WriteFile(filepath.Join(home, "served"), []byte("served"), 0600); err != nil {
						t.Error(err)
					}
				}()
			}
			fmt.Fprintf(w, "proxies:\n - {name: %s, type: direct}\n", name)
		}))
		defer func() { once.Do(func() { close(release) }); server.Close() }()
		go func() {
			defer close(done)
			ticker := time.NewTicker(time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-release:
					return
				case <-ticker.C:
					if _, err := os.Stat(filepath.Join(home, "release")); err == nil {
						once.Do(func() { close(release) })
						return
					}
				}
			}
		}()
		defer func() { once.Do(func() { close(release) }); <-done }()
		for _, stage := range []string{"old", "replacement"} {
			runEnginePhase(t, home, stage, "PSEUDO_PROVIDER_URL="+server.URL)
		}
		return
	}
	body := validConfig + fmt.Sprintf("proxy-providers:\n fixture:\n  type: http\n  url: %s\n  interval: 1\n  health-check: {enable: false}\n", os.Getenv("PSEUDO_PROVIDER_URL"))
	var e Engine
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	waitFile := func(name string) {
		deadline := time.Now().Add(4 * time.Second)
		for {
			if _, err := os.Stat(filepath.Join(home, name)); err == nil {
				return
			}
			if time.Now().After(deadline) {
				t.Fatal("provider阶段未完成", name)
			}
			time.Sleep(time.Millisecond)
		}
	}
	if phase == "old" {
		waitFile("started")
		requireStop(t, &e)
		return
	}
	deadline := time.Now().Add(4 * time.Second)
	for e.cfg.Providers["fixture"].Proxies()[0].Name() != "fresh" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if e.cfg.Providers["fixture"].Proxies()[0].Name() != "fresh" {
		t.Fatal("replacement context did not load fresh provider")
	}
	if err := os.WriteFile(filepath.Join(home, "release"), []byte("release"), 0600); err != nil {
		t.Fatal(err)
	}
	waitFile("served")
	time.Sleep(200 * time.Millisecond)
	if got := e.cfg.Providers["fixture"].Proxies()[0].Name(); got != "fresh" {
		t.Fatalf("late old response changed new context to %q", got)
	}
}

func TestMissingProviderKeepsKernelSemantics(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	server := httptest.NewServer(http.NotFoundHandler())
	defer server.Close()
	body := validConfig + fmt.Sprintf("proxy-providers:\n  missing:\n    type: http\n    url: %s\n    path: ./missing.yaml\n    interval: 0\n", server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatalf("client rejected kernel-tolerated provider failure: %v", err)
	}
	if !strings.Contains(e.Snapshot(), `"prepared":true`) {
		t.Fatal(e.Snapshot())
	}
	requireStop(t, &e)
}

func TestSocketOwnerRevocationKeepsCapturedLifetimeAndUniqueIdentity(t *testing.T) {
	first := newSocketOwner(func(int) bool { return true }, nil)
	if first.id == 0 || first.ctx == nil || first.ctx.Err() != nil || !first.active.Load() {
		t.Fatal("accepted owner has no active identity/lifetime")
	}
	e := Engine{}
	e.cancelOwner.Store(first)
	e.Cancel()
	if first.active.Load() || !errors.Is(first.ctx.Err(), context.Canceled) {
		t.Fatal("Cancel did not revoke the captured owner context")
	}
	first.revoke()
	replacement := newSocketOwner(func(int) bool { return true }, nil)
	defer replacement.revoke()
	if replacement.id == first.id || replacement.ctx.Err() != nil || !replacement.active.Load() {
		t.Fatal("replacement session borrowed the retired owner's identity/lifetime")
	}
	if !errors.Is(first.ctx.Err(), context.Canceled) || first.active.Load() {
		t.Fatal("replacement session reactivated the captured old owner")
	}
}

func TestPreparationFailureRevokesCapturedSocketOwner(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	original := errors.New("seed original failure")
	for _, seedFailure := range []bool{false, true} {
		t.Run(fmt.Sprint(seedFailure), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			var e Engine
			var captured *socketOwner
			body := validConfig
			if !seedFailure {
				body = "rules: ['UNKNOWN,invalid']\n"
			}
			err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", func(int) bool { return true }, PrepareOptions{
				Purpose: "PREVIEW",
				SeedGeo: func([]GeoSeed) error {
					captured = current.Load()
					if seedFailure {
						return original
					}
					return nil
				},
			}, configinput.Override{Mode: "prepend", Body: "geo-auto-update: false"})
			if err == nil || seedFailure && !errors.Is(err, original) {
				t.Fatalf("preparation lost its actual failure: %v", err)
			}
			if captured == nil || captured.active.Load() || !errors.Is(captured.ctx.Err(), context.Canceled) {
				t.Fatal("failed preparation retained its captured socket/DNS lifetime")
			}
			if current.Load() != nil || e.owner != nil || e.failed {
				t.Fatal("failed preparation retained or poisoned the session")
			}
			requireStop(t, &e)
		})
	}
}
