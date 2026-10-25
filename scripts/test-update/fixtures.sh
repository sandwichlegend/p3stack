#!/usr/bin/env bash
set -euo pipefail
[[ $HOME == /tmp/* ]] || { echo "refusing: HOME=$HOME"; exit 99; }

scenarios="clean kept copy both hand nobody removed first script interrupted added removed-file auto-updated stale-plugin edit-after-failure team-kit-auto-updated tool-without-p3stack released-while-choosing removed-through-tool edited-while-updating two-leftover-versions"
scenario=${1:-}
[[ " $scenarios " == *" $scenario "* && -n ${2:-} ]] || { echo "usage: fixtures.sh <$(tr ' ' '|' <<<"$scenarios")> <dir>" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
installer=$(cd "$here/../.." && pwd)/install.sh
python3 -I "$here/safe-home.py" check
[[ $2 == /tmp/* && -d $2 && ! -L $2 && -z $(ls -A "$2") ]] || { echo "refusing: fixture target must be new and empty under /tmp" >&2; exit 99; }
dir=$(cd "$2" && pwd -P)
[[ $dir == /tmp/* ]] || exit 99
created_home=$(python3 -I "$here/safe-home.py" create "$dir")
ln -s "${created_home##*/}" "$dir/home"
home=$dir/home
release=$dir/release
origin=$dir/origin.git
mkdir -p "$home/.codex" "$home/tmp" "$dir/bin" "$dir/sys"

for command in bash env git tar awk sed grep sha256sum shasum find sort diff cp mv rm mkdir cat ln ls head tail tr cut \
  dirname basename mktemp touch chmod wc uname paste readlink sleep date python3 xcode-select kill cmp rmdir ps; do
  path=$(command -v "$command" 2>/dev/null) && ln -s "$path" "$dir/sys/$command"
done

case $scenario in
  added) tools="codex cursor-agent" ;;
  interrupted|edit-after-failure|released-while-choosing|edited-while-updating) tools="codex" ;;
  removed) tools="claude codex opencode" ;;
  clean) tools="claude codex cursor-agent opencode" ;;
  copy|both|nobody|first) tools="claude codex" ;;
  *) tools="claude" ;;
esac
for tool in $tools; do ln -s "$here/fake-tool" "$dir/bin/$tool"; done

environment() {
  printf 'export %s=%q\n' \
    HOME "$home" TMPDIR "$home/tmp" P3STACK_TEST_HELPER "$here" \
    PATH "$dir/bin:$dir/sys" P3STACK_REPO_URL "$origin" \
    CLAUDE_CONFIG_DIR "$home/.claude" CODEX_HOME "$home/.codex" \
    XDG_CACHE_HOME "$home/.cache" XDG_CONFIG_HOME "$home/.config" \
    XDG_DATA_HOME "$home/.local/share" XDG_STATE_HOME "$home/.local/state"
  cat <<'EOF'
unset P3STACK_NONINTERACTIVE P3STACK_TTY P3STACK_REPO_DIR P3STACK_FAKE_MERGE P3STACK_FAKE_FAIL_AFTER_UPDATE P3STACK_FAKE_JSON P3STACK_FAKE_SKIP_UPDATE P3STACK_FAKE_REMOVE_AFTER_UPDATE P3STACK_FAKE_RELEASE_DURING_UPDATE P3STACK_FAKE_LATE_EDIT
EOF
  [[ $scenario != released-while-choosing ]] || echo "export P3STACK_FAKE_RELEASE_DURING_UPDATE=1"
  [[ $scenario != edited-while-updating ]] || echo "export P3STACK_FAKE_LATE_EDIT=1"
}

env_tmp=$(mktemp "$dir/.env.XXXXXXXX")
environment >"$env_tmp"
mv "$env_tmp" "$dir/env.sh"

load_environment() {
  [[ -s $dir/env.sh && ! -L $dir/env.sh ]] || { echo "refusing: missing fixture env file" >&2; exit 99; }
  source "$dir/env.sh" || exit 99
  [[ $HOME == "$dir/home" ]] || exit 99
  python3 -I "$here/safe-home.py" check --owned || exit 99
}

skill() {
  mkdir -p "$release/$1"
  cat >"$release/$1/SKILL.md" <<EOF
---
name: ${1##*/}
description: The ${1##*/} fixture skill.
---

# ${1##*/}

## Workflow

Plan the work.
Write the code.
Check the result.

## Autonomy

Proceed on reversible work.
Pause before deploys.
EOF
}

mkdir -p "$release/p3stack/hooks" "$release/p3stack/skills/poteto-mode/scripts/watch-pr" "$release/p3stack/skills/recall/references"
skill p3stack/skills/poteto-mode
skill p3stack/skills/swarm
skill p3stack/skills/recall
skill team-kit/skills/deslop
echo "Notes the recall skill reads." >"$release/p3stack/skills/recall/references/notes.md"
echo '{ "name": "p3stack" }' >"$release/p3stack/plugin.json"
echo '{ "name": "p3stack-team-kit" }' >"$release/team-kit/plugin.json"
printf '#!/usr/bin/env bash\necho "Use poteto-mode."\n' >"$release/p3stack/hooks/session-start"
chmod +x "$release/p3stack/hooks/session-start"
cat >"$release/p3stack/skills/poteto-mode/scripts/watch-pr/github.ts" <<'EOF'
export function listChecks(pr: number) {
  return [`checks for ${pr}`]
}

export function discoverStack(branch: string) {
  return [branch]
}
EOF

git() { command git -C "$release" -c user.name=fixture -c user.email=fixture@example.com "$@"; }
git init --quiet --initial-branch=main
git add -A
git commit --quiet -m "Release 1"
command git init --quiet --bare --initial-branch=main "$origin"
git push --quiet "$origin" main

(
  load_environment
  P3STACK_NONINTERACTIVE=1 bash "$installer" install
) >"$dir/setup.log" 2>&1 || { cat "$dir/setup.log" >&2; exit 1; }

installed() {
  local tool=$1 path=$2
  case $tool in
    claude) echo "$home/.claude/plugins/cache/p3stack/p3stack/$(git rev-parse HEAD | cut -c1-12)/$path" ;;
    claude-team-kit) echo "$home/.claude/plugins/cache/p3stack/p3stack-team-kit/$(git rev-parse HEAD | cut -c1-12)/$path" ;;
    codex) echo "$home/.codex/plugins/cache/p3stack/p3stack/1.0.0/$path" ;;
  esac
}

edit() {
  local file mark=$3
  file=$(installed "$1" "$2")
  awk -v mark="$mark" '
    NR > 1 && $0 == "---" && mark && !done { print "edited: true"; done = 1 }
    $0 == "Write the code." { print "Write the code test first." ; next }
    $0 == "  return [branch]" { print "  return [branch, \"main\"]"; next }
    { print }' "$file" >"$file.new"
  mv "$file.new" "$file"
}

change() {
  awk '$0 == "Pause before deploys." { print; print "Pause before force-pushes."; print "Pause before deleting data."; next }
    $0 == "export function discoverStack(branch: string) {" { print; print "  if (!branch) return []"; next }
    { print }' "$release/$1" >"$release/$1.new"
  mv "$release/$1.new" "$release/$1"
}

case $scenario in
  kept|copy) edit claude skills/poteto-mode/SKILL.md 1 ;;
  both|nobody) edit claude skills/poteto-mode/SKILL.md 1; change p3stack/skills/poteto-mode/SKILL.md ;;
  hand) edit claude skills/swarm/SKILL.md 0 ;;
  removed) edit claude skills/recall/SKILL.md 1; git rm --quiet -r p3stack/skills/recall ;;
  first)
    edit claude skills/swarm/SKILL.md 1
    edit codex skills/swarm/SKILL.md 0
    change p3stack/skills/poteto-mode/SKILL.md
    rm -rf "$home/.p3stack/installed"
    ;;
  interrupted|edit-after-failure|released-while-choosing|edited-while-updating) edit codex skills/poteto-mode/SKILL.md 1; change p3stack/skills/poteto-mode/SKILL.md ;;
  team-kit-auto-updated) edit claude-team-kit skills/deslop/SKILL.md 1 ;;
  removed-through-tool|tool-without-p3stack) edit claude skills/poteto-mode/SKILL.md 1 ;;
  added)
    for root in "$home/.codex/plugins/cache/p3stack/p3stack/1.0.0" "$home/.cursor/plugins/local/p3stack"; do
      mkdir -p "$root/skills/poteto-mode/references"
      echo "My own reference." >"$root/skills/poteto-mode/references/mine.md"
    done
    ;;
  removed-file)
    echo "My edited notes." >>"$(installed claude skills/recall/references/notes.md)"
    echo "echo my-hook" >>"$(installed claude hooks/session-start)"
    git rm --quiet p3stack/skills/recall/references/notes.md p3stack/hooks/session-start
    ;;
  auto-updated|two-leftover-versions) edit claude skills/poteto-mode/SKILL.md 1; change p3stack/skills/poteto-mode/SKILL.md ;;
  stale-plugin) change p3stack/skills/poteto-mode/SKILL.md ;;
  script) edit claude skills/poteto-mode/scripts/watch-pr/github.ts 0; change p3stack/skills/poteto-mode/scripts/watch-pr/github.ts ;;
esac
[[ $scenario == first ]] || change team-kit/skills/deslop/SKILL.md
git commit --quiet -am "Release 2"
git push --quiet "$origin" main
git rev-parse HEAD~1 HEAD >"$dir/releases"

case $scenario in
  auto-updated|stale-plugin) (load_environment; claude plugin update p3stack@p3stack) ;;
  team-kit-auto-updated)
    (load_environment; claude plugin update p3stack-team-kit@p3stack)
    echo "An edit made after the background auto-update." >>"$(installed claude-team-kit skills/deslop/SKILL.md)"
    ;;
  edit-after-failure)
    (load_environment; P3STACK_NONINTERACTIVE=1 P3STACK_FAKE_FAIL_AFTER_UPDATE=codex bash "$installer" update) >"$dir/failed-update.log" 2>&1 || true
    echo "An edit made after the failed update." >>"$(installed codex skills/poteto-mode/SKILL.md)"
    ;;
  two-leftover-versions)
    (eval "$(environment)"; claude plugin update p3stack@p3stack)
    echo "An edit in the newer leftover Claude version." >>"$(installed claude skills/poteto-mode/SKILL.md)"
    (eval "$(environment)"; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
    ;;
  removed-through-tool)
    (eval "$(environment)"; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
    ;;
  tool-without-p3stack) mkdir -p "$home/.cursor" ;;
esac

cat "$dir/env.sh"
echo "# Run: bash '$installer' update"
