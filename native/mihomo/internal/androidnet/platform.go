package androidnet

import (
	"encoding/json"
	"errors"
	"strings"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
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

// PlatformRuntime clears desktop-only TUN fields that Android VpnService cannot honor.
// The saved configuration body is unchanged; only the loading copy is adjusted.
// Invalid values still fail; ignored field paths are returned for logging.
func PlatformRuntime(r *config.RawConfig, _ configinput.Presence) ([]string, error) {
	switch r.Tun.DNSMode {
	case "", tun.DNSModeDisabled, tun.DNSModeNative, tun.DNSModeHijack:
	default:
		return nil, errors.New("invalid tun.dns-mode")
	}
	if r.Tun.MTU > 65535 {
		return nil, &PlatformError{Field: "tun.mtu", Reason: "invalidMtu"}
	}
	if !r.DNS.Enable && (len(r.Tun.DNSHijack) != 0 || len(r.Tun.Inet6Address) != 0) {
		return nil, &PlatformError{Field: "tun.dns-hijack", Reason: "dnsHijackConflict"}
	}
	var ignored []string
	ignore := func(field string, clear func()) {
		ignored = append(ignored, field)
		clear()
	}
	if !r.Tun.Enable {
		ignore("tun.enable", func() { r.Tun.Enable = true })
	}
	if r.Tun.FileDescriptor != 0 {
		ignore("tun.file-descriptor", func() { r.Tun.FileDescriptor = 0 })
	}
	if r.Tun.Device != "" {
		ignore("tun.device", func() { r.Tun.Device = "" })
	}
	if r.Tun.GSO {
		ignore("tun.gso", func() { r.Tun.GSO = false })
	}
	if r.Tun.GSOMaxSize != 0 {
		ignore("tun.gso-max-size", func() { r.Tun.GSOMaxSize = 0 })
	}
	if r.Tun.AutoRedirect {
		ignore("tun.auto-redirect", func() { r.Tun.AutoRedirect = false })
	}
	if r.Tun.IPRoute2TableIndex != 0 {
		ignore("tun.iproute2-table-index", func() { r.Tun.IPRoute2TableIndex = 0 })
	}
	if r.Tun.IPRoute2RuleIndex != 0 {
		ignore("tun.iproute2-rule-index", func() { r.Tun.IPRoute2RuleIndex = 0 })
	}
	if r.Tun.AutoRedirectInputMark != 0 {
		ignore("tun.auto-redirect-input-mark", func() { r.Tun.AutoRedirectInputMark = 0 })
	}
	if r.Tun.AutoRedirectOutputMark != 0 {
		ignore("tun.auto-redirect-output-mark", func() { r.Tun.AutoRedirectOutputMark = 0 })
	}
	if r.Tun.AutoRedirectIPRoute2FallbackRuleIndex != 0 {
		ignore("tun.auto-redirect-iproute2-fallback-rule-index", func() { r.Tun.AutoRedirectIPRoute2FallbackRuleIndex = 0 })
	}
	if len(r.Tun.IncludeInterface) != 0 {
		ignore("tun.include-interface", func() { r.Tun.IncludeInterface = nil })
	}
	if len(r.Tun.ExcludeInterface) != 0 {
		ignore("tun.exclude-interface", func() { r.Tun.ExcludeInterface = nil })
	}
	if len(r.Tun.IncludeMACAddress) != 0 {
		ignore("tun.include-mac-address", func() { r.Tun.IncludeMACAddress = nil })
	}
	if len(r.Tun.ExcludeMACAddress) != 0 {
		ignore("tun.exclude-mac-address", func() { r.Tun.ExcludeMACAddress = nil })
	}
	if len(r.Tun.ExcludeSrcPort) != 0 || len(r.Tun.ExcludeSrcPortRange) != 0 {
		ignore("tun.exclude-src-port", func() {
			r.Tun.ExcludeSrcPort = nil
			r.Tun.ExcludeSrcPortRange = nil
		})
	}
	if len(r.Tun.ExcludeDstPort) != 0 || len(r.Tun.ExcludeDstPortRange) != 0 {
		ignore("tun.exclude-dst-port", func() {
			r.Tun.ExcludeDstPort = nil
			r.Tun.ExcludeDstPortRange = nil
		})
	}
	if r.Tun.StrictRoute {
		ignore("tun.strict-route", func() { r.Tun.StrictRoute = false })
	}
	// system/mixed need kernel forwarding and netlink; untrusted_app VpnService cannot
	// honor them, and construction can kill :core. Remap to the mihomo default stack.
	if r.Tun.Stack == C.TunSystem || r.Tun.Stack == C.TunMixed {
		ignore("tun.stack", func() { r.Tun.Stack = C.TunMips })
	}
	return ignored, nil
}
