#!/usr/bin/env bash
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

ours_on_conflict=(t3stack/plugin.json t3stack/.cursor-plugin/plugin.json)
under_removed() {
  local path=$1 prefix
  while IFS= read -r prefix; do
    [[ -z "$prefix" ]] && continue
    [[ "$path" == "$prefix" || "$path" == "$prefix"/* ]] && return 0
  done <scripts/removed.txt
  return 1
}

settle_known_paths() {
  local path
  for path in "${ours_on_conflict[@]}"; do
    if git diff --name-only --diff-filter=U | grep -qxF "$path"; then
      git checkout --ours -- "$path"
      git add -- "$path"
    fi
  done
  while read -r path; do
    if [[ -n "$path" ]] && under_removed "$path"; then
      git rm -qf --ignore-unmatch -- "$path"
    fi
  done < <(git diff --name-only --diff-filter=U; git diff --cached --name-only --diff-filter=A)
}

while read -r here there; do
  [[ -z "$here" ]] && continue
  split=$(git subtree split -q --prefix="$there" "$upstream")
  git update-ref "refs/upstream/split/${here//\//-}" "$split"
  if [[ ! -d "$here" ]]; then
    git subtree add -q --prefix="$here" "$split" -m "Add $here from cursor/plugins $there"
    echo "added $here"
    continue
  fi
  if git merge-base --is-ancestor "$split" HEAD; then
    echo "$here is up to date"
    continue
  fi
  if git subtree merge -q --prefix="$here" "$split" -m "Merge cursor/plugins $there into $here" 2>/dev/null; then
    echo "merged $here"
    continue
  fi
  git rev-parse -q --verify MERGE_HEAD >/dev/null || {
    echo "git subtree merge failed before merging $there. Nothing was changed." >&2
    exit 1
  }
  settle_known_paths
  left=$(git diff --name-only --diff-filter=U)
  if [[ -n "$left" ]]; then
    echo "Conflicts merging $there into $here. Port upstream's intent to T3, then run:" >&2
    echo "  git add <files> && git commit --no-edit && scripts/sync-upstream.sh" >&2
    sed 's/^/  /' <<<"$left" >&2
    exit 1
  fi
  git commit -q --no-edit
  echo "merged $here, keeping our manifests and removals"
done <scripts/subtrees.txt

dropped=0
while IFS= read -r prefix; do
  [[ -z "$prefix" || -z "$(git ls-files -- "$prefix")" ]] && continue
  git rm -rqf --ignore-unmatch -- "$prefix"
  dropped=1
done <scripts/removed.txt
if [[ "$dropped" == 1 ]]; then
  git commit -q -m "Drop upstream files that t3stack removes"
  echo "dropped upstream files under scripts/removed.txt"
fi

scripts/check.sh
