package engine

import (
	"clashpseudo/native/internal/coreview"
	"context"
	"errors"
)

func (e *Engine) StreamRules(ctx context.Context, q coreview.RuleQuery, metadata, emit func(any) error) (string, error) {
	if err := q.Validate(); err != nil {
		return "", err
	}
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return "", ErrStopped
	}
	cfg, p, owner, sources := e.cfg, e.provenance, e.owner, e.sources
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	identity := coreview.RuleSourceIdentity(cfg, q)
	if err := metadata(map[string]any{"source": identity, "scopes": coreview.RuleScopes(cfg, p, sources), "origin": coreview.RuleOrigin(cfg, q)}); err != nil {
		return identity, err
	}
	identity, err := coreview.StreamRules(cfg, p, q, func(row any) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !owner.active.Load() {
			return ErrStopped
		}
		return emit(row)
	})
	if !owner.active.Load() {
		err = errors.Join(err, ErrStopped)
	}
	return identity, err
}
