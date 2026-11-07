package coreview

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"slices"
	"time"

	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/config"
	P "github.com/metacubex/mihomo/constant/provider"
)

type Resource struct {
	Kind                  string     `json:"kind"`
	Name                  string     `json:"name"`
	VehicleType           string     `json:"vehicleType"`
	Source                string     `json:"source"`
	Path                  string     `json:"path,omitempty"`
	Count                 *int       `json:"count,omitempty"`
	Bytes                 int64      `json:"bytes,omitempty"`
	UpdatedAt             *time.Time `json:"updatedAt,omitempty"`
	UpdatedAtSource       string     `json:"updatedAtSource"`
	FileModifiedAt        *time.Time `json:"fileModifiedAt,omitempty"`
	AutoUpdate            *bool      `json:"autoUpdate,omitempty"`
	UpdateIntervalSeconds *int       `json:"updateIntervalSeconds,omitempty"`
	LastAttempt           *time.Time `json:"lastAttempt,omitempty"`
	LastResult            string     `json:"lastResult,omitempty"`
	LastError             string     `json:"lastError,omitempty"`
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

// GeoResource carries the session's captured path, public update target and
// actual update observation. File metadata is read only for this response.
type GeoResource struct {
	Name, Path, Source string
	AutoUpdateTarget   bool
}

func ResourceSourceIdentity(cfg *config.Config) string {
	hash := sha256.New()
	fmt.Fprint(hash, ProxySourceIdentity(cfg))
	names := make([]string, 0, len(cfg.RuleProviders))
	for name := range cfg.RuleProviders {
		names = append(names, name)
	}
	slices.Sort(names)
	for _, name := range names {
		fmt.Fprint(hash, "/", RuleSourceIdentity(cfg, RuleQuery{Kind: "provider", Name: name}))
	}
	return hex.EncodeToString(hash.Sum(nil))
}

func Resources(cfg *config.Config, general *config.General, sources DiagnosticSources, provenance *configinput.Provenance, geo []GeoResource) (string, error) {
	result := ResourceList{Resources: make([]Resource, 0)}
	_, err := StreamResources(cfg, general, sources, provenance, geo, func(entry Resource) error {
		result.Resources = append(result.Resources, entry)
		return nil
	})
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(result)
	return string(data), err
}

// StreamResources reads public provider information and captured Geo paths one record at a time, without retaining resource history.
func StreamResources(cfg *config.Config, general *config.General, sources DiagnosticSources, provenance *configinput.Provenance, geo []GeoResource, emit func(Resource) error) (string, error) {
	identity := ResourceSourceIdentity(cfg)
	names := make([]string, 0, len(cfg.Providers))
	for name := range cfg.Providers {
		names = append(names, name)
	}
	declaredSourceOrder(names, sources.proxyProviders)
	for _, name := range names {
		provider := cfg.Providers[name]
		if provider.VehicleType() == P.Compatible {
			continue
		}
		count := provider.Count()
		entry := Resource{Kind: "proxyProvider", Name: name, VehicleType: provider.VehicleType().String(),
			Source: vehicleURL(provider), Path: vehiclePath(provider), Count: &count, UpdateSupported: provider.VehicleType() != P.Inline,
			Provenance: provenance.Definition("proxy-providers", name)}
		providerUpdatePolicy(&entry, provider.VehicleType(), sources.proxyIntervals[name])
		if fetcher, ok := provider.(interface{ UpdatedAt() time.Time }); ok {
			if updated := fetcher.UpdatedAt(); !updated.IsZero() {
				entry.UpdatedAt = &updated
				entry.UpdatedAtSource = "core-reported"
			}
		}
		if err := emit(entry); err != nil {
			return identity, err
		}
	}
	rules := make([]string, 0, len(cfg.RuleProviders))
	for name := range cfg.RuleProviders {
		rules = append(rules, name)
	}
	declaredSourceOrder(rules, sources.ruleProviders)
	for _, name := range rules {
		provider := cfg.RuleProviders[name]
		count := provider.Count()
		entry := Resource{Kind: "ruleProvider", Name: name, VehicleType: provider.VehicleType().String(),
			Source: vehicleURL(provider), Path: vehiclePath(provider), Count: &count,
			Behavior: provider.Behavior().String(), UpdateSupported: provider.VehicleType() != P.Inline,
			Provenance: provenance.Definition("rule-providers", name)}
		providerUpdatePolicy(&entry, provider.VehicleType(), sources.ruleIntervals[name])
		raw, err := json.Marshal(provider)
		if err != nil {
			return identity, err
		}
		var fields struct {
			Format string `json:"format"`
		}
		if err := json.Unmarshal(raw, &fields); err != nil {
			return identity, err
		}
		entry.Format = fields.Format
		if fetcher, ok := provider.(interface{ UpdatedAt() time.Time }); ok {
			if updated := fetcher.UpdatedAt(); !updated.IsZero() {
				entry.UpdatedAt = &updated
				entry.UpdatedAtSource = "core-reported"
			}
		}
		if err := emit(entry); err != nil {
			return identity, err
		}
	}
	for _, item := range geo {
		target, automatic := item.AutoUpdateTarget, general.GeoAutoUpdate
		interval := general.GeoUpdateInterval * 3600
		entry := Resource{Kind: "geo", Name: item.Name, VehicleType: "File",
			Source: item.Source, Path: item.Path, AutoUpdateTarget: &target,
			AutoUpdate: &automatic, UpdateIntervalSeconds: &interval, UpdatedAtSource: "unknown",
			UpdateSupported: item.Source != ""}
		if info, err := os.Stat(item.Path); err == nil && info.Mode().IsRegular() {
			entry.FileStatus = "present"
			entry.Bytes = info.Size()
			modified := info.ModTime()
			entry.FileModifiedAt = &modified
		} else if errors.Is(err, os.ErrNotExist) {
			entry.FileStatus = "missing"
		} else {
			entry.FileStatus = "unreadable"
		}
		if err := emit(entry); err != nil {
			return identity, err
		}
	}
	if ResourceSourceIdentity(cfg) != identity {
		return identity, RuleReadError("sourceChanged")
	}
	return identity, nil
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

func vehiclePath(value any) string {
	if fetched, ok := value.(interface{ Vehicle() P.Vehicle }); ok {
		return fetched.Vehicle().Path()
	}
	return ""
}

func vehicleURL(value any) string {
	if fetched, ok := value.(interface{ Vehicle() P.Vehicle }); ok {
		return fetched.Vehicle().Url()
	}
	return ""
}
