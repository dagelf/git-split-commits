#!/usr/bin/env bash
# split-commits.sh
# Split the last N commits on the current branch into N separate branches.
# First pass: do the ones that cherry-pick cleanly.
# Second pass: do the ones that conflict, and step you through each conflicted file.

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  split-commits.sh -n <N> [-b <base-ref>] [--prefix <name>] [--push] [--keep] [--no-editor]

Examples:
  ./split-commits.sh -n 4
  ./split-commits.sh -n 4 -b origin/main --prefix split --push
  ./split-commits.sh -n 12 --keep   # leave your current branch untouched

What it does:
  - Takes the last N commits from HEAD (oldest -> newest)
  - Creates a new branch per commit off <base-ref>
  - Cherry-picks each commit
    - If it applies cleanly: commits branch immediately
    - If it conflicts: defers it
  - Then processes deferred commits, walking you file-by-file to resolve conflicts
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

need_clean_tree() {
  if ! git diff --quiet || ! git diff --cached --quiet; then
    die "working tree has changes; commit/stash them first"
  fi
  if [[ -n "$(git ls-files -u)" ]]; then
    die "index has unmerged entries; resolve/abort first"
  fi
  if [[ -d "$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null)" ]]; then
    # not reliable as a dir; check file existence:
    true
  fi
  if git rev-parse -q --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
    die "a cherry-pick is in progress; run 'git cherry-pick --abort' first"
  fi
}

default_base_ref() {
  # Prefer origin/HEAD if available; otherwise origin/main; otherwise origin/master; otherwise main/master.
  local ref=""
  ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [[ -n "$ref" ]]; then
    echo "$ref"
    return
  fi
  for cand in origin/main origin/master main master; do
    if git rev-parse -q --verify "$cand" >/dev/null 2>&1; then
      echo "$cand"
      return
    fi
  done
  die "could not determine base ref; pass -b <base-ref>"
}

slugify() {
  # Make a safe-ish branch suffix from commit subject
  # shellcheck disable=SC2001
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' \
    | cut -c1-50
}

branch_for_commit() {
  local prefix="$1" sha="$2"
  local subj slug short
  short="$(git rev-parse --short "$sha")"
  subj="$(git show -s --format=%s "$sha")"
  slug="$(slugify "$subj")"
  echo "${prefix}/${short}-${slug}"
}

resolve_conflicts_file_by_file() {
  local no_editor="$1"
  while true; do
    mapfile -t files < <(git diff --name-only --diff-filter=U)
    if (( ${#files[@]} == 0 )); then
      break
    fi

    echo
    echo "Conflicted files:"
    for f in "${files[@]}"; do echo "  - $f"; done
    echo

    for f in "${files[@]}"; do
      echo "---- $f ----"
      echo "Showing conflict hunks (if any):"
      git --no-pager diff -- "$f" || true
      echo

      if [[ "$no_editor" != "1" ]]; then
        "${EDITOR:-vi}" "$f"
      else
        echo "(no editor) Edit '$f' in another terminal, then return here."
      fi

      # After editing, ensure markers are gone (optional but helpful)
      if git --no-pager grep -n '<<<<<<<\|=======\|>>>>>>>' -- "$f" >/dev/null 2>&1; then
        echo "Conflict markers still present in $f. Please finish resolving it."
      else
        echo "No conflict markers detected in $f."
      fi

      while true; do
        read -r -p "Stage this file now? [y/n/v] (v = view diff again) " ans
        case "${ans:-}" in
          y|Y)
            git add -- "$f"
            break
            ;;
          v|V)
            git --no-pager diff -- "$f" || true
            ;;
          n|N|'')
            echo "Leaving $f unstaged for now."
            break
            ;;
          *)
            echo "Please answer y, n, or v."
            ;;
        esac
      done
      echo
    done

    echo "Current status:"
    git status --short
    echo

    # If everything conflicted is staged, we can continue; otherwise loop again.
    if (( $(git diff --name-only --diff-filter=U | wc -l | tr -d ' ') == 0 )); then
      break
    fi

    echo "Some conflicts remain. Continuing the loop."
  done
}

push_branch() {
  local branch="$1"
  git push -u origin "$branch"
}

# ---------------- args ----------------
N=""
BASE=""
PREFIX="split"
DO_PUSH="0"
KEEP_ORIG="0"
NO_EDITOR="0"

while (( $# )); do
  case "$1" in
    -n) N="${2:-}"; shift 2;;
    -b) BASE="${2:-}"; shift 2;;
    --prefix) PREFIX="${2:-}"; shift 2;;
    --push) DO_PUSH="1"; shift;;
    --keep) KEEP_ORIG="1"; shift;;
    --no-editor) NO_EDITOR="1"; shift;;
    -h|--help) usage; exit 0;;
    *) die "unknown arg: $1 (try --help)";;
  esac
done

[[ -n "${N}" ]] || { usage; die "missing -n <N>"; }
[[ "${N}" =~ ^[0-9]+$ ]] || die "-n must be an integer"
(( N > 0 )) || die "-n must be > 0"

need_clean_tree

if [[ -z "$BASE" ]]; then
  BASE="$(default_base_ref)"
fi
git rev-parse -q --verify "$BASE" >/dev/null 2>&1 || die "base ref not found: $BASE"

ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
BASE_COMMIT="$(git rev-parse "$BASE")"

# Get last N commits from HEAD, oldest -> newest
mapfile -t COMMITS < <(git rev-list --reverse "HEAD~${N}..HEAD")

if (( ${#COMMITS[@]} != N )); then
  die "expected $N commits, found ${#COMMITS[@]} (are there at least $N commits on this branch?)"
fi

echo "Base ref:     $BASE ($BASE_COMMIT)"
echo "From branch:  $ORIG_BRANCH"
echo "Splitting N:  $N commits"
echo "Prefix:       $PREFIX"
echo

# Ensure we have a base anchor (optional but nice)
BASE_ANCHOR="${PREFIX}-base"
if ! git rev-parse -q --verify "$BASE_ANCHOR" >/dev/null 2>&1; then
  git branch "$BASE_ANCHOR" "$BASE"
fi

# First pass: try cherry-pick --no-commit to detect conflicts and defer them
CLEAN=()
CONFLICTING=()

for sha in "${COMMITS[@]}"; do
  b="$(branch_for_commit "$PREFIX" "$sha")"
  echo "==> Preparing $b from $BASE"
  git switch --quiet -c "$b" "$BASE"

  set +e
  out="$(git cherry-pick --no-commit "$sha" 2>&1)"
  rc=$?
  set -e

  if (( rc == 0 )); then
    if git diff --cached --quiet; then
      echo "    SKIP (empty on base)"
      CLEAN+=("$sha:$b:skipped")
    else
      author="$(git show -s --format='%an <%ae>' "$sha")"
      author_date="$(git show -s --format='%aI' "$sha")"
      committer_date="$(git show -s --format='%cI' "$sha")"

      GIT_AUTHOR_DATE="$author_date" \
      GIT_COMMITTER_DATE="$committer_date" \
        git commit -C "$sha" --author="$author" >/dev/null

      echo "    OK (clean)"
      CLEAN+=("$sha:$b")
      if [[ "$DO_PUSH" == "1" ]]; then
        push_branch "$b" >/dev/null
        echo "    pushed"
      fi
    fi
  else
    # Only defer real conflicts; otherwise stop with the error.
    if grep -qiE 'conflict|merge conflict' <<<"$out"; then
      echo "    CONFLICT (defer)"
      git cherry-pick --abort >/dev/null 2>&1 || true
      CONFLICTING+=("$sha:$b")
    else
      echo "    ERROR (not a conflict): $sha"
      echo "$out" >&2
      exit 1
    fi
  fi
done

echo
echo "First pass complete."
echo "  Clean:      ${#CLEAN[@]}"
echo "  Conflicts:  ${#CONFLICTING[@]}"
echo

# Second pass: do conflicting ones last and guide resolution per file
for item in "${CONFLICTING[@]}"; do
  sha="${item%%:*}"
  b="${item#*:}"
  echo "==> Resolving $b (commit $sha)"
  git switch --quiet -c "$b" "$BASE" || git switch --quiet "$b"

  # Start real cherry-pick (will stop on conflicts)
  set +e
  git cherry-pick "$sha"
  rc=$?
  set -e

  if (( rc == 0 )); then
    echo "    unexpectedly clean on second pass"
  else
    echo "    conflicts detected; entering guided resolution"
    resolve_conflicts_file_by_file "$NO_EDITOR"
    git cherry-pick --continue
    echo "    resolved and committed"
  fi

  if [[ "$DO_PUSH" == "1" ]]; then
    push_branch "$b" >/dev/null
    echo "    pushed"
  fi
done

# Return to original branch, optionally reset it back to base
git switch --quiet "$ORIG_BRANCH"

if [[ "$KEEP_ORIG" != "1" ]]; then
  echo
  echo "Note: leaving original branch unchanged."
  echo "If you want to drop the last $N commits from '$ORIG_BRANCH', run:"
  echo "  git reset --hard $BASE"
  echo "  git push --force-with-lease   # if '$ORIG_BRANCH' is on origin"
fi

echo
echo "Done. Created branches:"
for sha in "${COMMITS[@]}"; do
  echo "  - $(branch_for_commit "$PREFIX" "$sha")"
done
