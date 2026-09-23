# Gity

**A fast, native Git client for macOS.**

Gity is built entirely in SwiftUI for macOS. It covers the Git workflows developers use every day: reviewing changes, staging individual lines, committing, syncing with remotes, managing branches and rewriting history. Everything runs through your own `git` install, so your configuration, credentials, SSH keys and hooks work as they always do.

> **Status:** early development. Gity is usable day to day, but expect rough edges. Back up anything important before using history-rewriting features.

---

## Features

### Working copy and committing
- Changes, staged files and conflicts listed separately, each with a live diff
- Stage or unstage whole files with <kbd>Space</kbd>, or individual **hunks and lines** straight from the diff
- Commit composer with summary and description fields, a length guide and **Amend**
- Unfinished commit messages are saved per repository
- Discard changes to files, hunks or lines; new files go to the Trash, not straight to deletion
- Add untracked files to `.gitignore` by name, extension or folder, or stop tracking a file

### Remotes
- **Fetch**, **Pull** (merge or rebase) and **Push** from the toolbar
- Optionally stashes local changes before pulling, merging or rebasing and restores them afterwards
- First push lets you pick the remote and branch name and sets up tracking
- Force push always uses `--force-with-lease`
- Background fetching keeps ahead and behind counts current

### Branches and tags
- Create, rename and delete branches, optionally deleting the remote branch too
- Set or remove a branch's upstream
- Merge or rebase from the sidebar, or drag a branch onto the current one
- Create lightweight or annotated tags, push them and delete them locally or remotely

### History
- Commit history per branch, tag or the whole repository, with branch and tag labels
- Check out, branch or tag from any commit; cherry-pick, revert, or reset (soft, mixed or hard)
- **Edit messages, squash, delete and reorder commits**, from the context menu or the interactive rebase sheet
- **File history** that follows renames, and **blame** for the working copy or any commit
- **Reflog** browser for recovering lost commits and branches

### Safety
- **Undo (<kbd>⌘Z</kbd>)** for commits, amends, merges, pulls, rebases, resets, cherry-picks, reverts, and branch, tag and stash operations. Undo refuses to run if the branch has moved since, so it never throws away newer work.
- Confirmation before any operation that can't be undone
- A banner for merges, rebases, cherry-picks and reverts that stop on conflicts, with Continue, Skip and Abort, plus one-click "Resolve Using Mine / Theirs"
- Warns before rewriting commits that have already been pushed

### Navigation
- **Quick Open (<kbd>⇧⌘O</kbd>):** fuzzy search across recent repositories and every repository on your Mac, instantly
- Repository switcher in the toolbar that replaces the window's repository in place
- One window per repository, restored at launch
- Updates automatically when files change on disk

---

## Requirements

| | |
|---|---|
| **macOS** | 15 Sequoia or later |
| **Git** | Any recent version. Gity uses Homebrew's Git if installed, otherwise the Xcode Command Line Tools. A custom path can be set in Settings. |
| **Building** | Xcode 26 or later (Swift 6.2) |

## Getting started

```sh
git clone https://github.com/djam90/gity.git
cd gity
make app            # release build at build/Gity.app
open build/Gity.app
```

Move `build/Gity.app` to `/Applications` to keep it. Repositories can be opened from the welcome window, with <kbd>⌘O</kbd>, by dropping a folder on the Dock icon, or from the command line:

```sh
open -a Gity ~/code/my-project
```

## Keyboard shortcuts

| Action | Shortcut |
|---|---|
| Quick Open | <kbd>⇧⌘O</kbd> |
| Open Repository | <kbd>⌘O</kbd> |
| New Repository | <kbd>⌥⌘N</kbd> |
| Switch Repository | <kbd>⌥⌘O</kbd> |
| Working Copy / History / Reflog | <kbd>⌘1</kbd> / <kbd>⌘2</kbd> / <kbd>⌘3</kbd> |
| Stage or unstage selected files | <kbd>Space</kbd> |
| Discard selected files | <kbd>⌘⌫</kbd> |
| Commit | <kbd>⌘↩</kbd> |
| Fetch / Pull / Push | <kbd>⇧⌘F</kbd> / <kbd>⇧⌘P</kbd> / <kbd>⇧⌘U</kbd> |
| New Branch | <kbd>⇧⌘N</kbd> |
| Stash Changes | <kbd>⌥⌘S</kbd> |
| Undo / Redo last Git operation | <kbd>⌘Z</kbd> / <kbd>⇧⌘Z</kbd> |
| Refresh | <kbd>⌘R</kbd> |
| Show in Finder / Open in Terminal | <kbd>⇧⌘R</kbd> / <kbd>⌥⌘T</kbd> |

## Settings

- **General:** Git executable and recent repositories
- **Workflow:** whether Pull merges or rebases, whether local changes are stashed automatically, and how often to fetch in the background

---

## Development

```sh
make run     # debug build and launch
make test    # run the test suite
make clean   # remove build products
```

`Package.swift` also opens directly in Xcode. `scripts/build-app.sh` builds the app bundle with `swiftc` directly, so it can build without an Xcode project.

### Architecture

```
Sources/
├── GitKit/   UI-free Git layer: runs git, parses its output, builds patches, watches the file system
└── Gity/     SwiftUI app
    ├── App/            App entry point, menus, shared state
    ├── Repository/     Per-window model, operations, undo
    ├── Persistence/    Recent and discovered repositories
    ├── QuickOpen/      Quick Open panel
    └── Views/          Sidebar, history, diffs, sheets, settings
Tests/GitKitTests/      Parser unit tests and integration tests against real git
```

- **GitKit** runs the `git` command line tool through `Process` and parses machine-readable output (`status --porcelain=v2`, `for-each-ref` and `log` with custom formats, `blame --porcelain`). It has no UI dependencies and is covered by unit and integration tests.
- **Line staging** builds a patch from the selected lines and applies it with `git apply`, the same approach `git add -p` uses.
- **Interactive rebases** hand Git a prepared todo list through `GIT_SEQUENCE_EDITOR`, so no editor opens.
- **The app** uses `@Observable` models with main-actor default isolation (Swift 6 language mode). Each repository window has one model, and operations run one at a time.

### Data and privacy

Gity keeps everything on your Mac and makes no network requests of its own. Only Git contacts your remotes.

| Data | Location |
|---|---|
| Recent repositories | `~/Library/Application Support/com.gity.Gity/RecentRepositories.json`, with file bookmarks so moved repositories are still found |
| Repository index for Quick Open | `~/Library/Application Support/com.gity.Gity/DiscoveredRepositories.json` |
| Preferences and commit message drafts | `UserDefaults` (`com.gity.Gity`) |
| Open windows and sidebar state | macOS window restoration |

The repository index doesn't search Desktop, Documents, Downloads and other privacy-protected folders, so macOS never shows a permission prompt unexpectedly. A repository you open from one of those folders is still remembered.

The app isn't sandboxed: it needs to run `git`, which reads `~/.gitconfig`, SSH keys, credential helpers and hooks.

## Roadmap

- Word-level diff highlighting, side-by-side diffs, image diffs, syntax highlighting
- Sync button with ahead and behind counts in the toolbar
- Clone, worktrees and submodules
- Pull request integration
