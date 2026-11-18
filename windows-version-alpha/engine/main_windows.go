package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
)

type engineConfig struct {
	Adapter string
	UAPI    string
	MTU     int
	Program string
	Address string
	Port    uint16
	Bypass  []string
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 2 {
		return errors.New("expected awg or firewall")
	}
	input := bufio.NewReader(os.Stdin)
	line, err := input.ReadString('\n')
	if err != nil {
		return err
	}
	var config engineConfig
	if err := json.Unmarshal([]byte(line), &config); err != nil {
		return errors.New("invalid engine configuration")
	}

	switch os.Args[1] {
	case "awg":
		script, ok := strings.CutPrefix(config.UAPI, "set=1\n")
		if !ok {
			return errors.New("invalid AmneziaWG configuration")
		}
		adapter, err := tun.CreateTUN(config.Adapter, config.MTU)
		if err != nil {
			return fmt.Errorf("create Wintun adapter: %w", err)
		}
		peer, err := newAwgDevice(adapter, script)
		if err != nil {
			return err
		}
		defer peer.Close()
		if err := peer.Up(); err != nil {
			return fmt.Errorf("start AmneziaWG: %w", err)
		}
	case "firewall":
		session, err := protect(config)
		if err != nil {
			return err
		}
		defer session.Close()
	default:
		return errors.New("unsupported engine mode")
	}

	fmt.Println("ready")
	// The parent owns the lifetime of the adapter or filters through this pipe.
	_, err = io.Copy(io.Discard, input)
	return err
}

type startupTun struct {
	tun.Device
	configured chan struct{}
	offset     int
	failed     bool
}

func (t *startupTun) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	<-t.configured
	if t.failed {
		return 0, os.ErrClosed
	}
	if offset != t.offset {
		// NewDevice starts its reader before IpcSet. Retry its first read
		// with the configured padding before passing any packet through.
		return 0, nil
	}
	return t.Device.Read(bufs, sizes, offset)
}

func newAwgDevice(adapter tun.Device, script string) (*device.Device, error) {
	padding := 0
	for _, line := range strings.Split(script, "\n") {
		if value, ok := strings.CutPrefix(line, "s4="); ok {
			var err error
			padding, err = strconv.Atoi(value)
			if err != nil || padding < 0 || padding > 65535 {
				adapter.Close()
				return nil, errors.New("invalid AmneziaWG transport padding")
			}
		}
	}
	ready := &startupTun{
		Device: adapter, configured: make(chan struct{}),
		offset: device.MessageTransportHeaderSize + padding,
	}
	peer := device.NewDevice(ready, conn.NewStdNetBind(), device.NewLogger(device.LogLevelSilent, ""))
	err := peer.IpcSet(script)
	ready.failed = err != nil
	close(ready.configured)
	if err != nil {
		peer.Close()
		return nil, errors.New("AmneziaWG rejected the configuration")
	}
	return peer, nil
}
