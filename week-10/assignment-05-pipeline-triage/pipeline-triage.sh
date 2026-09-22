#!/bin/bash
#
# pipeline-triage.sh
# Read-only Azure DevOps dual-pipeline failure-triage tool for EpicBook.
#
# Queries the Infrastructure Pipeline and the Application Pipeline,
# retrieves run metadata AND real step-console log text (via the Build
# Logs REST API), classifies any failure into a known category, and
# writes a sanitized, structured health report.
#
# This script performs NO write, retry, cancel, approve, or delete
# operations against Azure DevOps. It only reads.

set -uo pipefail

# ---------------------------------------------------------------------
# Configuration — replace only the clearly marked student values below.
# Never place a PAT, password, or other secret in this file.
# ---------------------------------------------------------------------

full_name="Joy Ukpabi"
ado_org="https://dev.azure.com/DMI-Cohort-3"
ado_project="Epicbook Deployment"
ado_infra_pipeline_id="9"
ado_app_pipeline_id="10"

# Azure DevOps resource ID used to request an AAD access token for the
# REST API (this is a public, fixed constant — not a secret).
ado_resource_id="499b84ac-1321-427f-aa17-267ca6975798"
ado_project_encoded=$(printf '%s' "$ado_project" | sed 's/ /%20/g')

# ---------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------

base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
report_dir="$base_dir/reports"
report_file="$report_dir/pipeline-health-report.txt"

# ---------------------------------------------------------------------
# Failure-category patterns: "Category Name|regex1|regex2|..."
# Order matters — more specific categories are checked before general
# ones. All matching is case-insensitive.
# ---------------------------------------------------------------------

categories=(
  "Dependency Installation Failure|npm ERR!|ENOENT|ERESOLVE|pip install.*error|ModuleNotFoundError|package not found"
  "Build or Compilation Failure|build failed|compilation error|SyntaxError|TS[0-9]{4}|webpack.*failed"
  "Test Failure|tests? failed|AssertionError|FAIL |[0-9]+ failing|expect\\(received\\)"
  "Authentication, Authorization, or SSH Failure|401 Unauthorized|403 Forbidden|TF400813|invalid_grant|token has expired|permission denied \\(publickey\\)|Bad credentials"
  "Agent Availability, Timeout, or Queue Failure|no agent found|agent.*offline|timed out waiting for an agent|job.*timed out|runner.*offline|no agent pool"
  "Terraform Infrastructure or Provisioning Failure|Error: .*[Tt]erraform|Error acquiring the state lock|ResourceGroupNotFound|InvalidParameterValue|Error: Provider produced inconsistent|plan failed|apply failed|Error: creating"
  "Ansible, Nginx, or Application Deployment Failure|ansible-playbook.*failed|FAILED! =>|UNREACHABLE!|nginx: \\[emerg\\]|nginx.*failed to start|systemctl.*failed|deployment failed"
)

# ---------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------

pass_count=0
warning_count=0
failure_count=0
error_count=0

mkdir -p "$report_dir"
: > "$report_file"

# ---------------------------------------------------------------------
# Output / logging helpers
# ---------------------------------------------------------------------

write_line() {
  echo "$1" | tee -a "$report_file"
}

mark_pass() {
  write_line "[PASS] $1"
  pass_count=$((pass_count + 1))
}

mark_warning() {
  write_line "[WARN] $1"
  warning_count=$((warning_count + 1))
}

mark_failure() {
  write_line "[FAIL] $1"
  failure_count=$((failure_count + 1))
}

mark_error() {
  write_line "[ERROR] $1"
  error_count=$((error_count + 1))
}

print_header() {
  write_line "========================================"
  write_line "CI/CD Pipeline Failure Triage Report"
  write_line "========================================"
  write_line "Full Name: $full_name"
  write_line "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  write_line "Provider: Azure DevOps"
  write_line "Organization: $ado_org"
  write_line "Project: $ado_project"
  write_line ""
}

# Redacts any line that looks like it contains a secret before it is
# ever written to a log file or the report. Never reproduces the
# original sensitive text — only a fixed redaction notice.
sanitize_line() {
  local line="$1"
  if echo "$line" | grep -qiE \
    'authorization:[[:space:]]*bearer|bearer [a-z0-9._-]{10,}|password[[:space:]]*=|pwd[[:space:]]*=|client_secret|-----BEGIN [A-Z ]*PRIVATE KEY-----|personal access token|pat[_-]?token|Data Source=.*Password=|connectionstring.*password'
  then
    echo "[REDACTED: sensitive value removed]"
  else
    echo "$line"
  fi
}

# ---------------------------------------------------------------------
# Pre-flight configuration check
# ---------------------------------------------------------------------

validate_config() {
  local missing=0

  [ -z "$ado_org" ] && { write_line "[CONFIG ERROR] ado_org is not set"; missing=1; }
  [ -z "$ado_project" ] && { write_line "[CONFIG ERROR] ado_project is not set"; missing=1; }
  [ -z "$ado_infra_pipeline_id" ] && { write_line "[CONFIG ERROR] ado_infra_pipeline_id is not set"; missing=1; }
  [ -z "$ado_app_pipeline_id" ] && { write_line "[CONFIG ERROR] ado_app_pipeline_id is not set"; missing=1; }
  ! command -v az >/dev/null 2>&1 && { write_line "[CONFIG ERROR] az CLI not found"; missing=1; }
  ! command -v curl >/dev/null 2>&1 && { write_line "[CONFIG ERROR] curl not found"; missing=1; }
  ! command -v jq >/dev/null 2>&1 && { write_line "[CONFIG ERROR] jq not found"; missing=1; }

  if [ "$missing" -eq 1 ]; then
    mark_error "Script configuration incomplete. Cannot proceed."
    print_summary
    exit "$?"
  fi
}

# ---------------------------------------------------------------------
# Fetches real step-console log text for a completed build via the
# Azure DevOps Build Logs REST API (read-only: GET requests only).
# Appends sanitized log text to the given log file.
# ---------------------------------------------------------------------

fetch_build_logs() {
  local build_id="$1"
  local log_file="$2"

  local token
  token=$(az account get-access-token --resource "$ado_resource_id" --query accessToken -o tsv 2>/dev/null)
  if [ -z "$token" ]; then
    mark_error "Could not obtain an access token for the Build Logs API"
    return 1
  fi

  local encoded_project
  encoded_project=$(jq -rn --arg p "$ado_project" '$p|@uri')

  local logs_response
  logs_response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $token" \
    "$ado_org/$encoded_project/_apis/build/builds/$build_id/logs?api-version=7.1")

  local http_code
  http_code=$(echo "$logs_response" | tail -n1)
  local body
  body=$(echo "$logs_response" | sed '$d')

  if [ "$http_code" != "200" ]; then
    mark_error "Build Logs API returned HTTP $http_code while listing logs for build $build_id"
    return 1
  fi

  local log_ids
  log_ids=$(echo "$body" | jq -r '.value[].id' 2>/dev/null)

  if [ -z "$log_ids" ]; then
    write_line "No individual logs were returned for build $build_id."
    return 0
  fi

  : > "$log_file"
  local log_id
  for log_id in $log_ids
  do
    local content
    content=$(curl -s -H "Authorization: Bearer $token" \
      "$ado_org/$encoded_project/_apis/build/builds/$build_id/logs/$log_id?api-version=7.1")

    while IFS= read -r line
    do
      sanitize_line "$line" >> "$log_file"
    done <<< "$content"
  done

  return 0
}

# ---------------------------------------------------------------------
# Runs the category checks against a pipeline's log file. Only called
# when the pipeline's latest completed run result is "failed".
# Returns 0 if a known category matched, 1 if none matched
# (Unclassified Pipeline Failure).
# ---------------------------------------------------------------------

run_category_checks() {
  local pipeline_label="$1"
  local log_file="$2"
  local matched=1

  local entry
  for entry in "${categories[@]}"
  do
    local category_name="${entry%%|*}"
    local pattern_part="${entry#*|}"
    local pattern="${pattern_part//|/|}"

    local evidence_line
    evidence_line=$(grep -miE "$pattern" "$log_file" 2>/dev/null | head -n1 || true)

    if [ -n "$evidence_line" ]; then
      local sanitized_evidence
      sanitized_evidence=$(sanitize_line "$evidence_line")
      mark_failure "$pipeline_label — $category_name"
      write_line "    Evidence: $sanitized_evidence"
      matched=0
    fi
  done

  return "$matched"
}

# ---------------------------------------------------------------------
# Handles one pipeline end-to-end: fetch metadata, determine state,
# fetch logs and classify if failed.
# ---------------------------------------------------------------------

process_pipeline() {
  local pipeline_label="$1"
  local pipeline_id="$2"
  local log_file="$3"

  write_line "----------------------------------------"
  write_line "$pipeline_label (Pipeline ID: $pipeline_id)"
  write_line "----------------------------------------"

  local run_json
  run_json=$(az pipelines runs list \
    --organization "$ado_org" \
    --project "$ado_project" \
    --pipeline-ids "$pipeline_id" \
    --top 1 \
    --output json 2>/tmp/az_err_$$)

  local az_exit=$?
  if [ "$az_exit" -ne 0 ]; then
    local az_error
    az_error=$(cat /tmp/az_err_$$ 2>/dev/null)
    rm -f /tmp/az_err_$$
    mark_error "$pipeline_label — Azure DevOps API/authentication error: ${az_error:-unknown error}"
    return
  fi
  rm -f /tmp/az_err_$$

  local run_count
  run_count=$(echo "$run_json" | jq 'length' 2>/dev/null || echo 0)

  if [ "$run_count" -eq 0 ]; then
    mark_warning "$pipeline_label — No run found"
    return
  fi

  local run_id status result branch finish_time
  run_id=$(echo "$run_json" | jq -r '.[0].id')
  status=$(echo "$run_json" | jq -r '.[0].status')
  result=$(echo "$run_json" | jq -r '.[0].result // "none"')
  branch=$(echo "$run_json" | jq -r '.[0].sourceBranch // "unknown"')
  finish_time=$(echo "$run_json" | jq -r '.[0].finishTime // "unknown"')

  write_line "Run ID: $run_id"
  write_line "Branch: $branch"
  write_line "Status: $status"
  write_line "Result: $result"
  write_line "Completion Time: $finish_time"

  if [ "$status" != "completed" ]; then
    mark_warning "$pipeline_label — Latest run is '$status' (not yet completed); final result unknown"
    return
  fi

  case "$result" in
    succeeded)
      mark_pass "$pipeline_label — Latest completed run succeeded"
      ;;
    canceled)
      mark_warning "$pipeline_label — Latest completed run was canceled"
      ;;
    partiallySucceeded)
      mark_warning "$pipeline_label — Latest completed run partially succeeded"
      ;;
    failed)
      write_line "Retrieving step console logs for build $run_id ..."
      if fetch_build_logs "$run_id" "$log_file"; then
        if run_category_checks "$pipeline_label" "$log_file"; then
          : # a known category already marked as failure above
        else
          mark_failure "$pipeline_label — Unclassified Pipeline Failure (Azure DevOps reported failure but no known pattern matched retrieved log text; manual log review required — root cause not confirmed)"
        fi
      else
        mark_failure "$pipeline_label — Run failed, but log retrieval also failed; root cause not confirmed from available evidence"
      fi
      ;;
    *)
      mark_warning "$pipeline_label — Unrecognized result value: $result"
      ;;
  esac

  write_line ""
}

print_summary() {
  local overall_status
  local script_exit_code

  if [ "$error_count" -gt 0 ]; then
    overall_status="ERROR"
    script_exit_code=3
  elif [ "$failure_count" -gt 0 ]; then
    overall_status="FAIL"
    script_exit_code=2
  elif [ "$warning_count" -gt 0 ]; then
    overall_status="WARN"
    script_exit_code=1
  else
    overall_status="HEALTHY"
    script_exit_code=0
  fi

  write_line ""
  write_line "Summary:"
  write_line "PASS: $pass_count"
  write_line "WARN: $warning_count"
  write_line "FAIL: $failure_count"
  write_line "ERROR: $error_count"
  write_line "Overall Status: $overall_status"
  write_line "Script Exit Code: $script_exit_code"
  write_line "Report File: $report_file"

  return "$script_exit_code"
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------

validate_config
print_header

process_pipeline "Infrastructure Pipeline" "$ado_infra_pipeline_id" "$report_dir/infra-last-run.log"
process_pipeline "Application Pipeline" "$ado_app_pipeline_id" "$report_dir/app-last-run.log"

print_summary
exit $?
