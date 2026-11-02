package androidnet

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/metacubex/mihomo/config"
	tun "github.com/metacubex/sing-tun"

	"clashpseudo/native/internal/configinput"
)

// PlatformError describes a capability not carried by the Android integration.
// Errors from public core calls retain their own messages.
type PlatformError struct{ Field, Reason string }

func (e *PlatformError) Error() string { return e.Field + ": " + e.Reason }
func (e *PlatformError) RawCause() any { return json.RawMessage(e.Message(e.Error())) }
func (e *PlatformError) Message(detail string) string {
	reason := "nativeReason" + strings.ToUpper(e.Reason[:1]) + e.Reason[1:]
	value, _ := json.Marshal(map[string]any{"id": "nativeConfigurationUnsupported", "detail": detail, "args": map[string]any{
		"field": e.Field, "reason": map[string]any{"id": reason, "args": map[string]any{}},
	}})
	return string(value)
}

func PlatformRuntime(r *config.RawConfig, p configinput.Presence) error {
	unsupported := func(field, reason string) error { return &PlatformError{Field: field, Reason: reason} }
	if !r.Tun.Enable {
		return unsupported("tun.enable", "tunDisabled")
	}
	switch r.Tun.DNSMode {
	case "", tun.DNSModeDisabled, tun.DNSModeNative, tun.DNSModeHijack:
	default:
		return errors.New("invalid tun.dns-mode")
	}
	if r.Tun.MTU > 65535 {
		return unsupported("tun.mtu", "invalidMtu")
	}
	checks := []struct {
		field     string
		requested bool
		reason    string
	}{
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
	if !r.DNS.Enable && (len(r.Tun.DNSHijack) != 0 || len(r.Tun.Inet6Address) != 0) {
		return unsupported("tun.dns-hijack", "dnsHijackConflict")
	}
	return nil
}
