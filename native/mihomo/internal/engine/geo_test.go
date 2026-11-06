package engine

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	"go.yaml.in/yaml/v3"

	"clashpseudo/native/internal/coreview"
)

func TestStopWaitsForGeoBeforeReleasingSession(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	e.updates.Add(1)
	tun := signalTunnel{closed: make(chan struct{})}
	e.tun = tun
	stopped := make(chan error, 1)
	var release sync.Once
	t.Cleanup(func() {
		release.Do(func() { e.updates.Done() })
		requireStop(t, &e)
	})
	go func() { stopped <- e.Stop() }()
	select {
	case <-tun.closed:
	case <-time.After(time.Second):
		t.Fatal("TUN stayed attached while waiting for Geo")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
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
	release.Do(func() { e.updates.Done() })
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("Stop did not settle after Geo really finished")
	}
	if err := e.Prepare(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
		t.Fatal("同一Engine停止后再次装载")
	}
}

func TestStopWaitsForManualGeoWriteInItsOriginalHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	path := C.Path.GeoIP()
	tun := signalTunnel{closed: make(chan struct{})}
	e.tun = tun
	updated := make(chan error, 1)
	stopped := make(chan error, 1)
	defer func() {
		once.Do(func() { close(release) })
		requireStop(t, &e)
	}()
	go func() { updated <- e.UpdateResource("geo", "GeoIP") }()
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("manual Geo download did not start")
	}
	// 原 ResourceCalls 输入为 geo/GeoIP；HTTP 尚未放行时读取实际 runtimeConfig。
	diagnostic := make(chan error, 1)
	go func() {
		value, err := e.RuntimeConfig()
		if err == nil {
			var configuration struct {
				Mode string `yaml:"mode"`
			}
			err = yaml.Unmarshal([]byte(value), &configuration)
			if err == nil && configuration.Mode != "rule" {
				err = fmt.Errorf("GeoIP I/O 期间 runtimeConfig mode = %q，预期 rule", configuration.Mode)
			}
		}
		diagnostic <- err
	}()
	select {
	case err := <-diagnostic:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtimeConfig 等待了尚未放行的 GeoIP HTTP I/O")
	}
	select {
	case err := <-updated:
		t.Fatalf("HTTP 尚未放行，GeoIP 更新提前返回：%v", err)
	default:
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
	if err := e.Prepare(newHome, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
		t.Fatal("new home accepted before the old write returned")
	}
	once.Do(func() { close(release) })
	if err := <-updated; err != nil {
		t.Fatalf("completed Geo update lost its actual success: %v", err)
	}
	if err := <-stopped; err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalGeoData) {
		t.Fatalf("in-flight Geo write did not finish in the old home: %v", err)
	}
	requireFreshEngineProcess(t, newHome)
	if _, err := os.Stat(filepath.Join(newHome, filepath.Base(path))); !os.IsNotExist(err) {
		t.Fatalf("old Geo write escaped into the new home: %v", err)
	}
}

// Minimal GeoIPList/GeoSiteList with one empty cn entry accepted by both public
// loaders.
var minimalGeoData = []byte{0x0a, 0x04, 0x0a, 0x02, 'c', 'n'}

func seedMaxMindFixture(t *testing.T, home string) {
	t.Helper()
	for _, file := range []string{"Country.mmdb", "ASN.mmdb"} {
		if err := os.WriteFile(filepath.Join(home, file), minimalMMDB(), 0600); err != nil {
			t.Fatal(err)
		}
	}
}

func TestManualGeoUpdatesAreIndividualAndDoNotEnableMatchers(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	home := t.TempDir()
	seedMaxMindFixture(t, home)
	body := validConfig + fmt.Sprintf("geox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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

func TestGeoTargetsDoNotSurviveCoreProcessRestart(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	phase := os.Getenv("PSEUDO_ENGINE_PHASE")
	if phase == "" {
		home := t.TempDir()
		runEnginePhase(t, home, "matchers")
		runEnginePhase(t, home, "fresh")
		return
	}
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
	sources := fmt.Sprintf("geox-url:\n mmdb: %s/MMDB\n asn: %s/ASN\n geosite: %s/GeoSite\n", server.URL, server.URL, server.URL)
	home := os.Getenv("PSEUDO_ENGINE_HOME")
	rules := "rules: ['MATCH,DIRECT']\n"
	if phase == "matchers" {
		for _, file := range []string{"Country.mmdb", "ASN.mmdb", "GeoSite.dat"} {
			data := minimalMMDB()
			if file == "GeoSite.dat" {
				data = minimalGeoData
			}
			if err := os.WriteFile(filepath.Join(home, file), data, 0600); err != nil {
				t.Fatal(err)
			}
		}
		rules = "rules: ['GEOIP,cn,DIRECT', 'IP-ASN,64500,DIRECT', 'GEOSITE,cn,DIRECT', 'MATCH,DIRECT']\n"
	}
	var e Engine
	body := "mode: rule\nlog-level: silent\ngeodata-mode: false\ngeo-auto-update: false\ngeo-update-interval: 1\n" + rules + sources
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if phase == "matchers" {
		if !geodata.GeoIpEnable() || !geodata.ASNEnable() || !geodata.GeoSiteEnable() {
			t.Fatal("首个进程没有初始化三类Geo matcher")
		}
		return
	}
	if geodata.GeoIpEnable() || geodata.ASNEnable() || geodata.GeoSiteEnable() {
		t.Fatal("新core进程保留了旧进程的Geo matcher状态")
	}
	if err := updater.UpdateGeoDatabases(); err != nil {
		t.Fatal(err)
	}
	listed, err := e.Resources()
	var rows coreview.ResourceList
	if err != nil || json.Unmarshal([]byte(listed), &rows) != nil {
		t.Fatalf("无法读取新context的Geo状态: %v", err)
	}
	for _, row := range rows.Resources {
		if row.Kind == "geo" && (row.AutoUpdateTarget == nil || *row.AutoUpdateTarget) {
			t.Errorf("MATCH-only新进程错误继承旧Geo target: %+v", row)
		}
	}
	if strings.Contains(listed, `"enabled"`) {
		t.Fatal("Geo target被错误标记为当前matcher使用状态")
	}
	if got := requests.Load(); got != 0 {
		t.Errorf("MATCH-only新进程下载了未使用的Geo数据库: %d", got)
	}
}

func TestGeoPathsSnapshotPreservesAliasesAndChangesHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
		t.Run(aliases[0], func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}

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
			if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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
			var rows coreview.ResourceList
			if err != nil || json.Unmarshal([]byte(listed), &rows) != nil {
				t.Fatalf("cannot project captured Geo files: %v", err)
			}
			for _, row := range rows.Resources {
				if row.Kind == "geo" && row.FileStatus != "present" {
					t.Fatalf("snapshot projection lost its existing alias: %+v", row)
				}
			}
			requireStop(t, &e)
			if e.geoPaths != expected {
				t.Fatal("Stop改变了本process的已捕获路径")
			}
		})
	}
}

func TestGeoDiagnosticsCanReadDuringUpdates(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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

func TestManualGeoUpdatesKeepPublicFileAndErrorResultsWithoutHistory(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
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
	seedMaxMindFixture(t, home)
	body := validConfig + fmt.Sprintf("geox-url:\n geoip: %s/GeoIP\n geosite: %s/GeoSite\n mmdb: %s/MMDB\n asn: %s/ASN\n", server.URL, server.URL, server.URL, server.URL)
	if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	names := []string{"GeoIP", "GeoSite", "MMDB", "ASN"}
	paths := []string{C.Path.GeoIP(), C.Path.GeoSite(), C.Path.MMDB(), C.Path.ASN()}
	for i, name := range names {
		invalid.Store(false)
		if err := e.UpdateResource("geo", name); err != nil {
			t.Fatal(err)
		}
		previous, err := os.ReadFile(paths[i])
		if err != nil {
			t.Fatal(err)
		}
		past := time.Unix(1000000000, 0)
		if err = os.Chtimes(paths[i], past, past); err != nil {
			t.Fatal(err)
		}
		if err = e.UpdateResource("geo", name); err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(paths[i])
		if err != nil || !info.ModTime().Equal(past) {
			t.Fatal("相同内容的公开update改写了文件", name, err)
		}
		invalid.Store(true)
		updateErr := e.UpdateResource("geo", name)
		if updateErr == nil {
			t.Fatal("无效数据库被接受", name)
		}
		if data, err := os.ReadFile(paths[i]); err != nil || !bytes.Equal(data, previous) {
			t.Fatal("无效update替换了原文件", name, err)
		}
		listed, err := e.Resources()
		if err != nil {
			t.Fatal(err)
		}
		var rows coreview.ResourceList
		if err = json.Unmarshal([]byte(listed), &rows); err != nil {
			t.Fatal(err)
		}
		for _, row := range rows.Resources {
			if row.Kind == "geo" && (row.LastAttempt != nil || row.LastResult != "" || row.LastError != "" || row.LastSuccessfulCheck != nil || row.UpdatedAt != nil) {
				t.Fatal("Go保留了应用Geo历史", row)
			}
		}
		invalid.Store(false)
		if err = e.UpdateResource("geo", name); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.UpdateResource("geo", "unknown"); err == nil {
		t.Fatal("无效target被接受")
	}
}

func TestStopWaitsForMaxMindUpdateInOriginalHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"MMDB", "ASN"} {
		t.Run(name, func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			replacement := minimalMMDB()
			replacement[len(replacement)-1] = 6
			started, release := make(chan struct{}), make(chan struct{})
			var once sync.Once
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				close(started)
				<-release
				_, _ = w.Write(replacement)
			}))
			defer server.Close()
			var e Engine
			home := t.TempDir()
			seedMaxMindFixture(t, home)
			body := validConfig + fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
			if err := e.Prepare(home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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
				t.Fatal("update did not start")
			}
			go func() { stopped <- e.Stop() }()
			select {
			case <-tun.closed:
			case <-time.After(time.Second):
				t.Fatal("update blocked prompt TUN closure")
			}
			newHome := t.TempDir()
			if err := e.Prepare(newHome, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
				t.Fatal("replacement context accepted before update returned")
			}
			once.Do(func() { close(release) })
			if err := <-updated; err != nil {
				t.Fatalf("completed update lost its actual success: %v", err)
			}
			if err := <-stopped; err != nil {
				t.Fatal(err)
			}
			if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, replacement) {
				t.Fatalf("update did not finish in original home: %v", err)
			}
			requireFreshEngineProcess(t, newHome)
			newPath := filepath.Join(newHome, filepath.Base(path))
			if _, err := os.Stat(newPath); !os.IsNotExist(err) {
				t.Fatalf("update wrote into replacement home: %v", err)
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
