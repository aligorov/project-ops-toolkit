#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage_remote_deploy() {
  cat <<'EOF'
Usage:
  scripts/remote_deploy.sh --config PROFILE [options]

Copies toolkit + profile to a remote server over SSH and runs deploy there.

Options:
  --config FILE            Local profile config
  --ref REF                Override deploy ref on remote
  --image-tag TAG          Override IMAGE_TAG on remote
  --ssh-key FILE           SSH private key
  --skip-upload-profile    Do not upload profile file
  --skip-upload-secrets    Do not upload local secrets file
  --dry-run                Print commands without executing them
  -h, --help               Show help
EOF
}

append_line() {
  local file="$1"
  shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] append to %q: ' "$file"
    quote_cmd "$@"
    return 0
  fi
  printf '%s\n' "$*" >> "$file"
}

write_var_line() {
  local file="$1"
  local name="$2"
  local value="$3"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] write var %s=%q to %q\n' "$name" "$value" "$file"
    return 0
  fi
  printf '%s=%q\n' "$name" "$value" >> "$file"
}

write_array_line() {
  local file="$1"
  local name="$2"
  shift 2
  local item=""

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] write array %s to %q\n' "$name" "$file"
    return 0
  fi

  printf '%s=(' "$name" >> "$file"
  for item in "$@"; do
    printf ' %q' "$item" >> "$file"
  done
  printf ' )\n' >> "$file"
}

ensure_default_paths() {
  local profile_path="$1"
  local profile_base=""
  profile_base="$(basename "$profile_path")"
  profile_base="${profile_base%.profile.env}"

  [[ -n "${PROJECT_NAME:-}" ]] || PROJECT_NAME="$profile_base"
  [[ -n "${REMOTE_PORT:-}" ]] || REMOTE_PORT="22"
  [[ -n "${REMOTE_USER:-}" ]] || REMOTE_USER="root"
  [[ -n "${REMOTE_TOOLKIT_DIR:-}" ]] || REMOTE_TOOLKIT_DIR="/opt/project-ops"
  [[ -n "${REMOTE_PROFILE_PATH:-}" ]] || REMOTE_PROFILE_PATH="$REMOTE_TOOLKIT_DIR/profiles/${profile_base}.profile.env"
  [[ -n "${REMOTE_SECRETS_PATH:-}" ]] || REMOTE_SECRETS_PATH="$REMOTE_TOOLKIT_DIR/secrets/${profile_base}.deploy.env"
  [[ -n "${LOCAL_DEPLOY_SECRETS_FILE:-}" ]] || LOCAL_DEPLOY_SECRETS_FILE="$(cd "$(dirname "$profile_path")/.." && pwd)/secrets/${profile_base}.deploy.env"
}

write_remote_profile_copy() {
  local output_file="$1"
  local -a compose_files=()
  local -a env_files=()
  local -a services=()
  local item=""

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

  if [[ -n "${REMOTE_SECRETS_PATH:-}" ]]; then
    env_files+=("$REMOTE_SECRETS_PATH")
  fi

  if [[ "${DRY_RUN:-0}" -eq 0 ]]; then
    : > "$output_file"
  fi

  append_line "$output_file" "# shellcheck shell=bash"
  [[ -n "${PROJECT_NAME:-}" ]] && write_var_line "$output_file" "PROJECT_NAME" "$PROJECT_NAME"
  [[ -n "${REPO_URL:-}" ]] && write_var_line "$output_file" "REPO_URL" "$REPO_URL"
  [[ -n "${APP_DIR:-}" ]] && write_var_line "$output_file" "APP_DIR" "$APP_DIR"
  [[ -n "${DEPLOY_REF:-}" ]] && write_var_line "$output_file" "DEPLOY_REF" "$DEPLOY_REF"
  [[ -n "${REF_TYPE:-}" ]] && write_var_line "$output_file" "REF_TYPE" "$REF_TYPE"
  [[ -n "${MAIN_BRANCH:-}" ]] && write_var_line "$output_file" "MAIN_BRANCH" "$MAIN_BRANCH"
  [[ -n "${COMPOSE_DIR:-}" ]] && write_var_line "$output_file" "COMPOSE_DIR" "$COMPOSE_DIR"
  [[ -n "${COMPOSE_PROJECT_NAME:-}" ]] && write_var_line "$output_file" "COMPOSE_PROJECT_NAME" "$COMPOSE_PROJECT_NAME"
  [[ -n "${IMAGE_REPO:-}" ]] && write_var_line "$output_file" "IMAGE_REPO" "$IMAGE_REPO"
  [[ -n "${IMAGE_TAG:-}" ]] && write_var_line "$output_file" "IMAGE_TAG" "$IMAGE_TAG"
  write_array_line "$output_file" "DEPLOY_COMPOSE_FILES" "${compose_files[@]-}"
  write_array_line "$output_file" "DEPLOY_ENV_FILES" "${env_files[@]-}"
  write_array_line "$output_file" "DEPLOY_SERVICES" "${services[@]-}"
}

main() {
  local config_file=""
  local ref=""
  local image_tag_override=""
  local ssh_key=""
  local upload_profile=1
  local upload_secrets=1
  local ssh_target=""
  local ssh_port=""
  local tmp_dir=""
  local tmp_profile=""
  local remote_script_dir=""
  local remote_lib_dir=""
  local remote_profile_dir=""
  local remote_secrets_dir=""
  local remote_cmd=""
  local -a ssh_base=()
  local -a scp_base=()

  DRY_RUN=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage_remote_deploy
        exit 0
        ;;
      --config|--config=*)
        if [[ "$1" == *=* ]]; then
          config_file="${1#*=}"
          shift
        else
          config_file="${2:-}"
          shift 2
        fi
        ;;
      --ref)
        ref="${2:-}"
        shift 2
        ;;
      --image-tag)
        image_tag_override="${2:-}"
        shift 2
        ;;
      --ssh-key)
        ssh_key="${2:-}"
        shift 2
        ;;
      --skip-upload-profile)
        upload_profile=0
        shift
        ;;
      --skip-upload-secrets)
        upload_secrets=0
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      *)
        die "unknown remote deploy option: $1"
        ;;
    esac
  done

  [[ -n "$config_file" ]] || die "--config is required"
  [[ -f "$config_file" ]] || die "config file not found: $config_file"
  # shellcheck source=/dev/null
  source "$config_file"
  [[ -n "$ssh_key" ]] || ssh_key="${REMOTE_SSH_KEY:-}"

  ensure_default_paths "$config_file"
  [[ -n "${REMOTE_HOST:-}" ]] || die "REMOTE_HOST is required in profile"
  [[ -n "${APP_DIR:-}" ]] || die "APP_DIR is required in profile"
  [[ -n "${REPO_URL:-}" ]] || warn "REPO_URL is empty; first deploy on target host may fail"

  if [[ -n "$ref" ]]; then
    DEPLOY_REF="$ref"
  fi
  if [[ -n "$image_tag_override" ]]; then
    IMAGE_TAG="$image_tag_override"
  fi

  ssh_port="${REMOTE_PORT:-22}"
  ssh_target="${REMOTE_USER:-root}@${REMOTE_HOST}"
  remote_script_dir="$REMOTE_TOOLKIT_DIR/scripts"
  remote_lib_dir="$REMOTE_TOOLKIT_DIR/scripts/lib"
  remote_profile_dir="$(dirname "$REMOTE_PROFILE_PATH")"
  remote_secrets_dir="$(dirname "$REMOTE_SECRETS_PATH")"

  ssh_base=(ssh -p "$ssh_port")
  scp_base=(scp -P "$ssh_port")
  if [[ -n "$ssh_key" ]]; then
    ssh_base+=(-i "$ssh_key")
    scp_base+=(-i "$ssh_key")
  fi

  info "Remote deploy summary"
  info "  host:        $ssh_target"
  info "  toolkit_dir: $REMOTE_TOOLKIT_DIR"
  info "  app_dir:     $APP_DIR"
  info "  ref:         ${DEPLOY_REF:-latest}"
  info "  image_tag:   ${IMAGE_TAG:-}"
  [[ -n "${LOCAL_DEPLOY_SECRETS_FILE:-}" ]] && info "  local_env:    $LOCAL_DEPLOY_SECRETS_FILE"

  remote_cmd="mkdir -p $(printf %q "$remote_script_dir") $(printf %q "$remote_lib_dir") $(printf %q "$remote_profile_dir") $(printf %q "$remote_secrets_dir")"
  run_cmd "${ssh_base[@]}" "$ssh_target" "$remote_cmd"

  run_cmd "${scp_base[@]}" "$SCRIPT_DIR/project_ops.sh" "$ssh_target:$remote_script_dir/project_ops.sh"
  run_cmd "${scp_base[@]}" "$SCRIPT_DIR/project_deploy.sh" "$ssh_target:$remote_script_dir/project_deploy.sh"
  run_cmd "${scp_base[@]}" "$SCRIPT_DIR/lib/common.sh" "$ssh_target:$remote_lib_dir/common.sh"

  if [[ "$upload_profile" -eq 1 ]]; then
    tmp_dir="$(mktemp -d)"
    tmp_profile="$tmp_dir/$(basename "$REMOTE_PROFILE_PATH")"
    write_remote_profile_copy "$tmp_profile"
    run_cmd "${scp_base[@]}" "$tmp_profile" "$ssh_target:$REMOTE_PROFILE_PATH"
    [[ "${DRY_RUN:-0}" -eq 0 ]] && rm -rf "$tmp_dir"
  fi

  if [[ "$upload_secrets" -eq 1 && -n "${LOCAL_DEPLOY_SECRETS_FILE:-}" && -f "$LOCAL_DEPLOY_SECRETS_FILE" ]]; then
    run_cmd "${scp_base[@]}" "$LOCAL_DEPLOY_SECRETS_FILE" "$ssh_target:$REMOTE_SECRETS_PATH"
    run_cmd "${ssh_base[@]}" "$ssh_target" "chmod 600 $(printf %q "$REMOTE_SECRETS_PATH")"
  fi

  remote_cmd="chmod +x $(printf %q "$remote_script_dir/project_ops.sh") $(printf %q "$remote_script_dir/project_deploy.sh") && $(printf %q "$remote_script_dir/project_ops.sh") deploy --config $(printf %q "$REMOTE_PROFILE_PATH")"
  if [[ -n "$ref" ]]; then
    remote_cmd="$remote_cmd --ref $(printf %q "$ref")"
  fi
  if [[ -n "$image_tag_override" ]]; then
    remote_cmd="$remote_cmd --image-tag $(printf %q "$image_tag_override")"
  fi

  run_cmd "${ssh_base[@]}" "$ssh_target" "$remote_cmd"
}

main "$@"
