#!/usr/bin/env bash
# Recompute commit stats across EVERY repo the token can see — owned, private,
# org-owned and collaborations — then rewrite the badge block and the project
# table between their STATS:/TABLE: markers.
#
# Why this exists: GitHub's contribution graph only credits commits in PUBLIC
# repos unless "Include private contributions on my profile" is enabled, and
# even then third-party stat cards (github-readme-stats et al.) authenticate
# with their own token and can never see private work. This counts the commits
# directly from each repo's default-branch history instead.
#
# Requires: gh CLI authenticated with a token that has `repo` scope. (`read:org`
# is only needed if EXCLUDE_RE is relaxed to let org-owned repos back in.)
# The default GITHUB_TOKEN is scoped to this repo only and CANNOT see your other
# private repos — the workflow passes a PAT via GH_TOKEN instead.
set -euo pipefail

cd "$(dirname "$0")/.."

# Repositories deliberately left out of the counts (extended regex, matched
# against "owner/name"). Client and employer work that shouldn't be advertised
# goes here — excluded repos contribute nothing to the badges or the table.
EXCLUDE_RE='^(Infinium-Vision-Intelligence/|cansincomert/infinium)'

viewer_id=$(gh api graphql -f query='{viewer{id}}' --jq '.data.viewer.id')

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# owner + collaborator + organization_member, forks excluded
gh api "user/repos?affiliation=owner,collaborator,organization_member&per_page=100" --paginate \
  --jq '.[] | select(.fork==false) | [.full_name, .private] | @tsv' \
  | grep -Ev "$EXCLUDE_RE" | sort -u > "$work/repos.tsv"

echo "counting $(wc -l < "$work/repos.tsv") repositories (excluding /$EXCLUDE_RE/)"

: > "$work/counts.tsv"

while IFS=$'\t' read -r full is_private; do
  owner=${full%%/*}; name=${full##*/}

  read -r my_c all_c <<<"$(gh api graphql \
    -f query='query($o:String!,$n:String!,$a:ID!){
      repository(owner:$o,name:$n){
        defaultBranchRef{ target{ ... on Commit {
          all:history{totalCount}
          byme:history(author:{id:$a}){totalCount}
        }}}
      }
    }' -f o="$owner" -f n="$name" -f a="$viewer_id" \
    --jq '[(.data.repository.defaultBranchRef.target.byme.totalCount // 0),
           (.data.repository.defaultBranchRef.target.all.totalCount // 0)] | @tsv' 2>/dev/null || printf '0\t0')"

  printf '%s\t%s\t%s\t%s\n' "${my_c:-0}" "${all_c:-0}" "$is_private" "$full" >> "$work/counts.tsv"
done < "$work/repos.tsv"

# Only repos I actually committed to count toward the "repositories" figures.
mine=$(awk -F'\t'   '{s+=$1} END{print s+0}'            "$work/counts.tsv")
total=$(awk -F'\t'  '$1>0 {s+=$2} END{print s+0}'       "$work/counts.tsv")
repos=$(awk -F'\t'  '$1>0' "$work/counts.tsv" | wc -l | tr -d ' ')
private=$(awk -F'\t' '$1>0 && $3=="true"' "$work/counts.tsv" | wc -l | tr -d ' ')

echo "repos=$repos private=$private mine=$mine total=$total"

COUNTS="$work/counts.tsv" MINE=$mine TOTAL=$total REPOS=$repos PRIVATE=$private python3 - <<'PY'
import os, re, html

mine, total = os.environ["MINE"], os.environ["TOTAL"]
repos, private = os.environ["REPOS"], os.environ["PRIVATE"]

# Hand-written blurbs for the projects worth naming; anything else is folded
# into the "other repositories" row so the table stays readable.
BLURBS = {
    "cansincomert/arkafon-be":   "Fund-market analytics backend — TEFAS ingestion, AI market insights",
    "cansincomert/arkafon-fe":   "Financial analytics terminal — React 18 + Vite + TS, Sankey flow viz",
    "cansincomert/genomixLLM":   "MSc research — LLMs over FASTQ→VCF, RAG ablations, quantization studies",
    "cansincomert/karinca-new":  "Headless CMS + component-based JS frontend",
    "cansincomert/consensio-fe": "Clinical genomics dashboard — variant search & VCF annotation UI",
    "efedikmen/arkafon":         "Fund analytics platform — collaboration",
    "cansincomert/arkafon-ios":  "SwiftUI client for the analytics terminal",
    "cansincomert/studio-fe":    "Design studio site",
    "cansincomert/consensio":    "Variant frequency database",
    "cansincomert/swe573":       "Software development practice — semantic tagging app",
}
NAMED = 8  # rows to show individually

rows = []
with open(os.environ["COUNTS"], encoding="utf-8") as fh:
    for line in fh:
        my_c, all_c, is_private, full = line.rstrip("\n").split("\t")
        if int(my_c) > 0:
            rows.append((int(my_c), int(all_c), is_private == "true", full))
rows.sort(reverse=True)

badges = f"""<p align="center">
  <img src="https://img.shields.io/badge/Commits%20authored-{mine}-6f42c1?style=for-the-badge&logo=git&logoColor=white" alt="Commits authored"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Repositories%20contributed%20to-{repos}-0B7285?style=for-the-badge&logo=github&logoColor=white" alt="Repositories"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Private%20work-{private}%20repos-24292f?style=for-the-badge&logo=githubactions&logoColor=white" alt="Private repos"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Commits%20on%20those%20branches-{total}-2f9e44?style=for-the-badge&logo=gitlfs&logoColor=white" alt="Total commits"/>
</p>"""

lines = ['<table align="center">', '  <tr>',
         '    <th align="left">Project</th><th align="left">What it is</th><th align="right">My commits</th>',
         '  </tr>']
for my_c, _all_c, is_private, full in rows[:NAMED]:
    name = full.split("/")[-1]
    lock = " 🔒" if is_private else ""
    blurb = html.escape(BLURBS.get(full, ""))
    lines += ['  <tr>',
              f'    <td><b>{html.escape(name)}</b>{lock}</td>',
              f'    <td><sub>{blurb}</sub></td>',
              f'    <td align="right"><b>{my_c}</b></td>',
              '  </tr>']

rest = rows[NAMED:]
if rest:
    rest_commits = sum(r[0] for r in rest)
    lines += ['  <tr>',
              f'    <td><b>{len(rest)} other repositories</b></td>',
              '    <td><sub>Research prototypes, coursework, infrastructure and client work</sub></td>',
              f'    <td align="right"><b>{rest_commits}</b></td>',
              '  </tr>']
lines.append('</table>')
table = "\n".join(lines)

readme = open("README.md", encoding="utf-8").read()
original = readme

for marker, block in (("STATS", badges), ("TABLE", table)):
    readme, n = re.subn(
        rf"(<!-- {marker}:START[^>]*-->\n).*?(\n<!-- {marker}:END -->)",
        lambda m, b=block: m.group(1) + b + m.group(2),
        readme,
        flags=re.S,
    )
    if n == 0:
        raise SystemExit(f"marker {marker}:START/END not found in README.md")

if readme == original:
    print("no change")
else:
    open("README.md", "w", encoding="utf-8").write(readme)
    print("README.md updated")
PY
