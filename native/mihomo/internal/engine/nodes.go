package engine

import (
	"clashpseudo/native/internal/coreview"
	"context"
	"errors"
)

func (e *Engine) StreamNodes(ctx context.Context, source *string, metadata, emit func(any) error) (string, error) {
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return "", ErrStopped
	}
	cfg, p, owner := e.cfg, e.provenance, e.owner
	sources := e.sources
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	identity := coreview.ProxySourceIdentity(cfg)
	if err := metadata(map[string]any{"source": identity}); err != nil {
		return identity, err
	}
	identity, err := coreview.StreamNodes(cfg, p, sources, source, func(row any) error {
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
func (e *Engine) StreamStrategies(ctx context.Context, metadata, emit func(any) error) (string, error) {
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return "", ErrStopped
	}
	cfg, p, owner := e.cfg, e.provenance, e.owner
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	identity := coreview.ProxySourceIdentity(cfg)
	if err := metadata(map[string]any{"source": identity, "mode": e.Mode(), "globalReferenced": coreview.GlobalReferenced(cfg)}); err != nil {
		return identity, err
	}
	identity, err := coreview.StreamGroups(cfg, p, func(row any) error {
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
