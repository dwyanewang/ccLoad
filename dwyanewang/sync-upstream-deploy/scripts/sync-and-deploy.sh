#!/usr/bin/env bash
set -Eeuo pipefail

readonly BASE_BRANCH="master"
readonly CONFIG_BRANCH="chore/local-docker-deployment"
readonly DEPLOY_BRANCH="rw-main"
readonly BACKUP_BRANCH="rw-main-backup-latest"
readonly MANIFEST_PATH="dwyanewang/rw-main-branches.txt"
readonly DEFAULT_UPSTREAM_URL="https://github.com/caidaoli/ccLoad.git"

usage() {
  cat <<'EOF'
Usage: sync-and-deploy.sh [--dry-run]

Rebuild rw-main from the latest upstream master, the Docker configuration
branch, and the branches listed in dwyanewang/rw-main-branches.txt. Branch refs
move only after the candidate passes Compose validation and image build.

  --dry-run  Build and verify a candidate without moving branches or deploying.

Required environment:
  CCLOAD_DEPLOY_DIR             External directory containing .env and data/

Optional environment:
  CCLOAD_UPSTREAM_REMOTE        Upstream remote name (default: upstream)
  CCLOAD_UPSTREAM_URL           URL used when adding the remote
  CCLOAD_UPSTREAM_BRANCH        Upstream branch (default: master)
  CCLOAD_COMPOSE_FILE           Repo-relative Compose file
  CCLOAD_DEPLOY_WAIT_TIMEOUT    Compose health wait in seconds (default: 180)
EOF
}

fail() {
  printf 'sync-upstream-deploy: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "unknown argument: $1"
    ;;
esac
(( $# <= 1 )) || fail "only one optional argument is supported"

for command_name in git docker realpath awk; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || \
  fail "the skill script is not inside a Git worktree"
git_cmd=(git -C "$repo_root")

original_branch=$("${git_cmd[@]}" symbolic-ref --quiet --short HEAD) || \
  fail "detached HEAD is not supported"
[[ -z "$("${git_cmd[@]}" status --porcelain)" ]] || \
  fail "current worktree is not clean"

for branch_name in "$BASE_BRANCH" "$CONFIG_BRANCH"; do
  "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$branch_name" || \
    fail "required local branch does not exist: $branch_name"
done

manifest_file="$repo_root/$MANIFEST_PATH"
[[ -f "$manifest_file" ]] || fail "branch manifest not found: $MANIFEST_PATH"

find_worktree_for_branch() {
  local branch_ref="refs/heads/$1"
  "${git_cmd[@]}" worktree list --porcelain | awk -v wanted="$branch_ref" '
    /^worktree / {
      path = $0
      sub(/^worktree /, "", path)
    }
    /^branch / && $2 == wanted { print path }
  '
}

require_clean_branch_worktree() {
  local branch_name=$1
  local worktree_path
  worktree_path=$(find_worktree_for_branch "$branch_name")
  if [[ -n "$worktree_path" && -n "$(git -C "$worktree_path" status --porcelain)" ]]; then
    fail "worktree for $branch_name is dirty: $worktree_path"
  fi
}

for protected_branch in "$BASE_BRANCH" "$DEPLOY_BRANCH" "$BACKUP_BRANCH"; do
  protected_worktree=$(find_worktree_for_branch "$protected_branch")
  if [[ -n "$protected_worktree" && "$protected_worktree" != "$repo_root" ]]; then
    fail "$protected_branch is checked out in another worktree: $protected_worktree"
  fi
done
require_clean_branch_worktree "$CONFIG_BRANCH"

declare -a integration_branches=()
declare -A seen_branches=()
while IFS= read -r line || [[ -n "$line" ]]; do
  entry=${line%%#*}
  entry=${entry#"${entry%%[![:space:]]*}"}
  entry=${entry%"${entry##*[![:space:]]}"}
  [[ -n "$entry" ]] || continue

  "${git_cmd[@]}" check-ref-format --branch "$entry" >/dev/null || \
    fail "invalid branch in manifest: $entry"
  [[ -z "${seen_branches[$entry]+present}" ]] || \
    fail "duplicate branch in manifest: $entry"
  case "$entry" in
    "$BASE_BRANCH"|"$CONFIG_BRANCH"|"$DEPLOY_BRANCH"|"$BACKUP_BRANCH")
      fail "reserved branch in manifest: $entry"
      ;;
  esac
  "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$entry" || \
    fail "local branch from manifest does not exist: $entry"
  require_clean_branch_worktree "$entry"
  seen_branches[$entry]=1
  integration_branches+=("$entry")
done < "$manifest_file"

deploy_dir=${CCLOAD_DEPLOY_DIR:-}
[[ -n "$deploy_dir" ]] || fail "CCLOAD_DEPLOY_DIR is required"
deploy_dir=$(realpath -m -- "$deploy_dir")
[[ "$deploy_dir" != "/" ]] || fail "CCLOAD_DEPLOY_DIR must not be /"
case "$deploy_dir" in
  "$repo_root"|"$repo_root"/*)
    fail "CCLOAD_DEPLOY_DIR must be outside the repository"
    ;;
esac
env_file="$deploy_dir/.env"
data_dir="$deploy_dir/data"
[[ -f "$env_file" ]] || fail "deployment environment file not found: $env_file"

upstream_remote=${CCLOAD_UPSTREAM_REMOTE:-upstream}
upstream_url=${CCLOAD_UPSTREAM_URL:-$DEFAULT_UPSTREAM_URL}
upstream_branch=${CCLOAD_UPSTREAM_BRANCH:-master}
compose_relative=${CCLOAD_COMPOSE_FILE:-docker-compose.build.yml}
wait_timeout=${CCLOAD_DEPLOY_WAIT_TIMEOUT:-180}
[[ "$wait_timeout" =~ ^[1-9][0-9]*$ ]] || \
  fail "CCLOAD_DEPLOY_WAIT_TIMEOUT must be a positive integer"

compose_file=$(realpath -m -- "$repo_root/$compose_relative")
case "$compose_file" in
  "$repo_root"/*) ;;
  *) fail "CCLOAD_COMPOSE_FILE must resolve inside the repository" ;;
esac
[[ -f "$compose_file" ]] || fail "Compose file not found: $compose_file"

if "${git_cmd[@]}" remote get-url "$upstream_remote" >/dev/null 2>&1; then
  configured_upstream=$("${git_cmd[@]}" remote get-url "$upstream_remote")
  info "Using upstream remote $upstream_remote ($configured_upstream)"
else
  info "Adding upstream remote $upstream_remote ($upstream_url)"
  "${git_cmd[@]}" remote add "$upstream_remote" "$upstream_url"
fi

upstream_ref="refs/remotes/$upstream_remote/$upstream_branch"
info "Fetching $upstream_remote/$upstream_branch"
"${git_cmd[@]}" fetch --prune "$upstream_remote" \
  "refs/heads/$upstream_branch:$upstream_ref"
"${git_cmd[@]}" show-ref --verify --quiet "$upstream_ref" || \
  fail "fetched upstream ref is unavailable: $upstream_ref"

base_before=$("${git_cmd[@]}" rev-parse "$BASE_BRANCH")
upstream_commit=$("${git_cmd[@]}" rev-parse "$upstream_ref")
"${git_cmd[@]}" merge-base --is-ancestor "$base_before" "$upstream_commit" || \
  fail "$BASE_BRANCH cannot fast-forward to $upstream_remote/$upstream_branch"

config_commit=$("${git_cmd[@]}" rev-parse "$CONFIG_BRANCH")
if "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$DEPLOY_BRANCH"; then
  deploy_before=$("${git_cmd[@]}" rev-parse "$DEPLOY_BRANCH")
else
  deploy_before=""
fi

info "Base: $BASE_BRANCH ($base_before -> $upstream_commit)"
info "Configuration: $CONFIG_BRANCH ($config_commit)"
for branch_name in "${integration_branches[@]}"; do
  read -r behind ahead < <("${git_cmd[@]}" rev-list --left-right --count \
    "$upstream_commit...$branch_name")
  branch_short=$("${git_cmd[@]}" rev-parse --short "$branch_name")
  info "Integration: $branch_name ($branch_short; behind $behind, ahead $ahead)"
done

candidate_branch="rw-main-rebuild-$(date +%Y%m%d-%H%M%S)-$$"
"${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$candidate_branch" && \
  fail "temporary candidate branch already exists: $candidate_branch"

candidate_created=0
cleanup() {
  local status=$?
  trap - EXIT
  if (( candidate_created )); then
    if "${git_cmd[@]}" rev-parse --quiet --verify MERGE_HEAD >/dev/null; then
      "${git_cmd[@]}" merge --abort >/dev/null 2>&1 || true
    fi
    local active_branch
    active_branch=$("${git_cmd[@]}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ "$active_branch" == "$candidate_branch" ]]; then
      "${git_cmd[@]}" switch --quiet "$original_branch" >/dev/null 2>&1 || true
    fi
    if "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$candidate_branch"; then
      "${git_cmd[@]}" branch -D "$candidate_branch" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

info "Creating candidate $candidate_branch from $upstream_remote/$upstream_branch"
"${git_cmd[@]}" switch --quiet --create "$candidate_branch" "$upstream_commit"
candidate_created=1

merge_branch() {
  local branch_name=$1
  info "Merging $branch_name"
  GIT_MERGE_AUTOEDIT=no "${git_cmd[@]}" merge --no-ff --no-edit -- "$branch_name"
}

merge_branch "$CONFIG_BRANCH"
for branch_name in "${integration_branches[@]}"; do
  merge_branch "$branch_name"
done

export CCLOAD_DEPLOY_DIR="$deploy_dir"
if [[ -z "${VERSION:-}" ]]; then
  VERSION=$("${git_cmd[@]}" describe --tags --always)
  export VERSION
fi
compose_cmd=(docker compose -f "$compose_file")

info "Validating Docker Compose configuration"
"${compose_cmd[@]}" config --quiet
info "Building Docker image from candidate"
"${compose_cmd[@]}" build
[[ -z "$("${git_cmd[@]}" status --porcelain)" ]] || \
  fail "candidate validation left worktree changes"

candidate_head=$("${git_cmd[@]}" rev-parse HEAD)
info "Candidate: $candidate_head"

if (( dry_run )); then
  "${git_cmd[@]}" switch --quiet "$original_branch"
  "${git_cmd[@]}" branch -D "$candidate_branch" >/dev/null
  candidate_created=0
  info "Dry run passed; $BASE_BRANCH and $DEPLOY_BRANCH were not changed"
  exit 0
fi

if "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$BACKUP_BRANCH"; then
  backup_before=$("${git_cmd[@]}" rev-parse "$BACKUP_BRANCH")
else
  backup_before=""
fi

info "Atomically updating $BASE_BRANCH and $DEPLOY_BRANCH"
{
  printf 'start\n'
  printf 'update refs/heads/%s %s %s\n' "$BASE_BRANCH" "$upstream_commit" "$base_before"
  if [[ -n "$deploy_before" ]]; then
    if [[ -n "$backup_before" ]]; then
      printf 'update refs/heads/%s %s %s\n' \
        "$BACKUP_BRANCH" "$deploy_before" "$backup_before"
    else
      printf 'create refs/heads/%s %s\n' "$BACKUP_BRANCH" "$deploy_before"
    fi
    printf 'update refs/heads/%s %s %s\n' \
      "$DEPLOY_BRANCH" "$candidate_head" "$deploy_before"
  else
    printf 'create refs/heads/%s %s\n' "$DEPLOY_BRANCH" "$candidate_head"
  fi
  printf 'prepare\n'
  printf 'commit\n'
} | "${git_cmd[@]}" update-ref --stdin

"${git_cmd[@]}" switch --quiet "$DEPLOY_BRANCH"
"${git_cmd[@]}" branch -D "$candidate_branch" >/dev/null
candidate_created=0

mkdir -p -- "$data_dir"
info "Deploying the prebuilt image from $DEPLOY_BRANCH"
"${compose_cmd[@]}" up -d --no-build --remove-orphans --wait --wait-timeout "$wait_timeout"

info "Synchronization and deployment completed"
printf 'base:     %s -> %s\n' "$base_before" "$upstream_commit"
printf 'upstream: %s\n' "$upstream_commit"
printf 'config:   %s\n' "$config_commit"
printf 'candidate: %s\n' "$candidate_head"
if [[ -n "$deploy_before" ]]; then
  printf 'deploy:   %s -> %s\n' "$deploy_before" "$candidate_head"
  printf 'backup:   %s -> %s\n' "$BACKUP_BRANCH" "$deploy_before"
else
  printf 'deploy:   (created) -> %s\n' "$candidate_head"
fi
"${compose_cmd[@]}" ps
