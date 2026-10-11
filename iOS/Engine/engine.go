// Anemia's tunnel engine: Xray-core and AmneziaWG in one Go runtime, built as
// a C archive for the iOS packet-tunnel extension (Scripts/build-engine.sh).
//
// A process can host only one Go runtime, so both engines share this archive
// and one runs at a time. The extension passes the utun descriptor that
// NetworkExtension owns; each engine start takes its own dup of it and closes
// that dup when it stops, so the original always stays with the system.
//
// Every exported function is safe to call from any thread. Strings returned to
// C are malloc'ed; release them with AnemiaFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"time"
	"unsafe"

	awgconn "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	awgdevice "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/xtls/xray-core/common/platform"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
	"golang.org/x/sys/unix"
)

// tunInboundTag marks the inbound that reads the tunnel. It is started only
// after the rest of the instance is up (see startXray).
const tunInboundTag = "tun-in"

func main() {}

var (
	mu        sync.Mutex
	xray      *core.Instance
	awg       *awgdevice.Device
	engine    string
	startedAt time.Time
	// Дескриптор, продублированный для xray. Кто его отпускает, зависит от
	// платформы: `AndroidTun.Close()` в xray-core ничего не делает, так что на
	// Android после `instance.Close()` он всё ещё открыт — и ядро держит
	// туннель живым, пока мы его не закроем. Патченная iOS-ветка (`ownsFd: true`,
	// `tun_darwin.go`) владеет им и закрывает сама; там закрытие номер второй раз
	// означало бы закрыть дескриптор, который к этому моменту уже выдал чужой
	// `open()`. AmneziaWG таким не страдает: `NativeTun.Close()` закрывает файл
	// сам на обеих платформах, поэтому там за нами ничего не остаётся.
	xrayFD = -1
)

// AnemiaStartXray starts Xray-core with a JSON config whose tunnel inbound
// (protocol "tun", tag "tun-in") reads from tunFD. Returns NULL on success,
// otherwise the error text.
//
//export AnemiaStartXray
func AnemiaStartXray(config *C.char, tunFD C.int) *C.char {
	return cError(startXray(C.GoString(config), int(tunFD)))
}

// AnemiaStartAWG starts AmneziaWG on tunFD and applies a UAPI `set=1` script.
// Returns NULL on success, otherwise the error text.
//
//export AnemiaStartAWG
func AnemiaStartAWG(uapi *C.char, tunFD C.int) *C.char {
	return cError(startAWG(C.GoString(uapi), int(tunFD)))
}

// AnemiaStop stops whichever engine runs. Safe to call when none does.
//
//export AnemiaStop
func AnemiaStop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

// AnemiaNetworkChanged tells the engine that the device's network path changed
// (Wi-Fi ↔ cellular): AmneziaWG rebinds its sockets. Xray needs nothing —
// its next dial simply takes the new path.
//
//export AnemiaNetworkChanged
func AnemiaNetworkChanged() {
	mu.Lock()
	defer mu.Unlock()
	if awg != nil {
		if err := awg.BindUpdate(); err != nil {
			logf("[AWG] rebind after network change: %v", err)
		}
	}
}

// AnemiaStatus returns the running engine's counters as JSON.
//
//export AnemiaStatus
func AnemiaStatus() *C.char {
	mu.Lock()
	defer mu.Unlock()

	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	s := status{
		Engine:     engine,
		Heap:       m.HeapInuse,
		Sys:        m.Sys - m.HeapReleased,
		Goroutines: runtime.NumGoroutine(),
	}
	if engine != "" {
		s.Uptime = time.Since(startedAt).Seconds()
	}
	switch {
	case xray != nil:
		s.Up, s.Down = xrayTraffic(xray)
	case awg != nil:
		s.Up, s.Down, s.Handshake = awgTraffic(awg)
	}
	data, _ := json.Marshal(s)
	return C.CString(string(data))
}

type status struct {
	Engine string  `json:"engine"`
	Uptime float64 `json:"uptime"`
	Up     int64   `json:"up"`
	Down   int64   `json:"down"`
	// Unix time of AmneziaWG's latest handshake; 0 before the first one.
	Handshake  int64  `json:"handshake"`
	Heap       uint64 `json:"heap"`
	Sys        uint64 `json:"sys"`
	Goroutines int    `json:"goroutines"`
}

// AnemiaSetMemoryLimit keeps the Go heap under limitBytes. A packet-tunnel
// extension is killed at ~50 MB of footprint, Go and Swift memory together.
//
//export AnemiaSetMemoryLimit
func AnemiaSetMemoryLimit(limitBytes C.longlong) {
	if limitBytes > 0 {
		debug.SetMemoryLimit(int64(limitBytes))
	}
	// Collect at +50% heap growth instead of +100%: slower bursts toward
	// the limit, at a small CPU cost.
	debug.SetGCPercent(50)
}

// AnemiaSetLogDirectory starts a fresh engine.log in dir and routes Go
// crash reports to crash.log there. Returns NULL or the error text.
//
//export AnemiaSetLogDirectory
func AnemiaSetLogDirectory(dir *C.char) *C.char {
	return cError(setLogDirectory(C.GoString(dir)))
}

// AnemiaVersion describes the linked engines, e.g.
// "Xray 26.3.27 (xray-core v1.260327.0), amneziawg-go v3.1.20260828".
//
//export AnemiaVersion
func AnemiaVersion() *C.char {
	parts := []string{"Xray " + core.Version()}
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			switch dep.Path {
			case "github.com/xtls/xray-core":
				patched := ""
				if dep.Replace != nil {
					patched = " + iOS patch"
				}
				parts[0] += " (xray-core " + dep.Version + patched + ")"
			case "github.com/amnezia-vpn/amneziawg-go/v3":
				parts = append(parts, "amneziawg-go "+dep.Version)
			}
		}
	}
	parts = append(parts, runtime.Version())
	return C.CString(strings.Join(parts, ", "))
}

// AnemiaFree releases a string returned by this library.
//
//export AnemiaFree
func AnemiaFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

// MARK: - Xray

func startXray(config string, tunFD int) error {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()

	cfg, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return fmt.Errorf("xray config: %w", err)
	}
	// The tunnel inbound goes in last, once everything it dispatches to
	// runs: a failed start then never leaves a stack reading the tunnel.
	var tunInbound *core.InboundHandlerConfig
	inbounds := cfg.Inbound[:0]
	for _, in := range cfg.Inbound {
		if in.Tag == tunInboundTag {
			tunInbound = in
		} else {
			inbounds = append(inbounds, in)
		}
	}
	cfg.Inbound = inbounds
	if tunInbound == nil {
		return errors.New("xray config: no \"" + tunInboundTag + "\" inbound")
	}

	instance, err := core.New(cfg)
	if err != nil {
		return fmt.Errorf("xray: %w", err)
	}
	if err := instance.Start(); err != nil {
		instance.Close()
		return fmt.Errorf("xray start: %w", err)
	}

	fd, err := dupNonblocking(tunFD)
	if err != nil {
		instance.Close()
		return err
	}
	// С этой минуты дубль наш: если запуск ниже сорвался и xray свою копию не
	// отпустил, его закрывает явный `closeXrayFD()` в ветке отказа
	// `AddInboundHandler` (на iOS `stopLocked` больше не трогает то, что
	// отдал владея патченной `DarwinTun`).
	xrayFD = fd
	// proxy/tun reads the descriptor from here (iOS mode).
	os.Setenv(platform.NormalizeEnvName(platform.TunFdKey), strconv.Itoa(fd))
	if err := core.AddInboundHandler(instance, tunInbound); err != nil {
		instance.Close()
		closeXrayFD()
		return fmt.Errorf("xray tunnel inbound: %w", err)
	}

	xray = instance
	engine = "xray"
	startedAt = time.Now()
	logf("[Anemia] xray started")
	return nil
}

func xrayTraffic(instance *core.Instance) (up, down int64) {
	manager, ok := instance.GetFeature(stats.ManagerType()).(stats.Manager)
	if !ok {
		return 0, 0
	}
	if c := manager.GetCounter("outbound>>>proxy>>>traffic>>>uplink"); c != nil {
		up = c.Value()
	}
	if c := manager.GetCounter("outbound>>>proxy>>>traffic>>>downlink"); c != nil {
		down = c.Value()
	}
	return up, down
}

// MARK: - AmneziaWG

// `IpcSet` — это тело операции `set`, а не весь разговор: рамочная строка
// `set=1` принадлежит сокетному протоколу (`IpcHandle` читает её сам и только
// после неё зовёт `IpcSetOperation`). Передать её внутрь `IpcSet` — значит
// отдать парсеру строку, где ключ называется `set`, а он отвечает на это
// `IPC error -22: invalid UAPI device key: set`. Наш эмиттер
// (`AmneziaWG.uapiScript` на Swift и `AmneziaWg.uapiScript` в `:core`) пишет
// рамку намеренно: с ней скрипт читают `Scripts/awg-harness` и золотые
// сверки, — поэтому снимается рамка, а не меняется формат.
func uapiBody(uapi string) string {
	if head, tail, found := strings.Cut(uapi, "\n"); found && strings.TrimRight(head, "\r") == "set=1" {
		return tail
	}
	return uapi
}

func startAWG(uapi string, tunFD int) error {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()

	fd, err := dupNonblocking(tunFD)
	if err != nil {
		return err
	}
	// `openTUNDevice` забирает дескриптор себе: на error-пути закрывает его
	// сама. Закрыть его здесь ещё раз — двойное закрытие чужого номера:
	// darwin-ветка (`tun_darwin.go`) вызывает `tunFile.Close()` на каждом
	// выходе с ошибкой, а освобождённый номер к этому моменту уже может
	// принадлежать сокету пинга или лога — закрыв его, мы тихо ломаем чужую
	// запись. Android-ветка закрывает явно, потому что
	// `CreateUnmonitoredTUNFromFD` ошибок не убирает.
	tunDevice, err := openTUNDevice(fd)
	if err != nil {
		return fmt.Errorf("awg tunnel: %w", err)
	}
	logger := &awgdevice.Logger{
		Verbosef: awgdevice.DiscardLogf,
		Errorf: func(format string, args ...any) {
			logf("[AWG] "+format, args...)
		},
	}
	device := awgdevice.NewDevice(tunDevice, awgconn.NewDefaultBind(), logger)
	// Before the peer exists: phones change source addresses all the time.
	device.DisableSomeRoamingForBrokenMobileSemantics()
	if err := device.IpcSet(uapiBody(uapi)); err != nil {
		device.Close()
		return fmt.Errorf("awg config: %w", err)
	}
	if err := device.Up(); err != nil {
		device.Close()
		return fmt.Errorf("awg up: %w", err)
	}

	awg = device
	engine = "awg"
	startedAt = time.Now()
	logf("[Anemia] amneziawg started")
	return nil
}

func awgTraffic(device *awgdevice.Device) (up, down, handshake int64) {
	dump, err := device.IpcGet()
	if err != nil {
		return 0, 0, 0
	}
	scanner := bufio.NewScanner(strings.NewReader(dump))
	for scanner.Scan() {
		key, value, ok := strings.Cut(scanner.Text(), "=")
		if !ok {
			continue
		}
		n, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			continue
		}
		switch key {
		case "tx_bytes":
			up += n
		case "rx_bytes":
			down += n
		case "last_handshake_time_sec":
			handshake = max(handshake, n)
		}
	}
	return up, down, handshake
}

// MARK: - Shared

func stopLocked() {
	if xray != nil {
		if err := xray.Close(); err != nil {
			logf("[Anemia] xray close: %v", err)
		}
		xray = nil
		if tunFdReleasedByEngine {
			// Инстанс был добавлен в менеджер inbound'ов (иначе `xray` не был бы
			// nil), значит патченный `AlwaysOnInboundHandler.Close()` дошёл до
			// `tun.Handler.Close()`, а тот отпустил дескриптор. Наш номер больше
			// не наш: между `Close()` и `unix.Close()` его мог занять любой
			// следующий `open()` — пинг-сокет, лог или новый utun.
			xrayFD = -1
		}
		logf("[Anemia] xray stopped")
	}
	if awg != nil {
		awg.Close()
		awg = nil
		logf("[Anemia] amneziawg stopped")
	}
	// На Android дескриптор ещё открыт: `AndroidTun.Close()` его не отпускает.
	// Не закрыть его — значит оставить системе туннель, который никто не читает.
	closeXrayFD()
	os.Unsetenv(platform.NormalizeEnvName(platform.TunFdKey))
	engine = ""
	// Hand the stopped engine's memory back before the next one starts.
	debug.FreeOSMemory()
}

// closeXrayFD отпускает дубль туннеля, выданный xray. Идемпотентно: его зовут
// и остановка, и сорвавшийся запуск.
func closeXrayFD() {
	if xrayFD >= 0 {
		unix.Close(xrayFD)
		xrayFD = -1
	}
}

func dupNonblocking(fd int) (int, error) {
	dup, err := unix.Dup(fd)
	if err != nil {
		return -1, fmt.Errorf("dup tunnel descriptor %d: %w", fd, err)
	}
	unix.CloseOnExec(dup)
	if err := unix.SetNonblock(dup, true); err != nil {
		unix.Close(dup)
		return -1, fmt.Errorf("tunnel descriptor: %w", err)
	}
	return dup, nil
}

func cError(err error) *C.char {
	if err == nil {
		return nil
	}
	logf("[Anemia] %v", err)
	return C.CString(err.Error())
}

// MARK: - Logging

var (
	logMu   sync.Mutex
	logFile *os.File
)

func setLogDirectory(dir string) error {
	logMu.Lock()
	defer logMu.Unlock()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(dir, "engine.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if logFile != nil {
		logFile.Close()
	}
	logFile = file

	crash, err := os.OpenFile(filepath.Join(dir, "crash.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer crash.Close() // SetCrashOutput keeps its own dup
	return debug.SetCrashOutput(crash, debug.CrashOptions{})
}

// logf writes one line in Xray's own timestamp format, so the engine's lines
// and Xray's (it appends to the same file) read as one log.
func logf(format string, args ...any) {
	logMu.Lock()
	defer logMu.Unlock()
	if logFile == nil {
		return
	}
	line := time.Now().Format("2006/01/02 15:04:05.000000 ") + fmt.Sprintf(format, args...)
	if !strings.HasSuffix(line, "\n") {
		line += "\n"
	}
	logFile.WriteString(line)
}
