# p3stack upstream sync

Use this as the prompt of a T3 `schedule_task` on the p3stack project, such as `{"type":"fixed_time","timeOfDay":"06:00"}`. Each run ports one batch of upstream pstack changes and opens a pull request. It never pushes to `main`, because every commit on `main` is a release.

---

Sync p3stack with upstream `cursor/plugins` and open a pull request for review.

1. Read `p3stack/skills/poteto-mode/SKILL.md` in full, including its Subagents section, and follow it.
2. Start from a fresh worktree off `origin/main` on a branch named `sync/<YYYY-MM-DD>`. If a `sync/*` pull request is already open, stop and report its link. One sync is in flight at a time.
3. Run `scripts/sync-upstream.sh`. If it finishes with the checks passing and `git rev-list --count origin/main..HEAD` is 0, there is nothing to sync. Delete the branch and stop with a one-line report. Any commits on the branch mean a sync is in progress, so carry on through the remaining steps even when a rerun reports every folder up to date.
4. If it stops on conflicts, resolve each one by porting upstream's intent to T3, not by taking either side. The T3 mechanics are in poteto-mode's Subagents section. Commit with `git commit --no-edit` and run `scripts/sync-upstream.sh` again until it finishes.
5. If `scripts/check.sh` reports Cursor-only terms, rewrite each hit for T3 (`scripts/check.sh --terms` lists them) and commit. Never add a file to `scripts/unported.txt` to silence the check.
6. Run the poteto-mode tests: `npx -y bun install --frozen-lockfile` and `npx -y bun test orch watch-pr check-plan.test.ts` in `p3stack/skills/poteto-mode/scripts`.
7. Flag, don't guess. When upstream changed how a workflow works rather than its wording, port your best reading and list it under **Needs a human** in the pull request body with the upstream commit and what you decided.
8. Run `/interrogate` on the branch diff against `origin/main`, with at least one reviewer from a lab other than yours. Fix what it confirms.
9. Push the branch and open the pull request per the Opening a PR playbook. The body lists each upstream commit merged, each conflict and how you ported it, and the **Needs a human** items. Link it with `link_pull_request`.
10. Don't merge it. Report the link.
