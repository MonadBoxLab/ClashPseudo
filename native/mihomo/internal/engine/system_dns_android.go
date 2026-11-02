//go:build android && cmfa

package engine

import (
	"clashpseudo/native/internal/androidnet"
	"github.com/metacubex/mihomo/dns"
)

// 调用方只在进程唯一一次装载前执行，不在停止或网络变化时重写。
func initializeSystemDNS(network androidnet.NetworkDNS) error {
	servers, err := network.SystemServers()
	if err != nil {
		return err
	}
	dns.UpdateSystemDNS(servers)
	return nil
}
