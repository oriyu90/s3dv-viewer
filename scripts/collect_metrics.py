#!/usr/bin/env python3
"""Turns runs/viewer_verify/*.json into the markdown table used by README §6.

Usage:  python3 scripts/collect_metrics.py [--dir DIR] [--write PATH]
The table is derived only from the self-test reports, so it cannot drift from
what the runs actually measured.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

CASES = [
    ("demo_product", "デモ（標準・バッチ）"),
    ("demo_parity", "デモ（研究パリティ）"),
    ("const_product", "東京 const 244 MB"),
    ("gt_product_2g", "東京 GT 1.27 GB（予算2GB）"),
    ("gt_product_384m", "東京 GT 1.27 GB（予算384MB）"),
    ("model_product", "東京 model 1.33 GB"),
    ("leak_repeat10", "リーク（10周）"),
]


def load(path: pathlib.Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except Exception:
        return None


def fmt_int(value) -> str:
    if value is None:
        return "—"
    try:
        return f"{int(round(float(value))):,}"
    except (TypeError, ValueError):
        return "—"


def fmt_mb(value) -> str:
    if value is None:
        return "—"
    try:
        return f"{float(value):.0f}"
    except (TypeError, ValueError):
        return "—"


def row(key: str, label: str, report: dict | None) -> str:
    if report is None:
        return f"| {label} | — | — | — | — | — | — | — | 未実行 |"
    viewer = report.get("viewer") or {}
    stats = report.get("stats") or {}
    verdict = report.get("verdict", "?")
    mark = "✅" if verdict == "pass" else ("⏱" if verdict == "timeout" else "❌")
    applied = viewer.get("packets")
    sent = stats.get("framesSent") or stats.get("packetsSent")
    parity = f"{fmt_int(applied)}/{fmt_int(sent)}" if applied is not None else "—"
    return "| {label} | {mark} | {parity} | {chunks} | {tris} | {draw} | {peak} | {bench} | {secs} |".format(
        label=label,
        mark=mark,
        parity=parity,
        chunks=fmt_int(stats.get("residentChunks")),
        tris=fmt_int(stats.get("residentTriangles")),
        draw=fmt_int(stats.get("evictionsTotal") or stats.get("evictions")),
        peak=fmt_mb(report.get("peakMB")),
        bench=(f"{float(report['benchFrameMS']):.0f}" if isinstance(report.get("benchFrameMS"), (int, float))
               and report["benchFrameMS"] > 0 else "—"),
        secs=(f"{float(report['elapsedSeconds']):.0f}" if isinstance(report.get("elapsedSeconds"), (int, float))
              else "—"),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dir", default=str(pathlib.Path(__file__).resolve().parent.parent / "runs/viewer_verify"))
    parser.add_argument("--write", default="")
    args = parser.parse_args()
    directory = pathlib.Path(args.dir)

    lines = [
        "| ケース | 判定 | 適用÷送信フレーム | 常駐チャンク※ | 常駐三角形※ | 退避 | アプリ最大MB | bench ms/frame | 秒 |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for key, label in CASES:
        lines.append(row(key, label, load(directory / f"{key}.json")))
    table = "\n".join(lines)

    print(table)
    if args.write:
        pathlib.Path(args.write).write_text(table + "\n")
        print(f"\nwritten: {args.write}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
