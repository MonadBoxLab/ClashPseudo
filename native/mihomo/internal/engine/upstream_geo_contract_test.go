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
	"regexp"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/resource"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"

	"clashpseudo/native/internal/coreview"
)

func TestUpstreamMMDBUpdateRequiresExistingDatabase(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	if kind := os.Getenv("PSEUDO_UPSTREAM_GEO_KIND"); kind != "" {
		var e Engine
		body := validConfig + fmt.Sprintf("geox-url:\n mmdb: %s\n asn: %s\n", os.Getenv("PSEUDO_UPSTREAM_GEO_URL"), os.Getenv("PSEUDO_UPSTREAM_GEO_URL"))
		if err := prepareUpstream(t, &e, os.Getenv("PSEUDO_UPSTREAM_GEO_HOME"), []byte(body), "rule", func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		// Deliberately call the fixed upstream API in this child process only.
		// Missing/corrupt old files can invoke log.Fatal and exit the process.
		var err error
		if kind == "MMDB" {
			err = recordUpstreamCall(t, "UpdateMMDB", updater.UpdateMMDB)
		} else {
			err = recordUpstreamCall(t, "UpdateASN", updater.UpdateASN)
		}
		if err != nil {
			t.Fatal(err)
		}
		requireStop(t, &e)
		return
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = writeUpstreamResponse(t, w, minimalMMDB())
	}))
	defer server.Close()
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt", "valid"} {
			t.Run(name+"/"+old, func(t *testing.T) {
				home := t.TempDir()
				file := "Country.mmdb"
				if name == "ASN" {
					file = "ASN.mmdb"
				}
				if old != "missing" {
					data := []byte("invalid old database")
					if old == "valid" {
						data = minimalMMDB()
					}
					if err := os.WriteFile(filepath.Join(home, file), data, 0600); err != nil {
						t.Fatal(err)
					}
				}
				cmd := exec.Command(os.Args[0], "-test.run=^TestUpstreamMMDBUpdateRequiresExistingDatabase$")
				if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
					cmd.Args = append(cmd.Args, "-test.gocoverdir="+directory.Value.String())
				}
				cmd.Env = append(os.Environ(), "PSEUDO_UPSTREAM_GEO_KIND="+name,
					"PSEUDO_UPSTREAM_GEO_HOME="+home, "PSEUDO_UPSTREAM_GEO_URL="+server.URL)
				output, err := runUpstreamProcess(t, cmd)
				if old == "valid" {
					if err != nil {
						t.Fatalf("valid existing database should update: %v\n%s", err, output)
					}
					// Identical bytes may return on the public updater's hash check;
					// this does not establish that a reader was opened or remains usable.
					return
				}
				var exited *exec.ExitError
				if !errors.As(err, &exited) || exited.ExitCode() != 1 || !strings.Contains(string(output), "Can't load "+name) {
					t.Fatalf("expected isolated upstream fatal on %s %s: %v\n%s", old, name, err, output)
				}
				t.Fatalf("public upstream updater terminated on %s %s: %v\n%s", old, name, err, output)
			})
		}
	}
}

// Each reproduction keeps a fatal upstream reader inside its own process. A
// nonzero exit remains a failed test with the child's complete original output.
func upstreamGeoScenario(t *testing.T, run func()) {
	t.Helper()
	if os.Getenv("PSEUDO_UPSTREAM_GEO_SCENARIO") == t.Name() {
		run()
		return
	}
	cmd := exec.Command(os.Args[0], "-test.run=^"+regexp.QuoteMeta(t.Name())+"$")
	if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
		cmd.Args = append(cmd.Args, "-test.gocoverdir="+directory.Value.String())
	}
	cmd.Env = append(os.Environ(), "PSEUDO_UPSTREAM_GEO_SCENARIO="+t.Name())
	output, err := runUpstreamProcess(t, cmd)
	if err != nil {
		t.Fatalf("upstream Geo reproduction failed: %v\n%s", err, output)
	}
}

func TestUpstreamMaxMindBootstrapUsesNormalRoutingWithoutDirectFallback(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt"} {
			for _, route := range []string{"REJECT", "DIRECT"} {
				t.Run(name+"/"+old+"/"+route, func(t *testing.T) {
					upstreamGeoScenario(t, func() {
						var requests atomic.Int32
						changed := minimalMMDB()
						changed[len(changed)-1] = 6
						server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
							if requests.Add(1) == 1 {
								_, _ = writeUpstreamResponse(t, w, minimalMMDB())
							} else {
								_, _ = writeUpstreamResponse(t, w, changed)
							}
						}))
						defer server.Close()
						var e Engine
						home := t.TempDir()
						sources := fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
						if err := prepareUpstream(t, &e, home, []byte("mode: rule\nlog-level: silent\nrules: ['MATCH,"+route+"']\n"+sources), "rule", func(int) bool { return true }); err != nil {
							t.Fatal(err)
						}
						defer requireStop(t, &e)
						path := C.Path.MMDB()
						if name == "ASN" {
							path = C.Path.ASN()
						}
						previous := []byte("corrupt old database")
						if old == "corrupt" {
							if err := os.WriteFile(path, previous, 0600); err != nil {
								t.Fatal(err)
							}
						}
						if route == "REJECT" {
							for attempt := 1; attempt <= 2; attempt++ {
								if err := recordUpstreamCall(t, "UpdateResource-"+name, func() error { return e.UpdateResource("geo", name) }); err == nil {
									t.Fatalf("bootstrap %d bypassed MATCH,REJECT", attempt)
								}
								if requests.Load() != 0 {
									t.Fatal("bootstrap silently downloaded with DIRECT")
								}
								data, err := os.ReadFile(path)
								if old == "missing" && !os.IsNotExist(err) || old == "corrupt" && (err != nil || !bytes.Equal(data, previous)) {
									t.Fatalf("rejected bootstrap changed old data: %v", err)
								}
							}
							return
						}
						for _, want := range [][]byte{minimalMMDB(), changed} {
							if err := recordUpstreamCall(t, "UpdateResource-"+name, func() error { return e.UpdateResource("geo", name) }); err != nil {
								t.Fatalf("normal routing failed to update %s: %v", name, err)
							}
							if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, want) {
								t.Fatalf("normal routed update did not install its actual data: %v", err)
							}
						}
						if requests.Load() != 2 {
							t.Fatalf("bootstrap and ordinary update made %d requests, want two", requests.Load())
						}
					})
				})
			}
		}
	}
}

func TestUpstreamAutomaticGeoFollowsCoreTargetsAcrossSessions(t *testing.T) {
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
	upstreamGeoScenario(t, func() {
		var requests atomic.Int32
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			if r.URL.Path == "/GeoSite" {
				_, _ = writeUpstreamResponse(t, w, minimalGeoData)
			} else {
				_, _ = writeUpstreamResponse(t, w, minimalMMDB())
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
		if err := prepareUpstream(t, &e, home, []byte(body), "rule", func(int) bool { return true }); err != nil {
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
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
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
	})
}

func TestUpstreamGeoInitialCheckDoesNotLetUnrelatedFreshFileMaskDueResources(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	upstreamGeoScenario(t, func() {
		var requests [4]atomic.Int32
		var invalidASN atomic.Bool
		names := []string{"GeoIP", "MMDB", "ASN", "GeoSite"}
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			for i, name := range names {
				if r.URL.Path == "/"+name {
					requests[i].Add(1)
					if name == "ASN" && invalidASN.Load() {
						_, _ = writeUpstreamResponse(t, w, []byte("invalid ASN replacement"))
					} else if name == "GeoIP" || name == "GeoSite" {
						_, _ = writeUpstreamResponse(t, w, minimalGeoData)
					} else {
						_, _ = writeUpstreamResponse(t, w, minimalMMDB())
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
		if err := prepareUpstream(t, &e, home, []byte(body), "rule", func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		defer requireStop(t, &e)
		// 使用公开hot mode保持DIRECT下载路由，Geo target仍属于同一个context。
		if err := e.SetMode("direct"); err != nil {
			t.Fatal(err)
		}
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
		invalidASN.Store(true)
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err == nil {
			t.Fatal("invalid ASN update accepted")
		}
		assertRequests([4]int32{0, 1, 1, 0})
		invalidASN.Store(false)
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
			t.Fatal(err)
		}
		assertRequests([4]int32{0, 1, 2, 0})
		// An unchanged-content check makes that file fresh without claiming a rewrite.
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
			t.Fatal(err)
		}
		assertRequests([4]int32{0, 1, 2, 0})
		// Fresh contents are not parsed or repaired ahead of the configured interval.
		for _, i := range []int{1, 3} {
			if err := os.WriteFile(paths[i], []byte("corrupt fresh database"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
			t.Fatal(err)
		}
		assertRequests([4]int32{0, 1, 2, 0})
	})
}

func TestUpstreamMaxMindUpdatesValidateBeforeReplacingOldData(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt", "valid"} {
			t.Run(name+"/"+old, func(t *testing.T) {
				upstreamGeoScenario(t, func() {
					var valid atomic.Bool
					changed := minimalMMDB()
					changed[len(changed)-1] = 6 // A different valid database (IPv6).
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
						if valid.Load() {
							_, _ = writeUpstreamResponse(t, w, changed)
						} else {
							_, _ = writeUpstreamResponse(t, w, []byte("not a MaxMind database"))
						}
					}))
					defer server.Close()
					var e Engine
					body := validConfig + fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
					if err := prepareUpstream(t, &e, t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
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
					if err := recordUpstreamCall(t, "UpdateResource-"+name, func() error { return e.UpdateResource("geo", name) }); err == nil {
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
					if err := recordUpstreamCall(t, "UpdateResource-"+name, func() error { return e.UpdateResource("geo", name) }); err != nil {
						t.Fatal(err)
					}
					data, err = os.ReadFile(path)
					if err != nil || !bytes.Equal(data, changed) {
						t.Fatalf("valid replacement not installed: %v", err)
					}
				})
			})
		}
	}
}

func TestUpstreamRequiredGeoStartupAndAutomaticRefresh(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	if kind := os.Getenv("PSEUDO_REQUIRED_GEO_KIND"); kind != "" {
		var requests atomic.Int32
		var invalid atomic.Bool
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			requests.Add(1)
			if invalid.Load() {
				_, _ = writeUpstreamResponse(t, w, []byte("invalid replacement"))
				return
			}
			_, _ = writeUpstreamResponse(t, w, minimalMMDB())
		}))
		defer server.Close()
		var e Engine
		rule := "GEOIP,cn,DIRECT"
		if kind == "ASN" {
			rule = "IP-ASN,64500,DIRECT"
		} else if kind == "none" {
			rule = "MATCH,DIRECT"
		}
		rules := fmt.Sprintf("'%s'", rule)
		if os.Getenv("PSEUDO_REQUIRED_GEO_REJECT") == "1" {
			rules += ", 'MATCH,REJECT'"
		}
		body := fmt.Sprintf("mode: rule\nlog-level: silent\ngeodata-mode: false\ngeox-url: {mmdb: '%s', asn: '%s'}\nrules: [%s]\n", server.URL, server.URL, rules)
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
		if err := prepareUpstream(t, &e, home, []byte(body), "rule", func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		defer requireStop(t, &e)
		if kind == "none" {
			if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
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
		var rows coreview.ResourceList
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
		if fault := os.Getenv("PSEUDO_REQUIRED_GEO_DEFAULT_ROUTE"); fault != "" {
			// Reproduce the ordinary empty-proxy vehicle traversing the active Geo
			// matcher after its backing database is lost. Keep the original assertions
			// and child-process failure visible when the upstream reader terminates.
			if fault == "corrupt" {
				if err := os.WriteFile(path, []byte("corrupt database after Prepare"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			captureUpstreamFiles(t, "before-default-vehicle", home)
			vehicle := resource.NewHTTPVehicle(server.URL, path, "", nil, time.Second, 0)
			data, _, err := vehicle.Read(context.Background(), utils.HashType{})
			if os.Getenv("PSEUDO_REQUIRED_GEO_REJECT") == "1" {
				if err == nil || requests.Load() != 1 {
					t.Fatalf("default vehicle bypassed the active Geo/MATCH,REJECT route: requests=%d err=%v", requests.Load(), err)
				}
				updateErr := recordUpstreamCall(t, "UpdateResource-"+kind, func() error { return e.UpdateResource("geo", kind) })
				if updateErr == nil || requests.Load() != 1 {
					t.Fatalf("app repair bypassed the active Geo/MATCH,REJECT route: requests=%d err=%v", requests.Load(), updateErr)
				}
				previous, readErr := os.ReadFile(path)
				if fault == "missing" && !os.IsNotExist(readErr) || fault == "corrupt" && (readErr != nil || !bytes.Equal(previous, []byte("corrupt database after Prepare"))) {
					t.Fatalf("rejected repair changed its backing database: %v", readErr)
				}
				return
			}
			if err != nil || !bytes.Equal(data, minimalMMDB()) {
				t.Fatalf("default-routed %s download did not survive %s backing data: %v", kind, fault, err)
			}
			if requests.Load() != 2 {
				t.Fatalf("default vehicle did not make exactly one normally routed request: %d", requests.Load())
			}
			// Exercise the actual app operation too; a warm first lookup alone is
			// not a repair if UpdateResource closes/resets that route's reader.
			if err := recordUpstreamCall(t, "UpdateResource-"+kind, func() error { return e.UpdateResource("geo", kind) }); err != nil {
				t.Fatalf("active Geo route could not repair its own backing database: %v", err)
			}
			if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
				t.Fatalf("active-route repair did not install valid data: %v", err)
			}
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
			if data, _, err := vehicle.Read(context.Background(), utils.HashType{}); err != nil || !bytes.Equal(data, minimalMMDB()) {
				t.Fatalf("post-update default route lost its live reader after deletion: %v", err)
			}
			invalid.Store(true)
			updateErr := recordUpstreamCall(t, "UpdateResource-"+kind, func() error { return e.UpdateResource("geo", kind) })
			if updateErr == nil {
				t.Fatal("active-route repair accepted an invalid replacement")
			}
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Fatalf("invalid repair created a missing backing database: %v", err)
			}
			return
		}
		// 同一context丢失数据库后，直接登记公开scheduler，保留实际修复结果。
		if err := e.SetMode("direct"); err != nil {
			t.Fatal(err)
		}
		if err := recordUpstreamCall(t, "RegisterGeoUpdater", func() error {
			updater.SetGeoAutoUpdate(true)
			updater.SetGeoUpdateInterval(1)
			updater.RegisterGeoUpdater()
			return nil
		}); err != nil {
			t.Fatal(err)
		}
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
		e.updates.Wait()
		if requests.Load() != 2 {
			t.Fatalf("automatic update selected unexpected resources: %d", requests.Load())
		}
		invalid.Store(true)
		old := []byte("invalid old data retained until a valid replacement exists")
		if err := os.WriteFile(path, old, 0600); err != nil {
			t.Fatal(err)
		}
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
			t.Fatal(err)
		}
		if requests.Load() != 2 {
			t.Fatal("automatic update inspected and repaired fresh bytes ahead of the interval")
		}
		past := time.Now().Add(-2 * time.Hour)
		if err := os.Chtimes(path, past, past); err != nil {
			t.Fatal(err)
		}
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err == nil {
			t.Fatal("automatic updater accepted an invalid replacement")
		}
		if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, old) {
			t.Fatalf("automatic invalid response destroyed old bytes: %v", err)
		}
		invalid.Store(false)
		if err := recordUpstreamCall(t, "UpdateGeoDatabases", updater.UpdateGeoDatabases); err != nil {
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
		for _, routing := range []string{"normalRouting", "normalRoutingCorrupt", "defaultVehicleMissing", "defaultVehicleCorrupt", "defaultVehicleRejectedMissing", "defaultVehicleRejectedCorrupt"} {
			if kind == "none" && routing != "normalRouting" {
				continue
			}
			t.Run(kind+"/"+routing, func(t *testing.T) {
				cmd := exec.Command(os.Args[0], "-test.run=^TestUpstreamRequiredGeoStartupAndAutomaticRefresh$")
				if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
					cmd.Args = append(cmd.Args, "-test.gocoverdir="+directory.Value.String())
				}
				cmd.Env = append(os.Environ(), "PSEUDO_REQUIRED_GEO_KIND="+kind)
				if routing == "normalRoutingCorrupt" {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_CORRUPT=1")
				}
				if routing == "defaultVehicleMissing" || routing == "defaultVehicleRejectedMissing" {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_DEFAULT_ROUTE=missing")
				} else if routing == "defaultVehicleCorrupt" || routing == "defaultVehicleRejectedCorrupt" {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_DEFAULT_ROUTE=corrupt")
				}
				if strings.HasPrefix(routing, "defaultVehicleRejected") {
					cmd.Env = append(cmd.Env, "PSEUDO_REQUIRED_GEO_REJECT=1")
				}
				output, err := runUpstreamProcess(t, cmd)
				if err != nil {
					t.Fatalf("upstream %s route reproduction failed: %v\n%s", routing, err, output)
				}
			})
		}
	}
}

func TestUpstreamStopWaitsForMaxMindBootstrapInOriginalHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, name := range []string{"MMDB", "ASN"} {
		t.Run(name, func(t *testing.T) {
			upstreamGeoScenario(t, func() {
				started, release := make(chan struct{}), make(chan struct{})
				var once sync.Once
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					close(started)
					<-release
					_, _ = writeUpstreamResponse(t, w, minimalMMDB())
				}))
				defer server.Close()
				var e Engine
				body := validConfig + fmt.Sprintf("geox-url: {mmdb: '%s', asn: '%s'}\n", server.URL, server.URL)
				if err := prepareUpstream(t, &e, t.TempDir(), []byte(body), "rule", func(int) bool { return true }); err != nil {
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
				go func() {
					updated <- recordUpstreamCall(t, "UpdateResource-"+name, func() error { return e.UpdateResource("geo", name) })
				}()
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
				if err := prepareUpstream(t, &e, newHome, []byte(validConfig), "rule", func(int) bool { return true }); err == nil {
					t.Fatal("replacement context accepted before bootstrap returned")
				}
				once.Do(func() { close(release) })
				if err := <-updated; err != nil {
					t.Fatalf("completed bootstrap lost its actual success: %v", err)
				}
				if err := <-stopped; err != nil {
					t.Fatal(err)
				}
				if data, err := os.ReadFile(path); err != nil || !bytes.Equal(data, minimalMMDB()) {
					t.Fatalf("bootstrap did not finish in original home: %v", err)
				}
				requireFreshEngineProcess(t, newHome)
				newPath := filepath.Join(newHome, filepath.Base(path))
				if _, err := os.Stat(newPath); !os.IsNotExist(err) {
					t.Fatalf("bootstrap wrote into replacement home: %v", err)
				}
			})
		})
	}
}

func writeUpstreamResponse(t *testing.T, writer http.ResponseWriter, body []byte) (int, error) {
	upstreamEvidenceWrite(t, fmt.Sprintf("response-%03d.bin", upstreamEvidenceSequence.Add(1)), body)
	return writer.Write(body)
}

func upstreamEvidenceWrite(t *testing.T, name string, content []byte) {
	t.Helper()
	directory := os.Getenv("PSEUDO_UPSTREAM_EVIDENCE_CASE")
	if directory == "" {
		return
	}
	if err := os.WriteFile(filepath.Join(directory, name), content, 0600); err != nil {
		t.Fatal(err)
	}
}

func captureUpstreamFiles(t *testing.T, label, home string) {
	t.Helper()
	if os.Getenv("PSEUDO_UPSTREAM_EVIDENCE_CASE") == "" {
		return
	}
	paths := map[string]string{"cache.db": filepath.Join(home, "cache.db"), "GeoIP.dat": filepath.Join(home, "GeoIP.dat"), "Country.mmdb": filepath.Join(home, "Country.mmdb"), "ASN.mmdb": filepath.Join(home, "ASN.mmdb"), "GeoSite.dat": filepath.Join(home, "GeoSite.dat")}
	states := map[string]any{}
	for _, path := range geoFiles() {
		if filepath.Clean(filepath.Dir(path)) == filepath.Clean(home) {
			paths[filepath.Base(path)] = path
		}
	}
	for name, path := range paths {
		data, err := os.ReadFile(path)
		state := map[string]any{"path": path, "present": err == nil}
		if err != nil {
			state["error"] = err.Error()
		} else {
			upstreamEvidenceWrite(t, label+"-"+name, data)
			if info, statErr := os.Stat(path); statErr == nil {
				state["mtime"] = info.ModTime().Format(time.RFC3339Nano)
			}
		}
		states[name] = state
	}
	data, err := json.MarshalIndent(states, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	upstreamEvidenceWrite(t, label+"-files.json", data)
}

var upstreamEvidenceSequence atomic.Int64

func prepareUpstream(t *testing.T, e *Engine, home string, body []byte, mode string, protect func(int) bool) error {
	t.Helper()
	upstreamEvidenceWrite(t, "input.yaml", body)
	captureUpstreamFiles(t, "before-prepare", home)
	if info, ok := debug.ReadBuildInfo(); ok {
		upstreamEvidenceWrite(t, "version.txt", []byte(os.Getenv("PSEUDO_UPSTREAM_VERSION")+"\n"+info.String()))
	}
	return e.Prepare(home, body, mode, protect)
}

func recordUpstreamCall(t *testing.T, name string, call func() error) error {
	t.Helper()
	label := fmt.Sprintf("%02d-%s", upstreamEvidenceSequence.Add(1), name)
	upstreamEvidenceWrite(t, label+".call", []byte(name+"\n"))
	captureUpstreamFiles(t, label, C.Path.HomeDir())
	err := call()
	result := "success\n"
	if err != nil {
		result = err.Error() + "\n"
	}
	upstreamEvidenceWrite(t, label+".result", []byte(result))
	return err
}

func runUpstreamProcess(t *testing.T, command *exec.Cmd) ([]byte, error) {
	t.Helper()
	root := os.Getenv("PSEUDO_UPSTREAM_EVIDENCE")
	directory := ""
	if root != "" {
		if err := os.MkdirAll(root, 0700); err != nil {
			t.Fatal(err)
		}
		prefix := strings.NewReplacer("/", "__", "\\", "_", ":", "_").Replace(t.Name())
		var err error
		directory, err = os.MkdirTemp(root, prefix+"-")
		if err != nil {
			t.Fatal(err)
		}
		command.Env = append(command.Env, "PSEUDO_UPSTREAM_EVIDENCE_CASE="+directory)
	}
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	output := append(append([]byte{}, stdout.Bytes()...), stderr.Bytes()...)
	if directory != "" {
		code := 0
		if err != nil {
			code = -1
			if exited, ok := err.(*exec.ExitError); ok {
				code = exited.ExitCode()
			}
		}
		for name, data := range map[string][]byte{
			"stdout.log": stdout.Bytes(), "stderr.log": stderr.Bytes(),
			"exit":             []byte(fmt.Sprintf("%d\n", code)),
			"command.json":     mustUpstreamJSON(t, command.Args),
			"environment.json": mustUpstreamJSON(t, upstreamScenarioEnvironment(command.Env)),
		} {
			if writeErr := os.WriteFile(filepath.Join(directory, name), data, 0600); writeErr != nil {
				t.Fatal(writeErr)
			}
		}
	}
	return output, err
}

func upstreamScenarioEnvironment(environment []string) []string {
	var scenario []string
	for _, value := range environment {
		if strings.HasPrefix(value, "PSEUDO_") {
			scenario = append(scenario, value)
		}
	}
	return scenario
}

func mustUpstreamJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	return data
}
