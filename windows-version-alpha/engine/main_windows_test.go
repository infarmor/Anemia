package main

import (
	"bytes"
	"crypto/ecdh"
	"crypto/rand"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/amnezia-vpn/amneziawg-go/v3/tun/tuntest"
)

func TestPaddedAmneziaTraffic(t *testing.T) {
	addresses := []netip.Addr{netip.MustParseAddr("198.51.100.1"), netip.MustParseAddr("198.51.100.2")}
	keys := make([]*ecdh.PrivateKey, len(addresses))
	ports := make([]string, len(addresses))
	channels := make([]*tuntest.ChannelTUN, len(addresses))
	for i := range addresses {
		key, err := ecdh.X25519().GenerateKey(rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		keys[i] = key
	}

	configs := make([]func(string) error, len(addresses))
	for i := range addresses {
		channels[i] = tuntest.NewChannelTUN()
		profile := fmt.Sprintf(
			"jc=5\njmin=500\njmax=1000\ns1=15\ns2=18\ns3=20\ns4=25\n"+
				"h1=123456-123500\nh2=67543-67550\nh3=123123-123200\nh4=32345-32350\n"+
				"private_key=%x\nlisten_port=0\nreplace_peers=true\npublic_key=%x\nprotocol_version=1\nreplace_allowed_ips=true\nallowed_ip=%s/32\n",
			keys[i].Bytes(), keys[1-i].PublicKey().Bytes(), addresses[1-i],
		)
		peer, err := newAwgDevice(channels[i].TUN(), profile)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(peer.Close)
		configs[i] = peer.IpcSet
		if err := peer.Up(); err != nil {
			t.Fatal(err)
		}
		state, err := peer.IpcGet()
		if err != nil {
			t.Fatal(err)
		}
		for _, line := range strings.Split(state, "\n") {
			if port, ok := strings.CutPrefix(line, "listen_port="); ok {
				ports[i] = port
				break
			}
		}
		if ports[i] == "" || ports[i] == "0" {
			t.Fatal("peer did not bind a loopback port")
		}
	}

	for i, configure := range configs {
		if err := configure(fmt.Sprintf("public_key=%x\nendpoint=127.0.0.1:%s\n",
			keys[1-i].PublicKey().Bytes(), ports[1-i])); err != nil {
			t.Fatal(err)
		}
	}
	for i, channel := range channels {
		packet := tuntest.Ping(addresses[1-i], addresses[i])
		select {
		case channel.Outbound <- packet:
		case <-time.After(3 * time.Second):
			t.Fatal("source peer did not accept the packet")
		}
		select {
		case received := <-channels[1-i].Inbound:
			if !bytes.Equal(received, packet) {
				t.Fatal("destination received a different packet")
			}
		case <-time.After(6 * time.Second):
			t.Fatal("padded AmneziaWG packet did not reach the remote peer")
		}
	}
}
