#!/usr/bin/env bash
# Pull cursor/plugins changes into t3stack. Each line of scripts/subtrees.txt
# maps a folder here to a folder upstream. The upstream folder's history is
# split out with `git subtree split`, which gives the same commit ids every run,
# then subtree-merged into the folder here, so only real edits conflict.
# Pass a ref to merge something other than cursor/plugins main (for testing).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

[[ -z "$(git status --porcelain)" ]] || {
  echo "Working tree isn't clean. Commit or stash your changes, then sync." >&2
  exit 1
}

upstream=refs/upstream/cursor-main
if [[ $# -gt 0 ]]; then
  upstream=$1
else
  git fetch --quiet --no-tags https://github.com/cursor/plugins.git "+main:$upstream"
fi
echo "upstream cursor/plugins at $(git rev-parse --short "$upstream")"

# Manifests are ours. Upstream bumps their version on every release.
ours_on_conflict=(t3stack/plugin.json t3stack/.cursor-plugin/plugin.json)

while read -r here there; do
  [[ -z "$here" || "$here" == \#* ]] && continue
  split=$(git subtree split -q --prefix="$there" "$upstream")
  git update-ref "refs/upstream/split/${here//\//-}" "$split"
  if [[ ! -d "$here" ]]; then
    git subtree add -q --prefix="$here" "$split" \
      -m "Add $here from cursor/plugins $there"
    echo "added $here"
    continue
  fi
  if git merge-base --is-ancestor "$split" HEAD; then
    echo "$here is up to date"
    continue
  fi
  if git subtree merge -q --prefix="$here" "$split" \
    -m "Merge cursor/plugins $there into $here"; then
    echo "merged $here"
    continue
  fi
  for f in "${ours_on_conflict[@]}"; do
    if git diff --name-only --diff-filter=U | grep -qxF "$f"; then
      git checkout --ours -- "$f" && git add "$f"
    fi
  done
  left=$(git diff --name-only --diff-filter=U)
  if [[ -n "$left" ]]; then
    echo "Conflicts merging $there into $here. Port upstream's intent to T3, then run:" >&2
    echo "  git commit --no-edit && scripts/sync-upstream.sh" >&2
    sed 's/^/  /' <<<"$left" >&2
    exit 1
  fi
  git commit -q --no-edit
  echo "merged $here (kept our manifests)"
done <scripts/subtrees.txt

scripts/check.sh
