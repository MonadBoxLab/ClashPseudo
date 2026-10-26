package engine

import (
	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/hub/executor"
	"testing"
)

func TestPrepareAppliesOverridesBeforePlatformAndMode(t *testing.T) {
	var e Engine
	body := []byte("rules:\n - MATCH,DIRECT\ndns:\n enable: false\n")
	part := configinput.Override{ID: "part", Revision: 1, Mode: "replace", Body: `mode: global
mixed-port: 19876
external-controller: 127.0.0.1:19877
proxies:
 - name: composed-node
   type: direct
proxy-groups:
 - name: composed-group
   type: select
   proxies: [composed-node, DIRECT]
rules:
 - MATCH,composed-group
`}
	if err := e.Prepare(t.TempDir(), body, "direct", nil, func(int) bool { return true }, part); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	if e.cfg.Proxies["composed-node"] == nil || e.cfg.Proxies["composed-group"] == nil {
		t.Fatal("composed proxies were not loaded")
	}
	if e.Mode() != "global" {
		t.Fatal("ordinary preparation replaced the composed explicit mode with an application fallback")
	}
	if len(e.cfg.Rules) != 1 || e.cfg.Rules[0].Adapter() != "composed-group" {
		t.Fatal("composed rules were not applied")
	}
	general := executor.GetGeneral()
	if general.MixedPort != 0 || e.cfg.General.MixedPort != 19876 || e.cfg.DNS.Enable ||
		e.cfg.Controller.ExternalController != "127.0.0.1:19877" || len(e.ingress) != 0 {
		t.Fatal("preview did not preserve explicit configuration independently from unopened executor ingress")
	}
}

func TestComposeFailureDoesNotAllocateOrPoisonEngine(t *testing.T) {
	var e Engine
	home := t.TempDir()
	body := []byte("rules:\n - MATCH,DIRECT\n")
	part := configinput.Override{ID: "bad", Revision: 1, Mode: "replace", Body: "dns: ["}
	if err := e.Prepare(home, body, "rule", nil, func(int) bool { return true }, part); err == nil {
		t.Fatal("invalid fragment accepted")
	}
	if e.cfg != nil || e.owner != nil || e.failed {
		t.Fatal("composition failure changed resource ownership")
	}
	if err := e.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := e.Prepare(home, body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	requireStop(t, &e)
}
