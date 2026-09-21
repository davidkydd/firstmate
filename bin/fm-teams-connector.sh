#!/usr/bin/env bash
# fm-teams-connector.sh - outbound-only Teams queue connector for one Firstmate home.
#
# The connector is disabled until config/teams.json exists, is owner-only, and
# contains enabled=true. It authenticates to the configured single-tenant Azure
# Service Bus namespace with the Azure CLI identity pinned to that tenant.
# It never opens a listener. Accepted message text reaches Firstmate only on
# stdin through `fm-inbox.sh external-note`; it never becomes shell syntax,
# arguments, a lifecycle key sequence, or a direct fleet-state mutation.
#
# Usage:
#   fm-teams-connector.sh serve
#   fm-teams-connector.sh status
#   fm-teams-connector.sh publish-result --request-id <id>
#       --outcome completed|refused|failed --text-file <path|->
#
# Environment:
#   FM_HOME          operational home (default: tracked code root)
#   FM_TEAMS_CONFIG  explicit config path (default: $FM_HOME/config/teams.json)
#
# Dependencies are installed with `npm ci --omit=dev --ignore-scripts` in integrations/teams.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
ENTRY="$ROOT/integrations/teams/src/connector-main.mjs"

if [ ! -f "$ROOT/integrations/teams/node_modules/@azure/service-bus/package.json" ]; then
  printf '%s\n' 'fm-teams-connector: dependencies are not installed; run npm ci --omit=dev in integrations/teams' >&2
  exit 1
fi

exec node "$ENTRY" "$@"
