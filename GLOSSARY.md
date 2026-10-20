# Gital

A native macOS Git client. This glossary defines the domain language used in the app's UI, code, and design discussions.

## Language

**Commit Edit Session**:
A mode in which one commit is opened for editing — its message and its changed lines — and the app waits for the user to save or abort. Exactly one commit can be in a session at a time.
_Avoid_: edit mode, amend session

**Editable Commit**:
A commit that a Commit Edit Session can target: reachable from HEAD through a merge-free linear span, and not itself a merge commit. Pushed commits are editable after an explicit warning.

**Removed Changes**:
Changes the user takes out of the commit during a Commit Edit Session. They are not discarded; they return to the working copy once the session completes.
_Avoid_: dropped lines, discarded changes

**Stopped Operation**:
A git operation (merge, rebase, cherry-pick, revert) that has paused and needs the user to resolve conflicts, continue, or abort. A Commit Edit Session pauses a rebase deliberately, but is presented as a session, not as a Stopped Operation.
_Avoid_: pending operation (UI copy), in-progress operation
