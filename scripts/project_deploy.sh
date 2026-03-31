#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage_deploy() {
  cat <<'EOF'
Usage:
  scripts/project_deploy.sh [options]

Universal deploy flow:
  1) clone or fetch repository
  2) checkout branch/tag/commit
  3) docker compose pull
  4) docker compose up -d

Options:
  --config FILE            Source trusted bash config before parsing options
  --repo-url URL           Git repository URL (required on first clone)
  --app-dir DIR            Deployment directory (required)
  --ref REF                Branch/tag/commit or "latest" (default: latest)
  --ref-type TYPE          auto|branch|tag|commit (default: auto)
  --main-branch NAME       Branch used for "latest" (default: main)
  --compose-dir DIR        Directory where docker compose is executed (default: APP_DIR)
  --compose-file FILE      Compose file, repeatable
  --env-file FILE          Compose env file, repeatable
  --project-name NAME      Compose project name
  --image-repo NAME        Export IMAGE_REPO for compose
  --image-tag TAG          Export IMAGE_TAG for compose
  --service NAME           Compose service, repeatable
  --skip-pull              Skip docker compose pull
  --skip-up                Skip docker compose up
  --remove-orphans         Add --remove-orphans to docker compose up
  --no-detach              Run docker compose up without -d
  --dry-run                Print commands without executing them
  -h, --help               Show help
EOF
}

guess_deploy_ref_in_dry_run() {
  local requested="$1"
  local requested_type="$2"
  local main_branch="$3"

  DEPLOY_TARGET_TYPE=""
  DEPLOY_TARGET_REF=""

  if [[ -z "$requested" || "$requested" == "latest" ]]; then
    DEPLOY_TARGET_TYPE="branch"
    DEPLOY_TARGET_REF="$main_branch"
    return 0
  fi

  case "$requested_type" in
    branch)
      DEPLOY_TARGET_TYPE="branch"
      DEPLOY_TARGET_REF="$requested"
      ;;
    tag)
      DEPLOY_TARGET_TYPE="tag"
      DEPLOY_TARGET_REF="$requested"
      ;;
    commit)
      DEPLOY_TARGET_TYPE="commit"
      DEPLOY_TARGET_REF="$requested"
      ;;
    auto)
      if [[ "$requested" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9._-]+)?$ ]]; then
        DEPLOY_TARGET_TYPE="tag"
      elif [[ "$requested" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        DEPLOY_TARGET_TYPE="commit"
      else
        DEPLOY_TARGET_TYPE="branch"
      fi
      DEPLOY_TARGET_REF="$requested"
      ;;
    *)
      die "--ref-type must be one of: auto|branch|tag|commit"
      ;;
  esac
}

resolve_tag_candidate() {
  local repo_dir="$1"
  local requested="$2"
  if git -C "$repo_dir" rev-parse -q --verify "refs/tags/$requested" >/dev/null 2>&1; then
    printf '%s\n' "$requested"
    return 0
  fi
  if is_semver "$requested" && git -C "$repo_dir" rev-parse -q --verify "refs/tags/v$requested" >/dev/null 2>&1; then
    printf 'v%s\n' "$requested"
    return 0
  fi
  return 1
}

remote_branch_exists() {
  local repo_dir="$1"
  local branch="$2"
  git -C "$repo_dir" show-ref --verify --quiet "refs/remotes/origin/$branch"
}

resolve_deploy_ref() {
  local repo_dir="$1"
  local requested="$2"
  local requested_type="$3"
  local main_branch="$4"

  DEPLOY_TARGET_TYPE=""
  DEPLOY_TARGET_REF=""

  if [[ -z "$requested" || "$requested" == "latest" ]]; then
    DEPLOY_TARGET_TYPE="branch"
    DEPLOY_TARGET_REF="$main_branch"
    return 0
  fi

  case "$requested_type" in
    branch)
      remote_branch_exists "$repo_dir" "$requested" || die "remote branch not found: $requested"
      DEPLOY_TARGET_TYPE="branch"
      DEPLOY_TARGET_REF="$requested"
      ;;
    tag)
      DEPLOY_TARGET_REF="$(resolve_tag_candidate "$repo_dir" "$requested" || true)"
      [[ -n "$DEPLOY_TARGET_REF" ]] || die "tag not found: $requested"
      DEPLOY_TARGET_TYPE="tag"
      ;;
    commit)
      git -C "$repo_dir" rev-parse --verify "${requested}^{commit}" >/dev/null 2>&1 || die "commit not found: $requested"
      DEPLOY_TARGET_TYPE="commit"
      DEPLOY_TARGET_REF="$requested"
      ;;
    auto)
      DEPLOY_TARGET_REF="$(resolve_tag_candidate "$repo_dir" "$requested" || true)"
      if [[ -n "$DEPLOY_TARGET_REF" ]]; then
        DEPLOY_TARGET_TYPE="tag"
      elif remote_branch_exists "$repo_dir" "$requested"; then
        DEPLOY_TARGET_TYPE="branch"
        DEPLOY_TARGET_REF="$requested"
      elif git -C "$repo_dir" rev-parse --verify "${requested}^{commit}" >/dev/null 2>&1; then
        DEPLOY_TARGET_TYPE="commit"
        DEPLOY_TARGET_REF="$requested"
      else
        die "unable to resolve ref: $requested"
      fi
      ;;
    *)
      die "--ref-type must be one of: auto|branch|tag|commit"
      ;;
  esac
}

checkout_deploy_target() {
  local repo_dir="$1"
  local target_type="$2"
  local target_ref="$3"

  run_cmd git -C "$repo_dir" reset --hard HEAD

  case "$target_type" in
    branch)
      info "Deploy ref: branch $target_ref"
      run_cmd git -C "$repo_dir" checkout -B "$target_ref" "origin/$target_ref"
      run_cmd git -C "$repo_dir" reset --hard "origin/$target_ref"
      ;;
    tag)
      info "Deploy ref: tag $target_ref"
      run_cmd git -C "$repo_dir" checkout --detach "$target_ref"
      ;;
    commit)
      target_ref="$(git -C "$repo_dir" rev-parse --verify "${target_ref}^{commit}")"
      info "Deploy ref: commit $target_ref"
      run_cmd git -C "$repo_dir" checkout --detach "$target_ref"
      ;;
    *)
      die "unsupported deploy target type: $target_type"
      ;;
  esac
}

sync_deploy_repo() {
  local repo_url="$1"
  local app_dir="$2"

  require_cmd git

  if [[ ! -d "$app_dir/.git" ]]; then
    [[ -n "$repo_url" ]] || die "--repo-url is required when APP_DIR is not initialized"
    mkdir -p "$(dirname "$app_dir")"
    info "Cloning repository into $app_dir"
    run_cmd git clone "$repo_url" "$app_dir"
    return 0
  fi

  if [[ -n "$repo_url" ]]; then
    local current_remote=""
    current_remote="$(git -C "$app_dir" remote get-url origin 2>/dev/null || true)"
    if [[ -n "$current_remote" && "$current_remote" != "$repo_url" ]]; then
      info "Updating origin URL"
      run_cmd git -C "$app_dir" remote set-url origin "$repo_url"
    fi
  fi

  info "Fetching repository updates"
  run_cmd git -C "$app_dir" fetch --prune --tags origin
}

main() {
  load_config_if_requested "$@"

  local repo_url="${REPO_URL:-}"
  local app_dir="${APP_DIR:-}"
  local ref="${DEPLOY_REF:-${REF:-latest}}"
  local ref_type="${REF_TYPE:-auto}"
  local main_branch="${MAIN_BRANCH:-main}"
  local compose_dir="${COMPOSE_DIR:-}"
  local project_name="${COMPOSE_PROJECT_NAME:-}"
  local image_repo="${IMAGE_REPO:-}"
  local image_tag="${IMAGE_TAG:-}"
  local pull=1
  local up=1
  local remove_orphans=0
  local detach=1
  local item=""
  local -a compose_files=()
  local -a env_files=()
  local -a services=()

  if [[ "${DEPLOY_COMPOSE_FILES+x}" = "x" ]]; then
    for item in "${DEPLOY_COMPOSE_FILES[@]-}"; do
      [[ -n "$item" ]] && compose_files+=("$item")
    done
  fi
  if [[ "${DEPLOY_ENV_FILES+x}" = "x" ]]; then
    for item in "${DEPLOY_ENV_FILES[@]-}"; do
      [[ -n "$item" ]] && env_files+=("$item")
    done
  fi
  if [[ "${DEPLOY_SERVICES+x}" = "x" ]]; then
    for item in "${DEPLOY_SERVICES[@]-}"; do
      [[ -n "$item" ]] && services+=("$item")
    done
  fi

  DRY_RUN=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config|--config=*)
        shift $([[ "$1" == *=* ]] && echo 1 || echo 2)
        ;;
      --repo-url)
        repo_url="${2:-}"
        shift 2
        ;;
      --app-dir)
        app_dir="${2:-}"
        shift 2
        ;;
      --ref)
        ref="${2:-}"
        shift 2
        ;;
      --ref-type)
        ref_type="${2:-}"
        shift 2
        ;;
      --main-branch)
        main_branch="${2:-}"
        shift 2
        ;;
      --compose-dir)
        compose_dir="${2:-}"
        shift 2
        ;;
      --compose-file)
        compose_files+=("${2:-}")
        shift 2
        ;;
      --env-file)
        env_files+=("${2:-}")
        shift 2
        ;;
      --project-name)
        project_name="${2:-}"
        shift 2
        ;;
      --image-repo)
        image_repo="${2:-}"
        shift 2
        ;;
      --image-tag)
        image_tag="${2:-}"
        shift 2
        ;;
      --service)
        services+=("${2:-}")
        shift 2
        ;;
      --skip-pull)
        pull=0
        shift
        ;;
      --skip-up)
        up=0
        shift
        ;;
      --remove-orphans)
        remove_orphans=1
        shift
        ;;
      --no-detach)
        detach=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage_deploy
        exit 0
        ;;
      *)
        die "unknown deploy option: $1"
        ;;
    esac
  done

  [[ -n "$app_dir" ]] || die "--app-dir is required"
  app_dir="$(path_from_cwd "$app_dir")"
  [[ -n "$compose_dir" ]] || compose_dir="$app_dir"
  if [[ "$compose_dir" != /* ]]; then
    compose_dir="$app_dir/$compose_dir"
  fi

  require_cmd docker
  sync_deploy_repo "$repo_url" "$app_dir"
  if [[ "$DRY_RUN" -eq 1 && ! -d "$app_dir/.git" ]]; then
    guess_deploy_ref_in_dry_run "$ref" "$ref_type" "$main_branch"
    info "Dry-run: repository is not cloned yet, ref validation is skipped"
  else
    resolve_deploy_ref "$app_dir" "$ref" "$ref_type" "$main_branch"
    checkout_deploy_target "$app_dir" "$DEPLOY_TARGET_TYPE" "$DEPLOY_TARGET_REF"
  fi
  detect_compose_cmd

  local file_path=""
  local env_path=""
  local -a compose_prefix=("${COMPOSE_CMD[@]}")
  for file_path in "${compose_files[@]-}"; do
    [[ -n "$file_path" ]] && compose_prefix+=(-f "$file_path")
  done
  for env_path in "${env_files[@]-}"; do
    [[ -n "$env_path" ]] && compose_prefix+=(--env-file "$env_path")
  done
  if [[ -n "$project_name" ]]; then
    compose_prefix+=(-p "$project_name")
  fi

  info "Deploy summary"
  info "  app_dir:    $app_dir"
  info "  compose:    $compose_dir"
  info "  ref:        $DEPLOY_TARGET_TYPE:$DEPLOY_TARGET_REF"
  info "  pull:       $([[ "$pull" -eq 1 ]] && echo yes || echo no)"
  info "  up:         $([[ "$up" -eq 1 ]] && echo yes || echo no)"
  [[ -n "$image_repo" ]] && info "  image_repo: $image_repo"
  [[ -n "$image_tag" ]] && info "  image_tag:  $image_tag"

  [[ -n "$image_repo" ]] && export IMAGE_REPO="$image_repo"
  [[ -n "$image_tag" ]] && export IMAGE_TAG="$image_tag"

  if [[ "$pull" -eq 1 ]]; then
    local -a pull_cmd=("${compose_prefix[@]}" pull)
    if [[ "${#services[@]}" -gt 0 ]]; then
      pull_cmd+=("${services[@]}")
    fi
    run_in_dir "$compose_dir" "${pull_cmd[@]}"
  fi

  if [[ "$up" -eq 1 ]]; then
    local -a up_cmd=("${compose_prefix[@]}" up)
    [[ "$detach" -eq 1 ]] && up_cmd+=(-d)
    [[ "$remove_orphans" -eq 1 ]] && up_cmd+=(--remove-orphans)
    if [[ "${#services[@]}" -gt 0 ]]; then
      up_cmd+=("${services[@]}")
    fi
    run_in_dir "$compose_dir" "${up_cmd[@]}"
    run_in_dir "$compose_dir" "${compose_prefix[@]}" ps
  fi
}

main "$@"
