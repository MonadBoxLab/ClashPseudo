package engine

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

func providerConfig(namespace string, definition map[string]any) *config.RawConfig {
	raw := &config.RawConfig{}
	if namespace == "proxies" {
		raw.ProxyProvider = map[string]map[string]any{"controlled": definition}
	} else {
		raw.RuleProvider = map[string]map[string]any{"controlled": definition}
	}
	return raw
}

func TestHTTPProviderCacheDefaultsUseThePreparationHomeWithoutChangingRawInput(t *testing.T) {
	for _, namespace := range []string{"proxies", "rules"} {
		for _, shape := range []string{"absent", "empty", "explicit"} {
			t.Run(namespace+"/"+shape, func(t *testing.T) {
				home := t.TempDir()
				if filepath.Clean(home) == filepath.Clean(C.Path.HomeDir()) {
					t.Fatal("fixture must use a different home from the old global path")
				}
				definition := map[string]any{"type": "http", "url": "http://fixture.invalid/controlled", "interval": 0}
				if shape == "empty" {
					definition["path"] = ""
				} else if shape == "explicit" {
					definition["path"] = "cache/explicit.yaml"
				}
				before, _ := json.Marshal(definition)
				if err := configurePlatform(providerConfig(namespace, definition), home); err != nil {
					t.Fatal(err)
				}
				after, _ := json.Marshal(definition)
				if string(before) != string(after) {
					t.Fatal("path validation rewrote an explicit or parser-derived input")
				}
				entries, err := os.ReadDir(home)
				if err != nil || len(entries) != 0 {
					t.Fatal("path validation created runtime resources")
				}
			})
		}
	}
}

func TestDerivedHTTPProviderPathCannotBorrowOrOverwriteTailscaleIdentity(t *testing.T) {
	for _, namespace := range []string{"proxies", "rules"} {
		for _, shape := range []string{"absent", "empty"} {
			for _, relationship := range []string{"same", "ancestor", "descendant", "sibling"} {
				t.Run(namespace+"/"+shape+"/"+relationship, func(t *testing.T) {
					home := t.TempDir()
					url := "http://fixture.invalid/controlled"
					cache := filepath.Join(namespace, filepath.Base(C.Path.GetPathByHash(namespace, url)))
					identity := cache
					switch relationship {
					case "ancestor":
						identity = namespace
					case "descendant":
						identity = filepath.Join(cache, "identity")
					case "sibling":
						identity = cache + "-identity"
					}
					definition := map[string]any{"type": "http", "url": url}
					if shape == "empty" {
						definition["path"] = ""
					}
					raw := providerConfig(namespace, definition)
					raw.Proxy = []map[string]any{{"type": "tailscale", "name": "Controlled identity", "state-dir": identity}}
					err := configurePlatform(raw, home)
					if relationship == "sibling" {
						if err != nil {
							t.Fatal("path prefix alone must not make unrelated siblings collide", err)
						}
					} else if err == nil {
						t.Fatal("the actual parser-derived cache could overwrite an identity")
					}
				})
			}
		}
	}
}

func TestHTTPDefaultPathFollowsActualAncestorsAndNeverDefaultsAnExplicitWrongType(t *testing.T) {
	for _, namespace := range []string{"proxies", "rules"} {
		t.Run(namespace+"/symlink", func(t *testing.T) {
			home, outside := t.TempDir(), t.TempDir()
			if err := os.Symlink(outside, filepath.Join(home, namespace)); err != nil {
				t.Fatal(err)
			}
			if err := configurePlatform(providerConfig(namespace, map[string]any{
				"type": "http", "url": "http://fixture.invalid/controlled",
			}), home); err == nil {
				t.Fatal("a default cache escaped through an existing symlink")
			}
		})
		for _, path := range []any{nil, false, 0, []any{}} {
			if err := configurePlatform(providerConfig(namespace, map[string]any{
				"type": "http", "url": "http://fixture.invalid/controlled", "path": path,
			}), t.TempDir()); err == nil {
				t.Fatal("an explicitly non-string path was replaced by a default")
			}
		}
	}
}
