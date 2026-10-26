package engine

import (
	"github.com/metacubex/mihomo/tunnel"

	"clashpseudo/native/internal/configinput"
)

func (e *Engine) Mode() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return ""
	}
	return tunnel.Mode().String()
}

func (e *Engine) SetMode(value string) error {
	mode, err := configinput.ParseMode(value)
	if err != nil {
		return err
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return ErrStopped
	}
	// This lock serializes application lifecycle calls. Upstream routing reads require
	// their own synchronization.
	tunnel.SetMode(mode)
	e.cfg.General.Mode = mode
	return nil
}

func (e *Engine) available() bool {
	return e.cfg != nil && e.owner != nil && e.owner.active.Load() && !e.failed
}
