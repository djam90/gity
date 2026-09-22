# Gity

A native macOS Git client in SwiftUI, in the spirit of Tower.

## Iteration 1

- Welcome window with recent repositories, open (⌘O), create (⌥⌘N), drag and drop
- One window per repository, restored on relaunch; `open -a Gity <folder>` and Dock drops work
- Sidebar: Working Copy, History, local branches (nested by `/`), remotes, tags, stashes, filter
- Ahead/behind badges, current-branch marker, double-click or context menu to check out
- Commit history table with branch/tag decorations
- Auto-refresh through FSEvents, plus a refresh on app activation
- Fetch all remotes, Show in Finder, Open in Terminal

## Iteration 2: diffs

- Working Copy: staged, unstaged, untracked and conflicted files, each with its diff
- History: selecting a commit shows its message, author and changed files, with a per-file diff against the first parent
- Unified diff view with old/new line numbers, hunk headers, binary detection, and truncation of large diffs ("Show Full Diff")
- Diff options: ignore whitespace, context lines (1/3/10/25/entire file), remembered in UserDefaults

## Build

```sh
make run     # debug build and launch
make app     # release build -> build/Gity.app
make test    # GitKit unit tests (needs Xcode)
```

`Package.swift` also opens directly in Xcode.

## Architecture

- `Sources/GitKit`: UI-free git layer. Runs the `git` CLI through `Process`, parses porcelain and format output, and watches FSEvents. Unit tested.
- `Sources/Gity`: SwiftUI app with `@Observable` models and main-actor default isolation.

### Local data

- Recent repositories: `~/Library/Application Support/com.gity.Gity/RecentRepositories.json`. Written atomically, versioned, and stored with file bookmarks so moved or renamed repos are still found.
- Preferences (git path): `UserDefaults` through `@AppStorage`.
- Window/UI state (open repos, sidebar sections): SwiftUI scene restoration and `@SceneStorage`.

The app is not sandboxed, same as Tower and Fork: it shells out to `git`, which needs `~/.gitconfig`, SSH keys, credential helpers and hooks.

## Next

- Stage/unstage (file and hunk), commit
- Word-level highlighting, side-by-side mode, image diffs
- Branch create/rename/delete, merge, pull/push
