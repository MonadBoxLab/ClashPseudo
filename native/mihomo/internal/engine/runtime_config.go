package engine

import (
	"clashpseudo/native/internal/ingress"
	"encoding/json"

	"github.com/metacubex/mihomo/hub/executor"
	"go.yaml.in/yaml/v3"
)

func (e *Engine) RuntimeConfig() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	body, err := json.Marshal(executor.GetGeneral())
	if err != nil {
		return "", err
	}
	var document yaml.Node
	if err := yaml.Unmarshal(body, &document); err != nil {
		return "", err
	}
	var block func(*yaml.Node)
	block = func(node *yaml.Node) {
		node.Style = 0
		for _, child := range node.Content {
			block(child)
		}
	}
	block(&document)
	body, err = yaml.Marshal(&document)
	return string(body), err
}
func (e *Engine) PreparationResult(attached bool) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	body, err := json.Marshal(struct {
		Prepared      bool                  `json:"prepared"`
		Attached      bool                  `json:"attached"`
		VPNIntent     bool                  `json:"vpnIntent"`
		LANIntent     bool                  `json:"lanIntent"`
		Specification any                   `json:"vpnSpec"`
		Listeners     []ingress.SocketState `json:"listeners"`
	}{e.cfg != nil, attached && e.tun != nil, e.options.VPNIntent, e.options.LANIntent, e.spec, e.listenerStates.Snapshot()})
	return string(body), err
}
