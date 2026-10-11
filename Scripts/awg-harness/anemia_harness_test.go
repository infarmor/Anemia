// Anemia ↔ amneziawg-go harness — copied into the engine checkout by
// Scripts/verify-awg-engine.sh (package device, so it can use the engine's
// channel TUN). Not compiled by SwiftPM.

package device

import (
	"bytes"
	"encoding/base64"
	"encoding/hex"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun/tuntest"
)

// Anemia harness: a server device and a client device configured with the
// exact UAPI script Anemia's AmneziaWGConfigBuilder produces, pinging both
// ways through the obfuscated tunnel over real loopback UDP.

func anemiaClientScript(t *testing.T) []string {
	path := os.Getenv("ANEMIA_CLIENT_UAPI")
	if path == "" {
		t.Skip("ANEMIA_CLIENT_UAPI not set")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimRight(string(raw), "\n"), "\n")
	if len(lines) == 0 || lines[0] != "set=1" {
		t.Fatalf("script must start with set=1")
	}
	drop := map[string]bool{}
	for _, k := range strings.Split(os.Getenv("ANEMIA_DROP"), ",") {
		if k != "" {
			drop[k] = true
		}
	}
	var kept []string
	for _, l := range lines[1:] {
		if drop[strings.SplitN(l, "=", 2)[0]] {
			continue
		}
		kept = append(kept, l)
	}
	return kept
}

func anemiaHex(t *testing.T, b64 string) string {
	k, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(k) != 32 {
		t.Fatalf("bad key %q", b64)
	}
	return hex.EncodeToString(k)
}

func anemiaUp(t *testing.T, name, cfg string) (*tuntest.ChannelTUN, *Device) {
	tun := tuntest.NewChannelTUN()
	dev := NewDevice(tun.TUN(), conn.NewDefaultBind(), NewLogger(anemiaLogLevel(), name+": "))
	if err := dev.IpcSet(cfg); err != nil {
		dev.Close()
		t.Fatalf("%s rejected its UAPI config: %v", name, err)
	}
	if err := dev.Up(); err != nil {
		t.Fatalf("%s up: %v", name, err)
	}
	t.Cleanup(dev.Close)
	return tun, dev
}

func TestAnemiaGeneratedClientConnects(t *testing.T) {
	client := anemiaClientScript(t)
	// The server shares every device-level obfuscation parameter.
	var obfuscation []string
	for _, l := range client {
		if strings.HasPrefix(l, "replace_peers=") {
			break
		}
		if !strings.HasPrefix(l, "private_key=") {
			obfuscation = append(obfuscation, l)
		}
	}
	server := append([]string{
		"private_key=" + anemiaHex(t, os.Getenv("SERVER_PRIV")),
		"listen_port=" + os.Getenv("AWG_PORT"),
	}, obfuscation...)
	server = append(server,
		"replace_peers=true",
		"public_key="+anemiaHex(t, os.Getenv("CLIENT_PUB")),
		"protocol_version=1",
		"replace_allowed_ips=true",
		"allowed_ip=10.66.0.2/32")

	serverTun, _ := anemiaUp(t, "server", strings.Join(server, "\n")+"\n")
	clientTun, clientDev := anemiaUp(t, "client", strings.Join(client, "\n")+"\n")

	serverIP, clientIP := netip.MustParseAddr("10.66.0.1"), netip.MustParseAddr("10.66.0.2")
	// amneziawg-go#168: the first transport packet after UAPI configuration can
	// use a stale S4 and be dropped — real traffic retransmits, so retry the
	// probe and then require steady-state packets to pass on the first try.
	send := func(label string, from, to *tuntest.ChannelTUN, dst, src netip.Addr, attempts int) int {
		msg := tuntest.Ping(dst, src)
		for attempt := 1; attempt <= attempts; attempt++ {
			from.Outbound <- msg
			select {
			case got := <-to.Inbound:
				if !bytes.Equal(msg, got) {
					t.Fatalf("%s: packet corrupted in transit", label)
				}
				return attempt
			case <-time.After(1500 * time.Millisecond):
			}
		}
		t.Fatalf("%s did not transit in %d attempts", label, attempts)
		return 0
	}
	t.Logf("client → server: first delivery on attempt %d", send("client → server", clientTun, serverTun, serverIP, clientIP, 6))
	t.Logf("server → client: first delivery on attempt %d", send("server → client", serverTun, clientTun, clientIP, serverIP, 6))
	for i := 0; i < 20; i++ {
		send("steady client → server", clientTun, serverTun, serverIP, clientIP, 1)
		send("steady server → client", serverTun, clientTun, clientIP, serverIP, 1)
	}
	t.Logf("steady state: 40 packets delivered without a retry")

	state, _ := clientDev.IpcGet()
	for _, l := range strings.Split(state, "\n") {
		for _, k := range []string{"last_handshake_time_sec", "rx_bytes", "tx_bytes", "random_trailers", "content_padding_addition", "h1", "s4"} {
			if strings.HasPrefix(l, k+"=") {
				t.Logf("client %s", l)
			}
		}
	}
}

// The pre-fix app sent base64 keys; the engine must refuse them.
func TestAnemiaBase64KeysAreRejected(t *testing.T) {
	client := anemiaClientScript(t)
	for i, l := range client {
		if strings.HasPrefix(l, "private_key=") {
			client[i] = "private_key=" + os.Getenv("CLIENT_PRIV")
		}
	}
	dev := NewDevice(tuntest.NewChannelTUN().TUN(), conn.NewDefaultBind(), NewLogger(LogLevelSilent, ""))
	defer dev.Close()
	err := dev.IpcSet(strings.Join(client, "\n") + "\n")
	if err == nil {
		t.Fatal("engine accepted a base64 private key")
	}
	t.Logf("base64 key refused as expected: %v", err)
}

func anemiaLogLevel() int {
	if os.Getenv("ANEMIA_VERBOSE") != "" {
		return LogLevelVerbose
	}
	return LogLevelError
}
