package engine

import "clashpseudo/native/internal/androidnet"

// 网络变化由AppRuntime替换内核进程，不热写resolver或上游system列表。
func (e *Engine) UpdateNetwork(network androidnet.NetworkDNS) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return `{"changed":false,"requiresRestart":false}`
	}
	if network.Key() != e.options.Network.Key() {
		return `{"changed":true,"requiresRestart":true}`
	}
	return `{"changed":false,"requiresRestart":false}`
}
