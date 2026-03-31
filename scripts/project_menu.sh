#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE_DIR="$WORKSPACE_DIR/profiles"
SECRET_DIR="$WORKSPACE_DIR/secrets"
RELEASE_SCRIPT="$SCRIPT_DIR/project_release.sh"
REMOTE_DEPLOY_SCRIPT="$SCRIPT_DIR/remote_deploy.sh"
REPO_INIT_SCRIPT="$SCRIPT_DIR/project_repo_init.sh"

# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PARSED_ARRAY=()

trim_value() {
  local value="${1:-}"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

slugify_name() {
  local value=""
  value="$(printf '%s' "${1:-project}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')"
  value="${value#-}"
  value="${value%-}"
  [[ -n "$value" ]] || value="project"
  printf '%s\n' "$value"
}

join_csv() {
  local first=1
  local item=""
  for item in "$@"; do
    [[ -n "$item" ]] || continue
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$item"
      first=0
    else
      printf ', %s' "$item"
    fi
  done
  printf '\n'
}

parse_csv_array() {
  local input="${1:-}"
  local item=""
  local -a raw_items=()
  PARSED_ARRAY=()
  IFS=',' read -r -a raw_items <<< "$input"
  for item in "${raw_items[@]-}"; do
    item="$(trim_value "$item")"
    [[ -n "$item" ]] && PARSED_ARRAY+=("$item")
  done
}

prompt_text() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value" >&2
  else
    printf '%s: ' "$label" >&2
  fi
  IFS= read -r answer
  [[ -n "$answer" ]] || answer="$default_value"
  printf '%s\n' "$answer"
}

prompt_secret() {
  local label="$1"
  local default_value="${2:-}"
  local answer=""

  if [[ -n "$default_value" ]]; then
    printf '%s [скрыто, Enter оставить]: ' "$label" >&2
  else
    printf '%s [ввод скрыт]: ' "$label" >&2
  fi
  IFS= read -r -s answer
  printf '\n' >&2
  [[ -n "$answer" ]] || answer="$default_value"
  printf '%s\n' "$answer"
}

prompt_yes_no() {
  local label="$1"
  local default_value="${2:-1}"
  local suffix="[Y/n]"
  local answer=""

  [[ "$default_value" -eq 1 ]] || suffix="[y/N]"

  while true; do
    printf '%s %s: ' "$label" "$suffix" >&2
    IFS= read -r answer
    answer="$(trim_value "$answer")"
    if [[ -z "$answer" ]]; then
      printf '%s\n' "$default_value"
      return 0
    fi
    case "$answer" in
      y|Y|yes|YES|да|ДА)
        printf '1\n'
        return 0
        ;;
      n|N|no|NO|нет|НЕТ)
        printf '0\n'
        return 0
        ;;
      *)
        echo "Введите y или n." >&2
        ;;
    esac
  done
}

select_menu_option() {
  local title="$1"
  shift
  local index=1
  local answer=""
  local max="$#"
  local option=""

  echo >&2
  echo "$title" >&2
  for option in "$@"; do
    echo "  $index. $option" >&2
    index=$((index + 1))
  done

  while true; do
    printf 'Выбор: ' >&2
    IFS= read -r answer
    if [[ "$answer" =~ ^[0-9]+$ ]] && [[ "$answer" -ge 1 ]] && [[ "$answer" -le "$max" ]]; then
      printf '%s\n' "$answer"
      return 0
    fi
    echo "Введите число от 1 до $max." >&2
  done
}

prompt_enum() {
  local label="$1"
  local default_value="$2"
  shift 2
  local -a options=("$@")
  local answer=""
  local option=""

  while true; do
    printf '%s [%s] (варианты: %s): ' "$label" "$default_value" "$(join_csv "${options[@]}")" >&2
    IFS= read -r answer
    answer="$(trim_value "$answer")"
    [[ -n "$answer" ]] || answer="$default_value"
    for option in "${options[@]}"; do
      if [[ "$answer" == "$option" ]]; then
        printf '%s\n' "$answer"
        return 0
      fi
    done
    echo "Допустимые значения: $(join_csv "${options[@]}")." >&2
  done
}

ensure_state_dirs() {
  mkdir -p "$PROFILE_DIR" "$SECRET_DIR"
}

profile_path_from_slug() {
  printf '%s/%s.profile.env\n' "$PROFILE_DIR" "$1"
}

secret_path_from_slug() {
  printf '%s/%s.deploy.env\n' "$SECRET_DIR" "$1"
}

list_profile_paths() {
  find "$PROFILE_DIR" -maxdepth 1 -type f -name '*.profile.env' | sort
}

choose_profile_path() {
  local -a profiles=()
  local path=""
  local choice=0

  while IFS= read -r path; do
    profiles+=("$path")
  done < <(list_profile_paths)

  if [[ "${#profiles[@]}" -eq 0 ]]; then
    warn "Профилей пока нет. Сначала создайте профиль."
    return 1
  fi

  echo >&2
  echo "Доступные профили:" >&2
  for choice in "${!profiles[@]}"; do
    echo "  $((choice + 1)). $(basename "${profiles[$choice]}" .profile.env)" >&2
  done

  while true; do
    printf 'Выберите профиль: ' >&2
    IFS= read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#profiles[@]}" ]]; then
      printf '%s\n' "${profiles[$((choice - 1))]}"
      return 0
    fi
    echo "Введите число от 1 до ${#profiles[@]}." >&2
  done
}

detect_git_remote_url() {
  local root_dir="$1"
  local remote_name="$2"
  git -C "$root_dir" remote get-url "$remote_name" 2>/dev/null || true
}

detect_git_branch() {
  local root_dir="$1"
  git -C "$root_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

split_repo_slug() {
  local slug="${1:-}"
  local prefix="${2:-}"
  if [[ "$slug" =~ ^([^/]+)/([^/]+)$ ]]; then
    printf -v "${prefix}_OWNER" '%s' "${BASH_REMATCH[1]}"
    printf -v "${prefix}_REPO" '%s' "${BASH_REMATCH[2]}"
    return 0
  fi
  printf -v "${prefix}_OWNER" '%s' ""
  printf -v "${prefix}_REPO" '%s' ""
  return 1
}

detect_package_version() {
  local root_dir="$1"
  local package_path="$root_dir/package.json"
  [[ -f "$package_path" ]] || return 1
  node --input-type=module - "$package_path" <<'EOF'
import fs from "node:fs";

const file = process.argv[2];
const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
if (parsed && typeof parsed.version === "string") {
  process.stdout.write(parsed.version);
}
EOF
}

write_var_line() {
  local file="$1"
  local name="$2"
  local value="$3"
  printf '%s=%q\n' "$name" "$value" >> "$file"
}

write_array_line() {
  local file="$1"
  local name="$2"
  shift 2
  local item=""
  printf '%s=(' "$name" >> "$file"
  for item in "$@"; do
    printf ' %q' "$item" >> "$file"
  done
  printf ' )\n' >> "$file"
}

write_profile_file() {
  local profile_path="$1"
  local -a release_package_jsons=("${!2}")
  local -a compose_files=("${!3}")
  local -a deploy_services=("${!4}")

  : > "$profile_path"
  echo "# shellcheck shell=bash" >> "$profile_path"
  write_var_line "$profile_path" "PROJECT_NAME" "$PROFILE_PROJECT_NAME"
  write_var_line "$profile_path" "ROOT_DIR" "$PROFILE_ROOT_DIR"
  write_var_line "$profile_path" "RELEASE_REPO" "$PROFILE_RELEASE_REPO"
  write_var_line "$profile_path" "IMAGE_REPO" "$PROFILE_RELEASE_REPO"
  write_var_line "$profile_path" "VERSION_FILE" "$PROFILE_VERSION_FILE"
  write_var_line "$profile_path" "DOCKERFILE" "$PROFILE_DOCKERFILE"
  write_var_line "$profile_path" "BUILD_CONTEXT" "$PROFILE_BUILD_CONTEXT"
  write_var_line "$profile_path" "PLATFORM" "$PROFILE_PLATFORM"
  write_var_line "$profile_path" "PUSH_LATEST" "$PROFILE_PUSH_LATEST"
  write_var_line "$profile_path" "RELEASE_GIT_ENABLED" "$PROFILE_RELEASE_GIT_ENABLED"
  write_var_line "$profile_path" "GIT_REMOTE" "$PROFILE_GIT_REMOTE"
  write_var_line "$profile_path" "GIT_BRANCH" "$PROFILE_GIT_BRANCH"
  write_var_line "$profile_path" "GIT_TAG_PREFIX" "$PROFILE_GIT_TAG_PREFIX"
  write_var_line "$profile_path" "GIT_PROTOCOL" "$PROFILE_GIT_PROTOCOL"
  write_var_line "$profile_path" "GITHUB_OWNER" "$PROFILE_GITHUB_OWNER"
  write_var_line "$profile_path" "GITHUB_REPO_NAME" "$PROFILE_GITHUB_REPO_NAME"
  write_var_line "$profile_path" "GITHUB_REPO_VISIBILITY" "$PROFILE_GITHUB_REPO_VISIBILITY"
  write_var_line "$profile_path" "GITHUB_REPO_DESCRIPTION" "$PROFILE_GITHUB_REPO_DESCRIPTION"
  write_array_line "$profile_path" "RELEASE_PACKAGE_JSONS" "${release_package_jsons[@]-}"

  write_var_line "$profile_path" "REPO_URL" "$PROFILE_REPO_URL"
  write_var_line "$profile_path" "APP_DIR" "$PROFILE_APP_DIR"
  write_var_line "$profile_path" "DEPLOY_REF" "latest"
  write_var_line "$profile_path" "REF_TYPE" "auto"
  write_var_line "$profile_path" "MAIN_BRANCH" "$PROFILE_MAIN_BRANCH"
  write_var_line "$profile_path" "COMPOSE_DIR" "$PROFILE_COMPOSE_DIR"
  write_var_line "$profile_path" "COMPOSE_PROJECT_NAME" "$PROFILE_COMPOSE_PROJECT_NAME"
  write_array_line "$profile_path" "DEPLOY_COMPOSE_FILES" "${compose_files[@]-}"
  write_array_line "$profile_path" "DEPLOY_SERVICES" "${deploy_services[@]-}"

  write_var_line "$profile_path" "REMOTE_HOST" "$PROFILE_REMOTE_HOST"
  write_var_line "$profile_path" "REMOTE_USER" "$PROFILE_REMOTE_USER"
  write_var_line "$profile_path" "REMOTE_PORT" "$PROFILE_REMOTE_PORT"
  write_var_line "$profile_path" "REMOTE_TOOLKIT_DIR" "$PROFILE_REMOTE_TOOLKIT_DIR"
  write_var_line "$profile_path" "REMOTE_PROFILE_PATH" "$PROFILE_REMOTE_PROFILE_PATH"
  write_var_line "$profile_path" "REMOTE_SECRETS_PATH" "$PROFILE_REMOTE_SECRETS_PATH"
  write_var_line "$profile_path" "REMOTE_SSH_KEY" "$PROFILE_REMOTE_SSH_KEY"
  write_var_line "$profile_path" "LOCAL_DEPLOY_SECRETS_FILE" "$PROFILE_LOCAL_SECRETS_FILE"
  write_var_line "$profile_path" "DEPLOY_ENV_TEMPLATE" "$PROFILE_DEPLOY_ENV_TEMPLATE"
  write_array_line "$profile_path" "DEPLOY_ENV_FILES" "$PROFILE_REMOTE_SECRETS_PATH"
}

ensure_version_file_if_missing() {
  local root_dir="$1"
  local version_file="$2"
  local package_version=""
  local create_now=0
  local value=""

  if [[ -f "$root_dir/$version_file" ]]; then
    return 0
  fi

  echo
  warn "Файл версии не найден: $root_dir/$version_file"
  package_version="$(detect_package_version "$root_dir" 2>/dev/null || true)"
  create_now="$(prompt_yes_no "Создать VERSION сейчас?" 1)"
  if [[ "$create_now" -ne 1 ]]; then
    return 0
  fi

  if [[ -n "$package_version" ]]; then
    value="$(prompt_text "Версия для файла VERSION" "$package_version")"
  else
    value="$(prompt_text "Версия для файла VERSION" "0.1.0")"
  fi

  mkdir -p "$(dirname "$root_dir/$version_file")"
  printf '%s\n' "$value" > "$root_dir/$version_file"
  info "Создан $root_dir/$version_file"
}

extract_env_key() {
  local line="${1%%#*}"
  line="$(trim_value "$line")"
  [[ -n "$line" ]] || return 1
  if [[ "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

read_existing_env_value() {
  local file="$1"
  local key="$2"
  local line=""

  [[ -f "$file" ]] || return 0
  while IFS= read -r line; do
    if [[ "$line" =~ ^${key}=(.*)$ ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
    fi
  done < "$file"
}

write_secret_file_from_template() {
  local template_path="$1"
  local output_file="$2"
  local current_file="$3"
  local tmp_file="$output_file.tmp"
  local line=""
  local key=""
  local existing_value=""
  local answer=""
  local hidden=0

  : > "$tmp_file"

  if [[ -f "$template_path" ]]; then
    while IFS= read -r line; do
      key="$(extract_env_key "$line" || true)"
      [[ -n "$key" ]] || continue
      existing_value="$(read_existing_env_value "$current_file" "$key")"
      hidden=0
      case "$key" in
        *TOKEN*|*PASSWORD*|*SECRET*|*KEY*)
          hidden=1
          ;;
      esac

      if [[ "$hidden" -eq 1 ]]; then
        answer="$(prompt_secret "$key" "$existing_value")"
      else
        answer="$(prompt_text "$key" "$existing_value")"
      fi
      printf '%s=%s\n' "$key" "$answer" >> "$tmp_file"
    done < "$template_path"
  fi

  echo
  echo "Дополнительные переменные можно добавить вручную."
  echo "Формат: KEY=value. Пустая строка завершает ввод."
  while true; do
    answer="$(prompt_text "extra KEY=value" "")"
    [[ -n "$answer" ]] || break
    printf '%s\n' "$answer" >> "$tmp_file"
  done

  mv "$tmp_file" "$output_file"
  chmod 600 "$output_file"
  info "Secrets сохранены в $output_file"
}

edit_secrets_wizard() {
  local profile_path=""
  local secret_file=""
  local template_path=""

  profile_path="$(choose_profile_path)" || return 0
  # shellcheck source=/dev/null
  source "$profile_path"

  secret_file="${LOCAL_DEPLOY_SECRETS_FILE:-$(secret_path_from_slug "$(basename "$profile_path" .profile.env)")}"
  template_path="${DEPLOY_ENV_TEMPLATE:-}"
  if [[ -z "$template_path" ]]; then
    template_path="$(prompt_text "Путь к шаблону env" "")"
  fi
  mkdir -p "$(dirname "$secret_file")"
  write_secret_file_from_template "$template_path" "$secret_file" "$secret_file"
}

setup_profile_wizard() {
  local profile_name=""
  local slug=""
  local profile_path=""
  local default_root=""
  local current_branch=""
  local current_remote=""
  local current_remote_slug=""
  local current_remote_protocol=""
  local current_owner=""
  local current_repo=""
  local default_owner=""
  local default_protocol=""
  local derived_repo_url=""
  local package_csv=""
  local compose_csv=""
  local services_csv=""
  local create_secrets=0
  local -a release_package_jsons=()
  local -a compose_files=()
  local -a deploy_services=()

  ensure_state_dirs
  echo
  echo "Создание/обновление профиля проекта"
  profile_name="$(prompt_text "Имя профиля" "")"
  [[ -n "$profile_name" ]] || {
    warn "Имя профиля пустое."
    return 0
  }

  slug="$(slugify_name "$profile_name")"
  profile_path="$(profile_path_from_slug "$slug")"

  if [[ -f "$profile_path" ]]; then
    # shellcheck source=/dev/null
    source "$profile_path"
    info "Обновляем существующий профиль: $profile_path"
  fi

  PROFILE_PROJECT_NAME="$(prompt_text "Название проекта" "${PROJECT_NAME:-$profile_name}")"
  default_root="${ROOT_DIR:-}"
  PROFILE_ROOT_DIR="$(prompt_text "Локальный путь к репозиторию" "$default_root")"

  if [[ -d "$PROFILE_ROOT_DIR/.git" ]]; then
    current_branch="$(detect_git_branch "$PROFILE_ROOT_DIR")"
    current_remote="$(detect_git_remote_url "$PROFILE_ROOT_DIR" "${GIT_REMOTE:-origin}")"
  else
    current_branch="${GIT_BRANCH:-main}"
    current_remote="${REPO_URL:-}"
  fi

  current_remote_slug="$(parse_github_repo_slug "$current_remote" || true)"
  current_remote_protocol="$(parse_github_protocol "$current_remote" || true)"
  split_repo_slug "$current_remote_slug" "CURRENT_REMOTE"
  current_owner="${CURRENT_REMOTE_OWNER:-}"
  current_repo="${CURRENT_REMOTE_REPO:-}"
  default_owner="$(detect_gh_login || true)"
  default_protocol="$(detect_gh_git_protocol || true)"

  PROFILE_RELEASE_REPO="$(prompt_text "Docker image repo (user/image)" "${RELEASE_REPO:-${IMAGE_REPO:-}}")"
  PROFILE_VERSION_FILE="$(prompt_text "Файл версии" "${VERSION_FILE:-VERSION}")"
  PROFILE_DOCKERFILE="$(prompt_text "Путь к Dockerfile" "${DOCKERFILE:-Dockerfile}")"
  PROFILE_BUILD_CONTEXT="$(prompt_text "Build context" "${BUILD_CONTEXT:-.}")"
  PROFILE_PLATFORM="$(prompt_text "Платформа buildx" "${PLATFORM:-linux/amd64}")"
  PROFILE_PUSH_LATEST="$(prompt_yes_no "Публиковать тег latest вместе с версией?" "${PUSH_LATEST:-1}")"
  PROFILE_RELEASE_GIT_ENABLED="$(prompt_yes_no "По умолчанию делать git commit/push/tag?" "${RELEASE_GIT_ENABLED:-1}")"
  PROFILE_GIT_REMOTE="$(prompt_text "Git remote для релиза" "${GIT_REMOTE:-origin}")"
  PROFILE_GIT_BRANCH="$(prompt_text "Git branch для релиза" "${GIT_BRANCH:-$current_branch}")"
  PROFILE_GIT_TAG_PREFIX="$(prompt_text "Префикс git tag" "${GIT_TAG_PREFIX:-v}")"
  PROFILE_GITHUB_OWNER="$(prompt_text "GitHub owner/org" "${GITHUB_OWNER:-${current_owner:-$default_owner}}")"
  PROFILE_GITHUB_REPO_NAME="$(prompt_text "GitHub repo name" "${GITHUB_REPO_NAME:-${current_repo:-$slug}}")"
  PROFILE_GITHUB_REPO_VISIBILITY="$(prompt_enum "GitHub visibility" "${GITHUB_REPO_VISIBILITY:-private}" "public" "private")"
  PROFILE_GITHUB_REPO_DESCRIPTION="$(prompt_text "GitHub repo description" "${GITHUB_REPO_DESCRIPTION:-}")"
  PROFILE_GIT_PROTOCOL="$(prompt_enum "Git protocol для origin" "${GIT_PROTOCOL:-${current_remote_protocol:-${default_protocol:-https}}}" "https" "ssh")"

  package_csv="$(join_csv "${RELEASE_PACKAGE_JSONS[@]-}")"
  if [[ -z "$package_csv" ]]; then
    [[ -f "$PROFILE_ROOT_DIR/package.json" ]] && package_csv="package.json"
  fi
  package_csv="$(prompt_text "package.json для синхронизации версии (csv)" "$package_csv")"
  parse_csv_array "$package_csv"
  release_package_jsons=("${PARSED_ARRAY[@]-}")

  derived_repo_url=""
  if [[ -n "$PROFILE_GITHUB_OWNER" && -n "$PROFILE_GITHUB_REPO_NAME" ]]; then
    derived_repo_url="$(remote_url_for_protocol "$PROFILE_GITHUB_OWNER" "$PROFILE_GITHUB_REPO_NAME" "$PROFILE_GIT_PROTOCOL")"
  fi
  PROFILE_REPO_URL="$(prompt_text "Git URL для deploy на сервер" "${REPO_URL:-${current_remote:-$derived_repo_url}}")"
  PROFILE_APP_DIR="$(prompt_text "Папка приложения на сервере" "${APP_DIR:-/opt/$slug}")"
  PROFILE_MAIN_BRANCH="$(prompt_text "Основная ветка deploy" "${MAIN_BRANCH:-$PROFILE_GIT_BRANCH}")"
  PROFILE_COMPOSE_DIR="$(prompt_text "Каталог для docker compose внутри APP_DIR" "${COMPOSE_DIR:-.}")"

  compose_csv="$(join_csv "${DEPLOY_COMPOSE_FILES[@]-}")"
  if [[ -z "$compose_csv" && -f "$PROFILE_ROOT_DIR/docker-compose.yml" ]]; then
    compose_csv="docker-compose.yml"
  fi
  compose_csv="$(prompt_text "Compose files (csv)" "$compose_csv")"
  parse_csv_array "$compose_csv"
  compose_files=("${PARSED_ARRAY[@]-}")

  PROFILE_COMPOSE_PROJECT_NAME="$(prompt_text "Имя docker compose проекта" "${COMPOSE_PROJECT_NAME:-$slug}")"
  services_csv="$(join_csv "${DEPLOY_SERVICES[@]-}")"
  services_csv="$(prompt_text "Сервисы compose для deploy (csv, можно пусто)" "$services_csv")"
  parse_csv_array "$services_csv"
  deploy_services=("${PARSED_ARRAY[@]-}")

  PROFILE_REMOTE_HOST="$(prompt_text "SSH host сервера deploy" "${REMOTE_HOST:-}")"
  PROFILE_REMOTE_USER="$(prompt_text "SSH user" "${REMOTE_USER:-root}")"
  PROFILE_REMOTE_PORT="$(prompt_text "SSH port" "${REMOTE_PORT:-22}")"
  PROFILE_REMOTE_TOOLKIT_DIR="$(prompt_text "Каталог toolkit на сервере" "${REMOTE_TOOLKIT_DIR:-/opt/project-ops}")"
  PROFILE_REMOTE_SSH_KEY="$(prompt_text "SSH key path (можно пусто)" "${REMOTE_SSH_KEY:-}")"
  PROFILE_REMOTE_PROFILE_PATH="${REMOTE_PROFILE_PATH:-$PROFILE_REMOTE_TOOLKIT_DIR/profiles/$slug.profile.env}"
  PROFILE_REMOTE_SECRETS_PATH="${REMOTE_SECRETS_PATH:-$PROFILE_REMOTE_TOOLKIT_DIR/secrets/$slug.deploy.env}"
  PROFILE_LOCAL_SECRETS_FILE="${LOCAL_DEPLOY_SECRETS_FILE:-$(secret_path_from_slug "$slug")}"

  if [[ -n "${DEPLOY_ENV_TEMPLATE:-}" ]]; then
    PROFILE_DEPLOY_ENV_TEMPLATE="$(prompt_text "Локальный шаблон env" "$DEPLOY_ENV_TEMPLATE")"
  elif [[ -f "$PROFILE_ROOT_DIR/.env.example" ]]; then
    PROFILE_DEPLOY_ENV_TEMPLATE="$(prompt_text "Локальный шаблон env" "$PROFILE_ROOT_DIR/.env.example")"
  else
    PROFILE_DEPLOY_ENV_TEMPLATE="$(prompt_text "Локальный шаблон env" "")"
  fi

  write_profile_file "$profile_path" release_package_jsons[@] compose_files[@] deploy_services[@]
  info "Профиль сохранён: $profile_path"

  ensure_version_file_if_missing "$PROFILE_ROOT_DIR" "$PROFILE_VERSION_FILE"

  create_secrets="$(prompt_yes_no "Сразу заполнить secrets для deploy?" 1)"
  if [[ "$create_secrets" -eq 1 ]]; then
    mkdir -p "$(dirname "$PROFILE_LOCAL_SECRETS_FILE")"
    write_secret_file_from_template "$PROFILE_DEPLOY_ENV_TEMPLATE" "$PROFILE_LOCAL_SECRETS_FILE" "$PROFILE_LOCAL_SECRETS_FILE"
  fi
}

run_repo_init_wizard() {
  local dry_run="${1:-0}"
  local profile_path=""
  local push_after_setup=0
  local cmd=()

  profile_path="$(choose_profile_path)" || return 0
  # shellcheck source=/dev/null
  source "$profile_path"

  push_after_setup="$(prompt_yes_no "Сразу выполнить git push после настройки origin?" 0)"

  cmd=("$REPO_INIT_SCRIPT" --config "$profile_path")
  [[ "$push_after_setup" -eq 1 ]] && cmd+=(--push)
  [[ "$dry_run" -eq 1 ]] && cmd+=(--dry-run)

  echo
  echo "Команда repo-init:"
  quote_cmd "${cmd[@]}"
  run_cmd "${cmd[@]}"
}

show_profiles() {
  local path=""
  local count=0
  echo
  echo "Профили:"
  while IFS= read -r path; do
    count=$((count + 1))
    echo "  - $(basename "$path" .profile.env)"
  done < <(list_profile_paths)
  [[ "$count" -gt 0 ]] || echo "  нет профилей"
}

show_profile_details() {
  local profile_path=""
  profile_path="$(choose_profile_path)" || return 0
  echo
  echo "Профиль: $profile_path"
  sed -n '1,240p' "$profile_path"
}

run_release_wizard() {
  local dry_run="${1:-0}"
  local profile_path=""
  local choice=0
  local tag=""
  local bump=""
  local use_git=0
  local git_all=0
  local no_cache=0
  local multi_arch=0
  local push_latest=1
  local cmd=()

  profile_path="$(choose_profile_path)" || return 0
  # shellcheck source=/dev/null
  source "$profile_path"

  ensure_version_file_if_missing "${ROOT_DIR:-}" "${VERSION_FILE:-VERSION}"

  choice="$(select_menu_option "Тип релиза" \
    "Явный номер сборки / тег" \
    "Bump patch" \
    "Bump minor" \
    "Bump major")"

  case "$choice" in
    1)
      tag="$(prompt_text "Тег / номер сборки" "${RELEASE_TAG:-}")"
      [[ -n "$tag" ]] || {
        warn "Тег пустой."
        return 0
      }
      ;;
    2) bump="patch" ;;
    3) bump="minor" ;;
    4) bump="major" ;;
  esac

  use_git="$(prompt_yes_no "Выполнить git commit/push/tag?" "${RELEASE_GIT_ENABLED:-1}")"
  if [[ "$use_git" -eq 1 ]]; then
    git_all="$(prompt_yes_no "Добавить все локальные изменения в release commit?" 0)"
  fi
  multi_arch="$(prompt_yes_no "Собирать multi-arch (amd64+arm64)?" 0)"
  no_cache="$(prompt_yes_no "Собирать без cache?" 0)"
  push_latest="$(prompt_yes_no "Пушить тег latest?" "${PUSH_LATEST:-1}")"

  cmd=("$RELEASE_SCRIPT" --config "$profile_path")
  [[ -n "$tag" ]] && cmd+=(--tag "$tag")
  [[ -n "$bump" ]] && cmd+=(--bump "$bump")
  [[ "$use_git" -eq 1 ]] && cmd+=(--git)
  [[ "$git_all" -eq 1 ]] && cmd+=(--git-all)
  [[ "$multi_arch" -eq 1 ]] && cmd+=(--multi-arch)
  [[ "$no_cache" -eq 1 ]] && cmd+=(--no-cache)
  [[ "$push_latest" -eq 0 ]] && cmd+=(--no-latest)
  [[ "$dry_run" -eq 1 ]] && cmd+=(--dry-run)

  echo
  echo "Команда релиза:"
  quote_cmd "${cmd[@]}"
  run_cmd "${cmd[@]}"
}

run_deploy_wizard() {
  local dry_run="${1:-0}"
  local profile_path=""
  local ref=""
  local image_tag=""
  local upload_secrets=1
  local cmd=()

  profile_path="$(choose_profile_path)" || return 0
  # shellcheck source=/dev/null
  source "$profile_path"

  ref="$(prompt_text "Git ref для deploy" "${DEPLOY_REF:-latest}")"
  image_tag="$(prompt_text "IMAGE_TAG для deploy" "${IMAGE_TAG:-$ref}")"
  upload_secrets="$(prompt_yes_no "Загрузить secrets на сервер перед deploy?" 1)"

  cmd=("$REMOTE_DEPLOY_SCRIPT" --config "$profile_path" --ref "$ref" --image-tag "$image_tag")
  [[ "$upload_secrets" -eq 0 ]] && cmd+=(--skip-upload-secrets)
  [[ "$dry_run" -eq 1 ]] && cmd+=(--dry-run)

  echo
  echo "Команда deploy:"
  quote_cmd "${cmd[@]}"
  run_cmd "${cmd[@]}"
}

menu_loop() {
  local choice=""
  ensure_state_dirs

  while true; do
    echo
    echo "=============================="
    echo " Project Release/Deploy Menu"
    echo "=============================="
    echo "1. Создать или обновить профиль проекта"
    echo "2. Показать список профилей"
    echo "3. Показать содержимое профиля"
    echo "4. Заполнить или обновить secrets"
    echo "5. Создать или подключить GitHub repo (public/private)"
    echo "6. Dry-run GitHub repo setup"
    echo "7. Запустить релиз в Git + Docker"
    echo "8. Dry-run релиза"
    echo "9. Деплой на удалённый сервер по SSH"
    echo "10. Dry-run деплоя"
    echo "0. Выход"
    printf 'Выберите пункт: '
    IFS= read -r choice

    case "$choice" in
      1) setup_profile_wizard ;;
      2) show_profiles ;;
      3) show_profile_details ;;
      4) edit_secrets_wizard ;;
      5) run_repo_init_wizard 0 ;;
      6) run_repo_init_wizard 1 ;;
      7) run_release_wizard 0 ;;
      8) run_release_wizard 1 ;;
      9) run_deploy_wizard 0 ;;
      10) run_deploy_wizard 1 ;;
      0) exit 0 ;;
      *) echo "Неизвестный пункт." ;;
    esac
  done
}

menu_loop "$@"
