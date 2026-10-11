#!/usr/bin/env python3
"""
Сервер-заглушка для замера скорости на эмуляторе.

Экран скорости ходит в speed.cloudflare.com (`__down?bytes=N`, `__up`). Чтобы
проверить арифметику замера — окно, бюджет, «прогретая» точка, сглаживание —
ответы должны быть *известной* скорости, а не того, что даст канал. Отладочная
сборка принимает `--es speed_base http://10.0.2.2:8098`, и тогда:

    /__down?bytes=25000000   отдаёт ровно столько байт, с паузой между чанками
    /__up                    принимает POST и отвечает размером тела

Скорость задаётся здесь (`--mbps`), и остаётся сравнить то, что покажет экран,
с этим числом: расхождение в разы значит ошибку в формуле, в десятки процентов —
плату за NAT эмулятора.
"""
import argparse
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHUNK = 256 * 1024


class Handler(BaseHTTPRequestHandler):
    mbps = 20.0

    def log_message(self, fmt, *args):
        print(f"{self.command} {self.path} <- {self.client_address[0]}", flush=True)

    def do_GET(self):
        match = re.search(r"bytes=(\d+)", self.path)
        total = int(match.group(1)) if match else 0
        delay = CHUNK * 8 / (self.mbps * 1e6)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(total))
        self.end_headers()
        block = b"x" * CHUNK
        sent = 0
        try:
            while sent < total:
                size = min(CHUNK, total - sent)
                self.wfile.write(block[:size])
                self.wfile.flush()
                sent += size
                if size == CHUNK:
                    import time
                    time.sleep(delay)
        except (BrokenPipeError, ConnectionResetError):
            # Замер могли остановить посреди отдачи — это не авария сервера.
            print(f"поток закрыт на {sent} из {total}", flush=True)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        remaining = length
        while remaining > 0:
            chunk = self.rfile.read(min(CHUNK, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", "1")
        self.end_headers()
        self.wfile.write(b"1")
        print(f"принято {length - remaining} байт", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8098)
    parser.add_argument("--mbps", type=float, default=20.0)
    args = parser.parse_args()
    Handler.mbps = args.mbps
    print(f"speed fixture: {args.mbps} Мбит/с, http://0.0.0.0:{args.port}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
