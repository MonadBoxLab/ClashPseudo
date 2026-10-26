package engine

import (
	"encoding/json"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

func TestStrategyCurrentDelayIdentityMatchesBatchAndSurvivesRelease(t *testing.T) {
	var e Engine
	body := []byte("proxy-groups:\n - {name: choice, type: select, proxies: [REJECT, DIRECT]}\nrules:\n - MATCH,DIRECT\n")
	if err := e.Prepare(t.TempDir(), body, "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := e.Stop(); err != nil {
			t.Error(err)
		}
	})
	read := func() Strategy {
		t.Helper()
		body, err := e.Strategies()
		if err != nil {
			t.Fatal(err)
		}
		var snapshot Strategies
		if err := json.Unmarshal([]byte(body), &snapshot); err != nil {
			t.Fatal(err)
		}
		for _, group := range snapshot.Groups {
			if group.Name == "choice" {
				return group
			}
		}
		t.Fatal("missing group")
		return Strategy{}
	}
	before := read()
	if before.Now != "REJECT" || len(before.CurrentIdentity) != 64 {
		t.Fatalf("invalid initial observation: %+v", before)
	}
	id, err := e.StartDelayTest("choice", []string{"REJECT"})
	if err != nil {
		t.Fatal(err)
	}
	awaitDelayFixture(t, e.delays[id])
	batch := readDelayFixture(t, &e, id)
	if len(batch.Members) != 1 || batch.Members[0].Identity != before.CurrentIdentity {
		t.Fatalf("batch identity differs from current member: %+v", batch)
	}
	e.CancelDelayTest(id)
	if len(e.delays) != 0 || read().CurrentIdentity != before.CurrentIdentity {
		t.Fatal("releasing native test data changed a stable observation identity")
	}
	direct := "DIRECT"
	if err := e.SetStrategy("choice", Choice{Type: "select", Member: &direct}); err != nil {
		t.Fatal(err)
	}
	if read().CurrentIdentity == before.CurrentIdentity {
		t.Fatal("different current member retained the previous identity")
	}
}

func TestDelayObservationIdentityTracksProviderVersionAndSameNameObjects(t *testing.T) {
	leaf := &delayProxyFixture{name: "same"}
	provider := &delayProviderFixture{version: 1, members: []C.Proxy{leaf}}
	group := &delayProviderGroupFixture{providers: []P.ProxyProvider{provider}}
	root := &delayProxyFixture{name: "group", adapter: group}
	identity := func(member C.Proxy) string { return delayMemberIdentity(delaySourceIdentity(root), member) }
	first := identity(leaf)
	if len(first) != 64 || identity(leaf) != first {
		t.Fatal("stable sources need stable opaque identities")
	}
	provider.version++
	second := identity(leaf)
	if second == first {
		t.Fatal("provider version update retained the old observation")
	}
	group.providers = []P.ProxyProvider{&delayProviderFixture{version: 2, members: []C.Proxy{leaf}}}
	third := identity(leaf)
	if third == second {
		t.Fatal("same-version provider replacement retained the old observation")
	}
	if identity(&delayProxyFixture{name: "same"}) == third {
		t.Fatal("same-name member replacement retained the old observation")
	}
}
