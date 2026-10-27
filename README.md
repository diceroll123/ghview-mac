# GHView

A native macOS app for working through GitHub pull requests: what needs your review, what you have in flight, and what is ready to merge, across every organization and repository you care about.

It is built with SwiftUI and talks to GitHub through the [GitHub CLI](https://cli.github.com) (`gh`), so it uses your existing login. It has no server of its own and never handles your token: it only talks to GitHub, through `gh`, and loads avatars from github.com.

This is mostly for my day job where I work with many repos and lots of PRs across each, and it was largely slopped/slapped together. Mostly made it because the GitHub website is annoying/slow to navigate on large scales. It works for my use case, but rough edges exist. I'll tweak it toward general usefulness in my free time. Contributions are welcome!

## Requirements

- macOS 15 or later
- Xcode 16 or later (building needs full Xcode; the Command Line Tools lack the SwiftUI macro plugin)
- The GitHub CLI, signed in: `brew install gh`, then `gh auth login`

GHView works with github.com only. GitHub Enterprise hosts are not supported.

## Build and run

```sh
just app     # builds GHView.app from a release build
just run     # builds it and opens it
just build   # debug build
just test    # runs the test suite
```

Without `just`, `scripts/bundle.sh` builds the app bundle and `swift test` runs the tests.

## What it does

**Sidebar**

- **Inbox**: Needs your review, Needs your teams' review, Your drafts, Waiting for review or checks, Needs action, and Ready to merge, each with a count.
- **Views**: the built-in searches (Authored by me, Assigned to me, Involves me, Review requests) and your own saved searches. Selecting one puts its GitHub search in the filter box, and editing the text runs a new search.
- **Sources**: your user, your organizations (detected from your account) and any repositories you add by hand. Sources can be grouped, reordered by drag and drop, renamed, hidden and combined: Cmd or Shift-click several to browse them together.
- Anything at the top of the sidebar can be hidden and brought back from the View menu or Settings.

**Pull request list**

- A flat list with the repository, author and last update on each row, a checks icon, review and merge state, labels, and line changes.
- The filter box understands `author:`, `label:`, `reviewer:`, `review:`, `checks:`, `is:draft`, `base:`, `branch:` and `repo:`. `@me` stands for you.
- For a user or organization, a **Repos | PRs** segment switches between its pull requests and its repositories. Picking a repository keeps the list beside its PRs. Repositories are marked when they are private, archived or forks.
- Select several PRs with the checkboxes (or Cmd-A) and act on them together.

**Pull request detail**

- Overview with checks (failures first), reviewers, labels and the head commit hash; an Activity tab with comments, reviews and review threads, and a comment box that keeps your draft per PR; a Diff tab with syntax highlighting.

**Actions**

- Approve, Merge, Auto-merge, Rebase, Close, Reopen, Mark ready, and `@dependabot` commands.
- Merge and approve are pinned to the commit you were looking at. If the branch has moved since, nothing is merged or approved and you are asked to review again.
- Bulk merge and close ask for confirmation and list exactly what they will touch.
- The merge method (squash, merge commit, rebase) is your choice, and falls back to what each repository allows. Controls that cannot work for a selection are left out instead of shown disabled.

**Settings** (Cmd-comma)

- Show repositories under each source (off by default), hide archived repositories (off by default), and whether a right-click acts on just the PR you clicked or on all selected PRs.

## How it works

The project is a Swift package with two targets:

- `GHCore`: models, GraphQL and REST queries, filtering, the inbox rules, diff and Markdown parsing, and the `gh` process runner. It has no UI.
- `GHView`: the SwiftUI app and its state (`AppModel`).

Data comes from a few GraphQL queries per screen rather than many REST calls, and the app shows its remaining API budget in the sidebar footer. The `gh` runner can be replaced in tests, which is how the tests exercise loading, ordering and failure handling without touching the network.

## License

[MIT](LICENSE)
