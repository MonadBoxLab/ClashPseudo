package engine

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestConnectionStrategyUsesFullExactChain(t *testing.T) {
	var e Engine
	name := strings.Repeat("入口🌐", 80)
	config := "mixed-port: 0\nproxy-groups:\n  - name: '" + name + "'\n    type: select\n    hidden: true\n    icon: https://example.test/icon.svg?token=fixture\n    proxies: [DIRECT]\nrules: ['MATCH,DIRECT']\n"
	if err := e.Prepare(t.TempDir(), []byte(config), "rule", nil, func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	fixture := fixtureConnection(1)
	fixture.info.Chain = append(fixture.info.Chain, "DIRECT")
	for i := 0; i < 30; i++ {
		fixture.info.Chain = append(fixture.info.Chain, "not-a-group")
	}
	fixture.info.Chain = append(fixture.info.Chain, name)
	body, err := projectConnection(e.cfg.Proxies, fixture.ID(), fixture.info)
	if err != nil {
		t.Fatal(err)
	}
	var row connectionRow
	if err := json.Unmarshal(body, &row); err != nil {
		t.Fatal(err)
	}
	if row.Strategy == nil || row.Strategy.Type != "select" || row.Strategy.Icon != "https://example.test/icon.svg?token=fixture" {
		t.Fatalf("entry group lost before truncation: %+v", row.Strategy)
	}
	if !row.Truncated || len(row.Chains) != 16 || len(body) > maxConnectionRowBytes {
		t.Fatal("display budget changed")
	}
	bodyText, err := e.Strategies()
	if err != nil {
		t.Fatal(err)
	}
	var groups Strategies
	if err := json.Unmarshal([]byte(bodyText), &groups); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, group := range groups.Groups {
		if group.Name == name {
			found = group.Icon == row.Strategy.Icon && group.Hidden
		}
	}
	if !found {
		t.Fatal("strategy icon or hidden metadata missing")
	}
	fixture.info.Chain = []string{"DIRECT", "GLOBAL"}
	body, err = projectConnection(e.cfg.Proxies, fixture.ID(), fixture.info)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &row); err != nil {
		t.Fatal(err)
	}
	if row.Strategy == nil || row.Strategy.Type != "select" {
		t.Fatal("GLOBAL not resolved as real group")
	}
}

func TestConnectionStrategyIconBudget(t *testing.T) {
	for _, icon := range []string{
		"https://example.test/" + strings.Repeat("a", 1024),
		"https://example.test/" + strings.Repeat("&", 180),
	} {
		var e Engine
		config := "mixed-port: 0\nproxy-groups:\n  - name: entry\n    type: select\n    icon: '" + icon + "'\n    proxies: [DIRECT]\nrules: ['MATCH,DIRECT']\n"
		if err := e.Prepare(t.TempDir(), []byte(config), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		connection := fixtureConnection(3)
		connection.info.Chain = []string{"DIRECT", "entry"}
		body, err := projectConnection(e.cfg.Proxies, connection.ID(), connection.info)
		requireStop(t, &e)
		if err != nil {
			t.Fatal(err)
		}
		var row connectionRow
		if err := json.Unmarshal(body, &row); err != nil {
			t.Fatal(err)
		}
		if row.Strategy == nil || row.Strategy.Type != "select" || row.Strategy.Icon != "" || !row.Truncated {
			t.Fatal("oversized icon must be omitted whole while retaining type")
		}
		if len(body) > maxConnectionRowBytes {
			t.Fatal("icon exceeded row budget")
		}
	}
}

func TestConnectionStrategyFallbackDoesNotGuessNames(t *testing.T) {
	for _, fixture := range []struct{ chain, want string }{
		{"DIRECT", "Direct"}, {"REJECT", "Reject"}, {"REJECT-DROP", "Reject"}, {"node-DIRECT", ""},
	} {
		connection := fixtureConnection(2)
		connection.info.Chain = []string{fixture.chain}
		body, err := projectConnection(nil, connection.ID(), connection.info)
		if err != nil {
			t.Fatal(err)
		}
		var row connectionRow
		if err := json.Unmarshal(body, &row); err != nil {
			t.Fatal(err)
		}
		if fixture.want == "" {
			if row.Strategy != nil {
				t.Fatal("unknown name treated as type")
			}
		} else if row.Strategy == nil || row.Strategy.Type != fixture.want {
			t.Fatal("built-in fallback lost")
		}
	}
}
