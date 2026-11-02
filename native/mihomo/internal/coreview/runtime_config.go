package coreview

import (
	"encoding/json"
	"fmt"
	"io"
	"net"

	"github.com/metacubex/mihomo/config"
)

// RuntimeConfig keeps public core feedback separate from host-owned listeners.
func RuntimeConfig(cfg *config.Config, general *config.General, resources []io.Closer, ingressActive bool) (string, error) {
	controller := cfg.Controller
	configured := controller.ExternalController != "" || controller.ExternalControllerTLS != "" ||
		controller.ExternalControllerUnix != "" || controller.ExternalControllerPipe != "" || controller.ExternalUI != ""
	ingress := make([]map[string]string, 0, len(resources))
	for _, resource := range resources {
		item := map[string]string{"type": fmt.Sprintf("%T", resource)}
		switch listener := resource.(type) {
		case interface{ Addr() net.Addr }:
			item["address"] = listener.Addr().String()
		case interface{ LocalAddr() net.Addr }:
			item["address"] = listener.LocalAddr().String()
		case interface{ Address() string }:
			item["address"] = listener.Address()
		}
		ingress = append(ingress, item)
	}
	data, err := json.Marshal(struct {
		config.General
		IngressActive        bool                `json:"android-ingress-active"`
		Ingress              []map[string]string `json:"android-ingress"`
		ControllerConfigured bool                `json:"external-controller-configured"`
		ControllerActive     bool                `json:"external-controller-active"`
	}{General: *general, IngressActive: ingressActive,
		Ingress: ingress, ControllerConfigured: configured})
	return string(data), err
}
