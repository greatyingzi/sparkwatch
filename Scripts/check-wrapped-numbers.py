#!/usr/bin/env python3
"""Detect "a number got split across two lines" in a rendered UI PNG.

Why a script: the wrapped-number bug looks like a layout quirk in a screenshot and is
easy to wave away, while the actual signature is mechanical — a line whose only word is
a number fragment, or a unit token sitting alone on its own line, or a number ending a
line with its unit starting the next one at nearly the same x. OCR word boxes give
exactly that.

Usage: python3 check-wrapped-numbers.py <png> [more.png ...]
"""
import re
import subprocess
import sys

NUMBER = re.compile(r"^\d[\d.,]*$")
FRAGMENT = re.compile(r"^\d[\d.,]*[kKMG]?$|^[kKMG]$")
UNIT = re.compile(r"^(tok/s|/s|t/s|MB/s|GB/s|KB/s|B/s|ms|s|W|GB|MiB|GiB|%)$", re.I)


def lines(path):
    """[(page, line_key, y, [(word, x)])] from tesseract's TSV."""
    tsv = subprocess.run(
        ["tesseract", path, "stdout", "-l", "chi_sim+eng", "--psm", "6", "tsv"],
        capture_output=True, text=True, errors="replace",
    ).stdout
    grouped = {}
    for row in tsv.splitlines()[1:]:
        parts = row.split("\t")
        if len(parts) < 12:
            continue
        try:
            page, block, par, line, left = int(parts[1]), int(parts[2]), int(parts[3]), int(parts[4]), int(parts[6])
            top, width, height = int(parts[7]), int(parts[8]), int(parts[9])
        except ValueError:
            continue
        text = parts[11].strip()
        if not text:
            continue
        key = (page, block, par, line)
        grouped.setdefault(key, []).append((left, top, width, height, text))
    out = []
    for key, words in grouped.items():
        words.sort()
        out.append((key, words))
    # order lines top-to-bottom, left-to-right
    out.sort(key=lambda item: (item[1][0][1], item[1][0][0]))
    return out


def check(path):
    findings = []
    rows = lines(path)
    for index, (key, words) in enumerate(rows):
        joined = " ".join(w[4] for w in words)
        # 1) a line whose only content is a numeric fragment
        if len(words) == 1 and FRAGMENT.match(words[0][4]) and not NUMBER.match(words[0][4]):
            findings.append(f"  单字碎片行: {joined!r} @y={words[0][1]}")
        # 2) a line whose only content is a unit token
        if len(words) == 1 and UNIT.match(words[0][4]):
            findings.append(f"  单字单位行: {joined!r} @y={words[0][1]}")
        # 3) a line ending in a number, next line starting with a unit at similar x
        if index + 1 < len(rows):
            nxt_words = rows[index + 1][1]
            last = words[-1]
            first = nxt_words[0]
            gap = abs(first[1] - last[1])
            if NUMBER.match(last[4].rstrip(".,")) and UNIT.match(first[4]) and gap < 40:
                findings.append(
                    f"  数字与单位跨行: {last[4]!r} (y={last[1]}) → {first[4]!r} (y={first[1]}, Δx={gap})"
                )
            if FRAGMENT.match(last[4]) and first[4][:1].isdigit() and gap < 40:
                findings.append(
                    f"  数字被拆两行: {last[4]!r} (y={last[1]}) → {first[4]!r} (y={first[1]}, Δx={gap})"
                )
    print(f"{path}: {'发现 ' + str(len(findings)) + ' 处' if findings else '未发现数字折行'}")
    for finding in findings:
        print(finding)
    return len(findings)


if __name__ == "__main__":
    total = sum(check(p) for p in sys.argv[1:])
    print(f"合计 {total} 处")
