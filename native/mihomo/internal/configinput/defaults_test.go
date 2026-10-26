package configinput

import (
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	"reflect"
	"testing"
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
	prepared, presence, err := RunningDefaults(composed, "direct", "")
	if err != nil {
		t.Fatal(err)
	}
	raw, err := config.UnmarshalRawConfig(prepared)
	if err != nil {
		t.Fatal(err)
	}
	if raw.Mode.String() != "global" || raw.Tun.Enable || raw.Tun.Stack != C.TunMixed || raw.Tun.MTU != 0 || raw.Tun.AutoRoute || len(raw.Tun.DNSHijack) != 0 || raw.DNS.Enable || raw.DNS.Listen != "" || len(raw.DNS.NameServer) != 0 || !raw.Profile.StoreSelected || !raw.Profile.StoreFakeIP || !raw.Sniffer.Enable || raw.Sniffer.Sniff["HTTP"].OverrideDest == nil || *raw.Sniffer.Sniff["HTTP"].OverrideDest {
		t.Fatalf("explicit composed values were changed: %+v", raw.Tun)
	}
	if !presence.Has("tun.mtu") || !presence.Has("mode") {
		t.Fatal("original presence lost")
	}
	prepared, p, err := RunningDefaults([]byte("{}"), "", "")
	if err != nil {
		t.Fatal(err)
	}
	raw, _ = config.UnmarshalRawConfig(prepared)
	if !raw.Tun.Enable || raw.Tun.Stack != C.TunMips || raw.Tun.MTU != 1500 || !raw.Tun.AutoRoute || !raw.DNS.Enable || raw.Profile.StoreSelected || raw.Mode.String() != "rule" || len(raw.Tun.DNSHijack) != 1 {
		t.Fatalf("missing required defaults: %+v", raw)
	}
	if p.Has("tun.mtu") || p.Has("dns.enable") {
		t.Fatal("platform defaults mislabelled as source fields")
	}
}

func TestExplicitNullsKeepPublicRawConfigSemantics(t *testing.T) {
	for _, body := range []string{"tun: null\ndns: null\nprofile: null\n", "tun: {enable: null, mtu: null}\ndns: {enable: null}\nprofile: {store-selected: null}\n"} {
		prepared, _, err := RunningDefaults([]byte(body), "global", "")
		if err != nil {
			t.Fatal(err)
		}
		raw, err := config.UnmarshalRawConfig(prepared)
		if err != nil {
			t.Fatal(err)
		}
		upstream, err := config.UnmarshalRawConfig([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		if raw.Tun.Enable != upstream.Tun.Enable || raw.Tun.MTU != upstream.Tun.MTU || raw.DNS.Enable != upstream.DNS.Enable || raw.Profile.StoreSelected != upstream.Profile.StoreSelected {
			t.Fatal("explicit null was replaced with application defaults")
		}
	}
}

func TestDefaultMappingDoesNotMutateSavedSource(t *testing.T) {
	body := []byte("# preserved saved body\r\nmode: rule\r\n")
	before := append([]byte(nil), body...)
	if _, _, err := RunningDefaults(body, "direct", "global"); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(before, body) {
		t.Fatal("saved source bytes changed")
	}
}
