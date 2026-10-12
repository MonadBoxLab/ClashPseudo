package engine

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
)

const validConfig = "mode: rule\nfind-process-mode: off\nrules:\n  - MATCH,DIRECT\n"

type rawSocket struct{}

func (rawSocket) Control(f func(uintptr)) error  { f(42); return nil }
func (rawSocket) Read(func(uintptr) bool) error  { return nil }
func (rawSocket) Write(func(uintptr) bool) error { return nil }

func requireStop(t *testing.T, e *Engine) {
	t.Helper()
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestPrepareStopRestart(t *testing.T) {
	var e Engine
	home := t.TempDir()
	for i := 0; i < 3; i++ {
		if err := e.Prepare(home, []byte(validConfig), func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		if err := e.Prepare(home, []byte(validConfig), func(int) bool { return true }); err == nil {
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
		if e.cfg != nil || e.owner != nil || current.Load() != nil {
			t.Fatal("session references retained")
		}
	}
}

func TestProtectAndCancellation(t *testing.T) {
	var e Engine
	var accepted atomic.Bool
	accepted.Store(true)
	if err := e.Prepare(t.TempDir(), []byte(validConfig), func(int) bool { return accepted.Load() }); err != nil {
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

func TestInvalidConfigDoesNotPreventNextStart(t *testing.T) {
	var e Engine
	home := t.TempDir()
	for _, text := range []string{"[invalid yaml", "rules:\n  - UNKNOWN,invalid\n"} {
		if err := e.Prepare(home, []byte(text), func(int) bool { return true }); err == nil {
			t.Fatalf("accepted %q", text)
		}
		if current.Load() != nil || e.owner != nil {
			t.Fatal("failed prepare retained protector")
		}
		requireStop(t, &e)
	}
	if err := e.Prepare(home, []byte(validConfig), func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	requireStop(t, &e)
}

func TestUnknownResourceCannotReportSuccessfulClose(t *testing.T) {
	if err := closeResource(struct{}{}); err == nil {
		t.Fatal("resource without close was accepted")
	}
}

type failedCloser struct{}

func (failedCloser) Close() error { return errors.New("injected cleanup failure") }

func TestCleanupFailureCannotBecomeSuccess(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), func(int) bool { return true }); err != nil {
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
	if err := e.Prepare(t.TempDir(), []byte(validConfig), func(int) bool { return true }); err == nil {
		t.Fatal("restart accepted after cleanup failure")
	}
}

func TestProviderStopsUpdating(t *testing.T) {
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		fmt.Fprintln(w, "proxies:\n  - {name: fixture, type: socks5, server: 127.0.0.1, port: 9}")
	}))
	defer server.Close()
	body := validConfig + fmt.Sprintf("proxy-providers:\n  fixture:\n    type: http\n    url: %s\n    path: ./provider.yaml\n    interval: 1\n    health-check: {enable: false}\n", server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), func(int) bool { return true }); err != nil {
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
	if err := e.Prepare(t.TempDir(), []byte(body), func(int) bool { return true }); err != nil {
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

func TestMissingProviderKeepsKernelSemantics(t *testing.T) {
	server := httptest.NewServer(http.NotFoundHandler())
	defer server.Close()
	body := validConfig + fmt.Sprintf("proxy-providers:\n  missing:\n    type: http\n    url: %s\n    path: ./missing.yaml\n    interval: 0\n", server.URL)
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(body), func(int) bool { return true }); err != nil {
		t.Fatalf("client rejected kernel-tolerated provider failure: %v", err)
	}
	if !strings.Contains(e.Snapshot(), `"prepared":true`) {
		t.Fatal(e.Snapshot())
	}
	requireStop(t, &e)
}
