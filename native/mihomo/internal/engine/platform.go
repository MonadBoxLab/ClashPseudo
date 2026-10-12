package engine

import (
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/component/process"
	"github.com/metacubex/mihomo/config"
)

// Android owns ingress and system integration. Only the decoded running copy is
// changed; the downloaded document remains untouched in the application store.
func configurePlatform(r *config.RawConfig, home string) error {
	r.Port, r.SocksPort, r.MixedPort, r.RedirPort, r.TProxyPort = 0, 0, 0, 0, 0
	r.ShadowSocksConfig, r.VmessConfig = "", ""
	r.ExternalController, r.ExternalControllerTLS = "", ""
	r.ExternalControllerUnix, r.ExternalControllerPipe = "", ""
	r.ExternalUI, r.ExternalUIURL, r.ExternalUIName, r.ExternalDohServer = "", "", "", ""
	r.Secret, r.Interface, r.RoutingMark = "", "", 0
	r.AllowLan, r.IPv6 = false, false
	r.FindProcessMode = process.FindProcessOff
	r.Tun = config.RawTun{}
	r.TuicServer = config.RawTuicServer{}
	r.TLS = config.RawTLS{}
	r.NTP.Enable, r.IPTables.Enable, r.GeoAutoUpdate = false, false, false
	r.Listeners, r.Tunnels = nil, nil
	r.DNS.Enable, r.DNS.IPv6, r.DNS.Listen = true, false, ""
	r.Profile.StoreSelected, r.Profile.StoreFakeIP = false, false

	for _, providers := range []map[string]map[string]any{r.ProxyProvider, r.RuleProvider} {
		for _, provider := range providers {
			switch provider["type"] {
			case "http":
				// mihomo derives a cache name from the URL when no path is supplied.
				delete(provider, "path")
			case "file":
				path, ok := provider["path"].(string)
				if !ok || !managedPath(home, path) {
					return errors.New("file provider must use the application's resource directory")
				}
			}
		}
	}
	return nil
}

func managedPath(home, path string) bool {
	root, err := filepath.EvalSymlinks(home)
	if err != nil || path == "" {
		return false
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	path = filepath.Clean(path)
	rel, err := filepath.Rel(root, path)
	if err != nil || !filepath.IsLocal(rel) {
		return false
	}
	// Check existing ancestors as well, so a missing child cannot hide a symlink.
	for {
		resolved, err := filepath.EvalSymlinks(path)
		if err == nil {
			rel, err = filepath.Rel(root, resolved)
			return err == nil && filepath.IsLocal(rel)
		}
		if !os.IsNotExist(err) || path == root || strings.HasSuffix(path, string(filepath.Separator)) {
			return false
		}
		path = filepath.Dir(path)
	}
}
