package engine

import (
	"clashpseudo/native/internal/ingress"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/tunnel"
	"maps"
)

// workingConfig only changes the platform loading copy, preserving the requested configuration for diagnostics and the Builder specification.
func workingConfig(cfg *config.Config, preview bool) *config.Config {
	work := *cfg
	work.Listeners = maps.Clone(cfg.Listeners)
	general := *cfg.General
	general.Port, general.SocksPort, general.MixedPort = 0, 0, 0
	general.ShadowSocksConfig, general.VmessConfig = "", ""
	general.TuicServer.Enable, general.Tun.Enable = false, false
	work.General = &general
	dns := *cfg.DNS
	dns.Listen = ""
	work.DNS = &dns
	work.Tunnels = nil
	if preview {
		general.RedirPort, general.TProxyPort = 0, 0
		work.Listeners = nil
		ntp := *cfg.NTP
		ntp.Enable = false
		work.NTP = &ntp
		controller := *cfg.Controller
		controller.ExternalController, controller.ExternalControllerTLS = "", ""
		controller.ExternalControllerUnix, controller.ExternalControllerPipe = "", ""
		controller.ExternalDohServer = ""
		controller.ExternalUI, controller.ExternalUIURL, controller.ExternalUIName = "", "", ""
		work.Controller = &controller
		iptables := *cfg.IPTables
		iptables.Enable = false
		work.IPTables = &iptables
	}
	return &work
}
func (e *Engine) activateIngress() error {
	result := ingress.Activate(e.cfg, tunnel.Tunnel, ingress.Options{Protect: func(fd int) error { return e.owner.socket(fd, false) }, Observer: &e.listenerStates})
	if result.CleanupUncertain {
		e.failed = true
	}
	e.ingress = append(e.ingress, result.Resources...)
	return result.Err
}
