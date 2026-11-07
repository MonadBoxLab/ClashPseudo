package configinput

import (
	"bytes"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/config"
	"go.yaml.in/yaml/v3"
)

func TestRunningDefaultsUseComposedPresenceNotDecodedZeroValues(t *testing.T) {
	body := []byte(`mode: global
tun: {enable: false, stack: system, mtu: 0, auto-route: false, dns-hijack: []}
dns: {enable: false, listen: '', nameserver: [], fake-ip-filter: []}
profile: {store-selected: true, store-fake-ip: true}
sniffer: {enable: true, sniff: {HTTP: {ports: [80], override-destination: false}}}
`)
	composed, err := Compose(body, []Override{{ID: "override", Revision: 1, Mode: "replace", Body: "tun: {stack: mixed}\n"}})
	if err != nil {
		t.Fatal(err)
	}
	raw, presence, err := Decode(composed, "direct", "", true)
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := config.UnmarshalRawConfig(composed)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(raw, upstream) {
		t.Fatal("explicit fields were overwritten by application defaults")
	}
	if !presence.Has("tun.mtu") || !presence.Has("mode") {
		t.Fatal("composed field presence information was lost")
	}
	raw, p, err := Decode([]byte("{}"), "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	upstream, err = config.UnmarshalRawConfig([]byte("{}"))
	if err != nil {
		t.Fatal(err)
	}
	upstream.Tun.Enable = true
	upstream.Tun.MTU = 1500
	upstream.DNS.Enable = true
	if !reflect.DeepEqual(raw, upstream) {
		t.Fatal("upstream defaults beyond the three fields required by VPN were changed")
	}
	if p.Has("tun.mtu") || p.Has("dns.enable") {
		t.Fatal("application defaults were recorded as configuration provenance")
	}
}

func TestExplicitNullsKeepPublicRawConfigSemantics(t *testing.T) {
	for _, body := range []string{"tun: null\ndns: null\nprofile: null\n", "tun: {enable: null, mtu: null}\ndns: {enable: null}\nprofile: {store-selected: null}\n"} {
		raw, _, err := Decode([]byte(body), "global", "", true)
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if raw.Tun.Enable != upstream.Tun.Enable || raw.Tun.MTU != upstream.Tun.MTU || raw.DNS.Enable != upstream.DNS.Enable || raw.Profile != upstream.Profile {
			t.Fatal("upstream semantics for explicit null were changed")
		}
	}
}
func TestDefaultMappingDoesNotMutateSavedSource(t *testing.T) {
	body := []byte("# preserved saved body\r\nmode: rule\r\n")
	before := bytes.Clone(body)
	if _, _, err := Decode(body, "direct", "global", true); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(body, before) {
		t.Fatal("saved body was modified")
	}
}
func TestRunningDefaultsOnlyUsesAnExplicitModeIntent(t *testing.T) {
	for _, tc := range []struct{ body, saved, operation, want string }{
		{"{}", "", "", "rule"}, {"{}", "direct", "", "direct"}, {"mode: global", "direct", "", "global"}, {"mode: global", "direct", "rule", "rule"}, {"{}", "", "direct", "direct"},
	} {
		raw, p, err := Decode([]byte(tc.body), tc.saved, tc.operation, true)
		if err != nil {
			t.Fatal(err)
		}
		if raw.Mode.String() != tc.want {
			t.Fatalf("mode=%s, want %s", raw.Mode, tc.want)
		}
		upstream, _ := config.UnmarshalRawConfig([]byte(tc.body))
		if raw.Profile != upstream.Profile || p.Has("profile") || p.Has("mode") != (tc.body != "{}") {
			t.Fatal("operation or VPN defaults changed the profile and provenance")
		}
	}
}
func TestRunningDefaultsPreservesUnrelatedNodeValuesDuringInjection(t *testing.T) {
	body := []byte(`unknown:
  timestamp: 2001-12-15T02:59:43.123456789Z
  binary: !!binary SGVsbG8=
  integer: 0x0f
  float: 1.2300
  tagged: !application-value original
  quoted: "001"
  empty: ~
  3: numeric key
`)
	before := bytes.Clone(body)
	upstream, err := config.UnmarshalRawConfig(body)
	if err != nil {
		t.Fatal(err)
	}
	raw, p, err := Decode(body, "", "", true)
	if err != nil {
		t.Fatal(err)
	}
	upstream.Tun.Enable = true
	upstream.Tun.MTU = 1500
	upstream.DNS.Enable = true
	if !bytes.Equal(before, body) || !reflect.DeepEqual(raw, upstream) || p.Has("mode") || p.Has("profile") {
		t.Fatal("unrelated fields or upstream defaults were changed")
	}
}
func TestRunningDefaultsLeaveUnknownReferenceValuesForTheCore(t *testing.T) {
	for _, field := range []string{"unknown: &loop [*loop]\n", "unknown: &same {duplicate: one, duplicate: two}\nunknown-copy: *same\n", "unknown: {<<: 3}\n", "unknown: {? [one, two]: value}\n"} {
		for _, complete := range []bool{false, true} {
			body := field
			if complete {
				body += "tun: {enable: true, stack: mips, mtu: 1500, auto-route: true}\ndns: {enable: true}\n"
			}
			input := []byte(body)
			before := bytes.Clone(input)
			upstream, err := config.UnmarshalRawConfig(input)
			if err != nil {
				t.Fatal(err)
			}
			raw, _, err := Decode(input, "", "", true)
			if err != nil {
				t.Fatal(err)
			}
			upstream.Tun.Enable = true
			upstream.Tun.MTU = 1500
			upstream.DNS.Enable = true
			if !bytes.Equal(input, before) || !reflect.DeepEqual(raw, upstream) {
				t.Fatal("application changed unknown fields or the public decoding result")
			}
		}
	}
}
func TestRunningDefaultsUseInheritedPresenceWithoutChangingOtherAliases(t *testing.T) {
	for _, tun := range []string{"tun: *base\n", "tun: {<<: *base}\n", "<<: {tun: *base}\n"} {
		body := []byte("template: &base {enable: false, auto-route: false, dns-hijack: []}\n" + tun + "copy: *base\ndns: {enable: false}\n")
		before := bytes.Clone(body)
		raw, p, err := Decode(body, "", "", true)
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig(body)
		if err != nil {
			t.Fatal(err)
		}
		upstream.Tun.MTU = 1500
		if !reflect.DeepEqual(raw, upstream) || !bytes.Equal(body, before) || !p.Has("tun.enable") || !p.Has("tun.auto-route") || p.Has("tun.mtu") || p.Has("tun.stack") {
			t.Fatal("inherited fields, aliases, or field provenance were changed")
		}
		var fields map[string]map[string]any
		if err := yaml.Unmarshal(body, &fields); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(fields["template"], fields["copy"]) || len(fields["copy"]) != 3 {
			t.Fatal("alias was modified by defaults")
		}
	}
}
func TestRunningDefaultsReportThePublicDecodeErrorWithoutPrevalidation(t *testing.T) {
	for _, body := range []string{"[]", "dns: &loop [*loop]", "dns: {<<: 3}", "dns: ["} {
		_, original := config.UnmarshalRawConfig([]byte(body))
		if original == nil {
			t.Fatal("test body did not trigger a public decoding error")
		}
		if _, _, err := Decode([]byte(body), "", "", true); err == nil || err.Error() != original.Error() {
			t.Fatalf("original error was lost: %v, want %v", err, original)
		}
	}
}
func TestRunningDefaultsKeepsOriginalBytesWhenNoInjectionIsNeeded(t *testing.T) {
	for _, body := range []string{
		"\xef\xbb\xbf# saved spelling and mixed line breaks\r\ntun: {enable: false, stack: system, mtu: 0, auto-route: false, dns-hijack: []}\ndns: {enable: false}\r\nprofile: {store-selected: true}\nunknown: !!str 001\r\n",
		"# explicit null containers\r\ntun: null\ndns: null\r\n", "tun: null\ndns: null\n---\nignored: [\n",
	} {
		input := []byte(body)
		before := bytes.Clone(input)
		raw, _, err := Decode(input, "", "", true)
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig(before)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(input, before) || !reflect.DeepEqual(raw, upstream) {
			t.Fatal("body or RawConfig changed when no defaults were needed")
		}
	}
}
func TestPreviewLeavesVPNDefaultsToTheCore(t *testing.T) {
	raw, p, err := Decode([]byte("{}"), "", "", false)
	if err != nil {
		t.Fatal(err)
	}
	upstream, _ := config.UnmarshalRawConfig([]byte("{}"))
	if !reflect.DeepEqual(raw, upstream) || p.Has("tun.enable") {
		t.Fatal("PREVIEW applied VPN defaults")
	}
}
