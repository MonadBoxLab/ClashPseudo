package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"flag"
	"math/big"
	"net"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/metacubex/mihomo/component/ca"
	MTLS "github.com/metacubex/tls"
)

func TestInitializeTrustRootsSubprocess(t *testing.T) {
	const caseVariable = "CLASH_PSEUDO_TRUST_TEST_CASE"
	if scenario := os.Getenv(caseVariable); scenario != "" {
		runTrustRootsScenario(t, scenario)
		return
	}
	for _, scenario := range []string{"malformed-retry", "empty", "tls-validation", "public-client-options", "idempotence"} {
		t.Run(scenario, func(t *testing.T) {
			// Run each fallback-root case in a fresh process with its supplied certificate
			// material.
			command := exec.Command(os.Args[0], "-test.run=^TestInitializeTrustRootsSubprocess$", "-test.v")
			if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
				command.Args = append(command.Args, "-test.gocoverdir="+directory.Value.String())
			}
			for _, entry := range os.Environ() {
				if !strings.HasPrefix(entry, "GODEBUG=") && !strings.HasPrefix(entry, caseVariable+"=") {
					command.Env = append(command.Env, entry)
				}
			}
			debug := strings.Trim(os.Getenv("GODEBUG")+",x509usefallbackroots=1", ",")
			command.Env = append(command.Env, "GODEBUG="+debug, caseVariable+"="+scenario)
			if output, err := command.CombinedOutput(); err != nil {
				t.Fatalf("fresh-process scenario failed: %v\n%s", err, output)
			}
		})
	}
}

func runTrustRootsScenario(t *testing.T, scenario string) {
	t.Helper()
	if trustRootsReady() {
		t.Fatal("fresh process reported trust ready before initialization")
	}
	root, key, material := newTrustTestRoot(t, "supplied Android root")
	expected := x509.NewCertPool()
	expected.AddCert(root)
	switch scenario {
	case "malformed-retry":
		ca.DisableEmbedCa, ca.DisableSystemCa = false, true
		invalid := [][]byte{
			[]byte("not PEM"),
			append([]byte("unexpected prefix\n"), material...),
			append(bytes.Clone(material), []byte("unexpected suffix")...),
			[]byte("-----BEGIN CERTIFICATE-----\nunterminated"),
			pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte{1, 2, 3}}),
			pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte{1, 2, 3}}),
			append([]byte("-----BEGIN CERTIFICATE-----\ninvalid base64\n-----END CERTIFICATE-----\n"), material...),
			append([]byte("-----BEGIN CERTIFICATE-----\ninvalid prefix\n"), material...),
			pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Headers: map[string]string{"Unexpected": "header"}, Bytes: root.Raw}),
		}
		for index, bad := range invalid {
			if err := initializeTrustRoots(bad); err == nil {
				t.Fatalf("malformed material %d succeeded", index)
			}
			if trustRootsReady() {
				t.Fatal("failed parsing reported trust initialization complete")
			}
			if ca.DisableEmbedCa || !ca.DisableSystemCa {
				t.Fatal("failed parsing changed mihomo trust policy")
			}
		}
		if err := initializeTrustRoots(material); err != nil {
			t.Fatalf("failed parsing consumed initialization: %v", err)
		}
		assertProcessTrustPool(t, expected)
	case "empty":
		if err := initializeTrustRoots(nil); err != nil {
			t.Fatal(err)
		}
		if err := initializeTrustRoots([]byte{}); err != nil {
			t.Fatal(err)
		}
		assertProcessTrustPool(t, x509.NewCertPool())
		peer := newTrustTestPeer(t, root, key, "trusted.example", false)
		var unknown x509.UnknownAuthorityError
		if err := trustTestHandshake(peer, "trusted.example", nil); !errors.As(err, &unknown) {
			t.Fatalf("empty root set must reject the peer, got %v", err)
		}
	case "tls-validation":
		if err := initializeTrustRoots(material); err != nil {
			t.Fatal(err)
		}
		assertProcessTrustPool(t, expected)
		peer := newTrustTestPeer(t, root, key, "trusted.example", false)
		if err := trustTestHandshake(peer, "trusted.example", nil); err != nil {
			t.Fatalf("supplied trusted root was not used: %v", err)
		}
		var hostname x509.HostnameError
		if err := trustTestHandshake(peer, "wrong.example", nil); !errors.As(err, &hostname) {
			t.Fatalf("hostname validation was bypassed: %v", err)
		}
		expired := newTrustTestPeer(t, root, key, "trusted.example", true)
		var invalid x509.CertificateInvalidError
		if err := trustTestHandshake(expired, "trusted.example", nil); !errors.As(err, &invalid) || invalid.Reason != x509.Expired {
			t.Fatalf("expiry validation was bypassed: %v", err)
		}
		other, otherKey, _ := newTrustTestRoot(t, "unknown root")
		unknownPeer := newTrustTestPeer(t, other, otherKey, "trusted.example", false)
		var unknown x509.UnknownAuthorityError
		if err := trustTestHandshake(unknownPeer, "trusted.example", nil); !errors.As(err, &unknown) {
			t.Fatalf("unknown root was accepted: %v", err)
		}
		// Reset from the supplied fallback pool.
		ca.ResetCertificate()
		assertProcessTrustPool(t, expected)
	case "public-client-options":
		if err := initializeTrustRoots(material); err != nil {
			t.Fatal(err)
		}
		assertProcessTrustPool(t, expected)
		peer := newTrustTestPeer(t, root, key, "trusted.example", false)
		pinned := peer
		pinned.Certificate = append(slices.Clone(peer.Certificate), root.Raw)
		expired := newTrustTestPeer(t, root, key, "trusted.example", true)
		expired.Certificate = append(expired.Certificate, root.Raw)
		digest := sha256.Sum256(root.Raw)
		pin := hex.EncodeToString(digest[:])
		digest[0] ^= 1
		wrongPin := hex.EncodeToString(digest[:])
		verifier, err := ca.NewFingerprintVerifier(wrongPin, time.Now)
		if err != nil {
			t.Fatal(err)
		}
		pinFailure := verifier([]*x509.Certificate{root}, "trusted.example")
		if pinFailure == nil {
			t.Fatal("mismatched pin fixture was accepted")
		}
		counterfeit, counterfeitKey, _ := newTrustTestRoot(t, root.Subject.CommonName)
		badChain := newTrustTestPeer(t, counterfeit, counterfeitKey, "trusted.example", false)
		for _, test := range []struct {
			name, host, pin string
			peer            tls.Certificate
			accepted        bool
		}{
			{"default-root", "trusted.example", "", peer, true},
			{"default-wrong-host", "wrong.example", "", peer, false},
			{"default-expired", "trusted.example", "", expired, false},
			{"bad-chain-signature", "trusted.example", "", badChain, false},
			{"chain-pin", "trusted.example", pin, pinned, true},
			{"wrong-pin", "trusted.example", wrongPin, pinned, false},
			{"chain-pin-wrong-host", "wrong.example", pin, pinned, false},
			{"chain-pin-expired", "trusted.example", pin, expired, false},
		} {
			t.Run(test.name, func(t *testing.T) {
				configuration, err := ca.GetTLSConfig(ca.Option{
					TLSConfig: &MTLS.Config{ServerName: test.host}, Fingerprint: test.pin,
				})
				if err != nil {
					t.Fatal(err)
				}
				err = trustTestPublicHandshake(test.peer, configuration)
				if (err == nil) != test.accepted {
					t.Fatalf("fixed public client validation: accepted=%v err=%v", test.accepted, err)
				}
				switch test.name {
				case "default-wrong-host", "chain-pin-wrong-host":
					var hostname x509.HostnameError
					if !errors.As(err, &hostname) {
						t.Fatalf("wrong-host fixture failed for another reason: %v", err)
					}
				case "default-expired", "chain-pin-expired":
					var invalid x509.CertificateInvalidError
					if !errors.As(err, &invalid) || invalid.Reason != x509.Expired {
						t.Fatalf("expired fixture failed for another reason: %v", err)
					}
				case "bad-chain-signature":
					var unknown x509.UnknownAuthorityError
					if !errors.As(err, &unknown) {
						t.Fatalf("bad chain fixture failed for another reason: %v", err)
					}
				case "wrong-pin":
					if !errors.Is(err, pinFailure) {
						t.Fatalf("pin fixture failed for another reason: %v", err)
					}
				}
			})
		}
		if _, err := ca.GetTLSConfig(ca.Option{Fingerprint: "not-a-sha256-pin"}); err == nil {
			t.Fatal("malformed pin reached a TLS connection")
		}
		other, otherKey, extraMaterial := newTrustTestRoot(t, "explicit dedicated root")
		otherPeer := newTrustTestPeer(t, other, otherKey, "private.example", false)
		configuration, err := ca.GetTLSConfig(ca.Option{TLSConfig: &MTLS.Config{ServerName: "private.example"}})
		if err != nil {
			t.Fatal(err)
		}
		var unknown x509.UnknownAuthorityError
		if err := trustTestPublicHandshake(otherPeer, configuration); !errors.As(err, &unknown) {
			t.Fatalf("unconfigured dedicated root was not rejected by the verifier: %v", err)
		}
		if err := ca.AddCertificate(string(extraMaterial)); err != nil {
			t.Fatal(err)
		}
		for _, host := range []string{"private.example", "wrong.example"} {
			configuration, err := ca.GetTLSConfig(ca.Option{TLSConfig: &MTLS.Config{ServerName: host}})
			if err != nil {
				t.Fatal(err)
			}
			err = trustTestPublicHandshake(otherPeer, configuration)
			if (err == nil) != (host == "private.example") {
				t.Fatalf("dedicated certificate bypassed name validation: %v", err)
			}
			if host == "wrong.example" {
				var hostname x509.HostnameError
				if !errors.As(err, &hostname) {
					t.Fatalf("dedicated wrong-host fixture failed for another reason: %v", err)
				}
			}
		}
	case "idempotence":
		if err := initializeTrustRoots(material); err != nil {
			t.Fatal(err)
		}
		var workers sync.WaitGroup
		for range 16 {
			workers.Go(func() {
				if err := initializeTrustRoots(bytes.Clone(material)); err != nil {
					t.Errorf("identical concurrent initialization failed: %v", err)
				}
			})
		}
		workers.Wait()
		extra, _, extraMaterial := newTrustTestRoot(t, "explicit private certificate")
		if err := ca.AddCertificate(string(extraMaterial)); err != nil {
			t.Fatal(err)
		}
		expected.AddCert(extra)
		if err := initializeTrustRoots(material); err != nil {
			t.Fatal(err)
		}
		if !ca.GetCertPool().Equal(expected) {
			t.Fatal("idempotent initialization removed an explicitly configured certificate")
		}
		for _, changed := range [][]byte{nil, extraMaterial, append(bytes.Clone(material), '\n')} {
			if err := initializeTrustRoots(changed); err == nil {
				t.Fatal("different process material was silently accepted")
			}
		}
		if !ca.GetCertPool().Equal(expected) {
			t.Fatal("rejected replacement changed mihomo's trust pool")
		}
		if err := initializeTrustRoots(material); err != nil {
			t.Fatalf("rejected replacement poisoned the valid snapshot: %v", err)
		}
	default:
		t.Fatalf("unknown trust test scenario %q", scenario)
	}
	if !trustRootsReady() {
		t.Fatal("successful initialization did not publish trust readiness")
	}
}

func assertProcessTrustPool(t *testing.T, expected *x509.CertPool) {
	t.Helper()
	actual, err := x509.SystemCertPool()
	if err != nil {
		t.Fatal(err)
	}
	if !actual.Equal(expected) || !ca.GetCertPool().Equal(expected) {
		t.Fatal("Go and mihomo did not use exactly the supplied root set")
	}
	if !ca.DisableEmbedCa || ca.DisableSystemCa {
		t.Fatal("mihomo root-source policy differs from the Android material policy")
	}
}

func newTrustTestRoot(t *testing.T, name string) (*x509.Certificate, *ecdsa.PrivateKey, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: name},
		NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour),
		IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	return certificate, key, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func newTrustTestPeer(t *testing.T, root *x509.Certificate, key *ecdsa.PrivateKey, host string, expired bool) tls.Certificate {
	t.Helper()
	now := time.Now()
	template := &x509.Certificate{
		SerialNumber: big.NewInt(2), DNSNames: []string{host},
		NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Hour),
		KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	if expired {
		template.NotBefore, template.NotAfter = now.Add(-2*time.Hour), now.Add(-time.Hour)
	}
	der, err := x509.CreateCertificate(rand.Reader, template, root, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

// Exercise the real TLS verifier over net.Pipe.
func trustTestHandshake(peer tls.Certificate, host string, roots *x509.CertPool) error {
	return trustTestExchange(peer, func(ctx context.Context, connection net.Conn) error {
		return tls.Client(connection, &tls.Config{ServerName: host, RootCAs: roots}).HandshakeContext(ctx)
	})
}

func trustTestPublicHandshake(peer tls.Certificate, configuration *MTLS.Config) error {
	return trustTestExchange(peer, func(ctx context.Context, connection net.Conn) error {
		return MTLS.Client(connection, configuration).HandshakeContext(ctx)
	})
}

func trustTestExchange(peer tls.Certificate, handshake func(context.Context, net.Conn) error) error {
	clientSide, serverSide := net.Pipe()
	defer clientSide.Close()
	defer serverSide.Close()
	// Use a shorter transport deadline to unblock rejected-peer alert writes while
	// retaining the certificate error; join all goroutines before return.
	_ = clientSide.SetDeadline(time.Now().Add(time.Second))
	_ = serverSide.SetDeadline(time.Now().Add(time.Second))
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server := tls.Server(serverSide, &tls.Config{Certificates: []tls.Certificate{peer}, SessionTicketsDisabled: true})
	done := make(chan struct{})
	go func() {
		defer close(done)
		defer serverSide.Close()
		_ = server.HandshakeContext(ctx)
	}()
	err := handshake(ctx, clientSide)
	_ = clientSide.Close()
	<-done
	return err
}
