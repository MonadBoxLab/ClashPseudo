package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"sync"

	"github.com/metacubex/mihomo/component/ca"
)

var processTrust struct {
	sync.Mutex
	initialized bool
	fingerprint [sha256.Size]byte
}

// trustRootsReady gates native entry points that could perform network I/O.
func trustRootsReady() bool {
	processTrust.Lock()
	defer processTrust.Unlock()
	return processTrust.initialized
}

// Install Android's immutable process trust snapshot before network use;
// x509usefallbackroots=1 makes it authoritative. Identical subsequent input is
// idempotent.
func initializeTrustRoots(pemBytes []byte) error {
	processTrust.Lock()
	defer processTrust.Unlock()

	fingerprint := sha256.Sum256(pemBytes)
	if processTrust.initialized {
		if processTrust.fingerprint != fingerprint {
			return errors.New("trust roots already initialized with different material")
		}
		return nil
	}

	pool := x509.NewCertPool()
	remaining := bytes.TrimSpace(pemBytes)
	for index := 0; len(remaining) != 0; index++ {
		const begin = "-----BEGIN CERTIFICATE-----"
		const end = "-----END CERTIFICATE-----"
		if !bytes.HasPrefix(remaining, []byte(begin)) {
			return fmt.Errorf("trust roots: unexpected material before certificate %d", index+1)
		}
		endIndex := bytes.Index(remaining, []byte(end))
		if endIndex < 0 {
			return fmt.Errorf("trust roots: unterminated certificate %d", index+1)
		}
		blockEnd := endIndex + len(end)
		encoded := remaining[:blockEnd]
		// Isolate each PEM block so strict parsing validates every certificate in order.
		if bytes.Count(encoded, []byte("-----BEGIN")) != 1 {
			return fmt.Errorf("trust roots: malformed certificate %d", index+1)
		}
		block, rest := pem.Decode(encoded)
		if block == nil || block.Type != "CERTIFICATE" || len(block.Headers) != 0 || len(bytes.TrimSpace(rest)) != 0 {
			return fmt.Errorf("trust roots: invalid PEM certificate %d", index+1)
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return fmt.Errorf("trust roots: invalid X.509 certificate %d: %w", index+1, err)
		}
		pool.AddCert(certificate)
		remaining = bytes.TrimSpace(remaining[blockEnd:])
	}

	// Install a successfully parsed empty Android set as an empty pool; parse all input
	// before consuming SetFallbackRoots' once-only slot.
	x509.SetFallbackRoots(pool)
	ca.DisableEmbedCa = true
	ca.DisableSystemCa = false
	ca.ResetCertificate()
	processTrust.fingerprint = fingerprint
	processTrust.initialized = true
	// Identical later initialization retains private certificates added by ApplyConfig.
	return nil
}
