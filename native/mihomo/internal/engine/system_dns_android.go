//go:build android && cmfa

package engine

import (
	"clashpseudo/native/internal/androidnet"
	"github.com/metacubex/mihomo/dns"
)

// The caller runs this only before the process's single load, never rewriting it on stop or network changes.
func initializeSystemDNS(network androidnet.NetworkDNS) error {
	servers, err := network.SystemServers()
	if err != nil {
		return err
	}
	dns.UpdateSystemDNS(servers)
	return nil
}
