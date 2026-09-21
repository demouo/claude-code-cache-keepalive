#!/usr/bin/env python3
"""Render docs/cost-chart-{light,dark}.svg.

Grouped horizontal bars: 10 warm pings (cache reads) vs. one cold start
(a 1-hour cache rewrite), at a 1M-token context. Data comes from
cost-table.py so the chart and the table cannot drift apart.
"""
from __future__ import annotations

import importlib.util
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cost_table", HERE / "cost-table.py")
ct = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ct)

CTX = 1_000_000  # headline context for the chart

PALETTES = {
    "light": {
        "bg": "#ffffff", "fg": "#1f2328", "muted": "#59636e",
        "grid": "#d8dee4", "warm": "#1a7f37", "cold": "#cf222e",
        "card": "#f6f8fa",
    },
    "dark": {
        "bg": "#0d1117", "fg": "#e6edf3", "muted": "#9198a1",
        "grid": "#30363d", "warm": "#3fb950", "cold": "#f85149",
        "card": "#161b22",
    },
}

W, H = 960, 452
X0, X1 = 250, 790          # plot area
TOP = 104
ROW_H = 62
BAR_H = 20
BAR_GAP = 7
SAV_X = 812
MAXV = 24.0                 # headroom so the longest bar's value label fits


def esc(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def money(x: float) -> str:
    return f"${x:,.2f}"


def short_label(label: str) -> str:
    """'Claude Opus 5 / 4.8 / 4.7 / 4.6 / 4.5' -> 'Opus 5'"""
    s = label.removeprefix("Claude ")
    return s.split(" / ")[0]


def sx(v: float) -> float:
    return X0 + (v / MAXV) * (X1 - X0)


def render(theme: str) -> str:
    p = PALETTES[theme]
    rows = []
    for label, base, read in ct.MODELS:
        mtok = CTX / 1_000_000
        warm = ct.PINGS * mtok * read
        cold = mtok * base * ct.WRITE_1H
        rows.append((short_label(label), warm, cold, cold / warm))

    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'viewBox="0 0 {W} {H}" role="img" '
             f'aria-label="10 warm pings vs one cold start at 1M context">')
    o.append(f'<rect width="{W}" height="{H}" rx="12" fill="{p["bg"]}"/>')
    o.append(f'<text x="24" y="40" fill="{p["fg"]}" '
             f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
             f'font-size="20" font-weight="700">10 warm pings vs. one cold start</text>')
    o.append(f'<text x="24" y="64" fill="{p["muted"]}" '
             f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
             f'font-size="13">Claude prompt cache · 1M-token context · USD · '
             f'warm = 10 cache reads, cold = one 1-hour cache rewrite</text>')

    # legend
    lx = 24
    ly = 84
    for text, color, dx in (("warm ×10", p["warm"], 0), ("cold ×1", p["cold"], 150)):
        o.append(f'<rect x="{lx + dx}" y="{ly - 9}" width="12" height="12" rx="2" fill="{color}"/>')
        o.append(f'<text x="{lx + dx + 18}" y="{ly + 1}" fill="{p["muted"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="12">{text}</text>')

    # grid + x ticks
    for v in (0, 5, 10, 15, 20):
        x = sx(v)
        o.append(f'<line x1="{x:.1f}" y1="{TOP - 8}" x2="{x:.1f}" y2="{TOP + len(rows) * ROW_H - 18}" '
                 f'stroke="{p["grid"]}" stroke-width="1"/>')
        o.append(f'<text x="{x:.1f}" y="{TOP + len(rows) * ROW_H - 2}" fill="{p["muted"]}" '
                 f'text-anchor="middle" font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="11">{money(float(v))}</text>')

    for i, (label, warm, cold, ratio) in enumerate(rows):
        y = TOP + i * ROW_H
        # model label
        o.append(f'<text x="24" y="{y + BAR_H + 2}" fill="{p["fg"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="13" font-weight="600">{esc(label)}</text>')
        # warm bar
        ww = sx(warm) - X0
        o.append(f'<rect x="{X0}" y="{y}" width="{ww:.1f}" height="{BAR_H}" rx="4" fill="{p["warm"]}"/>')
        o.append(f'<text x="{X0 + ww + 8:.1f}" y="{y + BAR_H - 5}" fill="{p["muted"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="12">{money(warm)}</text>')
        # cold bar
        cw = sx(cold) - X0
        o.append(f'<rect x="{X0}" y="{y + BAR_H + BAR_GAP}" width="{cw:.1f}" height="{BAR_H}" '
                 f'rx="4" fill="{p["cold"]}"/>')
        o.append(f'<text x="{X0 + cw + 8:.1f}" y="{y + 2 * BAR_H + BAR_GAP - 5}" fill="{p["muted"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="12">{money(cold)}</text>')
        # savings
        o.append(f'<text x="{SAV_X}" y="{y + BAR_H + 2}" fill="{p["warm"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="15" font-weight="700">{ratio:.0f}×</text>')
        o.append(f'<text x="{SAV_X}" y="{y + BAR_H + 18}" fill="{p["muted"]}" '
                 f'font-family="system-ui,-apple-system,Segoe UI,Roboto,sans-serif" '
                 f'font-size="11">cheaper</text>')

    o.append('</svg>')
    return "\n".join(o)


def main() -> None:
    for theme in ("light", "dark"):
        out = HERE / f"cost-chart-{theme}.svg"
        out.write_text(render(theme) + "\n")
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
