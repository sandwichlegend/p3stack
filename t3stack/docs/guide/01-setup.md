# Set up pstack

In this page you install the plugin, pick which models pstack uses, and run your first task. Setup is one command plus a short conversation.

## Install the plugin

t3stack runs inside [T3 Code](https://github.com/pingdotgg/t3code). T3 drives Claude Code, Codex, and Cursor, and each of them loads plugins its own way, so install the `t3stack` and `t3stack-team-kit` plugins into every provider you use. The [repository README](https://github.com/sandwichlegend/t3stack#install) has the commands. A delegated agent runs on whichever provider its role names, so a provider without the plugin still works for subagents, because every brief names the skill files by path.

## Pick your models

Run:

```text
/setup-pstack
```

[`/setup-pstack`](../../skills/setup-pstack/SKILL.md) detects the models you have access to, asks for a reasoning budget, shows you each role (code delegates, judgment, the review panels), and asks what you want. Answer the questions. It writes `~/.t3stack/models.md`, a small file every t3stack skill reads. It also tells you which providers T3 can't run right now, such as one that isn't signed in.

The defaults run at `xhigh` reasoning, the same as the `large` budget. Code goes to Grok through Cursor, with GPT through Codex as the fallback. Prose and judgment go to Claude Opus. Every review panel seats Claude, GPT, and Grok, one model from each of three labs, because models from different labs miss different things. `unlimited` lifts each model to its highest tier, up to `max`. Grok tops out at `xhigh`, so it stays there. `medium` and `small` lower the reasoning and spend fewer tokens.

You only override what you care about. A role with no line in the file keeps the default. To restore a default, delete that role's line. A rerun of `/setup-pstack` keeps any seat you changed. When a default changes, a file written before the change still pins the old default, so delete those role lines, or delete the file, then run `/setup-pstack` again.

A seat reads `model@effort`, with `+fast` for fast mode and `|` between fallbacks. Set a role to `inherit` to run it on your chat's own model. For a panel role the value is a list, and one subagent runs per seat, so the list length sets the panel size. If a seat's provider can't run, the panel fills it from a lab it doesn't seat yet and says so. Setup also configures `swarm workers`, the default for every `/swarm` worker unless a race names a model for each arm, and `max parallel writers`, how many worktree agents may run at once on your machine.

## Accept the verification offer, or don't

At the end of setup, `/setup-pstack` looks for a way to prove app behavior in your project, either a `verify-*` skill or an existing harness. If it finds neither, it offers once to generate one with [`/create-verification-skill`](../../skills/create-verification-skill/SKILL.md).

Say yes and it writes `.agents/skills/verify-<app>/`, linked into `.claude/skills/` and `.cursor/skills/`, a project-local skill that teaches agents to drive your app the way a user does. It proves the skill works once before handing it over. Say no and setup moves on. You can run `/create-verification-skill` yourself any time. [Verify and ship](./06-verify-and-ship.md#create-a-project-verification-skill) covers it in depth.

If you're new to pstack, say yes. An agent that can check its own work keeps going until the check passes. An agent that can't hands every result back to you to check by hand. Of everything in this guide, the verification skill pays off the most.

The model file applies to the next spawn. No restart needed.

## Keep the cost in check

pstack spends extra tokens on subagents and review panels. That's the price of the rigor. To spend fewer:

- Rerun `/setup-pstack` and pick a smaller reasoning budget or cheaper models. A strong model in the main chat with cheaper, faster models in the code roles is a good split.
- Set a role to `inherit` so it runs on the chat's own model.
- Shorten a panel list. Each seat runs one subagent.
- Lower `max parallel writers` if your machine bogs down. Every agent runs locally.
- Save `/poteto-mode` for work that needs rigor. A small, obvious edit doesn't.

## Run your first task

Pick something real but small, and describe it the way you'd describe it to a colleague:

```text
/poteto-mode add a --json flag to this command. text output stays byte-identical. verify both.
```

Watch the todo list. Its first items are the matched playbook's steps copied in, the Feature playbook for this prompt. If `/poteto-mode` skips a step, the step stays in the list with `skip: <reason>`, so you can see what it chose not to do.

From here you can type normal follow-ups. In Claude Code and Codex threads, the t3stack session hook tells the agent to read `/poteto-mode` for every non-trivial engineering task, so it stays on without retyping. Cursor threads don't run the hook, so start each new task there with `/poteto-mode`.

Next: [Route work through `/poteto-mode`](./02-poteto-mode.md).
