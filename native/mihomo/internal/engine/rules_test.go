package engine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"clashpseudo/native/internal/coreview"
	P "github.com/metacubex/mihomo/constant/provider"
	RP "github.com/metacubex/mihomo/rules/provider"
)

type ruleStreamSnapshot struct {
	Rows        []coreview.RuleRow
	Scopes      []coreview.RuleScope `json:"scopes"`
	Origin      string               `json:"origin"`
	SourceToken string               `json:"source"`
	Total       int
}

func readRulePage(t *testing.T, e *Engine, query coreview.RuleQuery) ruleStreamSnapshot {
	t.Helper()
	snapshot := ruleStreamSnapshot{Rows: make([]coreview.RuleRow, 0)}
	identity, err := e.StreamRules(context.Background(), query, func(value any) error {
		body, err := json.Marshal(value)
		if err != nil {
			return err
		}
		return json.Unmarshal(body, &snapshot)
	}, func(value any) error {
		row, ok := value.(coreview.RuleRow)
		if !ok {
			t.Fatal("未知rule record", value)
		}
		snapshot.Rows = append(snapshot.Rows, row)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if identity != snapshot.SourceToken {
		t.Fatal("metadata与terminal来源不一致")
	}
	snapshot.Total = len(snapshot.Rows)
	return snapshot
}

func TestRulesExposeMainSubrulesAndAllProviderBehaviors(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	body := []byte(`rule-providers:
 domains:
  type: inline
  behavior: domain
  payload: ['+.example.test', exact.test]
 networks:
  type: inline
  behavior: ipcidr
  payload: [192.0.2.0/24, '2001:db8::/32']
 classical:
  type: inline
  behavior: classical
  payload: ['DOMAIN-SUFFIX,example.test', 'NETWORK,UDP']
sub-rules:
 branch:
  - DOMAIN,sub.test,DIRECT
rules:
 - RULE-SET,domains,DIRECT
 - MATCH,DIRECT
`)
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	main := readRulePage(t, &e, coreview.RuleQuery{Kind: "main"})
	if main.Total != 2 || len(main.Scopes) != 5 || main.Rows[0].Index != 1 || main.Rows[0].Providers[0] != "domains" || main.Rows[1].Index != 2 {
		t.Fatal(main)
	}
	sub := readRulePage(t, &e, coreview.RuleQuery{Kind: "sub", Name: "branch"})
	if sub.Rows[0].Payload != "sub.test" || sub.Rows[0].Target != "DIRECT" {
		t.Fatal(sub)
	}
	for _, name := range []string{"domains", "networks", "classical"} {
		stream := readRulePage(t, &e, coreview.RuleQuery{Kind: "provider", Name: name})
		if stream.Total != 2 || stream.Origin != "inline-source" {
			t.Fatal(name, stream)
		}
	}
	again := readRulePage(t, &e, coreview.RuleQuery{Kind: "main"})
	if len(main.SourceToken) != 64 || again.SourceToken != main.SourceToken || sub.SourceToken == main.SourceToken {
		t.Fatal("rule来源identity改变")
	}
	original := errors.New("consumer原始错误")
	if _, err := e.StreamRules(context.Background(), coreview.RuleQuery{Kind: "main"}, func(any) error { return nil }, func(any) error { return original }); err != original {
		t.Fatal(err)
	}
	for _, query := range []coreview.RuleQuery{{Kind: "missing"}, {Kind: "sub", Name: "missing"}, {Kind: "provider", Name: "missing"}, {Kind: "provider", Name: strings.Repeat("x", 4097)}} {
		if _, err := e.StreamRules(context.Background(), query, func(any) error { return nil }, func(any) error { return nil }); err == nil {
			t.Fatal("无效scope被接受", query)
		}
	}

}

func TestRulesExpandFileMrsThroughPublicDump(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	for _, behavior := range []P.RuleBehavior{P.Domain, P.IPCIDR} {
		t.Run(behavior.String(), func(t *testing.T) {
			if isolateEngineTest(t) {
				return
			}
			home := t.TempDir()
			text := []byte("+.example.test\nexact.test\n")
			if behavior == P.IPCIDR {
				text = []byte("192.0.2.0/24\n2001:db8::/32\n")
			}
			var mrs bytes.Buffer
			if err := RP.ConvertToMrs(text, behavior, P.TextRule, &mrs); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(home, "fixture.mrs"), mrs.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			body := []byte("rule-providers:\n fixture:\n  type: file\n  behavior: " + strings.ToLower(behavior.String()) + "\n  format: mrs\n  path: fixture.mrs\nrules:\n - RULE-SET,fixture,DIRECT\n - MATCH,DIRECT\n")
			var e Engine
			if err := e.Prepare(home, body, "rule", func(int) bool { return true }); err != nil {
				t.Fatal(err)
			}
			defer requireStop(t, &e)
			page := readRulePage(t, &e, coreview.RuleQuery{Kind: "provider", Name: "fixture"})
			if page.Total != 2 || page.Origin != "normalized-rules" {
				t.Fatal(page)
			}
		})
	}
}

func TestRulesEmptyProviderNameRemainsAnExactScope(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	body := []byte("rule-providers:\n '': {type: inline, behavior: classical, payload: ['DOMAIN,empty-provider.test']}\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	page := readRulePage(t, &e, coreview.RuleQuery{Kind: "provider", Name: ""})
	if page.Origin != "inline-source" || page.Total != 1 || len(page.Rows) != 1 || page.Rows[0].Payload != "DOMAIN,empty-provider.test" {
		t.Fatalf("empty-name provider read as main scope: %+v", page)
	}
}

func TestRulesClassicalUsesOnlyPublicEnumeration(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	home := t.TempDir()
	path := filepath.Join(home, "rules.txt")
	if err := os.WriteFile(path, []byte("DOMAIN,one.test\nDOMAIN,two.test\n"), 0600); err != nil {
		t.Fatal(err)
	}
	var e Engine
	body := []byte("rule-providers:\n fixture:\n  type: file\n  behavior: classical\n  format: text\n  path: rules.txt\n  payload: ['DOMAIN,one.test', 'DOMAIN,two.test']\nrules: ['MATCH,DIRECT']\n")
	if err := e.Prepare(home, body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	for _, state := range []string{"present", "changed", "missing"} {
		if state == "changed" {
			if err := os.WriteFile(path, []byte("DOMAIN,changed.test\n"), 0600); err != nil {
				t.Fatal(err)
			}
		}
		if state == "missing" {
			if err := os.Remove(path); err != nil {
				t.Fatal(err)
			}
		}
		count := 0
		_, err := e.StreamRules(context.Background(), coreview.RuleQuery{Kind: "provider", Name: "fixture"}, func(any) error { return nil }, func(any) error { count++; return nil })
		if err == nil || !strings.Contains(err.Error(), "sourceUnavailable") || count != 0 {
			t.Fatal("使用了classical文件替代解析", state, count, err)
		}
	}
}
