#!/usr/bin/env bash
# ado-pr-cli wrapper: resolve the skill directory, load LOCAL ADO org config, and
# run the vendored Python CLI via uv.
#
# The implementation is vendored into this skill and this tracked copy is the
# authoritative runtime source for the role.
#
# ADO org/project/repo are captain-specific and must NOT live in tracked shared
# material, so they are read from the firstmate home's LOCAL, gitignored
# config/ado-review.env (see cli/ado_pr_cli.py constants block). A full PR URL is
# self-describing and works with no config; a bare numeric PR id needs config.
#
# Usage: ./ado-pr-cli.sh <command> [args...]
# Example: ./ado-pr-cli.sh diff https://msazure.visualstudio.com/.../pullrequest/123

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT_FROM_SKILL="$(cd "$SCRIPT_DIR/../../.." && pwd)"

case "${1:-}" in
  post-comment|reply-thread)
    explicit=()
    [ "${FM_PRREVIEW_EXPLICIT_POST:-0}" = 1 ] && explicit=(--explicit)
    "$FM_ROOT_FROM_SKILL/bin/fm-role-policy.sh" check prreview post-review "${explicit[@]+"${explicit[@]}"}" >/dev/null
    ;;
  resolve-thread|requeue-policy|trigger-build)
    printf 'error: prreview does not authorize %s; use the current owning role and an explicit routed instruction\n' "$1" >&2
    exit 3
    ;;
esac

# Load LOCAL ADO org config if present. FM_HOME wins so a secondmate loads its own
# home's config; otherwise fall back to the home root that contains this skill.
config_home="${FM_HOME:-}"
if [ -z "$config_home" ]; then
  config_home="$(cd "$SCRIPT_DIR/../../.." 2>/dev/null && pwd || true)"
fi
ado_env="$config_home/config/ado-review.env"
if [ -f "$ado_env" ]; then
  # shellcheck disable=SC1090
  . "$ado_env"
fi
export FM_ADO_ORG="${FM_ADO_ORG:-}"
export FM_ADO_PROJECT="${FM_ADO_PROJECT:-}"
export FM_ADO_REPO="${FM_ADO_REPO:-}"

exec uv run --project "$SCRIPT_DIR/cli" python "$SCRIPT_DIR/cli/ado_pr_cli.py" "$@"
