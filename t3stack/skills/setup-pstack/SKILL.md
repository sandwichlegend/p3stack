---
name: setup-pstack
description: Configure which models t3stack uses per role and at what reasoning budget. Reads the models T3 Code can run and writes ~/.t3stack/models.md, which overrides the skill defaults. Use for /setup-pstack, "configure pstack models", "pstack budget", or changing pstack's model choices.
---

# Setup pstack

Write `~/.t3stack/models.md`, the file every t3stack skill reads to pick a model per role. The seat format and how a seat becomes a `delegate_task` target are in the Roles and models section of the **poteto-mode** skill (`../poteto-mode/SKILL.md`). Read it first.

## Steps

### 1. Detect available models

Call `orchestrator_capabilities` from the `t3-code` MCP server. Every model in a provider's `models` list is a candidate, and it is runnable when that provider's `canRunChildTask` is true. Note each provider whose `constraints` explain why it can't run tasks, such as "Provider is not authenticated", so you can tell the user. Never write a model id the catalog didn't list. `inherit` is always valid.

### 2. Load current state

The defaults are the file shape in step 5. If `~/.t3stack/models.md` exists, read it and treat its `# budget` line, its role lines, and its `max parallel writers` line as the current choices. Otherwise start from the defaults. A line whose role is not in step 5 is from a retired role. Drop it.

### 3. Budget, map, and confirm

**(a) Ask for a budget.** Use the session's structured question tool when it has one. Offer these four options with these exact labels, and name the current budget when the file records one. With no file, say that `large` matches the defaults.

- `unlimited — max reasoning`
- `large — xhigh reasoning`
- `medium — high reasoning`
- `small — medium reasoning`

**(b) Apply it.** Build the working table from the defaults, and on a re-run keep any seat the user changed. `unlimited`, `large`, `medium`, and `small` set the effort of every seat, fallbacks and panel seats included, to `max`, `xhigh`, `high`, or `medium`. A model that doesn't offer the level runs at the highest level it offers below it, so `unlimited` leaves Grok at `xhigh`. `inherit` seats don't change.

**(c) Show the roles and confirm.** Show every role with its seats. Mark a seat whose model isn't runnable right now, and name the provider constraint that blocks it. A blocked seat still falls back at spawn time, so it is a warning, not an error. Also list each line step 2 dropped. Ask whether to accept as-is or change specific roles, offering the runnable models plus `inherit` (this role runs on the parent chat's model). For panel roles (`arena runners`, `arena cross-judge pool`, `architect runners`, `interrogate reviewers`) the value is a list, and one agent runs per seat, so the list length sets the count. Seat models from different labs, because labs make a panel diverse. `arena cross-judge pool` is also a list, but Arena picks one seat from it whose lab differs from the parent's when possible. `swarm workers` is the default model for every worker unless a race or comparison assigns another model per arm. Ask for `max parallel writers` too, the cap on worktree agents running at once on this machine.

### 4. Validate

Every model in a seat must appear in the step 1 catalog under some provider. `inherit` always passes. If a chosen model isn't in the catalog, stop and ask again.

### 5. Write the file

Write `~/.t3stack/models.md` with a `# budget` line naming the chosen label and its effort, one line per role using the labels poteto-mode uses, and a `max parallel writers` line. Overwrite the whole file so re-runs stay idempotent. Create `~/.t3stack/` if it is missing. Shape:

```
# t3stack model configuration. One line per role. Delete a line to fall back to the default.
# A seat is model@effort, +fast for fast mode, | between fallbacks. Commas separate panel seats. inherit runs on the parent model.
# budget: large (xhigh)
feature, refactoring: grok-4.7@xhigh | gpt-6.1-sol@xhigh
bug-fix: grok-4.7@xhigh | gpt-6.1-sol@xhigh
perf-issue: grok-4.7@xhigh | gpt-6.1-sol@xhigh
hillclimb: grok-4.7@xhigh | gpt-6.1-sol@xhigh
judgment and prose: claude-opus-5-5@xhigh | gpt-6.1-sol@xhigh
hardest tasks: claude-opus-5-5@xhigh | gpt-6.1-sol@xhigh
how explorer: grok-4.7@xhigh | gpt-6.1-sol@xhigh
how explainer: claude-opus-5-5@xhigh | gpt-6.1-sol@xhigh
why investigators: grok-4.7@xhigh | gpt-6.1-sol@xhigh
why synthesizer: claude-opus-5-5@xhigh | gpt-6.1-sol@xhigh
reflect tooling: grok-4.7@xhigh | gpt-6.1-sol@xhigh
reflect judgment, divergent, synthesizer: claude-opus-5-5@xhigh | gpt-6.1-sol@xhigh
arena runners: claude-opus-5-5@xhigh, gpt-6.1-sol@xhigh, grok-4.7@xhigh
arena cross-judge pool: claude-opus-5-5@xhigh, gpt-6.1-sol@xhigh, grok-4.7@xhigh
swarm workers: grok-4.7@xhigh+fast | gpt-6.1-sol@xhigh+fast
architect runners: claude-opus-5-5@xhigh, gpt-6.1-sol@xhigh, grok-4.7@xhigh
interrogate reviewers: claude-opus-5-5@xhigh, gpt-6.1-sol@xhigh, grok-4.7@xhigh
max parallel writers: 4
```

### 6. Confirm

Tell the user the file was written, that every new spawn reads it, and which seats are blocked right now and why. Re-running this skill updates it.

### 7. Offer a verification skill (optional)

Check whether the project has a way to drive the real app for proof (a `verify-*` skill, or an existing harness). If not, offer once: "want a project-local verification skill, so agents can drive the app the way a user does and prove changes work? I can generate one with /create-verification-skill." On yes, invoke `/create-verification-skill`. On no, move on without pushing.
