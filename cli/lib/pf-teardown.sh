#!/bin/bash
# Compatibility entrypoint for per-session security cleanup.
#
#   pf-teardown.sh diskNsM  — remove exactly one mount's anchor/token/owned route
#   pf-teardown.sh          — reconcile stale sessions only; never touches active mounts
#   pf-teardown.sh --all    — remove every recorded session (uninstall/no-mount contexts only)
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
# shellcheck source=security-transaction.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/security-transaction.sh"

teardown_pf() {
  local target="${1:-}"
  if [[ "$target" == "--all" ]]; then
    security_teardown_all
  elif [[ -z "$target" ]]; then
    security_reconcile
  elif security_valid_session "$target"; then
    security_teardown_session "$target"
  else
    echo "pf-teardown: expected device identifier (diskN or diskNsM), --all, or no argument" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  teardown_pf "$@"
fi
