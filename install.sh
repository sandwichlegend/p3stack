#!/usr/bin/env bash
set -euo pipefail

repo=sandwichlegend/p3stack
marketplace=p3stack
plugins=(p3stack p3stack-team-kit)
codex_home=${CODEX_HOME:-$HOME/.codex}
codex_hooks=$codex_home/hooks.json
cursor_local=$HOME/.cursor/plugins/local
cursor_clone=$HOME/.p3stack/repo
agent_tasks=()
trust_codex_hook=0

usage() {
  cat <<EOF
Install p3stack into the AI coding tools T3 Code runs: Claude Code, Codex, and Cursor.

Usage: install.sh [install|update|uninstall]

  install    Add p3stack and p3stack-team-kit to every tool found (default)
  update     Pull the latest p3stack into every tool found
  uninstall  Remove p3stack from every tool found

Run it from a terminal, once per machine. Safe to run again.
Anything it can't do with certainty, it hands to your coding agent as a prompt.
EOF
}

say() { printf '%s\n' "$*"; }
heading() { printf '\n== %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
has() { command -v "$1" >/dev/null 2>&1; }
ask_agent() { agent_tasks+=("$1"); }

run() {
  printf '$ %s\n' "$*"
  "$@" </dev/null
}

lists() {
  local wanted=$1 output
  shift
  output=$("$@" </dev/null 2>/dev/null) || return 1
  [[ $'\n'$output$'\n' == *[[:space:]]"$wanted"$'\n'* || $'\n'$output == *$'\n'"$wanted "* ]]
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
    if lists "$plugin@$marketplace" claude plugin list; then
      run claude plugin uninstall "$plugin@$marketplace" || return 1
    fi
  done
  if lists "$marketplace" claude plugin marketplace list; then
    run claude plugin marketplace remove "$marketplace" || return 1
  fi
}

codex_hook_script() {
  local found=""
  for path in "$codex_home"/plugins/cache/"$marketplace"/p3stack/*/hooks/session-start; do
    [[ -x $path ]] && found=$path
  done
  printf '%s' "$found"
}

codex_hooks_json() {
  cat <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"$1\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
EOF
}

codex_hook_add() {
  local script
  script=$(codex_hook_script)
  if [[ -z $script ]]; then
    warn "couldn't find p3stack's startup hook in the Codex plugin cache"
    return 0
  fi
  if [[ ! -e $codex_hooks ]]; then
    say "writing the p3stack startup hook to $codex_hooks"
    codex_hooks_json "$script" >"$codex_hooks"
    trust_codex_hook=1
  elif [[ $(<"$codex_hooks") == *"\\\"$script\\\""* ]]; then
    say "the p3stack startup hook is already in $codex_hooks"
  else
    say "$codex_hooks already exists, so your agent will add the startup hook"
    ask_agent "In $codex_hooks, add a SessionStart hook of type \"command\" whose command is \"$script\" (with the double quotes) and timeout 10. Keep every existing entry as it is."
    trust_codex_hook=1
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
  local script
  script=$(codex_hook_script)
  if [[ -n $script && -f $codex_hooks ]]; then
    if [[ $(<"$codex_hooks") == "$(codex_hooks_json "$script")" ]]; then
      say "removing $codex_hooks, which only held the p3stack startup hook"
      rm "$codex_hooks"
    elif [[ $(<"$codex_hooks") == *"$script"* ]]; then
      ask_agent "In $codex_hooks, remove the SessionStart hook entry whose command is \"$script\". Keep every other entry as it is."
    fi
  fi
  for plugin in "${plugins[@]}"; do
    run codex plugin remove "$plugin@$marketplace" || return 1
  done
  if lists "$marketplace" codex plugin marketplace list; then
    run codex plugin marketplace remove "$marketplace" || return 1
  fi
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
  say "removing $cursor_local/p3stack, $cursor_local/p3stack-team-kit, and $cursor_clone"
  rm -rf "$cursor_local/p3stack" "$cursor_local/p3stack-team-kit" "$cursor_clone"
}

finish() {
  local action=$1 done_tools=$2 failed=$3
  heading "Next"
  if [[ $action == uninstall ]]; then
    say "p3stack is removed from:${done_tools:- nothing}. Your model choices stay in ~/.p3stack/."
  else
    say "Start or resume a T3 thread to load p3stack."
    [[ $action == install ]] && say "Then run /setup-pstack once in any T3 thread to pick models."
    [[ $done_tools == *cursor* ]] && say "Cursor doesn't run the startup hook, so type /poteto-mode at the start of each task there."
  fi
  for tool in $failed; do
    ask_agent "Finish the p3stack $action for $tool. The steps are in the $action section of https://github.com/sandwichlegend/p3stack#readme. The installer's output above shows where it stopped."
  done
  if [[ ${#agent_tasks[@]} -gt 0 ]]; then
    heading "Give this to your coding agent"
    for task in "${agent_tasks[@]}"; do
      say "- $task"
    done
  fi
  if [[ $trust_codex_hook == 1 ]]; then
    heading "One manual step"
    say "Run codex in a terminal, type /hooks, and trust the p3stack SessionStart hook. Codex skips hooks you haven't trusted, and T3 can't ask you."
  fi
  return 0
}

main() {
  local action=install
  case ${1:-install} in
    install|update|uninstall) action=${1:-install} ;;
    -h|--help|help) usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  [[ $# -le 1 ]] || { warn "too many arguments"; usage >&2; exit 2; }

  local done_tools="" failed="" skipped=""
  for tool in claude codex cursor; do
    if ! "${tool}_found"; then
      skipped="$skipped $tool"
      continue
    fi
    heading "$action p3stack in $tool"
    if "${tool}_${action}"; then
      done_tools="$done_tools $tool"
    else
      failed="$failed $tool"
      warn "$action stopped for $tool"
    fi
  done

  heading "Summary"
  [[ -n $done_tools ]] && say "done:${done_tools}"
  [[ -n $skipped ]] && say "not found, skipped:${skipped}"
  [[ -n $failed ]] && say "stopped:${failed}"
  if [[ -z $done_tools && -z $failed ]]; then
    say "None of Claude Code, Codex, or Cursor was found on this machine."
    exit 1
  fi
  finish "$action" "$done_tools" "$failed"
  [[ -z $failed ]]
}

main "$@"
