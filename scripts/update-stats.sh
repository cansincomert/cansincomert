#!/usr/bin/env bash
# Recompute commit stats across EVERY repo the token can see — owned, private
# and collaborations — then rewrite the badge block between the STATS: markers.
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
# goes here — excluded repos contribute nothing to the published badges.
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
import os, re

mine, total = os.environ["MINE"], os.environ["TOTAL"]
repos, private = os.environ["REPOS"], os.environ["PRIVATE"]

badges = f"""<p align="center">
  <img src="https://img.shields.io/badge/Commits%20authored-{mine}-6f42c1?style=for-the-badge&logo=git&logoColor=white" alt="Commits authored"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Repositories%20contributed%20to-{repos}-0B7285?style=for-the-badge&logo=github&logoColor=white" alt="Repositories"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Private%20work-{private}%20repos-24292f?style=for-the-badge&logo=githubactions&logoColor=white" alt="Private repos"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Commits%20on%20those%20branches-{total}-2f9e44?style=for-the-badge&logo=gitlfs&logoColor=white" alt="Total commits"/>
</p>"""

readme = open("README.md", encoding="utf-8").read()
original = readme

readme, n = re.subn(
    r"(<!-- STATS:START[^>]*-->\n).*?(\n<!-- STATS:END -->)",
    lambda m: m.group(1) + badges + m.group(2),
    readme,
    flags=re.S,
)
if n == 0:
    raise SystemExit("marker STATS:START/END not found in README.md")

if readme == original:
    print("no change")
else:
    open("README.md", "w", encoding="utf-8").write(readme)
    print("README.md updated")
PY
