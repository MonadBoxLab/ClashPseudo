//go:build linux && !android

package engine

import (
	"errors"
	"flag"
	"os"
	"os/exec"
	"syscall"
	"testing"

	tun "github.com/metacubex/sing-tun"
)

func prepareVPN(t *testing.T, e *Engine, body string) {
	t.Helper()
	if err := e.PrepareWithOptions(t.TempDir(), []byte(body), "rule", nil, func(int) bool { return true }, PrepareOptions{Purpose: "VPN", Generation: 7, Composition: "test"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { requireStop(t, e) })
}

func descriptorClosed(t *testing.T, fd int) {
	t.Helper()
	var stat syscall.Stat_t
	if err := syscall.Fstat(fd, &stat); !errors.Is(err, syscall.EBADF) {
		t.Fatalf("descriptor %d not consumed: %v", fd, err)
	}
}

func TestInvalidTunParametersConsumeDescriptor(t *testing.T) {
	var e Engine
	prepareVPN(t, &e, validConfig)
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := e.Attach(fd, 99); err == nil {
		t.Fatal("stale specification revision accepted")
	}
	descriptorClosed(t, fd)
}

func TestZeroTunDescriptorIsRejectedAndConsumedInIsolatedProcess(t *testing.T) {
	const child = "PSEUDO_TEST_ZERO_TUN_FD"
	if os.Getenv(child) == "1" {
		if err := syscall.Close(0); err != nil && !errors.Is(err, syscall.EBADF) {
			t.Fatal(err)
		}
		fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
		if err != nil || fd != 0 {
			t.Fatalf("could not allocate descriptor zero: %d %v", fd, err)
		}
		var e Engine
		if err := e.Attach(fd, 1); err == nil {
			t.Fatal("reserved zero descriptor was accepted")
		}
		descriptorClosed(t, 0)
		return
	}
	command := exec.Command(os.Args[0], "-test.run=^TestZeroTunDescriptorIsRejectedAndConsumedInIsolatedProcess$", "-test.count=1")
	if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
		command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
	}
	command.Env = append(os.Environ(), child+"=1")
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("isolated zero-descriptor regression failed: %v\n%s", err, output)
	}
}

func TestAttachWithoutSessionConsumesDescriptor(t *testing.T) {
	fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	var e Engine
	if err := e.Attach(fd, 1); !errors.Is(err, ErrStopped) {
		t.Fatalf("unexpected attach result: %v", err)
	}
	descriptorClosed(t, fd)
}

type ownedTestTun struct{ fd, closes, replacement int }

func (d *ownedTestTun) Read([]byte) (int, error)    { return 0, os.ErrClosed }
func (d *ownedTestTun) Write(p []byte) (int, error) { return len(p), nil }
func (d *ownedTestTun) Close() error {
	d.closes++
	if err := syscall.Close(d.fd); err != nil {
		return err
	}
	var err error
	d.replacement, err = syscall.Open("/dev/null", syscall.O_RDWR, 0)
	return err
}

type ownedTestStack struct {
	starts, closes int
	fail           bool
	onStart        func()
}

func (s *ownedTestStack) Start() error {
	s.starts++
	if s.onStart != nil {
		s.onStart()
	}
	if s.fail {
		return errors.New("injected start failure")
	}
	return nil
}
func (s *ownedTestStack) Close() error { s.closes++; return nil }

func TestExternalDescriptorHandoffsCloseExactlyOnceAndDoNotCloseReusedNumber(t *testing.T) {
	for _, point := range []string{"device", "stack", "start", "success"} {
		t.Run(point, func(t *testing.T) {
			var e Engine
			prepareVPN(t, &e, validConfig)
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			device := &ownedTestTun{fd: fd, replacement: -1}
			stack := &ownedTestStack{fail: point == "start"}
			stack.onStart = func() {
				owned, ok := e.tun.(*externalTun)
				if !ok || owned.stack != stack || owned.device != device {
					t.Fatal("returned stack/device were not registered before Start")
				}
			}
			factories := tunFactories{device: func(options tun.Options) (tun.Tun, error) {
				if options.FileDescriptor != fd || options.AutoRoute {
					t.Fatal("external FD entered native system routing")
				}
				if point == "device" {
					return nil, errors.New("injected device failure")
				}
				return device, nil
			}, stack: func(name string, options tun.StackOptions) (tun.Stack, error) {
				if name != "mips" {
					t.Fatalf("default stack %q", name)
				}
				if point == "stack" {
					return nil, errors.New("injected stack construction failure")
				}
				return stack, nil
			}}
			err = e.attach(fd, 1, factories)
			if point == "success" {
				if err != nil {
					t.Fatal(err)
				}
				requireStop(t, &e)
			} else if err == nil {
				t.Fatal("injected failure accepted")
			}
			if point == "device" {
				descriptorClosed(t, fd)
				if device.closes != 0 {
					t.Fatal("unreturned device was closed")
				}
				return
			}
			if device.closes != 1 {
				t.Fatalf("device closed %d times", device.closes)
			}
			wantStackClose := 1
			if point == "stack" {
				wantStackClose = 0
			}
			if stack.closes != wantStackClose {
				t.Fatalf("stack closed %d times", stack.closes)
			}
			if device.replacement != fd {
				t.Fatalf("test did not reuse descriptor number %d: got %d", fd, device.replacement)
			}
			defer syscall.Close(device.replacement)
			var stat syscall.Stat_t
			if err := syscall.Fstat(device.replacement, &stat); err != nil {
				t.Fatalf("raw guard double-closed reused number: %v", err)
			}
		})
	}
}

func TestFourExplicitStacksReachExternalFactoryWithoutFallback(t *testing.T) {
	for _, name := range []string{"mips", "gvisor", "mixed", "system"} {
		t.Run(name, func(t *testing.T) {
			var e Engine
			prepareVPN(t, &e, "ipv6: false\ntun: {stack: "+name+", inet6-address: []}\nrules: [\"MATCH,DIRECT\"]\n")
			fd, err := syscall.Open("/dev/null", syscall.O_RDWR, 0)
			if err != nil {
				t.Fatal(err)
			}
			device := &ownedTestTun{fd: fd, replacement: -1}
			err = e.attach(fd, 1, tunFactories{func(tun.Options) (tun.Tun, error) { return device, nil }, func(got string, opts tun.StackOptions) (tun.Stack, error) {
				if got != name || opts.TunOptions.MTU != 1500 {
					t.Fatalf("stack/options changed: %s %+v", got, opts.TunOptions)
				}
				return nil, errors.New("stop after checking real selected stack")
			}})
			if err == nil {
				t.Fatal("failure ignored")
			}
			if device.replacement >= 0 {
				syscall.Close(device.replacement)
			}
		})
	}
}
