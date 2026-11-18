package main

import (
	"fmt"
	"net/netip"
	"time"
	"unsafe"

	"github.com/tailscale/wf"
	"golang.org/x/sys/windows"
)

var interfaceAliasToLUID = windows.NewLazySystemDLL("iphlpapi.dll").NewProc("ConvertInterfaceAliasToLuid")

func adapterLUID(name string) (uint64, error) {
	alias, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return 0, err
	}
	var luid uint64
	code, _, _ := interfaceAliasToLUID.Call(uintptr(unsafe.Pointer(alias)), uintptr(unsafe.Pointer(&luid)))
	if code != 0 {
		return 0, windows.Errno(code)
	}
	return luid, nil
}

func protect(config engineConfig) (*wf.Session, error) {
	luid, err := adapterLUID(config.Adapter)
	if err != nil {
		return nil, fmt.Errorf("find VPN adapter: %w", err)
	}
	appID, err := wf.AppID(config.Program)
	if err != nil {
		return nil, fmt.Errorf("identify VPN engine: %w", err)
	}
	endpoint, err := netip.ParseAddr(config.Address)
	if err != nil {
		return nil, fmt.Errorf("invalid VPN endpoint: %w", err)
	}
	session, err := wf.New(&wf.Options{Name: "Anemia Kill switch", Dynamic: true, TransactionStartTimeout: 5 * time.Second})
	if err != nil {
		return nil, err
	}
	if err := addFilters(session, luid, appID, endpoint, config.Port, config.Bypass); err != nil {
		session.Close()
		return nil, err
	}
	return session, nil
}

func addFilters(session *wf.Session, luid uint64, appID string, endpoint netip.Addr, port uint16, bypass []string) error {
	key, err := windows.GenerateGUID()
	if err != nil {
		return err
	}
	layer := wf.SublayerID(key)
	if err := session.AddSublayer(&wf.Sublayer{ID: layer, Name: "Anemia Kill switch", Weight: 0xffff}); err != nil {
		return err
	}
	equals := func(field wf.FieldID, value any) *wf.Match {
		return &wf.Match{Field: field, Op: wf.MatchTypeEqual, Value: value}
	}
	for _, ipv4 := range []bool{true, false} {
		connect := wf.LayerALEAuthConnectV6
		dhcpPort := uint16(547)
		if ipv4 {
			connect = wf.LayerALEAuthConnectV4
			dhcpPort = 67
		}
		add := func(name string, action wf.Action, conditions ...*wf.Match) error {
			id, err := windows.GenerateGUID()
			if err != nil {
				return err
			}
			weight := uint64(10)
			if action == wf.ActionBlock {
				weight = 1
			}
			err = session.AddRule(&wf.Rule{
				ID: wf.RuleID(id), Name: "Anemia " + name, Layer: connect, Sublayer: layer,
				Weight: weight, Conditions: conditions, Action: action, HardAction: action == wf.ActionBlock,
			})
			if err != nil {
				return fmt.Errorf("%s (%s): %w", name, connect, err)
			}
			return nil
		}
		if err := add("VPN", wf.ActionPermit, equals(wf.FieldIPLocalInterface, luid)); err != nil {
			return err
		}
		loopback := &wf.Match{Field: wf.FieldFlags, Op: wf.MatchTypeFlagsAllSet, Value: wf.ConditionFlagIsLoopback}
		if err := add("loopback", wf.ActionPermit, loopback); err != nil {
			return err
		}
		if err := add("DHCP", wf.ActionPermit, equals(wf.FieldIPProtocol, uint8(17)),
			equals(wf.FieldIPRemotePort, dhcpPort)); err != nil {
			return err
		}
		if !ipv4 {
			if err := add("IPv6 neighbor discovery", wf.ActionPermit, equals(wf.FieldIPProtocol, uint8(58)),
				equals(wf.FieldIPRemoteAddress, netip.MustParsePrefix("ff02::/16"))); err != nil {
				return err
			}
			if err := add("IPv6 local control", wf.ActionPermit, equals(wf.FieldIPProtocol, uint8(58)),
				equals(wf.FieldIPRemoteAddress, netip.MustParsePrefix("fe80::/10"))); err != nil {
				return err
			}
		}
		if ipv4 == endpoint.Is4() {
			if err := add("VPN endpoint", wf.ActionPermit, equals(wf.FieldALEAppID, appID),
				equals(wf.FieldIPRemoteAddress, endpoint), equals(wf.FieldIPRemotePort, port)); err != nil {
				return err
			}
		}
		for _, address := range bypass {
			prefix, err := netip.ParsePrefix(address)
			if err != nil {
				ip, parseErr := netip.ParseAddr(address)
				if parseErr != nil {
					return fmt.Errorf("invalid bypass address: %w", parseErr)
				}
				prefix = netip.PrefixFrom(ip, ip.BitLen())
			}
			if prefix.Addr().Is4() == ipv4 {
				if err := add("split tunnel", wf.ActionPermit, equals(wf.FieldIPRemoteAddress, prefix)); err != nil {
					return err
				}
			}
		}
		if err := add("block traffic outside VPN", wf.ActionBlock); err != nil {
			return err
		}
	}
	return nil
}
