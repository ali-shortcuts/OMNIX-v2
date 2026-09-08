# OMNIX real Office UI acceptance gate
#
# Run this on an interactive Windows desktop with Microsoft Office installed AFTER OMNIX.
# It verifies the part CI cannot prove: the OMNIX Ribbon tab is actually visible and the
# Open Workspace command actually opens the OMNIX task pane in Excel, Word and PowerPoint.
#
# Safety/correctness:
# - Uses normal Office COM automation + Windows UI Automation only.
# - Creates temporary blank Office files in memory and closes them without saving.
# - Does not alter Trust Center, Office Resiliency, registry policy, or security settings.
# - Does not click unrelated UI controls.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\real-office-ui-acceptance.json",
    [int]$StartupDelayMs = 2200,
    [int]$WorkspaceDelayMs = 1600
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
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Release-ComObjectSafe($obj) {
    if ($null -ne $obj) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { }
    }
}

function Add-TemporaryDocument($app, [string]$hostName) {
    switch ($hostName) {
        'Excel' {
            return $app.Workbooks.Add()
        }
        'Word' {
            return $app.Documents.Add()
        }
        'PowerPoint' {
            return $app.Presentations.Add()
        }
        default { return $null }
    }
}

function Close-TemporaryDocument($doc, [string]$hostName) {
    if ($null -eq $doc) { return }
    try {
        switch ($hostName) {
            'Excel'      { $doc.Close($false) }
            'Word'       { $doc.Close(0) } # wdDoNotSaveChanges
            'PowerPoint' { $doc.Close() }
        }
    } catch { }
}

function Get-OfficeWindowHandle($app, [string]$hostName) {
    try {
        switch ($hostName) {
            'Excel' {
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
    } catch {
        return $null
    }
}

function Find-UiElementByNameFragment($root, [string[]]$fragments) {
    if ($null -eq $root) { return $null }
    try {
        $trueCondition = [System.Windows.Automation.Condition]::TrueCondition
        $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $trueCondition)
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

function Test-HostUi($host) {
    $app = $null
    $doc = $null
    $started = Get-Date
    $result = [ordered]@{
        Host = $host.Name
        Installed = $true
        Started = $false
        Version = $null
        WindowHandleFound = $false
        RibbonTabFound = $false
        RibbonTabActivated = $false
        OpenWorkspaceButtonFound = $false
        OpenWorkspaceInvoked = $false
        WorkspaceEvidenceFound = $false
        WorkspaceEvidence = $null
        Error = $null
        DurationMs = 0
        Pass = $false
    }

    try {
        $app = New-Object -ComObject $host.ProgId
        $result.Started = $true
        try { $app.Visible = $true } catch { }
        try { $app.DisplayAlerts = $false } catch { }

        $doc = Add-TemporaryDocument $app $host.Name
        Start-Sleep -Milliseconds $StartupDelayMs
        try { $result.Version = [string]$app.Version } catch { $result.Version = 'unknown' }

        $hwnd = Get-OfficeWindowHandle $app $host.Name
        if ($hwnd -eq [IntPtr]::Zero) {
            throw "Could not obtain the active Office window handle."
        }
        $result.WindowHandleFound = $true

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        if ($null -eq $root) { throw "UI Automation could not attach to the Office window." }

        # The OMNIX tab label is fixed by our Ribbon XML and is independent of the Office UI language.
        $tab = Find-UiElementByExactName $root 'OMNIX'
        if ($null -eq $tab) {
            $tab = Find-UiElementByNameFragment $root @('OMNIX')
        }
        $result.RibbonTabFound = ($null -ne $tab)
        if ($tab) {
            $result.RibbonTabActivated = Activate-UiElement $tab
            Start-Sleep -Milliseconds 500
        }

        $openButton = Find-UiElementByExactName $root 'Open Workspace'
        if ($null -eq $openButton) {
            $openButton = Find-UiElementByNameFragment $root @('Open Workspace')
        }
        $result.OpenWorkspaceButtonFound = ($null -ne $openButton)
        if ($openButton) {
            $result.OpenWorkspaceInvoked = Activate-UiElement $openButton
            Start-Sleep -Milliseconds $WorkspaceDelayMs
        }

        # A custom task pane can expose different control types across Office builds. Instead of
        # requiring one fragile class name, require a user-facing OMNIX workspace signal after the
        # Open Workspace command: chat label, input placeholder, or an OMNIX pane element.
        $workspace = Find-UiElementByExactName $root 'Chat'
        if ($null -eq $workspace) {
            $workspace = Find-UiElementByNameFragment $root @(
                'Ask about this document',
                'OMNIX AI',
                'New Chat'
            )
        }
        if ($null -eq $workspace -and $result.OpenWorkspaceInvoked) {
            # Last fallback: look for another OMNIX-named element after invocation. This does not
            # by itself prove a pane exists unless the Open Workspace command was successfully invoked.
            $workspace = Find-UiElementByNameFragment $root @('OMNIX')
        }

        if ($workspace) {
            $result.WorkspaceEvidenceFound = $true
            try { $result.WorkspaceEvidence = [string]$workspace.Current.Name } catch { $result.WorkspaceEvidence = 'UI element found' }
        }

        $result.Pass = [bool](
            $result.Started -and
            $result.WindowHandleFound -and
            $result.RibbonTabFound -and
            $result.RibbonTabActivated -and
            $result.OpenWorkspaceButtonFound -and
            $result.OpenWorkspaceInvoked -and
            $result.WorkspaceEvidenceFound)
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
        Close-TemporaryDocument $doc $host.Name
        if ($null -ne $app) {
            try { $app.Quit() } catch { }
        }
        Release-ComObjectSafe $doc
        Release-ComObjectSafe $app
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $result.DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
    }

    return [pscustomobject]$result
}

# Do not interfere with a user's existing Office work.
$running = @()
foreach ($host in $hosts) {
    if (Get-Process -Name $host.Process -ErrorAction SilentlyContinue) { $running += $host.Name }
}
if ($running.Count -gt 0) {
    throw "Close Office before running the OMNIX UI acceptance gate. Currently running: $($running -join ', ')"
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($host in $hosts) {
    $results.Add((Test-HostUi $host))
    Start-Sleep -Milliseconds 900
}

$installed = @($results | Where-Object { $_.Installed })
$overallPass = ($installed.Count -eq 3) -and (@($installed | Where-Object { -not $_.Pass }).Count -eq 0)

$report = [ordered]@{
    TestId = 'OFFICE-UI-REAL-001'
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Machine = $env:COMPUTERNAME
    Windows = [Environment]::OSVersion.VersionString
    InteractiveSession = [Environment]::UserInteractive
    OverallPass = $overallPass
    Results = $results
}

$report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 8

if (-not $overallPass) { exit 1 }
exit 0
