package engine

import (
	"errors"

	"github.com/metacubex/mihomo/tunnel"
)

func parseMode(value string) (tunnel.TunnelMode, error) {
	switch value {
	case "rule":
		return tunnel.Rule, nil
	case "global":
		return tunnel.Global, nil
	case "direct":
		return tunnel.Direct, nil
	default:
		return tunnel.Rule, errors.New("invalid tunnel mode")
	}
}

func (e *Engine) Mode() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return ""
	}
	return tunnel.Mode().String()
}

func (e *Engine) SetMode(value string) error {
	mode, err := parseMode(value)
	if err != nil {
		return err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return ErrStopped
	}
	// This lock orders our lifecycle calls, not upstream routing goroutines.
	// v1.19.32's official SetMode still has unsynchronized traffic-side reads.
	tunnel.SetMode(mode)
	e.cfg.General.Mode = mode
	return nil
}

func (e *Engine) available() bool {
	return e.cfg != nil && e.owner != nil && e.owner.active.Load() && !e.failed
}
