# p3stack upstream sync

Use this as the prompt of a T3 Code `schedule_task` on the p3stack project, such as `{"type":"fixed_time","timeOfDay":"06:00"}`. Each run ports one batch of upstream pstack changes and opens a pull request. It never pushes to `main`, because every commit on `main` is a release.

---

Sync p3stack with upstream `cursor/plugins` and open a pull request for review.

1. Read `p3stack/skills/poteto-mode/SKILL.md` in full, including its Subagents section, and follow it.
2. Start from a fresh worktree off `origin/main` on a branch named `sync/<YYYY-MM-DD>`. If a `sync/*` pull request is already open, stop and report its link. One sync is in flight at a time.
3. Run `scripts/sync-upstream.sh`. If it finishes with the checks passing and `git rev-list --count origin/main..HEAD` is 0, there is nothing to sync. Delete the branch and stop with a one-line report. Any commits on the branch mean a sync is in progress, so carry on through the remaining steps even when a rerun reports every folder up to date.
4. If it stops on conflicts, resolve each one by porting upstream's intent to T3 Code, not by taking either side. The T3 Code mechanics are in poteto-mode's Subagents section. Commit with `git commit --no-edit` and run `scripts/sync-upstream.sh` again until it finishes. If it stops on a file listed in `scripts/ported.txt`, that line names the part of the upstream file p3stack ports. Handle the stop by its message, commit, and run `scripts/sync-upstream.sh` again:
   - **Changed.** Port any change to the named part, ignore the rest of the file, and set the line's hash to the one printed.
   - **Gone.** Upstream no longer has the path. Gather evidence before you change the line, with `$upstream`, `$there`, and `$blob` from the message:
     1. `git log --first-parent --no-patch --diff-merges=first-parent --diff-filter=D --format=%h $upstream -- $there` lists the commits on upstream's main line that removed it, merges included. If it lists nothing, upstream never had that path, so the path in the line is wrong. Run `git show --name-status -M --diff-merges=first-parent <hash>` on each to see what that commit renamed or added. `-M` pairs the removal with the closest added file, which can be an unchanged copy instead of the file upstream maintains.
     2. `git log --first-parent --diff-merges=first-parent --diff-filter=AR --name-status --format=%h <newest hash from step 1>..$upstream` lists files added or renamed on the main line after the removal, where a later successor would appear.
     3. `git grep -n -F <basename without extension> $upstream` finds files that still refer to it. Put one distinctive line from `git show $blob` in a file, with no blank lines, and run `git grep -n -F -f <that file> $upstream` to find where that content is now. A hit can be a stale copy, and no hit only means that line is gone.

     A path is a candidate only if `git cat-file -e $upstream:<path>` succeeds. Then decide. If upstream maintains the file at a new path, put that path in the line and keep the old hash, so the rerun diffs it against what p3stack ported. Never pick a path only because it still holds the old content. If the path in the line was wrong, fix it. If upstream deleted the file, drop the line and keep p3stack's copy. List every path change or dropped line under **Needs a human** with the evidence you used.
5. If `scripts/check.sh` reports Cursor-only terms, rewrite each hit for T3 Code (`scripts/check.sh --terms` lists them) and commit. Never add a file to `scripts/unported.txt` to silence the check.
6. Run the poteto-mode tests: `npx -y bun install --frozen-lockfile` and `npx -y bun test orch watch-pr check-plan.test.ts` in `p3stack/skills/poteto-mode/scripts`. Then run the skill script tests from the repo root as CI does: `npm install --no-save fast-check@4.5.3` and `node --disable-warning=ExperimentalWarning --test p3stack/skills/*/scripts/test/*.test.ts`. Delete the `node_modules` folder that the install leaves.
7. Flag, don't guess. When upstream changed how a workflow works rather than its wording, port your best reading and list it under **Needs a human** in the pull request body with the upstream commit and what you decided.
8. Run `/interrogate` on the branch diff against `origin/main`, with at least one reviewer from a lab other than yours. Sort each confirmed finding by what it is about:
   - **The port.** A conflict resolution, a T3 Code rewrite, a `scripts/ported.txt` edit, or anything else this branch wrote. Fix it and commit.
   - **Upstream's own content.** Text or code the branch took from upstream unchanged, including a gap or a bug in what upstream wrote. p3stack ports upstream to T3 Code. It doesn't rewrite it. Don't commit a change for it, and don't let it hold up the sync. Record it as an FYI for step 10, with the upstream commit, the file, and what the reviewers flagged.

   If you can't tell which kind a finding is, run `git show refs/upstream/split/<folder>:<path>` on the file. A line that is there unchanged came from upstream.

   Treat a gap you find yourself in upstream's content the same way. It goes in the FYIs, not in **Needs a human**.
9. Push the branch and open the pull request per the Opening a PR playbook. The body lists each upstream commit merged, each conflict and how you ported it, and the **Needs a human** items. `scripts/check.sh` lists every subtree line that is in neither upstream's split nor `origin/main`, which means this branch wrote it. For each file on that list, add a line `` - `<file>`: <reason> `` to a `## Lines not from upstream` section, with a one-line reason such as the T3 Code rewrite or the conflict it resolves. CI fails the pull request until every file has a reason. If a file on the list holds a line that only changes upstream's meaning, drop that line instead of explaining it. Link the pull request with `link_pull_request`.
10. Don't merge it. Report the link, then list each FYI from step 8 under **FYI for a human**: the upstream commit, the file, and what the reviewers flagged. Leave the FYIs out of the pull request body, because they ask nothing of its reviewer.
