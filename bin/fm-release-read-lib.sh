#!/usr/bin/env bash
# fm-release-read-lib.sh - the single owner of firstmate's read-only ADO release
# helpers. It reads and classifies an ADO project's two release backends (classic
# adoRelease / VSRM and managedSdp / build), and holds nothing PR-specific: it is
# the shared read layer beneath every post-merge release consumer.
#
# Usage: . bin/fm-release-read-lib.sh
#
# Sourced by:
#   - bin/fm-lookout-job-ado-release-tracker.sh - the passive definition-watching
#     lookout poller (the fleet backstop; keeps the helpers in scope for its own
#     lookout_job_poll and for the fm-lookout tests that source that job file).
#   - the prrelease peer's per-PR track loop, which reuses these same reads to
#     locate a merged PR's release and read its ring progression (see
#     docs/ado-release-tracking.md and the prrelease charter). prrelease works a
#     durable per-PR queue and supersedes the lookout for per-PR tracking; both
#     share this one read code path so the reads never drift.
#
# Every function here is READ-ONLY: it observes release/build state and never
# triggers, approves, retries, or cancels a rollout. The az invocation routes
# through the mockable fm_lookout_ado_az seam (FM_ADO_AZ override), so hermetic
# tests inject a fake az returning canned JSON. The deterministic drop/escalate/
# silent triage over these facts lives in bin/fm-release-watch-triage.sh, which
# is network-free and takes the facts these reads produce.

# --- az invocation seam (mockable, mirrors bin/fm-ado-lib.sh fm_ado_az) ------
fm_lookout_ado_az() {
  "${FM_ADO_AZ:-az}" "$@"
}

# The Azure DevOps AAD resource id `az rest` needs to acquire a token. Owned by
# bin/fm-ado-lib.sh FM_ADO_REST_RESOURCE; defaulted here (fall back only) so a
# standalone consumer, which mirrors rather than sources that lib, still works and
# the lib's value wins if it is ever sourced first. Azure DevOps's public,
# well-known first-party application id -- same for every ADO org, not a tenant id
# and not a secret; override via FM_ADO_REST_RESOURCE.
FM_ADO_REST_RESOURCE="${FM_ADO_REST_RESOURCE:-499b84ac-1321-427f-aa17-267ca6975798}"

# Classic Release Management (adoRelease) lives on the vsrm.* host, not the plain
# dev.azure.com / *.visualstudio.com host the build API uses; derive it from
# ADO_ORG. https://dev.azure.com/<org> -> https://vsrm.dev.azure.com/<org>, and
# https://<org>.visualstudio.com -> https://<org>.vsrm.visualstudio.com.
lookout_ado_vsrm_host() {  # <org-url>
  printf '%s' "$1" | sed -E 's#^(https?://)dev\.azure\.com#\1vsrm.dev.azure.com#; s#^(https?://)([^./]+)\.visualstudio\.com#\1\2.vsrm.visualstudio.com#'
}

# Classify a normalized CICD state into report vs absorb.
#   terminal-failure : report always.
#   terminal-success : report on first observation of this run reaching it.
#   in-progress      : absorb.
lookout_ado_state_class() {
  case "$1" in
    BuildFailed|ValidationFailed|ReleaseFailed|ReleaseCanceled|ReleaseAbandoned)
      echo failure ;;
    BuildSucceeded|ValidationPassed|ReleaseFinished|ReleaseSucceeded)
      echo success ;;
    *)
      echo progress ;;
  esac
}

# Map a raw ADO release/build status+result into a normalized CICD state. The two
# backends report different raw vocabularies, so each has its own mapping.
#   adoRelease environment status: notStarted|inProgress|succeeded|rejected|canceled|...
#   managedSdp build status/result: inProgress/notStarted + succeeded|failed|canceled|...
lookout_ado_cicd_from_adorelease() {  # <env-status>
  case "$1" in
    succeeded) echo ReleaseSucceeded ;;
    partiallySucceeded) echo ReleaseFinished ;;
    rejected|failed) echo ReleaseFailed ;;
    canceled|cancelled) echo ReleaseCanceled ;;
    abandoned) echo ReleaseAbandoned ;;
    queued|scheduled|notStarted|inProgress) echo ReleaseInProgress ;;
    *) echo NotStart ;;
  esac
}

lookout_ado_cicd_from_managedsdp() {  # <build-status> <build-result>
  local status=$1 result=$2
  if [ "$status" != completed ]; then
    echo BuildInProgress
    return
  fi
  case "$result" in
    succeeded) echo BuildSucceeded ;;
    partiallySucceeded) echo BuildSucceeded ;;
    failed) echo BuildFailed ;;
    canceled|cancelled) echo ReleaseCanceled ;;
    *) echo BuildFailed ;;
  esac
}

# Read the newest release for a classic adoRelease definition via the VSRM API.
# Echoes "<runId>\t<cicdState>\t<name>" or exits non-zero on read failure.
lookout_ado_read_adorelease() {  # <org> <project> <def-id>
  local org=$1 project=$2 def=$3 host url json
  # Classic release reads go to the vsrm.* host with an explicit --resource so az
  # can acquire a token (the plain dev.azure.com host 404s for /_apis/release, and
  # without --resource az cannot derive the AAD resource and gets an HTML redirect).
  host=$(lookout_ado_vsrm_host "$org")
  url="$host/$project/_apis/release/releases?definitionId=$def&\$top=1&queryOrder=descending&api-version=7.1"
  json=$(fm_lookout_ado_az rest --method get --resource "$FM_ADO_REST_RESOURCE" --url "$url" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '
    (.value // [])[0] as $r
    | if $r == null then empty
      else
        ($r.environments // []) as $envs
        | ([$envs[].status] | if any(. == "rejected" or . == "failed") then "failed"
            elif any(. == "canceled" or . == "cancelled") then "canceled"
            elif any(. == "inProgress" or . == "queued" or . == "scheduled") then "inProgress"
            elif (length > 0 and all(. == "succeeded")) then "succeeded"
            elif any(. == "succeeded") then "partiallySucceeded"
            else "notStarted" end) as $status
        | "\($r.id)\t\($status)\t\($r.name // "release")"
      end
  ' 2>/dev/null
}

# Read the newest run for a managedSdp (build) pipeline via the build API.
# Echoes "<runId>\t<status>\t<result>\t<name>" or exits non-zero on read failure.
lookout_ado_read_managedsdp() {  # <org> <project> <def-id>
  local org=$1 project=$2 def=$3 url json
  url="$org/$project/_apis/build/builds?definitions=$def&\$top=1&queryOrder=finishTimeDescending&api-version=7.1"
  json=$(fm_lookout_ado_az rest --method get --url "$url" 2>/dev/null) || return 1
  printf '%s' "$json" | jq -r '
    (.value // [])[0] as $b
    | if $b == null then empty
      else "\($b.id)\t\($b.status // "inProgress")\t\($b.result // "")\t\($b.definition.name // "build")"
      end
  ' 2>/dev/null
}
