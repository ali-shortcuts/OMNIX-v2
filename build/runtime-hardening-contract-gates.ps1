# OMNIX runtime-hardening anti-drift contract.
# Structural only: compilation and real Office execution remain separate evidence gates.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]

function Read-Repo([string]$relative) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $failures.Add("Missing: $relative")
        return ''
    }
    return Get-Content -LiteralPath $path -Raw
}
function Require([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if (-not $text.Contains($needle)) { $failures.Add("${relative}: missing '$needle' — $reason") }
}
function Forbid([string]$relative,[string]$needle,[string]$reason) {
    $text = Read-Repo $relative
    if ($text.Contains($needle)) { $failures.Add("${relative}: forbidden '$needle' — $reason") }
}

# Excel writes: one-cell text/formula tools, bounded contiguous highlights, payload limits.
$excel = 'src/OMNIX.Core/Context/ExcelHostAdapter.cs'
Require $excel 'ResolveAndValidateTarget' 'Preview and apply must pass through a central target validator.'
Require $excel 'areaCount != 1' 'AI writes must reject multi-area Excel ranges.'
Require $excel 'cells != 1' 'write_to_cell and insert_formula must remain single-cell mutations.'
Require $excel 'MaxHighlightCells' 'highlight_range needs a hard upper bound in addition to configured context limits.'
Require $excel 'ExcelCellTextLimit' 'cell text must be length-bounded before COM mutation.'
Require $excel 'ExcelFormulaLengthLimit' 'formula payloads must be length-bounded.'
Require $excel 'StartsWith("=", StringComparison.Ordinal)' 'insert_formula must reject non-formula payloads.'

# Word writes: no caret-only insertion masquerading as rewrite; bounded selection/replacement.
$word = 'src/OMNIX.Core/Context/WordHostAdapter.cs'
Require $word 'MaxRewriteSelectionChars' 'selected Word range must have a hard mutation bound.'
Require $word 'MaxRewriteReplacementChars' 'replacement text must have a hard mutation bound.'
Require $word 'length <= 0' 'rewrite_selected_text must reject a caret-only/empty selection.'
Require $word 'RequireBoundedRewriteSelection' 'Word preview and apply must revalidate the selection.'
Require $word 'RequireBoundedReplacement' 'Word preview and apply must revalidate replacement length.'
Require $word 'UndoRecord' 'Word should contribute a native undo boundary where the host supports it.'

# PowerPoint writes/context: bounded text, safe current-slide resolution, notes-body lookup, undo entry.
$ppt = 'src/OMNIX.Core/Context/PowerPointHostAdapter.cs'
Require $ppt 'MaxSlideTitleChars' 'PowerPoint title writes must be bounded.'
Require $ppt 'MaxSlideBodyChars' 'PowerPoint body writes must be bounded.'
Require $ppt 'MaxSpeakerNotesChars' 'PowerPoint notes writes must be bounded.'
Require $ppt 'ResolveActiveSlide' 'normal authoring views must resolve the active slide without view-type guessing.'
Require $ppt 'GetNotesBodyShape' 'speaker notes must resolve the notes body placeholder safely.'
Require $ppt 'ppPlaceholderBody' 'notes lookup must prefer the semantic body placeholder.'
Require $ppt 'StartNewUndoEntry' 'PowerPoint should create an undo boundary when supported.'
Require $ppt 'range.Characters(1, Math.Min(length, remaining))' 'shape text must be bounded before full materialization where possible.'

# Internal tool protocol must never be exposed as raw JSON in normal streaming UI.
$gateway = 'src/OMNIX.Core/AiGateway/AiGateway.cs'
Require $gateway 'ToolProtocolDeltaFilter' 'Gateway must filter internal omnix_tool protocol from user-visible streaming.'
Require $gateway '```omnix_tool' 'tool protocol marker must remain explicit and deterministic.'
Require $gateway 'visibleDelta.Complete(call == null, response.Text)' 'Gateway must decide whether the held suffix is user-visible only after parsing the response.'
Require $gateway 'return ONLY one fenced tool block' 'system prompt must tell models not to mix tool protocol with user-facing prose.'
Require $gateway 'await _privacy.EnsureAllowedAsync(provider)' 'privacy must still execute before cloud/provider SendAsync.'

# Provider access/free claims must be traceable to dated official sources.
$contracts = 'src/OMNIX.Core/AiGateway/ProviderContracts.cs'
$registry = 'src/OMNIX.Core/AiGateway/ProviderRegistry.cs'
Require $contracts 'AccessVerifiedUtc' 'provider access metadata needs a last-verified date.'
Require $contracts 'AccessVerificationUrl' 'provider access metadata needs an official verification source.'
Require $registry 'AccessVerifiedDate = "2026-09-09"' 'current access classifications must carry an explicit verification date.'
Require $registry 'https://ai.google.dev/gemini-api/docs/pricing' 'Gemini access classification must point to official pricing.'
Require $registry 'https://console.groq.com/docs/rate-limits' 'Groq access classification must point to official rate limits.'
Require $registry 'https://openrouter.ai/collections/free-models' 'OpenRouter free classification must point to its official free catalog.'
Require $registry 'https://docs.mistral.ai/admin/billing-usage/subscriptions' 'Mistral Free mode must point to official subscription docs.'
Require $registry 'https://huggingface.co/docs/inference-providers/pricing' 'Hugging Face credits must point to official pricing.'
Require $registry 'https://www.cerebras.ai/pricing' 'Cerebras trial/free classification must point to official pricing.'

# No broad OS execution tool is allowed to creep into the Office tool whitelist.
$tools = 'src/OMNIX.Core/Tools/Tools.cs'
Forbid $tools 'run_powershell' 'AI may not gain a PowerShell execution tool.'
Forbid $tools 'run_command' 'AI may not gain an unrestricted command tool.'
Forbid $tools 'write_registry' 'AI may not gain a registry mutation tool.'
Forbid $tools 'delete_file' 'AI may not gain an arbitrary file-deletion tool.'

if ($failures.Count -gt 0) {
    Write-Host 'OMNIX RUNTIME-HARDENING CONTRACT: FAIL' -ForegroundColor Red
    foreach ($f in $failures) { Write-Host " - $f" -ForegroundColor Red }
    exit 1
}
Write-Host 'OMNIX RUNTIME-HARDENING CONTRACT: PASS'
Write-Host 'Write bounds, hidden tool protocol, privacy ordering and provider-source traceability are structurally intact.'
exit 0
