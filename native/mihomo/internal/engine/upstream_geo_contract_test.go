package engine

import (
	"errors"
	"flag"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/component/updater"
)

func TestUpstreamMMDBUpdateRequiresExistingDatabase(t *testing.T) {
	if kind := os.Getenv("PSEUDO_UPSTREAM_GEO_KIND"); kind != "" {
		var e Engine
		body := validConfig + fmt.Sprintf("geox-url:\n mmdb: %s\n asn: %s\n", os.Getenv("PSEUDO_UPSTREAM_GEO_URL"), os.Getenv("PSEUDO_UPSTREAM_GEO_URL"))
		if err := e.Prepare(os.Getenv("PSEUDO_UPSTREAM_GEO_HOME"), []byte(body), "rule", nil, func(int) bool { return true }); err != nil {
			t.Fatal(err)
		}
		// Deliberately call the fixed upstream API in this child process only.
		// Missing/corrupt old files can invoke log.Fatal and exit the process.
		var err error
		if kind == "MMDB" {
			err = updater.UpdateMMDB()
		} else {
			err = updater.UpdateASN()
		}
		if err != nil {
			t.Fatal(err)
		}
		requireStop(t, &e)
		return
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(minimalMMDB())
	}))
	defer server.Close()
	for _, name := range []string{"MMDB", "ASN"} {
		for _, old := range []string{"missing", "corrupt", "valid"} {
			t.Run(name+"/"+old, func(t *testing.T) {
				home := t.TempDir()
				file := "Country.mmdb"
				if name == "ASN" {
					file = "ASN.mmdb"
				}
				if old != "missing" {
					data := []byte("invalid old database")
					if old == "valid" {
						data = minimalMMDB()
					}
					if err := os.WriteFile(filepath.Join(home, file), data, 0600); err != nil {
						t.Fatal(err)
					}
				}
				cmd := exec.Command(os.Args[0], "-test.run=^TestUpstreamMMDBUpdateRequiresExistingDatabase$")
				if directory := flag.Lookup("test.gocoverdir"); directory != nil && directory.Value.String() != "" {
					cmd.Args = append(cmd.Args, "-test.gocoverdir="+directory.Value.String())
				}
				cmd.Env = append(os.Environ(), "PSEUDO_UPSTREAM_GEO_KIND="+name,
					"PSEUDO_UPSTREAM_GEO_HOME="+home, "PSEUDO_UPSTREAM_GEO_URL="+server.URL)
				output, err := cmd.CombinedOutput()
				if old == "valid" {
					if err != nil {
						t.Fatalf("valid existing database should update: %v\n%s", err, output)
					}
					return
				}
				var exited *exec.ExitError
				if !errors.As(err, &exited) || exited.ExitCode() != 1 || !strings.Contains(string(output), "Can't load "+name) {
					t.Fatalf("expected isolated upstream fatal on %s %s: %v\n%s", old, name, err, output)
				}
			})
		}
	}
}
