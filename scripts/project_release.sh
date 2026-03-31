#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage_release() {
  cat <<'EOF'
Usage:
  scripts/project_release.sh [options]

Universal Docker release flow:
  1) optional version bump
  2) docker buildx build --push
  3) optional git commit/tag/push

Options:
  --config FILE            Source trusted bash config before parsing options
  --root-dir DIR           Project root (default: current directory)
  --repo USER/IMAGE        Docker image repo (required)
  --tag TAG                Image tag (default: VERSION file or latest)
  --bump PART              patch|minor|major
  --version-file FILE      Version file relative to root (default: VERSION)
  --package-json FILE      package.json to sync version into, repeatable
  --dockerfile FILE        Dockerfile path relative to root (default: Dockerfile)
  --context DIR            Build context relative to root (default: .)
  --platform PLATFORMS     Build platform(s), default: linux/amd64
  --multi-arch             Use linux/amd64,linux/arm64
  --no-latest              Do not publish :latest alias
  --no-cache               Build without cache
  --git                    Also commit/push version files and git tag
  --git-all                With --git: commit all local changes
  --git-remote NAME        Git remote (default: origin)
  --git-branch NAME        Git branch (default: current branch)
  --git-tag-prefix PREFIX  Git tag prefix (default: v)
  --git-strict             Exit non-zero if git step fails
  --dry-run                Print commands without executing them
  -h, --help               Show help
EOF
}

read_version_value() {
  local root_dir="$1"
  local version_file="$2"
  local rel=""
  rel="$(make_relative_to_root "$root_dir" "$version_file")"
  [[ -f "$root_dir/$rel" ]] || return 1
  tr -d '[:space:]' < "$root_dir/$rel"
}

bump_semver() {
  local current="$1"
  local part="$2"
  local major=""
  local minor=""
  local patch=""

  [[ "$current" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid semantic version: $current"
  IFS='.' read -r major minor patch <<< "$current"

  case "$part" in
    patch) patch=$((patch + 1)) ;;
    minor) minor=$((minor + 1)); patch=0 ;;
    major) major=$((major + 1)); minor=0; patch=0 ;;
    *) die "--bump must be one of: patch|minor|major" ;;
  esac

  printf '%s.%s.%s\n' "$major" "$minor" "$patch"
}

sync_package_json_versions() {
  local root_dir="$1"
  local version="$2"
  shift 2
  local -a files=("$@")

  [[ "${#files[@]}" -gt 0 ]] || return 0
  require_cmd node

  if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
    printf '[dry-run] '
    quote_cmd node update-package-json-version "$version" "${files[@]}"
    return 0
  fi

  run_in_dir "$root_dir" node --input-type=module - "$version" "${files[@]}" <<'EOF'
import fs from "node:fs";

const [, , version, ...files] = process.argv;

for (const file of files) {
  if (!fs.existsSync(file)) continue;
  const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
  parsed.version = version;
  fs.writeFileSync(file, JSON.stringify(parsed, null, 2) + "\n");
}
EOF
}

git_remote_tag_commit() {
  local root_dir="$1"
  local tag_ref="$2"
  local remote="$3"
  local commit=""

  commit="$(git -C "$root_dir" ls-remote --tags "$remote" "refs/tags/${tag_ref}^{}" | awk 'NR==1{print $1}')"
  if [[ -z "$commit" ]]; then
    commit="$(git -C "$root_dir" ls-remote --tags "$remote" "refs/tags/${tag_ref}" | awk 'NR==1{print $1}')"
  fi
  printf '%s\n' "$commit"
}

git_remote_url() {
  local root_dir="$1"
  local remote="$2"
  git -C "$root_dir" remote get-url "$remote" 2>/dev/null || true
}

warn_github_https_auth() {
  local root_dir="$1"
  local remote="$2"
  local remote_url=""

  remote_url="$(git_remote_url "$root_dir" "$remote")"
  case "$remote_url" in
    https://github.com/*|http://github.com/*)
      warn "GitHub over HTTPS requires token-based auth or a credential helper."
      warn "Prefer SSH for automation:"
      warn "  git -C $root_dir remote set-url $remote git@github.com:ORG/REPO.git"
      ;;
  esac
}

git_unexpected_changes() {
  local root_dir="$1"
  shift
  local -a allowed=("$@")
  local line=""
  local path=""
  local allowed_item=""
  local found=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    path="${line:3}"
    found=0
    for allowed_item in "${allowed[@]-}"; do
      if [[ "$path" == "$allowed_item" ]]; then
        found=1
        break
      fi
    done
    [[ "$found" -eq 0 ]] && printf '%s\n' "$path"
  done < <(git -C "$root_dir" status --porcelain)
}

run_git_release() {
  local root_dir="$1"
  local tag="$2"
  local git_all="$3"
  local git_remote="$4"
  local git_branch="$5"
  local git_tag_prefix="$6"
  shift 6
  local -a tracked_files=("$@")
  local tag_ref="${git_tag_prefix}${tag}"
  local unexpected=""
  local head_commit=""
  local local_tag_commit=""
  local remote_tag_commit=""

  require_cmd git

  git -C "$root_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    warn "not a git repository: $root_dir"
    return 1
  }

  if [[ -d "$root_dir/.git/rebase-merge" || -d "$root_dir/.git/rebase-apply" || -f "$root_dir/.git/MERGE_HEAD" ]]; then
    warn "git has unfinished rebase or merge"
    return 1
  fi

  if ! git -C "$root_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
    warn "repository has no commits (HEAD is missing)"
    return 1
  fi

  if [[ -z "$git_branch" ]]; then
    git_branch="$(git -C "$root_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  fi
  [[ -n "$git_branch" && "$git_branch" != "HEAD" ]] || {
    warn "cannot detect branch, use --git-branch"
    return 1
  }

  if [[ "$git_all" -eq 1 ]]; then
    run_cmd git -C "$root_dir" add -A
    if [[ -n "$(git -C "$root_dir" status --porcelain)" ]]; then
      run_cmd git -C "$root_dir" commit -m "release: $tag_ref"
    fi
  else
    unexpected="$(git_unexpected_changes "$root_dir" "${tracked_files[@]-}")"
    if [[ -n "$unexpected" ]]; then
      warn "git tree has unrelated local changes:"
      printf '%s\n' "$unexpected" | sed 's/^/  - /' >&2
      warn "use --git-all to include everything"
      return 1
    fi
    if [[ "${#tracked_files[@]}" -gt 0 ]]; then
      run_cmd git -C "$root_dir" add -- "${tracked_files[@]}"
      if [[ -n "$(git -C "$root_dir" status --porcelain -- "${tracked_files[@]}")" ]]; then
        run_cmd git -C "$root_dir" commit -m "release: $tag_ref"
      fi
    fi
  fi

  if ! run_cmd git -C "$root_dir" push "$git_remote" "$git_branch"; then
    warn "git push failed for branch $git_branch"
    warn_github_https_auth "$root_dir" "$git_remote"
    return 1
  fi

  head_commit="$(git -C "$root_dir" rev-parse HEAD)"
  remote_tag_commit="$(git_remote_tag_commit "$root_dir" "$tag_ref" "$git_remote")"

  if git -C "$root_dir" rev-parse -q --verify "refs/tags/$tag_ref" >/dev/null 2>&1; then
    local_tag_commit="$(git -C "$root_dir" rev-list -n 1 "$tag_ref")"
    if [[ "$local_tag_commit" != "$head_commit" ]]; then
      warn "local tag $tag_ref points to another commit"
      return 1
    fi
  else
    run_cmd git -C "$root_dir" tag -a "$tag_ref" -m "Release $tag_ref"
  fi

  if [[ -n "$remote_tag_commit" ]]; then
    if [[ "$remote_tag_commit" != "$head_commit" ]]; then
      warn "remote tag $tag_ref points to another commit"
      return 1
    fi
    info "Git tag already exists on remote: $tag_ref"
    return 0
  fi

  if ! run_cmd git -C "$root_dir" push "$git_remote" "refs/tags/$tag_ref"; then
    warn "failed to push tag $tag_ref"
    warn_github_https_auth "$root_dir" "$git_remote"
    return 1
  fi

  info "Git release pushed: branch=$git_branch tag=$tag_ref"
  return 0
}

main() {
  load_config_if_requested "$@"

  local root_dir="${ROOT_DIR:-$PWD}"
  local repo="${RELEASE_REPO:-${IMAGE_REPO:-}}"
  local tag="${RELEASE_TAG:-}"
  local bump="${BUMP:-}"
  local version_file="${VERSION_FILE:-VERSION}"
  local dockerfile="${DOCKERFILE:-Dockerfile}"
  local context_dir="${BUILD_CONTEXT:-.}"
  local platform="${PLATFORM:-linux/amd64}"
  local use_multi_arch=0
  local push_latest=1
  local no_cache=0
  local git_release=0
  local git_all=0
  local git_remote="${GIT_REMOTE:-origin}"
  local git_branch="${GIT_BRANCH:-}"
  local git_tag_prefix="${GIT_TAG_PREFIX:-v}"
  local git_strict=0
  local tag_explicit=0
  local item=""
  local -a package_jsons=()

  if is_truthy "${PUSH_LATEST:-1}"; then
    push_latest=1
  else
    push_latest=0
  fi
  if [[ -n "${RELEASE_TAG:-}" ]]; then
    tag_explicit=1
  fi
  if [[ "${RELEASE_PACKAGE_JSONS+x}" = "x" ]]; then
    for item in "${RELEASE_PACKAGE_JSONS[@]-}"; do
      [[ -n "$item" ]] && package_jsons+=("$item")
    done
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
      --repo)
        repo="${2:-}"
        shift 2
        ;;
      --tag)
        tag="${2:-}"
        tag_explicit=1
        shift 2
        ;;
      --bump)
        bump="${2:-}"
        shift 2
        ;;
      --version-file)
        version_file="${2:-}"
        shift 2
        ;;
      --package-json)
        package_jsons+=("${2:-}")
        shift 2
        ;;
      --dockerfile)
        dockerfile="${2:-}"
        shift 2
        ;;
      --context)
        context_dir="${2:-}"
        shift 2
        ;;
      --platform)
        platform="${2:-}"
        shift 2
        ;;
      --multi-arch)
        use_multi_arch=1
        shift
        ;;
      --no-latest)
        push_latest=0
        shift
        ;;
      --no-cache)
        no_cache=1
        shift
        ;;
      --git)
        git_release=1
        shift
        ;;
      --git-all)
        git_all=1
        shift
        ;;
      --git-remote)
        git_remote="${2:-}"
        shift 2
        ;;
      --git-branch)
        git_branch="${2:-}"
        shift 2
        ;;
      --git-tag-prefix)
        git_tag_prefix="${2:-}"
        shift 2
        ;;
      --git-strict)
        git_strict=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage_release
        exit 0
        ;;
      *)
        die "unknown release option: $1"
        ;;
    esac
  done

  [[ -n "$repo" ]] || die "--repo is required"
  root_dir="$(path_abs "$root_dir" || true)"
  [[ -n "$root_dir" ]] || die "unable to resolve root dir"

  if [[ "${#package_jsons[@]}" -eq 0 ]]; then
    [[ -f "$root_dir/package.json" ]] && package_jsons+=("package.json")
    [[ -f "$root_dir/frontend/package.json" ]] && package_jsons+=("frontend/package.json")
  fi

  local version_file_rel=""
  local dockerfile_rel=""
  local context_rel=""
  local current_version=""
  local next_version=""
  local package_json=""
  local path_item=""
  local git_rc=0
  local build_platform="$platform"
  local -a package_json_rels=()
  local -a build_cmd=()
  local -a git_tracked_files=()

  version_file_rel="$(make_relative_to_root "$root_dir" "$version_file")"
  dockerfile_rel="$(make_relative_to_root "$root_dir" "$dockerfile")"
  context_rel="$(make_relative_to_root "$root_dir" "$context_dir")"

  for package_json in "${package_jsons[@]-}"; do
    [[ -n "$package_json" ]] && package_json_rels+=("$(make_relative_to_root "$root_dir" "$package_json")")
  done

  if [[ -n "$bump" ]]; then
    current_version="$(read_version_value "$root_dir" "$version_file_rel" || true)"
    [[ -n "$current_version" ]] || die "version file not found or empty: $version_file_rel"
    next_version="$(bump_semver "$current_version" "$bump")"
    write_text_file "$root_dir/$version_file_rel" "$next_version"
    sync_package_json_versions "$root_dir" "$next_version" "${package_json_rels[@]-}"
    tag="$next_version"
    info "Version bumped: $current_version -> $next_version"
  fi

  if [[ -z "$tag" ]]; then
    tag="$(read_version_value "$root_dir" "$version_file_rel" || true)"
  fi
  [[ -n "$tag" ]] || tag="latest"

  if [[ "$git_release" -eq 1 && -z "$bump" && "$tag_explicit" -eq 0 && "$tag" == "latest" ]]; then
    current_version="$(read_version_value "$root_dir" "$version_file_rel" || true)"
    [[ -n "$current_version" ]] || die "--git without --tag requires a valid version file or explicit --tag"
    next_version="$(bump_semver "$current_version" "patch")"
    write_text_file "$root_dir/$version_file_rel" "$next_version"
    sync_package_json_versions "$root_dir" "$next_version" "${package_json_rels[@]-}"
    tag="$next_version"
    info "Auto bump enabled for --git: $current_version -> $next_version"
  fi

  [[ "$git_release" -eq 1 && "$tag" == "latest" ]] && die "--git requires a concrete version tag, not latest"
  [[ "$use_multi_arch" -eq 1 ]] && build_platform="linux/amd64,linux/arm64"

  require_cmd docker
  run_cmd docker buildx version >/dev/null

  info "Release summary"
  info "  root_dir:   $root_dir"
  info "  repo:       $repo"
  info "  tag:        $tag"
  info "  platform:   $build_platform"
  info "  git:        $([[ "$git_release" -eq 1 ]] && echo yes || echo no)"

  build_cmd=(docker buildx build "$context_rel" -f "$dockerfile_rel" --platform "$build_platform" --push -t "$repo:$tag")
  [[ "$push_latest" -eq 1 && "$tag" != "latest" ]] && build_cmd+=(-t "$repo:latest")
  [[ "$no_cache" -eq 1 ]] && build_cmd+=(--no-cache)
  run_in_dir "$root_dir" "${build_cmd[@]}"

  if [[ "$git_release" -eq 1 ]]; then
    [[ -f "$root_dir/$version_file_rel" ]] && git_tracked_files+=("$version_file_rel")
    for path_item in "${package_json_rels[@]-}"; do
      [[ -f "$root_dir/$path_item" ]] && git_tracked_files+=("$path_item")
    done
    if ! run_git_release "$root_dir" "$tag" "$git_all" "$git_remote" "$git_branch" "$git_tag_prefix" "${git_tracked_files[@]-}"; then
      git_rc=1
      [[ "$git_strict" -eq 1 ]] && die "git step failed after image publication"
      warn "git step failed; Docker image is already published"
    fi
  fi

  return "$git_rc"
}

main "$@"
