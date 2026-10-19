#!/usr/bin/env bash
set -euo pipefail

repo=sandwichlegend/p3stack
marketplace=p3stack
plugins=(p3stack p3stack-team-kit)
claude_settings=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
todo_tools=CLAUDE_CODE_ENABLE_TODO_TOOLS
codex_home=${CODEX_HOME:-$HOME/.codex}
codex_hooks=$codex_home/hooks.json
cursor_local=$HOME/.cursor/plugins/local
cursor_clone=$HOME/.p3stack/repo
opencode_spec=github:$repo
agent_tasks=()
trust_codex_hook=0

usage() {
  cat <<EOF
Install p3stack into the AI coding tools T3 Code runs: Claude Code, Codex, Cursor, and OpenCode.

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

query() {
  local output
  if ! output=$("$@" </dev/null 2>&1); then
    warn "couldn't run: $*"
    printf '%s\n' "$output" >&2
    return 1
  fi
  printf '%s' "$output"
}

lists() {
  local listing=$1 wanted=$2
  [[ $'\n'$listing$'\n' == *[[:space:]]"$wanted"$'\n'* || $'\n'$listing == *$'\n'"$wanted "* ]]
}

claude_found() { has claude; }
codex_found() { has codex; }
cursor_found() { has cursor-agent || has cursor || [[ -d $HOME/.cursor ]]; }
opencode_found() { has opencode; }

claude_settings_state() {
  python3 -I - "$claude_settings" "$todo_tools" <<'EOF'
import json, os, sys, tempfile

path, key = sys.argv[1], sys.argv[2]
sys.excepthook = lambda kind, error, trace: print(f"warning: {error}", file=sys.stderr)

def report(state):
    print(state)
    sys.exit()

def unique(pairs):
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError("duplicate key")
    return dict(pairs)

def reject(constant):
    raise ValueError(constant)

if os.path.islink(path):
    report("symlink")
settings = {}
try:
    with open(path, encoding="utf-8") as f:
        settings = json.load(f, object_pairs_hook=unique, parse_constant=reject)
except FileNotFoundError:
    pass
except ValueError:
    report("invalid")
env = settings.get("env", {}) if isinstance(settings, dict) else None
if not isinstance(env, dict):
    report("invalid")
if key in env:
    report("already" if env[key] == "1" else "other")
settings["env"] = {**env, key: "1"}

folder = os.path.dirname(path)
os.makedirs(folder, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.", suffix=".json")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    if os.path.exists(path):
        os.chmod(tmp, os.stat(path).st_mode & 0o7777)
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise
report("set")
EOF
}

claude_todo_tools() {
  local task="In $claude_settings, set \"env\".\"$todo_tools\" to the string \"1\", creating the file or its \"env\" object if needed. Keep every other key and value as it is. This turns on Claude Code's todo tools, which poteto-mode needs on Claude models newer than Opus 4.7."
  if ! has python3; then
    say "python3 isn't installed, so your agent will turn on Claude Code's todo tools"
    ask_agent "$task"
    return 0
  fi
  case $(claude_settings_state) in
    set) say "turned on Claude Code's todo tools with $todo_tools=1 in $claude_settings" ;;
    already) say "Claude Code's todo tools are already on in $claude_settings" ;;
    other) say "$claude_settings sets $todo_tools to a value other than \"1\", so it was left as it is. Set it to \"1\" to give poteto-mode its todolist on Claude models newer than Opus 4.7." ;;
    symlink)
      say "$claude_settings is a symlink, so your agent will turn on the todo tools"
      ask_agent "$task"
      ;;
    invalid)
      say "$claude_settings isn't JSON the installer can edit safely, so your agent will turn on the todo tools"
      ask_agent "$task"
      ;;
    *)
      warn "couldn't update $claude_settings, so your agent will turn on the todo tools"
      ask_agent "$task"
      ;;
  esac
}

claude_install() {
  run claude plugin marketplace add "$repo" || return 1
  for plugin in "${plugins[@]}"; do
    run claude plugin install "$plugin@$marketplace" || return 1
  done
  claude_todo_tools
}

claude_update() {
  claude_install || return 1
  run claude plugin marketplace update "$marketplace" || return 1
  for plugin in "${plugins[@]}"; do
    run claude plugin update "$plugin@$marketplace" || return 1
  done
}

claude_uninstall() {
  local installed markets
  installed=$(query claude plugin list) || return 1
  markets=$(query claude plugin marketplace list) || return 1
  for plugin in "${plugins[@]}"; do
    if lists "$installed" "$plugin@$marketplace"; then
      run claude plugin uninstall "$plugin@$marketplace" || return 1
    fi
  done
  if lists "$markets" "$marketplace"; then
    run claude plugin marketplace remove "$marketplace" || return 1
  fi
  if [[ -f $claude_settings && $(<"$claude_settings") == *"$todo_tools"* ]]; then
    say "$todo_tools stays in $claude_settings, since you may want the todo tools without p3stack. To turn them off, delete it from \"env\" there."
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
  local script add_task
  script=$(codex_hook_script)
  if [[ -z $script ]]; then
    ask_agent "Codex installed p3stack, but its startup hook script isn't under $codex_home/plugins/cache/$marketplace/p3stack/. Find hooks/session-start in the installed p3stack plugin and add it as a SessionStart command hook in $codex_hooks, keeping every existing entry."
    return 0
  fi
  add_task="In $codex_hooks, add a SessionStart hook of type \"command\" that runs the executable $script with timeout 10, quoting the path for the shell and escaping it for JSON. Keep every existing entry as it is."
  trust_codex_hook=1
  local plain='^[A-Za-z0-9/._ @+-]+$'
  if ! [[ $script =~ $plain ]]; then
    say "the hook path has characters the installer won't write by hand, so your agent will add it"
    ask_agent "$add_task"
  elif [[ -L $codex_hooks ]]; then
    say "$codex_hooks is a symlink, so your agent will add the startup hook"
    ask_agent "$add_task"
  elif [[ ! -e $codex_hooks ]] && (set -C; codex_hooks_json "$script" >"$codex_hooks") 2>/dev/null; then
    say "wrote the p3stack startup hook to $codex_hooks"
  elif [[ -f $codex_hooks && $(<"$codex_hooks") == *"\\\"$script\\\""* ]]; then
    say "the p3stack startup hook is already in $codex_hooks"
    trust_codex_hook=0
  elif [[ -e $codex_hooks ]]; then
    say "$codex_hooks already exists, so your agent will add the startup hook"
    ask_agent "$add_task"
  else
    warn "couldn't create $codex_hooks, so your agent will add the startup hook"
    ask_agent "$add_task"
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
  local script markets
  script=$(codex_hook_script)
  if [[ -f $codex_hooks && ! -L $codex_hooks ]]; then
    if [[ -n $script && $(<"$codex_hooks") == "$(codex_hooks_json "$script")" ]]; then
      say "removing $codex_hooks, which only held the p3stack startup hook"
      rm "$codex_hooks" || return 1
    elif [[ $(<"$codex_hooks") == *"/plugins/cache/$marketplace/p3stack/"* ]]; then
      ask_agent "In $codex_hooks, remove every SessionStart hook entry whose command runs a path under $codex_home/plugins/cache/$marketplace/p3stack/. Keep every other entry as it is."
    fi
  elif [[ -L $codex_hooks ]]; then
    ask_agent "Check $codex_hooks (a symlink) for SessionStart hook entries that run a path under $codex_home/plugins/cache/$marketplace/p3stack/, and remove only those."
  fi
  for plugin in "${plugins[@]}"; do
    run codex plugin remove "$plugin@$marketplace" || return 1
  done
  markets=$(query codex plugin marketplace list) || return 1
  if lists "$markets" "$marketplace"; then
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
  if [[ ! -d $cursor_clone/p3stack || ! -d $cursor_clone/team-kit ]]; then
    warn "$cursor_clone is missing p3stack/ or team-kit/, so the Cursor copies were left as they are"
    return 1
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

opencode_v2() {
  local version
  version=$(query opencode --version) || return 1
  if [[ ! $version =~ v?([0-9]+)\. ]] || ((BASH_REMATCH[1] < 2)); then
    warn "p3stack needs OpenCode V2, and this is ${version:-an unknown version}. Install @opencode/cli to upgrade."
    return 1
  fi
}

opencode_install() {
  opencode_v2 || return 1
  run opencode plugin add "$opencode_spec"
}

opencode_update() {
  opencode_install || return 1
  run opencode plugin update "$opencode_spec"
}

opencode_uninstall() { run opencode plugin remove "$opencode_spec"; }

finish() {
  local action=$1 done_tools=$2 failed=$3
  heading "Next"
  if [[ $action == uninstall ]]; then
    say "p3stack is removed from:${done_tools:- nothing}. Your model choices stay in ~/.p3stack/."
  else
    say "Start or resume a T3 thread to load p3stack."
    [[ $action == install ]] && say "Then run /setup-pstack once in any T3 thread to pick models."
    [[ $done_tools == *cursor* ]] && say "Cursor doesn't run the startup hook, so type /poteto-mode at the start of each task there."
    if [[ $done_tools == *opencode* ]]; then
      say "For OpenCode, use Refresh provider status in T3's Settings > Providers. OpenCode can keep its old config for about 30 seconds, so refresh again if p3stack's skills don't show."
    fi
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
  for tool in claude codex cursor opencode; do
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
    say "None of Claude Code, Codex, Cursor, or OpenCode was found on this machine."
    exit 1
  fi
  finish "$action" "$done_tools" "$failed"
  [[ -z $failed ]]
}

main "$@"
