#!/usr/bin/env bash
#
# Purpose:
#   Update the vendored OpenVPN git submodule and stage the parent repository
#   gitlink.
#
# What it does:
#   - initializes third_party/openvpn if needed;
#   - refuses to update a dirty submodule working tree;
#   - fast-forwards the selected branch from its remote;
#   - stages only the updated third_party/openvpn gitlink in this repo.
#
# When it is called:
#   Run manually when intentionally bumping the vendored OpenVPN revision.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

submodule_path="third_party/openvpn"
branch=""
remote="origin"
stage=1
force=0

usage() {
    cat <<'EOF'
Usage: ./vendor.sh [--branch <branch>] [--remote <remote>] [--no-stage] [--force]

Updates third_party/openvpn with a fast-forward merge and stages the parent
repository gitlink.

Examples:
  ./vendor.sh
  ./vendor.sh --branch master
  ./vendor.sh --remote upstream --no-stage

Options:
  --branch <branch>  Branch to update. Defaults to the current submodule branch.
  --remote <remote>  Remote to fetch from. Defaults to origin.
  --no-stage         Do not run "git add third_party/openvpn" in this repo.
  --force            Reset and clean local changes in third_party/openvpn and its
                    nested submodules before updating.
  -h, --help         Show this help.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '==> %s\n' "$*"
}

reset_submodule_worktree() {
    log "resetting local changes in $submodule_path"
    git -C "$submodule_dir" reset --hard
    git -C "$submodule_dir" clean -fdx
    git -C "$submodule_dir" submodule update --init --recursive
    git -C "$submodule_dir" submodule foreach --recursive 'git reset --hard && git clean -fdx'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --branch)
            [ "$#" -ge 2 ] || die "--branch requires a value"
            branch="$2"
            shift 2
            ;;
        --remote)
            [ "$#" -ge 2 ] || die "--remote requires a value"
            remote="$2"
            shift 2
            ;;
        --no-stage)
            stage=0
            shift
            ;;
        --force)
            force=1
            shift
            ;;
        --*)
            die "unknown option: $1"
            ;;
        *)
            die "unexpected argument: $1"
            ;;
    esac
done

case "$branch" in
    -*)
        die "branch must not start with '-'"
        ;;
esac

case "$remote" in
    -*)
        die "remote must not start with '-'"
        ;;
esac

known_paths="$(git -C "$ROOT_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
    | awk '{ print $2 }')"

printf '%s\n' "$known_paths" | grep -Fxq "$submodule_path" \
    || die "unknown submodule path: $submodule_path"

submodule_dir="$ROOT_DIR/$submodule_path"
if [ -d "$submodule_dir/.git" ] || [ -f "$submodule_dir/.git" ]; then
    log "using existing $submodule_path checkout"
else
    log "initializing $submodule_path"
    git -C "$ROOT_DIR" submodule update --init "$submodule_path"
fi

[ -d "$submodule_dir/.git" ] || [ -f "$submodule_dir/.git" ] \
    || die "$submodule_path is not a git checkout after initialization"

if [ "$force" -eq 1 ]; then
    reset_submodule_worktree
fi

dirty_status="$(git -C "$submodule_dir" status --porcelain=v1 --untracked-files=all)"
if [ -n "$dirty_status" ]; then
    printf '%s\n' "$dirty_status" >&2
    die "$submodule_path has local changes; commit, stash, clean them first, or use --force"
fi

if [ -z "$branch" ]; then
    branch="$(git -C "$submodule_dir" symbolic-ref --quiet --short HEAD || true)"
fi

[ -n "$branch" ] || die "$submodule_path is detached; pass --branch <branch>"

old_rev="$(git -C "$submodule_dir" rev-parse --short=12 HEAD)"

log "fetching $remote/$branch"
git -C "$submodule_dir" fetch --tags "$remote" "refs/heads/$branch"

if git -C "$submodule_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$submodule_dir" checkout "$branch"
else
    git -C "$submodule_dir" checkout -B "$branch" FETCH_HEAD
fi

log "fast-forwarding $submodule_path"
git -C "$submodule_dir" merge --ff-only FETCH_HEAD

if [ "$force" -eq 1 ]; then
    reset_submodule_worktree
fi

new_rev="$(git -C "$submodule_dir" rev-parse --short=12 HEAD)"

if [ "$stage" -eq 1 ]; then
    git -C "$ROOT_DIR" add "$submodule_path"
    log "staged $submodule_path"
else
    log "left $submodule_path unstaged"
fi

printf '%s: %s -> %s\n' "$submodule_path" "$old_rev" "$new_rev"
