package ingress

import (
	"errors"
	"os"
	"strings"
	"syscall"
	"testing"

	"clashpseudo/native/internal/configinput"
	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/tunnel"
)

func parsedTunOptions(t *testing.T, body string) LC.Tun {
	t.Helper()
	raw, _, err := configinput.Decode([]byte(body), "rule", "", true)
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := config.ParseRawConfig(raw)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for _, proxy := range cfg.Proxies {
			if err := proxy.Close(); err != nil {
				t.Error(err)
			}
		}
	})
	return cfg.General.Tun
}
func descriptorClosed(t *testing.T, fd int) {
	t.Helper()
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
		t.Fatalf("FD %d was not closed: %v", fd, err)
	}
}
func TestExternalDescriptorHandoffsDoNotCloseReusedNumber(t *testing.T) {
	for _, closedByPublic := range []bool{false, true} {
		options := parsedTunOptions(t, "ipv6: false\nrules: ['MATCH,DIRECT']\n")
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		replacement := -1
		original := errors.New("public constructor original cause")
		value, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
			if got.FileDescriptor != fd || got.AutoRoute || got.AutoDetectInterface || !sing_tun.EnforceBindInterface {
				t.Fatal("external FD platform parameters changed")
			}
			if closedByPublic {
				if err := syscall.Close(fd); err != nil {
					t.Fatal(err)
				}
				replacement, err = syscall.Open("/dev/null", syscall.O_RDWR, 0)
				if err != nil || replacement != fd {
					t.Fatal("test did not reuse the original FD", replacement, err)
				}
			}
			return nil, original
		})
		if value != nil || err != original || !uncertain {
			t.Fatal("construction error or unconfirmed FD ownership changed", value, err, uncertain)
		}
		var stat syscall.Stat_t
		if err := syscall.Fstat(fd, &stat); err != nil {
			t.Fatal("application guessed FD ownership after public construction failed and closed it again", err)
		}
		if replacement >= 0 {
			_ = syscall.Close(replacement)
		} else {
			_ = syscall.Close(fd)
		}
	}
}
func TestFourExplicitStacksReachPublicConstructorWithoutFallback(t *testing.T) {
	for _, name := range []string{"mips", "gvisor", "mixed", "system"} {
		t.Run(name, func(t *testing.T) {
			options := parsedTunOptions(t, "ipv6: false\ntun: {stack: "+name+", inet6-address: []}\nrules: ['MATCH,DIRECT']\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer syscall.Close(fd)
			calls := 0
			original := errors.New("selected public constructor failed")
			_, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
				calls++
				if !strings.EqualFold(got.Stack.String(), name) || got.MTU != 1500 {
					t.Fatal("public constructor did not receive the selected stack or MTU")
				}
				return nil, original
			})
			if calls != 1 || err != original || !uncertain {
				t.Fatal("another stack was retried after construction failed", calls, err)
			}
		})
	}
}
func TestTunDNSModeReachesPublicConstructor(t *testing.T) {
	for _, mode := range []string{"", "disabled", "native", "hijack"} {
		t.Run(mode, func(t *testing.T) {
			options := parsedTunOptions(t, "ipv6: false\ntun: {stack: mips, inet6-address: [], dns-mode: '"+mode+"'}\nrules: ['MATCH,DIRECT']\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			defer syscall.Close(fd)
			checked := false
			original := errors.New("public DNS mode check")
			_, err, _ = newTun(fd, options, tunnel.Tunnel, func(got LC.Tun, _ C.Tunnel) (*Tun, error) {
				checked = true
				if got.DNSMode != mode || got.FileDescriptor != fd {
					t.Fatal("DNS mode or FD changed")
				}
				return nil, original
			})
			if !checked || err != original {
				t.Fatal("call was not forwarded to the public constructor", err)
			}
		})
	}
}
func TestTunPublicConstructionAndStartErrorsKeepAllOriginalCauses(t *testing.T) {
	for _, phase := range []string{"construct", "start"} {
		options := parsedTunOptions(t, "ipv6: false\nrules: ['MATCH,DIRECT']\n")
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil {
			t.Fatal(err)
		}
		defer syscall.Close(fd)
		original := errors.New("public " + phase + " original cause")
		closeErr := errors.New("public close original cause")
		publicErr := errors.Join(original, closeErr)
		_, err, uncertain := newTun(fd, options, tunnel.Tunnel, func(LC.Tun, C.Tunnel) (*Tun, error) { return nil, publicErr })
		if err != publicErr || !errors.Is(err, original) || !errors.Is(err, closeErr) || !uncertain {
			t.Fatal("original construction, Start, or Close error was replaced", err)
		}
	}
}
func TestPublicTunExternalFDCloseAndMTUZero(t *testing.T) {
	pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(pair[1])
	if err = syscall.SetNonblock(pair[0], true); err != nil {
		t.Fatal(err)
	}
	options := parsedTunOptions(t, "ipv6: false\ntun: {stack: gvisor, mtu: 0}\nrules: ['MATCH,DIRECT']\n")
	value, err, uncertain := NewTun(pair[0], options, nil, tunnel.Tunnel)
	if err != nil || uncertain {
		t.Fatalf("public external FD construction failed: %v, cleanupUncertain=%t", err, uncertain)
	}
	if value.Config().MTU != 0 {
		t.Fatal("requested MTU 0 was rewritten by the application")
	}
	if err = value.Close(); err != nil {
		t.Fatal(err)
	}
	descriptorClosed(t, pair[0])
	replacement, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(replacement)
	if err = value.Close(); !errors.Is(err, os.ErrClosed) {
		t.Fatal("repeated public Close did not preserve the actual upstream error", err)
	}
	var stat syscall.Stat_t
	if err = syscall.Fstat(replacement, &stat); err != nil {
		t.Fatal("repeated Close closed a reused FD", err)
	}
}
