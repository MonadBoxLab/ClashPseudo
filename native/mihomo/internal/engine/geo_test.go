package engine

import (
	"bytes"
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
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/resource"
	C "github.com/metacubex/mihomo/constant"
)

func TestStopWaitsForGeoBeforeReleasingSession(t *testing.T) {
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	g := &geoUpdater{cancel: make(chan struct{}), done: make(chan struct{})}
	e.geo = g
	tun := signalTunnel{closed: make(chan struct{})}
	e.tun = tun
	stopped := make(chan error, 1)
	var release sync.Once
	t.Cleanup(func() {
		release.Do(func() { close(g.done) })
		requireStop(t, &e)
	})
	go func() { stopped <- e.Stop() }()
	select {
	case <-g.cancel:
	case <-time.After(time.Second):
		t.Fatal("Geo scheduling was not cancelled promptly")
	}
	select {
	case <-tun.closed:
	case <-time.After(time.Second):
		t.Fatal("TUN stayed attached while waiting for Geo")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err == nil {
		t.Fatal("new session accepted before the old Geo write finished")
	}
	// The previous implementation silently abandoned the join after six seconds.
	select {
	case err := <-stopped:
		t.Fatalf("Stop returned before Geo completion: %v", err)
	case <-time.After(6200 * time.Millisecond):
	}
	var state map[string]any
	if err := json.Unmarshal([]byte(e.Snapshot()), &state); err != nil {
		t.Fatal(err)
	}
	if state["prepared"] != true || state["attached"] != false {
		t.Fatalf("wrong pending cleanup state: %v", state)
	}
	release.Do(func() { close(g.done) })
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not settle after Geo really finished")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatalf("completed cleanup prevented restart: %v", err)
	}
}

func TestStopWaitsForManualGeoWriteInItsOriginalHome(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		_, _ = w.Write(minimalGeoData)
	}))
	defer server.Close()
	var e Engine
	home := t.TempDir()
	body := validConfig + fmt.Sprintf("geox-url: {geoip: '%s'}\n", server.URL)
	if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	path := C.Path.GeoIP()
	tun := signalTunnel{closed: make(chan struct{})}
	e.tun = tun
	updated := make(chan error, 1)
	stopped := make(chan error, 1)
	t.Cleanup(func() {
		once.Do(func() { close(release) })
		requireStop(t, &e)
	})
	go func() { updated <- e.UpdateResource("geo", "GeoIP") }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("manual Geo download did not start")
	}
	e.mu.Lock()
	pending := e.geoUpdateStateLocked("GeoIP")
	e.mu.Unlock()
	if pending.LastAttempt.IsZero() || pending.LastResult != "" || !pending.LastSuccessfulCheck.IsZero() {
		t.Fatalf("pending update invented a completed result: %+v", pending)
	}
	go func() { stopped <- e.Stop() }()
	select {
	case <-tun.closed:
	case <-time.After(time.Second):
		t.Fatal("manual Geo network I/O prevented prompt TUN closure")
	}
	select {
	case err := <-stopped:
		t.Fatalf("Stop did not wait for the actual Geo write: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	newHome := t.TempDir()
	if err := e.Prepare(newHome, []byte(validConfig), "rule", nil, func(int) bool { return true }); err == nil {
		t.Fatal("new home accepted before the old write returned")
	}
	once.Do(func() { close(release) })
	if err := <-updated; !errors.Is(err, ErrStopped) {
		t.Fatalf("stale Geo completion was reported as current: %v", err)
	}
	if err := <-stopped; err != nil {
		t.Fatal(err)
	}
	if len(e.geoResults) != 0 {
		t.Fatal("late stopped update retained session result state")
	}
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalGeoData) {
		t.Fatalf("in-flight Geo write did not finish in the old home: %v", err)
	}
	if err := e.Prepare(newHome, []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(C.Path.GeoIP()); !os.IsNotExist(err) {
		t.Fatalf("old Geo write escaped into the new home: %v", err)
	}
}

// Minimal GeoIPList/GeoSiteList with one empty cn entry accepted by both public
// loaders.
var minimalGeoData = []byte{0x0a, 0x04, 0x0a, 0x02, 'c', 'n'}

func TestManualGeoUpdatesAreIndividualAndDoNotEnableMatchers(t *testing.T) {
	var requests [4]atomic.Int32
	names := []string{"GeoIP", "GeoSite", "MMDB", "ASN"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i, name := range names {
			if r.URL.Path == "/"+name {
				requests[i].Add(1)
				if i < 2 {
					_, _ = w.Write(minimalGeoData)
				} else {
					_, _ = w.Write(minimalMMDB())
				}
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer server.Close()
	var e Engine
	body := validConfig + fmt.Sprintf("geox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	before := []bool{geodata.GeoIpEnable(), geodata.GeoSiteEnable(), geodata.ASNEnable()}
	for _, name := range names {
		if err := e.UpdateResource("geo", name); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
	for _, path := range []string{C.Path.GeoIP(), C.Path.GeoSite()} {
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, minimalGeoData) {
			t.Fatalf("database not installed at %s: %v", path, err)
		}
	}
	for _, path := range []string{C.Path.MMDB(), C.Path.ASN()} {
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, minimalMMDB()) {
			t.Fatalf("MaxMind database not installed at %s: %v", path, err)
		}
	}
	for i := range requests {
		if requests[i].Load() != 1 {
			t.Fatalf("%s unexpectedly requested %d times", names[i], requests[i].Load())
		}
	}
	after := []bool{geodata.GeoIpEnable(), geodata.GeoSiteEnable(), geodata.ASNEnable()}
	for i := range before {
		if before[i] != after[i] {
			t.Fatal("manual download changed matcher enablement")
		}
	}
}

func TestMaxMindBootstrapReturnsToNormalRoutingWithoutDirectFallback(t *testing.T) {
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt"} {
			t.Run(name+"/"+old, func(t *testing.T) {
				var requests atomic.Int32
				changed := minimalMMDB()
				changed[len(changed)-1] = 6 // A different valid response after bootstrap.
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if requests.Add(1) == 1 {
						_, _ = w.Write(minimalMMDB())
					} else {
						_, _ = w.Write(changed)
					}
				}))
				defer server.Close()
				var e Engine
				// Keep the same session and rejection rule throughout: only repairing
				// the unusable old database may bypass it with explicit DIRECT.
				body := fmt.Sprintf("mode: rule\nlog-level: silent\nrules: ['MATCH,REJECT']\ngeox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
				if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
				path := C.Path.MMDB()
				if name == "ASN" {
					path = C.Path.ASN()
				}
				if old == "corrupt" {
					if err := os.WriteFile(path, []byte("corrupt old database"), 0600); err != nil {
						t.Fatal(err)
					}
				}
				if err := e.UpdateResource("geo", name); err != nil {
					t.Fatalf("DIRECT bootstrap could not repair %s database: %v", old, err)
				}
				if requests.Load() != 1 {
					t.Fatalf("bootstrap made %d HTTP requests, want one", requests.Load())
				}
				if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
					t.Fatalf("bootstrap did not install the valid database: %v", err)
				}
				for attempt := 1; attempt <= 2; attempt++ {
					if err := e.UpdateResource("geo", name); err == nil {
						t.Fatalf("normal update %d bypassed MATCH,REJECT after bootstrap", attempt)
					}
					if requests.Load() != 1 {
						t.Fatalf("normal update %d reached HTTP despite rejection (including a DIRECT fallback): %d requests", attempt, requests.Load())
					}
					if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
						t.Fatalf("rejected normal update %d changed the installed database: %v", attempt, err)
					}
				}
			})
		}
	}
}

func TestAutomaticGeoFollowsCoreTargetsAcrossSessions(t *testing.T) {
	var requests atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		if r.URL.Path == "/GeoSite" {
			_, _ = w.Write(minimalGeoData)
		} else {
			_, _ = w.Write(minimalMMDB())
		}
	}))
	defer server.Close()
	var e Engine
	defer requireStop(t, &e)
	sources := fmt.Sprintf("geox-url:\n mmdb: %s/MMDB\n asn: %s/ASN\n geosite: %s/GeoSite\n", server.URL, server.URL, server.URL)
	home := t.TempDir()
	for _, file := range []string{"Country.mmdb", "ASN.mmdb", "GeoSite.dat"} {
		data := minimalMMDB()
		if file == "GeoSite.dat" {
			data = minimalGeoData
		}
		if err := os.WriteFile(filepath.Join(home, file), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	first := "mode: rule\nlog-level: silent\ngeodata-mode: false\nrules: ['GEOIP,cn,DIRECT', 'IP-ASN,64500,DIRECT', 'GEOSITE,cn,DIRECT', 'MATCH,DIRECT']\n" + sources
	if err := e.Prepare(home, []byte(first), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	if !geodata.GeoIpEnable() || !geodata.ASNEnable() || !geodata.GeoSiteEnable() {
		t.Fatal("first session did not actually initialize all three Geo matcher families")
	}
	requireStop(t, &e)
	before := requests.Load()
	second := "mode: rule\nlog-level: silent\ngeodata-mode: false\ngeo-auto-update: true\ngeo-update-interval: 1\nrules: ['MATCH,DIRECT']\n" + sources
	if err := e.Prepare(t.TempDir(), []byte(second), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	// Run both preparations and the deterministic update tick in the same process and
	// Engine.
	if err := e.updateResource("geo", "", true); err != nil {
		t.Fatal(err)
	}
	listed, err := e.Resources()
	var rows ResourceList
	if err != nil || json.Unmarshal([]byte(listed), &rows) != nil {
		t.Fatalf("cannot inspect second session: %v", err)
	}
	// Expect the core's retained process-wide targets after the MATCH-only configuration
	// is loaded.
	for _, row := range rows.Resources {
		if row.Kind == "geo" && (row.AutoUpdateTarget == nil || *row.AutoUpdateTarget != (row.Name != "GeoIP")) {
			t.Errorf("second session did not expose the retained public core target: %+v", row)
		}
	}
	if strings.Contains(listed, `"enabled"`) {
		t.Fatal("retained core target was mislabeled as current matcher usage")
	}
	if got := requests.Load() - before; got != 3 {
		t.Errorf("automatic updates did not check exactly the three missing core targets: %d downloads", got)
	}
}

func TestGeoInitialCheckDoesNotLetUnrelatedFreshFileMaskDueResources(t *testing.T) {
	var requests [4]atomic.Int32
	var invalidASN atomic.Bool
	names := []string{"GeoIP", "MMDB", "ASN", "GeoSite"}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for i, name := range names {
			if r.URL.Path == "/"+name {
				requests[i].Add(1)
				if name == "ASN" && invalidASN.Load() {
					_, _ = w.Write([]byte("invalid ASN replacement"))
				} else if name == "GeoIP" || name == "GeoSite" {
					_, _ = w.Write(minimalGeoData)
				} else {
					_, _ = w.Write(minimalMMDB())
				}
				return
			}
		}
		http.NotFound(w, r)
	}))
	defer server.Close()
	home := t.TempDir()
	paths := [4]string{filepath.Join(home, "GeoIP.dat"), filepath.Join(home, "Country.mmdb"), filepath.Join(home, "ASN.mmdb"), filepath.Join(home, "GeoSite.dat")}
	for i, path := range paths {
		data := minimalMMDB()
		if i == 0 || i == 3 {
			data = minimalGeoData
		}
		if err := os.WriteFile(path, data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	var e Engine
	body := fmt.Sprintf("mode: rule\nlog-level: silent\ngeodata-mode: false\ngeo-update-interval: 1\nrules: ['GEOIP,cn,DIRECT', 'IP-ASN,64500,DIRECT', 'GEOSITE,cn,DIRECT', 'MATCH,DIRECT']\ngeox-url:\n geoip: %s/GeoIP\n mmdb: %s/MMDB\n asn: %s/ASN\n geosite: %s/GeoSite\n", server.URL, server.URL, server.URL, server.URL)
	if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	old := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(paths[1], old, old); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(paths[2]); err != nil {
		t.Fatal(err)
	}
	assertRequests := func(want [4]int32) {
		t.Helper()
		for i := range requests {
			if got := requests[i].Load(); got != want[i] {
				t.Fatalf("%s HTTP requests: got %d want %d", names[i], got, want[i])
			}
		}
	}
	// Complete safe repair before routed MMDB download, whose IP-ASN rule may read the
	// ASN database.
	invalidASN.Store(true)
	if err := e.updateResource("geo", "", true); err == nil {
		t.Fatal("invalid ASN repair accepted")
	}
	assertRequests([4]int32{0, 0, 1, 0})
	e.mu.Lock()
	deferredMMDB := e.geoUpdateStateLocked("MMDB")
	e.mu.Unlock()
	if deferredMMDB != (geoUpdateState{}) {
		t.Fatal("deferred normal update was falsely recorded as attempted")
	}
	invalidASN.Store(false)
	// Repair missing ASN before normal MMDB routing and evaluate freshness per target
	// file.
	if err := e.updateResource("geo", "", true); err != nil {
		t.Fatal(err)
	}
	assertRequests([4]int32{0, 1, 2, 0})
	// A successful unchanged-content check retains the original mtime and updates check
	// freshness.
	if err := e.updateResource("geo", "", true); err != nil {
		t.Fatal(err)
	}
	assertRequests([4]int32{0, 1, 2, 0})
	// Validate contents even with fresh mtimes and recent successful checks.
	for _, i := range []int{1, 3} {
		if err := os.WriteFile(paths[i], []byte("corrupt fresh database"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.updateResource("geo", "", true); err != nil {
		t.Fatal(err)
	}
	assertRequests([4]int32{0, 2, 2, 1})
}

func TestGeoResourceDueChecksEachFileAndCurrentBytes(t *testing.T) {
	for _, name := range []string{"GeoIP", "MMDB", "GeoSite", "ASN"} {
		t.Run(name, func(t *testing.T) {
			now := time.Now()
			path := filepath.Join(t.TempDir(), name)
			item := geoResource{name: name, path: path}
			data := minimalMMDB()
			if name == "GeoIP" || name == "GeoSite" {
				data = minimalGeoData
			}
			if err := os.WriteFile(path, data, 0600); err != nil {
				t.Fatal(err)
			}
			assertDue := func(lastCheck time.Time, want bool) {
				t.Helper()
				if got := geoResourceDue(item, time.Hour, lastCheck, now); got != want {
					t.Fatalf("due=%v, want %v (last check %v)", got, want, lastCheck)
				}
			}
			assertDue(time.Time{}, false)
			old := now.Add(-2 * time.Hour)
			if err := os.Chtimes(path, old, old); err != nil {
				t.Fatal(err)
			}
			assertDue(time.Time{}, true)
			assertDue(now.Add(-time.Minute), false)
			if err := os.WriteFile(path, []byte("corrupt fresh database"), 0600); err != nil {
				t.Fatal(err)
			}
			assertDue(now.Add(-time.Minute), true)
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			assertDue(now.Add(-time.Minute), true)
			if err := os.Mkdir(path, 0700); err != nil {
				t.Fatal(err)
			}
			assertDue(now.Add(-time.Minute), true)
		})
	}
}

func TestGeoPathsSnapshotPreservesAliasesAndChangesHome(t *testing.T) {
	geoData := append(append([]byte(nil), minimalGeoData...), minimalGeoData...)
	maxMindData := minimalMMDB()
	maxMindData[len(maxMindData)-1] = 6
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/GeoIP" || r.URL.Path == "/GeoSite" {
			_, _ = w.Write(geoData)
		} else {
			_, _ = w.Write(maxMindData)
		}
	}))
	defer server.Close()
	var e Engine
	defer requireStop(t, &e)
	body := validConfig + fmt.Sprintf("geox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	for _, aliases := range [][4]string{
		{"gEoIp.DaT", "geoip.db", "aSn.MmDb", "gEoSiTe.DaT"},
		{"GeoIP.dat", "Country.mmdb", "ASN.mmdb", "GeoSite.dat"},
	} {
		home := t.TempDir()
		var expected [4]string
		for i, file := range aliases {
			expected[i] = filepath.Join(home, file)
			data := minimalMMDB()
			if i == 0 || i == 3 {
				data = minimalGeoData
			}
			if err := os.WriteFile(expected[i], data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		if e.geoPaths != expected {
			t.Fatalf("session captured wrong home or alias paths: got %v want %v", e.geoPaths, expected)
		}
		for i, name := range []string{"GeoIP", "MMDB", "ASN", "GeoSite"} {
			if err := e.UpdateResource("geo", name); err != nil {
				t.Fatalf("updating existing alias %s failed: %v", expected[i], err)
			}
			want := maxMindData
			if i == 0 || i == 3 {
				want = geoData
			}
			if data, err := os.ReadFile(expected[i]); err != nil || !bytes.Equal(data, want) {
				t.Fatalf("update did not write the captured alias path %s: %v", expected[i], err)
			}
		}
		listed, err := e.Resources()
		var rows ResourceList
		if err != nil || json.Unmarshal([]byte(listed), &rows) != nil {
			t.Fatalf("cannot project captured Geo files: %v", err)
		}
		for _, row := range rows.Resources {
			if row.Kind == "geo" && row.FileStatus != "present" {
				t.Fatalf("snapshot projection lost its existing alias: %+v", row)
			}
		}
		requireStop(t, &e)
		if e.geoPaths != ([4]string{}) {
			t.Fatal("Stop retained paths from the old home")
		}
	}
}

func TestGeoDiagnosticsCanReadDuringUpdates(t *testing.T) {
	home := t.TempDir()
	for _, name := range []string{"GeoIP.dat", "GeoSite.dat", "Country.mmdb", "ASN.mmdb"} {
		data := minimalMMDB()
		if strings.HasSuffix(name, ".dat") {
			data = minimalGeoData
		}
		if err := os.WriteFile(filepath.Join(home, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/GeoIP" || r.URL.Path == "/GeoSite" {
			_, _ = w.Write(minimalGeoData)
		} else {
			_, _ = w.Write(minimalMMDB())
		}
	}))
	defer server.Close()
	var e Engine
	body := validConfig + fmt.Sprintf("geo-auto-update: true\ngeo-update-interval: 1\ngeox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	updated := make(chan error, 1)
	go func() {
		for range 20 {
			for _, name := range []string{"GeoIP", "GeoSite", "MMDB", "ASN"} {
				if err := e.UpdateResource("geo", name); err != nil {
					updated <- err
					return
				}
			}
		}
		updated <- nil
	}()
	var readErr error
	for range 80 {
		if _, readErr = e.Resources(); readErr != nil {
			break
		}
	}
	updateErr := <-updated
	if readErr != nil || updateErr != nil {
		t.Fatalf("concurrent resource operation failed: read=%v update=%v", readErr, updateErr)
	}
}

func TestGeoUpdateStateTracksChecksWithoutInventingFileUpdates(t *testing.T) {
	var invalid atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if invalid.Load() {
			_, _ = w.Write([]byte("invalid replacement"))
		} else if r.URL.Path == "/GeoIP" || r.URL.Path == "/GeoSite" {
			_, _ = w.Write(minimalGeoData)
		} else {
			_, _ = w.Write(minimalMMDB())
		}
	}))
	defer server.Close()
	var e Engine
	home := t.TempDir()
	body := validConfig + fmt.Sprintf("geox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	prepare := func() {
		t.Helper()
		if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
	}
	prepare()
	defer requireStop(t, &e)
	readState := func(name string) geoUpdateState {
		e.mu.Lock()
		defer e.mu.Unlock()
		return e.geoUpdateStateLocked(name)
	}
	names := []string{"GeoIP", "GeoSite", "MMDB", "ASN"}
	paths := []string{C.Path.GeoIP(), C.Path.GeoSite(), C.Path.MMDB(), C.Path.ASN()}
	for i, name := range names {
		if state := readState(name); state != (geoUpdateState{}) {
			t.Fatalf("unused %s has an invented result: %+v", name, state)
		}
		invalid.Store(false)
		started := time.Now()
		if err := e.UpdateResource("geo", name); err != nil {
			t.Fatal(err)
		}
		state := readState(name)
		if state.LastResult != "success" || state.LastAttempt.Before(started) || state.LastSuccessfulCheck.Before(state.LastAttempt) || state.LastSuccessfulCheck.After(time.Now()) {
			t.Fatalf("bad successful check state for %s: %+v", name, state)
		}
		// Record unchanged bytes as a successful check while preserving the previous write
		// timestamp.
		past := time.Unix(1000000000, 0)
		if err := os.Chtimes(paths[i], past, past); err != nil {
			t.Fatal(err)
		}
		if err := e.UpdateResource("geo", name); err != nil {
			t.Fatal(err)
		}
		checked := readState(name)
		info, err := os.Stat(paths[i])
		if err != nil || !info.ModTime().Equal(past) {
			t.Fatalf("unchanged %s unexpectedly rewrote its file: %v", name, err)
		}
		if checked.LastResult != "success" || !checked.LastAttempt.After(state.LastAttempt) || !checked.LastSuccessfulCheck.After(state.LastSuccessfulCheck) {
			t.Fatalf("unchanged-content check was not recorded for %s: %+v", name, checked)
		}
		invalid.Store(true)
		if err := e.UpdateResource("geo", name); err == nil {
			t.Fatalf("invalid %s update accepted", name)
		}
		failed := readState(name)
		if failed.LastResult != "failed" || !failed.LastAttempt.After(checked.LastAttempt) || !failed.LastSuccessfulCheck.Equal(checked.LastSuccessfulCheck) {
			t.Fatalf("failure overwrote successful-check evidence for %s: %+v", name, failed)
		}
		if len(e.geoResults) != i+1 {
			t.Fatalf("%s attempt altered other resource records: %+v", name, e.geoResults)
		}
	}
	if err := e.UpdateResource("geo", "unknown"); err == nil || len(e.geoResults) != 4 {
		t.Fatal("invalid target created an unbounded history entry")
	}
	requireStop(t, &e)
	if len(e.geoResults) != 0 {
		t.Fatal("Stop retained session Geo results")
	}
	prepare()
	for _, name := range names {
		if state := readState(name); state != (geoUpdateState{}) {
			t.Fatalf("new session inferred %s update success from an existing file: %+v", name, state)
		}
	}
}

func TestMaxMindUpdatesValidateBeforeReplacingOldData(t *testing.T) {
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt", "valid"} {
			t.Run(name+"/"+old, func(t *testing.T) {
				var valid atomic.Bool
				changed := minimalMMDB()
				changed[len(changed)-1] = 6 // A different valid database (IPv6).
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if valid.Load() {
						_, _ = w.Write(changed)
					} else {
						_, _ = w.Write([]byte("not a MaxMind database"))
					}
				}))
				defer server.Close()
				var e Engine
				body := validConfig + fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
				if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
				path := C.Path.MMDB()
				if name == "ASN" {
					path = C.Path.ASN()
				}
				var previous []byte
				if old != "missing" {
					previous = []byte("corrupt old bytes must survive a bad response")
					if old == "valid" {
						previous = minimalMMDB()
					}
					if err := os.WriteFile(path, previous, 0600); err != nil {
						t.Fatal(err)
					}
				}
				if err := e.UpdateResource("geo", name); err == nil {
					t.Fatal("invalid download accepted")
				}
				data, err := os.ReadFile(path)
				if old == "missing" {
					if !os.IsNotExist(err) {
						t.Fatalf("invalid download created a database: %v", err)
					}
				} else if err != nil || !bytes.Equal(data, previous) {
					t.Fatalf("invalid download changed old data: %v", err)
				}
				valid.Store(true)
				if err := e.UpdateResource("geo", name); err != nil {
					t.Fatal(err)
				}
				data, err = os.ReadFile(path)
				if err != nil || !bytes.Equal(data, changed) {
					t.Fatalf("valid replacement not installed: %v", err)
				}
			})
		}
	}
}

func TestRequiredGeoStartupAndAutomaticRepair(t *testing.T) {
	if kind := os.Getenv("PSEUDO_REQUIRED_GEO_KIND"); kind != "" {
		var requests atomic.Int32
		var invalid atomic.Bool
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			if invalid.Load() {
				_, _ = w.Write([]byte("invalid replacement"))
				return
			}
			_, _ = w.Write(minimalMMDB())
		}))
		defer server.Close()
		var e Engine
		rule := "GEOIP,cn,DIRECT"
		if kind == "ASN" {
			rule = "IP-ASN,64500,DIRECT"
		} else if kind == "none" {
			rule = "MATCH,DIRECT"
		}
		body := fmt.Sprintf("mode: rule\nlog-level: silent\ngeodata-mode: false\ngeox-url: {mmdb: '%s', asn: '%s'}\nrules: ['%s']\n", server.URL, server.URL, rule)
		home := t.TempDir()
		if os.Getenv("PSEUDO_REQUIRED_GEO_CORRUPT") == "1" {
			file := "Country.mmdb"
			if kind == "ASN" {
				file = "ASN.mmdb"
			}
			if err := os.WriteFile(filepath.Join(home, file), []byte("corrupt startup database"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if err := e.Prepare(home, []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		defer requireStop(t, &e)
		if kind == "none" {
			if err := e.updateResource("geo", "", true); err != nil {
				t.Fatal(err)
			}
			if requests.Load() != 0 {
				t.Fatal("configured URLs alone triggered unused downloads")
			}
			for _, path := range geoFiles() {
				if _, err := os.Stat(path); !os.IsNotExist(err) {
					t.Fatalf("automatic update created an unused database: %s: %v", path, err)
				}
			}
			return
		}
		path, other := C.Path.MMDB(), C.Path.ASN()
		var rows ResourceList
		listed, err := e.Resources()
		if err != nil || json.Unmarshal([]byte(listed), &rows) != nil {
			t.Fatalf("cannot list required Geo resource state: %v", err)
		}
		for _, row := range rows.Resources {
			if row.Kind == "geo" && (row.AutoUpdateTarget == nil || *row.AutoUpdateTarget != (row.Name == kind)) {
				t.Fatalf("Geo mode reported the wrong core update target: %+v", row)
			}
		}
		if kind == "ASN" {
			path, other = other, path
		}
		if requests.Load() != 1 {
			t.Fatalf("startup did not download exactly the required database: %d", requests.Load())
		}
		if _, err := os.Stat(other); !os.IsNotExist(err) {
			t.Fatalf("startup downloaded an unused database: %v", err)
		}
		if err := os.Remove(path); err != nil {
			t.Fatal(err)
		}
		if os.Getenv("PSEUDO_REQUIRED_GEO_DEFAULT_ROUTE") == "1" {
			// Evidence for the routing gap: the default public vehicle recursively
			// evaluates the active Geo rule before it can download the missing DB.
			vehicle := resource.NewHTTPVehicle(server.URL, path, "", nil, time.Second, 0)
			_, _, _ = vehicle.Read(context.Background(), utils.HashType{})
			t.Fatal("default-routed missing-database download unexpectedly survived")
		}
		// The actual session timer must use the safe first-install path too.
		e.mu.Lock()
		e.startGeo(true, 1)
		e.mu.Unlock()
		deadline := time.Now().Add(2 * time.Second)
		for {
			data, err := os.ReadFile(path)
			if err == nil && bytes.Equal(data, minimalMMDB()) {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("automatic scheduler did not repair missing %s: %v", kind, err)
			}
			time.Sleep(5 * time.Millisecond)
		}
		if requests.Load() != 2 {
			t.Fatalf("automatic repair selected unexpected resources: %d", requests.Load())
		}
		invalid.Store(true)
		old := []byte("invalid old data retained until a valid replacement exists")
		if err := os.WriteFile(path, old, 0600); err != nil {
			t.Fatal(err)
		}
		if err := e.updateResource("geo", "", true); err == nil {
			t.Fatal("automatic updater accepted an invalid replacement")
		}
		if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, old) {
			t.Fatalf("automatic invalid response destroyed old bytes: %v", err)
		}
		e.mu.Lock()
		failed := e.geoUpdateStateLocked(kind)
		e.mu.Unlock()
		if failed.LastResult != "failed" || failed.LastAttempt.IsZero() || failed.LastSuccessfulCheck.IsZero() || len(e.geoResults) != 1 {
			t.Fatalf("automatic per-database results were not retained: %+v", e.geoResults)
		}
		invalid.Store(false)
		if err := e.updateResource("geo", "", true); err != nil {
			t.Fatal(err)
		}
		if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
			t.Fatalf("automatic corrupt-old repair failed: %v", err)
		}
		return
	}
	// Isolate startup demand cases in fresh processes because public Init flags persist
	// process-wide.
	for _, kind := range []string{"MMDB", "ASN", "none"} {
		for _, routing := range []string{"safeBootstrap", "safeBootstrapCorrupt", "defaultVehicleFatal"} {
			if kind == "none" && routing != "safeBootstrap" {
				continue
			}
			t.Run(kind+"/"+routing, func(t *testing.T) {
				cmd := exec.Command(os.Args[0], "-test.run=^TestRequiredGeoStartupAndAutomaticRepair$")
				if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
					cmd.Args = append(cmd.Args, "-test.gocoverdir="+directory.Value.String())
				}
				cmd.Env = append(os.Environ(), "PSEUDO_REQUIRED_GEO_KIND="+kind)
				if routing == "safeBootstrapCorrupt" {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_CORRUPT=1")
				}
				if routing == "defaultVehicleFatal" {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_DEFAULT_ROUTE=1")
				}
				output, err := cmd.CombinedOutput()
				if routing == "defaultVehicleFatal" {
					var exited *exec.ExitError
					if !errors.As(err, &exited) || exited.ExitCode() != 1 || !strings.Contains(string(output), "Can't load "+kind) {
						t.Fatalf("expected isolated default-routing fatal: %v\n%s", err, output)
					}
				} else if err != nil {
					t.Fatalf("%v\n%s", err, output)
				}
			})
		}
	}
}

func TestStopWaitsForMaxMindBootstrapInOriginalHome(t *testing.T) {
	for _, name := range []string{"MMDB", "ASN"} {
		t.Run(name, func(t *testing.T) {
			started, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(started)
				<-release
				_, _ = w.Write(minimalMMDB())
			}))
			defer server.Close()
			var e Engine
			body := validConfig + fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
			if err := e.Prepare(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			path := C.Path.MMDB()
			if name == "ASN" {
				path = C.Path.ASN()
			}
			tun := signalTunnel{closed: make(chan struct{})}
			e.tun = tun
			updated, stopped := make(chan error, 1), make(chan error, 1)
			t.Cleanup(func() {
				once.Do(func() { close(release) })
				requireStop(t, &e)
			})
			go func() { updated <- e.UpdateResource("geo", name) }()
			select {
			case <-started:
			case <-time.After(time.Second):
				t.Fatal("bootstrap did not start")
			}
			go func() { stopped <- e.Stop() }()
			select {
			case <-tun.closed:
			case <-time.After(time.Second):
				t.Fatal("bootstrap blocked prompt TUN closure")
			}
			newHome := t.TempDir()
			if err := e.Prepare(newHome, []byte(validConfig), "rule", nil, func(int) bool { return true }); err == nil {
				t.Fatal("replacement context accepted before bootstrap returned")
			}
			once.Do(func() { close(release) })
			if err := <-updated; !errors.Is(err, ErrStopped) {
				t.Fatalf("stale bootstrap reported current success: %v", err)
			}
			if err := <-stopped; err != nil {
				t.Fatal(err)
			}
			if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
				t.Fatalf("bootstrap did not finish in original home: %v", err)
			}
			if err := e.Prepare(newHome, []byte(validConfig), "rule", nil, func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			newPath := C.Path.MMDB()
			if name == "ASN" {
				newPath = C.Path.ASN()
			}
			if _, err := os.Stat(newPath); !os.IsNotExist(err) {
				t.Fatalf("bootstrap wrote into replacement home: %v", err)
			}
		})
	}
}

// Construct a minimal empty IPv4 MaxMind database with its separator and supported
// metadata.
func minimalMMDB() []byte {
	data := append(make([]byte, 16), []byte("\xab\xcd\xefMaxMind.com")...)
	data = append(data, 0xe2, 0x4b)
	data = append(data, []byte("record_size")...)
	data = append(data, 0xa1, 24, 0x4a)
	data = append(data, []byte("ip_version")...)
	return append(data, 0xa1, 4)
}
