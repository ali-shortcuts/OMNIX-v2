# OMNIX real Office -> AI Gateway/provider -> rendered UI end-to-end acceptance
#
# Run only on an interactive Windows desktop AFTER OMNIX is installed and a usable provider/model
# is configured. The provider can be local or cloud; this script never changes privacy settings,
# API keys, networking, Trust Center or Office policy.
#
# For each required host (Excel, Word, PowerPoint) the test:
#   1. Creates a TEMPORARY UNSAVED document containing a cryptographically-random marker.
#   2. Selects/exposes that marker through the normal Office context adapter path.
#   3. Opens the real OMNIX Ribbon -> Workspace.
#   4. Starts a new chat and asks the model to return the current Office selection/slide text.
#      The prompt NEVER contains the marker, so echoing the prompt cannot fake the test.
#   5. Requires a rendered OMNIX assistant message to contain the random marker.
#   6. Clears the test chat, closes the temporary document WITHOUT SAVING and quits Office.
#
# This is deliberately separate from provider-acceptance.ps1: it proves the complete path
# Office context -> Workspace -> AiGateway -> configured provider/model -> stream -> WPF chat UI.

[CmdletBinding()]
param(
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\real-office-ai-e2e.json",
    [int]$StartupDelayMs = 2200,
    [int]$WorkspaceDelayMs = 1400,
    [int]$ResponseTimeoutSec = 75
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Security

$hosts = @(
    [pscustomobject]@{ Name='Excel';      ProgId='Excel.Application';      Process='EXCEL' },
    [pscustomobject]@{ Name='Word';       ProgId='Word.Application';       Process='WINWORD' },
    [pscustomobject]@{ Name='PowerPoint'; ProgId='PowerPoint.Application'; Process='POWERPNT' }
)

$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Release-ComObjectSafe($obj) {
    if ($null -ne $obj) {
        try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { }
    }
}

function Assert-NoOfficeProcesses {
    $running = @()
    foreach ($officeHost in $hosts) {
        if (Get-Process -Name $officeHost.Process -ErrorAction SilentlyContinue) { $running += $officeHost.Name }
    }
    if ($running.Count -gt 0) {
        throw "Close Excel, Word and PowerPoint before running OFFICE-AI-E2E-REAL-001. Running: $($running -join ', ')"
    }
}

function New-RandomMarker([string]$hostName) {
    return ('OMNIX_E2E_' + $hostName.ToUpperInvariant() + '_' + [Guid]::NewGuid().ToString('N')).ToUpperInvariant()
}

function Get-Sha256Text([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Add-TemporaryOfficeContent($app, [string]$hostName, [string]$marker) {
    switch ($hostName) {
        'Excel' {
            $book = $app.Workbooks.Add()
            $sheet = $book.Worksheets.Item(1)
            $cell = $sheet.Range('A1')
            $cell.Value2 = $marker
            [void]$cell.Select()
            Release-ComObjectSafe $cell
            Release-ComObjectSafe $sheet
            return $book
        }
        'Word' {
            $doc = $app.Documents.Add()
            $doc.Content.Text = $marker
            $range = $doc.Range(0, $marker.Length)
            [void]$range.Select()
            Release-ComObjectSafe $range
            return $doc
        }
        'PowerPoint' {
            $pres = $app.Presentations.Add()
            # 12 = ppLayoutBlank. 1 = msoTextOrientationHorizontal.
            $slide = $pres.Slides.Add(1, 12)
            $shape = $slide.Shapes.AddTextbox(1, 40, 40, 620, 90)
            $shape.TextFrame.TextRange.Text = $marker
            try {
                if ($null -ne $app.ActiveWindow) { $app.ActiveWindow.View.GotoSlide(1) }
            } catch { }
            Release-ComObjectSafe $shape
            Release-ComObjectSafe $slide
            return $pres
        }
        default { throw "Unsupported host: $hostName" }
    }
}

function Close-TemporaryOfficeContent($doc, [string]$hostName) {
    if ($null -eq $doc) { return }
    try {
        switch ($hostName) {
            'Excel'      { $doc.Close($false) }
            'Word'       { $doc.Close(0) }
            'PowerPoint' { $doc.Close() }
        }
    } catch { }
}

function Get-OfficeWindowHandle($app, [string]$hostName) {
    try {
        switch ($hostName) {
            'Excel'      { return [IntPtr]([int64]$app.Hwnd) }
            'Word'       { if ($null -ne $app.ActiveWindow) { return [IntPtr]([int64]$app.ActiveWindow.Hwnd) } }
            'PowerPoint' {
                if ($null -ne $app.ActiveWindow) { return [IntPtr]([int64]$app.ActiveWindow.HWND) }
                return [IntPtr]([int64]$app.HWND)
            }
        }
    } catch { }
    return [IntPtr]::Zero
}

function Find-UiElementByAutomationId($root, [string]$automationId) {
    if ($null -eq $root) { return $null }
    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
        return $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    } catch { return $null }
}

function Find-AllUiElementsByAutomationId($root, [string]$automationId) {
    if ($null -eq $root) { return @() }
    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $automationId)
        $found = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
        $items = @()
        foreach ($x in $found) { $items += $x }
        return $items
    } catch { return @() }
}

function Find-UiElementByExactName($root, [string]$name) {
    if ($null -eq $root) { return $null }
    try {
        $condition = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $name)
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
                    if ($name.IndexOf($fragment, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $element }
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
            ([System.Windows.Automation.SelectionItemPattern]$pattern).Select(); return $true
        }
    } catch { }
    $pattern = $null
    try {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.InvokePattern]$pattern).Invoke(); return $true
        }
    } catch { }
    return $false
}

function Set-UiValue($element, [string]$value) {
    if ($null -eq $element) { return $false }
    $pattern = $null
    try {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$pattern)) {
            ([System.Windows.Automation.ValuePattern]$pattern).SetValue($value)
            return $true
        }
    } catch { }
    return $false
}

function Get-UiText($element) {
    if ($null -eq $element) { return '' }
    $pattern = $null
    try {
        if ($element.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$pattern)) {
            return ([System.Windows.Automation.TextPattern]$pattern).DocumentRange.GetText(-1)
        }
    } catch { }
    try { return [string]$element.Current.Name } catch { return '' }
}

function Wait-ForElementByAutomationId($root, [string]$id, [int]$timeoutMs) {
    $deadline = (Get-Date).AddMilliseconds($timeoutMs)
    do {
        $e = Find-UiElementByAutomationId $root $id
        if ($null -ne $e) { return $e }
        Start-Sleep -Milliseconds 180
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Wait-ForAssistantMarker($root, [string]$marker, [int]$timeoutSec) {
    $started = Get-Date
    $deadline = $started.AddSeconds($timeoutSec)
    $lastBodies = 0
    do {
        $bodies = @(Find-AllUiElementsByAutomationId $root 'OMNIX.AssistantMessageBody')
        $lastBodies = $bodies.Count
        for ($i = $bodies.Count - 1; $i -ge 0; $i--) {
            $text = Get-UiText $bodies[$i]
            if (-not [string]::IsNullOrEmpty($text) -and
                $text.IndexOf($marker, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return [pscustomobject]@{
                    Found = $true
                    DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
                    AssistantBodiesSeen = $lastBodies
                    ResponseChars = $text.Length
                }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    return [pscustomobject]@{
        Found = $false
        DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
        AssistantBodiesSeen = $lastBodies
        ResponseChars = 0
    }
}

function Prompt-ForHost([string]$hostName) {
    switch ($hostName) {
        'Excel'      { return 'Return only the exact text currently in the selected Excel cell. No explanation.' }
        'Word'       { return 'Return only the exact selected text from the current Word document. No explanation.' }
        'PowerPoint' { return 'Return only the exact marker text visible on the current PowerPoint slide. No explanation.' }
    }
    return 'Return only the exact current Office selection text.'
}

function Test-HostAiE2E($officeHost) {
    $app = $null
    $doc = $null
    $started = Get-Date
    $marker = New-RandomMarker $officeHost.Name
    $result = [ordered]@{
        Host = $officeHost.Name
        Installed = $true
        Started = $false
        Version = $null
        TemporaryDocumentCreated = $false
        MarkerSha256 = Get-Sha256Text $marker
        WindowHandleFound = $false
        RibbonTabFound = $false
        WorkspaceOpened = $false
        NewChatInvoked = $false
        ContextControlFound = $false
        ChatInputFound = $false
        InputSet = $false
        SendButtonFound = $false
        SendInvoked = $false
        AssistantMarkerMatched = $false
        AssistantBodiesSeen = 0
        ResponseChars = 0
        ResponseMs = $null
        StatusElementFound = $false
        ProcessExitedCleanly = $false
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

        $doc = Add-TemporaryOfficeContent $app $officeHost.Name $marker
        $result.TemporaryDocumentCreated = ($null -ne $doc)
        Start-Sleep -Milliseconds $StartupDelayMs

        $hwnd = Get-OfficeWindowHandle $app $officeHost.Name
        if ($hwnd -eq [IntPtr]::Zero) { throw 'Could not obtain the active Office window handle.' }
        $result.WindowHandleFound = $true

        $root = [System.Windows.Automation.AutomationElement]::FromHandle($hwnd)
        if ($null -eq $root) { throw 'UI Automation could not attach to the Office window.' }

        $tab = Find-UiElementByExactName $root 'OMNIX'
        if ($null -eq $tab) { $tab = Find-UiElementByNameFragment $root @('OMNIX') }
        $result.RibbonTabFound = ($null -ne $tab)
        if ($null -eq $tab -or -not (Activate-UiElement $tab)) { throw 'OMNIX Ribbon tab could not be activated.' }
        Start-Sleep -Milliseconds 450

        $open = Find-UiElementByExactName $root 'Open Workspace'
        if ($null -eq $open) { $open = Find-UiElementByNameFragment $root @('Open Workspace') }
        if ($null -eq $open -or -not (Activate-UiElement $open)) { throw 'Open Workspace could not be invoked.' }
        Start-Sleep -Milliseconds $WorkspaceDelayMs

        $input = Wait-ForElementByAutomationId $root 'OMNIX.ChatInput' 10000
        $result.ChatInputFound = ($null -ne $input)
        $result.WorkspaceOpened = $result.ChatInputFound
        if ($null -eq $input) { throw 'OMNIX chat input did not become visible.' }

        $context = Find-UiElementByAutomationId $root 'OMNIX.ContextText'
        $result.ContextControlFound = ($null -ne $context)

        $newChat = Find-UiElementByAutomationId $root 'OMNIX.NewChatButton'
        if ($null -ne $newChat) {
            $result.NewChatInvoked = Activate-UiElement $newChat
            Start-Sleep -Milliseconds 250
        }

        $prompt = Prompt-ForHost $officeHost.Name
        $result.InputSet = Set-UiValue $input $prompt
        if (-not $result.InputSet) { throw 'Could not set OMNIX chat input through UI Automation ValuePattern.' }

        $send = Find-UiElementByAutomationId $root 'OMNIX.SendButton'
        $result.SendButtonFound = ($null -ne $send)
        if ($null -eq $send) { throw 'OMNIX Send button was not found.' }
        $result.SendInvoked = Activate-UiElement $send
        if (-not $result.SendInvoked) { throw 'OMNIX Send button could not be invoked.' }

        $wait = Wait-ForAssistantMarker $root $marker $ResponseTimeoutSec
        $result.AssistantMarkerMatched = [bool]$wait.Found
        $result.AssistantBodiesSeen = [int]$wait.AssistantBodiesSeen
        $result.ResponseChars = [int]$wait.ResponseChars
        $result.ResponseMs = [int]$wait.DurationMs

        $status = Find-UiElementByAutomationId $root 'OMNIX.StatusText'
        $result.StatusElementFound = ($null -ne $status)

        if (-not $result.AssistantMarkerMatched) {
            $statusText = Get-UiText $status
            if ([string]::IsNullOrWhiteSpace($statusText) -or $statusText -eq 'OMNIX status') {
                $statusText = 'No matching assistant marker was rendered before timeout. Verify provider/model, privacy mode and network/local-runtime availability.'
            }
            throw $statusText
        }

        $clear = Find-UiElementByAutomationId $root 'OMNIX.ClearButton'
        if ($null -ne $clear) { [void](Activate-UiElement $clear) }

        $result.Pass = [bool](
            $result.Started -and
            $result.TemporaryDocumentCreated -and
            $result.WindowHandleFound -and
            $result.RibbonTabFound -and
            $result.WorkspaceOpened -and
            $result.ChatInputFound -and
            $result.InputSet -and
            $result.SendButtonFound -and
            $result.SendInvoked -and
            $result.AssistantMarkerMatched)
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147221164) {
            $result.Installed = $false
            $result.Error = 'Office COM class is not registered; this required host appears not installed.'
        } else {
            $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
        }
    }
    catch {
        $result.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    }
    finally {
        Close-TemporaryOfficeContent $doc $officeHost.Name
        if ($null -ne $app) { try { $app.Quit() } catch { } }
        Release-ComObjectSafe $doc
        Release-ComObjectSafe $app
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 800
        $result.ProcessExitedCleanly = ($null -eq (Get-Process -Name $officeHost.Process -ErrorAction SilentlyContinue))
        if (-not $result.ProcessExitedCleanly) { $result.Pass = $false }
        $result.DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
    }

    return [pscustomobject]$result
}

Assert-NoOfficeProcesses

$results = New-Object System.Collections.Generic.List[object]
foreach ($officeHost in $hosts) {
    $results.Add((Test-HostAiE2E $officeHost))
    Start-Sleep -Milliseconds 1000
}

$installed = @($results | Where-Object { $_.Installed })
$requiredHostCountPass = ($installed.Count -eq 3)
$allMarkerRoundTripsPass = ($requiredHostCountPass -and @($installed | Where-Object { -not $_.AssistantMarkerMatched }).Count -eq 0)
$allProcessesExitedPass = ($requiredHostCountPass -and @($installed | Where-Object { -not $_.ProcessExitedCleanly }).Count -eq 0)
$allRowsPass = ($requiredHostCountPass -and @($installed | Where-Object { -not $_.Pass }).Count -eq 0)
$overallPass = [bool]($requiredHostCountPass -and $allMarkerRoundTripsPass -and $allProcessesExitedPass -and $allRowsPass)

$report = [ordered]@{
    TestId = 'OFFICE-AI-E2E-REAL-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Windows = [Environment]::OSVersion.VersionString
    InteractiveSession = [Environment]::UserInteractive
    RequiredHosts = @($hosts | Select-Object -ExpandProperty Name)
    RequiredHostCountPass = $requiredHostCountPass
    AllMarkerRoundTripsPass = $allMarkerRoundTripsPass
    AllProcessesExitedPass = $allProcessesExitedPass
    OverallPass = $overallPass
    Results = $results
    Privacy = 'Reports only test-generated marker hashes/timings/status; no provider keys, model response bodies or user Office content are stored.'
    Safety = 'Temporary unsaved Office documents only; no Trust Center/Resiliency/network/privacy-setting changes.'
}

$report | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 9

if (-not $overallPass) { exit 1 }
exit 0