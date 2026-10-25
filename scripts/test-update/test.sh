#!/usr/bin/env bash
# Usage: scripts/test-update/test.sh [case...]
set -euo pipefail
[[ $HOME == /tmp/* ]] || { echo "refusing: HOME=$HOME"; exit 99; }

here=$(cd "$(dirname "$0")" && pwd)
installer=$(cd "$here/../.." && pwd)/install.sh
python3 -I "$here/safe-home.py" check
scratch=$(mktemp -d /tmp/p3stack-tests.XXXXXXXX)
bootstrap=$(python3 -I "$here/safe-home.py" create "$scratch")
export HOME=$bootstrap CLAUDE_CONFIG_DIR=$bootstrap/.claude CODEX_HOME=$bootstrap/.codex
export XDG_CONFIG_HOME=$bootstrap/.config XDG_DATA_HOME=$bootstrap/.local/share XDG_CACHE_HOME=$bootstrap/.cache XDG_STATE_HOME=$bootstrap/.local/state
mkdir -p "$HOME/tmp"
export TMPDIR=$HOME/tmp
trap 'rm -rf "$scratch"' EXIT
failures=0
case_failed=0

fail() {
  printf '    FAIL: %s\n' "$*"
  case_failed=1
}

setup() {
  dir=$(mktemp -d "$scratch/$1.XXXXXXXX")
  "$here/fixtures.sh" "$2" "$dir" >"$dir.stdout"
  home=$dir/home
  old=$(sed -n 1p "$dir/releases")
  new=$(sed -n 2p "$dir/releases")
  claude=$home/.claude/plugins/cache/p3stack/p3stack/${new:0:12}
  claude_old=$home/.claude/plugins/cache/p3stack/p3stack/${old:0:12}
  codex=$home/.codex/plugins/cache/p3stack/p3stack/1.0.0
}

load_fixture() {
  [[ -s $dir/env.sh && ! -L $dir/env.sh ]] || { echo "refusing: missing fixture env file" >&2; return 99; }
  source "$dir/env.sh" || return 99
  [[ $HOME == "$dir/home" ]] || return 99
  python3 -I "$here/safe-home.py" check --owned
}

update_answering() {
  local answer_lines=$1
  shift
  printf '%b' "$answer_lines" >"$dir/answers"
  (
    load_fixture || exit 99
    export P3STACK_TTY=$dir/answers "$@"
    bash "$installer" ${action:-update} ${tools:-}
  ) >"$dir/out" 2>&1 || { [[ ${expect_failure:-0} == 1 ]] || fail "install.sh update exited nonzero"; return; }
  [[ ${expect_failure:-0} != 1 ]] || fail "update succeeded when it should stop"
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
record_is() {
  local plugin
  for plugin in p3stack p3stack-team-kit; do
    [[ $(cat "$home/.p3stack/installed/$1/$plugin.commit" 2>/dev/null) == "$2" ]] || fail "$1's $plugin record isn't release ${2:0:7}"
  done
}
recorded() { record_is "$1" "$new"; }

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
  says "p3stack's change was skipped. You'll be asked again on the next update."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  lacks "$claude/skills/poteto-mode/SKILL.md" "Pause before force-pushes."
  same "$claude/skills/poteto-mode/SKILL.md" "$codex/skills/poteto-mode/SKILL.md"
}

test_both_accept() {
  setup both-accept both
  update_answering "a\n"
  asked 1
  says "Installed p3stack's poteto-mode."
  says "Your version is saved in ~/.p3stack/edits/claude/"
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  same "$claude_old/skills/poteto-mode/SKILL.md" "$(backup_for claude skills/poteto-mode/SKILL.md)"
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
  local merge=$home/.p3stack/merge/claude/p3stack/skills/poteto-mode/SKILL.md
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
  has "$home/agent.log" "codex in $home/.p3stack/merge/claude/p3stack/skills/poteto-mode/SKILL.md"
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
  says "Moved your recall to ~/.agents/skills/recall, where Claude Code, Codex and OpenCode load it. p3stack won't update it any more."
  has "$home/.agents/skills/recall/SKILL.md" "Write the code test first."
  exists "$home/.agents/skills/recall/references/notes.md"
  [[ $(readlink "$home/.claude/skills/recall") == "$home/.agents/skills/recall" ]] || fail "~/.claude/skills/recall isn't linked"
  absent "$claude/skills/recall"
}

test_removed_accept() {
  setup removed-accept removed
  update_answering "a\n"
  asked 1
  says "Removed recall. Your version is saved in ~/.p3stack/edits/claude/"
  absent "$claude/skills/recall"
  absent "$home/.agents/skills/recall"
  has "$(backup_for claude skills/recall/SKILL.md)" "Write the code test first."
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
  has "$(backup_for codex skills/swarm/SKILL.md)" "Write the code test first."
  recorded claude
  recorded codex
}

test_first_nobody() {
  setup first-nobody first
  update_answering "" P3STACK_NONINTERACTIVE=1
  says "No one is at the keyboard to choose, so p3stack's versions go into Codex. Old copies are saved in ~/.p3stack/edits/codex/."
  is_release "$new" "$codex/skills/swarm/SKILL.md" skills/swarm/SKILL.md
  has "$(backup_for codex skills/swarm/SKILL.md)" "Write the code test first."
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
  update_answering "k\n"
  says "Kept your version of poteto-mode/scripts/watch-pr/github.ts."
  asked 1
}

test_script_talk() {
  local path=skills/poteto-mode/scripts/watch-pr/github.ts
  setup script-talk script
  update_answering "t\n1\n" P3STACK_FAKE_MERGE="export const merged = true"
  has "$home/.p3stack/merge/claude/p3stack/skills/poteto-mode/scripts/watch-pr/github.ts/BRIEF.md" "This file is a script, so run its tests first."
  exists "$home/.p3stack/merge/claude/p3stack/skills/poteto-mode/scripts/watch-pr/github.ts/theirs.ts"
  has "$claude/$path" "export const merged = true"
}

test_cli_terminal() {
  command -v python3 >/dev/null && command -v node >/dev/null || { echo "    skip: needs python3 and node"; return; }
  local node
  node=$(command -v node)
  setup cli-terminal both
  (
    load_fixture || exit 99
    export PATH="$PATH:$(dirname "$node")" P3STACK_HANDOFF=1
    python3 -I "$here/terminal.py" "$dir/out" k node "$(dirname "$installer")/cli/bin/p3stack.mjs" update --tools claude
  ) || fail "p3stack update in a terminal exited nonzero"
  says "Choose K/A/T [T]:"
  says "Kept your version of poteto-mode."
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
}

backup_for() { find "$home/.p3stack/edits/$1" -type f -path "*/$2" 2>/dev/null | sort | tail -1; }

test_backups_must_succeed_before_install() {
  setup backups-must-succeed both
  echo blocked >"$home/.p3stack/edits"
  expect_failure=1 update_answering "a\n"
  recorded codex
  absent "$claude"
  has "$claude_old/skills/poteto-mode/SKILL.md" "Write the code test first."
  record_is claude "$old"
  says "backup"
  never_says "Your version is saved"
}

test_interrupted_update_recovers_edits() {
  setup interrupted-update interrupted
  expect_failure=1 update_answering "k\n" P3STACK_FAKE_FAIL_AFTER_UPDATE=codex
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  says "Codex's update didn't finish. Your backed-up files were reconciled"
  update_answering "k\n"
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  recorded codex
  has "$home/.p3stack/installed/codex/bases" "$old"
  absent "$home/.p3stack/pending/codex"
}

test_backups_are_immutable_generations() {
  setup immutable-backups both
  update_answering "a\n"
  local first
  first=$(backup_for claude skills/poteto-mode/SKILL.md)
  exists "$first"
  cp "$first" "$dir/first-backup"
  echo "Second user edit." >>"$claude/skills/poteto-mode/SKILL.md"
  update_answering "n\n"
  same "$first" "$dir/first-backup"
  [[ $(find "$home/.p3stack/edits/claude" -type f -name SKILL.md | wc -l) == 2 ]] || fail "expected two backup generations"
  update_answering ""
  local count
  count=$(find "$home/.p3stack/edits/claude" -type f -name SKILL.md | wc -l)
  update_answering ""
  [[ $(find "$home/.p3stack/edits/claude" -type f -name SKILL.md | wc -l) == "$count" ]] || fail "unchanged backup was duplicated"
}

test_merges_get_their_own_folder() {
  setup merge-folders both
  local path=skills/poteto-mode/SKILL.md
  echo "Codex independent edit." >>"$codex/$path"
  update_answering "t\n1\nt\n2\n" P3STACK_FAKE_MERGE="Merged user text"
  has "$home/.p3stack/merge/claude/p3stack/$path/yours.md" "Write the code test first."
  has "$home/.p3stack/merge/codex/p3stack/$path/yours.md" "Codex independent edit."
  setup merge-empty both
  update_answering "t\n1\nk\nn\n" P3STACK_FAKE_MERGE=$'\n'
  says "empty result.md"
  has "$claude/$path" "Write the code test first."
}

test_user_added_files_are_kept() {
  setup added-files added
  update_answering ""
  has "$codex/skills/poteto-mode/references/mine.md" "My own reference."
  has "$home/.cursor/plugins/local/p3stack/skills/poteto-mode/references/mine.md" "My own reference."
  says "Kept your file skills/poteto-mode/references/mine.md."
  exists "$(backup_for codex skills/poteto-mode/references/mine.md)"
}

test_background_auto_updates_recover_old_folder() {
  setup auto-update auto-updated
  update_answering "k\n"
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  says "before the background auto-update"
}

test_removing_file_is_not_removing_skill() {
  setup removed-file removed-file
  update_answering "a\nk\n"
  has "$claude/skills/recall/references/notes.md" "My edited notes."
  exists "$claude/skills/recall/SKILL.md"
  absent "$claude/hooks/session-start"
  absent "$home/.agents/skills/recall"
  says "the new release no longer has this file"
}

test_kept_conflict_keeps_old_base() {
  setup old-base both
  update_answering "k\nn\n" P3STACK_NONINTERACTIVE=1
  update_answering "t\n1\nn\n" P3STACK_FAKE_MERGE="Merged result"
  says "you and p3stack both changed"
  is_release "$old" "$home/.p3stack/merge/claude/p3stack/skills/poteto-mode/SKILL.md/original.md" skills/poteto-mode/SKILL.md
  update_answering ""
  asked 0
}

test_stale_plugin_copies_are_not_edits() {
  setup stale-plugin stale-plugin
  update_answering ""
  asked 0
  never_says "Marked it edited"
  never_says "Kept your version"
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_no_silent_unguarded_update() {
  setup root-json kept
  update_answering "" P3STACK_FAKE_JSON=reordered
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  setup root-unresolved kept
  expect_failure=1 update_answering "" P3STACK_FAKE_JSON='[{"id":"p3stack@p3stack"},{"id":"p3stack-team-kit@p3stack"}]'
  record_is claude "$old"
  absent "$claude"
  says "couldn't find where Claude Code keeps p3stack"
}

test_cursor_has_known_base() {
  setup cursor-base clean
  rm -rf "$home/.p3stack/installed/cursor"
  echo "My Cursor edit." >>"$home/.cursor/plugins/local/p3stack/skills/swarm/SKILL.md"
  update_answering ""
  never_says "and Cursor doesn't say"
  has "$home/.cursor/plugins/local/p3stack/skills/swarm/SKILL.md" "My Cursor edit."
}

test_only_one_update_runs_at_a_time() {
  setup update-lock both
  mkfifo "$dir/keyboard"
  (
    load_fixture || exit 99
    export P3STACK_TTY=$dir/keyboard
    exec bash "$installer" update
  ) >"$dir/holder.out" 2>&1 &
  local holder=$! n
  for ((n = 0; n < 500; n++)); do
    [[ ! -f $home/.p3stack/lock/command ]] || break
    sleep 0.01
  done
  exists "$home/.p3stack/lock/command"
  expect_failure=1 update_answering "a\n"
  says "another p3stack"
  says "delete ~/.p3stack/lock"
  absent "$claude"
  printf 'a\n' >"$dir/keyboard"
  wait "$holder" || fail "the lock holder failed"
  mkdir -p "$home/.p3stack/lock"
  echo 2147483647 >"$home/.p3stack/lock/pid"
  update_answering ""
  recorded claude
  absent "$home/.p3stack/lock"
}

test_personal_skill_collision_keeps_skill_in_place() {
  setup personal-collision removed
  mkdir -p "$home/.agents/skills/recall"
  echo "My personal skill" >"$home/.agents/skills/recall/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  never_says "was kept in ~/.agents"
  has "$home/.agents/skills/recall/SKILL.md" "My personal skill"
  says "already exists"
  has "$claude/skills/recall/SKILL.md" "Write the code test first."
  setup accept-parent both
  rm "$claude_old/skills/swarm/SKILL.md"
  update_answering "a\n" P3STACK_FAKE_REMOVE_AFTER_UPDATE=skills/poteto-mode
  exists "$claude/skills/poteto-mode/SKILL.md"
}

test_added_files_offer_copy_and_ignore_tool_markers() {
  setup added-copy added
  rm "$home/.cursor/plugins/local/p3stack/skills/poteto-mode/references/mine.md"
  mkdir -p "$codex/node_modules/foo"
  echo tool >"$codex/node_modules/foo/cache"
  echo tool >"$codex/.in_use"
  echo tool >"$codex/.orphaned_at"
  echo tool >"$codex/.package-lock.json"
  update_answering "y\n"
  asked 1
  has "$home/.cursor/plugins/local/p3stack/skills/poteto-mode/references/mine.md" "My own reference."
  [[ $(find "$home/.p3stack/edits" -type f | wc -l) == 1 ]] || fail "backed up tool markers"
}

test_deleted_files_report_once() {
  setup deleted-file kept
  rm "$claude_old/skills/swarm/SKILL.md"
  update_answering ""
  says "You deleted p3stack/skills/swarm/SKILL.md; p3stack's update put it back."
  update_answering ""
  never_says "You deleted"
}

test_backup_hash_verification_stops_install() {
  setup bad-backup both
  local real_cp
  real_cp=$(command -v cp)
  cat >"$dir/bin/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
"$real_cp" "\$@" || exit
case "\$*" in */.p3stack/edits/*) echo corrupt >>"\${@: -1}" ;; esac
EOF
  chmod +x "$dir/bin/cp"
  expect_failure=1 update_answering "a\n"
  says "backup verification failed"
  absent "$claude"
  record_is claude "$old"
}

test_auto_updated_folder_missing_warns_once() {
  setup auto-missing auto-updated
  (load_fixture || exit 99; claude plugin update p3stack-team-kit@p3stack)
  rm -rf "$claude_old" "${claude_old/p3stack\/p3stack\//p3stack\/p3stack-team-kit\/}"
  update_answering ""
  [[ $(grep -c "Edits made before the auto-update may be" "$dir/out") == 1 ]] || fail "expected one missing-folder warning"
}

test_background_auto_updates_recover_opencode_folder() {
  setup auto-opencode clean
  local package=$home/.cache/opencode/npm/git-p3stack-0123456789ab
  echo "My OpenCode edit." >>"$package/0000000000001/node_modules/p3stack/p3stack/skills/poteto-mode/SKILL.md"
  (load_fixture || exit 99; P3STACK_FAKE_OPENCODE_NEW_FOLDER=1 opencode plugin update github:sandwichlegend/p3stack)
  update_answering "n\n"
  has "$package/0000000000002/node_modules/p3stack/p3stack/skills/poteto-mode/SKILL.md" "My OpenCode edit."
  says "before the background auto-update"
}

test_sha256_falls_back_to_shasum() {
  setup shasum kept
  [[ -L $dir/sys/shasum ]] || return 0
  rm "$dir/sys/sha256sum"
  update_answering ""
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
}

test_incomplete_lock_is_recovered() {
  setup incomplete-lock both
  mkdir "$home/.p3stack/lock"
  touch -t 200001010000 "$home/.p3stack/lock"
  update_answering "a\n"
  recorded claude
  absent "$home/.p3stack/lock"
}

stop_at_record_write() {
  local real_cp
  real_cp=$(command -v cp)
  cat >"$dir/bin/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in */.p3stack/installed/*) kill -TERM \$PPID; exit 1 ;; esac
exec "$real_cp" "\$@"
EOF
  chmod +x "$dir/bin/cp"
}

push_release() {
  local work=$dir/release-work
  rm -rf "$work"
  git clone --quiet "$dir/origin.git" "$work"
  "$@" "$work"
  git -C "$work" -c user.name=fixture -c user.email=fixture@example.com commit --quiet -am "Next release"
  git -C "$work" push --quiet origin main
  git -C "$work" rev-parse HEAD
}

change_deslop_again() { echo "Check the diff twice." >>"$1/team-kit/skills/deslop/SKILL.md"; }

test_edit_after_failed_update_survives() {
  setup edit-after-failure interrupted
  expect_failure=1 update_answering "k\n" P3STACK_FAKE_FAIL_AFTER_UPDATE=codex
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  echo "EDIT_AFTER_FAILURE" >>"$codex/skills/poteto-mode/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$codex/skills/poteto-mode/SKILL.md" "EDIT_AFTER_FAILURE"
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  [[ -n $(grep -rl EDIT_AFTER_FAILURE "$home/.p3stack/edits/codex") ]] || fail "EDIT_AFTER_FAILURE has no backup"
}

test_replay_never_overwrites_newer_edits() {
  setup replay-accept both
  stop_at_record_write
  expect_failure=1 update_answering "a\n"
  rm "$dir/bin/cp"
  exists "$home/.p3stack/pending/claude"
  echo "LATE_EDIT" >>"$claude/skills/poteto-mode/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  says "Finished an interrupted update in Claude Code."
  has "$claude/skills/poteto-mode/SKILL.md" "LATE_EDIT"
  [[ -n $(grep -rl LATE_EDIT "$home/.p3stack/edits/claude") ]] || fail "LATE_EDIT has no backup"
  recorded claude
  setup replay-keep interrupted
  stop_at_record_write
  expect_failure=1 update_answering "k\n"
  rm "$dir/bin/cp"
  echo "LATE_EDIT" >>"$codex/skills/poteto-mode/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$codex/skills/poteto-mode/SKILL.md" "LATE_EDIT"
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  [[ -n $(grep -rl LATE_EDIT "$home/.p3stack/edits/codex") ]] || fail "LATE_EDIT has no backup"
}

test_replay_leaves_pre_update_content_for_scan() {
  setup replay-pre both
  stop_at_record_write
  expect_failure=1 update_answering "a\n"
  rm "$dir/bin/cp"
  cp "$claude_old/skills/poteto-mode/SKILL.md" "$claude/skills/poteto-mode/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  [[ -n $(grep -rl "Write the code test first." "$home/.p3stack/edits/claude") ]] || fail "the user's pre-update version has no backup"
}

test_dead_journal_does_not_block_updates() {
  setup dead-journal kept
  mkdir -p "$home/.p3stack/pending/bogus" "$home/.p3stack/pending/cursor/sources"
  echo "x" >"$home/.p3stack/pending/bogus/rows"
  printf 'cursor\034p3stack\034skills/x/SKILL.md\034edited-kept\034keep\n' >"$home/.p3stack/pending/cursor/rows"
  echo "Merged text that only the journal has." >"$home/.p3stack/pending/cursor/sources/0"
  update_answering ""
  says "pending-failed"
  says "Kept your version of poteto-mode."
  recorded claude
  absent "$home/.p3stack/pending/cursor"
  absent "$home/.p3stack/pending/bogus"
  [[ -n $(grep -rl "Merged text that only the journal has." "$home/.p3stack/edits") ]] || fail "journal-only merge result wasn't backed up"
  update_answering ""
  never_says "pending"
}

test_missing_root_journal_finishes_after_rebuild() {
  setup missing-root added
  local real_cp
  real_cp=$(command -v cp)
  cat >"$dir/bin/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in *'/.p3stack/repo/p3stack '*) echo injected copy failure >&2; exit 1 ;; esac
exec "$real_cp" "\$@"
EOF
  chmod +x "$dir/bin/cp"
  expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  rm "$dir/bin/cp"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$home/.cursor/plugins/local/p3stack/skills/poteto-mode/references/mine.md" "My own reference."
  has "$codex/skills/poteto-mode/references/mine.md" "My own reference."
  absent "$home/.p3stack/pending/cursor"
  recorded cursor
}

test_uninstall_drops_journal_and_names_backups() {
  setup uninstall-journal interrupted
  stop_at_record_write
  expect_failure=1 update_answering "k\n"
  rm "$dir/bin/cp"
  exists "$home/.p3stack/pending/codex"
  action=uninstall update_answering ""
  absent "$home/.p3stack/pending/codex"
  says "~/.p3stack/edits/codex/"
}

test_merge_results_survive_a_dropped_journal() {
  setup merge-dropped both
  expect_failure=1 update_answering "t\n1\nn\n" P3STACK_FAKE_MERGE="merged by the agent" P3STACK_FAKE_FAIL_AFTER_UPDATE=claude
  [[ -n $(grep -rl "merged by the agent" "$home/.p3stack/edits/claude") ]] || fail "merged result wasn't saved with the backups"
  absent "$home/.p3stack/pending/claude"
  record_is claude "$old"
}

test_record_matches_what_the_tool_installed() {
  setup partial-record kept
  update_answering "" P3STACK_FAKE_SKIP_UPDATE=p3stack-team-kit
  [[ $(cat "$home/.p3stack/installed/claude/p3stack.commit") == "$new" ]] || fail "p3stack record isn't the new release"
  [[ $(cat "$home/.p3stack/installed/claude/p3stack-team-kit.commit") == "$old" ]] || fail "team-kit record isn't the release Claude Code kept"
  update_answering "" P3STACK_FAKE_SKIP_UPDATE=p3stack-team-kit
  never_says "deslop"
}

test_failed_codex_marketplace_listing_stops_before_replace() {
  setup unknown-commit copy
  mkdir "$dir/real"
  cp "$here/fake-tool" "$dir/real/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
[[ \$* != "plugin marketplace list" ]] || exit 1
exec "$dir/real/codex" "\$@"
EOF
  chmod +x "$dir/bin/codex" "$dir/real/codex"
  tools=codex expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  record_is codex "$old"
  absent "$home/.p3stack/pending/codex"
  says 'codex plugin marketplace list'
  never_says '$ codex plugin marketplace upgrade'
  never_says '$ codex plugin add'
  is_release "$old" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_failed_update_keeps_old_record() {
  setup failed-record interrupted
  expect_failure=1 update_answering "k\n" P3STACK_FAKE_FAIL_AFTER_UPDATE=codex
  record_is codex "$old"
  expect_failure=1 update_answering "k\n" P3STACK_FAKE_FAIL_AFTER_UPDATE=codex
  record_is codex "$old"
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
}

test_install_on_installed_tool_updates_it() {
  setup install-updates both
  action=install update_answering "a\n"
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  has "$claude_old/skills/poteto-mode/SKILL.md" "Write the code test first."
  cmp -s <(git --git-dir="$dir/origin.git" show "$new:team-kit/skills/deslop/SKILL.md") "$home/.codex/plugins/cache/p3stack/p3stack-team-kit/1.0.0/skills/deslop/SKILL.md" || fail "Codex's team-kit wasn't updated by install"
  recorded claude
  recorded codex
}

test_present_tool_without_p3stack_is_installed() {
  setup without-p3stack kept
  mkdir -p "$home/.cursor"
  update_answering ""
  never_says "Using the commit Cursor installed"
  says "Kept your version of poteto-mode."
  recorded claude
  exists "$home/.cursor/plugins/local/p3stack/skills/poteto-mode/SKILL.md"
  recorded cursor
}

test_unresolved_install_listing_stops_only_that_tool() {
  setup unlisted-folder copy
  rm -rf "$home/.p3stack/installed/claude"
  mkdir "$dir/real"
  cp "$here/fake-tool" "$dir/real/claude"
  rm "$dir/bin/claude"
  cat >"$dir/bin/claude" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in
  "plugin list") exit 0 ;;
  "plugin list --json") echo '[{"id":"p3stack@p3stack"},{"id":"p3stack-team-kit@p3stack"}]'; exit 0 ;;
esac
exec "$dir/real/claude" "\$@"
EOF
  chmod +x "$dir/bin/claude" "$dir/real/claude"
  expect_failure=1 update_answering ""
  says "couldn't find where Claude Code keeps"
  has "$claude_old/skills/poteto-mode/SKILL.md" "Write the code test first."
  absent "$home/.p3stack/installed/claude"
  recorded codex
}

test_unresolved_root_stops_only_that_tool() {
  setup unresolved-one copy
  expect_failure=1 update_answering "" P3STACK_FAKE_JSON='[{"id":"p3stack@p3stack"},{"id":"p3stack-team-kit@p3stack"}]'
  record_is claude "$old"
  recorded codex
  says "couldn't find where Claude Code keeps"
}

test_team_kit_only_auto_update_keeps_old_edit() {
  setup team-kit-auto clean
  local deslop=skills/deslop/SKILL.md team=$home/.claude/plugins/cache/p3stack/p3stack-team-kit
  echo "TEAMKIT_OLD_EDIT" >>"$team/${old:0:12}/$deslop"
  (load_fixture || exit 99; claude plugin update p3stack-team-kit@p3stack)
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$team/${new:0:12}/$deslop" "TEAMKIT_OLD_EDIT"
  has "$(backup_for claude "$deslop")" "TEAMKIT_OLD_EDIT"
}

test_active_folder_edit_after_auto_update_is_kept() {
  setup active-edit auto-updated
  echo "NEW_ACTIVE_EDIT" >>"$claude/skills/poteto-mode/SKILL.md"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$claude/skills/poteto-mode/SKILL.md" "NEW_ACTIVE_EDIT"
  says "your newer version of poteto-mode in Claude Code was kept"
  [[ -n $(grep -rl NEW_ACTIVE_EDIT "$home/.p3stack/edits/claude") ]] || fail "active edit has no backup"
  [[ -n $(grep -rl "Write the code test first." "$home/.p3stack/edits/claude") ]] || fail "older edit has no backup"
}

test_two_versions_ask_which_to_keep() {
  setup two-versions auto-updated
  echo "NEW_ACTIVE_EDIT" >>"$claude/skills/poteto-mode/SKILL.md"
  update_answering "o\nk\n"
  asked 2
  says "[A] Keep the active one (recommended)"
  says "[O] Keep the older one"
  has "$claude/skills/poteto-mode/SKILL.md" "Write the code test first."
  lacks "$claude/skills/poteto-mode/SKILL.md" "NEW_ACTIVE_EDIT"
  [[ -n $(grep -rl NEW_ACTIVE_EDIT "$home/.p3stack/edits/claude") ]] || fail "active edit has no backup"
}

test_opencode_auto_update_scans_both_folders() {
  setup opencode-both clean
  local package=$home/.cache/opencode/npm/git-p3stack-0123456789ab skill=node_modules/p3stack/p3stack/skills/poteto-mode/SKILL.md
  echo "OLD_OPENCODE_EDIT" >>"$package/0000000000001/$skill"
  (load_fixture || exit 99; P3STACK_FAKE_OPENCODE_NEW_FOLDER=1 opencode plugin update github:sandwichlegend/p3stack)
  echo "ACTIVE_OPENCODE_EDIT" >>"$package/0000000000002/$skill"
  update_answering "" P3STACK_NONINTERACTIVE=1
  has "$package/0000000000002/$skill" "ACTIVE_OPENCODE_EDIT"
  [[ -n $(grep -rl OLD_OPENCODE_EDIT "$home/.p3stack/edits/opencode") ]] || fail "older OpenCode edit has no backup"
}

test_deliberate_revert_is_an_edit() {
  setup revert kept
  update_answering ""
  local team=$home/.claude/plugins/cache/p3stack/p3stack-team-kit next
  git --git-dir="$dir/origin.git" show "$old:team-kit/skills/deslop/SKILL.md" >"$team/${new:0:12}/skills/deslop/SKILL.md"
  next=$(push_release change_deslop_again)
  update_answering "" P3STACK_NONINTERACTIVE=1
  says "your version of deslop in Claude Code was kept"
  has "$team/${next:0:12}/skills/deslop/SKILL.md" "Pause before deploys."
  lacks "$team/${next:0:12}/skills/deslop/SKILL.md" "Pause before force-pushes."
  lacks "$team/${next:0:12}/skills/deslop/SKILL.md" "Check the diff twice."
}

test_hand_updated_tool_is_lag_not_edit() {
  setup hand-updated clean
  (load_fixture || exit 99; codex plugin marketplace upgrade p3stack; codex plugin add p3stack-team-kit@p3stack) >/dev/null
  local next
  next=$(push_release change_deslop_again)
  update_answering ""
  asked 0
  never_says "Kept your version of deslop"
  cmp -s <(git --git-dir="$dir/origin.git" show "$next:team-kit/skills/deslop/SKILL.md") "$home/.codex/plugins/cache/p3stack/p3stack-team-kit/1.0.0/skills/deslop/SKILL.md" || fail "Codex's deslop isn't the newest release"
}

test_kept_removed_file_stops_asking() {
  setup removed-file-kept removed-file
  update_answering "k\nk\n"
  says "you won't be asked about it again"
  update_answering ""
  asked 0
  has "$claude/skills/recall/references/notes.md" "My edited notes."
  has "$claude/hooks/session-start" "echo my-hook"
}

test_kept_removed_skill_reaches_every_tool() {
  setup removed-everywhere removed
  update_answering "k\n"
  has "$home/.agents/skills/recall/SKILL.md" "Write the code test first."
  [[ $(cd "$home/.claude/skills/recall" && pwd -P) == "$(cd "$home/.agents/skills/recall" && pwd -P)" ]] || fail "~/.claude/skills/recall doesn't lead to ~/.agents/skills/recall"
  says "where Claude Code, Codex and OpenCode load it"
  absent "$claude/skills/recall"
  absent "$codex/skills/recall"
  setup removed-hidden removed
  mkdir -p "$home/.claude/skills/recall"
  echo "Another recall" >"$home/.claude/skills/recall/SKILL.md"
  update_answering "k\n"
  says "where Codex and OpenCode load it"
  has "$claude/skills/recall/SKILL.md" "Write the code test first."
  exists "$claude/skills/recall/references/notes.md"
  has "$home/.claude/skills/recall/SKILL.md" "Another recall"
  update_answering ""
  asked 0
  exists "$claude/skills/recall/SKILL.md"
}

test_kept_removed_skill_reaches_cursor() {
  setup removed-cursor removed
  mkdir -p "$home/.cursor/plugins/local"
  cp -R "$claude_old" "$home/.cursor/plugins/local/p3stack"
  update_answering "k\n"
  exists "$home/.agents/skills/recall/SKILL.md"
  absent "$home/.cursor/plugins/local/p3stack/skills/recall"
  says "where Claude Code, Codex, Cursor and OpenCode load it"
}

test_unsafe_file_stops_only_that_tool() {
  setup unsafe-file copy
  ln -s /dev/null "$claude_old/skills/poteto-mode/link.md"
  expect_failure=1 update_answering ""
  says "skills/poteto-mode/link.md"
  says "Move the link out"
  record_is claude "$old"
  recorded codex
}

test_unusual_filename_stops_only_that_tool() {
  setup unusual-file copy
  echo "My file" >"$claude_old/skills/poteto-mode/"$'odd\nname.md'
  expect_failure=1 update_answering ""
  says "odd"
  says "Rename the file or move it out"
  record_is claude "$old"
  recorded codex
}

test_lock_names_path_and_reclaims_reused_pid() {
  setup lock-identity both
  sleep 300 &
  local sleeper=$!
  mkdir "$home/.p3stack/lock"
  echo "$sleeper" >"$home/.p3stack/lock/pid"
  ps -o args= -p "$sleeper" >"$home/.p3stack/lock/command" 2>/dev/null || ps -o pid,args | awk -v pid="$sleeper" '$1 == pid { sub(/^ *[0-9]+ +/, ""); print }' >"$home/.p3stack/lock/command"
  update_answering "a\n"
  recorded claude
  mkdir -p "$home/.p3stack/lock"
  echo "$sleeper" >"$home/.p3stack/lock/pid"
  echo "bash install.sh update" >"$home/.p3stack/lock/command"
  update_answering "a\n"
  recorded claude
  absent "$home/.p3stack/lock"
  mkdir -p "$home/.p3stack/lock"
  echo "$sleeper" >"$home/.p3stack/lock/pid"
  ps -o args= -p "$sleeper" >"$home/.p3stack/lock/command" 2>/dev/null || ps -o pid,args | awk -v pid="$sleeper" '$1 == pid { sub(/^ *[0-9]+ +/, ""); print }' >"$home/.p3stack/lock/command"
  touch -t 200001010000 "$home/.p3stack/lock"
  update_answering ""
  absent "$home/.p3stack/lock"
  kill "$sleeper" 2>/dev/null || true
}

test_lock_reclaims_unrelated_process_named_p3stack() {
  setup named-lock kept
  bash -c 'exec -a p3stack-unrelated /bin/sleep 300' &
  local sleeper=$!
  kill -0 "$sleeper" || fail "the unrelated lock owner exited before the test"
  mkdir "$home/.p3stack/lock"
  echo "$sleeper" >"$home/.p3stack/lock/pid"
  ps -o args= -p "$sleeper" >"$home/.p3stack/lock/command" 2>/dev/null || ps -o pid,args | awk -v pid="$sleeper" '$1 == pid { sub(/^ *[0-9]+ +/, ""); print }' >"$home/.p3stack/lock/command"
  update_answering ""
  recorded claude
  absent "$home/.p3stack/lock"
  kill "$sleeper" 2>/dev/null || true
}

test_backup_dedupe_compares_raw_bytes_and_mode() {
  setup raw-dedupe kept
  local file=$claude/skills/poteto-mode/SKILL.md
  update_answering ""
  sed 's/$/\r/' "$file" >"$dir/crlf" && cp "$dir/crlf" "$file"
  update_answering ""
  local found=0 backup
  while IFS= read -r backup; do cmp -s "$backup" "$dir/crlf" && found=1; done < <(find "$home/.p3stack/edits/claude" -type f -name SKILL.md)
  ((found)) || fail "no backup holds the CRLF bytes"
  chmod +x "$file"
  update_answering ""
  [[ -n $(find "$home/.p3stack/edits/claude" -type f -name SKILL.md -perm -u+x) ]] || fail "no backup keeps the executable mode"
}

test_merge_folder_keeps_one_previous_result() {
  setup merge-archive both
  local merge=$home/.p3stack/merge/claude/p3stack/skills/poteto-mode/SKILL.md
  mkdir -p "$merge"
  echo "last result" >"$merge/result.md"
  echo "older archive" >"$merge/result.md.20260101T000000Z-abc1234-x"
  echo "stale" >"$merge/stale.md"
  update_answering "t\n1\nn\n" P3STACK_FAKE_MERGE="merged by the agent"
  [[ $(cd "$merge" && ls | LC_ALL=C sort | paste -sd' ' -) == "BRIEF.md original.md result.md result.previous.md theirs.md yours.md" ]] || fail "merge folder holds $(cd "$merge" && ls | paste -sd' ' -)"
  has "$merge/result.previous.md" "last result"
}


release_while_choosing() {
  echo "RELEASE_THREE" >>"$dir/release/p3stack/skills/poteto-mode/SKILL.md"
  git -C "$dir/release" -c user.name=fixture -c user.email=fixture@example.com commit --quiet -am "Release 3"
  third=$(git -C "$dir/release" rev-parse HEAD)
  mkdir -p "$dir/real"
  cp "$here/fake-tool" "$dir/real/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == 'plugin marketplace upgrade p3stack' && ! -f '$dir/pushed' ]]; then
  git -C '$dir/release' push --quiet '$dir/origin.git' main || exit 1
  touch '$dir/pushed'
fi
exec '$dir/real/codex' "\$@"
EOF
  chmod +x "$dir/bin/codex"
}

test_release_during_choices_keeps_user_version() {
  setup release-race-keep interrupted
  release_while_choosing
  tools=codex update_answering "k\n"
  has "$codex/skills/poteto-mode/SKILL.md" "Write the code test first."
  lacks "$codex/skills/poteto-mode/SKILL.md" RELEASE_THREE
  record_is codex "$third"
  has "$home/.p3stack/installed/codex/bases" "$old"
  never_says "You changed poteto-mode again"
  says "p3stack released again while you were choosing"
  tools=codex update_answering "a\n"
  asked 1
  is_release "$third" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_release_during_choices_accepts_actual_release() {
  setup release-race-accept interrupted
  release_while_choosing
  tools=codex update_answering "a\n"
  is_release "$third" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  never_says "You changed poteto-mode again"
  [[ -z $(grep -rl RELEASE_THREE "$home/.p3stack/edits/codex") ]] || fail "release content was backed up as a user edit"
  record_is codex "$third"
}

test_release_during_choices_keeps_merge_and_its_base() {
  setup release-race-merge interrupted
  release_while_choosing
  tools=codex update_answering "t\n1\n" P3STACK_FAKE_MERGE=MERGED_CHOICE
  has "$codex/skills/poteto-mode/SKILL.md" MERGED_CHOICE
  has "$home/.p3stack/installed/codex/bases" "$new"
  never_says "You changed poteto-mode again"
  tools=codex update_answering "a\n"
  asked 1
  is_release "$third" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

fail_cursor_copy() {
  local subtree=$1 real_cp
  real_cp=$(command -v cp)
  cat >"$dir/bin/cp" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in *'/.p3stack/repo/$subtree '*) echo injected copy failure >&2; exit 1 ;; esac
exec '$real_cp' "\$@"
EOF
  chmod +x "$dir/bin/cp"
}

test_missing_root_rescans_surviving_folders() {
  setup missing-survivor added
  local cursor=$home/.cursor/plugins/local team=$home/.cursor/plugins/local/p3stack-team-kit/skills/deslop/SKILL.md
  echo PRE_TEAM_EDIT >>"$team"
  fail_cursor_copy team-kit
  tools=cursor expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  rm "$dir/bin/cp"
  echo LATE_SURVIVOR_EDIT >>"$cursor/p3stack/skills/poteto-mode/SKILL.md"
  echo LATE_SURVIVOR_FILE >"$cursor/p3stack/skills/poteto-mode/mine.txt"
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  has "$cursor/p3stack/skills/poteto-mode/SKILL.md" LATE_SURVIVOR_EDIT
  has "$cursor/p3stack/skills/poteto-mode/mine.txt" LATE_SURVIVOR_FILE
  has "$team" PRE_TEAM_EDIT
  [[ -n $(grep -rl LATE_SURVIVOR_EDIT "$home/.p3stack/edits/cursor") ]] || fail "survivor's edit has no backup"
  [[ -n $(grep -rl LATE_SURVIVOR_FILE "$home/.p3stack/edits/cursor") ]] || fail "survivor's added file has no backup"
  recorded cursor
}

change_swarm_again() { echo RELEASE_THREE >>"$1/p3stack/skills/swarm/SKILL.md"; }

test_missing_root_new_release_keeps_original_edit() {
  setup missing-new-release added
  local file=$home/.cursor/plugins/local/p3stack/skills/swarm/SKILL.md
  echo MY_CURSOR_EDIT >>"$file"
  fail_cursor_copy p3stack
  tools=cursor expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  rm "$dir/bin/cp"
  local third
  third=$(push_release change_swarm_again)
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  has "$file" MY_CURSOR_EDIT
  lacks "$file" RELEASE_THREE
  record_is cursor "$third"
  tools=cursor update_answering "a\n"
  asked 1
  is_release "$third" "$file" skills/swarm/SKILL.md
}

test_failed_update_new_release_rescans_original_edit() {
  setup failed-new-release added
  local team=$home/.cursor/plugins/local/p3stack-team-kit/skills/deslop/SKILL.md
  echo MY_TEAM_EDIT >>"$team"
  fail_cursor_copy p3stack
  tools=cursor expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  rm "$dir/bin/cp"
  local third
  third=$(push_release change_deslop_again)
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  has "$team" MY_TEAM_EDIT
  record_is cursor "$third"
  has "$home/.p3stack/installed/cursor/bases" "$old"
  tools=cursor update_answering "a\n"
  asked 1
  cmp -s <(git --git-dir="$dir/origin.git" show "$third:team-kit/skills/deslop/SKILL.md") "$team" || fail "Accept didn't install release 3"
}

test_stale_replay_rolls_back_then_scans() {
  setup stale-replay interrupted
  stop_at_record_write
  tools=codex expect_failure=1 update_answering "a\n"
  rm "$dir/bin/cp"
  local third
  third=$(push_release change_deslop_again)
  (load_fixture || exit 99; codex plugin marketplace upgrade p3stack; codex plugin add p3stack@p3stack; codex plugin add p3stack-team-kit@p3stack)
  tools=codex update_answering "a\n"
  asked 1
  says "you and p3stack both changed this skill"
  is_release "$third" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  record_is codex "$third"
}

test_replay_pre_update_content_stays_an_open_question() {
  setup replay-pre-question both
  stop_at_record_write
  tools=claude expect_failure=1 update_answering "a\n"
  rm "$dir/bin/cp"
  cp "$claude_old/skills/poteto-mode/SKILL.md" "$claude/skills/poteto-mode/SKILL.md"
  tools=claude update_answering "a\n"
  asked 1
  says "you and p3stack both changed this skill"
  never_says "You changed poteto-mode again"
  never_says "Your edits are restored."
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

test_claude_uninstalled_through_tool_ignores_leftovers() {
  setup uninstalled-claude both
  (load_fixture || exit 99; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
  tools=claude action=install update_answering ""
  asked 0
  recorded claude
  is_release "$new" "$claude/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  has "$(backup_for claude skills/poteto-mode/SKILL.md)" "Write the code test first."
  says "isn't installed in Claude Code"
}

test_claude_uninstalled_without_record_backs_up_cache() {
  setup uninstalled-no-record both
  rm -rf "$home/.p3stack/installed/claude"
  (load_fixture || exit 99; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
  tools=claude action=install update_answering ""
  asked 0
  recorded claude
  has "$(backup_for claude skills/poteto-mode/SKILL.md)" "Write the code test first."
}

test_codex_uninstalled_through_tool_drops_record() {
  setup uninstalled-codex copy
  (load_fixture || exit 99; codex plugin remove p3stack@p3stack; codex plugin remove p3stack-team-kit@p3stack)
  tools=codex update_answering ""
  asked 0
  recorded codex
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  says "isn't installed in Codex"
}

test_unknown_base_historical_release_still_asks() {
  setup unknown-historical clean
  rm -rf "$home/.p3stack/installed/codex"
  tools=codex update_answering "a\n"
  asked 1
  says "No record of the last install"
  has "$(backup_for codex skills/deslop/SKILL.md)" "Pause before deploys."
  recorded codex
}

test_uninstall_failure_keeps_journal_and_sources() {
  setup failed-uninstall interrupted
  stop_at_record_write
  tools=codex expect_failure=1 update_answering "t\n1\n" P3STACK_FAKE_MERGE=JOURNAL_MERGE
  rm "$dir/bin/cp"
  mkdir -p "$dir/real"
  cp "$here/fake-tool" "$dir/real/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
[[ \$* != 'plugin remove p3stack-team-kit@p3stack' ]] || exit 1
exec '$dir/real/codex' "\$@"
EOF
  chmod +x "$dir/bin/codex"
  tools=codex action=uninstall expect_failure=1 update_answering ""
  exists "$home/.p3stack/pending/codex/rows"
  has "$home/.p3stack/pending/codex/sources/p3stack/skills/poteto-mode/SKILL.md" JOURNAL_MERGE
  says "uninstall failed"
  never_says "Dropped the unfinished"
  cp "$dir/real/codex" "$dir/bin/codex"
  tools=codex action=uninstall update_answering ""
  absent "$home/.p3stack/pending/codex"
  [[ -n $(grep -rl JOURNAL_MERGE "$home/.p3stack/edits/codex") ]] || fail "successful uninstall lost the merge result"
}


test_fetches_before_recovery() {
  setup recovery-fetch both
  stop_at_record_write
  tools=claude expect_failure=1 update_answering "k\n"
  rm "$dir/bin/cp"
  local clone=$home/.p3stack/repo
  rm -rf "$clone"
  git init --quiet --initial-branch=main "$clone"
  git -C "$clone" remote add origin "$dir/origin.git"
  git -C "$clone" fetch --quiet --depth 1 origin "$old"
  git -C "$clone" checkout --quiet -B main FETCH_HEAD
  git -C "$clone" config branch.main.remote origin
  git -C "$clone" config branch.main.merge refs/heads/main
  tools=claude update_answering "a\n"
  says "Finished an interrupted update in Claude Code."
  absent "$home/.p3stack/pending/claude"
  recorded claude
}

test_replay_leaves_non_plain_destination_alone() {
  setup replay-symlink both
  stop_at_record_write
  tools=claude expect_failure=1 update_answering "a\n"
  rm "$dir/bin/cp"
  echo MY_EXTERNAL_FILE >"$home/external"
  rm "$claude/skills/poteto-mode/SKILL.md"
  ln -s "$home/external" "$claude/skills/poteto-mode/SKILL.md"
  tools=claude expect_failure=1 update_answering ""
  says "isn't a plain file any more"
  never_says "Your edits are restored."
  has "$home/external" MY_EXTERNAL_FILE
  [[ -L $claude/skills/poteto-mode/SKILL.md ]] || fail "the newer symlink was replaced"
}

test_accept_uses_each_plugins_actual_release() {
  setup accept-old-plugin clean
  local team=$home/.claude/plugins/cache/p3stack/p3stack-team-kit
  echo MY_TEAM_EDIT >>"$team/${old:0:12}/skills/deslop/SKILL.md"
  tools=claude update_answering "a\n" P3STACK_FAKE_SKIP_UPDATE=p3stack-team-kit
  cmp -s <(git --git-dir="$dir/origin.git" show "$old:team-kit/skills/deslop/SKILL.md") "$team/${old:0:12}/skills/deslop/SKILL.md" || fail "Accept didn't use the installed plugin's release"
  [[ $(cat "$home/.p3stack/installed/claude/p3stack-team-kit.commit") == "$old" ]] || fail "team-kit record isn't the actual release"
}



test_accept_actual_release_removal_reports_the_removal() {
  setup race-removal interrupted
  release_while_choosing
  git -C "$dir/release" rm --quiet p3stack/skills/poteto-mode/SKILL.md
  git -C "$dir/release" -c user.name=fixture -c user.email=fixture@example.com commit --quiet -m "Remove poteto-mode"
  tools=codex update_answering "a\n"
  absent "$codex/skills/poteto-mode/SKILL.md"
  says "The installed p3stack release removed poteto-mode."
  never_says "Installed p3stack's poteto-mode."
  has "$(backup_for codex skills/poteto-mode/SKILL.md)" "Write the code test first."
}

test_codex_real_listing_reinstalls_removed_plugins() {
  setup codex-reallist copy
  (load_fixture || exit 99; codex plugin remove p3stack@p3stack; codex plugin remove p3stack-team-kit@p3stack)
  tools=codex update_answering "" P3STACK_NONINTERACTIVE=1
  recorded codex
  is_release "$new" "$codex/skills/swarm/SKILL.md" skills/swarm/SKILL.md
  tools=codex action=install update_answering "" P3STACK_NONINTERACTIVE=1
  recorded codex
}

test_two_leftover_versions_back_up_only_their_own_edits() {
  setup two-leftovers auto-updated
  echo SECOND_LEFTOVER_EDIT >>"$claude/skills/poteto-mode/SKILL.md"
  (load_fixture || exit 99; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
  tools=claude action=install update_answering "" P3STACK_NONINTERACTIVE=1
  recorded claude
  has "$(find "$home/.p3stack/edits/claude" -path "*/p3stack/${old:0:12}/skills/poteto-mode/SKILL.md" | head -1)" 'Write the code test first.'
  has "$(find "$home/.p3stack/edits/claude" -path "*/p3stack/${new:0:12}/skills/poteto-mode/SKILL.md" | head -1)" SECOND_LEFTOVER_EDIT
  [[ $(find "$home/.p3stack/edits/claude" -type f | wc -l) == 2 ]] || fail "pristine files from another release were called user edits"
  (load_fixture || exit 99; claude plugin uninstall p3stack@p3stack; claude plugin uninstall p3stack-team-kit@p3stack)
  tools=claude action=install update_answering "" P3STACK_NONINTERACTIVE=1
  [[ $(find "$home/.p3stack/edits/claude" -type f | wc -l) == 2 ]] || fail "identical leftovers weren't deduplicated"
  never_says 'backup failed'
}

fail_listing_at() {
  local tool=$1 number=$2 command=$3
  mkdir -p "$dir/realbin"
  cp "$here/fake-tool" "$dir/realbin/$tool"
  rm "$dir/bin/$tool"
  cat >"$dir/bin/$tool" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == '$command' ]]; then
  n=0
  [[ ! -f '$dir/list-count' ]] || n=\$(cat '$dir/list-count')
  n=\$((n+1)); echo \$n >'$dir/list-count'
  if [[ \$n == '$number' ]]; then echo 'injected listing failure' >&2; exit 1; fi
fi
exec '$dir/realbin/$tool' "\$@"
WRAP
  chmod +x "$dir/bin/$tool"
}

test_listing_failure_stops_at_every_detection_phase() {
  local number
  for number in 1 3 4 5 6 7 8; do
    setup listing-failure-$number auto-updated
    fail_listing_at claude "$number" 'plugin list --json'
    tools=claude expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
    says 'claude plugin list --json'
    never_says '$ claude plugin install'
    never_says '$ claude plugin update'
    has "$claude_old/skills/poteto-mode/SKILL.md" 'Write the code test first.'
    record_is claude "$old"
  done
}

test_codex_listing_failure_does_not_fall_back_to_cache() {
  setup codex-list-failure copy
  fail_listing_at codex 1 'plugin list'
  tools=codex expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  says 'codex plugin list'
  never_says '$ codex plugin add'
  record_is codex "$old"
}

late_codex_edits() {
  mkdir -p "$dir/realbin"
  cp "$here/fake-tool" "$dir/realbin/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == 'plugin marketplace add sandwichlegend/p3stack' && ! -f '$dir/late-written' ]]; then
  echo LATE_USER_EDIT_R4 >>'$codex/skills/poteto-mode/SKILL.md'
  echo LATE_ADDED_FILE_R4 >'$codex/skills/poteto-mode/mine.txt'
  touch '$dir/late-written'
fi
exec '$dir/realbin/codex' "\$@"
WRAP
  chmod +x "$dir/bin/codex"
}

test_codex_late_edit_and_added_file_survive() {
  setup codex-late interrupted
  late_codex_edits
  tools=codex update_answering "a\n"
  has "$codex/skills/poteto-mode/SKILL.md" LATE_USER_EDIT_R4
  has "$codex/skills/poteto-mode/mine.txt" LATE_ADDED_FILE_R4
  has "$(backup_for codex skills/poteto-mode/SKILL.md)" LATE_USER_EDIT_R4
  has "$(backup_for codex skills/poteto-mode/mine.txt)" LATE_ADDED_FILE_R4
  says 'after the scan'
  tools=codex update_answering "a\n"
  asked 1
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
}

late_cursor_edits() {
  cat >"$dir/bin/git" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in *'pull --ff-only'*)
  echo MY_LATE_EDIT >>'$home/.cursor/plugins/local/p3stack/skills/recall/SKILL.md'
  echo MY_LATE_FILE >'$home/.cursor/plugins/local/p3stack/skills/recall/mine.txt' ;;
esac
exec '$dir/sys/git' "\$@"
WRAP
  chmod +x "$dir/bin/git"
}

test_cursor_late_edit_and_added_file_survive() {
  setup cursor-late added
  late_cursor_edits
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  has "$home/.cursor/plugins/local/p3stack/skills/recall/SKILL.md" MY_LATE_EDIT
  has "$home/.cursor/plugins/local/p3stack/skills/recall/mine.txt" MY_LATE_FILE
  has "$(backup_for cursor skills/recall/SKILL.md)" MY_LATE_EDIT
  has "$(backup_for cursor skills/recall/mine.txt)" MY_LATE_FILE
  says 'after the scan'
}

test_codex_moving_marketplace_keeps_provenance_honest() {
  setup codex-mixed interrupted
  mkdir -p "$dir/realbin"
  cp "$here/fake-tool" "$dir/realbin/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == 'plugin add p3stack-team-kit@p3stack' && ! -f '$dir/published' ]]; then
  echo UPSTREAM_THREE >>'$dir/release/p3stack/skills/swarm/SKILL.md'
  git -C '$dir/release' -c user.name=fixture -c user.email=fixture@example.com commit -qam third
  git -C '$dir/release' push -q '$dir/origin.git' main
  '$dir/realbin/codex' plugin marketplace upgrade p3stack
  touch '$dir/published'
fi
exec '$dir/realbin/codex' "\$@"
WRAP
  chmod +x "$dir/bin/codex"
  tools=codex expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  record_is codex "$old"
  says 'marketplace changed'
  tools=codex update_answering "" P3STACK_NONINTERACTIVE=1
  has "$codex/skills/swarm/SKILL.md" UPSTREAM_THREE
  local third
  third=$(git --git-dir="$dir/origin.git" rev-parse HEAD)
  record_is codex "$third"
  never_says 'Kept your version of swarm'
}

test_failed_cursor_rebuild_does_not_blame_user_for_missing_files() {
  setup cursor-damage added
  echo MY_TEAM_EDIT >>"$home/.cursor/plugins/local/p3stack-team-kit/skills/deslop/SKILL.md"
  fail_cursor_copy p3stack
  tools=cursor expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  rm "$dir/bin/cp"
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  never_says 'You deleted '
  never_says "p3stack-team-kit isn't installed"
  never_says 'record was dropped'
  has "$home/.cursor/plugins/local/p3stack-team-kit/skills/deslop/SKILL.md" MY_TEAM_EDIT
  recorded cursor
}

test_deleted_file_notes_name_the_plugin() {
  setup deleted-labels added
  rm "$home/.cursor/plugins/local/p3stack/plugin.json" "$home/.cursor/plugins/local/p3stack-team-kit/plugin.json"
  tools=cursor update_answering "" P3STACK_NONINTERACTIVE=1
  says 'You deleted p3stack/plugin.json'
  says 'You deleted p3stack-team-kit/plugin.json'
}

test_opencode_uninstalled_listing_backs_up_leftovers() {
  setup opencode-leftover clean
  local root
  root=$(find "$home/.cache/opencode/npm" -path '*/p3stack/p3stack/skills/poteto-mode/SKILL.md' | head -1)
  echo OPENCODE_LEFTOVER_EDIT >>"$root"
  (load_fixture || exit 99; P3STACK_FAKE_OPENCODE_NEW_FOLDER=1 opencode plugin update github:sandwichlegend/p3stack; opencode plugin remove github:sandwichlegend/p3stack)
  tools=opencode action=install update_answering "" P3STACK_NONINTERACTIVE=1
  [[ -n $(grep -rl OPENCODE_LEFTOVER_EDIT "$home/.p3stack/edits/opencode" 2>/dev/null) ]] || fail 'OpenCode leftover edit has no backup'
  never_says 'No edited files.'
  says "isn't installed in OpenCode"
  [[ $(find "$home/.p3stack/edits/opencode" -type f | wc -l) == 1 ]] || fail 'pristine OpenCode leftovers were backed up as edits'
  recorded opencode
}

test_opencode_failed_listing_stops_the_tool() {
  setup opencode-list-failure clean
  fail_listing_at opencode 1 'plugin list'
  tools=opencode expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  says 'opencode plugin list'
  never_says '$ opencode plugin add'
  record_is opencode "$old"
}

test_release_race_without_choices_does_not_claim_choices() {
  setup race-no-choice clean
  release_while_choosing
  tools=codex update_answering "" P3STACK_NONINTERACTIVE=1
  never_says 'while you were choosing'
}

test_failed_fetch_warns_and_recovers_cached_journal_only() {
  setup fetch-failure interrupted
  stop_at_record_write
  tools=codex expect_failure=1 update_answering "k\n"
  rm "$dir/bin/cp"
  cat >"$dir/bin/git" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
case "\$*" in *'fetch --quiet origin'*) echo INJECTED_FETCH_FAILURE >&2; exit 1 ;; esac
exec '$dir/sys/git' "\$@"
WRAP
  chmod +x "$dir/bin/git"
  tools=codex expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1
  says "couldn't fetch"
  says 'git -C'
  says 'Finished an interrupted update'
  never_says '$ codex plugin add'
  never_says 'Checking your installed copies'
  absent "$home/.p3stack/pending/codex"
  has "$codex/skills/poteto-mode/SKILL.md" 'Write the code test first.'
}

test_codex_records_distinct_commits_between_adds() {
  setup codex-distinct-commits interrupted
  mkdir -p "$dir/realbin"
  cp "$here/fake-tool" "$dir/realbin/codex"
  rm "$dir/bin/codex"
  cat >"$dir/bin/codex" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == 'plugin add p3stack@p3stack' ]]; then
  '$dir/realbin/codex' "\$@" || exit 1
  touch '$dir/first-added'
  exit 0
fi
if [[ \$* == 'plugin marketplace list' && -f '$dir/first-added' && ! -f '$dir/published' ]]; then
  n=0
  [[ ! -f '$dir/after-count' ]] || n=\$(cat '$dir/after-count')
  n=\$((n+1)); echo \$n >'$dir/after-count'
  if [[ \$n == 2 ]]; then
    echo UPSTREAM_THREE >>'$dir/release/p3stack/skills/swarm/SKILL.md'
    echo UPSTREAM_TEAM_THREE >>'$dir/release/team-kit/skills/deslop/SKILL.md'
    git -C '$dir/release' -c user.name=fixture -c user.email=fixture@example.com commit -qam third
    git -C '$dir/release' push -q '$dir/origin.git' main
    git -C '$home/.codex/.tmp/marketplaces/p3stack' pull --quiet --ff-only
    touch '$dir/published'
  fi
fi
exec '$dir/realbin/codex' "\$@"
WRAP
  chmod +x "$dir/bin/codex"
  tools=codex update_answering "a\n"
  local third
  third=$(git --git-dir="$dir/origin.git" rev-parse HEAD)
  [[ $(cat "$home/.p3stack/installed/codex/p3stack.commit") == "$new" ]] || fail 'first plugin was attributed to the later marketplace commit'
  [[ $(cat "$home/.p3stack/installed/codex/p3stack-team-kit.commit") == "$third" ]] || fail 'second plugin lacks its own commit'
  lacks "$codex/skills/swarm/SKILL.md" UPSTREAM_THREE
  has "$home/.codex/plugins/cache/p3stack/p3stack-team-kit/1.0.0/skills/deslop/SKILL.md" UPSTREAM_TEAM_THREE
  tools=codex update_answering "" P3STACK_NONINTERACTIVE=1
  has "$codex/skills/swarm/SKILL.md" UPSTREAM_THREE
  never_says 'Kept your version of swarm'
}

fake_capture() {
  local capture=$1 status=0 expected
  shift
  (load_fixture || exit 99; "$@") >"$dir/listing" 2>&1 || status=$?
  expected=$(sed -n 's/^exit: //p' "$here/real-cli/$capture")
  [[ $status == "$expected" ]] || fail "$capture exit $status differs from real exit $expected"
  python3 "$here/check-cli-format.py" "$capture" "$dir/listing" "$home" "$old" || fail "$capture differs from real output"
}

test_fake_listings_match_real_captures() {
  setup cli-format clean
  : >"$dir/out"
  local tool capture args
  for capture in codex-0.164.0-list-installed-json.txt codex-0.164.0-list-installed.txt claude-2.1.310-list-installed.txt claude-2.1.310-list-installed-json.txt opencode-2.1.4-list-observed-3.txt; do
    tool=${capture%%-*}
    args='plugin list'
    [[ $capture != *json.txt ]] || args+=' --json'
    (load_fixture || exit 99; "$tool" $args) >"$dir/listing"
    python3 "$here/check-cli-format.py" "$capture" "$dir/listing" "$home" "$old" || fail "$tool listing differs from its real capture"
  done
  (load_fixture || exit 99; codex plugin remove p3stack@p3stack; codex plugin remove p3stack-team-kit@p3stack; codex plugin list) >"$dir/listing"
  python3 "$here/check-cli-format.py" codex-0.164.0-list-removed.txt "$dir/listing" "$home" "$old" || fail "Codex removed listing differs from its real capture"
  (load_fixture || exit 99; opencode plugin remove github:sandwichlegend/p3stack; opencode plugin list) >"$dir/listing"
  python3 "$here/check-cli-format.py" opencode-2.1.4-plugin-list.txt "$dir/listing" "$home" "$old" || fail "OpenCode removed listing differs from its real capture"
  for tool in claude codex opencode cursor-agent; do
    capture=$tool
    case $tool in
      claude) capture+=-2.1.310-marketplace-list.txt ;;
      codex) capture+=-0.164.0-marketplace-list.txt ;;
      opencode) capture+=-2.1.4-plugin-marketplace-list.txt ;;
      cursor-agent) capture+=-2026.10.16-marketplace-list.txt ;;
    esac
    fake_capture "$capture" "$tool" plugin marketplace list
  done
  (load_fixture || exit 99; claude plugin marketplace remove p3stack; codex plugin marketplace remove p3stack)
  for tool in claude codex opencode cursor-agent; do
    case $tool in claude) version=2.1.310 ;; codex) version=0.164.0 ;; opencode) version=2.1.4 ;; cursor-agent) version=2026.10.16 ;; esac
    fake_capture "$tool-$version-marketplace-list-empty.txt" "$tool" plugin marketplace list
  done
  (load_fixture || exit 99; P3STACK_FAKE_OPENCODE_STALE=empty opencode plugin list) >"$dir/listing"
  python3 "$here/check-cli-format.py" opencode-2.1.4-list-observed-1.txt "$dir/listing" "$home" "$old" || fail 'OpenCode stale listing differs from capture'
  rm -rf "$home/.codex"
  fake_capture codex-0.164.0-list-missing-home.txt codex plugin list

}

test_fresh_codex_home_installs() {
  setup fresh-codex clean
  rm -rf "$home/.codex" "$home/.p3stack/installed/codex"
  tools=codex action=install update_answering "" P3STACK_NONINTERACTIVE=1
  exists "$codex/skills/poteto-mode/SKILL.md"
  recorded codex
}

test_codex_upgrade_does_not_call_release_files_user_edits() {
  setup codex-release interrupted
  tools=codex update_answering "a\n"
  is_release "$new" "$codex/skills/poteto-mode/SKILL.md" skills/poteto-mode/SKILL.md
  never_says 'after the scan'
}

test_opencode_stale_empty_listing_keeps_active_edit() {
  setup opencode-stale clean
  local file=$home/.cache/opencode/npm/git-p3stack-0123456789ab/0000000000001/node_modules/p3stack/p3stack/skills/poteto-mode/SKILL.md
  echo STALE_OPENCODE_EDIT_R5 >>"$file"
  tools=opencode expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1 P3STACK_FAKE_OPENCODE_STALE=empty
  has "$file" STALE_OPENCODE_EDIT_R5
  record_is opencode "$old"
  never_says '$ opencode plugin add'
  never_says 'record was dropped'
  says 'disagrees'
}

test_opencode_stale_listing_retries_when_attended() {
  setup opencode-retry clean
  local file=$home/.cache/opencode/npm/git-p3stack-0123456789ab/0000000000001/node_modules/p3stack/p3stack/skills/poteto-mode/SKILL.md
  echo STALE_RETRY_EDIT_R5 >>"$file"
  rm -f "$home/opencode-list-count"
  tools=opencode update_answering "" P3STACK_FAKE_OPENCODE_STALE=empty P3STACK_FAKE_OPENCODE_STALE_CALLS=2
  has "$file" STALE_RETRY_EDIT_R5
  has "$(backup_for opencode skills/poteto-mode/SKILL.md)" STALE_RETRY_EDIT_R5
  recorded opencode
}

test_opencode_stale_installed_listing_after_remove_stops() {
  setup opencode-stale-remove clean
  (load_fixture || exit 99; opencode plugin remove github:sandwichlegend/p3stack)
  tools=opencode expect_failure=1 update_answering "" P3STACK_NONINTERACTIVE=1 P3STACK_FAKE_OPENCODE_STALE=installed
  record_is opencode "$old"
  never_says '$ opencode plugin add'
  never_says 'record was dropped'
  says 'disagrees'
}

test_other_tools_late_edit_and_added_file_survive() {
  local tool file trigger active
  for tool in claude opencode; do
    setup late-$tool clean
    if [[ $tool == claude ]]; then
      file=$claude_old/skills/poteto-mode/SKILL.md
      active=$claude/skills/poteto-mode
      trigger='plugin marketplace update p3stack'
    else
      active=$home/.cache/opencode/npm/git-p3stack-0123456789ab/0000000000001/node_modules/p3stack/p3stack/skills/poteto-mode
      file=$active/SKILL.md
      trigger='plugin add github:sandwichlegend/p3stack'
    fi
    echo INITIAL_USER_EDIT_R5 >>"$file"
    mkdir -p "$dir/realbin"
    cp "$here/fake-tool" "$dir/realbin/$tool"
    rm "$dir/bin/$tool"
    cat >"$dir/bin/$tool" <<WRAP
#!/usr/bin/env bash
set -euo pipefail
[[ \$HOME == /tmp/* ]] || { echo "refusing: HOME=\$HOME"; exit 99; }
python3 -I '$here/safe-home.py' check --owned
if [[ \$* == '$trigger' ]]; then
  echo LATE_USER_EDIT_R5 >>'$file'
  echo LATE_USER_FILE_R5 >'${file%/*}/mine.txt'
fi
exec '$dir/realbin/$tool' "\$@"
WRAP
    chmod +x "$dir/bin/$tool"
    tools=$tool update_answering "" P3STACK_NONINTERACTIVE=1
    has "$active/SKILL.md" INITIAL_USER_EDIT_R5
    has "$active/SKILL.md" LATE_USER_EDIT_R5
    has "$active/mine.txt" LATE_USER_FILE_R5
    has "$(backup_for "$tool" skills/poteto-mode/SKILL.md)" LATE_USER_EDIT_R5
    has "$(backup_for "$tool" skills/poteto-mode/mine.txt)" LATE_USER_FILE_R5
  done
}

test_test_helpers_refuse_unsafe_home_and_missing_env() {
  setup guard clean
  local key before after
  before=$(find "$home/" -type f -exec sha256sum {} + | LC_ALL=C sort)
  for key in HOME CLAUDE_CONFIG_DIR CODEX_HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME; do
    if (load_fixture || exit 99; export "$key=/home/liam"; bash "$here/fixtures.sh" clean "$dir") >"$dir/refused" 2>&1; then fail "fixtures accepted unsafe $key"; fi
    if (load_fixture || exit 99; export "$key=/home/liam"; "$dir/bin/codex" plugin list) >"$dir/refused" 2>&1; then fail "fake accepted unsafe $key"; fi
    if (load_fixture || exit 99; export "$key=/home/liam"; bash "$here/test.sh" clean) >"$dir/refused" 2>&1; then fail "tests accepted unsafe $key"; fi
  done
  if bash "$here/fixtures.sh" clean "$dir" >"$dir/refused" 2>&1; then fail 'fixtures accepted a nonempty target'; fi
  mv "$dir/env.sh" "$dir/saved-env"
  if (load_fixture || exit 99; bash "$installer" update) >"$dir/refused" 2>&1; then fail 'missing env file did not stop execution'; fi
  mv "$dir/saved-env" "$dir/env.sh"
  after=$(find "$home/" -type f -exec sha256sum {} + | LC_ALL=C sort)
  [[ $before == "$after" ]] || fail 'refused command changed the fixture home'
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
