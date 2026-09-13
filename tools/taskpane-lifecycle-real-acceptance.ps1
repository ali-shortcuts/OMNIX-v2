# OMNIX real Office per-window task-pane lifecycle acceptance
#
# Run on an interactive Windows desktop with Excel + Word + PowerPoint installed after OMNIX.
# This verifies a lifecycle invariant that hosted CI cannot prove: closing a real Office document
# window after opening the OMNIX workspace must dispose the window-bound task-pane host and release
# the matching WorkspaceController immediately. The test repeats the cycle twice per host so a
# stale window/controller cannot silently survive and poison the next document window.
#
# Safety:
# - temporary unsaved documents/presentations only;
# - no Trust Center, Resiliency, registry-policy, network, firewall or restart changes;
# - UI Automation targets only the OMNIX Ribbon tab/button and deterministic workspace IDs;
# - lifecycle proof is read from OMNIX's own local startup log and is scoped by an exact HWND count
#   delta, so an old matching log line cannot produce a false PASS.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\taskpane-lifecycle-real-acceptance.json",
    [int]$StartupDelayMs = 2200,
    [int]$WorkspaceDelayMs = 1400,
    [int]$ReleaseDelayMs = 1200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$hosts = @(
    [pscustomobject]@{ Name='Excel';      ProgId='Excel.Application';      Process='EXCEL' },
    [pscustomobject]@{ Name='Word';       ProgId='Word.Application';       Process='WINWORD' },
    [pscustomobject]@{ Name='PowerPoint'; ProgId='PowerPoint.Application'; Process='POWERPNT' }
)

$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$startupLog = Join-Path $env:LOCALAPPDATA 'OMNIX\logs\startup-debug.log'

function Release-ComObjectSafe($obj) {
    if ($null -ne $obj) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { }
    }
}

function Add-TemporaryDocument($app, [string]$hostName) {
    switch ($hostName) {
        'Excel'      { return $app.Workbooks.Add() }
        'Word'       { return $app.Documents.Add() }
        'PowerPoint' { return $app.Presentations.Add() }
        default      { throw "Unknown Office host: $hostName" }
    }
}

function Close-TemporaryDocument($doc, [string]$hostName) {
    if ($null -eq $doc) { return }
    switch ($hostName) {
        'Excel'      { $doc.Close($false) }
        'Word'       { $doc.Close(0) }
        'PowerPoint' { $doc.Close() }
    }
}

function Get-OfficeWindowHandle($app, [string]$hostName) {
    try {
        switch ($hostName) {
            'Excel' {
                if ($null -ne $app.ActiveWindow) { return [IntPtr]([int64]$app.ActiveWindow.Hwnd) }
                return [IntPtr]([int64]$app.Hwnd)
            }
            'Word' {
                if ($null -ne $app.ActiveWindow) { return [IntPtr]([int64]$app.ActiveWindow.Hwnd) }
            }
            'PowerPoint' {
                if ($null -ne $app.ActiveWindow) { return [IntPtr]([int64]$app.ActiveWindow.HWND) }
                return [IntPtr]([int64]$app.HWND)
            }
        }
    } catch { }
    return [IntPtr]::Zero
}

function Find-UiElementByExactName($root, [string]$name) {
    if ($null -eq $root) { return $null }
    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $name)
        return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    } catch { return $null }
}

function Find-UiElementByAutomationId($root, [string]$automationId) {
    if ($null -eq $root) { return $null }
    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
        return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    } catch { return $null }
}

function Find-UiElementByNameFragment($root, [string[]]$fragments) {
    if ($null -eq $root) { return $null }
    try {
        $all = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)
        foreach ($element in $all) {
            try {
                $name = [string]$element.Current.Name
                if ([string]::IsNullOrWhiteSpace($name)) { continue }
                foreach ($fragment in $fragments) {
                    if ($name.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        return $element
                    }
                }
            } catch { }
        }
    } catch { }
    return $null
}

function Test-UiElementVisible($element) {
    if ($null -eq $element) { return $false }
    try {
        if ([bool]$element.Current.IsOffscreen) { return $false }
        $rect = $element.Current.BoundingRectangle
        return ($rect.Width -ge 20 -and $rect.Height -ge 10)
    } catch { return $false }
}

function Activate-UiElement($element) {
    if ($null -eq $element) { return $false }

    $pattern = $null
    try {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.SelectionItemPattern]$pattern).Select()
            return $true
        }
    } catch { }

    $pattern = $null
    try {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.InvokePattern]$pattern).Invoke()
            return $true
        }
    } catch { }

    return $false
}

function Get-ReleaseLogCount([string]$hostName, [IntPtr]$hwnd) {
    if (-not (Test-Path -LiteralPath $startupLog -PathType Leaf)) { return 0 }
    $key = $hwnd.ToInt64()
    $needle = "$hostName task pane released for window $key (task-pane host disposed)"
    try {
        return @(
            Select-String -LiteralPath $startupLog -SimpleMatch $needle -ErrorAction SilentlyContinue
        ).Count
    } catch {
        return 0
    }
}

function Open-Workspace($app, [string]$hostName) {
    $evidence = [ordered]@{
        WindowHandle = 0
        RibbonTabFound = $false
        RibbonTabActivated = $false
        OpenWorkspaceButtonFound = $false
        OpenWorkspaceInvoked = $false
        WorkspaceVisible = $false
        WorkspaceAutomationId = $null
        Pass = $false
    }

    $hwnd = Get-OfficeWindowHandle $app $hostName
    $evidence.WindowHandle = $hwnd.ToInt64()
    if ($hwnd -eq [IntPtr]::Zero) { return [pscustomobject]$evidence }

    $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
    if ($null -eq $root) { return [pscustomobject]$evidence }

    $tab = Find-UiElementByExactName $root 'OMNIX'
    if ($null -eq $tab) { $tab = Find-UiElementByNameFragment $root @('OMNIX') }
    $evidence.RibbonTabFound = ($null -ne $tab)
    if ($tab) {
        $evidence.RibbonTabActivated = Activate-UiElement $tab
        Start-Sleep -Milliseconds 500
    }

    $button = Find-UiElementByExactName $root 'Open Workspace'
    if ($null -eq $button) { $button = Find-UiElementByNameFragment $root @('Open Workspace') }
    $evidence.OpenWorkspaceButtonFound = ($null -ne $button)
    if ($button) {
        $evidence.OpenWorkspaceInvoked = Activate-UiElement $button
        Start-Sleep -Milliseconds $WorkspaceDelayMs
    }

    $workspace = Find-UiElementByAutomationId $root 'OMNIX.ChatInput'
    if ($null -eq $workspace) { $workspace = Find-UiElementByAutomationId $root 'OMNIX.WorkspaceRoot' }
    if ($null -eq $workspace) { $workspace = Find-UiElementByExactName $root 'OMNIX chat input' }
    if ($workspace) {
        $evidence.WorkspaceVisible = Test-UiElementVisible $workspace
        try { $evidence.WorkspaceAutomationId = [string]$workspace.Current.AutomationId } catch { }
    }

    $evidence.Pass = [bool](
        $evidence.RibbonTabFound -and
        $evidence.RibbonTabActivated -and
        $evidence.OpenWorkspaceButtonFound -and
        $evidence.OpenWorkspaceInvoked -and
        $evidence.WorkspaceVisible)
    return [pscustomobject]$evidence
}

function Invoke-LifecycleRound($app, $officeHost, [int]$round) {
    $doc = $null
    $roundResult = [ordered]@{
        Round = $round
        WindowHandle = 0
        WorkspacePass = $false
        Workspace = $null
        ReleaseLogCountBefore = 0
        ReleaseLogCountAfter = 0
        ReleaseLogged = $false
        Error = $null
        Pass = $false
    }

    try {
        $doc = Add-TemporaryDocument $app $officeHost.Name
        Start-Sleep -Milliseconds $StartupDelayMs

        $workspace = Open-Workspace $app $officeHost.Name
        $roundResult.Workspace = $workspace
        $roundResult.WindowHandle = [int64]$workspace.WindowHandle
        $roundResult.WorkspacePass = [bool]$workspace.Pass
        if (-not $roundResult.WorkspacePass) {
            throw "OMNIX workspace did not become visible in $($officeHost.Name), round $round."
        }

        $hwnd = [IntPtr]([int64]$roundResult.WindowHandle)
        $roundResult.ReleaseLogCountBefore = Get-ReleaseLogCount $officeHost.Name $hwnd

        Close-TemporaryDocument $doc $officeHost.Name
        Release-ComObjectSafe $doc
        $doc = $null
        Start-Sleep -Milliseconds $ReleaseDelayMs

        $roundResult.ReleaseLogCountAfter = Get-ReleaseLogCount $officeHost.Name $hwnd
        $roundResult.ReleaseLogged = [bool](
            $roundResult.ReleaseLogCountAfter -gt $roundResult.ReleaseLogCountBefore)
        if (-not $roundResult.ReleaseLogged) {
            throw "No new task-pane release log was observed for $($officeHost.Name) HWND=$($roundResult.WindowHandle), round $round."
        }

        $roundResult.Pass = $true
    }
    catch {
        $roundResult.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $doc) {
            try { Close-TemporaryDocument $doc $officeHost.Name } catch { }
            Release-ComObjectSafe $doc
        }
    }

    return [pscustomobject]$roundResult
}

function Wait-HostProcessExit([string]$processName, [int]$timeoutMs = 10000) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue))
}

function Test-HostLifecycle($officeHost) {
    $app = $null
    $started = Get-Date
    $result = [ordered]@{
        Host = $officeHost.Name
        Installed = $true
        Started = $false
        Version = $null
        FirstRound = $null
        SecondRound = $null
        FirstReleasePass = $false
        ReopenPass = $false
        SecondReleasePass = $false
        ProcessExitedPass = $false
        Error = $null
        DurationMs = 0
        Pass = $false
    }

    try {
        $app = New-Object -ComObject $officeHost.ProgId
        $result.Started = $true
        try { $app.Visible = $true } catch { }
        try { $app.DisplayAlerts = $false } catch { }
        try { $result.Version = [string]$app.Version } catch { $result.Version = 'unknown' }

        $first = Invoke-LifecycleRound $app $officeHost 1
        $result.FirstRound = $first
        $result.FirstReleasePass = [bool]($first.Pass -and $first.ReleaseLogged)
        if (-not $result.FirstReleasePass) { throw "First lifecycle round failed for $($officeHost.Name)." }

        # The second round is the stale-state detector: a new Office document must still get a
        # working OMNIX workspace after the first window/controller was destroyed.
        $second = Invoke-LifecycleRound $app $officeHost 2
        $result.SecondRound = $second
        $result.ReopenPass = [bool]$second.WorkspacePass
        $result.SecondReleasePass = [bool]($second.Pass -and $second.ReleaseLogged)
        if (-not ($result.ReopenPass -and $result.SecondReleasePass)) {
            throw "Second lifecycle/reopen round failed for $($officeHost.Name)."
        }

        try { $app.Quit() } catch { }
        Release-ComObjectSafe $app
        $app = $null
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        $result.ProcessExitedPass = Wait-HostProcessExit $officeHost.Process
        if (-not $result.ProcessExitedPass) {
            throw "$($officeHost.Name) process remained after Quit; lifecycle evidence is not clean."
        }

        $result.Pass = $true
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147221164) {
            $result.Installed = $false
            $result.Error = 'Office COM class is not registered; this host appears not installed.'
        } else {
            $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
        }
    }
    catch {
        $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $app) {
            try { $app.Quit() } catch { }
            Release-ComObjectSafe $app
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $result.ProcessExitedPass = [bool]($result.ProcessExitedPass -or (Wait-HostProcessExit $officeHost.Process 5000))
        $result.DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
        $result.Pass = [bool](
            $result.Started -and
            $result.FirstReleasePass -and
            $result.ReopenPass -and
            $result.SecondReleasePass -and
            $result.ProcessExitedPass -and
            [string]::IsNullOrWhiteSpace([string]$result.Error))
    }

    return [pscustomobject]$result
}

$running = @()
foreach ($officeHost in $hosts) {
    if (Get-Process -Name $officeHost.Process -ErrorAction SilentlyContinue) { $running += $officeHost.Name }
}
if ($running.Count -gt 0) {
    throw "Close Excel, Word and PowerPoint before running task-pane lifecycle acceptance. Running: $($running -join ', ')"
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($officeHost in $hosts) {
    $results.Add((Test-HostLifecycle $officeHost))
    Start-Sleep -Milliseconds 800
}

$installed = @($results | Where-Object { $_.Installed })
$failures = New-Object System.Collections.Generic.List[string]
if ($installed.Count -ne 3) { $failures.Add("Expected Excel, Word and PowerPoint; installed/testable host count was $($installed.Count).") }
foreach ($row in $installed) {
    if (-not $row.Pass) { $failures.Add("$($row.Host) task-pane lifecycle acceptance failed.") }
}

$report = [ordered]@{
    TestId = 'TASKPANE-LIFECYCLE-REAL-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Machine = $env:COMPUTERNAME
    Windows = [Environment]::OSVersion.VersionString
    InteractiveSession = [Environment]::UserInteractive
    StartupLogPath = $startupLog
    RequiredHostCount = 3
    InstalledHostCount = $installed.Count
    TwoRoundsPerHostRequired = $true
    Results = $results
    FailureCount = $failures.Count
    Failures = @($failures)
    OverallPass = ($failures.Count -eq 0)
    Safety = 'Temporary unsaved Office documents only. No registry policy, Trust Center, Office Resiliency, network, firewall or restart changes.'
}

$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 12

if (-not $report.OverallPass) { exit 1 }
exit 0
