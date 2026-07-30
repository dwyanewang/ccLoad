#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_UPSTREAM_URL="https://github.com/caidaoli/ccLoad.git"

usage() {
  cat <<'EOF'
Usage: sync-and-deploy.sh [--dry-run]

Synchronize the local base branch with ccLoad upstream, rebase the current
deployment branch, then rebuild and verify the Docker Compose deployment.

Required environment:
  CCLOAD_DEPLOY_DIR             External directory containing .env and data/

Optional environment:
  CCLOAD_UPSTREAM_REMOTE        Upstream remote name (default: upstream)
  CCLOAD_UPSTREAM_URL           URL used when adding the remote
  CCLOAD_UPSTREAM_BRANCH        Upstream branch (default: master)
  CCLOAD_BASE_BRANCH            Local base branch (default: master)
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
current_branch=$("${git_cmd[@]}" branch --show-current)
[[ -n "$current_branch" ]] || fail "detached HEAD is not supported"

base_branch=${CCLOAD_BASE_BRANCH:-master}
[[ "$current_branch" != "$base_branch" ]] || \
  fail "run this script from the deployment branch, not $base_branch"
"${git_cmd[@]}" show-ref --verify --quiet "refs/heads/$base_branch" || \
  fail "local base branch does not exist: $base_branch"

worktree_status=$("${git_cmd[@]}" status --porcelain=v1 --untracked-files=all)
[[ -z "$worktree_status" ]] || \
  fail "worktree must be clean before synchronization"

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

base_before=$("${git_cmd[@]}" rev-parse "$base_branch")
deploy_before=$("${git_cmd[@]}" rev-parse "$current_branch")

if "${git_cmd[@]}" remote get-url "$upstream_remote" >/dev/null 2>&1; then
  configured_upstream=$("${git_cmd[@]}" remote get-url "$upstream_remote")
else
  configured_upstream=""
fi

if (( dry_run )); then
  info "dry run: repository=$repo_root"
  info "dry run: deployment branch=$current_branch ($deploy_before)"
  info "dry run: base branch=$base_branch ($base_before)"
  if [[ -z "$configured_upstream" ]]; then
    info "dry run: add remote $upstream_remote -> $upstream_url"
  else
    info "dry run: use remote $upstream_remote -> $configured_upstream"
  fi
  info "dry run: fetch $upstream_remote/$upstream_branch"
  info "dry run: fast-forward $base_branch, then rebase $current_branch"
  info "dry run: build $compose_file with deployment data in $deploy_dir"
  exit 0
fi

if [[ -z "$configured_upstream" ]]; then
  info "Adding upstream remote $upstream_remote"
  "${git_cmd[@]}" remote add "$upstream_remote" "$upstream_url"
else
  info "Using upstream remote $upstream_remote ($configured_upstream)"
fi

info "Fetching $upstream_remote/$upstream_branch"
"${git_cmd[@]}" fetch --prune "$upstream_remote" "$upstream_branch"
upstream_ref="refs/remotes/$upstream_remote/$upstream_branch"
"${git_cmd[@]}" show-ref --verify --quiet "$upstream_ref" || \
  fail "fetched upstream ref is unavailable: $upstream_ref"
upstream_commit=$("${git_cmd[@]}" rev-parse "$upstream_ref")

cleanup() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    local git_dir
    git_dir=$("${git_cmd[@]}" rev-parse --absolute-git-dir 2>/dev/null || true)
    if [[ -n "$git_dir" && ( -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ) ]]; then
      "${git_cmd[@]}" rebase --abort >/dev/null 2>&1 || true
    fi
    local active_branch
    active_branch=$("${git_cmd[@]}" branch --show-current 2>/dev/null || true)
    if [[ "$active_branch" != "$current_branch" ]]; then
      "${git_cmd[@]}" switch "$current_branch" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

info "Fast-forwarding $base_branch to $upstream_remote/$upstream_branch"
"${git_cmd[@]}" switch "$base_branch"
"${git_cmd[@]}" merge --ff-only "$upstream_ref"

info "Rebasing $current_branch onto $base_branch"
"${git_cmd[@]}" switch "$current_branch"
"${git_cmd[@]}" rebase "$base_branch"

mkdir -p -- "$data_dir"
export CCLOAD_DEPLOY_DIR="$deploy_dir"
if [[ -z "${VERSION:-}" ]]; then
  VERSION=$("${git_cmd[@]}" describe --tags --always)
  export VERSION
fi

compose_cmd=(docker compose -f "$compose_file")
info "Validating Docker Compose configuration"
"${compose_cmd[@]}" config --quiet

info "Building and deploying Docker services"
"${compose_cmd[@]}" up -d --build --remove-orphans --wait --wait-timeout "$wait_timeout"

base_after=$("${git_cmd[@]}" rev-parse "$base_branch")
deploy_after=$("${git_cmd[@]}" rev-parse "$current_branch")
info "Synchronization and deployment completed"
printf 'base:     %s -> %s\n' "$base_before" "$base_after"
printf 'upstream: %s\n' "$upstream_commit"
printf 'deploy:   %s -> %s\n' "$deploy_before" "$deploy_after"
"${compose_cmd[@]}" ps
