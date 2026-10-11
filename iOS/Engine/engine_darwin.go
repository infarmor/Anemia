//go:build darwin

// Darwin-only половина интерфейса движка. NetworkExtension не отдаёт туннель
// дескриптором в руки: процесс получает utun, открытый системой, и его ещё
// нужно найти среди сокетов этого процесса.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"os"
	"strings"

	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/unix"
)

// sysprotoControl / utunOptIfname: <sys/kern_control.h>, <net/if_utun.h>.
const (
	sysprotoControl = 2
	utunOptIfname   = 2
)

// tunFdReleasedByEngine: наша ли ветка `tun` отпускает дубль дескриптора.
// Патченная iOS-ветка (`tun_darwin.go`, `ownsFd: true`) владеет им и закрывает
// сама на `Instance.Close()`, поэтому второй `unix.Close` того же номера был бы
// закрытием чужого дескриптора.
const tunFdReleasedByEngine = true

// openTUNDevice wraps the utun descriptor NetworkExtension opened for this
// process. MTU 0: the tunnel settings already carry it, and unlike the linux
// branch this one asks for none.
func openTUNDevice(fd int) (awgtun.Device, error) {
	return awgtun.CreateTUNFromFile(os.NewFile(uintptr(fd), "utun"), 0)
}

// AnemiaFindTunnelFD returns the utun descriptor NetworkExtension opened for
// this process, or -1. Call it after setTunnelNetworkSettings.
//
//export AnemiaFindTunnelFD
func AnemiaFindTunnelFD() C.int {
	// Highest number first. iOS reuses this process across restarts, and a
	// utun control socket still open from an earlier session has a *lower*
	// number than the one NetworkExtension just made — binding the engine to
	// it gives a tunnel that handshakes, counts nothing and never errors.
	for fd := 1023; fd >= 0; fd-- {
		sa, err := unix.Getpeername(fd)
		if err != nil {
			continue
		}
		if _, ok := sa.(*unix.SockaddrCtl); !ok {
			continue
		}
		if name, err := unix.GetsockoptString(fd, sysprotoControl, utunOptIfname); err == nil &&
			strings.HasPrefix(name, "utun") {
			logf("[Anemia] tunnel socket: fd %d = %s", fd, name)
			return C.int(fd)
		}
	}
	return -1
}
