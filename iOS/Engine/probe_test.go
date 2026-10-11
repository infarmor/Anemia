package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

// Runs against a local VLESS server started with a macOS xray binary:
//
//	ANEMIA_XRAY=/path/to/xray go test -run Probe ./...
//
// (see Scripts/test-engine.sh, which also sets up the patched module).

const testUser = "7f3c5c1e-8a51-4a36-9d7a-3a8b1a52c001"

func startServer(t *testing.T) int {
	t.Helper()
	binary := os.Getenv("ANEMIA_XRAY")
	if binary == "" {
		t.Skip("ANEMIA_XRAY not set")
	}
	port := freePort(t)
	config := fmt.Sprintf(`{
		"log": {"loglevel": "warning"},
		"inbounds": [{"listen": "127.0.0.1", "port": %d, "protocol": "vless",
			"settings": {"clients": [{"id": %q}], "decryption": "none"}}],
		"outbounds": [{"protocol": "freedom"}]
	}`, port, testUser)
	path := filepath.Join(t.TempDir(), "server.json")
	if err := os.WriteFile(path, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(binary, "run", "-c", path)
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { cmd.Process.Kill(); cmd.Wait() })
	for i := 0; i < 50; i++ {
		if conn, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port)); err == nil {
			conn.Close()
			return port
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatal("server didn't start")
	return 0
}

func freePort(t *testing.T) int {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port
}

func clientConfig(port int, user string) string {
	return fmt.Sprintf(`{
		"log": {"loglevel": "none"},
		"inbounds": [],
		"outbounds": [{"tag": "proxy", "protocol": "vless",
			"settings": {"vnext": [{"address": "127.0.0.1", "port": %d,
				"users": [{"id": %q, "encryption": "none"}]}]}}],
		"routing": {"domainStrategy": "AsIs", "rules": []}
	}`, port, user)
}

func target(t *testing.T) string {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	t.Cleanup(server.Close)
	return server.URL + "/generate_204"
}

func TestProbeThroughAWorkingServer(t *testing.T) {
	port := startServer(t)
	ms, err := probeOne(clientConfig(port, testUser), target(t), 5*time.Second)
	if err != nil {
		t.Fatalf("probe failed: %v", err)
	}
	if ms < 1 || ms > 5000 {
		t.Fatalf("implausible time %d ms", ms)
	}
}

func TestProbeRejectsAWrongKey(t *testing.T) {
	port := startServer(t)
	_, err := probeOne(clientConfig(port, "00000000-0000-4000-8000-000000000000"), target(t), 3*time.Second)
	if err == nil {
		t.Fatal("a wrong user id passed the check")
	}
}

func TestProbeTimesOutOnADeadServer(t *testing.T) {
	port := freePort(t) // nothing listens
	start := time.Now()
	_, err := probeOne(clientConfig(port, testUser), target(t), 2*time.Second)
	if err == nil {
		t.Fatal("a dead server passed the check")
	}
	if time.Since(start) > 4*time.Second {
		t.Fatalf("took %v, beyond the timeout", time.Since(start))
	}
}

// The C entry point, several servers at once, results in request order.
func TestProbeBatch(t *testing.T) {
	port := startServer(t)
	url := target(t)
	requests, _ := json.Marshal([]probeRequest{
		{ID: "good", Config: clientConfig(port, testUser)},
		{ID: "bad", Config: clientConfig(port, "00000000-0000-4000-8000-000000000000")},
		{ID: "broken", Config: "{"},
	})
	results := runProbeBatch(string(requests), url, 3*time.Second, 2)
	if len(results) != 3 || results[0].ID != "good" || results[1].ID != "bad" || results[2].ID != "broken" {
		t.Fatalf("unexpected results %+v", results)
	}
	if results[0].Ms < 1 {
		t.Fatalf("good server failed: %+v", results[0])
	}
	if results[1].Ms != -1 || results[2].Ms != -1 || !strings.Contains(results[2].Error, "config") {
		t.Fatalf("failures not reported: %+v", results)
	}
}

// A probe must hand logging back to the running tunnel.
func TestProbeKeepsTheRunningLogger(t *testing.T) {
	port := startServer(t)
	cfg, err := serial.LoadJSONConfig(strings.NewReader(clientConfig(port, testUser)))
	if err != nil {
		t.Fatal(err)
	}
	running, err := core.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := running.Start(); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	xray = running
	mu.Unlock()
	defer func() {
		mu.Lock()
		xray = nil
		mu.Unlock()
		running.Close()
	}()
	if _, err := probeOne(clientConfig(port, testUser), target(t), 5*time.Second); err != nil {
		t.Fatal(err)
	}
	// The running instance still carries traffic after the probe closed.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := fetch(ctx, running, target(t)); err != nil {
		t.Fatalf("running instance broke: %v", err)
	}
}

// startInstance brings up a client instance (outbounds only) the way probeOne
// does, and closes it with the test.
func startInstance(t *testing.T, config string) *core.Instance {
	t.Helper()
	cfg, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		t.Fatal(err)
	}
	instance, err := core.New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { instance.Close() })
	if err := instance.Start(); err != nil {
		t.Fatal(err)
	}
	return instance
}

// answer serves a fixed body, so a test can check what came back rather than
// only that a request survived.
func answer(t *testing.T, body string) string {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return server.URL + "/geoip"
}

// The leak screen asks "what address do sites see" — through the tunnel, from
// the engine. That is only worth anything if the body really comes back, so
// this is the test that pins it: a real VLESS tunnel, a real answer.
func TestFetchBodyReturnsTheAnswerThroughTheTunnel(t *testing.T) {
	port := startServer(t)
	instance := startInstance(t, clientConfig(port, testUser))
	const body = `{"ip":"203.0.113.7","country_code":"NL","isp":"Exit Provider"}`
	elapsed, bytes, got, err := fetchBody(context.Background(), instance, answer(t, body), 4096)
	if err != nil {
		t.Fatalf("fetch through the tunnel failed: %v", err)
	}
	if !strings.Contains(got, "203.0.113.7") {
		t.Fatalf("body did not come back: %q", got)
	}
	if bytes != int64(len(body)) {
		t.Fatalf("counted %d bytes, server sent %d", bytes, len(body))
	}
	if elapsed <= 0 {
		t.Fatalf("no time measured: %v", elapsed)
	}
}

// A cut body must still count everything: the speed test reads the number of
// bytes, and the leak screen reads the text — the same call serves both only
// if the cap does not lie about size.
func TestFetchBodyTruncatesButCountsEverything(t *testing.T) {
	port := startServer(t)
	instance := startInstance(t, clientConfig(port, testUser))
	body := strings.Repeat("x", 5000)
	_, bytes, got, err := fetchBody(context.Background(), instance, answer(t, body), 100)
	if err != nil {
		t.Fatalf("fetch failed: %v", err)
	}
	if len(got) != 100 {
		t.Fatalf("kept %d bytes, asked for 100", len(got))
	}
	if bytes != 5000 {
		t.Fatalf("counted %d, server sent 5000", bytes)
	}
}

// A server that answers 404 is not "an empty exit address" — the screen has to
// know the difference between no answer and an answer without data.
func TestFetchBodyReportsHTTPStatus(t *testing.T) {
	port := startServer(t)
	instance := startInstance(t, clientConfig(port, testUser))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	t.Cleanup(server.Close)
	_, _, _, err := fetchBody(context.Background(), instance, server.URL+"/geoip", 1024)
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("HTTP 404 not reported: %v", err)
	}
}
