# p3stack

[pstack](https://github.com/cursor/plugins/tree/main/pstack), Lauren Tan's (poteto) engineering workflow for Cursor, rewritten to run in [T3 Code](https://github.com/pingdotgg/t3code) on [Orchestrator V2](https://github.com/pingdotgg/t3code/tree/main/docs/orchestration-v2).

T3 Code drives Claude Code, Codex, and Cursor from one app, and its `t3-code` MCP server lets any agent delegate a task to any of their models. p3stack uses that for pstack's multi-model work. The default review panels seat Claude Opus, GPT, and Grok, one model from each of three labs, and code goes to Grok with GPT as the fallback.

The plugin's own [README](./p3stack/README.md) and [guide](./p3stack/docs/guide/README.md) cover the skills.

## Install

Install both plugins into every provider you use in T3. Each provider loads plugins its own way.

Claude Code:

```text
/plugin install p3stack --marketplace sandwichlegend/p3stack
/plugin install p3stack-team-kit@p3stack
```

Codex:

```shell
codex plugin marketplace add sandwichlegend/p3stack
codex plugin add p3stack@p3stack
codex plugin add p3stack-team-kit@p3stack
```

Codex asks you to trust the session hook on first run, and again after the hook changes.

Cursor: add `https://github.com/sandwichlegend/p3stack` as a plugin marketplace, then install `p3stack` and `p3stack-team-kit`.

Then run `/setup-pstack` once in any T3 thread. It reads the models T3 can run and writes `~/.p3stack/models.md`.

The manifests leave out `version`, so each commit to `main` is a release.

## What changed from pstack

The skills say the T3 thing directly. There is no translation layer.

| pstack in Cursor | p3stack in T3 Code |
|---|---|
| `Task` subagents with `subagent_type`, `model`, `readonly` | `delegate_task` with a role, a `target` of provider, model, and options, and a self-contained brief |
| Model slugs such as `grok-4.7-xhigh-fast` in `~/.cursor/rules/pstack-models.mdc` | Seats such as `grok-4.7@xhigh+fast` in `~/.p3stack/models.md`, resolved against `orchestrator_capabilities` |
| Cloud agents, one VM each | `isolation: "worktree"` on this machine, capped by `max parallel writers` |
| `/loop` | T3 wakes: task completion, `watch_pull_request`, and `schedule_task` heartbeats |
| `agent-transcripts/` | `t3_thread_list`, `t3_thread_search`, and `t3_thread_read` |
| Custom Mode | A SessionStart hook in Claude Code and Codex |
| Grok Bot webhook routines in `/make-bot-ui` | `schedule_task` webhook tasks |
| Benny, on Cursor Automations and Slack | Removed. Build automation lines from `schedule_task` |
| `cursor-team-kit` | `p3stack-team-kit`, with `control-ui` driving T3's browser preview |

The [Subagents section of poteto-mode](./p3stack/skills/poteto-mode/SKILL.md#subagents) is the one place that defines spawning, roles, waking, and history.

## Layout

- `p3stack/` is the plugin, merged from upstream `pstack/`.
- `team-kit/skills/` holds `deslop`, `control-ui`, and `control-cli`, each merged from upstream `cursor-team-kit/skills/`.
- `scripts/subtrees.txt` maps each folder here to its upstream folder.
- `scripts/removed.txt` lists upstream paths p3stack deletes.
- `scripts/unported.txt` lists files that still use Cursor-only mechanics. It is empty after the port.

## Syncing with upstream

```shell
scripts/sync-upstream.sh
```

It fetches `cursor/plugins` into `refs/upstream/`, which are never pushed, and splits each upstream folder's history out with `git subtree split`. A split gives the same commits every run, so each sync is an ordinary subtree merge and only real edits conflict. The script keeps our plugin manifests when upstream bumps its version, keeps the paths in `scripts/removed.txt` deleted, and then runs `scripts/check.sh`.

A clean merge can still bring Cursor-only instructions into a file we already ported. `scripts/check.sh` fails on any Cursor-only term in a file that `scripts/unported.txt` doesn't list, so a sync can't land until every new Cursor mechanic is rewritten for T3. Run `scripts/check.sh --terms` to see each hit.

[`scripts/sync-agent.md`](./scripts/sync-agent.md) is the prompt for an agent that runs the sync on a schedule and opens a pull request.

## Credit

pstack is Lauren Tan's, and the team-kit skills are Cursor's, both MIT. See [`p3stack/LICENSE`](./p3stack/LICENSE) and [`team-kit/LICENSE`](./team-kit/LICENSE).
