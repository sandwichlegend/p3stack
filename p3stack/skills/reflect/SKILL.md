---
name: reflect
description: Spawn three parallel review subagents over the active T3 Code thread, surface learnings, and route each to a concrete edit on an existing skill. Use when the user says reflect.
disable-model-invocation: true
---

# Reflect

Mine the current conversation for durable learnings, then route them into skill edits.

Invoke when the user says "reflect" or "/reflect". Skip when the conversation is trivial, off-topic, or already covered by an existing skill the parent followed correctly. One-offs are not learnings.

## 1. Locate the active thread

Before fanning out, get this conversation's T3 Code thread id. `orchestrator_capabilities` returns it as `parentThreadId`. Reviewers read the thread with `t3_thread_read` and `view: "activity"`, which includes tool calls, and page with `afterPosition`. The thread's delegated tasks are threads too. Stay inside this thread and the tasks it spawned. Other threads are private chats from other work. If the thread can't be read, pass a tight digest of the session instead.

## 2. Spawn three reviewers in parallel

One message, three `delegate_task` calls with `role: "review"` and `mode: "async"`. Reviewers keep their provider's MCP servers, which they need to look up the tickets, chat threads, and observability traces the thread references.

Each reviewer and the synthesizer name a role. Resolve each role's seat and target per the Roles and models section of the **poteto-mode** skill, and pick each agent's effort and speed for the job there too.

| Lens | Role | Prompt template |
|---|---|---|
| Judgment | `reflect judgment, divergent, synthesizer` | `references/judgment-reviewer.md` |
| Tooling | `reflect tooling` | `references/tooling-reviewer.md` |
| Divergent | `reflect judgment, divergent, synthesizer` | `references/divergent-reviewer.md` |

Pass each template verbatim, substituting the thread id or digest where marked. Reviewers return findings as their task result.

## 3. Synthesize

One `delegate_task` with `role: "review"` on the `reflect judgment, divergent, synthesizer` role. It spot-verifies citations through MCP. Pass `references/synthesizer.md` verbatim, with each reviewer's full output inlined where marked. It returns an Accepted / Rejected / Backlog list.

## 4. Structural enforcement check

Move any Accepted item that a lint rule, script, metadata flag, or runtime check would enforce more reliably to Backlog. See the **encode-lessons-in-structure** principle skill.

## 5. Apply

Present the synthesizer's full Accepted / Rejected / Backlog output and wait for explicit approval before applying any Accepted edit. The user picks the subset and may redirect routings. Skill changes affect every future agent in the org. Do not auto-apply.

File each Backlog item to your team's devex or backlog tracker without waiting. Only the Accepted list waits for approval.

Never edit a skill inside an installed plugin, under `~/.claude/plugins/`, `~/.codex/plugins/`, `~/.cursor/plugins/`, or `~/.cache/opencode/npm/`. Before approval, show its destination, `.agents/skills/<skill>/` or `~/.agents/skills/<skill>/`. After approval, copy the skill folder there, link it into the other providers' folders where the Subagents section of **poteto-mode** puts new skills, and edit the copy. Never open a PR or push.

Follow each approved row's Routing exactly:

- Trivial existing-skill edit (a one-line bullet, a tightened sentence, a stale fact corrected): the parent does it directly.
- Substantive existing-skill edit (a new section, a new pattern table, more than ~10 lines): run the **poteto-mode** skill's Authoring a skill playbook (`../poteto-mode/playbooks/authoring-a-skill.md`), including its test loop.
- `tune description: <skill path>` (the skill exists but didn't trigger when it should have): run the same playbook's description steps.
- `new skill: <kebab-name>`: create it through the same playbook. Do not invent the shape ad hoc. Write it where the Subagents section of **poteto-mode** puts new skills.

If your environment ships a SKILL.md validator, run it on every touched skill before declaring done.

## 6. Summarize for the user

Short list, no preamble:

- Edits applied: `<skill path>`. What changed, one line each.
- New skills created: `<skill path>`. One line each (rare).
- Backlog filed to the devex tracker: `<issue title>` (`<tags>`). One line each.
- Dropped: one line per rejected finding + reason from the synthesizer.
