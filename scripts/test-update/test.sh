#!/usr/bin/env bash
# Usage: scripts/test-update/test.sh [case...]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
installer=$(cd "$here/../.." && pwd)/install.sh
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
failures=0
case_failed=0

fail() {
  printf '    FAIL: %s\n' "$*"
  case_failed=1
}

setup() {
  dir=$scratch/$1
  rm -rf "$dir"
  "$here/fixtures.sh" "$2" "$dir" >"$dir.env"
  home=$dir/home
  old=$(sed -n 1p "$dir/releases")
  new=$(sed -n 2p "$dir/releases")
  claude=$home/.claude/plugins/cache/p3stack/p3stack/${new:0:12}
  claude_old=$home/.claude/plugins/cache/p3stack/p3stack/${old:0:12}
  codex=$home/.codex/plugins/cache/p3stack/p3stack/1.0.0
}

update_answering() {
  local answer_lines=$1
  shift
  printf '%b' "$answer_lines" >"$dir/answers"
  (
    eval "$(cat "$dir.env")"
    export P3STACK_TTY=$dir/answers "$@"
    bash "$installer" update
  ) >"$dir/out" 2>&1 || fail "install.sh update exited nonzero"
}

release() { git --git-dir="$dir/origin.git" show "$1:p3stack/$2"; }

says() { grep -qF -- "$1" "$dir/out" || fail "output lacks: $1"; }
never_says() { ! grep -qF -- "$1" "$dir/out" || fail "output has: $1"; }
has() { grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 lacks: $2"; }
lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 has: $2"; }
same() { cmp -s "$1" "$2" || fail "$1 differs from $2"; }
is_release() { cmp -s <(release "$1" "$3") "$2" || fail "$2 isn't release ${1:0:7}'s $3"; }
exists() { [[ -e $1 || -L $1 ]] || fail "$1 is missing"; }
absent() { [[ ! -e $1 && ! -L $1 ]] || fail "$1 exists"; }
asked() { [[ $(grep -c 'Choose ' "$dir/out" || true) == "$1" ]] || fail "asked $(grep -c 'Choose ' "$dir/out" || true) questions, not $1"; }
recorded() { [[ $(cat "$home/.p3stack/installed/$1/commit") == "$new" ]] || fail "$1's record isn't release ${new:0:7}"; }

test_clean() {
  setup clean clean
  update_answering ""
  asked 0
  [[ $(grep -c 'No edited files.' "$dir/out") == 4 ]] || fail "expected No edited files. for four tools"
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  is_release "$new" "$home/.cursor/plugins/local/p3stack/skills/swarm/SKILL.md" skills/swarm/SKILL.md
  for tool in claude codex cursor opencode; do recorded "$tool"; done
  has "$home/.p3stack/installed/claude/p3stack.sha256" "  skills/poteto-mode/SKILL.md"
}

test_kept() {
  setup kept kept
  update_answering ""
  asked 0
  says "poteto-mode   p3stack didn't change it in this release"
  says "Kept your version of poteto-mode."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  has "$claude/skills/poteto-mode/SKILL.md" "edited: true"
  recorded claude
}

test_copy_yes() {
  setup copy-yes copy
  update_answering "y\n"
  asked 1
  says "poteto-mode: p3stack didn't change it, so your version in Claude Code stays."
  says "Codex still has p3stack's poteto-mode. Copy your version there too?"
  says "Copied your poteto-mode from Claude Code, marked edited."
  same "$claude/skills/poteto-mode/SKILL.md" "$codex/skills/poteto-mode/SKILL.md"
  has "$codex/skills/poteto-mode/SKILL.md" "edited: true"
}

test_copy_no() {
  setup copy-no copy
  update_answering "n\n"
  asked 1
  says "Left Codex alone. You won't be asked again for this edit."
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  update_answering ""
  asked 0
  says "Kept your version of poteto-mode."
}

test_both_keep() {
  setup both-keep both
  update_answering "k\ny\n"
  asked 2
  says "poteto-mode in Claude Code: you and p3stack both changed this skill."
  says 'Yours     1 line in "## Workflow"'
  says 'p3stack   2 lines in "## Autonomy"'
  says "[T] Talk to a model to merge them (recommended)"
  says "p3stack's change was skipped. You'll be asked again if it changes in a later release."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  lacks "$claude/skills/poteto-mode/SKILL.md" "Pause before force-pushes."
  same "$claude/skills/poteto-mode/SKILL.md" "$codex/skills/poteto-mode/SKILL.md"
}

test_both_accept() {
  setup both-accept both
  update_answering "a\n"
  asked 1
  says "Installed p3stack's poteto-mode."
  says "Your version is saved in ~/.p3stack/edits/claude/p3stack/skills/poteto-mode/SKILL.md"
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  same "$claude_old/skills/poteto-mode/SKILL.md" "$home/.p3stack/edits/claude/p3stack/skills/poteto-mode/SKILL.md"
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_both_talk() {
  setup both-talk both
  update_answering "t\n1\ny\n" P3STACK_FAKE_MERGE="merged by the agent"
  asked 3
  says "Which coding agent should merge them? (only tools you have installed are listed)"
  says "[1] Claude Code (recommended)"
  says "[2] Codex"
  says "It has original.md, yours.md, theirs.md, and a brief."
  says "Installed the merged poteto-mode, marked edited."
  says "Copied your poteto-mode from Claude Code, marked edited."
  local merge=$home/.p3stack/merge/poteto-mode
  is_release "$old" "$merge/original.md" skills/poteto-mode/SKILL.md
  is_release "$new" "$merge/theirs.md" skills/poteto-mode/SKILL.md
  has "$merge/yours.md" "Write the code test first."
  has "$home/agent.log" "claude in $merge: # Merge poteto-mode"
  has "$home/agent.log" 'Write the combined file to `result.md`'
  has "$claude/skills/poteto-mode/SKILL.md" "merged by the agent"
  has "$codex/skills/poteto-mode/SKILL.md" "merged by the agent"
}

test_both_talk_no_result() {
  setup both-talk-none both
  update_answering "t\n2\nk\nn\n"
  asked 4
  says "Codex closed without writing result.md. Nothing changed yet."
  [[ $(grep -c 'you and p3stack both changed this skill' "$dir/out") == 2 ]] || fail "expected the keep, accept, or talk question again"
  says "Kept your version of poteto-mode."
  has "$home/agent.log" "codex in $home/.p3stack/merge/poteto-mode"
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
}

test_hand() {
  setup hand hand
  update_answering ""
  asked 0
  says 'Found a change with no "edited" mark:'
  says "skills/swarm/SKILL.md   1 line differs from what was installed"
  says "Marked it edited."
  says "Kept your version of swarm."
  has "$claude/skills/swarm/SKILL.md" "edited: true"
  has "$claude/skills/swarm/SKILL.md" "Write the code test first."
}

test_nobody() {
  setup nobody nobody
  update_answering "" P3STACK_NONINTERACTIVE=1
  asked 0
  says "No one is at the keyboard to choose, so your version of poteto-mode in Claude Code was kept."
  says "p3stack's change to it was skipped. Run \"p3stack update\" in a terminal to choose."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_no_keyboard() {
  setup no-keyboard nobody
  update_answering "" P3STACK_TTY=/nonexistent/tty
  asked 0
  says "No one is at the keyboard to choose, so your version of poteto-mode in Claude Code was kept."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
}

test_removed_keep() {
  setup removed-keep removed
  update_answering "k\n"
  asked 1
  says "recall        p3stack removed it in this release"
  says "recall in Claude Code: you edited this skill, and the new release no longer has it."
  says "[A] Accept p3stack's version (recommended)"
  never_says "Talk to a model"
  says "Moved your recall to ~/.agents/skills/recall and linked it into each tool."
  has "$home/.agents/skills/recall/SKILL.md" "Write the code test first."
  exists "$home/.agents/skills/recall/references/notes.md"
  [[ $(readlink "$home/.claude/skills/recall") == ../../.agents/skills/recall ]] || fail "~/.claude/skills/recall isn't linked"
  [[ $(readlink "$home/.cursor/skills/recall") == ../../.agents/skills/recall ]] || fail "~/.cursor/skills/recall isn't linked"
  absent "$claude/skills/recall"
}

test_removed_accept() {
  setup removed-accept removed
  update_answering "a\n"
  asked 1
  says "Removed recall. Your version is saved in ~/.p3stack/edits/claude/p3stack/skills/recall/SKILL.md"
  absent "$claude/skills/recall"
  absent "$home/.agents/skills/recall"
  has "$home/.p3stack/edits/claude/p3stack/skills/recall/SKILL.md" "Write the code test first."
}

test_first() {
  setup first first
  update_answering "a\n"
  asked 1
  says "No record of the last install. Using the commit in the folder name (${old:0:7})."
  says "Kept your version of swarm."
  says "No record of the last install in Codex, and Codex doesn't say which version it has."
  says "2 skills differ from the new release: poteto-mode, swarm"
  says "They may be your edits, or just the older version."
  says "poteto-mode and swarm in Codex:"
  says "Installed p3stack's versions. Old copies saved in ~/.p3stack/edits/codex/."
  [[ $(grep -c 'Saved a record for next time.' "$dir/out") == 2 ]] || fail "expected a saved record for both tools"
  has "$claude/skills/swarm/SKILL.md" "Write the code test first."
  is_release "$new" "$codex/skills/swarm/SKILL.md" skills/swarm/SKILL.md
  is_release "$old" "$home/.p3stack/edits/codex/p3stack/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  has "$home/.p3stack/edits/codex/p3stack/skills/swarm/SKILL.md" "Write the code test first."
  recorded claude
  recorded codex
}

test_first_nobody() {
  setup first-nobody first
  update_answering "" P3STACK_NONINTERACTIVE=1
  says "No one is at the keyboard to choose, so p3stack's versions go into Codex. Old copies are saved in ~/.p3stack/edits/codex/."
  is_release "$new" "$codex/skills/swarm/SKILL.md" skills/swarm/SKILL.md
  has "$home/.p3stack/edits/codex/p3stack/skills/swarm/SKILL.md" "Write the code test first."
}

test_script() {
  local path=skills/poteto-mode/scripts/watch-pr/github.ts
  setup script script
  update_answering "k\n"
  asked 1
  says "poteto-mode/scripts/watch-pr/github.ts p3stack also changed it"
  says "1 file you edited:"
  says "poteto-mode/scripts/watch-pr/github.ts in Claude Code: you and p3stack both changed this file."
  says 'Yours     1 line near "function discoverStack"'
  never_says 'with no "edited" mark'
  has "$claude/$path" 'return [branch, "main"]'
  lacks "$claude/$path" "edited: true"
  update_answering ""
  says "Kept your version of poteto-mode/scripts/watch-pr/github.ts."
  asked 0
}

test_script_talk() {
  local path=skills/poteto-mode/scripts/watch-pr/github.ts
  setup script-talk script
  update_answering "t\n1\n" P3STACK_FAKE_MERGE="export const merged = true"
  has "$home/.p3stack/merge/poteto-mode-scripts-watch-pr-github.ts/BRIEF.md" "This file is a script, so run its tests first."
  exists "$home/.p3stack/merge/poteto-mode-scripts-watch-pr-github.ts/theirs.ts"
  has "$claude/$path" "export const merged = true"
}

test_cli_terminal() {
  command -v python3 >/dev/null && command -v node >/dev/null || { echo "    skip: needs python3 and node"; return; }
  local node
  node=$(command -v node)
  setup cli-terminal both
  (
    eval "$(cat "$dir.env")"
    export PATH="$PATH:$(dirname "$node")" P3STACK_HANDOFF=1
    python3 -I "$here/terminal.py" "$dir/out" k node "$(dirname "$installer")/cli/bin/p3stack.mjs" update --tools claude
  ) || fail "p3stack update in a terminal exited nonzero"
  says "Choose K/A/T [T]:"
  says "Kept your version of poteto-mode."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
}

cases=$(declare -F | awk '$3 ~ /^test_/ { sub(/^test_/, "", $3); print $3 }')
for name in ${*:-$cases}; do
  case_failed=0
  printf '%s\n' "$name"
  "test_$name"
  if ((case_failed)); then
    failures=$((failures + 1))
    sed 's/^/    | /' "$dir/out"
  fi
done
if ((failures)); then
  echo "$failures update scenarios failed"
  exit 1
fi
echo "all update scenarios pass"
