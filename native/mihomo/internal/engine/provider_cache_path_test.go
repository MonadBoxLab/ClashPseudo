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
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func providerInput(t *testing.T, namespace string, definition map[string]any, proxies ...map[string]any) []byte {
	t.Helper()
	section := "proxy-providers"
	if namespace == "rules" {
		section = "rule-providers"
	}
	body, err := json.Marshal(map[string]any{
		"geo-auto-update": false,
		"profile":         map[string]any{"store-selected": false},
		"dns":             map[string]any{"enable": false},
		"rules":           []string{"MATCH,DIRECT"},
		"proxies":         proxies,
		section:           map[string]any{"controlled": definition},
	})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func providerPath(t *testing.T, cfg *config.Config, namespace string) string {
	t.Helper()
	if namespace == "rules" {
		if cfg.RuleProviders["controlled"] == nil {
			t.Fatal("missing actual rule provider")
		}
		return providerVehiclePath(t, cfg.RuleProviders["controlled"])
	}
	if cfg.Providers["controlled"] == nil {
		t.Fatal("missing actual proxy provider")
	}
	return providerVehiclePath(t, cfg.Providers["controlled"])
}

func providerVehiclePath(t *testing.T, provider any) string {
	t.Helper()
	vehicle, ok := provider.(interface{ Vehicle() P.Vehicle })
	if !ok || vehicle.Vehicle() == nil {
		t.Fatalf("actual provider %T has no public vehicle", provider)
	}
	return vehicle.Vehicle().Path()
}

func providerText(namespace string) []byte {
	if namespace == "rules" {
		return []byte("payload: ['DOMAIN,fixture.test']\n")
	}
	return []byte("proxies: [{name: fixture, type: direct}]\n")
}

func TestHTTPProviderPathsUseThePublicParserAndPreparationHome(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, namespace := range []string{"proxies", "rules"} {
		content := providerText(namespace)
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write(content)
		}))
		for _, shape := range []string{"absent", "empty", "explicit"} {
			t.Run(namespace+"/"+shape, func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}
				home := t.TempDir()
				if filepath.Clean(home) == filepath.Clean(C.Path.HomeDir()) {
					t.Fatal("fixture must use a new preparation home")
				}
				definition := map[string]any{"type": "http", "url": server.URL, "interval": 0, "behavior": "classical"}
				want := filepath.Join(home, namespace, filepath.Base(C.Path.GetPathByHash(namespace, server.URL)))
				if shape == "empty" {
					definition["path"] = ""
				} else if shape == "explicit" {
					definition["path"] = "cache/explicit.yaml"
					want = filepath.Join(home, "cache/explicit.yaml")
				}
				body := providerInput(t, namespace, definition)
				before := bytes.Clone(body)
				var e Engine
				if err := e.Prepare(home, body, "", func(int) bool { return true }); err != nil {
					t.Fatal(err)
				}
				defer requireStop(t, &e)
				if got := providerPath(t, e.cfg, namespace); got != want {
					t.Fatalf("actual provider path = %q, want %q", got, want)
				}
				stored, err := os.ReadFile(want)
				if err != nil || !bytes.Equal(stored, content) || !bytes.Equal(body, before) {
					t.Fatalf("public provider cache or original input changed: %v", err)
				}
			})
		}
		server.Close()
	}
}

func TestFileProviderPathsHaveNoApplicationFilenameOrSymlinkBlacklist(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, namespace := range []string{"proxies", "rules"} {
		for _, name := range []string{
			"providers/explicit.yaml", "cache.db", "GeoIP.dat", "configurations.json",
			"tailscale/state", "identities/state", "tailscale-account/state",
			"../outside/provider.yaml", "absolute", "outside-link/provider.yaml", "inside-link/provider.yaml",
		} {
			t.Run(namespace+"/"+name, func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}
				parent := t.TempDir()
				home, outside := filepath.Join(parent, "core"), filepath.Join(parent, "outside")
				for _, directory := range []string{home, outside, filepath.Join(home, "inside")} {
					if err := os.MkdirAll(directory, 0700); err != nil {
						t.Fatal(err)
					}
				}
				for link, target := range map[string]string{"outside-link": outside, "inside-link": filepath.Join(home, "inside")} {
					if err := os.Symlink(target, filepath.Join(home, link)); err != nil {
						t.Fatal(err)
					}
				}
				path := name
				if name == "absolute" {
					path = filepath.Join(outside, "absolute.yaml")
				}
				want := path
				if !filepath.IsAbs(path) {
					want = filepath.Join(home, path)
				}
				if err := os.MkdirAll(filepath.Dir(want), 0700); err != nil {
					t.Fatal(err)
				}
				content := providerText(namespace)
				if err := os.WriteFile(want, content, 0600); err != nil {
					t.Fatal(err)
				}
				body := providerInput(t, namespace, map[string]any{"type": "file", "path": path, "behavior": "classical"})
				var e Engine
				if err := prepareUpstream(t, &e, home, body, "", func(int) bool { return true }); err != nil {
					t.Fatalf("application rejected a path accepted by production cmfa: %v", err)
				}
				if got := providerPath(t, e.cfg, namespace); got != want || !C.Path.IsSafePath(got) {
					t.Fatalf("path did not follow the public resolver: %q, want %q", got, want)
				}
				requireStop(t, &e)
				captureUpstreamFiles(t, "after-stop", home)
				stored, err := os.ReadFile(want)
				if err != nil || !bytes.Equal(stored, content) {
					t.Fatalf("reading a provider changed its original file: %v", err)
				}
			})
		}
	}
}

func TestProviderAndProtocolPathRelationshipsAreLeftToTheirOwners(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, namespace := range []string{"proxies", "rules"} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write(providerText(namespace))
		}))
		for _, shape := range []string{"absent", "empty", "explicit"} {
			for _, relationship := range []string{"same", "ancestor", "descendant", "sibling"} {
				t.Run(namespace+"/"+shape+"/"+relationship, func(t *testing.T) {
					if isolateEngineTest(t) {
						return
					}
					home := t.TempDir()
					cache := filepath.Join(namespace, filepath.Base(C.Path.GetPathByHash(namespace, server.URL)))
					if shape == "explicit" {
						cache = "logins/account-a"
					}
					identity := cache
					switch relationship {
					case "ancestor":
						identity = filepath.Dir(cache)
					case "descendant":
						identity = filepath.Join(cache, "identity")
					case "sibling":
						identity = cache + "-identity"
					}
					definition := map[string]any{"type": "http", "url": server.URL, "behavior": "classical"}
					if shape == "empty" {
						definition["path"] = ""
					} else if shape == "explicit" {
						definition["path"] = cache
					}
					body := providerInput(t, namespace, definition, map[string]any{"type": "tailscale", "name": "identity", "state-dir": identity})
					var e Engine
					if err := e.Prepare(home, body, "", func(int) bool { return true }); err != nil {
						t.Fatalf("application invented a provider/identity path conflict: %v", err)
					}
					defer requireStop(t, &e)
					if providerPath(t, e.cfg, namespace) != filepath.Join(home, cache) || e.cfg.Proxies["identity"].Type() != C.Tailscale {
						t.Fatal("provider path or protocol declaration was changed")
					}
				})
			}
		}
		server.Close()
	}
}

func TestProviderPathTypesKeepTheActualPublicParserResult(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, namespace := range []string{"proxies", "rules"} {
		for index, path := range []any{nil, false, 0, []any{}, map[string]any{"original": "原文🙂"}} {
			t.Run(namespace+"/"+fmt.Sprint(index), func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}
				home, phase := os.Getenv("PSEUDO_ENGINE_HOME"), os.Getenv("PSEUDO_ENGINE_PHASE")
				if phase == "" {
					home = t.TempDir()
					server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(providerText(namespace)) }))
					defer server.Close()
					for _, stage := range []string{"public", "application"} {
						runEnginePhase(t, home, stage, "PSEUDO_PROVIDER_PATH_URL="+server.URL)
					}
					return
				}
				body := providerInput(t, namespace, map[string]any{"type": "http", "url": os.Getenv("PSEUDO_PROVIDER_PATH_URL"), "path": path, "behavior": "classical"})
				resultPath := filepath.Join(home, "public-path-result.json")
				var expected struct{ Path, Error string }
				if phase == "public" {
					var paths Engine
					if _, err := paths.Paths(home); err != nil {
						t.Fatal(err)
					}
					raw, err := config.UnmarshalRawConfig(body)
					if err != nil {
						t.Fatal(err)
					}
					cfg, original := config.ParseRawConfig(raw)
					if original != nil {
						expected.Error = original.Error()
					} else {
						expected.Path = providerPath(t, cfg, namespace)
						baseline := Engine{cfg: cfg}
						requireStop(t, &baseline)
					}
					data, err := json.Marshal(expected)
					if err != nil {
						t.Fatal(err)
					}
					if err := os.WriteFile(resultPath, data, 0600); err != nil {
						t.Fatal(err)
					}
					return
				}
				data, err := os.ReadFile(resultPath)
				if err != nil {
					t.Fatal(err)
				}
				if err := json.Unmarshal(data, &expected); err != nil {
					t.Fatal(err)
				}
				var e Engine
				err = e.Prepare(home, body, "", func(int) bool { return true })
				defer requireStop(t, &e)
				if expected.Error != "" {
					if err == nil || !strings.Contains(err.Error(), expected.Error) {
						t.Fatalf("public path decode result changed for %v: %v; want %s", path, err, expected.Error)
					}
				} else if err != nil || providerPath(t, e.cfg, namespace) != expected.Path {
					t.Fatalf("publicly accepted path was rejected or rewritten: %v: %v", path, err)
				}
			})
		}
	}
}
