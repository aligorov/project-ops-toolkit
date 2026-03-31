#!/usr/bin/env bash

set -Eeuo pipefail

die() {
  echo "Error: $*" >&2
  exit 1
}

warn() {
  echo "Warning: $*" >&2
}

info() {
  echo "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

is_semver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

extract_config_arg() {
  local prev=""
  local arg=""
  for arg in "$@"; do
    case "$arg" in
      --config=*)
        printf '%s\n' "${arg#*=}"
        return 0
        ;;
    esac
    if [[ "$prev" == "--config" ]]; then
      printf '%s\n' "$arg"
      return 0
    fi
    prev="$arg"
  done
  return 1
}

load_config_if_requested() {
  local config_file=""
  config_file="$(extract_config_arg "$@" || true)"
  if [[ -z "$config_file" ]]; then
    return 0
  fi
  [[ -f "$config_file" ]] || die "config file not found: $config_file"
  # shellcheck source=/dev/null
  source "$config_file"
}

path_abs() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  (
    cd "$PWD/$value" >/dev/null 2>&1 && pwd -P
  ) || return 1
}

path_from_cwd() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s/%s\n' "$PWD" "$value"
}

make_relative_to_root() {
  local root="$1"
  local path="$2"
  if [[ "$path" = /* ]]; then
    case "$path" in
      "$root")
        printf '.\n'
        ;;
      "$root"/*)
        printf '%s\n' "${path#"$root"/}"
        ;;
      *)
        die "path is outside root dir: $path"
        ;;
    esac
  else
    printf '%s\n' "$path"
  fi
}

quote_cmd() {
  local arg=""
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
}

run_cmd() {
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] '
    quote_cmd "$@"
    return 0
  fi
  "$@"
}

run_in_dir() {
  local dir="$1"
  shift
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] cd %q && ' "$dir"
    quote_cmd "$@"
    return 0
  fi
  (
    cd "$dir"
    "$@"
  )
}

write_text_file() {
  local file="$1"
  local value="$2"
  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] write %q to %q\n' "$value" "$file"
    return 0
  fi
  printf '%s\n' "$value" > "$file"
}

detect_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return 0
  fi
  die "docker compose is not available"
}
