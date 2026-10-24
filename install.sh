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
p3stack_home=$HOME/.p3stack
release_clone=${P3STACK_REPO_DIR:-$p3stack_home/repo}
repo_url=${P3STACK_REPO_URL:-https://github.com/$repo.git}
records=$p3stack_home/installed
edits_home=$p3stack_home/edits
merges=$p3stack_home/merge
keyboard=${P3STACK_TTY:-/dev/tty}
opencode_spec=github:$repo
tool_names="claude codex cursor opencode"
agent_tasks=()
work=""
locked=0
pending=$p3stack_home/pending
cursor_previous=""
trust_codex_hook=0

usage() {
  cat <<EOF
Install p3stack into the AI coding tools T3 Code runs: Claude Code, Codex, Cursor, and OpenCode.

Usage: install.sh [install|update|uninstall] [tool...]
       install.sh detect

  install    Add p3stack and p3stack-team-kit to every tool found (default)
  update     Pull the latest p3stack into every tool found
  uninstall  Remove p3stack from every tool found
  detect     Print the tools found on this machine, one per line

Tools: $tool_names. Name some to act on only those.

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
  "$@" </dev/null 3<&-
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

claude_settings_enable() {
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

# json.dumps can't write a number's source text, so each number is parsed as a unique string and its text is put back after dumps.
numbers = {}
nonce = os.urandom(8).hex()

def keep(token):
    mark = f"\0{nonce}:{len(numbers)}\0"
    numbers[json.dumps(mark)] = token
    return mark

def reject(constant):
    raise ValueError(constant)

def has_acl(path):
    try:
        return "system.posix_acl_access" in os.listxattr(path)
    except (AttributeError, OSError):
        return False

if os.path.islink(path):
    report("symlink")
settings = {}
try:
    with open(path, encoding="utf-8") as f:
        settings = json.load(f, object_pairs_hook=unique, parse_float=keep, parse_int=keep, parse_constant=reject)
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
text = json.dumps(settings, indent=2, ensure_ascii=False)
for mark, token in numbers.items():
    text = text.replace(mark, token)

folder = os.path.dirname(path)
os.makedirs(folder, exist_ok=True)
old = os.stat(path) if os.path.exists(path) else None
if old and (not os.access(path, os.W_OK) or has_acl(path)):
    report("locked")
fd, tmp = tempfile.mkstemp(dir=folder, prefix=".settings.", suffix=".json")
new = os.fstat(fd)
if old and (old.st_uid, old.st_gid) != (new.st_uid, new.st_gid):
    os.close(fd)
    os.unlink(tmp)
    report("locked")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text + "\n")
        f.flush()
        os.fsync(f.fileno())
    if old:
        os.chmod(tmp, old.st_mode & 0o7777)
    os.replace(tmp, path)
except BaseException:
    os.unlink(tmp)
    raise
report("set")
EOF
}

python_ready() {
  has python3 || return 1
  [[ $(uname -s) != Darwin || $(command -v python3) != /usr/bin/python3 ]] || xcode-select -p >/dev/null 2>&1
}

claude_todo_tools() {
  local newer="Claude models newer than Opus 4.7, Sonnet 4.6, and Haiku 4.5"
  local reason
  if ! python_ready; then
    reason="python3 isn't installed or can't run"
  else
    case $(claude_settings_enable) in
      set) say "turned on Claude Code's todo tools with $todo_tools=1 in $claude_settings"; return 0 ;;
      already) say "Claude Code's todo tools are already on in $claude_settings"; return 0 ;;
      other)
        say "$claude_settings sets $todo_tools to a value other than \"1\", so it was left as it is. Set it to \"1\" to give poteto-mode its todolist on $newer."
        return 0
        ;;
      symlink) reason="$claude_settings is a symlink" ;;
      invalid) reason="$claude_settings isn't JSON the installer can edit safely" ;;
      locked) reason="$claude_settings has write protection, an owner, or an ACL the installer can't keep" ;;
      *) reason="couldn't update $claude_settings" ;;
    esac
  fi
  say "$reason, so your agent will turn on Claude Code's todo tools"
  ask_agent "In $claude_settings, set \"env\".\"$todo_tools\" to the string \"1\", creating the file or its \"env\" object if needed. Keep every other key and value as it is. If the key already has a value other than \"1\", leave it and tell me. This turns on Claude Code's todo tools, which poteto-mode needs on $newer."
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
    say "$todo_tools stays in $claude_settings, since you may want it without p3stack. Delete it from \"env\" there if you don't."
  fi
}

claude_root() {
  local list root="" pattern="\"id\": *\"$1@$marketplace\"[^}]*\"installPath\": *\"([^\"]*)\""
  list=$(claude plugin list --json </dev/null 2>/dev/null) || return 1
  if has node; then
    root=$(printf '%s' "$list" | node -e '
      let data=""; process.stdin.on("data", x => data += x).on("end", () => {
        const visit = value => {
          if (!value || typeof value !== "object") return;
          if (value.id === process.argv[1] && typeof value.installPath === "string") { console.log(value.installPath); return; }
          for (const child of Object.values(value)) visit(child);
        };
        try { visit(JSON.parse(data)); } catch { process.exitCode = 1; }
      });' "$1@$marketplace") || return 1
  elif python_ready; then
    root=$(printf '%s' "$list" | python3 -I -c '
import json, sys
def visit(value):
    if isinstance(value, dict):
        if value.get("id") == sys.argv[1] and isinstance(value.get("installPath"), str):
            print(value["installPath"])
            return
        for child in value.values(): visit(child)
    elif isinstance(value, list):
        for child in value: visit(child)
try: visit(json.load(sys.stdin))
except ValueError: sys.exit(1)
' "$1@$marketplace") || return 1
  else
    list=${list//$'\n'/ }
    [[ $list =~ $pattern ]] && root=${BASH_REMATCH[1]}
  fi
  [[ -n $root && -d $root ]] && printf '%s' "$root"
}

# Claude Code names each install folder by the first 12 characters of its commit.
claude_commit() {
  local root version
  root=$(claude_root p3stack) || return 1
  version=$(basename "$root")
  [[ $version =~ ^[0-9a-f]{7,40}$ ]] && release_commit "$version"
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

codex_root() {
  local dir found=""
  for dir in "$codex_home/plugins/cache/$marketplace/$1"/*/; do
    [[ -d $dir ]] && found=${dir%/}
  done
  [[ -n $found ]] && printf '%s' "$found"
}

# Codex copies plugins from its marketplace clone but keeps them in a folder named 1.0.0, so the clone's commit is only true right after an install.
codex_commit() {
  local list root
  list=$(codex plugin marketplace list </dev/null 2>/dev/null) || return 1
  root=$(awk -v name="$marketplace" '$1 == name { sub(/^[^ ]+ +/, ""); print; exit }' <<<"$list")
  [[ -n $root ]] && git -C "$root" rev-parse --verify --quiet 'HEAD^{commit}'
}

cursor_install() {
  has git || { warn "git is required for Cursor"; return 1; }
  if [[ -d $release_clone/.git ]]; then
    run git -C "$release_clone" pull --ff-only --quiet || return 1
  else
    mkdir -p "$(dirname "$release_clone")"
    run git clone --quiet "$repo_url" "$release_clone" || return 1
  fi
  if [[ ! -d $release_clone/p3stack || ! -d $release_clone/team-kit ]]; then
    warn "$release_clone is missing p3stack/ or team-kit/, so the Cursor copies were left as they are"
    return 1
  fi
  mkdir -p "$cursor_local"
  rm -rf "$cursor_local/p3stack" "$cursor_local/p3stack-team-kit"
  run cp -R "$release_clone/p3stack" "$cursor_local/p3stack" || return 1
  run cp -R "$release_clone/team-kit" "$cursor_local/p3stack-team-kit" || return 1
  if [[ -d $HOME/.cursor/plugins/cache/cursor-public/pstack ]]; then
    warn "Cursor's own pstack plugin is installed. Turn it off in Cursor's Customize panel so threads don't pick its Cursor-only skills."
  fi
}

cursor_update() { cursor_install; }

cursor_uninstall() {
  say "removing $cursor_local/p3stack, $cursor_local/p3stack-team-kit, and $release_clone"
  rm -rf "$cursor_local/p3stack" "$cursor_local/p3stack-team-kit" "$release_clone"
}

cursor_root() { [[ -d $cursor_local/$1 ]] && printf '%s' "$cursor_local/$1"; }

cursor_commit() { git -C "$release_clone" rev-parse --verify --quiet 'HEAD^{commit}'; }

opencode_v2() {
  local version pattern='v?([0-9]+)\.'
  version=$(query opencode --version) || return 1
  if [[ ! $version =~ $pattern ]] || ((BASH_REMATCH[1] < 2)); then
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

# OpenCode installs the whole repository under a new timestamped folder on each update.
opencode_package() {
  local dir stamp found="" newest=""
  for dir in "${XDG_CACHE_HOME:-$HOME/.cache}"/opencode/npm/git-p3stack-*/*/node_modules/p3stack; do
    [[ -d $dir ]] || continue
    stamp=$(basename "$(dirname "$(dirname "$dir")")")
    [[ $stamp > $newest ]] && newest=$stamp found=$dir
  done
  [[ -n $found ]] && printf '%s' "$found"
}

opencode_root() {
  local package
  package=$(opencode_package) || return 1
  [[ -d $package/$(subtree "$1") ]] && printf '%s' "$package/$(subtree "$1")"
}

opencode_commit() {
  local package lock pattern='#([0-9a-f]{40})'
  package=$(opencode_package) || return 1
  lock=$(cat "$(dirname "$package")/.package-lock.json" 2>/dev/null) || return 1
  [[ $lock =~ $pattern ]] && printf '%s' "${BASH_REMATCH[1]}"
}

tool_label() {
  case $1 in
    claude) say "Claude Code" ;;
    codex) say Codex ;;
    cursor) say Cursor ;;
    opencode) say OpenCode ;;
  esac
}

subtree() {
  case $1 in
    p3stack) say p3stack ;;
    p3stack-team-kit) say team-kit ;;
  esac
}

tilde() {
  if [[ $1 == "$HOME" || $1 == "$HOME/"* ]]; then printf '~%s' "${1#"$HOME"}"; else printf '%s' "$1"; fi
}
upper() { tr '[:lower:]' '[:upper:]' <<<"$1"; }
and_list() { awk -v n=$# 'NR > 1 { printf (NR == n ? " and " : ", ") } { printf "%s", $0 } END { print "" }' < <(printf '%s\n' "$@"); }
comma_list() { printf '%s\n' "$@" | paste -sd, - | sed 's/,/, /g'; }

if has sha256sum; then
  sha256() { sha256sum | cut -c1-64; }
else
  sha256() { shasum -a 256 | cut -c1-64; }
fi

drop_non_edits() {
  LC_ALL=C awk '
    { sub(/\r$/, "") }
    NR == 1 { front = $0 == "---"; print; next }
    front && $0 == "---" { front = 0 }
    front && $0 == "edited: true" { next }
    { print }' "$1"
}

file_hash() { drop_non_edits "$1" | sha256; }

hash_tree() {
  (
    cd "$1" || exit 1
    find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r path; do
      printf '%s  %s\n' "$(file_hash "$path")" "$path"
    done
  )
}

release_commit() { git -C "$release_clone" rev-parse --verify --quiet "$1^{commit}"; }

release_fetch() {
  has git || { warn "git is required to install or update p3stack"; return 1; }
  cursor_previous=$(cursor_commit 2>/dev/null || true)
  if [[ -d $release_clone/.git ]]; then
    git -C "$release_clone" fetch --quiet origin </dev/null 3<&- || return 1
  else
    mkdir -p "$(dirname "$release_clone")"
    git clone --quiet "$repo_url" "$release_clone" </dev/null 3<&- || return 1
  fi
  new_commit=$(release_commit origin/HEAD || release_commit origin/main) || return 1
  new_release=$(release_tree "$new_commit")
}

release_tree() {
  local commit=$1 dir=$work/release-$1 plugin
  if [[ ! -d $dir ]]; then
    mkdir -p "$dir.part"
    for plugin in "${plugins[@]}"; do
      : >"$dir.part/$plugin.sha256"
      git -C "$release_clone" cat-file -e "$commit:$(subtree "$plugin")" 2>/dev/null || continue
      mkdir -p "$dir.part/$plugin"
      git -C "$release_clone" archive "$commit" "$(subtree "$plugin")" | tar -x -C "$dir.part/$plugin" --strip-components=1 || return 1
      hash_tree "$dir.part/$plugin" >"$dir.part/$plugin.sha256"
    done
    mv "$dir.part" "$dir"
  fi
  printf '%s' "$dir"
}

record_commit() { cat "$records/$1/commit" 2>/dev/null; }

record_write() {
  local tool=$1 commit=$2 tree=$3 bases=${4:-/dev/null} plugin staging
  mkdir -p "$records/$tool"
  staging=$(mktemp -d "$records/$tool/.record.XXXXXX")
  for plugin in "${plugins[@]}"; do
    cp "$tree/$plugin.sha256" "$staging/$plugin.sha256" || return 1
  done
  cp "$bases" "$staging/bases" || return 1
  printf '%s\n' "$commit" >"$staging/commit" || return 1
  for plugin in "${plugins[@]}"; do mv "$staging/$plugin.sha256" "$records/$tool/$plugin.sha256" || return 1; done
  mv "$staging/bases" "$records/$tool/bases" || return 1
  mv "$staging/commit" "$records/$tool/commit" || return 1
  rmdir "$staging"
}

commit_named_by_install="claude opencode"

installed_base() {
  local base
  base=$(record_commit "$1" || true)
  if [[ -n $base ]]; then printf '%s' "$base"; return; fi
  if [[ $1 == cursor && -n $cursor_previous ]]; then printf '%s' "$cursor_previous"; return; fi
  [[ " $commit_named_by_install " == *" $1 "* ]] && "${1}_commit"
}

base_hashes() {
  local tool=$1 plugin=$2 base=$3 tree
  if [[ $(record_commit "$tool") == "$base" && -f $records/$tool/$plugin.sha256 ]]; then
    cat "$records/$tool/$plugin.sha256"
  elif tree=$(release_tree "$base"); then
    cat "$tree/$plugin.sha256"
  fi
}

# Fields are split by the unit separator because read collapses empty fields between tabs but keeps them between non-whitespace separators.
pair_hashes() {
  awk '
    { hash = substr($0, 1, 64); path = substr($0, 67); seen[path] = 1 }
    FILENAME == ARGV[1] { base[path] = hash; next }
    { new[path] = hash }
    END { for (path in seen) printf "%s%c%s%c%s\n", path, 28, base[path], 28, new[path] }' "$1" "$2" | LC_ALL=C sort
}

classify() {
  local base=$1 record=$2 disk=$3 new=$4 on_disk=differs release=changed
  if [[ -z $disk ]]; then on_disk=absent
  elif [[ $disk == "$new" ]]; then on_disk=as-new
  elif [[ $disk == "$record" ]]; then on_disk=as-record
  fi
  if [[ -z $new ]]; then release=removed
  elif [[ $new == "$record" ]]; then release=unchanged
  fi
  case $base/$on_disk/$release in
    */absent/*|*/as-new/*) say untouched ;;
    unknown/*) say unknown-base ;;
    known/as-record/*) say untouched ;;
    known/differs/unchanged) say edited-kept ;;
    known/differs/changed) say edited-conflict ;;
    known/differs/removed) say edited-removed ;;
  esac
}


class_policy() {
  local i=$1 name tool skill backup
  name=$(label "${row_path[i]}") tool=$(tool_label "${row_tool[i]}") skill=$(skill_of "${row_path[i]}" || true)
  backup=$(tilde "${row_backup[i]}")
  question=none choices="" recommended="" unattended=keep copy_offer=no
  scan_note="" question_note="" unattended_message="" report_style=file
  keep_note="Kept your version of $name."
  accept_note="Installed p3stack's $name. Your version is saved in $backup"
  moved_note=""
  case ${row_class[i]} in
    edited-kept)
      scan_note="p3stack didn't change it in this release" copy_offer=yes
      ;;
    edited-added)
      scan_note="you added this file" copy_offer=yes
      keep_note="Kept your file ${row_path[i]}."
      ;;
    edited-conflict)
      question=file choices=keep,accept,talk recommended=talk copy_offer=yes
      scan_note="p3stack also changed it"
      question_note="$name in $tool: you and p3stack both changed this $(noun 1 "$i")."
      unattended_message="No one is at the keyboard to choose, so your version of $name in $tool was kept. p3stack's change to it was skipped. Run \"p3stack update\" in a terminal to choose."
      keep_note="Kept your version of $name. p3stack's change was skipped. You'll be asked again on the next update."
      ;;
    edited-file-removed)
      question=file choices=keep,accept recommended=accept copy_offer=yes
      scan_note="p3stack removed this file in this release"
      question_note="$name in $tool: you edited this file, and the new release no longer has this file."
      unattended_message="No one is at the keyboard to choose, so your file $name in $tool was kept. Run \"p3stack update\" in a terminal to choose."
      accept_note="Removed $name. Your version is saved in $backup"
      ;;
    edited-removed)
      question=skill choices=keep,accept recommended=accept
      scan_note="p3stack removed it in this release"
      question_note="$skill in $tool: you edited this skill, and the new release no longer has it."
      unattended_message="No one is at the keyboard to choose, so your version of $skill in $tool was kept in $(tilde "$HOME/.agents/skills/$skill")."
      accept_note="Removed $name. Your version is saved in $backup"
      moved_note="Moved your $skill to $(tilde "$HOME/.agents/skills/$skill") and linked it into each tool. p3stack won't update it any more."
      ;;
    unknown-base)
      question=tool choices=keep,accept recommended=accept unattended=accept report_style=group
      unattended_message="No one is at the keyboard to choose, so p3stack's versions go into $tool. Old copies are saved in $(tilde "$edits_home/${row_tool[i]}")/."
      ;;
    deleted)
      keep_note="You deleted ${row_path[i]}; p3stack's update put it back."
      ;;
  esac
}

choice_label() {
  case $1 in
    keep) say "Keep mine" ;;
    accept) say "Accept p3stack's version" ;;
    talk) say "Talk to a model to merge them" ;;
  esac
}

merge_agents='claude:Claude Code
codex:Codex
cursor-agent:Cursor
opencode:OpenCode'

found_agents() {
  local line
  while IFS= read -r line; do
    has "${line%%:*}" && say "$line"
  done <<<"$merge_agents"
}

launch_agent() {
  case $1 in
    opencode) opencode --prompt "$2" ;;
    *) "$1" "$2" ;;
  esac
}

label() {
  local path=$1 pattern='^skills/([^/]+)/SKILL\.md$'
  [[ $path =~ $pattern ]] && { say "${BASH_REMATCH[1]}"; return; }
  say "${path#skills/}"
}

skill_of() { local pattern='^skills/([^/]+)/'; [[ $1 =~ $pattern ]] && say "${BASH_REMATCH[1]}"; }

has_frontmatter() { [[ -f $1 && $(head -1 "$1" | tr -d '\r') == --- ]]; }

marked() { has_frontmatter "$1" && awk 'NR > 1 && /^---\r?$/ { exit 1 } /^edited: true\r?$/ { found = 1; exit } END { exit !found }' "$1"; }

stamp() {
  has_frontmatter "$1" && ! marked "$1" || return 0
  local file=$1 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/p3stack.XXXXXX")
  awk 'NR > 1 && !done && /^---\r?$/ { print "edited: true"; done = 1 } { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
  rm -f "$tmp"
}

normalized_diff() {
  [[ -f $1 && -f $2 ]] || return 0
  drop_non_edits "$1" >"$work/from"
  drop_non_edits "$2" >"$work/to"
  diff -u "$work/from" "$work/to" || true
}

changed_lines() {
  normalized_diff "$1" "$2" | awk '/^\+\+\+|^---/ { next } /^\+/ { added++ } /^-/ { removed++ } END { n = added > removed ? added : removed; if (n == 1) print "1 line"; else if (n) print n " lines" }'
}

change_summary() {
  local count where
  count=$(changed_lines "$1" "$2")
  [[ -n $count ]] || return 0
  where=$(normalized_diff "$1" "$2" | awk -v from="$work/from" '
    /^@@ / { split($2, range, ","); line_number = -range[1]; next }
    /^---|^\+\+\+/ { next }
    /^[-+]/ { first = line_number; exit }
    /^ / { line_number++ }
    END {
      while ((getline line < from) > 0 && ++i <= first) {
        if (line ~ /^#+ /) near = "in \"" line "\""
        else if (match(line, /(function|def|class) [A-Za-z0-9_]+/)) near = "near \"" substr(line, RSTART, RLENGTH) "\""
      }
      print near
    }')
  say "$count${where:+ $where}"
}

row_tool=() row_plugin=() row_path=() row_class=() row_root=() row_base=() row_action=() row_source=() row_from=() row_backup=()

add_row() {
  local n=${#row_tool[@]}
  row_tool[n]=$1 row_plugin[n]=$2 row_path[n]=$3 row_class[n]=$4 row_root[n]=$5 row_base[n]=$6
  row_action[n]="" row_source[n]="" row_from[n]="" row_backup[n]=""
}

edited() { [[ ${row_class[$1]} == edited-* || ${row_class[$1]} == unknown-base ]]; }

base_file() {
  local tree
  [[ -n ${row_base[$1]} && ${row_base[$1]} != added ]] && tree=$(release_tree "${row_base[$1]}") && [[ -f $tree/${row_plugin[$1]}/${row_path[$1]} ]] &&
    printf '%s' "$tree/${row_plugin[$1]}/${row_path[$1]}"
}

new_file() { printf '%s' "$new_release/${row_plugin[$1]}/${row_path[$1]}"; }
disk_file() { printf '%s' "${row_root[$1]}/${row_path[$1]}"; }
backup_file() { printf '%s' "${row_backup[$1]}"; }

noun() {
  local count=$1 word=skill i
  shift
  for i in "$@"; do
    [[ ${row_path[i]} == skills/*/SKILL.md ]] || word=file
  done
  ((count == 1)) && say "$word" || say "${word}s"
}


# These names belong to tool caches, not to the user's plugin files.
ignored_paths='.in_use
.orphaned_at
node_modules
.package-lock.json
.git
.DS_Store'

installed_paths() {
  local root=$1 path part ignored
  find "$root" \( -type f -o -type l \) -print0 >"$work/disk-paths"
  while IFS= read -r -d '' path; do
    path=${path#"$root"/}
    ignored=0
    while IFS= read -r part; do
      [[ /$path/ != *"/$part/"* ]] || ignored=1
    done <<<"$ignored_paths"
    ((ignored == 0)) || continue
    if [[ $path == *$'\n'* || $path == *$'\t'* || $path == *$'\034'* || -L $root/$path ]]; then
      warn "couldn't safely scan $root/$path; installed files were left alone"
      return 1
    fi
    printf '%s\n' "$path"
  done <"$work/disk-paths"
}

history_matches() {
  local plugin=$1 path=$2 hash=$3 commit
  while IFS= read -r commit; do
    git -C "$release_clone" show "$commit:$(subtree "$plugin")/$path" >"$work/history-file" 2>/dev/null || continue
    [[ $(file_hash "$work/history-file") != "$hash" ]] || return 0
  done < <(git -C "$release_clone" log --all --format=%H -- "$(subtree "$plugin")/$path")
  return 1
}

old_root() {
  local tool=$1 plugin=$2 base=$3 dir lock
  case $tool in
    claude)
      dir=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/$marketplace/$plugin/${base:0:12}
      [[ -d $dir ]] && printf '%s' "$dir"
      ;;
    opencode)
      for dir in "${XDG_CACHE_HOME:-$HOME/.cache}"/opencode/npm/git-p3stack-*/*/node_modules/p3stack; do
        [[ -d $dir/$(subtree "$plugin") ]] || continue
        lock=$(cat "$(dirname "$dir")/.package-lock.json" 2>/dev/null || true)
        if [[ $lock == *"#$base"* ]]; then printf '%s' "$dir/$(subtree "$plugin")"; return 0; fi
      done
      return 1
      ;;
    *) return 1 ;;
  esac
}

backup_row() {
  local i=$1 source hash candidate generation dest
  source=$(disk_file "$i")
  hash=$(file_hash "$source") || return 1
  if [[ -d $edits_home/${row_tool[i]} ]]; then
    while IFS= read -r candidate; do
      [[ $candidate == *"/${row_plugin[i]}/${row_path[i]}" ]] || continue
      if [[ $(file_hash "$candidate") == "$hash" ]]; then
        row_backup[i]=$candidate row_source[i]=$candidate
        return 0
      fi
    done < <(find "$edits_home/${row_tool[i]}" -type f)
  fi
  if ! mkdir -p "$edits_home/${row_tool[i]}"; then warn "backup failed for $source; nothing will install"; return 1; fi
  generation=$edits_home/${row_tool[i]}/$run_generation
  if [[ ! -d $generation ]]; then
    mkdir "$generation" || { warn "couldn't create backup generation $generation"; return 1; }
  fi
  dest=$generation/${row_plugin[i]}/${row_path[i]}
  if [[ -e $dest || -L $dest ]] || ! mkdir -p "$(dirname "$dest")" || ! cp -p "$source" "$dest"; then
    warn "backup failed for $source; nothing will install"
    return 1
  fi
  if [[ $(sha256 <"$dest") != "$(sha256 <"$source")" ]]; then warn "backup verification failed for $source; nothing will install"; return 1; fi
  row_backup[i]=$dest row_source[i]=$dest
}

edits_scan() {
  local tool=$1 base=$2 known=unknown plugin plugin_base listing root active old path record new disk first=${#row_tool[@]} i count path_base override class skill warned=0
  local changed=() found=() unknown=() labels=()
  [[ -n $base ]] && known=known
  heading "$(tool_label "$tool")"
  if [[ -z $(record_commit "$tool") ]]; then
    case $known/$tool in
      known/claude) say "  No record of the last install. Using the commit in the folder name (${base:0:7})." ;;
      known/*) say "  No record of the last install. Using the commit $(tool_label "$tool") installed (${base:0:7})." ;;
      *) warn "No record of the last install in $(tool_label "$tool"), and $(tool_label "$tool") doesn't say which version it has." ;;
    esac
  fi
  active=$("${tool}_commit" 2>/dev/null || true)
  for plugin in "${plugins[@]}"; do
    root=$("${tool}_root" "$plugin") || { warn "couldn't resolve $plugin in $(tool_label "$tool"); no scan means no install"; return 1; }
    if [[ " $commit_named_by_install " == *" $tool "* && -n $base && -n $active && $base != "$active" ]]; then
      if old=$(old_root "$tool" "$plugin" "$base"); then
        root=$old
        say "  Checking $plugin edits from before the background auto-update."
      elif ((warned == 0)); then
        warn "Edits made before the auto-update may be in a folder $(tool_label "$tool") removed."
        warned=1
      fi
    fi
    listing=$work/base-$tool-$plugin
    : >"$listing"
    [[ $known == unknown ]] || base_hashes "$tool" "$plugin" "$base" >"$listing"
    if [[ -s $listing ]]; then plugin_base=known; else plugin_base=unknown; fi
    installed_paths "$root" >"$work/installed-paths"
    { pair_hashes "$listing" "$new_release/$plugin.sha256" | cut -d $'\034' -f1; cat "$work/installed-paths"; } | LC_ALL=C sort -u >"$work/paths"
    while IFS= read -r path; do
      [[ -n $path ]] || continue
      path_base=$base
      override=$(awk -F '\t' -v path="$plugin/$path" '$1 == path { print $2 }' "$records/$tool/bases" 2>/dev/null || true)
      [[ -z $override ]] || path_base=$override
      record=$(awk -v path="$path" 'substr($0, 67) == path { print substr($0, 1, 64) }' "$listing")
      if [[ -n $override && $override != added ]]; then
        old=$(release_tree "$override") || return 1
        if [[ -f $old/$plugin/$path ]]; then record=$(file_hash "$old/$plugin/$path"); fi
      fi
      new=$(awk -v path="$path" 'substr($0, 67) == path { print substr($0, 1, 64) }' "$new_release/$plugin.sha256")
      disk=""
      [[ ! -f $root/$path ]] || disk=$(file_hash "$root/$path")
      if [[ -z $disk ]]; then
        [[ -n $record && -n $new ]] || continue
        class=deleted
      elif [[ -z $record && -z $new && -z $(git -C "$release_clone" log --all -1 --format=%H -- "$(subtree "$plugin")/$path") ]]; then
        class=edited-added path_base=added
      else
        class=$(classify "$plugin_base" "$record" "$disk" "$new")
        if [[ $class != untouched ]] && history_matches "$plugin" "$path" "$disk"; then class=untouched; fi
        if [[ $class == edited-removed ]]; then
          skill=$(skill_of "$path" || true)
          [[ -n $skill && ! -f $new_release/$plugin/skills/$skill/SKILL.md ]] || class=edited-file-removed
        fi
      fi
      add_row "$tool" "$plugin" "$path" "$class" "$root" "$path_base"
    done <"$work/paths"
  done
  for ((i = first; i < ${#row_tool[@]}; i++)); do
    edited "$i" || continue
    backup_row "$i" || return 1
    found+=("$i")
    [[ ${row_class[i]} == unknown-base ]] && unknown+=("$i") && continue
    has_frontmatter "$(disk_file "$i")" && ! marked "$(disk_file "$i")" && changed+=("$i")
  done
  if ((${#changed[@]})); then
    if ((${#changed[@]} == 1)); then warn 'Found a change with no "edited" mark:'; else warn "Found ${#changed[@]} changes with no \"edited\" mark:"; fi
    for i in "${changed[@]}"; do
      count=$(changed_lines "$(base_file "$i")" "$(disk_file "$i")")
      case $count in
        "") printf '    %s\n' "${row_path[i]}" ;;
        "1 line") printf '    %s   1 line differs from what was installed\n' "${row_path[i]}" ;;
        *) printf '    %s   %s differ from what was installed\n' "${row_path[i]}" "$count" ;;
      esac
    done
    ((${#changed[@]} == 1)) && say "  Marked it edited." || say "  Marked them edited."
  fi
  if ((${#unknown[@]})); then
    for i in "${unknown[@]}"; do labels+=("$(label "${row_path[i]}")"); done
    if ((${#unknown[@]} == 1)); then count=differs; else count=differ; fi
    say "  ${#unknown[@]} $(noun ${#unknown[@]} "${unknown[@]}") $count from the new release: $(comma_list "${labels[@]}")"
    say "  They may be your edits, or just the older version."
  elif ((${#found[@]})); then
    say "  ${#found[@]} $(noun ${#found[@]} "${found[@]}") you edited:"
    for i in "${found[@]}"; do
      class_policy "$i"
      printf '    %-13s %s\n' "$(label "${row_path[i]}")" "$scan_note"
    done
  else
    say "  No edited files."
  fi
}

attended=0

open_keyboard() {
  [[ ${P3STACK_NONINTERACTIVE:-} == 1 ]] && return 0
  { exec 3<"$keyboard"; } 2>/dev/null && attended=1
  return 0
}

choose() {
  local recommended=$1 keys=() shown="" reply key mark
  choice=""
  shift
  while (($#)); do
    keys+=("$1")
    mark=""
    [[ $1 == "$recommended" ]] && mark=" (recommended)"
    printf '    [%s] %s%s\n' "$(upper "$1")" "$2" "$mark"
    shown+=${shown:+/}$(upper "$1")
    shift 2
  done
  while :; do
    printf '  Choose %s [%s]: ' "$shown" "$(upper "$recommended")"
    if ! IFS= read -r reply <&3; then
      printf '\n'
      attended=0
      return 1
    fi
    [[ -t 3 ]] || printf '%s\n' "$reply"
    reply=$(tr '[:upper:]' '[:lower:]' <<<"$reply" | tr -d '[:space:]')
    [[ -n $reply ]] || reply=$recommended
    for key in "${keys[@]}"; do
      [[ $reply == "$key" ]] && choice=$key && return 0
    done
    say "  Type $shown, or press enter for $(upper "$recommended")."
  done
}

group_rows() {
  local i=$1 kind=$2 j
  for ((j = 0; j < ${#row_tool[@]}; j++)); do
    [[ ${row_tool[j]} == "${row_tool[i]}" && ${row_class[j]} == "${row_class[i]}" && -z ${row_action[j]} ]] || continue
    case $kind in
      file) ((j == i)) ;;
      skill) [[ ${row_plugin[j]} == "${row_plugin[i]}" && $(skill_of "${row_path[j]}") == "$(skill_of "${row_path[i]}")" ]] ;;
      tool) true ;;
    esac && say "$j"
  done
}

summary_line() {
  [[ -z $2 ]] || printf '    %-9s %s\n' "$1" "$2"
}

ask_about() {
  local i=$1 kind=$2 labels=() j
  shift 2
  say ""
  if [[ $kind == tool ]]; then
    for j; do labels+=("$(label "${row_path[j]}")"); done
    say "  $(and_list "${labels[@]}") in $(tool_label "${row_tool[i]}"):"
  else
    say "  $question_note"
    if [[ $choices == *talk* ]]; then
      summary_line Yours "$(change_summary "$(base_file "$i")" "$(disk_file "$i")")"
      summary_line p3stack "$(change_summary "$(base_file "$i")" "$(new_file "$i")")"
    fi
  fi
}

unattended_note() {
  class_policy "$1"
  [[ -z $unattended_message ]] || warn "$unattended_message"
}

make_personal_skill() {
  local i=$1 skill dest link j
  shift
  skill=$(skill_of "${row_path[i]}")
  dest=$HOME/.agents/skills/$skill
  if [[ -e $dest || -L $dest ]]; then
    warn "$(tilde "$dest") already exists, so $skill comes out of $(tool_label "${row_tool[i]}") and your version is saved in $(tilde "${row_backup[i]}")."
    for j; do row_action[j]=accept; done
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -R "${row_root[i]}/skills/$skill" "$dest"
  for link in "$HOME/.claude/skills/$skill" "$HOME/.cursor/skills/$skill"; do
    [[ -e $link || -L $link ]] && continue
    mkdir -p "$(dirname "$link")"
    ln -s "../../.agents/skills/$skill" "$link"
  done
  for j; do row_action[j]=moved; done
}

merge_brief() {
  local i=$1 ext=$2 skill
  skill=$(skill_of "${row_path[i]}")
  cat <<EOF
# Merge $(label "${row_path[i]}")

The person at the keyboard changed their installed copy of this p3stack file, and p3stack also changed it in its new release. Help them combine the two.

- \`yours$ext\` is their copy, with their changes.
- \`theirs$ext\` is the file in p3stack's new release.
EOF
  if [[ -f original$ext ]]; then
    printf -- '- `original%s` is the file as p3stack shipped it in the release they have installed.\n\n' "$ext"
    printf '1. Compare each copy against `original%s`. Explain in plain words what they changed and what p3stack changed.\n' "$ext"
  else
    printf '\nThe release they installed is not available, so compare `yours%s` and `theirs%s` directly.\n\n' "$ext" "$ext"
    printf '1. Explain in plain words how the two versions differ.\n'
  fi
  printf '2. Help them combine the two. Ask before you drop a change from either side.\n'
  if [[ $ext != .md && -n $skill ]]; then
    printf '3. This file is a script, so run its tests first. Copy `%s` to a scratch folder, put the combined file in place of `%s`, run the tests there, and fix what fails.\n' "${row_root[i]}/skills/$skill" "${row_path[i]#skills/"$skill"/}"
    printf '4. Write the combined file to `result%s` in this folder. Leave the other files as they are.\n' "$ext"
  else
    printf '3. Write the combined file to `result%s` in this folder. Leave the other files as they are.\n' "$ext"
  fi
  printf '\nWhen `result%s` is written, tell them to close this session so the update can go on.\n' "$ext"
}

talk() {
  local i=$1 agents=() names=() line n options=() agent name file ext="" dir
  while IFS= read -r line; do
    agents+=("${line%%:*}")
    names+=("${line#*:}")
  done < <(found_agents)
  say "  Which coding agent should merge them? (only tools you have installed are listed)"
  for ((n = 0; n < ${#agents[@]}; n++)); do options+=("$((n + 1))" "${names[n]}"); done
  choose 1 "${options[@]}" || return 1
  agent=${agents[choice - 1]} name=${names[choice - 1]}
  file=${row_path[i]##*/}
  [[ $file == ?*.* ]] && ext=.${file##*.}
  dir=$merges/${row_tool[i]}/${row_plugin[i]}/${row_path[i]}
  mkdir -p "$dir" || return 1
  if [[ -e $dir/result$ext ]]; then
    mv "$dir/result$ext" "$dir/result$ext.$run_generation" || return 1
  fi
  rm -f "$dir/original$ext"
  if [[ -n $(base_file "$i") ]]; then cp "$(base_file "$i")" "$dir/original$ext" || return 1; fi
  cp "$(disk_file "$i")" "$dir/yours$ext" || return 1
  cp "$(new_file "$i")" "$dir/theirs$ext" || return 1
  (cd "$dir" && merge_brief "$i" "$ext" >BRIEF.md) || return 1
  say "  Opening $name in $(tilde "$dir")/ with the old p3stack still installed."
  say "  It has $( [[ -f $dir/original$ext ]] && printf 'original%s, ' "$ext")yours$ext, theirs$ext, and a brief. It explains both changes, then writes result$ext."
  (cd "$dir" && launch_agent "$agent" "$(cat BRIEF.md)") <&3 || true
  if [[ -s $dir/result$ext ]] && LC_ALL=C grep -q '[^[:space:]]' "$dir/result$ext"; then
    row_action[i]=merged row_source[i]=$dir/result$ext
    say "  Got result$ext. The merged $(label "${row_path[i]}") goes in after the update, marked edited."
    return 0
  fi
  if [[ -f $dir/result$ext ]]; then
    say "  $name wrote an empty result$ext. Nothing changed yet."
    rm -f "$dir/result$ext"
  else
    say "  $name closed without writing result$ext. Nothing changed yet."
  fi
  return 1
}

decide() {
  local i=$1 kind members=() options=() j word picked no_keyboard=0
  class_policy "$i"
  kind=$question
  if [[ $kind == none ]]; then
    row_action[i]=keep
    return 0
  fi
  if [[ -z $(found_agents) ]]; then
    choices=${choices/,talk/}
    [[ $recommended == talk ]] && recommended=keep
  fi
  while IFS= read -r j; do members+=("$j"); done < <(group_rows "$i" "$kind")
  for word in ${choices//,/ }; do options+=("${word:0:1}" "$(choice_label "$word")"); done
  while :; do
    picked=""
    if ((attended)) && ask_about "$i" "$kind" "${members[@]}" && choose "${recommended:0:1}" "${options[@]}"; then
      for word in ${choices//,/ }; do
        if [[ ${word:0:1} == "$choice" ]]; then picked=$word; fi
      done
    fi
    if [[ -z $picked ]]; then
      picked=$unattended
      no_keyboard=1
    fi
    if [[ $picked == talk ]]; then
      talk "$i" && return 0
      continue
    fi
    for j in "${members[@]}"; do row_action[j]=$picked; done
    if [[ $picked == keep && $kind == skill ]]; then make_personal_skill "$i" "${members[@]}"; fi
    if ((no_keyboard)) && [[ ${row_action[i]} == "$picked" || ${row_action[i]} == moved ]]; then unattended_note "$i"; fi
    return 0
  done
}

offer_copy() {
  local i=$1 j targets=() names=() entry declined others verb
  class_policy "$i"
  edited "$i" && [[ $copy_offer == yes ]] || return 0
  [[ ${row_action[i]} == keep || ${row_action[i]} == merged ]] || return 0
  for ((j = 0; j < ${#row_tool[@]}; j++)); do
    [[ ${row_tool[j]} != "${row_tool[i]}" && ${row_plugin[j]} == "${row_plugin[i]}" && ${row_path[j]} == "${row_path[i]}" ]] || continue
    [[ ${row_class[j]} == untouched && -z ${row_action[j]} ]] || continue
    targets+=("$j")
    names+=("$(tool_label "${row_tool[j]}")")
  done
  ((${#targets[@]} && attended)) || return 0
  declined=$records/${row_tool[i]}/declined
  entry="$(file_hash "${row_source[i]}")  ${row_plugin[i]}/${row_path[i]}"
  if grep -qxF "$entry" "$declined" 2>/dev/null; then return 0; fi
  others=$(and_list "${names[@]}")
  verb=has
  ((${#targets[@]} == 1)) || verb=have
  say ""
  if [[ $question == none && $copy_offer == yes ]]; then
    say "  $(label "${row_path[i]}"): p3stack didn't change it, so your version in $(tool_label "${row_tool[i]}") stays."
  fi
  say "  $others still $verb p3stack's $(label "${row_path[i]}"). Copy your version there too?"
  choose y y "Yes, copy it to $others" n "No, leave $others as it is" || return 0
  if [[ $choice == y ]]; then
    for j in "${targets[@]}"; do
      row_action[j]=copy row_source[j]=${row_source[i]} row_from[j]=${row_tool[i]} row_base[j]=${row_base[i]}
      [[ ${row_action[i]} != merged ]] || row_base[j]=$new_commit
    done
  else
    mkdir -p "$records/${row_tool[i]}"
    printf '%s\n' "$entry" >>"$declined"
    say "  Left $others alone. You won't be asked again for this edit."
  fi
}

edits_decide() {
  local i j tool found root count=${#row_tool[@]}
  for ((i = 0; i < count; i++)); do
    [[ ${row_class[i]} == edited-added ]] || continue
    for tool in $scanned_tools; do
      found=0
      for ((j = 0; j < ${#row_tool[@]}; j++)); do
        if [[ ${row_tool[j]} == "$tool" && ${row_plugin[j]} == "${row_plugin[i]}" && ${row_path[j]} == "${row_path[i]}" ]]; then found=1; break; fi
      done
      ((found == 0)) || continue
      root=$("${tool}_root" "${row_plugin[i]}")
      add_row "$tool" "${row_plugin[i]}" "${row_path[i]}" untouched "$root" added
    done
  done
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    if edited "$i" && [[ -z ${row_action[i]} ]]; then decide "$i"; fi
  done
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    offer_copy "$i"
  done
}

scanned_tools=""

edits_prepare() {
  local tool plugin base bases=() tools=() olds=() n installed=0
  work=$(mktemp -d "${TMPDIR:-/tmp}/p3stack.XXXXXX")
  release_fetch
  run_generation=$(date -u +%Y%m%dT%H%M%SZ)-${new_commit:0:7}-${work##*.}
  for tool; do
    installed=0
    for plugin in "${plugins[@]}"; do
      if "${tool}_root" "$plugin" >/dev/null; then installed=1; fi
    done
    if ((installed)) || [[ $action == update ]]; then tools+=("$tool"); fi
  done
  ((${#tools[@]})) || return 0
  for tool in "${tools[@]}"; do
    base=$(installed_base "$tool" || true)
    bases+=("$base")
    [[ -z $base ]] || olds+=("${base:0:7}")
  done
  say ""
  if [[ $(printf '%s\n' ${olds[@]+"${olds[@]}"} | sort -u | grep -c .) == 1 ]]; then
    say "p3stack ${olds[0]} → ${new_commit:0:7}"
  else
    say "p3stack ${new_commit:0:7}"
  fi
  say "Fetched the new release. Checking your installed copies before installing."
  open_keyboard
  for ((n = 0; n < ${#tools[@]}; n++)); do
    edits_scan "${tools[n]}" "${bases[n]}"
    scanned_tools+=" ${tools[n]} "
  done
  edits_decide
}

report_row() {
  local i=$1 name
  name=$(label "${row_path[i]}")
  class_policy "$i"
  [[ $report_style != group ]] || return 0
  case ${row_action[i]} in
    moved) say "  $moved_note" ;;
    keep) say "  $keep_note" ;;
    merged) say "  Installed the merged $name, marked edited." ;;
    copy) say "  Copied your $name from $(tool_label "${row_from[i]}"), marked edited." ;;
    accept) say "  $accept_note" ;;
  esac
}


journal_write() {
  local tool=$1 staging=$pending/.prepare-$1 i source
  mkdir -p "$pending"
  mkdir "$staging"
  cp -R "$new_release" "$staging/tree"
  printf '%s\n' "$new_commit" >"$staging/commit"
  : >"$staging/rows"
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ ${row_tool[i]} == "$tool" ]] || continue
    [[ ${row_class[i]} != deleted ]] || row_action[i]=keep
    [[ -n ${row_action[i]} ]] || continue
    source=${row_source[i]}
    if [[ ${row_action[i]} == merged ]]; then
      mkdir -p "$staging/sources"
      cp -p "$source" "$staging/sources/$i"
      [[ $(sha256 <"$source") == "$(sha256 <"$staging/sources/$i")" ]] || return 1
      source=$pending/$tool/sources/$i
    fi
    printf '%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n' \
      "${row_tool[i]}" "${row_plugin[i]}" "${row_path[i]}" "${row_class[i]}" "${row_action[i]}" \
      "$source" "${row_base[i]}" "${row_from[i]}" "${row_backup[i]}" >>"$staging/rows"
  done
  mv "$staging" "$pending/$tool"
}

journal_load() {
  local tool plugin path class action source base from backup
  row_tool=() row_plugin=() row_path=() row_class=() row_root=() row_base=() row_action=() row_source=() row_from=() row_backup=()
  while IFS=$'\034' read -r tool plugin path class action source base from backup; do
    add_row "$tool" "$plugin" "$path" "$class" "" "$base"
    i=$((${#row_tool[@]} - 1))
    row_action[i]=$action row_source[i]=$source row_from[i]=$from row_backup[i]=$backup
  done <"$1/rows"
}

edits_apply() {
  local tool=$1 journal=$pending/$1 commit tree i root plugin dest skill reported=" " had_record
  local kept=() accepted=() bases=$journal/bases.next
  had_record=$(record_commit "$tool" || true)
  commit=$(cat "$journal/commit") tree=$journal/tree
  : >"$bases"
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ ${row_tool[i]} == "$tool" && -n ${row_action[i]} ]] || continue
    root=$("${tool}_root" "${row_plugin[i]}") || { warn "couldn't resolve ${row_plugin[i]} after update; pending edits remain in $journal"; return 1; }
    dest=$root/${row_path[i]}
    skill=$(skill_of "${row_path[i]}" || true)
    case ${row_action[i]} in
      keep|merged|copy)
        if [[ ${row_class[i]} != deleted ]]; then
          mkdir -p "$(dirname "$dest")"
          cp -p "${row_source[i]}" "$dest"
          [[ $(sha256 <"$dest") == "$(sha256 <"${row_source[i]}")" ]] || return 1
          stamp "$dest"
          if [[ ${row_action[i]} == copy && -n ${row_base[i]} ]] ||
             [[ ${row_action[i]} == keep && ( ${row_class[i]} == edited-conflict || ${row_class[i]} == edited-file-removed || ${row_class[i]} == edited-added ) ]]; then
            printf '%s\t%s\n' "${row_plugin[i]}/${row_path[i]}" "${row_base[i]}" >>"$bases"
          fi
        elif [[ -f $tree/${row_plugin[i]}/${row_path[i]} ]]; then
          mkdir -p "$(dirname "$dest")"
          cp -p "$tree/${row_plugin[i]}/${row_path[i]}" "$dest"
        fi
        ;;
      accept)
        if [[ -f $tree/${row_plugin[i]}/${row_path[i]} ]]; then
          mkdir -p "$(dirname "$dest")"
          cp -p "$tree/${row_plugin[i]}/${row_path[i]}" "$dest"
        else
          rm -f "$dest"
        fi
        ;;
      moved) rm -rf "$root/skills/$skill" ;;
    esac
    class_policy "$i"
    if [[ $report_style == group ]]; then
      if [[ ${row_action[i]} == keep ]]; then kept+=("$(label "${row_path[i]}")"); else accepted+=("$i"); fi
    elif [[ ${row_action[i]} != moved || $reported != *" $skill "* ]]; then
      report_row "$i"
      reported+="$skill "
    fi
  done
  if ((${#kept[@]})); then say "  Kept $(and_list "${kept[@]}"), marked edited."; fi
  if ((${#accepted[@]})); then say "  Installed p3stack's versions. Old copies saved in $(tilde "$edits_home/$tool")/."; fi
  record_write "$tool" "$commit" "$tree" "$bases"
  rm -rf "$journal"
  if [[ -z $had_record && $scanned_tools == *" $tool "* ]]; then say "  Saved a record for next time."; fi
}

recover_updates() {
  local dir tool
  for dir in "$pending"/*; do
    [[ -d $dir && -f $dir/rows ]] || continue
    tool=${dir##*/}
    [[ " $tool_names " == *" $tool "* ]] || { warn "unknown pending tool $tool"; return 1; }
    journal_load "$dir"
    edits_apply "$tool"
    say "Finished an interrupted update in $(tool_label "$tool"). Your edits are restored."
  done
  row_tool=() row_plugin=() row_path=() row_class=() row_root=() row_base=() row_action=() row_source=() row_from=() row_backup=()
}

cleanup() {
  [[ -z $work ]] || rm -rf "$work"
  if ((locked)); then rm -f "$p3stack_home/lock/pid"; rmdir "$p3stack_home/lock"; fi
}

lock_owner_alive() {
  local pid
  pid=$(cat "$1/pid" 2>/dev/null || true)
  if [[ -n $pid && $pid != *[!0-9]* ]]; then kill -0 "$pid" 2>/dev/null; return; fi
  [[ -z $(find "$1" -prune -mmin +1) ]]
}

update_lock() {
  local lock=$p3stack_home/lock pid
  mkdir -p "$p3stack_home"
  if ! mkdir "$lock" 2>/dev/null; then
    exec 9<"$lock"
    if lock_owner_alive "$lock"; then warn "another p3stack command is running or starting"; return 1; fi
    if ! mkdir "$lock/reclaim" 2>/dev/null; then
      if lock_owner_alive "$lock/reclaim"; then warn "another p3stack command is reclaiming its lock"; return 1; fi
      rm -f "$lock/reclaim/pid"
      rmdir "$lock/reclaim" || return 1
      mkdir "$lock/reclaim" || return 1
    fi
    printf '%s\n' "$$" >"$lock/reclaim/pid"
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ ! $lock -ef /dev/fd/9 ]] || { [[ -n $pid && $pid != *[!0-9]* ]] && kill -0 "$pid" 2>/dev/null; }; then
      rm "$lock/reclaim/pid"
      rmdir "$lock/reclaim"
      warn "another p3stack command acquired the lock"
      return 1
    fi
    rm -f "$lock/pid" "$lock/reclaim/pid"
    rmdir "$lock/reclaim"
    rmdir "$lock" || return 1
    exec 9<&-
    mkdir "$lock" || { warn "another p3stack command acquired the lock"; return 1; }
  fi
  locked=1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  printf '%s\n' "$$" >"$lock/pid"
  # Unpublished journals cannot have reached a tool install.
  rm -rf "$pending"/.prepare-*
}

finish() {
  local action=$1 done_tools=$2 failed=$3
  heading "Next"
  if [[ $action == uninstall ]]; then
    say "p3stack is removed from:${done_tools:- nothing}. Your model choices stay in ~/.p3stack/."
  else
    say "Start or resume a T3 Code thread to load p3stack."
    [[ $action == install ]] && say "Then run /setup-pstack once in any T3 Code thread to pick models."
    [[ $done_tools == *cursor* ]] && say "Cursor doesn't run the startup hook, so type /poteto-mode at the start of each task there."
    if [[ $done_tools == *opencode* ]]; then
      say "For OpenCode, use Refresh provider status in T3 Code's Settings > Providers. OpenCode can keep its old config for about 30 seconds, so refresh again if p3stack's skills don't show."
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
    say "Run codex in a terminal, type /hooks, and trust the p3stack SessionStart hook. Codex skips hooks you haven't trusted, and T3 Code can't ask you."
  fi
  return 0
}

main() {
  local action=install
  case ${1:-install} in
    install|update|uninstall) action=${1:-install} ;;
    detect)
      [[ $# -le 1 ]] || { warn "detect takes no tools"; exit 2; }
      for tool in $tool_names; do "${tool}_found" && say "$tool"; done
      exit 0
      ;;
    -h|--help|help) usage; exit 0 ;;
    *) warn "unknown argument: $1"; usage >&2; exit 2 ;;
  esac
  shift || true
  for tool in "$@"; do
    [[ " $tool_names " == *" $tool "* ]] || { warn "unknown tool: $tool"; usage >&2; exit 2; }
  done
  local wanted=${*:-$tool_names}

  local done_tools="" failed="" skipped="" present=""
  for tool in $wanted; do
    if "${tool}_found"; then present="$present $tool"; else skipped="$skipped $tool"; fi
  done
  update_lock
  recover_updates
  if [[ $action != uninstall && -n $present ]]; then
    edits_prepare $present
    for tool in $present; do journal_write "$tool"; done
  fi
  for tool in $present; do
    heading "$action p3stack in $tool"
    if "${tool}_${action}"; then
      done_tools="$done_tools $tool"
      if [[ $action == uninstall ]]; then rm -rf "${records:?}/$tool"; else edits_apply "$tool"; fi
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
    if [[ $# -gt 0 ]]; then
      say "None of the tools you named was found on this machine:$skipped."
    else
      say "None of Claude Code, Codex, Cursor, or OpenCode was found on this machine."
    fi
    exit 1
  fi
  finish "$action" "$done_tools" "$failed"
  [[ -z $failed ]]
}

main "$@"
