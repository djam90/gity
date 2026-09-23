import GitKit

/// One step of undoing (or redoing) a git operation.
enum GitUndoStep {
    /// Moves the current branch from `from` to `to`. Refuses if `HEAD` is no longer at `from`,
    /// so an undo never throws away work done since.
    case moveHead(from: String, to: String, mode: ResetMode)
    /// Points a ref at an object, or deletes it when `object` is nil.
    case setRef(String, object: String?)
    case renameBranch(from: String, to: String)
    /// Switches to a branch, or detaches at a commit when `isDetached`.
    case switchTo(String, isDetached: Bool)
    /// Puts a dropped stash back.
    case storeStash(sha: String, message: String)
    /// Applies and removes the stash with this SHA, wherever it is in the list now.
    case popStash(sha: String)
    /// Drops the stash with this SHA.
    case dropStash(sha: String)
}

/// An undoable git operation, registered with the window's undo manager so Edit › Undo
/// (⌘Z) reverses commits, merges, resets, branch deletions and the like, as in Tower.
struct GitUndoRecord {
    /// Shown as "Undo <name>" in the Edit menu.
    let name: String
    let undo: [GitUndoStep]
    /// Empty when the operation can't be redone.
    let redo: [GitUndoStep]

    var reversed: GitUndoRecord {
        GitUndoRecord(name: name, undo: redo, redo: undo)
    }
}
