package engine

import (
	"clashpseudo/native/internal/ingress"
	"encoding/json"
	"github.com/metacubex/mihomo/hub/executor"
	LC "github.com/metacubex/mihomo/listener/config"
)

func (e *Engine) RuntimeConfig() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	var tun any
	if held, ok := e.tun.(interface{ Config() LC.Tun }); ok {
		tun = held.Config()
	}
	body, err := json.Marshal(map[string]any{"general": executor.GetGeneral(), "requested": e.cfg.General, "actual": map[string]any{"tun": tun, "listeners": e.listenerStates.Snapshot()}})
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
