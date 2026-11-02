//go:build android

package main

/*
#include <stdlib.h>
#include "native_bridge.h"
*/
import "C"

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"sync/atomic"
	"syscall"
	"unsafe"

	"clashpseudo/native/internal/coreipc"
	"clashpseudo/native/internal/engine"
	"github.com/metacubex/mihomo/log"
	"github.com/sirupsen/logrus"
)

func init() { logrus.SetOutput(io.Discard) }

func callbackBytes(value *C.char) []byte {
	if value == nil {
		return nil
	}
	defer C.free(unsafe.Pointer(value))
	return []byte(C.GoString(value))
}
func callbackJSON(value *C.char, target any) error {
	return decodeCallback(callbackBytes(value), target)
}
func callbackOK(value *C.char) error {
	var response struct {
		OK bool `json:"ok"`
	}
	if err := callbackJSON(value, &response); err != nil {
		return err
	}
	if !response.OK {
		return errors.New("Android callback did not confirm success")
	}
	return nil
}

var systemQuerySequence atomic.Int64

func systemQuery(ctx context.Context, host string, family int, wire []byte) ([]byte, []netip.Addr, error) {
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	id := systemQuerySequence.Add(1)
	body, cancelErr := invokePlatformQuery(ctx, func() []byte {
		if wire != nil {
			input := C.CBytes(wire)
			defer C.free(input)
			return callbackBytes(C.native_system_dns(C.longlong(id), (*C.char)(input), C.int(len(wire))))
		}
		name := C.CString(host)
		defer C.free(unsafe.Pointer(name))
		return callbackBytes(C.native_system_lookup(C.longlong(id), name, C.int(family)))
	}, func() error {
		var response any
		return callbackJSON(C.native_cancel_system_dns(C.longlong(id)), &response)
	})
	var response struct {
		Wire      string   `json:"wire"`
		Addresses []string `json:"addresses"`
		Exited    bool     `json:"exited"`
	}
	callErr := decodeCallback(body, &response)
	if !response.Exited {
		callErr = errors.Join(callErr, errors.New("Android system DNS actual exit is unconfirmed"))
	}
	bytes, decodeErr := base64.StdEncoding.DecodeString(response.Wire)
	ips := make([]netip.Addr, 0, len(response.Addresses))
	for _, text := range response.Addresses {
		ip, err := netip.ParseAddr(text)
		if err != nil {
			decodeErr = errors.Join(decodeErr, err)
			continue
		}
		if family == 4 && !ip.Is4() {
			continue
		}
		if family == 6 && !ip.Is6() {
			continue
		}
		ips = append(ips, ip)
	}
	return bytes, ips, errors.Join(callErr, decodeErr, cancelErr)
}
func androidCallbacks() nativeCallbacks {
	return nativeCallbacks{
		Protect: func(fd int) error { return callbackOK(C.native_protect(C.int(fd))) },
		ProtectNetwork: func(fd int, network string) error {
			handle := C.CString(network)
			defer C.free(unsafe.Pointer(handle))
			return callbackOK(C.native_protect_network(C.int(fd), handle))
		},
		DNS: func(ctx context.Context, wire []byte) ([]byte, error) {
			response, _, err := systemQuery(ctx, "", 0, wire)
			return response, err
		},
		Lookup: func(ctx context.Context, host string, family int) ([]netip.Addr, error) {
			_, ips, err := systemQuery(ctx, host, family, nil)
			return ips, err
		},
		Seed: func(seeds []engine.GeoSeed) error {
			body, err := json.Marshal(seeds)
			if err != nil {
				return err
			}
			value := C.CBytes(body)
			defer C.free(value)
			return callbackOK(C.native_seed_geo((*C.char)(value), C.int(len(body))))
		},
		Changed: func(revision uint64, changed bool) {
			flag := C.int(0)
			if changed {
				flag = 1
			}
			C.native_specification_changed(C.longlong(revision), flag)
		},
	}
}

//export CoreInvoke
func CoreInvoke(operation C.int, requestID C.longlong, inputFD, outputFD, tunFD C.int) *C.char {
	for _, fd := range []C.int{inputFD, outputFD} {
		if err := syscall.SetNonblock(int(fd), true); err != nil {
			closeErr := errors.Join(syscall.Close(int(inputFD)), syscall.Close(int(outputFD)))
			if tunFD >= 0 {
				closeErr = errors.Join(closeErr, syscall.Close(int(tunFD)))
			}
			body, _ := json.Marshal(map[string]any{"accepted": false, "exited": true, "error": coreipc.Failure("callFailed", errors.Join(err, closeErr))})
			return C.CString(string(body))
		}
	}
	input := os.NewFile(uintptr(inputFD), "core-request")
	output := os.NewFile(uintptr(outputFD), "core-result")
	var tun *os.File
	if tunFD >= 0 {
		tun = os.NewFile(uintptr(tunFD), "core-tun")
	}
	if input == nil || output == nil {
		if input != nil {
			_ = input.Close()
		}
		if output != nil {
			_ = output.Close()
		}
		if tun != nil {
			_ = tun.Close()
		}
		return C.CString(`{"accepted":false,"exited":true,"error":{"code":"callFailed","message":"invalid native descriptors"}}`)
	}
	return C.CString(string(dispatcher.invoke(int(operation), int64(requestID), input, output, tun, androidCallbacks())))
}

//export CoreReportCallbackError
func CoreReportCallbackError(value *C.char) {
	log.Errorln("Android specification callback: %s", fmt.Sprint(C.GoString(value)))
}
