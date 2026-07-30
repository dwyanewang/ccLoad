#!/usr/bin/env bash
set -Eeuo pipefail

readonly BASE_BRANCH="master"
readonly CONFIG_BRANCH="chore/local-docker-deployment"
readonly DEPLOY_BRANCH="rw-main"
readonly DEFAULT_UPSTREAM_URL="https://github.com/caidaoli/ccLoad.git"

usage() {
  cat <<'EOF'
Usage: sync-and-deploy.sh [--dry-run]

Fast-forward master from ccLoad upstream, merge master into the dedicated
deployment-configuration branch, fast-forward rw-main, then rebuild and verify
the Docker Compose deployment from rw-main.

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
  printf 'error: %s\n' "$*" >&2
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

if (( $# > 1 )); then
  usage >&2
  fail "only one optional argument is supported"
fi

for command_name in git docker realpath; do
  command -v "$command_name" >/dev/null 2>&1 || fail "required command not found: $command_name"
done
docker compose version >/dev/null 2>&1 || fail "Docker Compose plugin is unavailable"

script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null) || \
  fail "the skill script is not inside a Git worktree"
git_cmd=(git -C "$repo_root")

original_branch=$("${git_cmd[@]}" branch --show-current)
[[ -n "$original_branch" ]] || fail "detached HEAD is not supported"

for branch_name in "$BASE_BRANCH" "$CONFIG_BRANCH" "$DEPLOY_BRANCH"; do
  "${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$branch_name" || \
    fail "required local branch does not exist: $branch_name"
done

worktree_status=$("${git_cmd[@]}" status --porcelain=v1 --untracked-files=all)
[[ -z "$worktree_status" ]] || fail "worktree must be clean before synchronization"

"${git_cmd[@]}" merge-base --is-ancestor "$DEPLOY_BRANCH" "$CONFIG_BRANCH" || \
  fail "$DEPLOY_BRANCH contains commits not present in $CONFIG_BRANCH"

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
if [[ ! -f "$env_file" ]]; then
  if (( dry_run )); then
    info "dry run: deployment requires $env_file"
  else
    fail "deployment environment file not found: $env_file"
  fi
fi

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

base_before=$("${git_cmd[@]}" rev-parse "$BASE_BRANCH")
config_before=$("${git_cmd[@]}" rev-parse "$CONFIG_BRANCH")
deploy_before=$("${git_cmd[@]}" rev-parse "$DEPLOY_BRANCH")

if "${git_cmd[@]}" remote get-url "$upstream_remote" >/dev/null 2>&1; then
  configured_upstream=$("${git_cmd[@]}" remote get-url "$upstream_remote")
else
  configured_upstream=""
fi

if (( dry_run )); then
  info "dry run: repository=$repo_root"
  info "dry run: original branch=$original_branch"
  info "dry run: base branch=$BASE_BRANCH ($base_before)"
  info "dry run: config branch=$CONFIG_BRANCH ($config_before)"
  info "dry run: deploy branch=$DEPLOY_BRANCH ($deploy_before)"
  if [[ -z "$configured_upstream" ]]; then
    info "dry run: add remote $upstream_remote -> $upstream_url"
  else
    info "dry run: use remote $upstream_remote -> $configured_upstream"
  fi
  info "dry run: fetch $upstream_remote/$upstream_branch"
  info "dry run: fast-forward $BASE_BRANCH"
  info "dry run: merge $BASE_BRANCH into $CONFIG_BRANCH"
  info "dry run: fast-forward $DEPLOY_BRANCH to $CONFIG_BRANCH"
  info "dry run: build $compose_file from $DEPLOY_BRANCH with data in $deploy_dir"
  exit 0
fi

if [[ -z "$configured_upstream" ]]; then
  info "Adding upstream remote $upstream_remote"
  "${git_cmd[@]}" remote add "$upstream_remote" "$upstream_url"
else
  info "Using upstream remote $upstream_remote ($configured_upstream)"
fi

info "Fetching $upstream_remote/$upstream_branch"
upstream_ref="refs/remotes/$upstream_remote/$upstream_branch"
"${git_cmd[@]}" fetch --prune "$upstream_remote" \
  "refs/heads/$upstream_branch:$upstream_ref"
"${git_cmd[@]}" show-ref --verify --quiet "$upstream_ref" || \
  fail "fetched upstream ref is unavailable: $upstream_ref"
upstream_commit=$("${git_cmd[@]}" rev-parse "$upstream_ref")

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    local git_dir
    git_dir=$("${git_cmd[@]}" rev-parse --absolute-git-dir 2>/dev/null || true)
    if [[ -n "$git_dir" && -f "$git_dir/MERGE_HEAD" ]]; then
      "${git_cmd[@]}" merge --abort >/dev/null 2>&1 || true
    fi
    local active_branch
    active_branch=$("${git_cmd[@]}" branch --show-current 2>/dev/null || true)
    if [[ "$active_branch" != "$original_branch" ]]; then
      "${git_cmd[@]}" switch "$original_branch" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

info "Fast-forwarding $BASE_BRANCH to $upstream_remote/$upstream_branch"
"${git_cmd[@]}" switch "$BASE_BRANCH"
"${git_cmd[@]}" merge --ff-only "$upstream_ref"

info "Merging $BASE_BRANCH into $CONFIG_BRANCH"
"${git_cmd[@]}" switch "$CONFIG_BRANCH"
"${git_cmd[@]}" merge --no-edit "$BASE_BRANCH"

info "Fast-forwarding $DEPLOY_BRANCH to $CONFIG_BRANCH"
"${git_cmd[@]}" switch "$DEPLOY_BRANCH"
"${git_cmd[@]}" merge --ff-only "$CONFIG_BRANCH"

mkdir -p -- "$data_dir"
export CCLOAD_DEPLOY_DIR="$deploy_dir"
if [[ -z "${VERSION:-}" ]]; then
  VERSION=$("${git_cmd[@]}" describe --tags --always)
  export VERSION
fi

compose_cmd=(docker compose -f "$compose_file")
info "Validating Docker Compose configuration"
"${compose_cmd[@]}" config --quiet

info "Building and deploying Docker services from $DEPLOY_BRANCH"
"${compose_cmd[@]}" up -d --build --remove-orphans --wait --wait-timeout "$wait_timeout"

base_after=$("${git_cmd[@]}" rev-parse "$BASE_BRANCH")
config_after=$("${git_cmd[@]}" rev-parse "$CONFIG_BRANCH")
deploy_after=$("${git_cmd[@]}" rev-parse "$DEPLOY_BRANCH")
info "Synchronization and deployment completed"
printf 'base:     %s -> %s\n' "$base_before" "$base_after"
printf 'upstream: %s\n' "$upstream_commit"
printf 'config:   %s -> %s\n' "$config_before" "$config_after"
printf 'deploy:   %s -> %s\n' "$deploy_before" "$deploy_after"
"${compose_cmd[@]}" ps
