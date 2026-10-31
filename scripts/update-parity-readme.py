#!/usr/bin/env python3
"""Rewrite the PARITY block of README.md from docs/parity-status.json."""
import argparse, json, re, sys
from pathlib import Path

START, END = "<!-- PARITY:START -->", "<!-- PARITY:END -->"
REPO = "https://github.com/rpribau/smthz"


def load(text):
    try:
        d = json.loads(text)
    except ValueError as e:
        sys.exit(f"parity-status: invalid JSON: {e}")
    for k in ("updated", "method", "areas"):
        if k not in d:
            sys.exit(f"parity-status: missing key '{k}'")
    if not isinstance(d["areas"], list) or not d["areas"]:
        sys.exit("parity-status: 'areas' must be a non-empty list")
    for a in d["areas"]:
        n = a.get("name", "?")
        for k in ("id", "name", "weight", "functional", "visual"):
            if k not in a:
                sys.exit(f"parity-status: area '{n}' missing '{k}'")
        if not isinstance(a["weight"], (int, float)) or a["weight"] <= 0:
            sys.exit(f"parity-status: area '{n}' weight must be positive")
        for k in ("functional", "visual"):
            if not isinstance(a[k], (int, float)) or not 0 <= a[k] <= 100:
                sys.exit(f"parity-status: area '{n}' {k} must be 0-100")
        if not all(isinstance(i, int) for i in a.get("issues", [])):
            sys.exit(f"parity-status: area '{n}' issues must be integers")
    return d


def mean(areas, key):
    w = sum(a["weight"] for a in areas)
    return int(sum(a["weight"] * a[key] for a in areas) / w + 0.5)  # half up, not banker's


def bar(p):
    n = int(p / 10 + 0.5)
    return "█" * n + "░" * (10 - n) + f" {p}%"


def render(d):
    f, v = mean(d["areas"], "functional"), mean(d["areas"], "visual")
    rows = ["| Area | Functional | Visual | Issues |", "|---|---|---|---|"]
    for a in d["areas"]:
        iss = ", ".join(f"[#{i}]({REPO}/issues/{i})" for i in a.get("issues", [])) or "-"
        rows.append(f"| {a['name']} | {a['functional']}% | {a['visual']}% | {iss} |")
    return "\n".join([
        f"smthz is about {f}% of the way to functional parity with Orca 1.4.238 (visual: {v}%).", "",
        "```text", f"Functional  {bar(f)}", f"Visual      {bar(v)}", "```", "",
        *rows, "", d["method"], "", f"Last updated: {d['updated']}"])


def apply(readme, block):
    pat = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    if not pat.search(readme):
        sys.exit(f"README: markers {START} / {END} not found")
    return pat.sub(lambda _: f"{START}\n{block}\n{END}", readme, count=1)


def selftest():
    d = load(json.dumps({"updated": "2026-01-01", "method": "m", "areas": [
        {"id": "a", "name": "A", "weight": 1, "functional": 50, "visual": 100, "issues": [7]},
        {"id": "b", "name": "B", "weight": 3, "functional": 10, "visual": 0, "issues": []}]}))
    assert mean(d["areas"], "functional") == 20 and mean(d["areas"], "visual") == 25
    assert bar(20) == "██░░░░░░░░ 20%"
    once = apply(f"x\n{START}\nold\n{END}\ny", render(d))
    assert apply(once, render(d)) == once and "old" not in once and once.startswith("x\n") and once.endswith("\ny")
    print("selftest ok")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--status", default="docs/parity-status.json")
    p.add_argument("--readme", default="README.md")
    p.add_argument("--check", action="store_true")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()
    if a.selftest:
        return selftest()
    old = Path(a.readme).read_text()
    new = apply(old, render(load(Path(a.status).read_text())))
    if a.check:
        if new != old:
            sys.exit("README parity block is out of date: run scripts/update-parity-readme.py")
    elif new != old:
        Path(a.readme).write_text(new)


main()
