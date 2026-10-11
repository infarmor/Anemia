package main

import (
	"encoding/json"
	"testing"
)

// Статус молчаливого движка — это не «движок не ответил».
//
// `AnemiaStatus` маршалит этот же `status` и никогда не возвращает пустой
// ответ: у структуры нет `omitempty`, поэтому без туннеля все восемь ключей на
// месте, а `engine` — пустая строка и счётчики нули. Значит `Engine.status == nil`
// в расширении ловит только разошедшуюся схему, но не тишину, и «показания нет»
// в проверке здоровья AmneziaWG узнаётся по полю `engine`
// (PacketTunnelProvider.checkHealth): нуль, записанный базовой линией, делает
// следующую дельту равной всем накопленным байтам, и `received > 0` читается как
// «проверка пройдена».
//
// Проверяется само основание, а не граница C: Go запрещает cgo в _test.go, и
// `AnemiaStatus()` отсюда не позвать.
func TestIdleStatusStillCarriesEveryKey(t *testing.T) {
	data, err := json.Marshal(status{})
	if err != nil {
		t.Fatalf("нулевой статус не маршалится: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("ответ движка — не JSON: %v (%s)", err, data)
	}
	// Тот же список, что читает Swift (`Engine.Status.CodingKeys`).
	for _, key := range []string{"engine", "uptime", "up", "down", "handshake", "heap", "sys", "goroutines"} {
		if _, ok := doc[key]; !ok {
			t.Errorf("движок молчит — и всё же ключ %s потерял: %s", key, data)
		}
	}
	if doc["engine"] != "" {
		t.Errorf("без запущенного движка engine = %v, а не пустая строка", doc["engine"])
	}
	for _, key := range []string{"up", "down", "handshake"} {
		if v, ok := doc[key].(float64); !ok || v != 0 {
			t.Errorf("ключ %s без движка = %v — Swift прочтёт из этого показание", key, doc[key])
		}
	}
}
