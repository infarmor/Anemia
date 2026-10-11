#!/usr/bin/env python3
"""Панель подписок для проверки Android-клиента (см. Android/README.md).

  /sub     — 2 ссылки base64 + заголовки панели (трафик, срок, имя)
  /rotated — те же ссылки в другом порядке (проверка переноса id)
  /empty   — 200 с телом, где нет ни одной ссылки (не должно затирать список)
  /gone    — 403, как отвечает просроченный токен
"""
import base64
import http.server
import sys

LINKS = [
    "vless://b831381d-6324-4d53-ad4f-8cda48b30811@10.0.2.2:10443?type=tcp#Первый",
    "ss://YWVzLTI1Ni1nY206c2VjcmV0MTIz@10.0.2.2:8388#Второй",
]
EXPIRE = 4_102_444_800  # 2100 год, чтобы проверка «просрочено» не срабатывала


class Handler(http.server.BaseHTTPRequestHandler):
    served = 0

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        ua = self.headers.get("User-Agent", "")
        # /sub каждый раз отдаёт ссылки в другом порядке: так видно, что
        # `обновить` переносит id, а не выдаёт новые. Счётчик — только по
        # /sub: иначе посторонний запрос (404, проверка живости) сдвигал бы
        # чётность, и свойство «порядок меняется» исчезало бы молча.
        path = self.path.strip("/")
        if path == "sub":
            Handler.served += 1
            links = list(reversed(LINKS)) if Handler.served % 2 else LINKS
        else:
            links = list(reversed(LINKS)) if path == "rotated" else None
        if path in ("sub", "rotated"):
            body = base64.b64encode("\n".join(links).encode())
            self._send(200, body, {
                "Content-Type": "text/plain; charset=utf-8",
                "subscription-userinfo": "upload=1024; download=204800; total=1073741824; expire=%d" % EXPIRE,
                "profile-title": "Test Panel",
                "profile-update-interval": "24",
                "seen-user-agent": ua,
            })
        elif path == "empty":
            self._send(200, "это не подписка, а страница перехвата сети".encode("utf-8"),
                       {"Content-Type": "text/html"})
        elif path == "gone":
            self._send(403, b"token expired")
        else:
            self._send(404, b"")

    def log_message(self, format, *args):
        sys.stderr.write("панель: " + (format % args) + " ua=%s\n" % self.headers.get("User-Agent"))


if __name__ == "__main__":
    http.server.HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
