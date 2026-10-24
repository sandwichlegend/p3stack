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
  local list pattern="\"id\": *\"$1@$marketplace\"[^}]*\"installPath\": *\"([^\"]*)\""
  list=$(claude plugin list --json </dev/null 2>/dev/null) || return 1
  list=${list//$'\n'/ }
  [[ $list =~ $pattern && -d ${BASH_REMATCH[1]} ]] && printf '%s' "${BASH_REMATCH[1]}"
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
  local package lock
  package=$(opencode_package) || return 1
  lock=$(cat "$(dirname "$package")/.package-lock.json" 2>/dev/null) || return 1
  [[ $lock =~ \#([0-9a-f]{40}) ]] && printf '%s' "${BASH_REMATCH[1]}"
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

tilde() { printf '%s' "${1/#$HOME/\~}"; }
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
  local tool=$1 commit=$2 tree=$3 plugin
  mkdir -p "$records/$tool"
  for plugin in "${plugins[@]}"; do
    cp "$tree/$plugin.sha256" "$records/$tool/$plugin.sha256"
  done
  printf '%s\n' "$commit" >"$records/$tool/commit"
}

commit_named_by_install="claude opencode"

installed_base() {
  if [[ " $commit_named_by_install " == *" $1 "* ]] && "${1}_commit"; then return 0; fi
  record_commit "$1"
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
    END { for (path in seen) print path "\037" base[path] "\037" new[path] }' "$1" "$2" | LC_ALL=C sort
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

edit_rules='
class            one_question_per  choices           recommended  unattended  offer_copy
edited-kept      none              -                 -            keep        yes
edited-conflict  file              keep,accept,talk  talk         keep        yes
edited-removed   skill             keep,accept       accept       keep        no
unknown-base     tool              keep,accept       accept       accept      no
'

rule() {
  awk -v class="$1" -v field="$2" '
    NR == 2 { for (i = 1; i <= NF; i++) column[$i] = i }
    $1 == class { print $column[field] }' <<<"$edit_rules"
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
  local path=$1
  [[ $path =~ ^skills/([^/]+)/SKILL\.md$ ]] && { say "${BASH_REMATCH[1]}"; return; }
  say "${path#skills/}"
}

skill_of() { [[ $1 =~ ^skills/([^/]+)/ ]] && say "${BASH_REMATCH[1]}"; }

has_frontmatter() { [[ -f $1 && $(head -1 "$1" | tr -d '\r') == --- ]]; }

marked() { has_frontmatter "$1" && awk 'NR > 1 && /^---\r?$/ { exit 1 } /^edited: true\r?$/ { found = 1; exit } END { exit !found }' "$1"; }

stamp() {
  has_frontmatter "$1" && ! marked "$1" || return 0
  local file=$1 tmp
  tmp=$(mktemp)
  awk 'NR > 1 && !done && /^---\r?$/ { print "edited: true"; done = 1 } { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
  rm -f "$tmp"
}

normalized_diff() {
  [[ -f $1 && -f $2 ]] || return 0
  drop_non_edits "$1" >"$work/from"
  drop_non_edits "$2" >"$work/to"
  diff "$work/from" "$work/to" || true
}

changed_lines() {
  normalized_diff "$1" "$2" | awk '/^>/ { added++ } /^</ { removed++ } END { n = added > removed ? added : removed; if (n == 1) print "1 line"; else if (n) print n " lines" }'
}

change_summary() {
  local count where
  count=$(changed_lines "$1" "$2")
  [[ -n $count ]] || return 0
  where=$(normalized_diff "$1" "$2" | awk -v from="$work/from" '
    /^[0-9]/ { first = $0 + 0; exit }
    END {
      while ((getline line < from) > 0 && ++i <= first) {
        if (line ~ /^#+ /) near = "in \"" line "\""
        else if (match(line, /(function|def|class) [A-Za-z0-9_]+/)) near = "near \"" substr(line, RSTART, RLENGTH) "\""
      }
      print near
    }')
  say "$count${where:+ $where}"
}

row_tool=() row_plugin=() row_path=() row_class=() row_root=() row_base=() row_action=() row_source=() row_from=()

add_row() {
  local n=${#row_tool[@]}
  row_tool[n]=$1 row_plugin[n]=$2 row_path[n]=$3 row_class[n]=$4 row_root[n]=$5 row_base[n]=$6
  row_action[n]="" row_source[n]="" row_from[n]=""
}

edited() { [[ ${row_class[$1]} == edited-* || ${row_class[$1]} == unknown-base ]]; }

base_file() {
  local tree
  [[ -n ${row_base[$1]} ]] && tree=$(release_tree "${row_base[$1]}") && [[ -f $tree/${row_plugin[$1]}/${row_path[$1]} ]] &&
    printf '%s' "$tree/${row_plugin[$1]}/${row_path[$1]}"
}

new_file() { printf '%s' "$new_release/${row_plugin[$1]}/${row_path[$1]}"; }
disk_file() { printf '%s' "${row_root[$1]}/${row_path[$1]}"; }
backup_file() { printf '%s' "$edits_home/${row_tool[$1]}/${row_plugin[$1]}/${row_path[$1]}"; }

noun() {
  local count=$1 word=skill i
  shift
  for i in "$@"; do
    [[ ${row_path[i]} == skills/*/SKILL.md ]] || word=file
  done
  ((count == 1)) && say "$word" || say "${word}s"
}

edits_scan() {
  local tool=$1 base=$2 known=unknown plugin plugin_base listing root path record new disk first=${#row_tool[@]} i reason count
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
  for plugin in "${plugins[@]}"; do
    root=$("${tool}_root" "$plugin") || continue
    listing=$work/base-$tool-$plugin
    : >"$listing"
    [[ $known == unknown ]] || base_hashes "$tool" "$plugin" "$base" >"$listing"
    if [[ -s $listing ]]; then plugin_base=known; else plugin_base=unknown; fi
    while IFS=$'\037' read -r path record new; do
      [[ -n $path ]] || continue
      [[ $plugin_base == known || -n $new ]] || continue
      disk=""
      [[ -f $root/$path ]] && disk=$(file_hash "$root/$path")
      [[ -n $disk ]] || continue
      add_row "$tool" "$plugin" "$path" "$(classify "$plugin_base" "$record" "$disk" "$new")" "$root" "$base"
    done < <(pair_hashes "$listing" "$new_release/$plugin.sha256")
  done
  for ((i = first; i < ${#row_tool[@]}; i++)); do
    edited "$i" || continue
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
      stamp "$(disk_file "$i")"
    done
    ((${#changed[@]} == 1)) && say "  Marked it edited." || say "  Marked them edited."
  fi
  if ((${#unknown[@]})); then
    for i in "${unknown[@]}"; do labels+=("$(label "${row_path[i]}")"); done
    if ((${#unknown[@]} == 1)); then reason=differs; else reason=differ; fi
    say "  ${#unknown[@]} $(noun ${#unknown[@]} "${unknown[@]}") $reason from the new release: $(comma_list "${labels[@]}")"
    say "  They may be your edits, or just the older version."
  elif ((${#found[@]})); then
    say "  ${#found[@]} $(noun ${#found[@]} "${found[@]}") you edited:"
    for i in "${found[@]}"; do
      case ${row_class[i]} in
        edited-kept) reason="p3stack didn't change it in this release" ;;
        edited-conflict) reason="p3stack also changed it" ;;
        edited-removed) reason="p3stack removed it in this release" ;;
      esac
      printf '    %-13s %s\n' "$(label "${row_path[i]}")" "$reason"
    done
  else
    say "  No edited files."
  fi
  for i in ${found[@]+"${found[@]}"}; do
    mkdir -p "$(dirname "$(backup_file "$i")")"
    cp "$(disk_file "$i")" "$(backup_file "$i")"
    row_source[i]=$(backup_file "$i")
  done
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
  local i=$1 kind=$2 tool labels=() j
  shift 2
  tool=$(tool_label "${row_tool[i]}")
  say ""
  case $kind in
    file)
      say "  $(label "${row_path[i]}") in $tool: you and p3stack both changed this $(noun 1 "$i")."
      summary_line Yours "$(change_summary "$(base_file "$i")" "$(disk_file "$i")")"
      summary_line p3stack "$(change_summary "$(base_file "$i")" "$(new_file "$i")")"
      ;;
    skill) say "  $(skill_of "${row_path[i]}") in $tool: you edited this skill, and the new release no longer has it." ;;
    tool)
      for j; do labels+=("$(label "${row_path[j]}")"); done
      say "  $(and_list "${labels[@]}") in $tool:"
      ;;
  esac
}

unattended_note() {
  local i=$1 tool skill
  tool=$(tool_label "${row_tool[i]}")
  skill=$(skill_of "${row_path[i]}")
  case ${row_class[i]} in
    edited-conflict)
      warn "No one is at the keyboard to choose, so your version of $(label "${row_path[i]}") in $tool was kept."
      warn "p3stack's change to it was skipped. Run \"p3stack update\" in a terminal to choose."
      ;;
    edited-removed) warn "No one is at the keyboard to choose, so your version of $skill in $tool was kept in $(tilde "$HOME/.agents/skills/$skill")." ;;
    unknown-base) warn "No one is at the keyboard to choose, so p3stack's versions go into $tool. Old copies are saved in $(tilde "$edits_home/${row_tool[i]}")/." ;;
  esac
}

make_personal_skill() {
  local i=$1 skill dest link j
  shift
  skill=$(skill_of "${row_path[i]}")
  dest=$HOME/.agents/skills/$skill
  if [[ -e $dest || -L $dest ]]; then
    warn "$(tilde "$dest") already exists, so $skill comes out of $(tool_label "${row_tool[i]}") and your version is saved in $(tilde "$edits_home/${row_tool[i]}/${row_plugin[i]}/skills/$skill")/."
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
  dir=$merges/$(label "${row_path[i]}" | tr / -)
  rm -rf "$dir"
  mkdir -p "$dir"
  if [[ -n $(base_file "$i") ]]; then cp "$(base_file "$i")" "$dir/original$ext"; fi
  cp "$(disk_file "$i")" "$dir/yours$ext"
  cp "$(new_file "$i")" "$dir/theirs$ext"
  (cd "$dir" && merge_brief "$i" "$ext" >BRIEF.md)
  say "  Opening $name in $(tilde "$dir")/ with the old p3stack still installed."
  say "  It has $( [[ -f $dir/original$ext ]] && printf 'original%s, ' "$ext")yours$ext, theirs$ext, and a brief. It explains both changes, then writes result$ext."
  (cd "$dir" && launch_agent "$agent" "$(cat BRIEF.md)") <&3 || true
  if [[ -f $dir/result$ext ]]; then
    row_action[i]=merged row_source[i]=$dir/result$ext
    say "  Got result$ext. The merged $(label "${row_path[i]}") goes in after the update, marked edited."
    return 0
  fi
  say "  $name closed without writing result$ext. Nothing changed yet."
  return 1
}

decide() {
  local i=$1 class=${row_class[$1]} kind choices recommended members=() options=() j word picked
  kind=$(rule "$class" one_question_per)
  if [[ $kind == none ]]; then
    row_action[i]=keep
    return 0
  fi
  if [[ $kind == skill && -z $(skill_of "${row_path[i]}") ]]; then
    row_action[i]=accept
    return 0
  fi
  choices=$(rule "$class" choices) recommended=$(rule "$class" recommended)
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
      picked=$(rule "$class" unattended)
      unattended_note "$i"
    fi
    if [[ $picked == talk ]]; then
      talk "$i" && return 0
      continue
    fi
    for j in "${members[@]}"; do row_action[j]=$picked; done
    if [[ $picked == keep && $kind == skill ]]; then make_personal_skill "$i" "${members[@]}"; fi
    return 0
  done
}

offer_copy() {
  local i=$1 j targets=() names=() entry declined others verb
  edited "$i" && [[ $(rule "${row_class[i]}" offer_copy) == yes ]] || return 0
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
  if [[ ${row_class[i]} == edited-kept ]]; then
    say "  $(label "${row_path[i]}"): p3stack didn't change it, so your version in $(tool_label "${row_tool[i]}") stays."
  fi
  say "  $others still $verb p3stack's $(label "${row_path[i]}"). Copy your version there too?"
  choose y y "Yes, copy it to $others" n "No, leave $others as it is" || return 0
  if [[ $choice == y ]]; then
    for j in "${targets[@]}"; do
      row_action[j]=copy row_source[j]=${row_source[i]} row_from[j]=${row_tool[i]}
    done
  else
    mkdir -p "$records/${row_tool[i]}"
    printf '%s\n' "$entry" >>"$declined"
    say "  Left $others alone. You won't be asked again for this edit."
  fi
}

edits_decide() {
  local i
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    if edited "$i" && [[ -z ${row_action[i]} ]]; then decide "$i"; fi
  done
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    offer_copy "$i"
  done
}

scanned_tools=""

edits_prepare() {
  local tool plugin base bases=() tools=() olds=() n
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  release_fetch || return 1
  for tool; do
    for plugin in "${plugins[@]}"; do
      if "${tool}_root" "$plugin" >/dev/null; then
        tools+=("$tool")
        break
      fi
    done
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
  case ${row_class[i]}/${row_action[i]} in
    unknown-base/*) ;;
    edited-removed/moved) say "  Moved your $(skill_of "${row_path[i]}") to $(tilde "$HOME/.agents/skills/$(skill_of "${row_path[i]}")") and linked it into each tool. p3stack won't update it any more." ;;
    edited-removed/accept) say "  Removed $name. Your version is saved in $(tilde "$(backup_file "$i")")" ;;
    edited-conflict/keep)
      say "  Kept your version of $name."
      say "  p3stack's change was skipped. You'll be asked again if it changes in a later release."
      ;;
    */keep) say "  Kept your version of $name." ;;
    */merged) say "  Installed the merged $name, marked edited." ;;
    */copy) say "  Copied your $name from $(tool_label "${row_from[i]}"), marked edited." ;;
    */accept)
      say "  Installed p3stack's $name."
      say "  Your version is saved in $(tilde "$(backup_file "$i")")"
      ;;
  esac
}

edits_apply() {
  local tool=$1 commit tree i root roots="" plugin dest skill kept=() accepted=() reported=" " had_record
  had_record=$(record_commit "$tool" || true)
  if ! commit=$("${tool}_commit") || ! tree=$(release_tree "$commit"); then
    commit=$new_commit tree=$new_release
  fi
  for plugin in "${plugins[@]}"; do roots+="$plugin=$("${tool}_root" "$plugin" || true)"$'\n'; done
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ ${row_tool[i]} == "$tool" && -n ${row_action[i]} ]] || continue
    root=$(awk -v plugin="${row_plugin[i]}=" 'index($0, plugin) == 1 { print substr($0, length(plugin) + 1) }' <<<"$roots")
    if [[ -z $root ]]; then
      warn "couldn't find ${row_plugin[i]} in $(tool_label "$tool") after the update, so $(label "${row_path[i]}") wasn't put back. Your version is in $(tilde "$(backup_file "$i")")"
      continue
    fi
    dest=$root/${row_path[i]}
    skill=$(skill_of "${row_path[i]}")
    case ${row_action[i]} in
      keep|merged|copy)
        mkdir -p "$(dirname "$dest")"
        cp "${row_source[i]}" "$dest"
        stamp "$dest"
        ;;
      accept)
        if [[ -f $tree/${row_plugin[i]}/${row_path[i]} ]]; then
          cp "$tree/${row_plugin[i]}/${row_path[i]}" "$dest"
        else
          rm -f "$dest"
          if [[ -n $skill && ! -d $tree/${row_plugin[i]}/skills/$skill ]]; then rm -rf "$root/skills/$skill"; fi
        fi
        ;;
      moved) rm -rf "$root/skills/$skill" ;;
    esac
    if [[ ${row_class[i]} == unknown-base ]]; then
      if [[ ${row_action[i]} == keep ]]; then kept+=("$(label "${row_path[i]}")"); else accepted+=("$i"); fi
    elif [[ ${row_class[i]} != edited-removed || $reported != *" $skill "* ]]; then
      report_row "$i"
      reported+="$skill "
    fi
  done
  if ((${#kept[@]})); then say "  Kept $(and_list "${kept[@]}"), marked edited."; fi
  if ((${#accepted[@]})); then say "  Installed p3stack's versions. Old copies saved in $(tilde "$edits_home/$tool")/."; fi
  record_write "$tool" "$commit" "$tree"
  if [[ -z $had_record && $scanned_tools == *" $tool "* ]]; then say "  Saved a record for next time."; fi
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
  if [[ $action != uninstall && -n $present ]] && ! edits_prepare $present; then
    warn "couldn't fetch p3stack from $repo_url, so nothing was installed"
    exit 1
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
