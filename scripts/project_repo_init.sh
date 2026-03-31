#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage_repo_init() {
  cat <<'EOF'
Usage:
  scripts/project_repo_init.sh [options]

Create or connect a GitHub repository for the current project.

Options:
  --config FILE            Source trusted bash profile config
  --root-dir DIR           Local project root
  --owner NAME             GitHub owner or org
  --repo-name NAME         GitHub repo name
  --repo-slug OWNER/NAME   GitHub repo slug
  --visibility TYPE        public|private
  --public                 Shortcut for --visibility public
  --private                Shortcut for --visibility private
  --description TEXT       Repo description
  --git-remote NAME        Git remote to configure (default: origin)
  --git-branch NAME        Git branch to push (default: current or main)
  --git-protocol TYPE      https|ssh
  --push                   Push current branch after remote setup
  --dry-run                Print commands without executing them
  -h, --help               Show help
EOF
}

detect_git_remote_url_local() {
  local root_dir="$1"
  local remote_name="$2"
  git -C "$root_dir" remote get-url "$remote_name" 2>/dev/null || true
}

detect_git_branch_local() {
  local root_dir="$1"
  git -C "$root_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

ensure_git_repo() {
  local root_dir="$1"
  local branch="$2"

  if git -C "$root_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  mkdir -p "$root_dir"
  info "Initializing git repository in $root_dir"
  if run_in_dir "$root_dir" git init -b "$branch" >/dev/null 2>&1; then
    return 0
  fi
  run_in_dir "$root_dir" git init
  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    git -C "$root_dir" symbolic-ref HEAD "refs/heads/$branch" >/dev/null 2>&1 || true
  fi
}

github_repo_exists() {
  local slug="$1"
  gh repo view "$slug" >/dev/null 2>&1
}

main() {
  load_config_if_requested "$@"

  local root_dir="${ROOT_DIR:-$PWD}"
  local owner="${GITHUB_OWNER:-}"
  local repo_name="${GITHUB_REPO_NAME:-}"
  local visibility="${GITHUB_REPO_VISIBILITY:-}"
  local description="${GITHUB_REPO_DESCRIPTION:-}"
  local git_remote="${GIT_REMOTE:-origin}"
  local git_branch="${GIT_BRANCH:-}"
  local git_protocol="${GIT_PROTOCOL:-}"
  local repo_slug=""
  local current_remote_url=""
  local current_remote_slug=""
  local current_remote_protocol=""
  local default_owner=""
  local default_protocol=""
  local remote_url=""
  local create_cmd_flag=""
  local push_after_setup=0

  if [[ -n "${RELEASE_REPO:-}" && -z "$repo_name" ]]; then
    repo_name="${RELEASE_REPO##*/}"
  fi

  DRY_RUN=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config|--config=*)
        shift $([[ "$1" == *=* ]] && echo 1 || echo 2)
        ;;
      --root-dir)
        root_dir="${2:-}"
        shift 2
        ;;
      --owner)
        owner="${2:-}"
        shift 2
        ;;
      --repo-name)
        repo_name="${2:-}"
        shift 2
        ;;
      --repo-slug)
        repo_slug="${2:-}"
        shift 2
        ;;
      --visibility)
        visibility="${2:-}"
        shift 2
        ;;
      --public)
        visibility="public"
        shift
        ;;
      --private)
        visibility="private"
        shift
        ;;
      --description)
        description="${2:-}"
        shift 2
        ;;
      --git-remote)
        git_remote="${2:-}"
        shift 2
        ;;
      --git-branch)
        git_branch="${2:-}"
        shift 2
        ;;
      --git-protocol)
        git_protocol="${2:-}"
        shift 2
        ;;
      --push)
        push_after_setup=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage_repo_init
        exit 0
        ;;
      *)
        die "unknown repo-init option: $1"
        ;;
    esac
  done

  require_cmd git
  require_cmd gh

  root_dir="$(path_from_cwd "$root_dir")"
  [[ -n "$root_dir" ]] || die "unable to resolve root dir"

  current_remote_url="$(detect_git_remote_url_local "$root_dir" "$git_remote")"
  current_remote_slug="$(parse_github_repo_slug "$current_remote_url" || true)"
  current_remote_protocol="$(parse_github_protocol "$current_remote_url" || true)"

  if [[ -n "$repo_slug" ]]; then
    if [[ "$repo_slug" =~ ^([^/]+)/([^/]+)$ ]]; then
      owner="${BASH_REMATCH[1]}"
      repo_name="${BASH_REMATCH[2]}"
    else
      die "--repo-slug must be in OWNER/NAME format"
    fi
  elif [[ -n "$current_remote_slug" ]]; then
    owner="${owner:-${current_remote_slug%%/*}}"
    repo_name="${repo_name:-${current_remote_slug##*/}}"
  fi

  default_owner="$(detect_gh_login || true)"
  owner="${owner:-$default_owner}"
  repo_name="${repo_name:-$(basename "$root_dir")}"

  default_protocol="$(detect_gh_git_protocol || true)"
  git_protocol="${git_protocol:-${current_remote_protocol:-${default_protocol:-https}}}"
  visibility="${visibility:-private}"
  git_branch="${git_branch:-$(detect_git_branch_local "$root_dir")}"
  git_branch="${git_branch:-main}"

  [[ -n "$owner" ]] || die "GitHub owner is required"
  [[ -n "$repo_name" ]] || die "GitHub repo name is required"
  [[ "$visibility" == "public" || "$visibility" == "private" ]] || die "--visibility must be public or private"
  [[ "$git_protocol" == "https" || "$git_protocol" == "ssh" ]] || die "--git-protocol must be https or ssh"

  gh auth status -h github.com >/dev/null 2>&1 || die "Run 'gh auth login' first"
  ensure_git_repo "$root_dir" "$git_branch"

  repo_slug="$owner/$repo_name"
  remote_url="$(remote_url_for_protocol "$owner" "$repo_name" "$git_protocol")"
  create_cmd_flag="--$visibility"

  info "GitHub repo setup summary"
  info "  root_dir:    $root_dir"
  info "  repo:        $repo_slug"
  info "  visibility:  $visibility"
  info "  git_remote:  $git_remote"
  info "  git_branch:  $git_branch"
  info "  git_protocol:$git_protocol"
  info "  remote_url:  $remote_url"

  if github_repo_exists "$repo_slug"; then
    info "GitHub repo already exists: $repo_slug"
  else
    local -a create_cmd=(gh repo create "$repo_slug" "$create_cmd_flag")
    if [[ -n "$description" ]]; then
      create_cmd+=(--description "$description")
    fi
    run_cmd "${create_cmd[@]}"
  fi

  if [[ -n "$current_remote_url" ]]; then
    if [[ "$current_remote_url" != "$remote_url" ]]; then
      info "Updating git remote $git_remote"
      run_cmd git -C "$root_dir" remote set-url "$git_remote" "$remote_url"
    else
      info "Git remote $git_remote is already configured"
    fi
  else
    info "Adding git remote $git_remote"
    run_cmd git -C "$root_dir" remote add "$git_remote" "$remote_url"
  fi

  if [[ "$push_after_setup" -eq 1 ]]; then
    if ! git -C "$root_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
      warn "Repository has no commits yet. Commit files first, then push."
      return 1
    fi
    run_cmd git -C "$root_dir" push -u "$git_remote" "$git_branch"
  fi

  if [[ "$visibility" == "private" && "$git_protocol" == "https" ]]; then
    warn "Private repo over HTTPS is fine for local git, but server-side deploy will need credentials."
    warn "For deploy hosts, prefer SSH clone URL in REPO_URL."
  fi
}

main "$@"
