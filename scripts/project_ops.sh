#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage_main() {
  cat <<'EOF'
Usage:
  scripts/project_ops.sh <command> [options]

Commands:
  menu           Interactive wizard for profiles, secrets, release, deploy
  release        Build and publish Docker image, optionally push git tag
  deploy         Local deploy inside a target server
  remote-deploy  Copy toolkit to server over SSH and run deploy there

Examples:
  scripts/project_ops.sh menu
  scripts/project_ops.sh release --help
  scripts/project_ops.sh deploy --help
  scripts/project_ops.sh remote-deploy --help
EOF
}

main() {
  [[ $# -gt 0 ]] || {
    usage_main
    exit 1
  }

  case "$1" in
    menu)
      shift
      exec "$SCRIPT_DIR/project_menu.sh" "$@"
      ;;
    release)
      shift
      exec "$SCRIPT_DIR/project_release.sh" "$@"
      ;;
    deploy)
      shift
      exec "$SCRIPT_DIR/project_deploy.sh" "$@"
      ;;
    remote-deploy)
      shift
      exec "$SCRIPT_DIR/remote_deploy.sh" "$@"
      ;;
    -h|--help)
      usage_main
      ;;
    *)
      echo "Error: unknown command: $1" >&2
      usage_main
      exit 1
      ;;
  esac
}

main "$@"
