# Commit content editing uses a stopped-rebase session, not in-app diff editing

To let the user edit an older commit's changed lines (issue #5), we stop an app-driven
`rebase -i` at the target with an `edit` line, `reset --soft HEAD^`, and open the commit's
content as staged changes in the ordinary Changes view — a "Commit Edit Session" — instead of
building a separate in-app diff editor that rewrites the commit's tree directly. The session
reuses the existing staging UI (per-line unstage = remove from commit), the existing commit
composer (prefilled message, "Save Commit"), and the existing stopped-operation conflict flow
for descendant replays, at the cost of the app holding a long-lived mode persisted in
`.git/gital-edit-session.json` so a restart can restore the session. Saving recommits with the
original author and author date, stashes the removed changes, continues the rebase, and pops
the stash afterwards so removed changes return to the working copy rather than being discarded.

## Considered Options

- **In-app diff editing** (select lines to strip from the commit; the app computes the new
  tree and runs the whole rebase non-interactively, matching the existing exec-guarded todo
  style): no mode state, but limited to removing lines — no free-form edits or additions —
  and it duplicates staging UI semantics in a second code path.
- **Amend-on-top session** (stop at the commit without soft-reset; finish with
  `commit --amend`): simpler, but removing lines from the commit is not directly possible.

## Consequences

- HEAD edits also go through the rebase machinery (todo is a single `edit` line), so abort is
  always `rebase --abort`; the composer's existing Amend checkbox remains the fast path for
  message-only HEAD edits.
- A stopped rebase whose stop point is the session's `edit` line must be presented as a
  session, not as a generic stopped operation; the state file's phase field makes the
  distinction, and it is deleted as stale whenever `rebase-merge` is gone.
