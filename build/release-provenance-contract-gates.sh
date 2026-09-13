#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$root/.github/workflows/development-preview-release.yml"
packager="$root/build/package-runtime-release-evidence.sh"
acceptance="$root/build/runtime-release-evidence-acceptance.sh"
failures=()

need() {
  local file="$1"
  local needle="$2"
  local reason="$3"
  if [[ ! -f "$file" ]]; then
    failures+=("Missing: ${file#$root/}")
    return
  fi
  if ! grep -F -- "$needle" "$file" >/dev/null; then
    failures+=("${file#$root/}: missing '$needle' — $reason")
  fi
}

forbid() {
  local file="$1"
  local needle="$2"
  local reason="$3"
  if [[ -f "$file" ]] && grep -F -- "$needle" "$file" >/dev/null; then
    failures+=("${file#$root/}: forbidden '$needle' — $reason")
  fi
}

need "$workflow" 'release-provenance-contract' 'preview publication must wait for the exact-head provenance workflow.'
need "$workflow" 'runtime_run=' 'preview publication must retain the exact successful runtime workflow run id.'
need "$workflow" 'omnix-runtime-hardening-evidence' 'release must download the exact runtime-hardening artifact.'
need "$workflow" 'package-runtime-release-evidence.sh' 'downloaded runtime reports must pass the fail-closed packager.'
need "$workflow" 'runtime-evidence-index.json' 'release must publish a source/run-bound runtime evidence index.'
need "$workflow" 'OMNIX-runtime-hardening-evidence.zip' 'release must publish the verified runtime evidence bundle.'
need "$workflow" 'OMNIX-runtime-hardening-evidence.sha256' 'runtime evidence bundle must have a release checksum.'
need "$workflow" 'TOOL-REQUEST-ISOLATION-RUNTIME-001' 'release wiring must explicitly preserve request/document isolation evidence.'
need "$workflow" 'release-input/runtime-evidence-index.json' 'runtime index must be included in gh release assets.'
need "$workflow" 'release-input/OMNIX-runtime-hardening-evidence.zip' 'runtime evidence ZIP must be included in gh release assets.'
need "$workflow" 'release-input/OMNIX-runtime-hardening-evidence.sha256' 'runtime evidence checksum must be included in gh release assets.'
need "$workflow" 'Office tool request-isolation' 'release notes must accurately describe the isolation runtime gate.'

need "$packager" 'OMNIX_RUNTIME_HARDENING_RELEASE_EVIDENCE' 'runtime evidence bundle needs a stable evidence type.'
need "$packager" 'SourceCommit' 'runtime release evidence must be source-commit bound.'
need "$packager" 'RuntimeWorkflow' 'runtime release evidence must be workflow-run bound.'
need "$packager" 'TOOL-REQUEST-ISOLATION-RUNTIME-001' 'packager must validate the document-scope/tool isolation report.'
need "$packager" 'ScopeLossAfterApprovalBlockedWrite == true' 'late document-scope loss after approval must remain fail-closed.'
need "$packager" 'sha256sum' 'individual reports and the evidence ZIP must be checksum-bound.'
forbid "$packager" '|| true' 'release evidence validation must never silently ignore a failed check.'

need "$acceptance" 'RUNTIME-RELEASE-EVIDENCE-PACKAGER-001' 'packager behavior needs deterministic acceptance.'
need "$acceptance" 'TamperedIsolationRejected' 'negative evidence tampering must be exercised.'

if (( ${#failures[@]} > 0 )); then
  echo 'OMNIX RELEASE-PROVENANCE CONTRACT: FAIL' >&2
  printf ' - %s\n' "${failures[@]}" >&2
  exit 1
fi

echo 'OMNIX RELEASE-PROVENANCE CONTRACT: PASS'
echo 'Preview publication is exact-head gated and must preserve verified runtime-hardening evidence with source/run/checksum binding.'
