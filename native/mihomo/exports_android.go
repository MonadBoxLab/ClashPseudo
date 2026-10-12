package main

/*
#include <stdlib.h>
int native_protect(int fd);
*/
import "C"

import (
	"io"
	"unsafe"

	"clashpseudo/native/internal/engine"
	"github.com/sirupsen/logrus"
)

func init() {
	// Upstream messages can include provider URLs and credentials. Android UI
	// reports operation stages; raw core output must not enter device logcat.
	logrus.SetOutput(io.Discard)
}

var core engine.Engine

func result(err error) *C.char {
	if err == nil {
		return C.CString("")
	}
	return C.CString(err.Error())
}

//export CoreVersion
func CoreVersion() *C.char { return C.CString(engine.Version) }

//export CorePrepare
func CorePrepare(home, body *C.char, size C.int) *C.char {
	return result(core.Prepare(C.GoString(home), C.GoBytes(unsafe.Pointer(body), size), func(fd int) bool {
		return C.native_protect(C.int(fd)) != 0
	}))
}

//export CoreAttach
func CoreAttach(fd, mtu C.int, address *C.char, prefixLength C.int) *C.char {
	return result(core.Attach(int(fd), int(mtu), C.GoString(address), int(prefixLength)))
}

//export CoreCancel
func CoreCancel() { core.Cancel() }

//export CoreStop
func CoreStop() *C.char { return result(core.Stop()) }

//export CoreSnapshot
func CoreSnapshot() *C.char { return C.CString(core.Snapshot()) }
