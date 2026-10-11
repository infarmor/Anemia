#!/usr/bin/env python3
"""
Сервер-заглушка для проверки утечек на эмуляторе.

Экран утечек ходит в ip.sb, Cloudflare и bash.ws. На устройстве нельзя
подменить их ответы, не подменив DNS, поэтому отладочная сборка умеет
`--es leak_base http://10.0.2.2:8099`: приложение идёт по тем же путям, но
ответы даёт этот сервер, и форма ответов — настоящая форма сервисов (её разбирает
`LeakCheck.parse*`, сверенный с Swift эталонами).

Два режима — чтобы на экране можно было увидеть и утечку, и её отсутствие:

    --mode leak   выход в NL, провайдер в DE, IPv6 в DE, резолверы DE + US
                  → «Найдены утечки»: IPv6 выдаёт адрес, DNS видит провайдер
    --mode clean  выход в NL, провайдер в DE, IPv6 в NL, резолверы только US
                  → «Утечек нет»

Каждый запрос печатается с путём и адресом клиента: по этому логу и по
`tunnel-access.log` движка видно, сколько ходов прошало через туннель, а
сколько ушло мимо него (ход «без VPN» обязан быть один).
"""
import argparse
import json
import random
import string
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PLANTED = {
    "leak": {
        "exit": {"ip": "203.0.113.7", "country_code": "NL", "country": "Netherlands",
                 "city": "Amsterdam", "isp": "Exit Provider AS64500"},
        "ipv6": {"ip": "2001:db8:dead::beef", "country_code": "DE", "country": "Germany",
                 "city": "Frankfurt", "isp": "Home Provider AS64501"},
        "dns": [
            {"ip": "192.0.2.53", "type": "dns", "country": "DE", "country_name": "Germany",
             "org": "Home ISP"},
            {"ip": "198.51.100.53", "type": "dns", "country": "US", "country_name": "United States",
             "org": "Public Resolver"},
        ],
    },
    "clean": {
        "exit": {"ip": "203.0.113.7", "country_code": "NL", "country": "Netherlands",
                 "city": "Amsterdam", "isp": "Exit Provider AS64500"},
        "ipv6": {"ip": "2001:db8:cafe::1", "country_code": "NL", "country": "Netherlands",
                 "city": "Amsterdam", "isp": "Exit Provider AS64500"},
        "dns": [
            {"ip": "198.51.100.53", "type": "dns", "country": "US", "country_name": "United States",
             "org": "Public Resolver"},
        ],
    },
}


# Ответ для хода вне туннеля: адрес провайдера, всегда тот же, в каком бы
# режиме ни работал сервер. Без отдельного наблюдателя экран нечем было бы
# сравнить, и «выход» совпал бы с «провайдером» даже при рабочем туннеле.
HOME = {
    "ip": "198.51.100.9",
    "country_code": "DE",
    "country": "Germany",
    "city": "Berlin",
    "isp": "Home Provider AS64501",
}


class Handler(BaseHTTPRequestHandler):
    mode = "leak"
    ids = set()

    def log_message(self, fmt, *args):  # свой формат, с режимом
        print(f"[{self.mode}] {self.command} {self.path} <- {self.client_address[0]}", flush=True)

    def send(self, body, content_type):
        raw = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0]
        direct = path.startswith("/direct/")
        if direct:
            path = path[len("/direct"):]
        data = PLANTED[self.mode]
        if path == "/geoip":
            self.send(json.dumps(HOME if direct else data["exit"]), "application/json")
        elif path == "/geoip6":
            self.send(json.dumps(data["ipv6"]), "application/json")
        elif path == "/trace":
            info = HOME if direct else data["exit"]
            self.send(f"ip={info['ip']}\nloc={info['country_code']}\nslp=yes\n", "text/plain")
        elif path == "/id":
            token = "".join(random.choices(string.ascii_lowercase + string.digits, k=8))
            Handler.ids.add(token)
            self.send(token + "\n", "text/plain")
        elif path.startswith("/dnsleak/test/"):
            token = path.rsplit("/", 1)[-1]
            if token not in Handler.ids:
                self.send_error(404, "unknown id")
                return
            # Один и тот же адрес дважды: проверка «не повторять резолвер» живёт
            # в разборе, и пусть она сработает здесь, а не на телефоне.
            body = json.dumps(data["dns"] + [data["dns"][0]])
            self.send(body, "application/json")
        else:
            self.send_error(404, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=sorted(PLANTED), default="leak")
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--host", default="0.0.0.0")
    args = parser.parse_args()
    Handler.mode = args.mode
    print(f"leak fixture, режим {args.mode}, http://{args.host}:{args.port}", flush=True)
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
