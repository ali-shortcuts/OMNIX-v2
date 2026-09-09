# OMNIX real Office AI write-boundary acceptance
#
# Runs only on an interactive Windows machine with desktop Excel, Word and PowerPoint installed
# and OMNIX already installed. It uses temporary UNSAVED Office documents and deliberately submits
# over-broad/oversized write requests through the real compiled ToolExecutor with confirmation set
# to APPROVE. PASS means the host adapter itself still rejects those mutations before Office data
# changes. This proves that UI confirmation is not the only write-safety boundary.

[CmdletBinding()]
param(
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\OMNIX",
    [string]$OutputPath = "$env:LOCALAPPDATA\OMNIX\logs\office-write-boundary-acceptance.json",
    [int]$StartupDelayMs = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredFiles = @(
    'OMNIX.Core.dll',
    'Newtonsoft.Json.dll',
    'Microsoft.Office.Interop.Excel.dll',
    'Microsoft.Office.Interop.Word.dll',
    'Microsoft.Office.Interop.PowerPoint.dll'
)
foreach ($name in $requiredFiles) {
    $path = Join-Path $InstallDir $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required installed OMNIX file is missing: $path" }
}

foreach ($name in @('EXCEL','WINWORD','POWERPNT')) {
    if (Get-Process -Name $name -ErrorAction SilentlyContinue) {
        throw "Close Excel, Word and PowerPoint before OFFICE-WRITE-BOUNDARY-REAL-001. Running: $name"
    }
}

$logDir = Split-Path -Parent $OutputPath
if ($logDir) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

function Load-OmnixAssembly([string]$name) {
    [void][Reflection.Assembly]::LoadFrom((Join-Path $InstallDir $name))
}
Load-OmnixAssembly 'Newtonsoft.Json.dll'
Load-OmnixAssembly 'Microsoft.Office.Interop.Excel.dll'
Load-OmnixAssembly 'Microsoft.Office.Interop.Word.dll'
Load-OmnixAssembly 'Microsoft.Office.Interop.PowerPoint.dll'
$corePath = Join-Path $InstallDir 'OMNIX.Core.dll'
[void][Reflection.Assembly]::LoadFrom($corePath)

$bridgeSource = @'
using System.Threading.Tasks;
using OMNIX.Core.Tools;
namespace OMNIX.E2E {
    public static class BoundaryConfirmationBridge {
        public static Task<bool> Approve(WritePreview preview) { return Task.FromResult(true); }
    }
}
'@
Add-Type -TypeDefinition $bridgeSource -ReferencedAssemblies $corePath -ErrorAction Stop
$bridgeType = ('OMNIX.E2E.BoundaryConfirmationBridge' -as [type])
if ($null -eq $bridgeType) { throw 'Could not load OMNIX write-boundary confirmation bridge.' }

function Release-ComObjectSafe($obj) {
    if ($null -ne $obj) { try { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj) } catch { } }
}
function Wait-ProcessExit([string]$processName, [int]$timeoutMs = 5000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 200
    } while ($sw.ElapsedMilliseconds -lt $timeoutMs)
    return (-not (Get-Process -Name $processName -ErrorAction SilentlyContinue))
}
function New-ToolCall([string]$name, [string]$json) {
    $call = New-Object -TypeName 'OMNIX.Core.Tools.ToolCall'
    $call.Name = $name
    $call.ArgumentsJson = $json
    return $call
}
function New-ApprovedExecutor {
    $executor = New-Object -TypeName 'OMNIX.Core.Tools.ToolExecutor'
    $prop = $executor.GetType().GetProperty('WriteConfirmation')
    $method = $bridgeType.GetMethod('Approve')
    $delegate = [Delegate]::CreateDelegate($prop.PropertyType, $method)
    $prop.SetValue($executor, $delegate, $null)
    return $executor
}
function Invoke-Tool($executor, $call, $adapter) {
    return $executor.ExecuteAsync($call, $adapter).GetAwaiter().GetResult()
}
function Base-Result([string]$host) {
    return [ordered]@{
        Host = $host
        Installed = $true
        Started = $false
        Version = $null
        BoundaryChecks = [ordered]@{}
        AllBoundaryChecksPass = $false
        ProcessExitedCleanly = $false
        Error = $null
        Pass = $false
    }
}

function Test-ExcelBoundaries {
    $r = Base-Result 'Excel'
    $app=$null; $book=$null; $sheet=$null; $adapter=$null; $executor=$null
    try {
        $app = New-Object -ComObject Excel.Application
        $r.Started = $true
        $app.Visible = $false
        $app.DisplayAlerts = $false
        $r.Version = [string]$app.Version
        $book = $app.Workbooks.Add()
        $sheet = $app.ActiveSheet
        $sheet.Range('A1').Value2 = 'KEEP_A1'
        $sheet.Range('A2').Value2 = 'KEEP_A2'
        Start-Sleep -Milliseconds $StartupDelayMs

        $adapter = New-Object -TypeName 'OMNIX.Core.Context.ExcelHostAdapter' -ArgumentList @($app,[Func[int]]{2000},[Func[int]]{6000})
        $executor = New-ApprovedExecutor

        $multiWrite = Invoke-Tool $executor (New-ToolCall 'write_to_cell' '{"address":"A1:A2","value":"MUST_NOT_APPLY"}') $adapter
        $r.BoundaryChecks.MultiCellWriteRejected = [bool]((-not $multiWrite.Success) -and
            [string]$sheet.Range('A1').Value2 -eq 'KEEP_A1' -and [string]$sheet.Range('A2').Value2 -eq 'KEEP_A2')

        $multiFormula = Invoke-Tool $executor (New-ToolCall 'insert_formula' '{"address":"A1:A2","formula":"=1+1"}') $adapter
        $r.BoundaryChecks.MultiCellFormulaRejected = [bool]((-not $multiFormula.Success) -and
            [string]$sheet.Range('A1').Value2 -eq 'KEEP_A1' -and [string]$sheet.Range('A2').Value2 -eq 'KEEP_A2')

        $largeHighlight = Invoke-Tool $executor (New-ToolCall 'highlight_range' '{"address":"A1:Z100"}') $adapter
        $r.BoundaryChecks.OversizedHighlightRejected = [bool](-not $largeHighlight.Success)

        $badFormula = Invoke-Tool $executor (New-ToolCall 'insert_formula' '{"address":"B1","formula":"SUM(A1:A2)"}') $adapter
        $r.BoundaryChecks.NonFormulaPayloadRejected = [bool]((-not $badFormula.Success) -and [string]::IsNullOrEmpty([string]$sheet.Range('B1').Formula))

        $tooLongValue = 'X' * 33000
        $longJson = @{ address='C1'; value=$tooLongValue } | ConvertTo-Json -Compress
        $longWrite = Invoke-Tool $executor (New-ToolCall 'write_to_cell' $longJson) $adapter
        $r.BoundaryChecks.OversizedCellValueRejected = [bool]((-not $longWrite.Success) -and [string]::IsNullOrEmpty([string]$sheet.Range('C1').Value2))

        $r.AllBoundaryChecksPass = (@($r.BoundaryChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0)
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147221164) { $r.Installed=$false; $r.Error='Excel COM class is not registered.' }
        else { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    }
    catch { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    finally {
        if ($null -ne $book) { try { $book.Close($false) } catch { } }
        if ($null -ne $app) { try { $app.Quit() } catch { } }
        $adapter=$null; $executor=$null
        Release-ComObjectSafe $sheet; Release-ComObjectSafe $book; Release-ComObjectSafe $app
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $r.ProcessExitedCleanly = Wait-ProcessExit 'EXCEL'
    }
    $r.Pass = [bool]($r.Installed -and $r.Started -and $r.AllBoundaryChecksPass -and $r.ProcessExitedCleanly)
    return [pscustomobject]$r
}

function Test-WordBoundaries {
    $r = Base-Result 'Word'
    $app=$null; $doc=$null; $adapter=$null; $executor=$null
    try {
        $app = New-Object -ComObject Word.Application
        $r.Started = $true
        $app.Visible = $false
        $app.DisplayAlerts = 0
        $r.Version = [string]$app.Version
        $doc = $app.Documents.Add()
        $doc.Content.Text = 'WORD_KEEP_ORIGINAL'
        Start-Sleep -Milliseconds $StartupDelayMs

        $adapter = New-Object -TypeName 'OMNIX.Core.Context.WordHostAdapter' -ArgumentList @($app,[Func[int]]{6000})
        $executor = New-ApprovedExecutor

        $app.Selection.SetRange(0,0)
        $caretRewrite = Invoke-Tool $executor (New-ToolCall 'rewrite_selected_text' '{"text":"MUST_NOT_INSERT"}') $adapter
        $r.BoundaryChecks.CaretOnlyRewriteRejected = [bool]((-not $caretRewrite.Success) -and ([string]$doc.Content.Text).Contains('WORD_KEEP_ORIGINAL'))

        [void]$doc.Content.Select()
        $oversized = 'Y' * 50001
        $oversizedJson = @{ text=$oversized } | ConvertTo-Json -Compress
        $largeRewrite = Invoke-Tool $executor (New-ToolCall 'rewrite_selected_text' $oversizedJson) $adapter
        $r.BoundaryChecks.OversizedReplacementRejected = [bool]((-not $largeRewrite.Success) -and ([string]$doc.Content.Text).Contains('WORD_KEEP_ORIGINAL'))

        $r.AllBoundaryChecksPass = (@($r.BoundaryChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0)
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147221164) { $r.Installed=$false; $r.Error='Word COM class is not registered.' }
        else { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    }
    catch { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    finally {
        if ($null -ne $doc) { try { $doc.Close(0) } catch { } }
        if ($null -ne $app) { try { $app.Quit() } catch { } }
        $adapter=$null; $executor=$null
        Release-ComObjectSafe $doc; Release-ComObjectSafe $app
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $r.ProcessExitedCleanly = Wait-ProcessExit 'WINWORD'
    }
    $r.Pass = [bool]($r.Installed -and $r.Started -and $r.AllBoundaryChecksPass -and $r.ProcessExitedCleanly)
    return [pscustomobject]$r
}

function Test-PowerPointBoundaries {
    $r = Base-Result 'PowerPoint'
    $app=$null; $pres=$null; $slide=$null; $adapter=$null; $executor=$null
    try {
        $app = New-Object -ComObject PowerPoint.Application
        $r.Started = $true
        try { $app.Visible = -1 } catch { }
        $r.Version = [string]$app.Version
        $pres = $app.Presentations.Add()
        $slide = $pres.Slides.Add(1,1)
        try { $slide.Shapes.Title.TextFrame.TextRange.Text = 'PPT_KEEP_ORIGINAL' } catch { }
        try { $app.ActiveWindow.View.GotoSlide(1) } catch { }
        Start-Sleep -Milliseconds $StartupDelayMs

        $adapter = New-Object -TypeName 'OMNIX.Core.Context.PowerPointHostAdapter' -ArgumentList @($app,[Func[int]]{6000})
        $executor = New-ApprovedExecutor

        $largeBody = 'B' * 20001
        $bodyJson = @{ index='2'; title='BOUNDARY'; body=$largeBody } | ConvertTo-Json -Compress
        $insert = Invoke-Tool $executor (New-ToolCall 'insert_slide' $bodyJson) $adapter
        $r.BoundaryChecks.OversizedSlideBodyRejected = [bool]((-not $insert.Success) -and [int]$pres.Slides.Count -eq 1)

        $largeNotes = 'N' * 20001
        $notesJson = @{ slide='1'; notes=$largeNotes } | ConvertTo-Json -Compress
        $notes = Invoke-Tool $executor (New-ToolCall 'add_speaker_notes' $notesJson) $adapter
        $r.BoundaryChecks.OversizedSpeakerNotesRejected = [bool](-not $notes.Success)

        $largeTitle = 'T' * 501
        $titleJson = @{ index='2'; title=$largeTitle; body='small' } | ConvertTo-Json -Compress
        $title = Invoke-Tool $executor (New-ToolCall 'insert_slide' $titleJson) $adapter
        $r.BoundaryChecks.OversizedSlideTitleRejected = [bool]((-not $title.Success) -and [int]$pres.Slides.Count -eq 1)

        $r.AllBoundaryChecksPass = (@($r.BoundaryChecks.Values | Where-Object { -not [bool]$_ }).Count -eq 0)
    }
    catch [System.Runtime.InteropServices.COMException] {
        if ($_.Exception.HResult -eq -2147221164) { $r.Installed=$false; $r.Error='PowerPoint COM class is not registered.' }
        else { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    }
    catch { $r.Error="$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
    finally {
        if ($null -ne $pres) { try { $pres.Close() } catch { } }
        if ($null -ne $app) { try { $app.Quit() } catch { } }
        $adapter=$null; $executor=$null
        Release-ComObjectSafe $slide; Release-ComObjectSafe $pres; Release-ComObjectSafe $app
        [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        $r.ProcessExitedCleanly = Wait-ProcessExit 'POWERPNT'
    }
    $r.Pass = [bool]($r.Installed -and $r.Started -and $r.AllBoundaryChecksPass -and $r.ProcessExitedCleanly)
    return [pscustomobject]$r
}

$results = @(
    (Test-ExcelBoundaries),
    (Test-WordBoundaries),
    (Test-PowerPointBoundaries)
)
$requiredHostCountPass = (@($results | Where-Object { $_.Installed }).Count -eq 3)
$allBoundsPass = $requiredHostCountPass -and (@($results | Where-Object { -not $_.Pass }).Count -eq 0)

$report = [ordered]@{
    TestId = 'OFFICE-WRITE-BOUNDARY-REAL-001'
    EvidenceSchema = 1
    TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
    Windows = [Environment]::OSVersion.VersionString
    InteractiveSession = [Environment]::UserInteractive
    InstalledPayload = $InstallDir
    RequiredHosts = @('Excel','Word','PowerPoint')
    RequiredHostCountPass = $requiredHostCountPass
    AllBoundaryChecksPass = [bool]$allBoundsPass
    Results = $results
    OverallPass = [bool]$allBoundsPass
    Safety = 'Temporary unsaved Office documents only; invalid writes are approved by a deterministic test delegate and must still be rejected by compiled host bounds. No user files or Office security settings are modified.'
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
$report | ConvertTo-Json -Depth 10
if (-not $report.OverallPass) { exit 1 }
exit 0
