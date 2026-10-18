# p3stack

[pstack](https://github.com/cursor/plugins/tree/main/pstack), Lauren Tan's (poteto) engineering workflow for Cursor, rewritten to run in [T3 Code](https://github.com/pingdotgg/t3code) on [Orchestrator V2](https://github.com/pingdotgg/t3code/tree/main/docs/orchestration-v2).

T3 Code drives Claude Code, Codex, and Cursor from one app, and its `t3-code` MCP server lets any agent delegate a task to any of their models. p3stack uses that for pstack's multi-model work. The default review panels seat Claude Opus, GPT, and Grok, one model from each of three labs, and code goes to Grok with GPT as the fallback.

The plugin's own [README](./p3stack/README.md) and [guide](./p3stack/docs/guide/README.md) cover the skills.

## Install

T3 doesn't install plugins itself. It runs Claude Code, Codex, and Cursor, and each of them loads plugins from its own folder on your machine. So install p3stack from a terminal, once for each of those tools you use in T3. Threads you start or resume afterward pick it up.

You get two plugins: `p3stack`, the skills and agents, and `p3stack-team-kit`, which carries `deslop`, `control-ui`, and `control-cli`.

### One command

```shell
curl -fsSL https://raw.githubusercontent.com/sandwichlegend/p3stack/main/install.sh | bash
```

The installer finds which of Claude Code, Codex, and Cursor you have and sets up both plugins in each. It prints each install, update, or uninstall command it runs, and it's safe to run again. Anything it can't do with certainty, such as editing a Codex `hooks.json` you already have, it prints as a prompt to give your coding agent.

It installs into your home folder, once per machine, and every project and T3 thread picks it up. Nothing is written into your repositories.

One step stays manual. If you use Codex, run `codex` in a terminal, type `/hooks`, and trust the p3stack SessionStart hook. Codex skips hooks you haven't trusted, and T3 can't ask you. The installer reminds you when it's needed.

To keep p3stack out of one of the tools, uninstall it from that tool by hand afterward, using the steps below.

Then run `/setup-pstack` once in any T3 thread to pick models.

The rest of this section does the same thing by hand.

### Claude Code

```shell
claude plugin marketplace add sandwichlegend/p3stack
claude plugin install p3stack@p3stack
claude plugin install p3stack-team-kit@p3stack
```

Inside a Claude Code session, `/plugin install p3stack --marketplace sandwichlegend/p3stack` does the same for the main plugin.

T3's Claude threads then load the skills, the `poteto-agent` and `comment-sicko` agents, and the startup hook that points every session at `/poteto-mode`.

### Codex

```shell
codex plugin marketplace add sandwichlegend/p3stack
codex plugin add p3stack@p3stack
codex plugin add p3stack-team-kit@p3stack
```

T3's Codex threads then load the skills. Codex ignores hooks that ship inside a plugin, so the startup hook needs two more steps:

1. Add this entry to the `hooks.SessionStart` list in `~/.codex/hooks.json`. Create the file with `{"hooks": {"SessionStart": []}}` first if you don't have one.

   ```json
   {
     "hooks": [
       {
         "type": "command",
         "command": "\"$HOME/.codex/plugins/cache/p3stack/p3stack/1.0.0/hooks/session-start\"",
         "timeout": 10
       }
     ]
   }
   ```

2. Run `codex` in a terminal, type `/hooks`, and trust the new hook. Codex skips hooks you haven't trusted, and T3 can't ask you, so a hook you skip here never runs in T3.

Without the hook, ask for poteto-mode by name at the start of each task.

### Cursor

Cursor installs third-party plugins only through team marketplaces, which need a Teams admin. It also loads any plugin folder in `~/.cursor/plugins/local/`, so clone the repository and copy both plugins there. Copy them, don't link them: Cursor skips symlinked plugin folders.

```shell
git clone https://github.com/sandwichlegend/p3stack.git ~/.p3stack/repo
mkdir -p ~/.cursor/plugins/local
cp -R ~/.p3stack/repo/p3stack ~/.cursor/plugins/local/p3stack
cp -R ~/.p3stack/repo/team-kit ~/.cursor/plugins/local/p3stack-team-kit
```

If you also have Cursor's own `pstack` plugin installed, turn it off in Cursor's Customize panel. Both plugins ship skills named `poteto-mode` and `setup-pstack`, and a thread may pick the Cursor-only copy.

Cursor doesn't run the startup hook, so type `/poteto-mode` at the start of each task in a Cursor thread.

### Then

Run `/setup-pstack` once in any T3 thread. It reads the models T3 can run and writes `~/.p3stack/models.md`.

## Update

The manifests leave out `version`, so each commit to `main` is a release.

```shell
curl -fsSL https://raw.githubusercontent.com/sandwichlegend/p3stack/main/install.sh | bash -s -- update
```

Start a new thread, or resume one, to load the update.

By hand, Claude Code:

```shell
claude plugin marketplace update p3stack
claude plugin update p3stack@p3stack
claude plugin update p3stack-team-kit@p3stack
```

To update automatically instead, run `/plugin` in Claude Code, open Marketplaces, pick `p3stack`, and turn on auto-update.

Codex:

```shell
codex plugin marketplace upgrade p3stack
codex plugin add p3stack@p3stack
codex plugin add p3stack-team-kit@p3stack
```

If Codex asks you to trust the startup hook again, trust it with `/hooks`.

Cursor:

```shell
git -C ~/.p3stack/repo pull
rm -rf ~/.cursor/plugins/local/p3stack ~/.cursor/plugins/local/p3stack-team-kit
cp -R ~/.p3stack/repo/p3stack ~/.cursor/plugins/local/p3stack
cp -R ~/.p3stack/repo/team-kit ~/.cursor/plugins/local/p3stack-team-kit
```

## Uninstall

```shell
curl -fsSL https://raw.githubusercontent.com/sandwichlegend/p3stack/main/install.sh | bash -s -- uninstall
```

It removes the plugins and the Cursor copies. It deletes your Codex `hooks.json` only when the file holds nothing but the p3stack hook it wrote. If you have other hooks there, it prints a prompt for your agent to remove just the p3stack entry.

By hand, Claude Code:

```shell
claude plugin uninstall p3stack@p3stack
claude plugin uninstall p3stack-team-kit@p3stack
claude plugin marketplace remove p3stack
```

Codex:

```shell
codex plugin remove p3stack@p3stack
codex plugin remove p3stack-team-kit@p3stack
codex plugin marketplace remove p3stack
```

Then delete the p3stack entry from `~/.codex/hooks.json`.

Cursor:

```shell
rm -rf ~/.cursor/plugins/local/p3stack ~/.cursor/plugins/local/p3stack-team-kit
```

Your model choices and run files stay in `~/.p3stack/`. The installer's uninstall removes the Cursor copy in `~/.p3stack/repo`, and by hand you can delete it too. Delete `~/.p3stack/` to remove everything.

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
- `scripts/ported.txt` lists upstream files outside the synced folders that p3stack copies, with the blob hash each copy matches and the part it ports.
- `scripts/check-docs.mjs` is upstream's docs check, pointed at `p3stack/`. It fails when `p3stack/README.md` or the guide drifts from the tree: a skill, playbook, or agent left out, a wrong count, a broken link or anchor, or a model setup-pstack doesn't use.

## Syncing with upstream

```shell
scripts/sync-upstream.sh
```

It fetches `cursor/plugins` into `refs/upstream/`, which are never pushed, and splits each upstream folder's history out with `git subtree split`. A split gives the same commits every run, so each sync is an ordinary subtree merge and only real edits conflict. The script keeps our plugin manifests when upstream bumps its version, keeps the paths in `scripts/removed.txt` deleted, and then runs `scripts/check.sh`. Before the checks, it stops if upstream changed a file in `scripts/ported.txt` or no longer has it. Its message says what to do, and step 4 of `scripts/sync-agent.md` covers both cases.

A clean merge can still bring Cursor-only instructions into a file we already ported. `scripts/check.sh` fails on any Cursor-only term in a file that `scripts/unported.txt` doesn't list, so a sync can't land until every new Cursor mechanic is rewritten for T3. Run `scripts/check.sh --terms` to see each hit.

[`scripts/sync-agent.md`](./scripts/sync-agent.md) is the prompt for an agent that runs the sync on a schedule and opens a pull request.

## Credit

pstack is Lauren Tan's, and the team-kit skills are Cursor's, both MIT. See [`p3stack/LICENSE`](./p3stack/LICENSE) and [`team-kit/LICENSE`](./team-kit/LICENSE).
