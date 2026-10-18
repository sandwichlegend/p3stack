# p3stack upstream sync

Use this as the prompt of a T3 `schedule_task` on the p3stack project, such as `{"type":"fixed_time","timeOfDay":"06:00"}`. Each run ports one batch of upstream pstack changes and opens a pull request. It never pushes to `main`, because every commit on `main` is a release.

---

Sync p3stack with upstream `cursor/plugins` and open a pull request for review.

1. Read `p3stack/skills/poteto-mode/SKILL.md` in full, including its Subagents section, and follow it.
2. Start from a fresh worktree off `origin/main` on a branch named `sync/<YYYY-MM-DD>`. If a `sync/*` pull request is already open, stop and report its link. One sync is in flight at a time.
3. Run `scripts/sync-upstream.sh`. If it finishes with the checks passing and `git rev-list --count origin/main..HEAD` is 0, there is nothing to sync. Delete the branch and stop with a one-line report. Any commits on the branch mean a sync is in progress, so carry on through the remaining steps even when a rerun reports every folder up to date.
4. If it stops on conflicts, resolve each one by porting upstream's intent to T3, not by taking either side. The T3 mechanics are in poteto-mode's Subagents section. Commit with `git commit --no-edit` and run `scripts/sync-upstream.sh` again until it finishes. If it stops on a file listed in `scripts/ported.txt`, that line names the part of the upstream file p3stack ports. Handle the stop by its message, commit, and run `scripts/sync-upstream.sh` again:
   - **Changed.** Port any change to the named part, ignore the rest of the file, and set the line's hash to the one printed.
   - **Gone.** Upstream no longer has the path. Gather evidence before you change the line, with `$upstream`, `$there`, and `$blob` from the message:
     1. `git log --first-parent --no-patch --diff-merges=first-parent --diff-filter=D --format=%h $upstream -- $there` lists the commits on upstream's main line that removed it, merges included. If it lists nothing, upstream never had that path, so the path in the line is wrong. Run `git show --name-status -M --diff-merges=first-parent <hash>` on each to see what that commit renamed or added. `-M` pairs the removal with the closest added file, which can be an unchanged copy instead of the file upstream maintains.
     2. `git log --first-parent --diff-merges=first-parent --diff-filter=AR --name-status --format=%h <newest hash from step 1>..$upstream` lists files added or renamed on the main line after the removal, where a later successor would appear.
     3. `git grep -n -F <basename without extension> $upstream` finds files that still refer to it. Put one distinctive line from `git show $blob` in a file, with no blank lines, and run `git grep -n -F -f <that file> $upstream` to find where that content is now. A hit can be a stale copy, and no hit only means that line is gone.

     A path is a candidate only if `git cat-file -e $upstream:<path>` succeeds. Then decide. If upstream maintains the file at a new path, put that path in the line and keep the old hash, so the rerun diffs it against what p3stack ported. Never pick a path only because it still holds the old content. If the path in the line was wrong, fix it. If upstream deleted the file, drop the line and keep p3stack's copy. List every path change or dropped line under **Needs a human** with the evidence you used.
5. If `scripts/check.sh` reports Cursor-only terms, rewrite each hit for T3 (`scripts/check.sh --terms` lists them) and commit. Never add a file to `scripts/unported.txt` to silence the check.
6. Run the poteto-mode tests: `npx -y bun install --frozen-lockfile` and `npx -y bun test orch watch-pr check-plan.test.ts` in `p3stack/skills/poteto-mode/scripts`.
7. Flag, don't guess. When upstream changed how a workflow works rather than its wording, port your best reading and list it under **Needs a human** in the pull request body with the upstream commit and what you decided.
8. Run `/interrogate` on the branch diff against `origin/main`, with at least one reviewer from a lab other than yours. Fix what it confirms.
9. Push the branch and open the pull request per the Opening a PR playbook. The body lists each upstream commit merged, each conflict and how you ported it, and the **Needs a human** items. Link it with `link_pull_request`.
10. Don't merge it. Report the link.
