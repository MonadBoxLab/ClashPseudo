//go:build !android || !cmfa

package engine

import "clashpseudo/native/internal/androidnet"

func initializeSystemDNS(network androidnet.NetworkDNS) error {
	_, err := network.SystemServers()
	return err
}
