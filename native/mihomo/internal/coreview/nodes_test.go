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

func TestGroupsExportSelectionFieldsWithoutRawProxyJSON(t *testing.T) {
	cfg, err := executor.ParseWithBytes([]byte("proxy-groups: [{name: choice, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,DIRECT']\n"))
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
	cfg.Proxies["choice"] = &nodeRawFixture{
		Proxy: cfg.Proxies["choice"],
		err:   errors.New("must not export the full strategy group JSON"),
	}
	var actual map[string]any
	_, err = StreamGroups(cfg, nil, func(value any) error {
		row := value.(map[string]any)
		if _, exists := row["raw"]; exists {
			t.Fatal("strategy record still contains the full raw JSON")
		}
		if row["name"] == "choice" {
			actual = row
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if actual == nil || actual["type"] != "select" || actual["now"] != "DIRECT" || actual["fixed"] != "" || actual["hidden"] != false || actual["icon"] != "" {
		t.Fatal(actual)
	}
	members := actual["members"].([]map[string]string)
	if len(members) != 2 || members[0]["name"] != "DIRECT" || members[1]["name"] != "REJECT" || members[0]["identity"] != actual["currentIdentity"] || actual["sourceIdentity"] == "" {
		t.Fatal(actual)
	}
}

func TestNodeProjectionKeepsPublicFieldsAndMarshalFailure(t *testing.T) {
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
	wire := []byte(`{"name":"raw-node","type":"Direct","udp":true,"uot":false,"history":[{"time":"2026-01-01T00:00:00Z","delay":42}],"extra":{"https://example.test":{"alive":true,"history":[{"time":"2026-01-01T00:00:00Z","delay":43}]}},"password":"fixture-secret","future":{"text":"原文"}}`)
	proxy := &nodeRawFixture{Proxy: cfg.Proxies["raw-node"], wire: wire}
	cfg.Proxies["raw-node"] = proxy
	var row map[string]any
	_, err = StreamNodes(cfg, nil, DiagnosticSources{}, nil, func(value any) error {
		candidate := value.(map[string]any)
		if candidate["name"] == "raw-node" {
			row = candidate
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if row == nil || row["type"] != "Direct" || row["udp"] != true || row["uot"] != false {
		t.Fatal("node fields do not match", row)
	}
	for _, key := range []string{"raw", "password", "future"} {
		if _, exists := row[key]; exists {
			t.Fatalf("node contains unnecessary field %s", key)
		}
	}
	encoded, err := json.Marshal(row)
	if err != nil {
		t.Fatal(err)
	}
	var actual, expected map[string]any
	if err := json.Unmarshal(encoded, &actual); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(wire, &expected); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"history", "extra"} {
		if !reflect.DeepEqual(actual[key], expected[key]) {
			t.Fatalf("node delay history mismatch: %s", key)
		}
	}
	proxy.wire = []byte(`{not-json`)
	if _, err := StreamNodes(cfg, nil, DiagnosticSources{}, nil, func(any) error { return nil }); err == nil {
		t.Fatal("invalid node JSON did not return a decoding error")
	}
	original := errors.New("original marshal failure 原文")
	proxy.err = original
	if _, err := StreamNodes(cfg, nil, DiagnosticSources{}, nil, func(any) error { return nil }); !errors.Is(err, original) {
		t.Fatal("original projection error was replaced", err)
	}
}
