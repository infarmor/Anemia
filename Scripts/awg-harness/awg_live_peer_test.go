// A live AmneziaWG peer for device runs — copied into the engine checkout by
// Android/Scripts/verify-awg-android.sh (package device, so it can use the
// engine's own channel TUN). Not compiled by SwiftPM.

package device

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/tuntest"
)

// TestAnemiaLivePeer brings up a server device on a real UDP port with the
// obfuscation parameters Anemia's builder emits, and waits for a handshake
// from a client over the network — the emulator, in practice. The engine
// reports the AWG handshake time and byte counters, so "the config starts" and
// "the tunnel actually works" become two different, both measurable, claims.
//
// Env: AWG_PEER_UAPI (path to the server's UAPI script), AWG_WAIT_SEC,
// AWG_CLIENT_IP and AWG_PEER_IP for the probe packets pushed at the client.
func TestAnemiaLivePeer(t *testing.T) {
	path := os.Getenv("AWG_PEER_UAPI")
	if path == "" {
		t.Skip("AWG_PEER_UAPI not set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) == 0 || lines[0] != "set=1" {
		t.Fatalf("script must start with set=1, got %q", lines[0])
	}
	// `set=1` — маркер *ответа* UAPI, в `IpcSet` его подавать нельзя (тот же шаг
	// делает `anemiaClientScript` в основном харнесе).
	lines = lines[1:]

	clientIP := netip.MustParseAddr(envOr("AWG_CLIENT_IP", "10.66.0.2"))
	peerIP := netip.MustParseAddr(envOr("AWG_PEER_IP", "10.66.0.1"))
	wait := 90 * time.Second
	if seconds := envOr("AWG_WAIT_SEC", ""); seconds != "" {
		var n int
		if _, err := fmt.Sscanf(seconds, "%d", &n); err == nil && n > 0 {
			wait = time.Duration(n) * time.Second
		}
	}

	tun := tuntest.NewChannelTUN()
	dev := NewDevice(tun.TUN(), conn.NewDefaultBind(), NewLogger(peerLogLevel(), "peer: "))
	if err := dev.IpcSet(strings.Join(lines, "\n") + "\n"); err != nil {
		dev.Close()
		t.Fatalf("peer rejected its UAPI config: %v", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		t.Fatalf("peer up: %v", err)
	}
	defer dev.Close()

	deadline := time.Now().Add(wait)
	handshakes := 0
	for time.Now().Before(deadline) {
		// One probe toward the client: without traffic of its own the client's
		// receive counter would never move, and rx=0 on the peer could then
		// mean either "no tunnel" or "nobody sent anything".
		select {
		case tun.Outbound <- tuntest.Ping(clientIP, peerIP):
		default:
		}
		state, err := dev.IpcGet()
		if err != nil {
			t.Fatalf("peer status failed: %v", err)
		}
		fields := peerParse(state)
		handshake := fields["last_handshake_time_sec"]
		rx := fields["rx_bytes"]
		tx := fields["tx_bytes"]
		pinger := fields["pinger"]
		t.Logf("peer: handshake=%s rx=%s tx=%s pinger=%s", handshake, rx, tx, pinger)
		if handshake != "" && handshake != "0" {
			handshakes++
		}
		if handshakes >= 2 && rx != "" && rx != "0" {
			t.Logf("PEER VERIFIED: handshake settled, %s bytes received from the client", rx)
			return
		}
		time.Sleep(2 * time.Second)
	}
	t.Fatalf("no live peer session within %v (handshakes seen: %d)", wait, handshakes)
}

// The pre-fix Android build sent base64 keys into UAPI; this proves the same
// engine the peer runs on refuses them, so a green peer session cannot be
// bought with a config the builder never produces.
func TestAnemiaPeerRejectsBase64Keys(t *testing.T) {
	path := os.Getenv("AWG_PEER_UAPI")
	if path == "" {
		t.Skip("AWG_PEER_UAPI not set")
	}
	raw, _ := os.ReadFile(path)
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) > 0 && lines[0] == "set=1" {
		lines = lines[1:]
	}
	for i, line := range lines {
		if strings.HasPrefix(line, "private_key=") {
			key := strings.TrimPrefix(line, "private_key=")
			bytes, err := hex.DecodeString(key)
			if err != nil {
				t.Fatalf("peer script carries a non-hex key: %v", err)
			}
			lines[i] = "private_key=" + base64.StdEncoding.EncodeToString(bytes)
		}
	}
	dev := NewDevice(tuntest.NewChannelTUN().TUN(), conn.NewDefaultBind(), NewLogger(LogLevelSilent, ""))
	defer dev.Close()
	if err := dev.IpcSet(strings.Join(lines, "\n") + "\n"); err == nil {
		t.Fatal("peer accepted a base64 private key")
	} else {
		t.Logf("base64 key refused as expected: %v", err)
	}
}

func peerParse(state string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(state, "\n") {
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		// The last peer block wins: status lists every peer, and the emulator is
		// the only one configured here.
		if key == "last_handshake_time_sec" || key == "rx_bytes" || key == "tx_bytes" || key == "pinger" {
			out[key] = value
		}
	}
	return out
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func peerLogLevel() int {
	if os.Getenv("ANEMIA_VERBOSE") != "" {
		return LogLevelVerbose
	}
	return LogLevelError
}
