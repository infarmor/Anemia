#!/usr/bin/env python3
"""Writes the `health` fixture: one tunnel-health case per tab-separated line.

Columns: label, mode, ms, prevUp, prevDown, curUp, curDown, latency, limit,
sendFloor, startFailures.  Empty means "nil" (no answer, no previous reading,
the policy's own default), and the golden next to it is what `LoaderTool health`
answers for these lines.
"""
import pathlib

COLS = 12
E = ""
ROWS = [
    # ── xray: один настоящий запрос через живое соединение ───────────────────
    ("xray-no-answer", "xray", E, E, E, E, E, E, E, E, "0"),
    ("xray-fast", "xray", "42", E, E, E, E, E, E, E, "0"),
    ("xray-slow", "xray", "3001", E, E, E, E, E, E, E, "0"),
    ("xray-limit-exact", "xray", "3000", E, E, E, E, E, E, E, "0"),
    ("xray-zero", "xray", "0", E, E, E, E, E, E, E, "0"),
    ("xray-custom-limit-over", "xray", "800", E, E, E, E, E, "500", E, "0"),
    ("xray-custom-limit-exact", "xray", "500", E, E, E, E, E, "500", E, "0"),
    ("xray-resets-streak", "xray", "42", E, E, E, E, E, E, E, "3"),
    ("xray-grows-streak", "xray", E, E, E, E, E, E, E, E, "2"),
    ("xray-ignores-counters", "xray", "42", "9", "9", "9", "9", "77", E, E, "0"),
    # ── AmneziaWG: только дельты счётчиков ───────────────────────────────────
    ("awg-first-reading", "awg", E, E, E, "100", "50", E, E, E, "0"),
    ("awg-received-latency-nil", "awg", E, "100", "100", "100", "150", E, E, E, "0"),
    ("awg-received-with-latency", "awg", E, "100", "100", "100", "150", "88", E, E, "0"),
    ("awg-engine-silent", "awg", E, "100", "100", E, E, "88", E, E, "3"),
    ("awg-sent-over-floor", "awg", E, "100", "100", "2101", "100", E, E, E, "0"),
    ("awg-sent-floor-exact", "awg", E, "100", "100", "2100", "100", E, E, E, "1"),
    ("awg-idle", "awg", E, "100", "100", "100", "100", E, E, E, "4"),
    ("awg-counters-reset", "awg", E, "100", "100", "50", "10", E, E, E, "1"),
    ("awg-received-wins", "awg", E, "100", "100", "6000", "101", E, E, E, "2"),
    ("awg-custom-floor-over", "awg", E, "100", "100", "111", "100", E, E, "10", "0"),
    ("awg-custom-floor-exact", "awg", E, "100", "100", "110", "100", E, E, "10", "0"),
    ("awg-resets-streak", "awg", E, "100", "100", "100", "101", "5", E, E, "5"),
    ("awg-grows-streak", "awg", E, "100", "100", "5000", "100", E, E, E, "1"),
    ("awg-silence-keeps-streak", "awg", E, "100", "100", "1000", "100", E, E, E, "0"),
    # ── отчёт до шага: молчание обязано оставить прежнее число, а вердикт —
    #    заменить его, даже когда отказ приходит после ответа ────────────────
    ("awg-silence-keeps-report", "awg", E, "100", "100", "100", "100", E, E, E, "4", "77"),
    ("awg-first-reading-with-report", "awg", E, E, E, "100", "100", E, E, E, "0", "12"),
    ("xray-overwrites-report", "xray", "42", E, E, E, E, E, E, E, "0", "999"),
    ("xray-no-answer-over-report", "xray", E, E, E, E, E, E, E, E, "2", "999"),
    ("bad-starthealth", "xray", "42", E, E, E, E, E, E, E, "0", "abc"),
    # ── битые строки: отказ обязан называть себя, а не превращаться в вердикт ─
    ("bad-mode", "wg", E, E, E, E, E, E, E, E, "0"),
    ("bad-ms", "xray", "abc", E, E, E, E, E, E, E, "0"),
    ("half-previous", "awg", E, "5", E, "100", "100", E, E, E, "0"),
    ("half-counters", "awg", E, "5", "5", "100", E, E, E, E, "0"),
    ("no-start", "xray", "42", E, E, E, E, E, E, E, E),
    ("counters-over-int32", "awg", E, "0", "0", "2147483648", "0", E, E, E, "0"),
    ("nan-limit", "xray", "42", E, E, E, E, E, "nan", E, "0"),
    ("few-columns", "xray", "42", E, E, E, E, E, E, E),
]


def main() -> None:
    path = (pathlib.Path(__file__).resolve().parent.parent
            / "core/src/test/resources/health/cases.txt")
    path.parent.mkdir(parents=True, exist_ok=True)
    def cells(row):
        row = list(row) + [E] * (COLS - len(row))
        assert len(row) == COLS, row
        return "\t".join(row)

    lines = [cells(row) for row in ROWS]
    # Строка без ярлыка — все колонки на месте, первое поле пустое.
    lines.append(cells(["", "xray", "42", "", "", "", "", "", "", "", "0"]))
    path.write_text("\n".join(lines) + "\n")
    for line in lines:
        assert len(line.split("\t")) == COLS, line
    print(f"→ {path.name}: {len(lines)} кейсов")


if __name__ == "__main__":
    main()
