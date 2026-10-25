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
present=""
stopped=" "
reinstall=" "
scanned_tools=" "
gen_stamp=""
new_release=""
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
  list=$(query claude plugin list --json) || return 1
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
  [[ -n $root && ( -d $root || ${2:-} == allow-missing ) ]] && printf '%s' "$root"
}

# Claude Code names each install folder by the first 12 characters of its commit.
claude_commit() {
  local root version
  root=$(claude_root "${1:-p3stack}") || return 1
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
    release_commit "$commit" >/dev/null || return 1
    rm -rf "$dir.part"
    mkdir -p "$dir.part" || return 1
    for plugin in "${plugins[@]}"; do
      : >"$dir.part/$plugin.sha256" || return 1
      git -C "$release_clone" cat-file -e "$commit:$(subtree "$plugin")" 2>/dev/null || continue
      mkdir -p "$dir.part/$plugin" || return 1
      git -C "$release_clone" archive "$commit" "$(subtree "$plugin")" | tar -x -C "$dir.part/$plugin" --strip-components=1 || return 1
      hash_tree "$dir.part/$plugin" >"$dir.part/$plugin.sha256" || return 1
    done
    mv "$dir.part" "$dir" || return 1
  fi
  printf '%s' "$dir"
}

release_hash() { awk -v path="$3" 'substr($0, 67) == path { print substr($0, 1, 64) }' "$1/$2.sha256" 2>/dev/null || true; }

record_commit() { cat "$records/$1/$2.commit" 2>/dev/null; }

has_record() {
  local plugin
  for plugin in "${plugins[@]}"; do
    [[ ! -f $records/$1/$plugin.commit ]] || return 0
  done
  return 1
}

record_write() {
  local tool=$1 plugin=$2 commit=$3 tree=$4 dir=$records/$1
  mkdir -p "$dir" &&
    cp "$tree/$plugin.sha256" "$dir/.$plugin.sha256" && mv "$dir/.$plugin.sha256" "$dir/$plugin.sha256" &&
    printf '%s\n' "$commit" >"$dir/.$plugin.commit" && mv "$dir/.$plugin.commit" "$dir/$plugin.commit"
}

# A tool that is merely present gets a plain install. Only plugins a tool already has are scanned for edits.
plugin_installed() {
  local tool=$1 plugin=$2 listing
  case $tool in
    claude)
      listing=$(query claude plugin list --json) || return 2
      [[ $listing == *\"$plugin@$marketplace\"* ]]
      ;;
    codex)
      listing=$(query codex plugin list) || return 2
      awk -v name="$plugin@$marketplace" '$1 == name && $2 ~ /^installed/ { found = 1 } END { exit !found }' <<<"$listing"
      ;;
    cursor) [[ -d $cursor_local/$plugin ]] ;;
    opencode)
      listing=$(query opencode plugin list) || return 2
      awk -v source="$opencode_spec" '$1 == "p3stack" && $3 == source { found = 1 } END { exit !found }' <<<"$listing"
      ;;
  esac
}

listing_failed() {
  warn "couldn't list p3stack in $(tool_label "$1"), so nothing was installed there. Check the failed plugin listing command above and run p3stack update again."
  stopped+="$1 "
}

leftover_roots() {
  local tool=$1 plugin=$2 dir
  case $tool in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/$marketplace/$plugin"/* ;;
    codex) printf '%s\n' "$codex_home/plugins/cache/$marketplace/$plugin"/* ;;
    opencode)
      for dir in "${XDG_CACHE_HOME:-$HOME/.cache}"/opencode/npm/git-p3stack-*/*/node_modules/p3stack; do
        printf '%s\n' "$dir/$(subtree "$plugin")"
      done ;;
  esac
}

leftover_commit() {
  local tool=$1 plugin=$2 root=$3 lock pattern='#([0-9a-f]{40})'
  case $tool in
    claude) release_commit "${root##*/}" ;;
    codex) record_commit "$tool" "$plugin" ;;
    opencode)
      lock=$(cat "$(dirname "$(dirname "$root")")/.package-lock.json" 2>/dev/null) || return 1
      [[ $lock =~ $pattern ]] && release_commit "${BASH_REMATCH[1]}" ;;
  esac
}

prepare_installation() {
  local tool=$1 plugin status root path expected actual leftover commit tree version saved backed
  for plugin in "${plugins[@]}"; do
    status=0
    plugin_installed "$tool" "$plugin" || status=$?
    ((status)) || continue
    if ((status == 2)); then listing_failed "$tool"; return 0; fi
    leftover=0 backed=0
    [[ ! -f $records/$tool/$plugin.commit ]] || leftover=1
    leftover_roots "$tool" "$plugin" >"$work/leftover-roots"
    while IFS= read -r root; do
      [[ -d $root ]] || continue
      leftover=1
      version=${root##*/}
      [[ $tool != opencode ]] || version=$(basename "$(dirname "$(dirname "$(dirname "$root")")")")
      tree=""
      commit=$(leftover_commit "$tool" "$plugin" "$root" || true)
      [[ -z $commit ]] || tree=$(release_tree "$commit" || true)
      if ! installed_paths "$tool" "$root" >"$work/leftover-paths"; then stopped+="$tool "; return 0; fi
      while IFS= read -r path; do
        expected=""
        [[ -z $tree ]] || expected=$(release_hash "$tree" "$plugin" "$path")
        actual=$(file_hash "$root/$path") || { stopped+="$tool "; return 0; }
        [[ -n $expected && $actual == "$expected" ]] && continue
        if ! saved=$(backup_copy "$tool" "$gen_stamp-leftover" "$plugin/$version/$path" "$root/$path"); then stopped+="$tool "; return 0; fi
        backed=1
        say "  Leftover $plugin/$version/$path is saved in $(tilde "$saved")."
      done <"$work/leftover-paths"
    done <"$work/leftover-roots"
    if ((leftover)); then
      rm -f "$records/$tool/$plugin.commit" "$records/$tool/$plugin.sha256" || return 1
      if [[ -f $records/$tool/bases ]]; then
        awk -F '\t' -v prefix="$plugin/" 'index($1, prefix) != 1' "$records/$tool/bases" >"$work/bases.leftover" &&
          mv "$work/bases.leftover" "$records/$tool/bases" || return 1
      fi
      if ((backed)); then saved="Changed leftover files were backed up above."
      else saved="No changed leftover files needed a backup."; fi
      say "  $plugin isn't installed in $(tool_label "$tool"). $saved Its record was dropped."
    fi
  done
}

has_p3stack() {
  local plugin status
  for plugin in "${plugins[@]}"; do
    status=0
    plugin_installed "$1" "$plugin" || status=$?
    case $status in 0) return 0 ;; 2) return 2 ;; esac
  done
  return 1
}

commit_named_by_install="claude opencode"

installed_base() {
  local base
  base=$(record_commit "$1" "$2" || true)
  if [[ -n $base ]]; then printf '%s' "$base"; return; fi
  if [[ $1 == cursor && -n $cursor_previous ]]; then printf '%s' "$cursor_previous"; return; fi
  [[ " $commit_named_by_install " == *" $1 "* ]] && "${1}_commit" "$2"
}

base_hashes() {
  local tool=$1 plugin=$2 base=$3 tree
  if tree=$(release_tree "$base"); then
    cat "$tree/$plugin.sha256"
  elif [[ $(record_commit "$tool" "$plugin") == "$base" && -f $records/$tool/$plugin.sha256 ]]; then
    cat "$records/$tool/$plugin.sha256"
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
    edited-kept-removed)
      scan_note="you kept it when p3stack removed it"
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
      keep_note="Kept your file ${row_path[i]}. p3stack no longer ships it, so it's yours now, and you won't be asked about it again."
      accept_note="Removed $name. Your version is saved in $backup"
      ;;
    edited-removed)
      question=skill choices=keep,accept recommended=accept
      scan_note="p3stack removed it in this release"
      question_note="$skill in $tool: you edited this skill, and the new release no longer has it."
      if [[ ${row_action[i]} == keep ]]; then
        unattended_message="No one is at the keyboard to choose, so your version of $skill in $tool was kept where it is."
      else
        unattended_message="No one is at the keyboard to choose, so your version of $skill in $tool was kept in $(tilde "$HOME/.agents/skills/$skill")."
      fi
      keep_note="Kept your $skill in $tool's p3stack folder, as your own files. p3stack won't ask about it again."
      accept_note="Removed $name. Your version is saved in $backup"
      moved_note="Moved your $skill to $(tilde "$HOME/.agents/skills/$skill")$(cat "$work/personal-$skill" 2>/dev/null || true). p3stack won't update it any more."
      ;;
    unknown-base)
      question=tool choices=keep,accept recommended=accept unattended=accept report_style=group
      unattended_message="No one is at the keyboard to choose, so p3stack's versions go into $tool. Old copies are saved in $(tilde "$edits_home/${row_tool[i]}")/."
      ;;
    deleted)
      keep_note="You deleted ${row_plugin[i]}/${row_path[i]}; p3stack's update put it back."
      ;;
  esac
  [[ ${row_kind[i]} != old ]] || scan_note+=" (from before the auto-update)"
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
  tmp=$(mktemp "${TMPDIR:-/tmp}/p3stack.XXXXXX") || return 1
  awk 'NR > 1 && !done && /^---\r?$/ { print "edited: true"; done = 1 } { print }' "$file" >"$tmp" && cat "$tmp" >"$file"
  local status=$?
  rm -f "$tmp"
  return $status
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

# One row per file per installed folder. kind is "old" for a folder a background auto-update left behind, "active" for the folder that replaced it.
row_fields="tool plugin path class root base action source from backup pre release apply partner kind replaces outcome"

rows_reset() {
  local field
  for field in $row_fields; do eval "row_$field=()"; done
}

rows_truncate() {
  local i field
  for ((i = ${#row_tool[@]} - 1; i >= $1; i--)); do
    for field in $row_fields; do unset "row_$field[$i]"; done
  done
}

rows_reset

add_row() {
  local n=${#row_tool[@]}
  row_tool[n]=$1 row_plugin[n]=$2 row_path[n]=$3 row_class[n]=$4 row_root[n]=$5 row_base[n]=$6 row_pre[n]=${7:-} row_kind[n]=${8:-}
  row_action[n]="" row_source[n]="" row_from[n]="" row_backup[n]="" row_release[n]="" row_apply[n]="" row_partner[n]="" row_replaces[n]="" row_outcome[n]=""
}

edited() { [[ ${row_class[$1]} == edited-* || ${row_class[$1]} == unknown-base ]]; }

base_file() {
  local tree
  [[ -n ${row_base[$1]} && ${row_base[$1]} != added ]] && tree=$(release_tree "${row_base[$1]}") && [[ -f $tree/${row_plugin[$1]}/${row_path[$1]} ]] &&
    printf '%s' "$tree/${row_plugin[$1]}/${row_path[$1]}"
}

new_file() { printf '%s' "$new_release/${row_plugin[$1]}/${row_path[$1]}"; }
disk_file() { printf '%s' "${row_root[$1]}/${row_path[$1]}"; }
yours_file() { if [[ -n ${row_source[$1]} ]]; then printf '%s' "${row_source[$1]}"; else disk_file "$1"; fi; }

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
  local tool=$1 root=$2 path part ignored
  find "$root" \( -type f -o -type l \) -print0 >"$work/disk-paths" || return 1
  while IFS= read -r -d '' path; do
    path=${path#"$root"/}
    ignored=0
    while IFS= read -r part; do
      [[ /$path/ != *"/$part/"* ]] || ignored=1
    done <<<"$ignored_paths"
    ((ignored == 0)) || continue
    if [[ $path == *$'\n'* || $path == *$'\t'* || $path == *$'\034'* ]]; then
      warn "A file in $(tilde "$root") has a tab, a line break, or a control character in its name: $(printf '%q' "$path"). The installer can't track it safely, so it left $(tool_label "$tool") alone. Rename the file or move it out of that folder, then run p3stack update again."
      return 1
    fi
    if [[ -L $root/$path ]]; then
      warn "$(tilde "$root/$path") is a symlink, so the installer can't tell whether it's yours, and it left $(tool_label "$tool") alone. Move the link out of $(tilde "$root"), or replace it with a copy of the file it points to, then run p3stack update again."
      return 1
    fi
    printf '%s\n' "$path"
  done <"$work/disk-paths"
}

# Content counts as update lag only if p3stack shipped it at the base commit or later; an older version on disk is a deliberate edit.
is_lag() {
  local plugin=$1 path=$2 hash=$3 from=$4 commit file
  file=$(subtree "$plugin")/$path
  {
    if [[ -n $from ]]; then
      printf '%s\n' "$from"
      git -C "$release_clone" rev-list "$from..$new_commit" -- "$file" 2>/dev/null || true
    else
      git -C "$release_clone" rev-list "$new_commit" -- "$file" 2>/dev/null || true
    fi
  } >"$work/lag-commits"
  while IFS= read -r commit; do
    git -C "$release_clone" show "$commit:$file" >"$work/history-file" 2>/dev/null || continue
    [[ $(file_hash "$work/history-file") != "$hash" ]] || return 0
  done <"$work/lag-commits"
  return 1
}

in_history() { [[ -n $(git -C "$release_clone" log -1 --format=%H "$new_commit" -- "$(subtree "$1")/$2" 2>/dev/null) ]]; }

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

same_file() { cmp -s "$1" "$2" && [[ $(ls -ld "$1" | cut -c1-10) == "$(ls -ld "$2" | cut -c1-10)" ]]; }

# Prints the new backup's path. Backups are never overwritten, so each call writes into a generation folder of its own.
save_copy() {
  local dest=$edits_home/$1/$2/$3 source=$4 collision=0
  while [[ -e $dest || -L $dest ]]; do
    if same_file "$dest" "$source"; then printf '%s' "$dest"; return 0; fi
    collision=$((collision + 1))
    dest=$edits_home/$1/$2-$collision/$3
  done
  if [[ -e $dest || -L $dest ]] || ! mkdir -p "$(dirname "$dest")" 2>/dev/null || ! cp -p "$source" "$dest"; then
    warn "backup failed for $(tilde "$source")"
    return 1
  fi
  if ! same_file "$source" "$dest"; then
    warn "backup verification failed for $(tilde "$source")"
    return 1
  fi
  printf '%s' "$dest"
}

backup_copy() {
  local tool=$1 generation=$2 path=$3 source=$4 candidate
  if [[ -d $edits_home/$tool ]]; then
    while IFS= read -r candidate; do
      [[ $candidate == *"/$path" ]] || continue
      if same_file "$candidate" "$source"; then printf '%s' "$candidate"; return 0; fi
    done < <(find "$edits_home/$tool" -type f)
  fi
  save_copy "$tool" "$generation" "$path" "$source"
}

backup_row() {
  local i=$1 dest generation=$scan_generation
  [[ ${row_kind[i]} != old ]] || generation+=-before-auto-update
  dest=$(backup_copy "${row_tool[i]}" "$generation" "${row_plugin[i]}/${row_path[i]}" "$(disk_file "$i")") || return 1
  row_backup[i]=$dest row_source[i]=$dest
}

scan_failed=0

scan_folder() {
  local tool=$1 plugin=$2 root=$3 base=$4 kind=$5 listing plugin_base path path_base override record new disk class skill old lag_from path_state
  listing=$work/base-$tool-$plugin-$kind
  : >"$listing"
  [[ -z $base ]] || base_hashes "$tool" "$plugin" "$base" >"$listing"
  if [[ -s $listing ]]; then plugin_base=known; else plugin_base=unknown; fi
  if ! installed_paths "$tool" "$root" >"$work/installed-paths"; then scan_failed=1; return 0; fi
  { pair_hashes "$listing" "$new_release/$plugin.sha256" | cut -d $'\034' -f1; cat "$work/installed-paths"; } | LC_ALL=C sort -u >"$work/paths"
  while IFS= read -r path; do
    [[ -n $path ]] || continue
    path_base=$base path_state=$plugin_base
    override=$(awk -F '\t' -v path="$plugin/$path" '$1 == path { print $2 }' "$records/$tool/bases" 2>/dev/null || true)
    new=$(release_hash "$new_release" "$plugin" "$path")
    disk=""
    [[ ! -f $root/$path ]] || disk=$(file_hash "$root/$path")
    if [[ $override == added ]]; then
      path_base=added
      if [[ -z $disk ]]; then continue
      elif [[ -z $new ]] && in_history "$plugin" "$path"; then class=edited-kept-removed
      elif [[ -z $new ]]; then class=edited-added
      elif [[ $disk == "$new" ]]; then class=untouched
      else class=edited-conflict
      fi
    else
      [[ -z $override ]] || path_base=$override
      record=$(awk -v path="$path" 'substr($0, 67) == path { print substr($0, 1, 64) }' "$listing")
      if [[ $override == unknown ]]; then
        path_state=unknown record="" path_base=""
      elif [[ -n $override ]]; then
        path_state=known
        if ! old=$(release_tree "$override"); then
          warn "couldn't read p3stack's release ${override:0:7}, which your kept $(label "$path") is based on"
          scan_failed=1
          return 0
        fi
        if [[ -f $old/$plugin/$path ]]; then record=$(file_hash "$old/$plugin/$path"); fi
      fi
      if [[ -z $disk ]]; then
        [[ -n $record && -n $new && -z $kind ]] || continue
        class=deleted
      elif [[ -z $record && -z $new ]] && ! in_history "$plugin" "$path"; then
        class=edited-added path_base=added
      else
        class=$(classify "$path_state" "$record" "$disk" "$new")
        lag_from=""
        [[ $path_state == unknown ]] || lag_from=$path_base
        if [[ $path_state == known && $class != untouched ]] && is_lag "$plugin" "$path" "$disk" "$lag_from"; then class=untouched; fi
        if [[ $class == edited-removed ]]; then
          skill=$(skill_of "$path" || true)
          [[ -n $skill && ! -f $new_release/$plugin/skills/$skill/SKILL.md ]] || class=edited-file-removed
        fi
      fi
    fi
    [[ $kind != old || $class == edited-* ]] || continue
    add_row "$tool" "$plugin" "$path" "$class" "$root" "$path_base" "$disk" "$kind"
  done <"$work/paths"
}

# After a background auto-update both folders can hold edits. The same edit in both is one edit; different edits are two versions to choose from.
pair_folders() {
  local first=$1 o a
  for ((o = first; o < ${#row_tool[@]}; o++)); do
    [[ ${row_kind[o]} == old ]] || continue
    for ((a = first; a < ${#row_tool[@]}; a++)); do
      [[ ${row_kind[a]} == active && ${row_plugin[a]} == "${row_plugin[o]}" && ${row_path[a]} == "${row_path[o]}" ]] || continue
      if ! edited "$a"; then
        row_class[a]=untouched
      elif [[ ${row_pre[a]} == "${row_pre[o]}" ]]; then
        row_class[o]=superseded
      else
        row_partner[a]=$o row_partner[o]=$a
      fi
      break
    done
  done
}

scan_stop() {
  warn "$3"
  stopped+="$1 "
  rows_truncate "$2"
}

edits_scan() {
  local tool=$1 plugin root base active old warned=0 first=${#row_tool[@]} i count p3base name status
  local changed=() found=() unknown=() labels=()
  name=$(tool_label "$tool")
  heading "$name"
  if ! has_record "$tool"; then
    p3base=$(installed_base "$tool" p3stack || true)
    case $tool/${p3base:+known} in
      claude/known) say "  No record of the last install. Using the commit in the folder name (${p3base:0:7})." ;;
      */known) say "  No record of the last install. Using the commit $name installed (${p3base:0:7})." ;;
      *) warn "No record of the last install in $name, and $name doesn't say which version it has." ;;
    esac
  fi
  scan_failed=0
  for plugin in "${plugins[@]}"; do
    status=0
    plugin_installed "$tool" "$plugin" || status=$?
    if ((status == 2)); then
      listing_failed "$tool"
      rows_truncate "$first"
      return 0
    fi
    ((status == 0)) || continue
    if ! root=$("${tool}_root" "$plugin"); then
      scan_stop "$tool" "$first" "p3stack is installed in $name, but the installer couldn't find where $name keeps $plugin, so it left $name alone. Check that $name still lists $plugin, or reinstall p3stack there, then run p3stack update again."
      return 0
    fi
    base=$(installed_base "$tool" "$plugin" || true)
    active=""
    [[ " $commit_named_by_install " != *" $tool "* ]] || active=$("${tool}_commit" "$plugin" 2>/dev/null || true)
    if [[ -n $base && -n $active && $base != "$active" ]]; then
      if old=$(old_root "$tool" "$plugin" "$base"); then
        say "  Checking $plugin edits from before the background auto-update and since."
        scan_folder "$tool" "$plugin" "$old" "$base" old
        ((scan_failed)) || scan_folder "$tool" "$plugin" "$root" "$active" active
        ((scan_failed)) || pair_folders "$first"
      else
        ((warned)) || warn "Edits made before the auto-update may be in a folder $name removed."
        warned=1
        scan_folder "$tool" "$plugin" "$root" "$active" ""
      fi
    else
      scan_folder "$tool" "$plugin" "$root" "$base" ""
    fi
    if ((scan_failed)); then scan_stop "$tool" "$first" "Nothing was installed in $name."; return 0; fi
  done
  for ((i = first; i < ${#row_tool[@]}; i++)); do
    edited "$i" || continue
    if ! backup_row "$i"; then scan_stop "$tool" "$first" "Nothing was installed in $name, so your files there are as they were."; return 0; fi
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
      summary_line Yours "$(change_summary "$(base_file "$i")" "$(yours_file "$i")")"
      summary_line p3stack "$(change_summary "$(base_file "$i")" "$(new_file "$i")")"
    fi
  fi
}

unattended_note() {
  class_policy "$1"
  [[ -z $unattended_message ]] || warn "$unattended_message"
}

# Codex, Cursor, and OpenCode load ~/.agents/skills themselves. Claude Code loads only its own skills folder, so it needs a link.
personal_visible() {
  local link dest=$HOME/.agents/skills/$2
  case $1 in
    claude)
      link=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/$2
      if [[ -L $link && -d $link && $(cd "$link" && pwd -P) == "$(cd "$dest" && pwd -P)" ]]; then return 0; fi
      [[ ! -e $link && ! -L $link ]] || return 1
      mkdir -p "$(dirname "$link")" && ln -s "$dest" "$link"
      ;;
    codex|cursor|opencode) [[ -f $dest/SKILL.md ]] ;;
    *) return 1 ;;
  esac
}

keep_skill_in_place() {
  local tool=$1 plugin=$2 skill=$3 j
  for ((j = 0; j < ${#row_tool[@]}; j++)); do
    [[ ${row_tool[j]} == "$tool" && ${row_plugin[j]} == "$plugin" && $(skill_of "${row_path[j]}" || true) == "$skill" ]] || continue
    [[ ${row_class[j]} != superseded && ${row_class[j]} != deleted && ${row_kind[j]} != active ]] || continue
    if ! edited "$j"; then
      row_class[j]=edited-kept-removed
      backup_row "$j"
    fi
    row_base[j]=added row_action[j]=keep
  done
}

personal_made=" "

make_personal_skill() {
  local i=$1 skill dest tool where=() visible=0 t
  shift
  skill=$(skill_of "${row_path[i]}") tool=${row_tool[i]}
  dest=$HOME/.agents/skills/$skill
  if [[ $personal_made != *" $skill "* ]]; then
    if [[ -e $dest || -L $dest ]]; then
      warn "$(tilde "$dest") already exists, so your $skill stays in $(tool_label "$tool")'s p3stack folder. Your version is also saved in $(tilde "${row_backup[i]}")."
      keep_skill_in_place "$tool" "${row_plugin[i]}" "$skill"
      return 0
    fi
    mkdir -p "$(dirname "$dest")"
    cp -R "${row_root[i]}/skills/$skill" "$dest"
    personal_made+="$skill "
    for t in $present; do
      if personal_visible "$t" "$skill"; then where+=("$(tool_label "$t")"); fi
    done
    if ((${#where[@]} == 1)); then
      printf ', where %s loads it' "${where[0]}" >"$work/personal-$skill"
    elif ((${#where[@]})); then
      printf ', where %s load it' "$(and_list "${where[@]}")" >"$work/personal-$skill"
    fi
  elif ! diff -rq "${row_root[i]}/skills/$skill" "$dest" >/dev/null 2>&1; then
    warn "Your $skill in $(tool_label "$tool") differs from the copy now in $(tilde "$dest"). The $(tool_label "$tool") version is saved in $(tilde "${row_backup[i]}")."
  fi
  if [[ " $present " == *" $tool "* ]] && personal_visible "$tool" "$skill"; then visible=1; fi
  if ((visible)); then
    for t; do row_action[t]=moved; done
  else
    warn "$(tool_label "$tool") can't see $(tilde "$dest"), so your $skill also stays in $(tool_label "$tool")'s p3stack folder."
    say "  Copied your $skill to $(tilde "$dest")$(cat "$work/personal-$skill" 2>/dev/null || true)."
    keep_skill_in_place "$tool" "${row_plugin[i]}" "$skill"
  fi
}

merge_brief() {
  local i=$1 ext=$2 kind=$3 skill step=1
  skill=$(skill_of "${row_path[i]}" || true)
  printf '# Merge %s\n\n' "$(label "${row_path[i]}")"
  if [[ $kind == versions ]]; then
    printf 'The person at the keyboard edited this p3stack file twice: once before %s updated p3stack in the background, and again in the new copy afterwards. Help them combine their two versions.\n\n' "$(tool_label "${row_tool[i]}")"
    printf -- '- `yours%s` is their newer version, in the copy %s uses now.\n' "$ext" "$(tool_label "${row_tool[i]}")"
    printf -- '- `older%s` is their older version, from before the background update.\n\n' "$ext"
    printf '%s. Explain in plain words how the two versions differ.\n' $((step++))
  else
    printf 'The person at the keyboard changed their installed copy of this p3stack file, and p3stack also changed it in its new release. Help them combine the two.\n\n'
    printf -- '- `yours%s` is their copy, with their changes.\n' "$ext"
    printf -- '- `theirs%s` is the file in p3stack'"'"'s new release.\n' "$ext"
    if [[ -f original$ext ]]; then
      printf -- '- `original%s` is the file as p3stack shipped it in the release they have installed.\n\n' "$ext"
      printf '%s. Compare each copy against `original%s`. Explain in plain words what they changed and what p3stack changed.\n' $((step++)) "$ext"
    else
      printf '\nThe release they installed is not available, so compare `yours%s` and `theirs%s` directly.\n\n' "$ext" "$ext"
      printf '%s. Explain in plain words how the two versions differ.\n' $((step++))
    fi
  fi
  printf '%s. Help them combine the two. Ask before you drop a change from either side.\n' $((step++))
  if [[ $ext != .md && -n $skill ]]; then
    printf '%s. This file is a script, so run its tests first. Copy `%s` to a scratch folder, put the combined file in place of `%s`, run the tests there, and fix what fails.\n' $((step++)) "${row_root[i]}/skills/$skill" "${row_path[i]#skills/"$skill"/}"
  fi
  printf '%s. Write the combined file to `result%s` in this folder. Leave the other files as they are.\n' $((step++)) "$ext"
  printf '\nWhen `result%s` is written, tell them to close this session so the update can go on.\n' "$ext"
}

# A merge folder holds the current inputs and at most one earlier result.
merge_folder_reset() {
  local dir=$1 ext=$2 entry
  if [[ -f $dir/result$ext ]]; then mv -f "$dir/result$ext" "$dir/result.previous$ext" || return 1; fi
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [[ -e $entry || -L $entry ]] || continue
    [[ ${entry##*/} == "result.previous$ext" ]] || rm -rf "$entry" || return 1
  done
}

talk() {
  local i=$1 kind=$2 other=${3:-} agents=() names=() line n options=() agent name file ext="" dir
  talk_result=""
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
  merge_folder_reset "$dir" "$ext" || return 1
  cp "$(yours_file "$i")" "$dir/yours$ext" || return 1
  if [[ $kind == versions ]]; then
    cp "$(yours_file "$other")" "$dir/older$ext" || return 1
  else
    if [[ -n $(base_file "$i") ]]; then cp "$(base_file "$i")" "$dir/original$ext" || return 1; fi
    cp "$(new_file "$i")" "$dir/theirs$ext" || return 1
  fi
  (cd "$dir" && merge_brief "$i" "$ext" "$kind" >BRIEF.md) || return 1
  say "  Opening $name in $(tilde "$dir")/ with the old p3stack still installed."
  if [[ $kind == versions ]]; then
    say "  It has yours$ext, older$ext, and a brief. It explains how they differ, then writes result$ext."
  else
    say "  It has $( [[ -f $dir/original$ext ]] && printf 'original%s, ' "$ext")yours$ext, theirs$ext, and a brief. It explains both changes, then writes result$ext."
  fi
  (cd "$dir" && launch_agent "$agent" "$(cat BRIEF.md)") <&3 || true
  if [[ -s $dir/result$ext ]] && LC_ALL=C grep -q '[^[:space:]]' "$dir/result$ext"; then
    talk_result=$dir/result$ext
    if [[ $kind == versions ]]; then
      say "  Got result$ext. It replaces both of your versions of $(label "${row_path[i]}")."
    else
      say "  Got result$ext. The merged $(label "${row_path[i]}") goes in after the update, marked edited."
    fi
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

choose_version() {
  local i=$1 o a name tool options=() picked record merged
  if [[ ${row_kind[i]} == old ]]; then o=$i a=${row_partner[i]}; else a=$i o=${row_partner[i]}; fi
  row_partner[o]="" row_partner[a]=""
  name=$(label "${row_path[a]}") tool=$(tool_label "${row_tool[a]}")
  options=(a "Keep the active one" o "Keep the older one")
  [[ -z $(found_agents) ]] || options+=(t "Talk to a model to merge them")
  winner=$a
  while :; do
    picked=""
    if ((attended)); then
      say ""
      say "  $name in $tool: you changed it before $tool's background auto-update and again after it, and the two versions differ."
      summary_line Older "$(change_summary "$(base_file "$o")" "$(yours_file "$o")")"
      summary_line Active "$(change_summary "$(base_file "$a")" "$(yours_file "$a")")"
      if choose a "${options[@]}"; then picked=$choice; fi
    fi
    case $picked in
      a) ;;
      o) winner=$o ;;
      t)
        talk "$a" versions "$o" || continue
        merged=$work/versions-$a
        cp "$talk_result" "$merged"
        row_source[a]=$merged
        record=""
        if [[ -n $(base_file "$a") ]]; then record=$(file_hash "$(base_file "$a")"); fi
        row_class[a]=$(classify known "$record" "$(file_hash "$merged")" "$(release_hash "$new_release" "${row_plugin[a]}" "${row_path[a]}")")
        case ${row_class[a]} in
          untouched) row_class[a]=edited-kept ;;
          edited-removed) row_class[a]=edited-file-removed ;;
        esac
        ;;
      *) warn "No one is at the keyboard to choose, so your newer version of $name in $tool was kept. Your older version is saved in $(tilde "${row_backup[o]}")." ;;
    esac
    break
  done
  if [[ $winner == "$a" ]]; then
    row_class[o]=superseded
  else
    row_class[a]=superseded row_replaces[o]=${row_pre[a]}
  fi
}

decide() {
  local i=$1 kind members=() options=() j word picked no_keyboard=0
  if [[ -n ${row_partner[i]} ]]; then
    choose_version "$i"
    i=$winner
    [[ -z ${row_action[i]} ]] || return 0
  fi
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
      if talk "$i" change; then
        row_action[i]=merged row_source[i]=$talk_result
        return 0
      fi
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
    [[ ${row_class[j]} == untouched && -z ${row_action[j]} && ${row_kind[j]} != old ]] || continue
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

edits_prepare() {
  local tool base status olds=() scan=()
  scan_generation=$gen_stamp-${new_commit:0:7}
  for tool; do
    [[ $stopped != *" $tool "* ]] || continue
    prepare_installation "$tool"
    [[ $stopped != *" $tool "* ]] || continue
    status=0
    has_p3stack "$tool" || status=$?
    if ((status == 2)); then listing_failed "$tool"; continue; fi
    ((status == 0)) || continue
    scan+=("$tool")
    reinstall+="$tool "
    base=$(installed_base "$tool" p3stack || true)
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
  for tool in ${scan[@]+"${scan[@]}"}; do
    edits_scan "$tool"
    [[ $stopped == *" $tool "* ]] || scanned_tools+="$tool "
  done
  edits_decide
  for tool; do
    [[ $stopped != *" $tool "* ]] || continue
    if ! journal_write "$tool"; then
      warn "couldn't save the update plan for $(tool_label "$tool") in $(tilde "$pending"), so nothing was installed there"
      stopped+="$tool "
    fi
  done
  rows_reset
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

# A journal is one tool's planned update: rows with the user's content before (pre), the release file the tool will write (release), and what apply writes (apply).
# Its state says how far the run got: "prepared" before the tool's own update returned, "tool-updated" after.
journal_write() {
  local tool=$1 staging=$pending/.prepare-$1 i source apply saved
  rm -rf "$staging" && mkdir -p "$staging" && cp -R "$new_release" "$staging/tree" &&
    printf '%s\n' "$new_commit" >"$staging/commit" && : >"$staging/rows" || return 1
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ ${row_tool[i]} == "$tool" && ${row_class[i]} != superseded ]] || continue
    [[ ${row_class[i]} != deleted ]] || row_action[i]=keep
    [[ -n ${row_action[i]} ]] || continue
    row_release[i]=$(release_hash "$new_release" "${row_plugin[i]}" "${row_path[i]}")
    source=""
    [[ -z ${row_replaces[i]} ]] || row_release[i]+=" ${row_replaces[i]}"
    case ${row_action[i]}/${row_class[i]} in
      */deleted|accept/*) apply=$(release_hash "$new_release" "${row_plugin[i]}" "${row_path[i]}") ;;
      moved/*) apply="" ;;
      *)
        source=${row_source[i]}
        apply=$(file_hash "$source") || return 1
        if [[ $source != "$edits_home"/* ]]; then
          saved=$staging/sources/${row_plugin[i]}/${row_path[i]}
          mkdir -p "$(dirname "$saved")" && cp -p "$source" "$saved" && cmp -s "$source" "$saved" || return 1
          source=$pending/$tool/sources/${row_plugin[i]}/${row_path[i]}
        fi
        ;;
    esac
    printf '%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n' \
      "${row_tool[i]}" "${row_plugin[i]}" "${row_path[i]}" "${row_class[i]}" "${row_action[i]}" "$source" \
      "${row_base[i]}" "${row_from[i]}" "${row_backup[i]}" "${row_root[i]}" "${row_pre[i]}" "${row_release[i]}" "$apply" >>"$staging/rows" || return 1
  done
  printf 'prepared\n' >"$staging/state" && mv "$staging" "$pending/$tool"
}

journal_load() {
  local journal=$pending/$1 tool plugin path class action source base from backup root pre release apply n
  [[ -f $journal/rows && -f $journal/commit && -d $journal/tree ]] || return 1
  case $(cat "$journal/state" 2>/dev/null) in prepared|tool-updated) ;; *) return 1 ;; esac
  awk -F $'\034' -v tool="$1" 'NF != 13 || $1 != tool { bad = 1 } END { exit bad }' "$journal/rows" || return 1
  rows_reset
  while IFS=$'\034' read -r tool plugin path class action source base from backup root pre release apply; do
    add_row "$tool" "$plugin" "$path" "$class" "$root" "$base" "$pre"
    n=$((${#row_tool[@]} - 1))
    row_action[n]=$action row_source[n]=$source row_from[n]=$from row_backup[n]=$backup row_release[n]=$release row_apply[n]=$apply
  done <"$journal/rows"
}

journal_save_sources() {
  local tool=$1 journal=$2 which=$3 i saved
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ ${row_source[i]} == "$journal/sources/"* && -f ${row_source[i]} ]] || continue
    if [[ $which != all ]]; then
      case ${row_outcome[i]} in already-right|restored) continue ;; esac
    fi
    saved=$(save_copy "$tool" "$gen_stamp-merged" "${row_plugin[i]}/${row_path[i]}" "${row_source[i]}") || return 1
    say "  Your merged $(label "${row_path[i]}") is saved in $(tilde "$saved")."
  done
}

reconcile_file() {
  local dest=$1 source=$2 safe=$3 leave=$4 tool=$5 path=$6 current="" wanted=""
  reconcile_outcome="" reconcile_backup=""
  if [[ -L $dest || ( -e $dest && ! -f $dest ) ]]; then
    reconcile_outcome=not-a-plain-file
    warn "$(tilde "$dest") isn't a plain file any more, so it was left as it is."
    return 0
  fi
  [[ ! -f $dest ]] || current=$(file_hash "$dest") || return 1
  [[ -z $source ]] || wanted=$(file_hash "$source") || return 1
  if [[ $current == "$wanted" ]]; then
    reconcile_outcome=already-right
  elif [[ -n $current && $current == "$leave" ]]; then
    reconcile_outcome=left-for-scan
    say "  Your pre-update version of $(label "${path#*/}") in $(tool_label "$tool") was left for this run's scan."
  elif [[ -z $current || " $safe " == *" $current "* ]]; then
    if [[ -z $source ]]; then
      rm -f "$dest" || return 1
    else
      mkdir -p "$(dirname "$dest")" && cp -p "$source" "$dest" && cmp -s "$source" "$dest" || return 1
    fi
    reconcile_outcome=restored
  else
    reconcile_backup=$(save_copy "$tool" "$gen_stamp-newer" "$path" "$dest") || return 1
    reconcile_outcome=newer-user-edit
    say "  You changed $(label "${path#*/}") in $(tool_label "$tool") after the update started, so it was left as it is. That version is saved in $(tilde "$reconcile_backup")."
  fi
}

write_base() {
  local file=$1 path=$2 base=${3:-unknown}
  if [[ -f $file ]]; then
    awk -F '\t' -v path="$path" '$1 != path' "$file" >"$file.next" || return 1
  else
    : >"$file.next" || return 1
  fi
  printf '%s\t%s\n' "$path" "$base" >>"$file.next" && mv "$file.next" "$file"
}

apply_row() {
  local i=$1 dest=$2 tree=$3 bases=$4 replay=$5 plan=$6 actual=$7 source="" leave="" base=""
  case ${row_action[i]}/${row_class[i]} in
    */deleted|accept/*) [[ ! -f $tree/${row_plugin[i]}/${row_path[i]} ]] || source=$tree/${row_plugin[i]}/${row_path[i]} ;;
    moved/*) ;;
    *) source=${row_source[i]} ;;
  esac
  [[ $replay != 1 ]] || leave=${row_pre[i]}
  reconcile_file "$dest" "$source" "${row_pre[i]} ${row_release[i]}" "$leave" "${row_tool[i]}" "${row_plugin[i]}/${row_path[i]}" || return 1
  row_outcome[i]=$reconcile_outcome
  case $reconcile_outcome in
    newer-user-edit|left-for-scan|not-a-plain-file)
      [[ -z $reconcile_backup ]] || row_backup[i]=$reconcile_backup
      write_base "$bases" "${row_plugin[i]}/${row_path[i]}" "${row_base[i]}"
      return
      ;;
  esac
  case ${row_action[i]}/${row_class[i]} in
    */deleted|accept/*|moved/*) ;;
    *) stamp "$dest" || return 1 ;;
  esac
  case ${row_action[i]}/${row_class[i]} in
    copy/*) base=${row_base[i]} ;;
    keep/edited-conflict) base=${row_base[i]:-unknown} ;;
    keep/edited-file-removed|keep/edited-added|keep/edited-kept-removed|keep/edited-removed) base=added ;;
  esac
  if [[ $actual != "$plan" ]]; then
    case ${row_action[i]} in
      keep|copy) base=${row_base[i]:-unknown} ;;
      merged) base=$plan ;;
    esac
  fi
  [[ -z $base ]] || write_base "$bases" "${row_plugin[i]}/${row_path[i]}" "$base"
  return 0
}

journal_apply() {
  local tool=$1 journal=$pending/$1 replay=${2:-0} commit i p root plugin installed tree had_record=0 kept=() accepted=() reported=" " skill bases raced=0 chose=0
  local actual_commits=() actual_trees=() actual_roots=()
  journal_load "$tool" || return 1
  commit=$(cat "$journal/commit") || return 1
  for ((p = 0; p < ${#plugins[@]}; p++)); do
    plugin=${plugins[p]}
    root=$("${tool}_root" "$plugin") || return 2
    actual_roots[p]=$root
    if ! installed=$("${tool}_commit" "$plugin" 2>/dev/null) || [[ -z $installed ]]; then
      git -C "$release_clone" fetch --quiet origin </dev/null 3<&- || return 1
      if ! installed=$("${tool}_commit" "$plugin" 2>/dev/null) || [[ -z $installed ]]; then
        warn "couldn't determine the commit $(tool_label "$tool") installed for $plugin, so its record stays unchanged and this update waits in $(tilde "$journal")"
        return 1
      fi
    fi
    if ! tree=$(release_tree "$installed") &&
      ! { git -C "$release_clone" fetch --quiet origin </dev/null 3<&- && tree=$(release_tree "$installed"); }; then
      warn "couldn't read the p3stack release $(tool_label "$tool") installed for $plugin (${installed:0:7}), so its record wasn't updated"
      return 1
    fi
    [[ $replay != 1 || $installed == "$commit" ]] || return 3
    actual_commits[p]=$installed actual_trees[p]=$tree
    [[ $installed == "$commit" ]] || raced=1
  done
  ! has_record "$tool" || had_record=1
  bases=$journal/bases.next
  : >"$bases" || return 1
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    for ((p = 0; p < ${#plugins[@]}; p++)); do
      [[ ${plugins[p]} == "${row_plugin[i]}" ]] && break
    done
    tree=${actual_trees[p]}
    case ${row_action[i]}/${row_class[i]} in
      accept/*|merged/*|moved/*|keep/edited-conflict|keep/edited-removed|keep/edited-file-removed|keep/unknown-base) chose=1 ;;
    esac
    row_release[i]+=" $(release_hash "$tree" "${row_plugin[i]}" "${row_path[i]}")"
    if ! apply_row "$i" "${actual_roots[p]}/${row_path[i]}" "$tree" "$bases" "$replay" "$commit" "${actual_commits[p]}"; then
      warn "couldn't write $(tilde "${actual_roots[p]}/${row_path[i]}"). The rest of this update waits in $(tilde "$journal")."
      return 1
    fi
    case ${row_outcome[i]} in already-right|restored) ;; *) continue ;; esac
    if [[ ${actual_commits[p]} != "$commit" ]]; then
      if [[ ( ${row_action[i]} == accept || ${row_class[i]} == deleted ) && ! -f $tree/${row_plugin[i]}/${row_path[i]} ]]; then
        say "  The installed p3stack release removed $(label "${row_path[i]}")."
        [[ -z ${row_backup[i]} ]] || say "  Your version is saved in $(tilde "${row_backup[i]}")."
        continue
      elif [[ ${row_action[i]} == keep ]]; then
        say "  Kept your version of $(label "${row_path[i]}")."
        continue
      fi
    fi
    skill=$(skill_of "${row_path[i]}" || true)
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
  mkdir -p "$records/$tool" && mv "$bases" "$records/$tool/bases" || return 1
  for ((p = 0; p < ${#plugins[@]}; p++)); do
    record_write "$tool" "${plugins[p]}" "${actual_commits[p]}" "${actual_trees[p]}" || return 1
  done
  journal_save_sources "$tool" "$journal" unapplied || return 1
  rm -rf "$journal" || return 1
  if ((raced && chose)); then say "  p3stack released again while you were choosing, or the tool installed a different release. Your choices were kept, and you'll be asked about any newer change next time."; fi
  if ((had_record == 0)) && [[ $scanned_tools == *" $tool "* ]]; then say "  Saved a record for next time."; fi
}

journal_rollback() {
  local tool=$1 journal=$pending/$1 i plugin root dest installed tree safe bases=$work/rollback-bases
  journal_load "$tool" || return 1
  if [[ $tool == claude ]]; then
    for plugin in "${plugins[@]}"; do
      root=$(claude_root "$plugin" allow-missing 2>/dev/null || true)
      [[ -z $root ]] || mkdir -p "$root" || return 1
    done
  fi
  if [[ -f $records/$tool/bases ]]; then cp "$records/$tool/bases" "$bases" || return 1; else : >"$bases" || return 1; fi
  for ((i = 0; i < ${#row_tool[@]}; i++)); do
    [[ -n ${row_backup[i]} ]] || continue
    root=$("${tool}_root" "${row_plugin[i]}" 2>/dev/null || true)
    [[ -n $root ]] || root=${row_root[i]}
    dest=$root/${row_path[i]}
    safe=${row_release[i]}
    installed=$("${tool}_commit" "${row_plugin[i]}" 2>/dev/null || true)
    if [[ -n $installed ]] && tree=$(release_tree "$installed"); then
      safe+=" $(release_hash "$tree" "${row_plugin[i]}" "${row_path[i]}")"
    fi
    reconcile_file "$dest" "${row_backup[i]}" "$safe" "${row_pre[i]}" "$tool" "${row_plugin[i]}/${row_path[i]}" || return 1
    row_outcome[i]=$reconcile_outcome
    write_base "$bases" "${row_plugin[i]}/${row_path[i]}" "${row_base[i]}" || return 1
  done
  mkdir -p "$records/$tool" && mv "$bases" "$records/$tool/bases" || return 1
  journal_save_sources "$tool" "$journal" all || return 1
  rm -rf "$journal"
}

journal_shelve() {
  local dir=$1 name=$2 dest=$p3stack_home/pending-failed/$2-$gen_stamp
  if [[ -d $dir/sources ]]; then
    mkdir -p "$edits_home/$name/$gen_stamp-unfinished" && cp -R "$dir/sources/." "$edits_home/$name/$gen_stamp-unfinished/" || {
      warn "couldn't copy the merge results in $(tilde "$dir/sources") to $(tilde "$edits_home"), so $(tilde "$dir") stays where it is"
      return 1
    }
  fi
  mkdir -p "$p3stack_home/pending-failed" && mv "$dir" "$dest" || { warn "couldn't move $(tilde "$dir") aside"; return 1; }
  warn "Couldn't read the unfinished update in $(tilde "$dir"), so it was moved to $(tilde "$dest"). Your backups are in $(tilde "$edits_home")/. Check the saved files before running p3stack update again."
}

journal_drop() {
  local tool=$1
  journal_load "$tool" || { journal_shelve "$pending/$tool" "$tool"; return; }
  journal_save_sources "$tool" "$pending/$tool" all || return 1
  rm -rf "${pending:?}/$tool" || return 1
  say "Dropped the unfinished p3stack update for $(tool_label "$tool"). Your backups stay in $(tilde "$edits_home/$tool")/."
}

recover_updates() {
  local dir name status
  [[ $action != uninstall ]] || return 0
  for dir in "$pending"/*; do
    [[ -d $dir ]] || continue
    name=${dir##*/}
    if [[ " $tool_names " != *" $name "* ]] || ! journal_load "$name"; then
      journal_shelve "$dir" "$name" || stopped+="$name "
      continue
    fi
    status=3
    if [[ $(cat "$dir/state") == tool-updated ]]; then
      status=0
      journal_apply "$name" 1 || status=$?
      ((status)) || say "Finished an interrupted update in $(tool_label "$name"). Any files left in place are checked by this run's scan."
    fi
    if ((status == 2 || status == 3)); then
      status=0
      journal_rollback "$name" || status=$?
      ((status)) || say "An earlier update in $(tool_label "$name") needs a fresh scan. Its backed-up files were reconciled, and this run checks every surviving p3stack folder before installing."
    fi
    if ((status)); then
      stopped+="$name "
      warn "Couldn't finish the earlier update in $(tool_label "$name"). It waits in $(tilde "$dir"), and $(tool_label "$name") is left alone this run. Your backups are in $(tilde "$edits_home/$name")/. Check the tool's plugin listing, then run p3stack update $name again."
    fi
  done
  rows_reset
}

cleanup() {
  [[ -z $work ]] || rm -rf "$work"
  if ((locked)); then rm -f "$p3stack_home/lock/pid" "$p3stack_home/lock/command"; rmdir "$p3stack_home/lock"; fi
}

# BusyBox ps has no -p, but lists every process by default.
process_args() {
  ps -o args= -p "$1" 2>/dev/null && return
  ps -o pid,args 2>/dev/null | awk -v pid="$1" '$1 == pid { sub(/^ *[0-9]+ +/, ""); print; found = 1 } END { exit !found }'
}

# A lock is stale when its PID is gone, when the PID now runs something other than the command that took the lock, or after six hours.
lock_owner_alive() {
  local pid args
  [[ -z $(find "$1" -prune -mmin +360 2>/dev/null) ]] || return 1
  pid=$(cat "$1/pid" 2>/dev/null || true)
  if [[ -n $pid && $pid != *[!0-9]* ]]; then
    kill -0 "$pid" 2>/dev/null || return 1
    args=$(process_args "$pid" || true)
    case $args in
      bash|*/bash|'bash -s'|*'/bash -s') [[ -f $1/command ]] || return 1 ;;
      bash\ *|*/bash\ *) [[ $args == *install.sh* ]] || return 1 ;;
      *) return 1 ;;
    esac
    [[ ! -f $1/command || $args == "$(cat "$1/command")" ]]
    return
  fi
  [[ -z $(find "$1" -prune -mmin +1) ]]
}

lock_held() {
  warn "$1 If no p3stack install or update is running, delete $(tilde "$p3stack_home/lock") and run this again."
  return 1
}

update_lock() {
  local lock=$p3stack_home/lock pid args stale
  mkdir -p "$p3stack_home"
  if ! mkdir "$lock" 2>/dev/null; then
    exec 9<"$lock"
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if lock_owner_alive "$lock"; then lock_held "another p3stack command${pid:+ (PID $pid)} is running or starting."; return 1; fi
    if ! mkdir "$lock/reclaim" 2>/dev/null; then
      if lock_owner_alive "$lock/reclaim"; then lock_held "another p3stack command is reclaiming its lock."; return 1; fi
      rm -f "$lock/reclaim/pid"
      rmdir "$lock/reclaim" || return 1
      mkdir "$lock/reclaim" || return 1
    fi
    printf '%s\n' "$$" >"$lock/reclaim/pid"
    stale=$pid
    pid=$(cat "$lock/pid" 2>/dev/null || true)
    if [[ ! $lock -ef /dev/fd/9 ]] || { [[ -n $pid && $pid != *[!0-9]* && $pid != "$stale" ]] && kill -0 "$pid" 2>/dev/null; }; then
      rm "$lock/reclaim/pid"
      rmdir "$lock/reclaim"
      lock_held "another p3stack command acquired the lock."
      return 1
    fi
    rm -f "$lock/pid" "$lock/command" "$lock/reclaim/pid"
    rmdir "$lock/reclaim"
    rmdir "$lock" || return 1
    exec 9<&-
    mkdir "$lock" || { lock_held "another p3stack command acquired the lock."; return 1; }
  fi
  locked=1
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
  printf '%s\n' "$$" >"$lock/pid"
  args=$(process_args "$$" || true)
  [[ -z $args ]] || printf '%s\n' "$args" >"$lock/command"
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

  local done_tools="" failed="" skipped="" tool_action status
  for tool in $wanted; do
    if "${tool}_found"; then present="$present $tool"; else skipped="$skipped $tool"; fi
  done
  update_lock
  work=$(mktemp -d "${TMPDIR:-/tmp}/p3stack.XXXXXX")
  gen_stamp=$(date -u +%Y%m%dT%H%M%SZ)-${work##*.}
  local fetch_failed=0
  if [[ $action != uninstall ]]; then
    if ! release_fetch; then
      warn "couldn't fetch p3stack with git -C $(tilde "$release_clone") fetch --quiet origin, or clone $repo_url. Cached interrupted updates will be recovered; no new installation will run."
      fetch_failed=1
    fi
  fi
  recover_updates
  ((fetch_failed == 0)) || return 1
  if [[ $action != uninstall && -n $present ]]; then edits_prepare $present; fi
  for tool in $present; do
    heading "$action p3stack in $tool"
    if [[ $stopped == *" $tool "* ]]; then
      failed="$failed $tool"
      warn "$action stopped for $tool"
      continue
    fi
    tool_action=$action
    [[ $action != install || $reinstall != *" $tool "* ]] || tool_action=update
    if "${tool}_${tool_action}"; then
      if [[ $action == uninstall ]]; then
        if [[ -d $pending/$tool ]]; then journal_drop "$tool" || { failed+=" $tool"; continue; }; fi
        rm -rf "${records:?}/$tool"
        done_tools="$done_tools $tool"
        continue
      fi
      status=0
      printf 'tool-updated\n' >"$pending/$tool/state.next" && mv "$pending/$tool/state.next" "$pending/$tool/state" || status=1
      ((status)) || journal_apply "$tool" || status=$?
      if ((status)); then
        failed="$failed $tool"
        warn "p3stack is updated in $(tool_label "$tool"), but your edits there aren't all back yet. They wait in $(tilde "$pending/$tool"), and the next p3stack update puts them back."
      else
        done_tools="$done_tools $tool"
      fi
    else
      failed="$failed $tool"
      warn "$action stopped for $tool"
      if [[ $action == uninstall ]]; then
        [[ ! -d $pending/$tool ]] || warn "uninstall failed in $(tool_label "$tool"), so its unfinished update stays in $(tilde "$pending/$tool"). Your backups stay in $(tilde "$edits_home/$tool")/. Retry p3stack uninstall $tool."
        continue
      fi
      [[ -d $pending/$tool ]] || continue
      status=0
      journal_rollback "$tool" || status=$?
      case $status in
        0) say "$(tool_label "$tool")'s update didn't finish. Your backed-up files were reconciled; files left in place will be scanned next time." ;;
        *) warn "Couldn't put your files in $(tool_label "$tool") back. They wait in $(tilde "$pending/$tool"), and your backups are in $(tilde "$edits_home/$tool")/." ;;
      esac
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
