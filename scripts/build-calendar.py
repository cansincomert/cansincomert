#!/usr/bin/env python3
"""Render the last 12 months of contributions as a blue GitHub-style calendar.

Third-party calendar services (ghchart et al.) cache aggressively and were
serving a stale public-only figure — 88 contributions against a real 1,329.
This asks the GraphQL API directly with our own token, so private contributions
are included, and writes assets/contributions.svg for the README to embed.

Requires: gh CLI authenticated with a token that has `repo` scope.
"""
import json
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "contributions.svg"

CELL, GAP = 11, 3
STEP = CELL + GAP
PAD_LEFT, PAD_TOP = 30, 20

# GitHub's blue scale, darkest = busiest.
LIGHT = {"NONE": "#ebedf0", "FIRST_QUARTILE": "#b6e3ff",
         "SECOND_QUARTILE": "#54aeff", "THIRD_QUARTILE": "#0969da",
         "FOURTH_QUARTILE": "#0550ae"}
DARK = {"NONE": "#161b22", "FIRST_QUARTILE": "#0a3069",
        "SECOND_QUARTILE": "#0550ae", "THIRD_QUARTILE": "#218bff",
        "FOURTH_QUARTILE": "#79c0ff"}

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

QUERY = """
query($from:DateTime!, $to:DateTime!) {
  viewer {
    contributionsCollection(from:$from, to:$to) {
      contributionCalendar {
        totalContributions
        weeks { contributionDays { date contributionCount contributionLevel weekday } }
      }
    }
  }
}
"""


def fetch(frm, to):
    out = subprocess.run(
        ["gh", "api", "graphql", "-f", f"query={QUERY}", "-F", f"from={frm}", "-F", f"to={to}"],
        capture_output=True, text=True, check=True,
    ).stdout
    return json.loads(out)["data"]["viewer"]["contributionsCollection"]["contributionCalendar"]


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def render(cal):
    weeks = cal["weeks"]
    total = cal["totalContributions"]

    width = PAD_LEFT + len(weeks) * STEP + 10
    height = PAD_TOP + 7 * STEP + 10

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" '
        f'aria-label="{total} contributions in the last year">',
        "<style>",
        "  text { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;"
        " font-size: 9px; fill: #57606a; }",
    ]
    # Level colours are driven by CSS classes so dark mode can override them.
    for lvl, col in LIGHT.items():
        parts.append(f"  .l-{lvl} {{ fill: {col}; }}")
    parts.append("  @media (prefers-color-scheme: dark) {")
    parts.append("    text { fill: #8b949e; }")
    for lvl, col in DARK.items():
        parts.append(f"    .l-{lvl} {{ fill: {col}; }}")
    parts.append("  }")
    parts.append("</style>")

    # Weekday labels — GitHub shows only Mon/Wed/Fri.
    for row, label in ((1, "Mon"), (3, "Wed"), (5, "Fri")):
        y = PAD_TOP + row * STEP + CELL - 2
        parts.append(f'<text x="0" y="{y}">{label}</text>')

    # Month labels above the first week that starts a new month.
    seen = set()
    for i, week in enumerate(weeks):
        days = week["contributionDays"]
        if not days:
            continue
        d = date.fromisoformat(days[0]["date"])
        if d.month not in seen and d.day <= 14:
            seen.add(d.month)
            x = PAD_LEFT + i * STEP
            parts.append(f'<text x="{x}" y="{PAD_TOP - 6}">{MONTHS[d.month - 1]}</text>')

    for i, week in enumerate(weeks):
        x = PAD_LEFT + i * STEP
        for day in week["contributionDays"]:
            y = PAD_TOP + day["weekday"] * STEP
            lvl = day["contributionLevel"]
            n = day["contributionCount"]
            label = f'{n} contribution{"" if n == 1 else "s"} on {day["date"]}'
            parts.append(
                f'<rect class="l-{lvl}" x="{x}" y="{y}" width="{CELL}" height="{CELL}" rx="2">'
                f"<title>{esc(label)}</title></rect>"
            )

    parts.append("</svg>")
    return "\n".join(parts), total


def main():
    today = date.today()
    frm = today - timedelta(days=364)
    cal = fetch(f"{frm}T00:00:00Z", f"{today}T23:59:59Z")
    svg, total = render(cal)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    previous = OUT.read_text(encoding="utf-8") if OUT.exists() else None
    OUT.write_text(svg, encoding="utf-8")

    print(f"calendar: {total} contributions over {len(cal['weeks'])} weeks -> {OUT.name}"
          f"{'' if previous != svg else ' (unchanged)'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
