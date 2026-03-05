# git-split-commits.sh

Split the last **N commits** on your current branch into **N separate branches** (one commit per branch), while:

- Doing the **clean** cherry-picks first
- Deferring **conflict** cherry-picks until last
- Guiding you through conflict resolution **file-by-file**
- Reusing the **original commit messages** for the new per-commit branches

This is ideal when you accidentally stacked multiple changes on one branch and want to turn them into multiple PRs.

---

## What this tool is for

You have something like:

```

base ── A ── B ── C ── D   (your current branch, HEAD)

````

And you want:

- `topic/A` containing only commit `A` (on top of `base`)
- `topic/B` containing only commit `B` (on top of `base`)
- `topic/C` containing only commit `C` (on top of `base`)
- `topic/D` containing only commit `D` (on top of `base`)

So you can open 4 separate PRs.

---

## What this tool is not for

If you want to split a **single commit** into **multiple commits** while keeping the branch history rewritten and the final tree identical, use Tom Ellis' `split.sh` instead:

- `split.sh` (single-commit splitter): https://raw.githubusercontent.com/tomjaguarpaw/git-split/refs/heads/master/split.sh

In short:

- **This script (`git-split-commits.sh`)**: many commits → many branches
- **`split.sh`**: one commit → many commits (history rewrite in-place)

---

## Requirements

- bash
- git
- A clean working tree (no uncommitted or staged changes)
- A sensible base ref (e.g. `origin/main`, `origin/master`, or a custom base like `split-base`)

---

## Installation

Put the script somewhere in your repo or on your PATH:

```bash
chmod +x git-split-commits.sh
````

Optional: make it available as `git split-commits` by placing it on your PATH as `git-split-commits`:

```bash
cp git-split-commits.sh ~/bin/git-split-commits
chmod +x ~/bin/git-split-commits
```

Then you can run:

```bash
git split-commits -n 4 -b origin/main
```

---

## Usage

```bash
./git-split-commits.sh -n <N> [-b <base-ref>] [--prefix <name>] [--push] [--keep] [--no-editor]
```

### Options

* `-n <N>`
  Number of commits from `HEAD` to split into separate branches.

* `-b <base-ref>`
  The base to branch from (defaults to `origin/HEAD` if available, else `origin/main`, `origin/master`, `main`, `master`).

* `--prefix <name>`
  Prefix for branch names. Default: `split`
  Branches are created like: `prefix/<shortsha>-<slug-of-subject>`

* `--push`
  Push each created branch to `origin` and set upstream tracking.

* `--keep`
  Leave your current branch untouched (default behavior is also to leave it untouched; this flag exists to make intent explicit if you extend the script later).

* `--no-editor`
  Don’t open `$EDITOR` during conflict resolution. The script will instruct you to resolve in another terminal and then continue.

---

## Examples

### Split the last 4 commits into 4 branches, based on origin/main

```bash
./git-split-commits.sh -n 4 -b origin/main
```

### Push each branch after creation

```bash
./git-split-commits.sh -n 4 -b origin/main --push
```

### Use a custom base ref (recommended if your branch diverged a while back)

Create an explicit base pointer first:

```bash
git branch split-base <sha-or-ref>
```

Then:

```bash
./git-split-commits.sh -n 4 -b split-base --push
```

### Use a custom prefix for branch names

```bash
./git-split-commits.sh -n 4 --prefix pr --push
```

---

## How it works

1. Collects the last `N` commits from `HEAD` (oldest → newest).
2. For each commit:

   * Creates a new branch off `<base-ref>`.
   * Tries `git cherry-pick --no-commit <sha>` to see if it applies cleanly.
   * If clean:

     * Commits with the original message: `git commit -C <sha>`
3. Conflicting commits are queued.
4. Second pass:

   * Attempts each conflicting cherry-pick.
   * Lists conflicted files and walks you through resolving them file-by-file.
   * After staging resolved files, continues with `git cherry-pick --continue`.

---

## Conflict resolution flow

When a cherry-pick conflicts, the script will:

* Show conflicted files (`git diff --name-only --diff-filter=U`)
* For each file:

  * Show diff context
  * Open `$EDITOR` (unless `--no-editor`)
  * Ask whether to stage the file
* Repeat until all conflicts are resolved
* Run `git cherry-pick --continue`

Tip: If you prefer a mergetool, you can swap the editor step with:

```bash
git mergetool -- "$file"
```

---

## Commit message reuse and authorship

For branches that cherry-pick cleanly, the script uses:

```bash
git commit -C <sha>
```

This reuses the original commit message. Cherry-pick preserves the original author by default.

For conflict cases, `git cherry-pick --continue` uses the original message unless you edit it.

---

## Safety notes

* The script refuses to run with a dirty working tree.
* It does not rewrite your current branch unless you explicitly do so afterward.
* If you later decide to remove the last `N` commits from your current branch, do it manually (and force-push only if you understand the impact):

```bash
git reset --hard <base-ref>
git push --force-with-lease
```

---

## Related tool for splitting a single commit into multiple commits

If your use case is: “I have one giant commit and want to split it into several commits while keeping the branch consistent,” use:

* `split.sh`: [https://raw.githubusercontent.com/tomjaguarpaw/git-split/refs/heads/master/split.sh](https://raw.githubusercontent.com/tomjaguarpaw/git-split/refs/heads/master/split.sh)

That tool is designed for interactive splitting of a **single** commit inside a branch and includes strong correctness checks to ensure the final state matches the original history.

---

## License

MIT
