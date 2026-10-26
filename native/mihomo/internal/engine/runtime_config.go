package engine

import (
	"encoding/json"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub/executor"
)

// Expose live General plus session-owned ingress settings and activity state as
// runtime JSON.
func (e *Engine) RuntimeConfig() (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.available() {
		return "", ErrStopped
	}
	general := *executor.GetGeneral()
	general.Inbound = e.cfg.General.Inbound
	general = redactGeneral(general)
	controller := e.cfg.Controller
	configured := controller.ExternalController != "" || controller.ExternalControllerTLS != "" ||
		controller.ExternalControllerUnix != "" || controller.ExternalControllerPipe != "" || controller.ExternalUI != ""
	data, err := json.Marshal(struct {
		config.General
		IngressActive        bool `json:"android-ingress-active"`
		ControllerConfigured bool `json:"external-controller-configured"`
		ControllerActive     bool `json:"external-controller-active"`
	}{General: general, IngressActive: e.tun != nil, ControllerConfigured: configured})
	return string(data), err
}

// Copy before redacting: slices and maps returned by the core may be shared.
func redactGeneral(value config.General) config.General {
	value.Authentication = redactStrings(value.Authentication)
	value.ShadowSocksConfig = redactPresent(value.ShadowSocksConfig)
	value.VmessConfig = redactPresent(value.VmessConfig)
	value.TuicServer.Token = redactStrings(value.TuicServer.Token)
	if len(value.TuicServer.Users) != 0 {
		// Redact credential-bearing user IDs, including map keys.
		value.TuicServer.Users = map[string]string{"[redacted]": "[redacted]"}
	}
	value.TuicServer.Certificate = redactPresent(value.TuicServer.Certificate)
	value.TuicServer.PrivateKey = redactPresent(value.TuicServer.PrivateKey)
	value.TuicServer.ClientAuthCert = redactPresent(value.TuicServer.ClientAuthCert)
	value.TuicServer.EchKey = redactPresent(value.TuicServer.EchKey)
	// Even a host or path may contain a subscription identifier. Keep only
	// whether each source was configured, rather than guessing safe URL parts.
	value.GeoXUrl.GeoIp = redactPresent(value.GeoXUrl.GeoIp)
	value.GeoXUrl.GeoSite = redactPresent(value.GeoXUrl.GeoSite)
	value.GeoXUrl.Mmdb = redactPresent(value.GeoXUrl.Mmdb)
	value.GeoXUrl.ASN = redactPresent(value.GeoXUrl.ASN)
	return value
}

func redactPresent(value string) string {
	if value == "" {
		return ""
	}
	return "[redacted]"
}

func redactStrings(values []string) []string {
	if values == nil {
		return nil
	}
	result := make([]string, len(values))
	for index, value := range values {
		result[index] = redactPresent(value)
	}
	return result
}
