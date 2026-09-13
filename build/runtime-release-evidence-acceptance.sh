#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
packager="$root/build/package-runtime-release-evidence.sh"
[[ -f "$packager" ]] || { echo "Packager missing: $packager" >&2; exit 1; }

for tool in jq sha256sum zip unzip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Required acceptance tool is missing: $tool" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
input="$tmp/input/build/artifact"
out="$tmp/out"
mkdir -p "$input" "$out"
source_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
runtime_run='123456789'

cat > "$input/request-budget-acceptance.json" <<'JSON'
{"TestId":"REQUEST-BUDGET-RUNTIME-001","FailureCount":0,"OverallPass":true}
JSON
cat > "$input/tool-request-isolation-acceptance.json" <<'JSON'
{"TestId":"TOOL-REQUEST-ISOLATION-RUNTIME-001","FailureCount":0,"PreCancelledReadBlocked":true,"InvalidScopeReadBlocked":true,"CancelAfterApprovalBlockedWrite":true,"ScopeLossAfterApprovalBlockedWrite":true,"CancellationPropagated":true,"ValidApprovedWritePass":true,"OverallPass":true}
JSON
cat > "$input/provider-error-redaction-acceptance.json" <<'JSON'
{"TestId":"PROVIDER-ERROR-REDACTION-RUNTIME-001","FailureCount":0,"OverallPass":true}
JSON
cat > "$input/image-normalization-acceptance.json" <<'JSON'
{"TestId":"IMAGE-NORMALIZATION-RUNTIME-001","FailureCount":0,"OverallPass":true}
JSON

bash "$packager" "$tmp/input" "$out" "$source_sha" "$runtime_run" > "$tmp/positive.log"

[[ -s "$out/OMNIX-runtime-hardening-evidence.zip" ]] || { echo 'Runtime evidence ZIP was not produced.' >&2; exit 1; }
[[ -s "$out/OMNIX-runtime-hardening-evidence.sha256" ]] || { echo 'Runtime evidence checksum was not produced.' >&2; exit 1; }
[[ -s "$out/runtime-evidence-index.json" ]] || { echo 'Runtime evidence index was not produced.' >&2; exit 1; }

expected_zip_sha="$(awk '{print $1}' "$out/OMNIX-runtime-hardening-evidence.sha256")"
actual_zip_sha="$(sha256sum "$out/OMNIX-runtime-hardening-evidence.zip" | awk '{print $1}')"
[[ "$expected_zip_sha" == "$actual_zip_sha" ]] || { echo 'Runtime evidence ZIP checksum mismatch.' >&2; exit 1; }

jq -e \
  --arg source "$source_sha" \
  --argjson runtimeRun "$runtime_run" \
  '.SourceCommit == $source and
   .RuntimeWorkflow.RunId == $runtimeRun and
   .OverallPass == true and
   (.Reports | length) == 4 and
   ([.Reports[].TestId] | index("TOOL-REQUEST-ISOLATION-RUNTIME-001")) != null' \
  "$out/runtime-evidence-index.json" >/dev/null

for required in \
  request-budget-acceptance.json \
  tool-request-isolation-acceptance.json \
  provider-error-redaction-acceptance.json \
  image-normalization-acceptance.json \
  runtime-evidence-index.json; do
  unzip -Z1 "$out/OMNIX-runtime-hardening-evidence.zip" | grep -Fx "$required" >/dev/null || {
    echo "Runtime evidence ZIP is missing $required" >&2
    exit 1
  }
done

# Negative case: one isolation invariant is false. Packaging MUST fail closed.
sed -i 's/"ScopeLossAfterApprovalBlockedWrite":true/"ScopeLossAfterApprovalBlockedWrite":false/' \
  "$input/tool-request-isolation-acceptance.json"
rm -rf "$tmp/negative-out"
mkdir -p "$tmp/negative-out"
set +e
bash "$packager" "$tmp/input" "$tmp/negative-out" "$source_sha" "$runtime_run" > "$tmp/negative.log" 2>&1
negative_exit=$?
set -e
if [[ $negative_exit -eq 0 ]]; then
  echo 'Tampered tool-isolation evidence was incorrectly accepted.' >&2
  cat "$tmp/negative.log" >&2
  exit 1
fi

jq -n \
  --arg testId 'RUNTIME-RELEASE-EVIDENCE-PACKAGER-001' \
  --arg source "$source_sha" \
  --argjson runtimeRun "$runtime_run" \
  --arg zipSha "$actual_zip_sha" \
  '{TestId:$testId, SourceCommit:$source, RuntimeWorkflowRunId:$runtimeRun, PositivePackagePass:true, TamperedIsolationRejected:true, RuntimeEvidenceZipSha256:$zipSha, OverallPass:true}'
