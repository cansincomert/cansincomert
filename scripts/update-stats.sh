#!/usr/bin/env bash
# Recompute commit stats across EVERY repo the token can see (private included)
# and rewrite the badge block between <!-- STATS:START --> and <!-- STATS:END -->.
#
# Requires: gh CLI authenticated with a token that has `repo` scope.
# The default GITHUB_TOKEN is scoped to this repo only and CANNOT see your other
# private repos — the workflow passes a PAT via GH_TOKEN instead.
set -euo pipefail

cd "$(dirname "$0")/.."

viewer_id=$(gh api graphql -f query='{viewer{id}}' --jq '.data.viewer.id')
login=$(gh api graphql -f query='{viewer{login}}' --jq '.data.viewer.login')

gh repo list "$login" --limit 500 --json nameWithOwner,isFork,isPrivate \
  --jq '.[] | select(.isFork==false) | [.nameWithOwner, .isPrivate] | @tsv' > /tmp/repos.tsv

total=0; mine=0; repos=0; private=0

while IFS=$'\t' read -r full is_private; do
  owner=${full%%/*}; name=${full##*/}
  repos=$((repos + 1))
  [ "$is_private" = "true" ] && private=$((private + 1))

  read -r all_c my_c <<<"$(gh api graphql \
    -f query='query($o:String!,$n:String!,$a:ID!){
      repository(owner:$o,name:$n){
        defaultBranchRef{ target{ ... on Commit {
          all:history{totalCount}
          byme:history(author:{id:$a}){totalCount}
        }}}
      }
    }' -f o="$owner" -f n="$name" -f a="$viewer_id" \
    --jq '[(.data.repository.defaultBranchRef.target.all.totalCount // 0),
           (.data.repository.defaultBranchRef.target.byme.totalCount // 0)] | @tsv' 2>/dev/null || printf '0\t0')"

  total=$((total + ${all_c:-0}))
  mine=$((mine + ${my_c:-0}))
done < /tmp/repos.tsv

echo "repos=$repos private=$private mine=$mine total=$total"

MINE=$mine TOTAL=$total REPOS=$repos PRIVATE=$private python3 - <<'PY'
import os, re

mine, total = os.environ["MINE"], os.environ["TOTAL"]
repos, private = os.environ["REPOS"], os.environ["PRIVATE"]

block = f"""<p align="center">
  <img src="https://img.shields.io/badge/Commits%20authored-{mine}-6f42c1?style=for-the-badge&logo=git&logoColor=white" alt="Commits authored"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Repositories-{repos}-0B7285?style=for-the-badge&logo=github&logoColor=white" alt="Repositories"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Private%20work-{private}%20repos-24292f?style=for-the-badge&logo=githubactions&logoColor=white" alt="Private repos"/>
  &nbsp;
  <img src="https://img.shields.io/badge/Total%20commits%20shipped-{total}-2f9e44?style=for-the-badge&logo=gitlfs&logoColor=white" alt="Total commits"/>
</p>"""

readme = open("README.md", encoding="utf-8").read()
new = re.sub(
    r"(<!-- STATS:START[^>]*-->\n).*?(\n<!-- STATS:END -->)",
    lambda m: m.group(1) + block + m.group(2),
    readme,
    flags=re.S,
)
if new == readme:
    print("no change")
else:
    open("README.md", "w", encoding="utf-8").write(new)
    print("README.md updated")
PY
