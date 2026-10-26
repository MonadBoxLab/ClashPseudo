package engine

import (
	"encoding/json"
	"errors"
	"net/url"
	"os"
	"time"

	"github.com/metacubex/mihomo/component/geodata"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/updater"
	C "github.com/metacubex/mihomo/constant"
	P "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"

	"clashpseudo/native/internal/configinput"
)

type Resource struct {
	Kind                  string     `json:"kind"`
	Name                  string     `json:"name"`
	VehicleType           string     `json:"vehicleType"`
	Source                string     `json:"source"`
	Count                 *int       `json:"count,omitempty"`
	Bytes                 int64      `json:"bytes,omitempty"`
	UpdatedAt             *time.Time `json:"updatedAt,omitempty"`
	UpdatedAtSource       string     `json:"updatedAtSource"`
	FileModifiedAt        *time.Time `json:"fileModifiedAt,omitempty"`
	AutoUpdate            *bool      `json:"autoUpdate,omitempty"`
	UpdateIntervalSeconds *int       `json:"updateIntervalSeconds,omitempty"`
	LastAttempt           *time.Time `json:"lastAttempt,omitempty"`
	LastResult            string     `json:"lastResult,omitempty"`
	LastSuccessfulCheck   *time.Time `json:"lastSuccessfulCheck,omitempty"`
	FileStatus            string     `json:"fileStatus,omitempty"`
	AutoUpdateTarget      *bool      `json:"autoUpdateTarget,omitempty"`
	Behavior              string     `json:"behavior,omitempty"`
	Format                string     `json:"format,omitempty"`
	UpdateSupported       bool       `json:"updateSupported"`
	// Keep definition origin and provider content URL as separate fields.
	Provenance *configinput.DefinitionProvenance `json:"provenance,omitempty"`
}

type ResourceList struct {
	Resources []Resource `json:"resources"`
}

// Expose only the source scheme and host in this diagnostic projection.
func redactSource(raw string) string {
	if raw == "" {
		return ""
	}
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Host == "" {
		return "[redacted]"
	}
	return parsed.Scheme + "://" + parsed.Host + "/…"
}

func (e *Engine) Resources() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	result := ResourceList{Resources: make([]Resource, 0)}
	names := make([]string, 0, len(e.cfg.Providers))
	for name := range e.cfg.Providers {
		names = append(names, name)
	}
	declaredSourceOrder(names, e.sources.proxyProviders)
	for _, name := range names {
		provider := e.cfg.Providers[name]
		if provider.VehicleType() == P.Compatible {
			continue
		}
		count := provider.Count()
		entry := Resource{Kind: "proxyProvider", Name: name, VehicleType: provider.VehicleType().String(),
			Source: redactSource(vehicleURL(provider)), Count: &count, UpdateSupported: provider.VehicleType() != P.Inline,
			Provenance: e.provenance.Definition("proxy-providers", name)}
		providerUpdatePolicy(&entry, provider.VehicleType(), e.sources.proxyIntervals[name])
		if fetcher, ok := provider.(interface{ UpdatedAt() time.Time }); ok {
			if updated := fetcher.UpdatedAt(); !updated.IsZero() {
				entry.UpdatedAt = &updated
				entry.UpdatedAtSource = "core-reported"
			}
		}
		result.Resources = append(result.Resources, entry)
	}
	rules := make([]string, 0, len(e.cfg.RuleProviders))
	for name := range e.cfg.RuleProviders {
		rules = append(rules, name)
	}
	declaredSourceOrder(rules, e.sources.ruleProviders)
	for _, name := range rules {
		provider := e.cfg.RuleProviders[name]
		count := provider.Count()
		entry := Resource{Kind: "ruleProvider", Name: name, VehicleType: provider.VehicleType().String(),
			Source: redactSource(vehicleURL(provider)), Count: &count,
			Behavior: provider.Behavior().String(), UpdateSupported: provider.VehicleType() != P.Inline,
			Provenance: e.provenance.Definition("rule-providers", name)}
		providerUpdatePolicy(&entry, provider.VehicleType(), e.sources.ruleIntervals[name])
		if source := e.ruleSources[name]; source.Format != "" {
			entry.Format = source.Format
		}
		if fetcher, ok := provider.(interface{ UpdatedAt() time.Time }); ok {
			if updated := fetcher.UpdatedAt(); !updated.IsZero() {
				entry.UpdatedAt = &updated
				entry.UpdatedAtSource = "core-reported"
			}
		}
		result.Resources = append(result.Resources, entry)
	}
	general := executor.GetGeneral()
	for _, item := range e.geoResourcesLocked() {
		target, automatic := item.autoUpdateTarget, general.GeoAutoUpdate
		interval := general.GeoUpdateInterval * 3600
		entry := Resource{Kind: "geo", Name: item.name, VehicleType: "File",
			Source: redactSource(item.source), AutoUpdateTarget: &target,
			AutoUpdate: &automatic, UpdateIntervalSeconds: &interval, UpdatedAtSource: "unknown",
			UpdateSupported: item.source != ""}
		state := e.geoUpdateStateLocked(item.name)
		entry.LastResult = state.LastResult
		if !state.LastAttempt.IsZero() {
			entry.LastAttempt = &state.LastAttempt
		}
		if !state.LastSuccessfulCheck.IsZero() {
			entry.LastSuccessfulCheck = &state.LastSuccessfulCheck
		}
		if info, err := os.Stat(item.path); err == nil && info.Mode().IsRegular() {
			entry.FileStatus = "present"
			entry.Bytes = info.Size()
			modified := info.ModTime()
			entry.FileModifiedAt = &modified
		} else if errors.Is(err, os.ErrNotExist) {
			entry.FileStatus = "missing"
		} else {
			entry.FileStatus = "unreadable"
		}
		result.Resources = append(result.Resources, entry)
	}
	data, err := json.Marshal(result)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func providerUpdatePolicy(entry *Resource, vehicle P.VehicleType, interval int) {
	entry.UpdatedAtSource = "unknown"
	if vehicle == P.HTTP || vehicle == P.File {
		automatic := vehicle == P.File || interval > 0
		entry.AutoUpdate = &automatic
	}
	if vehicle == P.HTTP {
		entry.UpdateIntervalSeconds = &interval
	}
}

func vehicleURL(value any) string {
	if fetched, ok := value.(interface{ Vehicle() P.Vehicle }); ok {
		return fetched.Vehicle().Url()
	}
	return ""
}

// DecodeResourceUpdate distinguishes an explicit empty provider name from a
// missing or null name. The update operation still validates kind and identity.
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
	return e.updateResource(kind, name, false)
}

func (e *Engine) updateResource(kind, name string, automaticGeo bool) error {
	if !automaticGeo && (len(name) > 512 || (kind == "geo" && name == "")) {
		return errors.New("invalid resource")
	}
	e.mu.Lock()
	if !e.available() {
		e.mu.Unlock()
		return ErrStopped
	}
	update, err := e.resourceUpdateLocked(kind, name, automaticGeo)
	if err != nil {
		e.mu.Unlock()
		return err
	}
	owner := e.owner
	// Register accepted updates and revoke admission under the same engine lock before
	// Stop waits.
	e.updates.Add(1)
	e.mu.Unlock()
	defer e.updates.Done()

	// Serialize manual and automatic updates in one queue; revalidate session/provider
	// ownership after waiting.
	e.updateMu.Lock()
	defer e.updateMu.Unlock()
	e.mu.Lock()
	active := e.owner == owner && e.available()
	e.mu.Unlock()
	if !active {
		return ErrStopped
	}
	err = update()
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.owner != owner || !e.available() {
		return ErrStopped
	}
	return err
}

// Select the public operation with e.mu held; release e.mu before invoking it.
func (e *Engine) resourceUpdateLocked(kind, name string, automaticGeo bool) (func() error, error) {
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
		if automaticGeo {
			// Follow the public core's process-wide update targets, including its
			// retained usage flags. Each target has its own due/validity check.
			type pendingGeo struct {
				resource geoResource
				update   func() error
			}
			var updates []pendingGeo
			for _, item := range e.geoResourcesLocked() {
				if !item.autoUpdateTarget {
					continue
				}
				update, err := e.resourceUpdateLocked("geo", item.name, false)
				if err != nil {
					return nil, err
				}
				updates = append(updates, pendingGeo{item, update})
			}
			owner := e.owner
			interval := time.Duration(e.cfg.General.GeoUpdateInterval) * time.Hour
			return func() error {
				var errs []error
				// Complete safe database repairs before routed downloads that may read other
				// MaxMind databases.
				for pass := 0; pass < 2; pass++ {
					if pass == 1 && errors.Join(errs...) != nil {
						return errors.Join(errs...)
					}
					for _, pending := range updates {
						e.mu.Lock()
						active := e.owner == owner && e.available()
						lastCheck := e.geoUpdateStateLocked(pending.resource.name).LastSuccessfulCheck
						e.mu.Unlock()
						if !active {
							return ErrStopped
						}
						repair := (pending.resource.name == "MMDB" || pending.resource.name == "ASN") && !mmdb.Verify(pending.resource.path)
						if (pass == 0) != repair {
							continue
						}
						if repair || geoResourceDue(pending.resource, interval, lastCheck, time.Now()) {
							errs = append(errs, pending.update())
						}
					}
				}
				return errors.Join(errs...)
			}, nil
		}
		switch name {
		case "GeoIP":
			if geodata.GeoIpUrl() != "" {
				return e.observeGeoUpdateLocked(name, updater.UpdateGeoIp), nil
			}
		case "MMDB":
			if geodata.MmdbUrl() != "" {
				return e.observeGeoUpdateLocked(name, func() error {
					return updateMaxMind(geodata.MmdbUrl(), C.Path.MMDB(), updater.UpdateMMDB, mmdb.ReloadIP)
				}), nil
			}
		case "GeoSite":
			if geodata.GeoSiteUrl() != "" {
				return e.observeGeoUpdateLocked(name, updater.UpdateGeoSite), nil
			}
		case "ASN":
			if geodata.ASNUrl() != "" {
				return e.observeGeoUpdateLocked(name, func() error {
					return updateMaxMind(geodata.ASNUrl(), C.Path.ASN(), updater.UpdateASN, mmdb.ReloadASN)
				}), nil
			}
		}
	}
	return nil, errors.New("invalid resource")
}
