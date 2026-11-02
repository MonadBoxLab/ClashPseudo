package coreview

import (
	"io"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/hub/executor"
)

const globalReferenceConfig = "mode: rule\nfind-process-mode: off\nrules:\n  - MATCH,DIRECT\n"

func TestGlobalDefinitionReferences(t *testing.T) {
	for _, tc := range []struct {
		name, body string
		want       bool
	}{
		{"unreferenced", globalReferenceConfig, false},
		{"rule", strings.ReplaceAll(globalReferenceConfig, "MATCH,DIRECT", "MATCH,GLOBAL"), true},
		{"hidden-group", `proxy-groups:
  - {name: hidden, type: select, hidden: true, proxies: [GLOBAL]}
  - {name: GLOBAL, type: select, proxies: [DIRECT]}
rules: ['MATCH,DIRECT']
`, true},
		{"subrule-name", `sub-rules:
  GLOBAL:
    - MATCH,DIRECT
rules:
  - SUB-RULE,(NETWORK,TCP),GLOBAL
  - MATCH,DIRECT
`, false},
		{"unused-subrule-target", `sub-rules:
  unused:
    - MATCH,GLOBAL
rules:
  - MATCH,DIRECT
`, true},
		{"provider-node-named-global", `proxy-providers:
  fixture:
    type: inline
    payload:
      - {name: GLOBAL, type: socks5, server: 127.0.0.1, port: 9}
    health-check: {enable: false}
proxy-groups:
  - {name: choose, type: select, use: [fixture]}
rules:
  - MATCH,DIRECT
`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg, err := executor.ParseWithBytes([]byte(tc.body))
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				for _, provider := range cfg.Providers {
					if closer, ok := provider.(io.Closer); ok {
						if err := closer.Close(); err != nil {
							t.Error(err)
						}
					}
				}
				for _, proxy := range cfg.Proxies {
					if err := proxy.Close(); err != nil {
						t.Error(err)
					}
				}
			}()
			observations, err := StrategyGroups(cfg)
			if err != nil {
				t.Fatal(err)
			}
			if got := ReadStrategies(cfg, "rule", nil, nil, observations).GlobalReferenced; got != tc.want {
				t.Fatalf("referenced=%v, want=%v", got, tc.want)
			}
		})
	}
}
