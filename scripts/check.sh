#!/usr/bin/env bash
# Static checks for t3stack. Exits nonzero on the first failure.
#   scripts/check.sh          run every check
#   scripts/check.sh --terms  list every Cursor-only term left in the skills
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Cursor-only mechanics. Adapted from upstream's
# scripts/generate-pstack-harness-trees.mjs TERMS list, minus the ones that are
# also valid in T3 (todo lists, plain model ids such as claude-opus-5-5).
terms=(
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
  '\.cursor/(skills|plugins|rules|projects)'
  'agent-transcripts'
  'always-applied rule'
  '\b(claude|grok|gpt|gemini|composer|kimi|glm)-[a-z0-9.-]*-(low|medium|high|xhigh|max)(-fast)?\b'
  '\bBugbot\b|[Cc]loud [Aa]gents?\b|Cursor [Aa]utomations?'
  '(^|[^a-z])/loop\b|/in-cloud'
  'option\+enter|alt\+enter|[Cc]ustom [Mm]ode'
)
pattern=$(IFS='|'; echo "${terms[*]}")
scanned() { git ls-files -- 't3stack/*.md' 'team-kit/*.md'; }
with_terms() { scanned | xargs grep -lE "$pattern" -- | sort; }

if [[ "${1:-}" == "--terms" ]]; then
  scanned | xargs grep -nE --color=auto "$pattern" --
  exit 0
fi

ours=(
  .claude-plugin/marketplace.json .cursor-plugin/marketplace.json .agents/plugins/marketplace.json
  t3stack/plugin.json t3stack/.claude-plugin/plugin.json t3stack/.cursor-plugin/plugin.json
  team-kit/plugin.json team-kit/.claude-plugin/plugin.json team-kit/.cursor-plugin/plugin.json
)
for f in "${ours[@]}"; do
  [[ -f "$f" ]] || fail "$f is missing"
  python3 -m json.tool "$f" >/dev/null 2>&1 || fail "$f is not valid JSON"
done
for f in "${ours[@]}"; do
  [[ "$f" == *marketplace.json ]] && continue
  python3 -c 'import json,sys; sys.exit("version" in json.load(open(sys.argv[1])))' "$f" ||
    fail "$f sets a version. Leave it out so each commit to main counts as an update."
  want=${f%%/*}; [[ "$want" == team-kit ]] && want=t3stack-team-kit
  got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$f")
  [[ "$got" == "$want" ]] || fail "$f is named $got, not $want"
done

# Every file that still uses a Cursor-only term must be listed in
# scripts/unported.txt, and every listed file must still use one. A clean
# upstream merge that adds a Cursor term to a ported file fails here.
listed=$(grep -vE '^(#|$)' scripts/unported.txt | sort)
for f in $listed; do
  [[ -f "$f" ]] || fail "scripts/unported.txt lists $f, which doesn't exist. Drop the line."
done
new=$(comm -23 <(with_terms) <(echo "$listed"))
[[ -z "$new" ]] || fail "Cursor-only terms in ported files. Port them to T3 (scripts/check.sh --terms):
$(sed 's/^/  /' <<<"$new")"
done_=$(comm -13 <(with_terms) <(echo "$listed"))
[[ -z "$done_" ]] || fail "These files are fully ported. Drop them from scripts/unported.txt:
$(sed 's/^/  /' <<<"$done_")"

echo "t3stack checks pass ($(grep -c . <<<"$listed" || true) files left to port)"
