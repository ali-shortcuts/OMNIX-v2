# Anti-drift contract for exact-build/fresh real-machine production evidence.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$root=Split-Path -Parent $PSScriptRoot
$files=@{
  Helper=Join-Path $root 'tools\real-evidence-binding.ps1'
  Runner=Join-Path $root 'tools\bound-real-acceptance.ps1'
  Guard=Join-Path $root 'tools\final-production-evidence-binding-guard.ps1'
  Acceptance=Join-Path $root 'tools\final-evidence-binding-guard-acceptance.ps1'
  FinalGate=Join-Path $root 'tools\final-production-gate.ps1'
  Package=Join-Path $root 'build\package.ps1'
  Lifecycle=Join-Path $root 'tools\lifecycle-acceptance.ps1'
  LifecycleCore=Join-Path $root 'tools\lifecycle-core-acceptance.ps1'
}
foreach($kv in $files.GetEnumerator()){
  if(-not(Test-Path -LiteralPath $kv.Value -PathType Leaf)){throw "FINAL_EVIDENCE_BINDING_CONTRACT: missing $($kv.Key): $($kv.Value)"}
  $tokens=$null;$errors=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($kv.Value,[ref]$tokens,[ref]$errors)
  if(@($errors).Count -gt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: PowerShell parse failure in $($kv.Key): $($errors[0].Message)"}
}

$package=Get-Content -LiteralPath $files.Package -Raw
foreach($needle in @('OMNIX-build-identity.json','OMNIX-BUILD-IDENTITY-001','SourceCommit','CoreSha256','ExcelSha256','WordSha256','PowerPointSha256','PAYLOAD_IDENTITY_GUARD')){
  if($package.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: package identity missing '$needle'."}
}

$helper=Get-Content -LiteralPath $files.Helper -Raw
foreach($needle in @('Read-VerifiedOmnixBuildIdentity','OMNIX-build-identity.json','OMNIX-BUILD-IDENTITY-001','BindingSchema = 2','PayloadIdentitySha256','PrimaryAssembliesValidated','ExcelSha256','WordSha256','PowerPointSha256','TimestampUtc','MaxAgeHours','stale')){
  if($helper.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: helper missing '$needle'."}
}

$runner=Get-Content -LiteralPath $files.Runner -Raw
foreach($needle in @('FullOfficeE2E','LocalOffline','Provider','RestartBefore','RestartAfter','ExpectedInstallerSha256','Save-BoundReport','restart-evidence-binding-state.json','PayloadIdentitySha256','PrimaryAssembliesValidated','StateSchema = 2','& $powershell @args')){
  if($runner.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: canonical runner missing '$needle'."}
}
$runnerTokens=$null;$runnerErrors=$null
$runnerAst=[System.Management.Automation.Language.Parser]::ParseFile($files.Runner,[ref]$runnerTokens,[ref]$runnerErrors)
$startProcessCommands=@($runnerAst.FindAll({param($node) $node -is [System.Management.Automation.Language.CommandAst] -and [string]::Equals($node.GetCommandName(),'Start-Process',[StringComparison]::OrdinalIgnoreCase)},$true))
if($startProcessCommands.Count -gt 0){throw 'FINAL_EVIDENCE_BINDING_CONTRACT: bound real acceptance runner must preserve child argument boundaries and must not execute Start-Process.'}

$lifecycle=Get-Content -LiteralPath $files.Lifecycle -Raw
foreach($needle in @('Baseline','AfterRepair','AfterUninstall','SourceCommit','lifecycle-core-acceptance.ps1')){
  if($lifecycle.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: lifecycle entrypoint missing '$needle'."}
}

$lifecycleCore=Get-Content -LiteralPath $files.LifecycleCore -Raw
foreach($needle in @('EvidenceSchema=4','New-OmnixEvidenceBinding','Compare-InstalledBinding','OMNIX-build-identity.json','PayloadIdentityPreserved','PayloadIdentityPreservedAcrossRepair','PrimaryAssembliesValidatedBeforeAndAfterRepair','EvidenceBinding=$state.EvidenceBinding','OMNIX-BUILD-IDENTITY-001')){
  if($lifecycleCore.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: lifecycle core missing '$needle'."}
}

$guard=Get-Content -LiteralPath $files.Guard -Raw
foreach($needle in @('FINAL-EVIDENCE-BINDING-REJECTED','Test-OmnixEvidenceBinding','PayloadIdentitySha256','PrimaryAssembliesValidated','Office E2E','Office persistence','Office UI','Windows restart persistence','Offline local AI','Live provider matrix','Lifecycle','PayloadIdentityPreservedAcrossRepair','PrimaryAssembliesValidatedBeforeAndAfterRepair','LifecyclePayloadIdentityBound','Consumer security','168','72')){
  if($guard.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: final binding guard missing '$needle'."}
}
if($guard -match '(?im)^\s*exit\b'){throw 'FINAL_EVIDENCE_BINDING_CONTRACT: composable binding guard must not call exit.'}

$final=Get-Content -LiteralPath $files.FinalGate -Raw
$bindingIndex=$final.IndexOf('& $bindingGuard',[StringComparison]::Ordinal);$taskPaneIndex=$final.IndexOf('& $taskPaneGuard',[StringComparison]::Ordinal);$coreIndex=$final.IndexOf('& $impl @PSBoundParameters',[StringComparison]::Ordinal)
if($bindingIndex -lt 0 -or $taskPaneIndex -lt 0 -or $coreIndex -lt 0){throw 'FINAL_EVIDENCE_BINDING_CONTRACT: canonical final gate is missing binding/task-pane/core invocation.'}
if(-not($bindingIndex -lt $taskPaneIndex -and $taskPaneIndex -lt $coreIndex)){throw 'FINAL_EVIDENCE_BINDING_CONTRACT: final gate order must be binding guard -> task-pane guard -> production core.'}

$acceptance=Get-Content -LiteralPath $files.Acceptance -Raw
foreach($needle in @('FINAL-EVIDENCE-BINDING-GUARD-RUNTIME-001','ValidExactBinding','MissingProviderBinding','WrongProviderCore','WrongProviderIdentity','OldBindingSchema','WrongRestartSource','MissingLifecycleBinding','WrongLifecycleIdentity','LifecycleIdentityNotPreserved','OldLifecycleSchema','StaleProvider','FutureOfficeUi','StaleLifecycle','WrongOfficeInstaller','CallerContinuation')){
  if($acceptance.IndexOf($needle,[StringComparison]::OrdinalIgnoreCase) -lt 0){throw "FINAL_EVIDENCE_BINDING_CONTRACT: behavior acceptance missing '$needle'."}
}

Write-Host 'FINAL-EVIDENCE-BINDING-CONTRACT-003: PASS'
