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
	raw, presence, err := RunningDefaults(composed, "direct", "")
	if err != nil {
		t.Fatal(err)
	}
	upstream, err := config.UnmarshalRawConfig(composed)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(raw, upstream) {
		t.Fatal("显式字段被应用缺省覆盖")
	}
	if !presence.Has("tun.mtu") || !presence.Has("mode") {
		t.Fatal("合成字段的存在信息丢失")
	}
	raw, p, err := RunningDefaults([]byte("{}"), "", "")
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
		t.Fatal("除VPN需要的三个字段外，上游缺省也被修改")
	}
	if p.Has("tun.mtu") || p.Has("dns.enable") {
		t.Fatal("应用缺省被记为配置来源")
	}
}

func TestExplicitNullsKeepPublicRawConfigSemantics(t *testing.T) {
	for _, body := range []string{"tun: null\ndns: null\nprofile: null\n", "tun: {enable: null, mtu: null}\ndns: {enable: null}\nprofile: {store-selected: null}\n"} {
		raw, _, err := RunningDefaults([]byte(body), "global", "")
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if raw.Tun.Enable != upstream.Tun.Enable || raw.Tun.MTU != upstream.Tun.MTU || raw.DNS.Enable != upstream.DNS.Enable || raw.Profile != upstream.Profile {
			t.Fatal("显式null的上游语义被改变")
		}
	}
}
func TestDefaultMappingDoesNotMutateSavedSource(t *testing.T) {
	body := []byte("# preserved saved body\r\nmode: rule\r\n")
	before := bytes.Clone(body)
	if _, _, err := RunningDefaults(body, "direct", "global"); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(body, before) {
		t.Fatal("保存正文被修改")
	}
}
func TestRunningDefaultsOnlyUsesAnExplicitModeIntent(t *testing.T) {
	for _, tc := range []struct{ body, saved, operation, want string }{
		{"{}", "", "", "rule"}, {"{}", "direct", "", "direct"}, {"mode: global", "direct", "", "global"}, {"mode: global", "direct", "rule", "rule"}, {"{}", "", "direct", "direct"},
	} {
		raw, p, err := RunningDefaults([]byte(tc.body), tc.saved, tc.operation)
		if err != nil {
			t.Fatal(err)
		}
		if raw.Mode.String() != tc.want {
			t.Fatalf("mode=%s，期望%s", raw.Mode, tc.want)
		}
		upstream, _ := config.UnmarshalRawConfig([]byte(tc.body))
		if raw.Profile != upstream.Profile || p.Has("profile") || p.Has("mode") != (tc.body != "{}") {
			t.Fatal("operation或VPN缺省改变了profile和来源信息")
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
	raw, p, err := RunningDefaults(body, "", "")
	if err != nil {
		t.Fatal(err)
	}
	upstream.Tun.Enable = true
	upstream.Tun.MTU = 1500
	upstream.DNS.Enable = true
	if !bytes.Equal(before, body) || !reflect.DeepEqual(raw, upstream) || p.Has("mode") || p.Has("profile") {
		t.Fatal("无关字段或上游缺省被修改")
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
			raw, _, err := RunningDefaults(input, "", "")
			if err != nil {
				t.Fatal(err)
			}
			upstream.Tun.Enable = true
			upstream.Tun.MTU = 1500
			upstream.DNS.Enable = true
			if !bytes.Equal(input, before) || !reflect.DeepEqual(raw, upstream) {
				t.Fatal("应用改变了未知字段或公开解码结果")
			}
		}
	}
}
func TestRunningDefaultsUseInheritedPresenceWithoutChangingOtherAliases(t *testing.T) {
	for _, tun := range []string{"tun: *base\n", "tun: {<<: *base}\n", "<<: {tun: *base}\n"} {
		body := []byte("template: &base {enable: false, auto-route: false, dns-hijack: []}\n" + tun + "copy: *base\ndns: {enable: false}\n")
		before := bytes.Clone(body)
		raw, p, err := RunningDefaults(body, "", "")
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig(body)
		if err != nil {
			t.Fatal(err)
		}
		upstream.Tun.MTU = 1500
		if !reflect.DeepEqual(raw, upstream) || !bytes.Equal(body, before) || !p.Has("tun.enable") || !p.Has("tun.auto-route") || p.Has("tun.mtu") || p.Has("tun.stack") {
			t.Fatal("继承字段、alias或字段来源被改变")
		}
		var fields map[string]map[string]any
		if err := yaml.Unmarshal(body, &fields); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(fields["template"], fields["copy"]) || len(fields["copy"]) != 3 {
			t.Fatal("alias被缺省修改")
		}
	}
}
func TestRunningDefaultsReportThePublicDecodeErrorWithoutPrevalidation(t *testing.T) {
	for _, body := range []string{"[]", "dns: &loop [*loop]", "dns: {<<: 3}", "dns: ["} {
		_, original := config.UnmarshalRawConfig([]byte(body))
		if original == nil {
			t.Fatal("测试正文未触发公开解码错误")
		}
		if _, _, err := RunningDefaults([]byte(body), "", ""); err == nil || err.Error() != original.Error() {
			t.Fatalf("原始错误丢失：%v，期望%v", err, original)
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
		raw, _, err := RunningDefaults(input, "", "")
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig(before)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(input, before) || !reflect.DeepEqual(raw, upstream) {
			t.Fatal("无需补缺省时改变了正文或RawConfig")
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
		t.Fatal("PREVIEW补入了VPN缺省")
	}
}
