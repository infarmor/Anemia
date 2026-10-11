//go:build android

// Android-половина интерфейса движка. Здесь туннель не надо искать:
// VpnService.Builder.establish() возвращает дескриптор, и Kotlin передаёт его
// в AnemiaStartXray/AnemiaStartAWG явно. Символ оставлен, чтобы C-поверхность
// библиотеки не зависела от платформы, — он просто всегда отвечает «не найдено».

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	awgtun "github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"golang.org/x/sys/unix"
)

// tunFdReleasedByEngine: `AndroidTun.Close()` в xray-core не делает ничего,
// так что после `instance.Close()` дубль дескриптора ещё открыт и ядро держит
// туннель живым — закрываем его сами.
const tunFdReleasedByEngine = false

// openTUNDevice оборачивает дескриптор от establish() в устройство AmneziaWG.
//
// Обычный путь (CreateTUNFromFile) на GOOS=android берётся из linux-ветки,
// которая настраивает интерфейс сама: поднимает netlink-слушателя и вызывает
// SIOCSIFMTU. Интерфейс здесь принадлежит не нам, а VpnService: MTU у него
// уже выставлен, а поменять его можно только с CAP_NET_ADMIN, которого у
// приложения нет — попытка кончается ошибкой, и туннель не поднимается вовсе.
// Unmonitored-вход делает ровно то, что нужно: оборачивает готовый
// дескриптор, ничего не настраивает и закрывает его на Close().
//
// Дескриптор передаётся этой функции в собственность: `startAWG` на ошибку
// больше не закрывает его (на darwin это было бы двойное закрытие). А здесь
// закрыть надо — `CreateUnmonitoredTUNFromFD` после `os.NewFile` возвращается
// с ошибкой, оставив файл открытым (TUNGETIFF на дескрипторе от establish() —
// как раз тот путь, где это бывает), и убегать ему некуда.
func openTUNDevice(fd int) (awgtun.Device, error) {
	device, _, err := awgtun.CreateUnmonitoredTUNFromFD(fd)
	if err != nil {
		unix.Close(fd)
	}
	return device, err
}

// AnemiaFindTunnelFD — на Android дескриптор даёт система по запросу
// establish(), поэтому здесь он всегда -1.
//
//export AnemiaFindTunnelFD
func AnemiaFindTunnelFD() C.int { return -1 }
