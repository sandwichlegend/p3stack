#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail() { echo "FAIL: $*" >&2; exit 1; }

cursor_only_terms=(
  '`Task`|\bTask (tool|subagent|call)'
  'AskQuestion'
  'subagent_type'
  'generalPurpose'
  'readonly: (true|false)'
  'environment: "(cloud|local)"'
  'cloud_base_branch'
  'run_in_background'
  'file_attachments'
  '`resume`'
  'inherit-parent'
  'pstack-models\.mdc'
  '\.cursor/rules'
  'agent-transcripts'
  'always-applied rule'
  '\b(claude|grok|gpt|gemini|composer|kimi|glm)-[a-z0-9.-]*-(low|medium|high|xhigh|max)(-fast)?\b'
  '[Cc]loud [Aa]gents?\b|[Cc]loud VMs?\b|Cursor [Aa]utomations?'
  '(^|[^a-z])/loop\b|/in-cloud'
  'option\+enter|alt\+enter|[Cc]ustom [Mm]odes?\b'
  '/add-plugin|cursor-team-kit|Grok Bot'
  "create-skill|Cursor's (built-in|own)|restart Cursor|Cursor restart|Cursor Projects?\\b"
)
pattern=$(IFS='|'; echo "${cursor_only_terms[*]}")
scan() { git ls-files -z -- t3stack team-kit | xargs -0 grep -I "$@" -E "$pattern" -- || true; }
with_terms() { scan -l | sort; }

if [[ "${1:-}" == "--terms" ]]; then
  scan -n
  exit 0
fi

for f in scripts/subtrees.txt scripts/removed.txt scripts/unported.txt; do
  git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 || fail "$f is not committed"
done

manifests=(
  t3stack/plugin.json t3stack/.claude-plugin/plugin.json t3stack/.cursor-plugin/plugin.json
  team-kit/plugin.json team-kit/.claude-plugin/plugin.json team-kit/.cursor-plugin/plugin.json
)
marketplaces=(.claude-plugin/marketplace.json .cursor-plugin/marketplace.json .agents/plugins/marketplace.json)
for f in "${manifests[@]}" "${marketplaces[@]}"; do
  [[ -f "$f" ]] || fail "$f is missing"
  python3 -m json.tool "$f" >/dev/null 2>&1 || fail "$f is not valid JSON"
done
for f in "${manifests[@]}"; do
  python3 -c 'import json,sys; sys.exit("version" in json.load(open(sys.argv[1])))' "$f" ||
    fail "$f sets a version. Leave it out so each commit to main counts as an update."
  folder=${f%%/*}
  want=t3stack
  [[ "$folder" == team-kit ]] && want=t3stack-team-kit
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  [[ "$got" == "$want" ]] || fail "$f is named $got, not $want"
done

hook=t3stack/hooks/session-start
[[ -x "$hook" ]] || fail "$hook is missing or not executable"
out=$("$hook") || fail "$hook exited nonzero"
[[ "$out" != *@T3STACK_ROOT@* ]] || fail "$hook left @T3STACK_ROOT@ unexpanded"
mode=$(grep -oE '[^`]*/skills/poteto-mode/SKILL\.md' <<<"$out" | head -1)
[[ -f "$mode" ]] || fail "$hook points at a missing file: $mode"

while IFS= read -r prefix; do
  [[ -z "$prefix" ]] && continue
  [[ -z "$(git ls-files -- "$prefix")" ]] ||
    fail "$prefix is listed in scripts/removed.txt but came back. Run git rm -r $prefix."
done <scripts/removed.txt

listed=$(grep -v '^$' scripts/unported.txt | sort || true)
for f in $listed; do
  [[ -f "$f" ]] || fail "scripts/unported.txt lists $f, which doesn't exist. Drop the line."
done
regained=$(comm -23 <(with_terms) <(printf '%s\n' "$listed" | grep -v '^$' || true))
[[ -z "$regained" ]] || fail "Cursor-only terms in ported files. Port them to T3 (scripts/check.sh --terms):
$(sed 's/^/  /' <<<"$regained")"
finished=$(comm -13 <(with_terms) <(printf '%s\n' "$listed" | grep -v '^$' || true))
[[ -z "$finished" ]] || fail "These files are fully ported. Drop them from scripts/unported.txt:
$(sed 's/^/  /' <<<"$finished")"

left=$(grep -c . <<<"$listed" || true)
echo "t3stack checks pass ($left files left to port)"
