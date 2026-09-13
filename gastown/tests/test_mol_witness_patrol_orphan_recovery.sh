#!/usr/bin/env bash
set -euo pipefail

# Executed coverage for the Step 3 "did this branch land?" test in
# mol-witness-patrol's `recover-orphaned-beads`.
#
# That test decides between force-closing an orphaned bead (terminal) and
# returning it to the pool (re-dispatch).  It was previously wrong in both
# directions: it grepped commit subjects of a stale LOCAL `main` for the branch
# name, and its ancestry fallback cannot see a rebase or squash landing.
# Contract pins in scripts/gascity_pack_inference_gate.py catch deletion of the
# guards; this file catches them being kept but broken.
#
# Ported from gastownhall/gascity-packs 05031f2 (#320), Step 3 cases only: the
# Step 1/2a liveness half of that change is not in this tree.
#
# The block is LIFTED out of the formula and executed, not transcribed.  A
# transcription is a second copy that drifts silently from the recipe that
# actually runs, which is the failure mode this whole area already has.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FORMULA="$ROOT/gastown/formulas/mol-witness-patrol.toml"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

STEP3="$tmp/step3-on-main.sh"
ERRLOG="$tmp/stderr.log"
: >"$ERRLOG"

fail() {
    echo "FAIL: $*" >&2
    if [ -s "$ERRLOG" ]; then
        echo "--- captured stderr ---" >&2
        tail -n 20 "$ERRLOG" >&2
    fi
    exit 1
}

# lift_block <sentinel> <dest> -- extract the fenced ```bash block containing
# <sentinel>.  `<bead>` is the formula's placeholder for the bead id; in shell
# it would parse as a redirect, so it is substituted mechanically.
lift_block() {
    local sentinel="$1" dest="$2"
    awk -v want="$sentinel" '
        /^[[:space:]]*```bash[[:space:]]*$/ { inblk = 1; body = ""; next }
        inblk && /^[[:space:]]*```[[:space:]]*$/ {
            inblk = 0
            if (index(body, want)) { printf "%s", body; found = 1 }
            body = ""
            next
        }
        inblk { body = body $0 "\n"; next }
        END { exit(found ? 0 : 1) }
    ' "$FORMULA" | sed 's/<bead>/TESTBEAD/g' >"$dest" ||
        fail "no fenced bash block in $FORMULA contains: $sentinel"
    [ -s "$dest" ] || fail "lifted an empty block for: $sentinel"
    bash -n "$dest" || fail "lifted block does not parse: $sentinel"
}

lift_block 'merge-base --is-ancestor' "$STEP3"

new_repo() {
    REPO="$tmp/repo-$1"
    ORIGIN="$tmp/repo-$1.git"
    git init -q --bare -b main "$ORIGIN"
    git init -q -b main "$REPO"
    git -C "$REPO" config user.name "Witness Patrol Test"
    git -C "$REPO" config user.email "witness@example.invalid"
    git -C "$REPO" remote add origin "$ORIGIN"
    printf 'baseline\n' >"$REPO/README.md"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m baseline
    git -C "$REPO" push -q origin main
}

# commit_branch <branch> <file>...
commit_branch() {
    local branch="$1"
    shift
    git -C "$REPO" checkout -q -b "$branch" main
    local f
    for f in "$@"; do
        printf 'branch work\n' >"$REPO/$f"
    done
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "work on $branch"
    git -C "$REPO" push -q origin "$branch"
    git -C "$REPO" checkout -q main
}

# add_branch_commit <branch> <file>
add_branch_commit() {
    git -C "$REPO" checkout -q "$1"
    printf 'more work\n' >"$REPO/$2"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "more work on $1"
    git -C "$REPO" push -q origin "$1"
    git -C "$REPO" checkout -q main
}

# advance_main [subject]
advance_main() {
    printf 'unrelated\n' >>"$REPO/README.md"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "${1:-unrelated main commit}"
    git -C "$REPO" push -q origin main
}

land_merge() {
    git -C "$REPO" merge -q --no-ff -m "merge $1" "$1"
    git -C "$REPO" push -q origin main
}

land_rebase() {
    # Replays the branch's commits onto a moved main: same content, new SHAs,
    # so ancestry can never see the landing.
    git -C "$REPO" cherry-pick "origin/main..origin/$1" >/dev/null 2>&1 ||
        fail "cherry-pick of $1 onto main failed"
    git -C "$REPO" push -q origin main
}

land_squash() {
    git -C "$REPO" merge --squash "$1" >/dev/null 2>&1
    git -C "$REPO" commit -q -m "squashed $1"
    git -C "$REPO" push -q origin main
}

# run_on_main <branch>
# `set +eu` because the recipe is executed by an agent in a plain shell, not
# under strict mode -- testing it stricter than it ships would measure the
# wrong thing.
run_on_main() {
    ON_MAIN=$(
        set +eu
        cd "$REPO" || exit 1
        BRANCH="$1"
        ON_MAIN=
        { . "$STEP3"; } >>"$ERRLOG" 2>&1
        printf '%s' "$ON_MAIN"
    )
}

assert_on_main() {
    local expected="$1" label="$2"
    [ "$ON_MAIN" = "$expected" ] ||
        fail "$label: expected ON_MAIN=$expected, got '$ON_MAIN'"
}

test_merge_commit_landing_reads_as_on_main() {
    new_repo ff
    commit_branch feat "feature.txt"
    land_merge feat
    run_on_main feat
    assert_on_main true "a branch merged with a merge commit"
}

test_rebased_landing_reads_as_on_main() {
    new_repo rebased
    commit_branch feat "feature.txt"
    advance_main
    land_rebase feat
    run_on_main feat
    assert_on_main true "a branch replayed onto a moved main"
}

test_squashed_landing_reads_as_on_main() {
    new_repo squashed
    commit_branch feat "one.txt"
    add_branch_commit feat "two.txt"
    advance_main
    land_squash feat
    run_on_main feat
    assert_on_main true "a branch squashed onto main"
}

test_landing_made_elsewhere_reads_as_on_main_despite_stale_local_main() {
    # gp-2xk, the live false negative: the witness runs in a rig checkout whose
    # local `main` -- and its origin/main tracking ref -- lag the refinery,
    # which lands from a different worktree.  Reading local main, or skipping
    # the refresh, reports a merged branch as unlanded and re-dispatches it.
    new_repo stale-local
    commit_branch polecat/feat "feature.txt"
    local refinery="$tmp/repo-stale-local-refinery"
    git clone -q "$ORIGIN" "$refinery"
    git -C "$refinery" config user.name "Refinery"
    git -C "$refinery" config user.email "refinery@example.invalid"
    printf 'unrelated\n' >>"$refinery/README.md"
    git -C "$refinery" commit -q -am "unrelated main commit"
    git -C "$refinery" cherry-pick "origin/main..origin/polecat/feat" >/dev/null 2>&1 ||
        fail "refinery cherry-pick of polecat/feat failed"
    git -C "$refinery" push -q origin main
    [ "$(git -C "$REPO" rev-parse origin/main)" != "$(git -C "$refinery" rev-parse main)" ] ||
        fail "fixture: the witness checkout's origin/main is not stale"
    run_on_main polecat/feat
    assert_on_main true "a branch landed from another worktree while local main is stale"
    [ "$(git -C "$REPO" rev-parse main)" != "$(git -C "$REPO" rev-parse origin/main)" ] ||
        fail "fixture: local main should still be stale after the check (it must not be read)"
}

test_subject_naming_the_branch_does_not_read_as_on_main() {
    # gp-2xk, the false positive: a main commit whose subject merely names the
    # branch is not a landing.  A subject grep would force-close this bead.
    new_repo subject-collision
    commit_branch polecat/feat "feature.txt"
    advance_main "chore: note polecat/feat is still in review"
    run_on_main polecat/feat
    assert_on_main false "an unlanded branch named in a main commit subject"
}

test_unlanded_branch_reads_as_not_on_main() {
    new_repo unlanded
    commit_branch feat "feature.txt"
    advance_main
    run_on_main feat
    assert_on_main false "a branch that never landed"
}

test_unlanded_branch_with_space_in_path_reads_as_not_on_main() {
    # Unquoted, this filename word-splits into pathspecs matching nothing;
    # `git diff --quiet` over those exits 0 and the branch reads as merged.
    new_repo space-unlanded
    commit_branch feat "has space.txt"
    advance_main
    run_on_main feat
    assert_on_main false "an unlanded branch touching a path with a space"
}

test_unlanded_branch_with_newline_in_path_reads_as_not_on_main() {
    # Without `-z`, `--name-only` C-quotes this path; re-reading the quoted
    # form yields a pathspec matching nothing -- the same destructive verdict
    # by a different route, which a per-file loop over unquoted output does
    # not fix.
    new_repo newline-unlanded
    commit_branch feat "$(printf 'has\nnewline.txt')"
    advance_main
    run_on_main feat
    assert_on_main false "an unlanded branch touching a path with a newline"
}

test_landed_branch_with_space_in_path_reads_as_on_main() {
    # Positive control for the two cases above: the quoting fix must not turn
    # every awkward filename into a permanent "not merged".
    new_repo space-landed
    commit_branch feat "has space.txt"
    advance_main
    land_rebase feat
    run_on_main feat
    assert_on_main true "a landed branch touching a path with a space"
}

test_main_touching_the_files_after_landing_reads_as_not_on_main() {
    # The content test's stated bound.  It answers not-merged, which
    # re-dispatches -- wasteful, never destructive.
    new_repo touched-after
    commit_branch feat "feature.txt"
    advance_main
    land_rebase feat
    printf 'main edited this later\n' >"$REPO/feature.txt"
    git -C "$REPO" add -A
    git -C "$REPO" commit -q -m "main edits the landed file"
    git -C "$REPO" push -q origin main
    run_on_main feat
    assert_on_main false "main having edited the landed files afterwards"
}

test_branch_with_no_changes_reads_as_not_on_main() {
    new_repo empty-branch
    git -C "$REPO" checkout -q -b feat main
    git -C "$REPO" commit -q --allow-empty -m "empty"
    git -C "$REPO" push -q origin feat
    git -C "$REPO" checkout -q main
    advance_main
    run_on_main feat
    assert_on_main false "a branch introducing no file changes"
}

test_unreachable_remote_reads_as_not_on_main() {
    new_repo no-remote
    commit_branch feat "feature.txt"
    land_merge feat
    git -C "$REPO" remote set-url origin "$tmp/does-not-exist.git"
    run_on_main feat
    assert_on_main false "a failed fetch"
}

# --- The lift itself -------------------------------------------------------

test_lifted_step3_block_is_the_hardened_one() {
    # If the extraction ever grabs the wrong block, or the guard is replaced by
    # a form that only looks right, the cases above could pass for the wrong
    # reason.  Assert the two jointly load-bearing halves are what ran.
    grep -qF -- 'git diff --name-only -z "$MERGE_BASE" "origin/$BRANCH"' "$STEP3" ||
        fail "lifted Step 3 block does not collect changed paths NUL-delimited"
    grep -qF -- '-- "${CHANGED[@]}"' "$STEP3" ||
        fail "lifted Step 3 block does not pass changed paths as a quoted array"
}

test_lifted_blocks_use_no_bash4_only_constructs() {
    # Same bar as gastown/tests/test_witness_heartbeat_check.sh: the fleet
    # includes macOS on bash 3.2.  Comment lines are stripped first -- the
    # recipe names `mapfile` in a comment explaining why it is not used.
    ! grep -v '^[[:space:]]*#' "$STEP3" |
        grep -nE 'declare -A|local -A|mapfile|readarray|\$\{[A-Za-z_]+\^|\$\{[A-Za-z_]+,,|&>>|\[\[ -v ' >/dev/null ||
        fail "$(basename "$STEP3") must stay bash 3.2 compatible"
}

test_merge_commit_landing_reads_as_on_main
test_rebased_landing_reads_as_on_main
test_squashed_landing_reads_as_on_main
test_landing_made_elsewhere_reads_as_on_main_despite_stale_local_main
test_subject_naming_the_branch_does_not_read_as_on_main
test_unlanded_branch_reads_as_not_on_main
test_unlanded_branch_with_space_in_path_reads_as_not_on_main
test_unlanded_branch_with_newline_in_path_reads_as_not_on_main
test_landed_branch_with_space_in_path_reads_as_on_main
test_main_touching_the_files_after_landing_reads_as_not_on_main
test_branch_with_no_changes_reads_as_not_on_main
test_unreachable_remote_reads_as_not_on_main
test_lifted_step3_block_is_the_hardened_one
test_lifted_blocks_use_no_bash4_only_constructs

echo "mol-witness-patrol orphan recovery tests passed"
