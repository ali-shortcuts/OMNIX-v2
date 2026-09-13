param([string]$OutputDirectory="$env:LOCALAPPDATA\OMNIX\v4\office-acceptance")
$ErrorActionPreference='Stop'
# Run interactively after installing the EXE. Does not connect a disabled add-in,
# invoke OpenWorkspace, edit security settings, or touch existing user documents.
if(Get-Process WINWORD,EXCEL,POWERPNT -ErrorAction SilentlyContinue){throw 'Close Word, Excel and PowerPoint before this test.'}
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$results=@()
function Wait-Panes($app,[int]$expected) {
    $deadline=[DateTime]::UtcNow.AddSeconds(45)
    $state=''
    do {
        try {
            $addin=$app.COMAddIns.Item('OMNIX')
            if($addin.Connect){
                $state=[string]$addin.Object.Health
                if($state -match (';panes='+$expected+'$')){return $state}
            }
        } catch {$state=$_.Exception.Message}
        Start-Sleep -Milliseconds 500
    } while([DateTime]::UtcNow -lt $deadline)
    throw "Automatic workspace did not reach $expected pane(s): $state"
}
foreach($hostName in @('Word','Excel','PowerPoint')) {
    for($launch=1;$launch -le 2;$launch++) {
        $app=$null;$first=$null;$second=$null
        try {
            $app=New-Object -ComObject "$hostName.Application"
            $app.Visible=$true
            switch($hostName) {
                Word {$first=$app.Documents.Add()}
                Excel {$first=$app.Workbooks.Add()}
                PowerPoint {$first=$app.Presentations.Add(-1)}
            }
            $one=Wait-Panes $app 1
            switch($hostName) {
                Word {$second=$app.Documents.Add()}
                Excel {$second=$app.Workbooks.Add()}
                PowerPoint {$second=$app.Presentations.Add(-1)}
            }
            $two=Wait-Panes $app 2
            switch($hostName) {
                Word {$second.Close(0)}
                Excel {$second.Close($false)}
                PowerPoint {$second.Saved=-1;$second.Close()}
            }
            $second=$null
            $afterClose=Wait-Panes $app 1
            $results+=@{Host=$hostName;Launch=$launch;Passed=$true;AutomaticStartup=$one;TwoWindows=$two;AfterClose=$afterClose}
        } catch {
            $results+=@{Host=$hostName;Launch=$launch;Passed=$false;Error=$_.Exception.Message}
        } finally {
            foreach($doc in @($second,$first)) {
                if($null -ne $doc){try {
                    switch($hostName) {
                        Word {$doc.Close(0)}
                        Excel {$doc.Close($false)}
                        PowerPoint {$doc.Saved=-1;$doc.Close()}
                    }
                } catch {}}
            }
            if($null -ne $app){try{$app.Quit()}catch{};[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($app)}
            $first=$null;$second=$null;$app=$null
            [GC]::Collect();[GC]::WaitForPendingFinalizers()
        }
    }
}
$results | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'office-runtime.json')
if(@($results | Where-Object { -not $_.Passed }).Count){throw 'Office acceptance failed; see office-runtime.json.'}
Write-Host 'Startup and window lifecycle checks passed. Reboot and visual acceptance remain separate.'
