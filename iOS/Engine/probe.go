package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	applog "github.com/xtls/xray-core/app/log"
	commonlog "github.com/xtls/xray-core/common/log"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
)

// Real checks: a request that actually travels through a proxy, rather than a
// handshake with the server. A server can answer the handshake and still not
// carry traffic (a wrong key, a blocked path behind it).

type probeRequest struct {
	ID     string `json:"id"`
	Config string `json:"config"`
}

type probeResult struct {
	ID string `json:"id"`
	// Milliseconds to the response headers; -1 when the request failed.
	Ms    int64  `json:"ms"`
	Error string `json:"error,omitempty"`
}

// AnemiaProbe checks servers for real: each gets a temporary Xray instance
// (outbounds only) and one GET of url through it. requests is a JSON array of
// {"id", "config"}; the answer is a JSON array of {"id", "ms", "error"}.
// Blocks until every server is done; at most `concurrency` run at once.
//
//export AnemiaProbe
func AnemiaProbe(requests *C.char, target *C.char, timeoutMs C.int, concurrency C.int) *C.char {
	results := runProbeBatch(C.GoString(requests), C.GoString(target),
		time.Duration(timeoutMs)*time.Millisecond, int(concurrency))
	data, _ := json.Marshal(results)
	return C.CString(string(data))
}

// runProbeBatch checks every request; results keep the request order.
func runProbeBatch(requests, target string, timeout time.Duration, concurrency int) []probeResult {
	var list []probeRequest
	if err := json.Unmarshal([]byte(requests), &list); err != nil {
		return []probeResult{}
	}
	results := make([]probeResult, len(list))
	slots := make(chan struct{}, max(concurrency, 1))
	var wg sync.WaitGroup
	for i, request := range list {
		wg.Add(1)
		slots <- struct{}{}
		go func(i int, request probeRequest) {
			defer wg.Done()
			defer func() { <-slots }()
			result := probeResult{ID: request.ID, Ms: -1}
			if ms, err := probeOne(request.Config, target, timeout); err != nil {
				result.Error = err.Error()
			} else {
				result.Ms = ms
			}
			results[i] = result
		}(i, request)
	}
	wg.Wait()
	return results
}

// AnemiaCheckActive times one GET of url through the running Xray instance:
// whether the tunnel carries traffic right now. Returns milliseconds, -1 when
// the request failed, -2 when Xray isn't running.
//
//export AnemiaCheckActive
func AnemiaCheckActive(target *C.char, timeoutMs C.int) C.longlong {
	mu.Lock()
	running := xray
	mu.Unlock()
	if running == nil {
		return -2
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	elapsed, err := fetch(ctx, running, C.GoString(target))
	if err != nil {
		logf("[Anemia] health check failed: %v", err)
		return -1
	}
	return C.longlong(max(elapsed.Milliseconds(), 1))
}

func probeOne(config, target string, timeout time.Duration) (int64, error) {
	cfg, err := serial.LoadJSONConfig(strings.NewReader(config))
	if err != nil {
		return -1, fmt.Errorf("config: %w", err)
	}
	instance, err := core.New(cfg)
	restoreLogHandler()
	if err != nil {
		return -1, err
	}
	defer func() {
		instance.Close()
		restoreLogHandler()
	}()
	if err := instance.Start(); err != nil {
		return -1, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	elapsed, err := fetch(ctx, instance, target)
	if err != nil {
		return -1, err
	}
	return max(elapsed.Milliseconds(), 1), nil
}

// fetch times one GET through instance, up to the response headers. The
// dispatched connections live as long as ctx.
func fetch(ctx context.Context, instance *core.Instance, target string) (time.Duration, error) {
	client, closeIdle := httpClientThrough(ctx, instance)
	defer closeIdle()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, err
	}
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return 0, plainError(err)
	}
	elapsed := time.Since(start)
	response.Body.Close()
	if response.StatusCode >= 400 {
		return 0, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	return elapsed, nil
}

// httpClientThrough makes an HTTP client whose connections are dispatched
// through instance — that is, through whatever route the running tunnel
// carries. Not keep-alive: each call gets a fresh routed connection, so a
// server answer cannot be a leftover from before the tunnel came up.
func httpClientThrough(ctx context.Context, instance *core.Instance) (*http.Client, func()) {
	transport := &http.Transport{
		DialContext: func(_ context.Context, _, addr string) (net.Conn, error) {
			dest, err := xnet.ParseDestination("tcp:" + addr)
			if err != nil {
				return nil, err
			}
			return core.Dial(ctx, instance, dest)
		},
		DisableKeepAlives: true,
	}
	return &http.Client{
		Transport: transport,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}, transport.CloseIdleConnections
}

// fetchBody asks target through instance and keeps the answer: what came back,
// how much of it there was, and how long it took. limit caps the returned
// body — the caller reads an address or a JSON report, not a megabyte — while
// bytes counts everything the server sent, which is what a throughput measure
// needs.
func fetchBody(ctx context.Context, instance *core.Instance, target string, limit int) (time.Duration, int64, string, error) {
	client, closeIdle := httpClientThrough(ctx, instance)
	defer closeIdle()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return 0, 0, "", err
	}
	request.Header.Set("User-Agent", "Anemia")
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		return 0, 0, "", plainError(err)
	}
	defer response.Body.Close()
	if response.StatusCode >= 400 {
		return 0, 0, "", fmt.Errorf("HTTP %d", response.StatusCode)
	}
	var kept []byte
	var total int64
	buffer := make([]byte, 32*1024)
	for {
		read, err := response.Body.Read(buffer)
		if read > 0 {
			total += int64(read)
			if limit > 0 && len(kept) < limit {
				take := read
				if len(kept)+take > limit {
					take = limit - len(kept)
				}
				kept = append(kept, buffer[:take]...)
			}
		}
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return 0, total, "", plainError(err)
		}
		if ctx.Err() != nil {
			return 0, total, "", plainError(ctx.Err())
		}
	}
	return time.Since(start), total, string(kept), nil
}

// AnemiaFetch asks url through the *running* tunnel and answers with JSON:
// {"ms":…,"bytes":…,"body":"…"}, the body cut to maxBytes; {"error":"…"} when
// the request failed, and an empty string when no tunnel is up.
//
// It exists because on Android the app cannot ask this about itself: its own
// UID is excluded from the tunnel it raises (`addDisallowedApplication`), and
// binding a socket to the tunnel's network is refused — measured on the
// emulator, `Binding socket to network N failed: EPERM`, both with a plain
// `allNetworks` handle and with a live `requestNetwork`. Only the engine
// carries traffic out of the exit, so the leak screen's "what sites see" is a
// request the engine makes on the app's behalf. The same door gives the speed
// test a way to move bytes through the tunnel: `bytes` counts all of them,
// `body` is only what the caller asked to keep.
//
//export AnemiaFetch
func AnemiaFetch(url *C.char, timeoutMs C.int, maxBytes C.int) *C.char {
	mu.Lock()
	running := xray
	mu.Unlock()
	if running == nil {
		return C.CString("")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	elapsed, bytes, body, err := fetchBody(ctx, running, C.GoString(url), int(maxBytes))
	if err != nil {
		data, _ := json.Marshal(fetchAnswer{Error: err.Error()})
		return C.CString(string(data))
	}
	data, _ := json.Marshal(fetchAnswer{
		Ms: max(elapsed.Milliseconds(), 1), Bytes: bytes, Body: body,
	})
	return C.CString(string(data))
}

type fetchAnswer struct {
	Ms    int64  `json:"ms,omitempty"`
	Bytes int64  `json:"bytes,omitempty"`
	Body  string `json:"body,omitempty"`
	Error string `json:"error,omitempty"`
}

// restoreLogHandler: every Xray instance registers its logger globally when
// it is created, and a closed one swallows everything. Hand logging back to
// the running tunnel after a probe instance comes or goes.
//
// The read and the registration happen under the same lock: released in
// between, a tunnel starting right now loses — its instance registers the
// good handler, then this writes back the old, already-closed one, and the
// engine log stays dead for the rest of the session.
func restoreLogHandler() {
	mu.Lock()
	defer mu.Unlock()
	if xray == nil {
		return
	}
	if logger, ok := xray.GetFeature((*applog.Instance)(nil)).(*applog.Instance); ok {
		commonlog.RegisterHandler(logger)
	}
}

// plainError drops the "Get \"https://…\":" wrapper around the cause.
func plainError(err error) error {
	var urlError *url.Error
	if errors.As(err, &urlError) {
		err = urlError.Err
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return errors.New("timeout")
	}
	return err
}
