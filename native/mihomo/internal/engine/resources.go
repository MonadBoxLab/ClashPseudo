package engine

import (
	"context"
	"encoding/json"
	"errors"

	"clashpseudo/native/internal/coreipc"

	"clashpseudo/native/internal/coreview"
	"github.com/metacubex/mihomo/component/updater"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
)

func (e *Engine) Resources() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	geo := make([]coreview.GeoResource, 0, 4)
	for _, item := range e.geoResourcesLocked() {
		geo = append(geo, coreview.GeoResource{Name: item.name, Path: item.path, Source: item.source, AutoUpdateTarget: item.autoUpdateTarget})
	}
	return coreview.Resources(e.cfg, executor.GetGeneral(), e.sources, e.provenance, geo)
}

func (e *Engine) StreamResources(ctx context.Context, metadata, emit func(any) error) (string, error) {
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return "", ErrStopped
	}
	cfg, general, sources, provenance, owner := e.cfg, executor.GetGeneral(), e.sources, e.provenance, e.owner
	geo := make([]coreview.GeoResource, 0, 4)
	for _, item := range e.geoResourcesLocked() {
		geo = append(geo, coreview.GeoResource{Name: item.name, Path: item.path, Source: item.source, AutoUpdateTarget: item.autoUpdateTarget})
	}
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	identity := coreview.ResourceSourceIdentity(cfg)
	if err := metadata(map[string]any{"source": identity}); err != nil {
		return identity, err
	}
	identity, err := coreview.StreamResources(cfg, general, sources, provenance, geo, func(entry coreview.Resource) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		if !owner.active.Load() {
			return ErrStopped
		}
		return emit(entry)
	})
	if !owner.active.Load() {
		err = errors.Join(err, ErrStopped)
	}
	return identity, err
}

type ListenerCloseResult struct {
	Name   string         `json:"name"`
	Closed bool           `json:"closed"`
	Error  *coreipc.Error `json:"error"`
}

func (e *Engine) CloseListeners(names []string) []ListenerCloseResult {
	e.mu.Lock()
	defer e.mu.Unlock()
	results := make([]ListenerCloseResult, 0, len(names))
	for _, name := range names {
		var err error
		if !e.available() {
			err = ErrStopped
		} else {
			err = e.listenerStates.CloseListener(name)
		}
		results = append(results, ListenerCloseResult{Name: name, Closed: err == nil, Error: coreipc.Failure("callFailed", err)})
	}
	return results
}

func DecodeResourceUpdate(body []byte) (kind, name string, err error) {
	var request struct {
		Kind string  `json:"kind"`
		Name *string `json:"name"`
	}
	if len(body) == 0 || len(body) > 4<<10 || json.Unmarshal(body, &request) != nil || request.Name == nil {
		return "", "", errors.New("invalid resource update")
	}
	return request.Kind, *request.Name, nil
}
func (e *Engine) UpdateResource(kind, name string) error {
	if len(name) > 512 || (kind == "geo" && name == "") {
		return errors.New("invalid resource")
	}
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return ErrStopped
	}
	update, err := e.resourceUpdateLocked(kind, name)
	if err != nil {
		e.mu.Unlock()
		return err
	}
	owner := e.owner
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()
	e.updateMu.Lock()
	defer e.updateMu.Unlock()
	e.mu.Lock()
	active := e.owner == owner && e.available()
	e.mu.Unlock()
	if !active {
		return ErrStopped
	}
	return update()
}
func (e *Engine) resourceUpdateLocked(kind, name string) (func() error, error) {
	switch kind {
	case "proxyProvider":
		provider := e.cfg.Providers[name]
		if provider == nil {
			return nil, errors.New("resource is unavailable")
		}
		if provider.VehicleType() == P.Compatible || provider.VehicleType() == P.Inline {
			return nil, errors.New("resource has no external source")
		}
		return provider.Update, nil
	case "ruleProvider":
		provider := e.cfg.RuleProviders[name]
		if provider == nil {
			return nil, errors.New("resource is unavailable")
		}
		if provider.VehicleType() == P.Inline {
			return nil, errors.New("inline resource has no external source")
		}
		return provider.Update, nil
	case "geo":
		switch name {
		case "GeoIP":
			return updater.UpdateGeoIp, nil
		case "MMDB":
			return updater.UpdateMMDB, nil
		case "GeoSite":
			return updater.UpdateGeoSite, nil
		case "ASN":
			return updater.UpdateASN, nil
		}
	}
	return nil, errors.New("invalid resource")
}
