package engine

import (
	"fmt"
	"strings"
	"testing"

	"clashpseudo/native/internal/configinput"
)

func TestPreparationDoesNotUseDiagnosticIdentityAsAnInputGate(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for index, origin := range []configinput.ConfigOrigin{
		{ID: "main", Revision: 0},
		{Revision: 1},
		{Name: "name without identity"},
	} {
		t.Run(fmt.Sprint(index), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}

			var e Engine
			if err := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "", func(int) bool { return true }, PrepareOptions{
				Purpose: "PREVIEW", MainOrigin: origin,
			}, configinput.Override{Mode: "prepend", Body: "rules: []"}); err != nil {
				t.Fatalf("diagnostic identity blocked actual preparation: %+v: %v", origin, err)
			}
			if e.cfg == nil || !e.available() {
				t.Fatal("preparation did not retain an actual core")
			}
			requireStop(t, &e)
		})
	}
}

func TestPreparationLeavesUnknownTypesAndNamedValuesToTheCore(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for index, fixture := range []struct{ fields, failure string }{
		{fields: "proxies: null\nproxy-groups: null\n"},
		{fields: "proxy-groups: [{name: 2, type: select, proxies: [DIRECT]}]\n", failure: "proxy group 0: missing name"},
		{fields: "unknown: {1: value, duplicate: one, duplicate: two}\n"},
		{fields: "unknown: &same {duplicate: one, duplicate: two}\nunknown-copy: *same\n"},
		{fields: "unknown: &loop [*loop]\n"},
		{fields: "unknown: {<<: 3}\n"},
		{fields: "unknown: {? [one, two]: value}\n"},
		{fields: "unknown: " + strings.Repeat("[", 130) + "0" + strings.Repeat("]", 130) + "\n"},
	} {
		for _, overrides := range [][]configinput.Override{nil, {{Mode: "prepend", Body: "rules: []"}}} {
			t.Run(fmt.Sprint(index, "/", len(overrides)), func(t *testing.T) {
				if isolateEngineTest(t) {
					return
				}

				var e Engine
				body := fixture.fields + "geo-auto-update: false\nrules: ['MATCH,DIRECT']\n"
				err := e.Prepare(t.TempDir(), []byte(body), "", func(int) bool { return true }, overrides...)
				if fixture.failure != "" {
					if err == nil || err.Error() != fixture.failure {
						t.Fatalf("actual public parser error changed: %v", err)
					}
					if e.cfg != nil || e.owner != nil || e.failed || current.Load() != nil {
						t.Fatal("parser rejection retained or poisoned the session")
					}
				} else {
					if err != nil {
						t.Fatalf("app prevalidated a field accepted by the public parser: %q: %v", fixture.fields, err)
					}
					if e.cfg == nil || !e.available() {
						t.Fatal("preparation did not reach the actual core")
					}
				}
				requireStop(t, &e)
			})
		}
	}
}

func TestPreparationRejectsLegacyPurposeAndIncompleteRunningIdentity(t *testing.T) {
	for _, options := range []PrepareOptions{
		{Purpose: "VPN", Generation: 1, Composition: "legacy"},
		{Purpose: "RUNNING", VPNIntent: true, Composition: "generation-missing"},
		{Purpose: "RUNNING", VPNIntent: true, Generation: 1},
	} {
		var e Engine
		if err := e.PrepareWithOptions(t.TempDir(), []byte(validConfig), "rule", func(int) bool { return true }, options); err == nil {
			t.Fatal("无效运行身份或旧用途被接受", options)
		}
		if e.cfg != nil || e.owner != nil || current.Load() != nil {
			t.Fatal("无效preparation认领了context")
		}
	}
}
