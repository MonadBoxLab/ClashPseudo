//go:build linux && !android

package engine

import (
	"errors"
	"strings"
	"syscall"
	"testing"

	tun "github.com/metacubex/sing-tun"
)

func TestTunDNSModeReachesExternalFactories(t *testing.T) {
	for _, mode := range []string{"", "disabled", "native", "hijack"} {
		t.Run(mode, func(t *testing.T) {
			var e Engine
			prepareVPN(t, &e, "ipv6: false\ntun: {stack: mips, inet6-address: [], dns-mode: '"+mode+"'}\nrules: ['MATCH,DIRECT']\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			device := &ownedTestTun{fd: fd, replacement: -1}
			checkedDevice, checkedStack := false, false
			err = e.attach(fd, 1, tunFactories{
				device: func(options tun.Options) (tun.Tun, error) {
					checkedDevice = true
					if options.DNSMode != mode || options.AutoRoute || options.FileDescriptor != fd {
						t.Fatalf("external TUN options changed: %+v", options)
					}
					return device, nil
				},
				stack: func(_ string, options tun.StackOptions) (tun.Stack, error) {
					checkedStack = true
					if options.TunOptions.DNSMode != mode {
						t.Fatalf("stack DNS mode changed: %q", options.TunOptions.DNSMode)
					}
					return nil, errors.New("stop after checking DNS mode")
				},
			})
			if device.replacement >= 0 {
				defer syscall.Close(device.replacement)
			}
			if err == nil || !checkedDevice || !checkedStack || device.closes != 1 {
				t.Fatalf("DNS mode or descriptor ownership lost: device=%v stack=%v closes=%d err=%v", checkedDevice, checkedStack, device.closes, err)
			}
		})
	}
}

func TestInvalidTunDNSModeIsRejectedBeforeNativeAllocation(t *testing.T) {
	var e Engine
	err := e.PrepareWithOptions(t.TempDir(), []byte("tun: {dns-mode: invalid}\nrules: ['MATCH,DIRECT']\n"),
		"rule", nil, func(int) bool { return true }, PrepareOptions{Purpose: "VPN", Generation: 7, Composition: "test"})
	if err == nil || !strings.Contains(err.Error(), "tun.dns-mode") {
		t.Fatalf("invalid DNS mode accepted: %v", err)
	}
	if e.owner != nil || e.failed || current.Load() != nil {
		t.Fatal("invalid DNS mode allocated a native session")
	}
	prepareVPN(t, &e, validConfig)
}
