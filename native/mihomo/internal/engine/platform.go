package engine

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"

	"clashpseudo/native/internal/configinput"
)

// Only known field paths and reason IDs cross this application-owned error
// boundary. Arbitrary upstream parse errors keep the existing generic UI path.
type PlatformError struct{ Field, Reason string }

func (e *PlatformError) Error() string { return e.Field + ": " + e.Reason }
func (e *PlatformError) Message() string {
	reason := "nativeReason" + strings.ToUpper(e.Reason[:1]) + e.Reason[1:]
	value, _ := json.Marshal(map[string]any{"id": "nativeConfigurationUnsupported", "args": map[string]any{
		"field": e.Field, "reason": map[string]any{"id": reason, "args": map[string]any{}},
	}})
	return string(value)
}

// Adapt resource paths and validate runtime limitations separately; PREVIEW retains
// inspection of otherwise valid user configurations.
func configurePlatform(r *config.RawConfig, home string) error {
	identities := []string{"tailscale", "identities"}
	var inspect func(any) error
	inspect = func(value any) error {
		switch node := value.(type) {
		case map[string]any:
			if node["type"] == "tailscale" {
				path := "tailscale"
				if configured, ok := node["state-dir"].(string); ok && configured != "" {
					path = configured
				}
				_, target, ok := managedTarget(home, path)
				if !ok {
					return &PlatformError{Field: "proxies.state-dir", Reason: "providerPath"}
				}
				identities = append(identities, target)
			}
			for _, child := range node {
				if err := inspect(child); err != nil {
					return err
				}
			}
		case []any:
			for _, child := range node {
				if err := inspect(child); err != nil {
					return err
				}
			}
		}
		return nil
	}
	for _, proxy := range r.Proxy {
		if err := inspect(proxy); err != nil {
			return err
		}
	}
	for _, provider := range r.ProxyProvider {
		if err := inspect(provider["payload"]); err != nil {
			return err
		}
	}
	for index, providers := range []map[string]map[string]any{r.ProxyProvider, r.RuleProvider} {
		prefix := "proxies"
		if index == 1 {
			prefix = "rules"
		}
		for _, provider := range providers {
			kind, _ := provider["type"].(string)
			if kind != "file" && kind != "http" {
				continue
			}
			rawPath, provided := provider["path"]
			path, textPath := rawPath.(string)
			if kind == "http" && (!provided || textPath && path == "") {
				url, _ := provider["url"].(string)
				// The public parser derives a path only for absent/empty HTTP
				// paths. Its hash filename is independent of the old global home;
				// resolve that filename against this preparation's own home.
				path = filepath.Join(prefix, filepath.Base(C.Path.GetPathByHash(prefix, url)))
			} else if !textPath {
				return &PlatformError{Field: "provider.path", Reason: "providerPath"}
			}
			if !managedPath(home, path) {
				return &PlatformError{Field: "provider.path", Reason: "providerPath"}
			}
			_, target, _ := managedTarget(home, path)
			for _, identity := range identities {
				_, protected, ok := managedTarget(home, identity)
				if !ok || pathContains(protected, target) || pathContains(target, protected) {
					return &PlatformError{Field: "provider.path", Reason: "providerPath"}
				}
			}
		}
	}
	return nil
}

func platformRuntime(r *config.RawConfig, p configinput.Presence) error {
	unsupported := func(field, reason string) error { return &PlatformError{Field: field, Reason: reason} }
	if !r.Tun.Enable {
		return unsupported("tun.enable", "tunDisabled")
	}
	if r.Tun.MTU == 0 || r.Tun.MTU > 65535 {
		return unsupported("tun.mtu", "invalidMtu")
	}
	for _, listener := range r.Listeners {
		switch listener["type"] {
		case "tun":
			return unsupported("listeners.type", "externalFd")
		case "redir":
			return unsupported("listeners.type", "rootRedirection")
		case "tproxy":
			return unsupported("listeners.type", "transparentSockets")
		}
	}

	for _, controller := range []struct{ name, value string }{
		{"external-controller", r.ExternalController}, {"external-controller-tls", r.ExternalControllerTLS},
		{"external-controller-unix", r.ExternalControllerUnix}, {"external-controller-pipe", r.ExternalControllerPipe},
		{"external-ui", r.ExternalUI}, {"external-ui-name", r.ExternalUIName}, {"external-doh-server", r.ExternalDohServer},
	} {
		if controller.value != "" {
			return unsupported(controller.name, "controllerUnavailable")
		}
	}
	if p.Has("external-ui-url") && r.ExternalUIURL != "" {
		return unsupported("external-ui-url", "controllerUnavailable")
	}
	checks := []struct {
		field     string
		requested bool
		reason    string
	}{
		{"redir-port", r.RedirPort != 0, "rootRedirection"},
		{"tproxy-port", r.TProxyPort != 0, "transparentSockets"},
		{"interface-name", r.Interface != "", "interfaceBinding"},
		{"routing-mark", r.RoutingMark != 0, "routingMark"},
		{"iptables.enable", r.IPTables.Enable, "firewall"},
		{"ntp.write-to-system", r.NTP.Enable && r.NTP.WriteToSystem, "systemClock"},
		{"tun.file-descriptor", r.Tun.FileDescriptor != 0, "externalFd"},
		{"tun.device", r.Tun.Device != "", "interfaceName"},
		{"tun.gso", r.Tun.GSO, "gso"},
		{"tun.gso-max-size", r.Tun.GSOMaxSize != 0, "gso"},
		{"tun.auto-redirect", r.Tun.AutoRedirect, "autoRedirect"},
		{"tun.iproute2-table-index", r.Tun.IPRoute2TableIndex != 0, "linuxRouting"},
		{"tun.iproute2-rule-index", r.Tun.IPRoute2RuleIndex != 0, "linuxRouting"},
		{"tun.auto-redirect-input-mark", r.Tun.AutoRedirectInputMark != 0, "routingMark"},
		{"tun.auto-redirect-output-mark", r.Tun.AutoRedirectOutputMark != 0, "routingMark"},
		{"tun.auto-redirect-iproute2-fallback-rule-index", r.Tun.AutoRedirectIPRoute2FallbackRuleIndex != 0, "linuxRouting"},
		{"tun.include-interface", len(r.Tun.IncludeInterface) != 0, "interfaceFilter"},
		{"tun.exclude-interface", len(r.Tun.ExcludeInterface) != 0, "interfaceFilter"},
		{"tun.include-mac-address", len(r.Tun.IncludeMACAddress) != 0, "macFilter"},
		{"tun.exclude-mac-address", len(r.Tun.ExcludeMACAddress) != 0, "macFilter"},
		{"tun.exclude-src-port", len(r.Tun.ExcludeSrcPort) != 0 || len(r.Tun.ExcludeSrcPortRange) != 0, "portFilter"},
		{"tun.exclude-dst-port", len(r.Tun.ExcludeDstPort) != 0 || len(r.Tun.ExcludeDstPortRange) != 0, "portFilter"},
		{"tun.strict-route", r.Tun.StrictRoute, "strictRoute"},
	}
	for _, c := range checks {
		if c.requested {
			return unsupported(c.field, c.reason)
		}
	}
	if !r.DNS.Enable && len(r.Tun.DNSHijack) != 0 {
		return unsupported("tun.dns-hijack", "dnsHijackConflict")
	}
	return nil
}

func platformParsed(cfg *config.Config) error {
	checkProxy := func(proxy C.Proxy) error {
		info := proxy.Adapter().ProxyInfo()
		if info.Interface != "" {
			return &PlatformError{Field: "proxies.interface-name", Reason: "interfaceBinding"}
		}
		if info.RoutingMark != 0 {
			return &PlatformError{Field: "proxies.routing-mark", Reason: "routingMark"}
		}
		if info.TFO {
			return &PlatformError{Field: "proxies.tfo", Reason: "tcpFastOpen"}
		}
		return nil
	}
	for _, proxy := range cfg.Proxies {
		if err := checkProxy(proxy); err != nil {
			return err
		}
	}
	for _, provider := range cfg.Providers {
		for _, proxy := range provider.Proxies() {
			if err := checkProxy(proxy); err != nil {
				return err
			}
		}
	}
	for _, listener := range cfg.Listeners {
		if base := listenerBase(listener.Config()); base != nil && base.RoutingMark != 0 {
			return &PlatformError{Field: "listeners.routing-mark", Reason: "routingMark"}
		}
	}
	if cfg.DNS.Enable && cfg.DNS.Listen != "" && cfg.DNS.ListenRoutingMark != 0 {
		if _, port, err := net.SplitHostPort(cfg.DNS.Listen); err == nil && port != "" && port != "0" {
			return &PlatformError{Field: "dns.listen-routing-mark", Reason: "routingMark"}
		}
	}
	return nil
}

func pathContains(parent, child string) bool {
	rel, err := filepath.Rel(parent, child)
	return err == nil && filepath.IsLocal(rel)
}

// Resolve existing ancestors before appending absent children, then check the
// resulting identity-directory relationship.
func managedTarget(home, path string) (root, target string, ok bool) {
	root, err := filepath.EvalSymlinks(home)
	if err != nil || path == "" {
		return "", "", false
	}
	if !filepath.IsAbs(path) {
		path = filepath.Join(root, path)
	}
	path = filepath.Clean(path)
	if !pathContains(root, path) || path == root {
		return "", "", false
	}
	missing := []string{}
	for {
		resolved, err := filepath.EvalSymlinks(path)
		if err == nil {
			for i := len(missing) - 1; i >= 0; i-- {
				resolved = filepath.Join(resolved, missing[i])
			}
			return root, resolved, pathContains(root, resolved) && resolved != root
		}
		if !os.IsNotExist(err) || path == root {
			return "", "", false
		}
		missing = append(missing, filepath.Base(path))
		path = filepath.Dir(path)
	}
}

func managedPath(home, path string) bool {
	root, target, ok := managedTarget(home, path)
	if !ok {
		return false
	}
	rel, _ := filepath.Rel(root, target)
	first := strings.ToLower(strings.Split(rel, string(filepath.Separator))[0])
	switch first {
	case "tailscale", "identities", "cache.db", "cache.db.tmp", "config.yaml", "configurations.json", "overrides.json", "preferences.json", "geoip.dat", "geosite.dat", "country.mmdb", "asn.mmdb", "geoip.db", "geoip.metadb":
		return false
	}
	return !strings.HasPrefix(first, "tailscale-")
}
