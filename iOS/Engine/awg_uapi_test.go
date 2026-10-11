package main

import (
	"strings"
	"testing"
)

// Рамочная строка `set=1` — часть сокетного протокола UAPI, а не тело
// операции. `device.IpcSet` зовёт `IpcSetOperation` напрямую, и та читает
// каждую строку как `ключ=значение`: `set=1` внутри неё превращается в
// неизвестный ключ `set` с `IPC error -22: invalid UAPI device key: set` —
// ровно так `awg://` и умирал на устройстве и в расширении, пока движок не
// начал срезать рамку сам.

func TestUapiBodyStripsTheFramingLine(t *testing.T) {
	script := "set=1\nprivate_key=abcd\njc=4\nreplace_peers=true\npublic_key=beef\n"
	body := uapiBody(script)
	if strings.HasPrefix(body, "set=1") {
		t.Fatalf("рамка осталась первой строкой: %q", body)
	}
	if !strings.HasPrefix(body, "private_key=") {
		t.Fatalf("срезано лишнее: %q", body)
	}
	if !strings.HasSuffix(body, "public_key=beef\n") {
		t.Fatalf("потерян конец скрипта: %q", body)
	}
	if strings.Contains(body, "set=") {
		t.Fatalf("рамка не удалена: %q", body)
	}
}

func TestUapiBodyToleratesWindowsLineEnds(t *testing.T) {
	// Эмиттер пишет `\n`, но скрипт приходит из чужого конфига и через копипаст:
	// `\r` в первой строке не должен превращать рамку в «не рамку».
	body := uapiBody("set=1\r\nprivate_key=abcd\n")
	if strings.Contains(body, "set=1") {
		t.Fatalf("рамка с \\r не снята: %q", body)
	}
}

func TestUapiBodyKeepsAnAlreadyStrippedScript(t *testing.T) {
	// Скрипт без рамки — валидный вход: сдвигать в нём ничего нельзя, иначе
	// первая настоящая настройка (`private_key`) пропала бы молча.
	script := "private_key=abcd\nlisten_port=51820\n"
	if got := uapiBody(script); got != script {
		t.Fatalf("скрипт без рамки изменён: %q", got)
	}
}

func TestUapiBodyStripsOnlyTheFirstLine(t *testing.T) {
	// `set=1` может встретиться не только в начале (чужой конфиг, склейка
	// двух скриптов). Срезается ровно одна рамка — всё остальное парсер
	// обязан увидеть сам и отвергнуть открыто, а не молча проглотить.
	script := "set=1\nprivate_key=abcd\nset=1\n"
	body := uapiBody(script)
	if strings.Count(body, "set=1") != 1 {
		t.Fatalf("срезано больше одной рамки: %q", body)
	}
}
