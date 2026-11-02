package engine

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"clashpseudo/native/internal/configinput"
	"clashpseudo/native/internal/coreview"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
)

type nodeStreamRow struct {
	Kind               string                            `json:"kind"`
	Name               string                            `json:"name"`
	SourceKind         string                            `json:"sourceKind"`
	Source             string                            `json:"sourceName"`
	SourceVersion      uint32                            `json:"sourceVersion"`
	Raw                map[string]any                    `json:"raw"`
	Provenance         *configinput.DefinitionProvenance `json:"provenance"`
	ProviderProvenance *configinput.DefinitionProvenance `json:"providerProvenance"`
}

func readNodeStream(t *testing.T, e *Engine, source *string) ([]nodeStreamRow, string, error) {
	t.Helper()
	rows := make([]nodeStreamRow, 0)
	metadataSource := ""
	identity, err := e.StreamNodes(context.Background(), source, func(value any) error {
		body, err := json.Marshal(value)
		if err != nil {
			return err
		}
		var meta struct {
			Source string `json:"source"`
		}
		if err = json.Unmarshal(body, &meta); err != nil {
			return err
		}
		metadataSource = meta.Source
		return nil
	}, func(value any) error {
		body, err := json.Marshal(value)
		if err != nil {
			return err
		}
		var row nodeStreamRow
		if err = json.Unmarshal(body, &row); err != nil {
			return err
		}
		rows = append(rows, row)
		return nil
	})
	if identity != "" && identity != metadataSource {
		t.Error("metadata与terminal来源不一致", identity, metadataSource)
	}
	return rows, identity, err
}
func TestNodesIncludeProviderMembersAndExcludeGroups(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	body := []byte(`proxies:
 - {name: shared-name, type: direct}
proxy-providers:
 first:
  type: inline
  payload:
   - {name: shared-name, type: socks5, server: 127.0.0.1, port: 9, username: secret-user, password: secret-password}
 second:
  type: inline
  payload:
   - {name: shared-name, type: direct}
proxy-groups:
 - name: Group
   type: select
   proxies: [DIRECT, shared-name]
   use: [first, second]
rules:
 - MATCH,DIRECT
`)
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	rows, _, err := readNodeStream(t, &e, nil)
	if err != nil {
		t.Fatal(err)
	}
	sources := []string{}
	builtins := 0
	for _, row := range rows {
		if row.Name == "Group" || row.Name == "GLOBAL" {
			t.Fatal("group出现在node stream", row)
		}
		if row.SourceKind == "configuration" && row.Name != "shared-name" {
			builtins++
		}
		if row.Name != "shared-name" {
			continue
		}
		kind := "proxyProvider"
		var version uint32
		if row.Source == "" {
			kind = "configuration"
		} else {
			version = e.cfg.Providers[row.Source].Version()
		}
		if row.SourceKind != kind || row.SourceVersion != version {
			t.Fatal("来源或version改变", row)
		}
		sources = append(sources, row.Source)
	}
	if strings.Join(sources, ",") != ",first,second" || builtins != 6 {
		t.Fatal(sources, builtins)
	}
}
func TestNodeTestHistoryKeepsCompletePublicTarget(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer server.Close()
	var e Engine
	if err := e.Prepare(t.TempDir(), []byte("proxies: [{name: history-node, type: direct}]\nrules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	target := strings.Replace(server.URL, "http://", "http://fixture-user:fixture-password@", 1) + "/原文?token=fixture"
	proxy := e.cfg.Proxies["history-node"]
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, err := proxy.URLTest(ctx, target, delayExpected); err != nil {
		t.Fatal(err)
	}
	rows, _, err := readNodeStream(t, &e, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.Name == "history-node" {
			raw, err := proxy.MarshalJSON()
			if err != nil {
				t.Fatal(err)
			}
			var original map[string]any
			if err = json.Unmarshal(raw, &original); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(row.Raw, original) {
				t.Fatal("公开history或原始target改变", row.Raw, original)
			}
			extra, ok := row.Raw["extra"].(map[string]any)
			if !ok || extra[target] == nil {
				t.Fatal("完整公开target丢失", row.Raw)
			}
			return
		}
	}
	t.Fatal("缺少history-node")
}
func TestNodesExactProviderFilterKeepsAllMembersAndEmptyName(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	body := []byte(`proxies:
 - {name: shared-name, type: direct}
proxy-providers:
 '':
  type: inline
  payload:
   - {name: DIRECT, type: direct}
 alpha-extra:
  type: inline
  payload:
   - {name: shared-name, type: direct}
 alpha:
  type: inline
  payload:
   - {name: shared-name, type: direct}
   - {name: alpha-second, type: direct}
rules: ['MATCH,DIRECT']
`)
	if err := e.Prepare(t.TempDir(), body, "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	source := "alpha"
	rows, _, err := readNodeStream(t, &e, &source)
	if err != nil || len(rows) != 2 || rows[0].Name != "shared-name" || rows[1].Name != "alpha-second" {
		t.Fatal(rows, err)
	}
	for _, row := range rows {
		if row.Source != "alpha" {
			t.Fatal(row)
		}
	}
	unrelated := &nodeChangingProvider{version: 1, changeOnRead: true}
	e.cfg.Providers["unrelated"] = unrelated
	defer delete(e.cfg.Providers, "unrelated")
	if rows, _, err = readNodeStream(t, &e, &source); err != nil || len(rows) != 2 || unrelated.version != 1 {
		t.Fatal("精确来源读取了无关provider成员", rows, err)
	}
	source = ""
	rows, _, err = readNodeStream(t, &e, &source)
	if err != nil || len(rows) != 1 || rows[0].Name != "DIRECT" || rows[0].SourceKind != "proxyProvider" {
		t.Fatal(rows, err)
	}
	source = "missing"
	if _, _, err = readNodeStream(t, &e, &source); err == nil {
		t.Fatal("缺失provider被接受")
	}
	source = strings.Repeat("x", 4097)
	if _, _, err = readNodeStream(t, &e, &source); err == nil {
		t.Fatal("超长来源被接受")
	}
}

type nodeChangingProvider struct {
	P.ProxyProvider
	version      uint32
	changeOnRead bool
}

func (p *nodeChangingProvider) VehicleType() P.VehicleType { return P.Inline }
func (p *nodeChangingProvider) Version() uint32            { return p.version }
func (p *nodeChangingProvider) Proxies() []C.Proxy {
	if p.changeOnRead {
		p.version++
	}
	return nil
}
func TestNodeStreamRejectsProviderChangesAndStoppedOwner(t *testing.T) {
	if isolateEngineTest(t) {
		return
	}
	var e Engine
	if _, _, err := readNodeStream(t, &e, nil); !errors.Is(err, ErrStopped) {
		t.Fatal(err)
	}
	if err := e.Prepare(t.TempDir(), []byte("rules: ['MATCH,DIRECT']\n"), "rule", func(int) bool { return true }); err != nil {
		t.Fatal(err)
	}
	defer requireStop(t, &e)
	provider := &nodeChangingProvider{version: 1}
	e.cfg.Providers["changing"] = provider
	defer delete(e.cfg.Providers, "changing")
	_, before, err := readNodeStream(t, &e, nil)
	if err != nil {
		t.Fatal(err)
	}
	provider.version++
	_, after, err := readNodeStream(t, &e, nil)
	if err != nil || before == after {
		t.Fatal(before, after, err)
	}
	provider.changeOnRead = true
	if _, _, err = readNodeStream(t, &e, nil); !errors.Is(err, coreview.ErrNodesChanged) {
		t.Fatal(err)
	}
	original := errors.New("consumer原始错误")
	if _, err = e.StreamNodes(context.Background(), nil, func(any) error { return nil }, func(any) error { return original }); err != original {
		t.Fatal(err)
	}
}
