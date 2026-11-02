package coreview

import (
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	C "github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub/executor"
)

type nodeRawFixture struct {
	C.Proxy
	wire []byte
	err  error
}

func (p *nodeRawFixture) MarshalJSON() ([]byte, error) { return p.wire, p.err }

func TestNodeProjectionKeepsOriginalProxyMapAndMarshalFailure(t *testing.T) {
	cfg, err := executor.ParseWithBytes([]byte("proxies: [{name: raw-node, type: direct}]\nrules: ['MATCH,DIRECT']\n"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, proxy := range cfg.Proxies {
			if err := proxy.Close(); err != nil {
				t.Error(err)
			}
		}
	})
	wire := []byte(`{"name":"raw-node","future":{"zero":0,"disabled":false,"nullable":null,"empty":[],"text":"原文"}}`)
	proxy := &nodeRawFixture{Proxy: cfg.Proxies["raw-node"], wire: wire}
	cfg.Proxies["raw-node"] = proxy
	var raw json.RawMessage
	_, err = StreamNodes(cfg, nil, DiagnosticSources{}, nil, func(value any) error {
		row := value.(map[string]any)
		if row["name"] == "raw-node" {
			raw = row["raw"].(json.RawMessage)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected any
	if len(raw) == 0 {
		t.Fatal("node projection missing")
	}
	if err := json.Unmarshal(raw, &actual); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(wire, &expected); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatal("raw proxy map changed")
	}
	original := errors.New("original marshal failure 原文")
	proxy.err = original
	if _, err := StreamNodes(cfg, nil, DiagnosticSources{}, nil, func(any) error { return nil }); !errors.Is(err, original) {
		t.Fatal("original projection error was replaced", err)
	}
}
