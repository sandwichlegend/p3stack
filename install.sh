#!/usr/bin/env bash
set -euo pipefail

repo=sandwichlegend/p3stack
marketplace=p3stack
plugins=(p3stack p3stack-team-kit)
codex_home=${CODEX_HOME:-$HOME/.codex}
codex_hooks=$codex_home/hooks.json
cursor_local=$HOME/.cursor/plugins/local
cursor_clone=$HOME/.p3stack/repo
codex_hook_changed=0
codex_hook_manual=0

usage() {
  cat <<EOF
Install p3stack into the AI coding tools T3 Code runs: Claude Code, Codex, and Cursor.

Usage: install.sh [install|update|uninstall] [--only claude,codex,cursor]

  install    Add p3stack and p3stack-team-kit to every tool found (default)
  update     Pull the latest p3stack into every tool found
  uninstall  Remove p3stack from every tool found
  --only     Limit to a comma-separated list of tools

Run it from a terminal, once per machine. Safe to run again.
EOF
}

say() { printf '%s\n' "$*"; }
heading() { printf '\n== %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
has() { command -v "$1" >/dev/null 2>&1; }

run() {
  printf '$ %s\n' "$*"
  "$@" </dev/null
}

remove() {
  local output status=0
  printf '$ %s\n' "$*"
  output=$("$@" </dev/null 2>&1) || status=$?
  [[ -n $output ]] && printf '%s\n' "$output"
  [[ $status == 0 ]] && return 0
  case $output in
    *"not found"*|*"not installed"*|*"not configured"*) say "already removed"; return 0 ;;
  esac
  return "$status"
}

claude_found() { has claude; }
codex_found() { has codex; }
cursor_found() { has cursor-agent || has cursor || [[ -d $HOME/.cursor ]]; }

claude_install() {
  run claude plugin marketplace add "$repo" || return 1
  for plugin in "${plugins[@]}"; do
    run claude plugin install "$plugin@$marketplace" || return 1
  done
}

claude_update() {
  claude_install || return 1
  run claude plugin marketplace update "$marketplace" || return 1
  for plugin in "${plugins[@]}"; do
    run claude plugin update "$plugin@$marketplace" || return 1
  done
}

claude_uninstall() {
  for plugin in "${plugins[@]}"; do
    remove claude plugin uninstall "$plugin@$marketplace" || return 1
  done
  remove claude plugin marketplace remove "$marketplace" || return 1
}

codex_hook_script() {
  local found=""
  for path in "$codex_home"/plugins/cache/"$marketplace"/p3stack/*/hooks/session-start; do
    [[ -x $path ]] && found=$path
  done
  printf '%s' "$found"
}

codex_hook_edit() {
  local mode=$1 command=${2:-}
  python3 - "$mode" "$codex_hooks" "$command" <<'PY'
import json, os, re, stat, sys, tempfile

mode, path, command = sys.argv[1:4]
ours = re.compile(r'^"?[^"]*/plugins/cache/p3stack/p3stack/[^/"]+/hooks/session-start"?$')

data = {}
if os.path.exists(path):
    with open(path) as handle:
        text = handle.read().strip()
    if text:
        try:
            data = json.loads(text)
        except ValueError as error:
            raise SystemExit(f"{path} isn't valid JSON ({error})")
if not isinstance(data, dict):
    raise SystemExit(f"{path} is not a JSON object")
hooks = data.get("hooks", {})
if not isinstance(hooks, dict):
    raise SystemExit(f"{path} has a \"hooks\" value that isn't an object")
groups = hooks.get("SessionStart", [])
if not isinstance(groups, list):
    raise SystemExit(f"{path} has a SessionStart value that isn't a list")

def is_ours(entry):
    return isinstance(entry, dict) and isinstance(entry.get("command"), str) and bool(ours.match(entry["command"]))

kept = []
for group in groups:
    entries = group.get("hooks") if isinstance(group, dict) else None
    if not isinstance(entries, list) or not any(is_ours(entry) for entry in entries):
        kept.append(group)
        continue
    others = [entry for entry in entries if not is_ours(entry)]
    if others:
        kept.append({**group, "hooks": others})

if mode == "add":
    kept.append({"hooks": [{"type": "command", "command": command, "timeout": 10}]})

if kept == groups:
    print("unchanged")
    raise SystemExit(0)

hooks["SessionStart"] = kept
data["hooks"] = hooks
directory = os.path.dirname(path)
os.makedirs(directory, exist_ok=True)
handle, temp = tempfile.mkstemp(dir=directory)
try:
    with os.fdopen(handle, "w") as out:
        json.dump(data, out, indent=2)
        out.write("\n")
    if os.path.exists(path):
        os.chmod(temp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(temp, path)
except BaseException:
    if os.path.exists(temp):
        os.unlink(temp)
    raise
print("changed")
PY
}

codex_hook_add() {
  local script result
  script=$(codex_hook_script)
  if [[ -z $script ]]; then
    warn "couldn't find p3stack's session-start hook under $codex_home/plugins/cache"
    codex_hook_manual=1
    return 0
  fi
  if ! has python3; then
    warn "python3 is missing, so the Codex startup hook wasn't added to $codex_hooks"
    codex_hook_manual=1
    return 0
  fi
  say "adding the p3stack startup hook to $codex_hooks"
  if ! result=$(codex_hook_edit add "\"$script\""); then
    warn "couldn't update $codex_hooks, so add the startup hook by hand"
    codex_hook_manual=1
    return 0
  fi
  [[ $result == changed ]] && codex_hook_changed=1
  say "startup hook $result"
}

codex_hook_remove() {
  [[ -f $codex_hooks ]] || return 0
  if ! has python3; then
    warn "python3 is missing, so remove the p3stack entry from $codex_hooks by hand"
    return 0
  fi
  say "removing the p3stack startup hook from $codex_hooks"
  if ! codex_hook_edit remove >/dev/null; then
    warn "couldn't update $codex_hooks, so remove the p3stack entry by hand"
    return 1
  fi
}

codex_install() {
  mkdir -p "$codex_home"
  run codex plugin marketplace add "$repo" || return 1
  for plugin in "${plugins[@]}"; do
    run codex plugin add "$plugin@$marketplace" || return 1
  done
  codex_hook_add
}

codex_update() {
  mkdir -p "$codex_home"
  run codex plugin marketplace add "$repo" || return 1
  run codex plugin marketplace upgrade "$marketplace" || return 1
  for plugin in "${plugins[@]}"; do
    run codex plugin add "$plugin@$marketplace" || return 1
  done
  codex_hook_add
}

codex_uninstall() {
  codex_hook_remove || return 1
  for plugin in "${plugins[@]}"; do
    remove codex plugin remove "$plugin@$marketplace" || return 1
  done
  remove codex plugin marketplace remove "$marketplace" || return 1
  find "$codex_home/plugins/cache/$marketplace" -depth -type d -empty -delete 2>/dev/null || true
}

cursor_install() {
  has git || { warn "git is required for Cursor"; return 1; }
  if [[ -d $cursor_clone/.git ]]; then
    run git -C "$cursor_clone" pull --ff-only --quiet || return 1
  else
    mkdir -p "$(dirname "$cursor_clone")"
    run git clone --quiet "https://github.com/$repo.git" "$cursor_clone" || return 1
  fi
  mkdir -p "$cursor_local"
  rm -rf "$cursor_local/p3stack" "$cursor_local/p3stack-team-kit"
  run cp -R "$cursor_clone/p3stack" "$cursor_local/p3stack" || return 1
  run cp -R "$cursor_clone/team-kit" "$cursor_local/p3stack-team-kit" || return 1
  if [[ -d $HOME/.cursor/plugins/cache/cursor-public/pstack ]]; then
    warn "Cursor's own pstack plugin is installed. Turn it off in Cursor's Customize panel so threads don't pick its Cursor-only skills."
  fi
}

cursor_update() { cursor_install; }

cursor_uninstall() {
  say "removing $cursor_local/p3stack and $cursor_local/p3stack-team-kit"
  rm -rf "$cursor_local/p3stack" "$cursor_local/p3stack-team-kit" "$cursor_clone"
}

next_steps() {
  local action=$1 done_tools=$2
  heading "Next"
  if [[ $action == uninstall ]]; then
    say "p3stack is removed. Your model choices and run files stay in ~/.p3stack/. Delete that folder to remove them too."
    return
  fi
  say "Start or resume a T3 thread to load p3stack."
  [[ $action == install ]] && say "Then run /setup-pstack once in any T3 thread to pick models."
  if [[ $done_tools == *codex* ]]; then
    if [[ $codex_hook_manual == 1 ]]; then
      say "Codex: add the startup hook to $codex_hooks by hand. The README's Codex section shows the entry."
    elif [[ $codex_hook_changed == 1 ]]; then
      say "Codex: run codex in a terminal, type /hooks, and trust the p3stack SessionStart hook. T3 can't ask you, and Codex skips hooks you haven't trusted."
    fi
  fi
  [[ $done_tools == *cursor* ]] && say "Cursor: type /poteto-mode at the start of each task. Cursor doesn't run the startup hook."
  return 0
}

main() {
  local action=install only="" only_given=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      install|update|uninstall) action=$1 ;;
      --only) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; only=$2; only_given=1; shift ;;
      --only=*) only=${1#--only=}; only_given=1 ;;
      -h|--help|help) usage; exit 0 ;;
      *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
    esac
    shift
  done

  local tools=(claude codex cursor)
  if [[ $only_given == 1 ]]; then
    tools=()
    local IFS=,
    for tool in $only; do
      [[ -z $tool ]] && continue
      case $tool in
        claude|codex|cursor) tools+=("$tool") ;;
        *) warn "unknown tool: $tool"; usage >&2; exit 2 ;;
      esac
    done
    unset IFS
    [[ ${#tools[@]} -gt 0 ]] || { warn "--only needs at least one tool"; usage >&2; exit 2; }
  fi

  local done_tools="" failed="" skipped=""
  for tool in "${tools[@]}"; do
    if ! "${tool}_found"; then
      skipped="$skipped $tool"
      continue
    fi
    heading "$action p3stack in $tool"
    if "${tool}_${action}"; then
      done_tools="$done_tools $tool"
    else
      failed="$failed $tool"
      warn "$action failed for $tool"
    fi
  done

  heading "Summary"
  [[ -n $done_tools ]] && say "done:${done_tools}"
  [[ -n $skipped ]] && say "not found, skipped:${skipped}"
  [[ -n $failed ]] && say "failed:${failed}"
  if [[ -z $done_tools && -z $failed ]]; then
    say "None of Claude Code, Codex, or Cursor was found on this machine."
    exit 1
  fi
  next_steps "$action" "$done_tools"
  [[ -z $failed ]]
}

main "$@"
