#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <runtime-artifact-dir> <output-dir> <source-sha> <runtime-workflow-run-id>" >&2
  exit 2
fi

input_dir="$1"
output_dir="$2"
source_sha="${3,,}"
runtime_run_id="$4"

if [[ ! -d "$input_dir" ]]; then
  echo "Runtime evidence input directory does not exist: $input_dir" >&2
  exit 2
fi
if [[ ! "$source_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid source SHA: $source_sha" >&2
  exit 2
fi
if [[ ! "$runtime_run_id" =~ ^[0-9]+$ ]]; then
  echo "Invalid runtime workflow run id: $runtime_run_id" >&2
  exit 2
fi

for tool in jq sha256sum zip find; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required tool is missing: $tool" >&2; exit 2; }
done

mkdir -p "$output_dir"
out_abs="$(cd "$output_dir" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

find_one() {
  local file_name="$1"
  mapfile -t matches < <(find "$input_dir" -type f -name "$file_name" -print)
  if [[ ${#matches[@]} -ne 1 ]]; then
    echo "Expected exactly one $file_name in runtime artifact; found ${#matches[@]}." >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

budget_src="$(find_one request-budget-acceptance.json)"
isolation_src="$(find_one tool-request-isolation-acceptance.json)"
redaction_src="$(find_one provider-error-redaction-acceptance.json)"
image_src="$(find_one image-normalization-acceptance.json)"

jq -e '
  .TestId == "REQUEST-BUDGET-RUNTIME-001" and
  .OverallPass == true and
  (.FailureCount | tonumber) == 0
' "$budget_src" >/dev/null || { echo 'Request-budget runtime evidence is invalid.' >&2; exit 1; }

jq -e '
  .TestId == "TOOL-REQUEST-ISOLATION-RUNTIME-001" and
  .OverallPass == true and
  (.FailureCount | tonumber) == 0 and
  .PreCancelledReadBlocked == true and
  .InvalidScopeReadBlocked == true and
  .CancelAfterApprovalBlockedWrite == true and
  .ScopeLossAfterApprovalBlockedWrite == true and
  .CancellationPropagated == true and
  .ValidApprovedWritePass == true
' "$isolation_src" >/dev/null || { echo 'Office tool request/document isolation runtime evidence is invalid.' >&2; exit 1; }

jq -e '
  .TestId == "PROVIDER-ERROR-REDACTION-RUNTIME-001" and
  .OverallPass == true and
  (.FailureCount | tonumber) == 0
' "$redaction_src" >/dev/null || { echo 'Provider-error redaction runtime evidence is invalid.' >&2; exit 1; }

jq -e '
  .TestId == "IMAGE-NORMALIZATION-RUNTIME-001" and
  .OverallPass == true and
  (.FailureCount | tonumber) == 0
' "$image_src" >/dev/null || { echo 'Image-normalization runtime evidence is invalid.' >&2; exit 1; }

cp "$budget_src" "$stage/request-budget-acceptance.json"
cp "$isolation_src" "$stage/tool-request-isolation-acceptance.json"
cp "$redaction_src" "$stage/provider-error-redaction-acceptance.json"
cp "$image_src" "$stage/image-normalization-acceptance.json"

budget_sha="$(sha256sum "$stage/request-budget-acceptance.json" | awk '{print $1}')"
isolation_sha="$(sha256sum "$stage/tool-request-isolation-acceptance.json" | awk '{print $1}')"
redaction_sha="$(sha256sum "$stage/provider-error-redaction-acceptance.json" | awk '{print $1}')"
image_sha="$(sha256sum "$stage/image-normalization-acceptance.json" | awk '{print $1}')"

jq -n \
  --arg source "$source_sha" \
  --argjson runtimeRunId "$runtime_run_id" \
  --arg budgetSha "$budget_sha" \
  --arg isolationSha "$isolation_sha" \
  --arg redactionSha "$redaction_sha" \
  --arg imageSha "$image_sha" \
  --arg releaseWorkflowRunId "${GITHUB_RUN_ID:-}" \
  '{
    EvidenceType: "OMNIX_RUNTIME_HARDENING_RELEASE_EVIDENCE",
    EvidenceSchema: 1,
    SourceCommit: $source,
    RuntimeWorkflow: {
      Name: "request-budget-runtime",
      RunId: $runtimeRunId
    },
    ReleaseWorkflowRunId: (if $releaseWorkflowRunId == "" then null else ($releaseWorkflowRunId | tonumber) end),
    Reports: [
      {FileName:"request-budget-acceptance.json", TestId:"REQUEST-BUDGET-RUNTIME-001", Sha256:$budgetSha},
      {FileName:"tool-request-isolation-acceptance.json", TestId:"TOOL-REQUEST-ISOLATION-RUNTIME-001", Sha256:$isolationSha},
      {FileName:"provider-error-redaction-acceptance.json", TestId:"PROVIDER-ERROR-REDACTION-RUNTIME-001", Sha256:$redactionSha},
      {FileName:"image-normalization-acceptance.json", TestId:"IMAGE-NORMALIZATION-RUNTIME-001", Sha256:$imageSha}
    ],
    OverallPass: true,
    Note: "Sanitized CI runtime evidence only; no prompts, provider response bodies, API keys, Office document contents, or machine secrets are included."
  }' > "$stage/runtime-evidence-index.json"

cp "$stage/runtime-evidence-index.json" "$out_abs/runtime-evidence-index.json"

(
  cd "$stage"
  zip -q "$out_abs/OMNIX-runtime-hardening-evidence.zip" \
    request-budget-acceptance.json \
    tool-request-isolation-acceptance.json \
    provider-error-redaction-acceptance.json \
    image-normalization-acceptance.json \
    runtime-evidence-index.json
)

runtime_zip_sha="$(sha256sum "$out_abs/OMNIX-runtime-hardening-evidence.zip" | awk '{print $1}')"
printf '%s  %s\n' "$runtime_zip_sha" 'OMNIX-runtime-hardening-evidence.zip' > "$out_abs/OMNIX-runtime-hardening-evidence.sha256"

# Final self-consistency check: the published index must remain tied to this exact source/run.
jq -e \
  --arg source "$source_sha" \
  --argjson runtimeRunId "$runtime_run_id" \
  '.EvidenceType == "OMNIX_RUNTIME_HARDENING_RELEASE_EVIDENCE" and
   .EvidenceSchema == 1 and
   .SourceCommit == $source and
   .RuntimeWorkflow.Name == "request-budget-runtime" and
   .RuntimeWorkflow.RunId == $runtimeRunId and
   .OverallPass == true and
   (.Reports | length) == 4 and
   ([.Reports[].TestId] | sort) == (["REQUEST-BUDGET-RUNTIME-001","TOOL-REQUEST-ISOLATION-RUNTIME-001","PROVIDER-ERROR-REDACTION-RUNTIME-001","IMAGE-NORMALIZATION-RUNTIME-001"] | sort)' \
  "$out_abs/runtime-evidence-index.json" >/dev/null

printf 'runtime_evidence_zip_sha256=%s\n' "$runtime_zip_sha"
printf 'runtime_evidence_zip=%s\n' "$out_abs/OMNIX-runtime-hardening-evidence.zip"
printf 'runtime_evidence_index=%s\n' "$out_abs/runtime-evidence-index.json"
