#!/usr/bin/env python3
"""Generate the warm-10 vs cold-start cost table.

Prices are USD per 1M tokens from Anthropic's public pricing page
(platform.claude.com/docs/en/about-claude/pricing).

Rate multipliers applied to the base input price:
  cache read     0.10x   (Fable 5.1 / Mythos 5.1: 0.025x)
  5m cache write 1.25x
  1h cache write 2.00x
"""
from __future__ import annotations

PINGS = 10
CONTEXTS = [(20_000, "20K"), (100_000, "100K"), (200_000, "200K"), (1_000_000, "1M")]

# (label, base input $/MTok, cache-read $/MTok)
MODELS = [
    ("Claude Opus 5 / 4.8 / 4.7 / 4.6 / 4.5", 5.00, 0.50),
    ("Claude Sonnet 5", 2.00, 0.20),
    ("Claude Sonnet 4.6 / 4.5", 3.00, 0.30),
    ("Claude Haiku 4.5", 1.00, 0.10),
    ("Claude Fable 5.1", 10.00, 0.25),
]

WRITE_5M = 1.25
WRITE_1H = 2.00


def money(x: float) -> str:
    return f"${x:,.3f}" if x < 1 else f"${x:,.2f}"


def main() -> None:
    print("### Main table — 10 warm pings vs. one cold start (1h TTL)\n")
    print("| Model | Context | warm x10 | cold start x1 | savings |")
    print("| --- | ---: | ---: | ---: | ---: |")
    for label, base, read in MODELS:
        for n, nlabel in CONTEXTS:
            mtok = n / 1_000_000
            warm = PINGS * mtok * read
            cold = mtok * base * WRITE_1H
            print(f"| {label} | {nlabel} | {money(warm)} | {money(cold)} | **{cold / warm:.2f}x** |")

    print("\n### Break-even and the 5m TTL\n")
    print("| Model | read rate | pings to equal one 1h write | pings to equal one 5m write |")
    print("| --- | ---: | ---: | ---: |")
    for label, base, read in MODELS:
        be_1h = base * WRITE_1H / read
        be_5m = base * WRITE_5M / read
        print(f"| {label} | {read / base:.3f}x | {be_1h:.0f} | {be_5m:.0f} |")


if __name__ == "__main__":
    main()
