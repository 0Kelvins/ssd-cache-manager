# End-to-end harness for the promote progress pipeline.
# Loads the merged GUI source (functions only), builds the controls, then runs
# a real promote through Start-Operation / Poll-Operation and records, tick by
# tick, the internal state that decides whether the progress bar advances.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$src = [IO.File]::ReadAllText('E:\Work\ssd-cache-manager\build\SSDCacheManager-src.ps1')
# Cut before the launcher region: it contains the elevation guard, which would
# pop a modal "administrator required" dialog and exit 1.
$anchor = '$form = Initialize-Controls'
$idx = $src.IndexOf($anchor)
if ($idx -lt 0) { throw 'anchor not found' }
$head = $src.Substring(0, $idx)
$lastRegion = $head.LastIndexOf('#region')
if ($lastRegion -gt 0) { $head = $head.Substring(0, $lastRegion) }
. ([scriptblock]::Create($head))

$script:report = New-Object System.Collections.Generic.List[string]
function AddRep([string]$t) { $script:report.Add($t) }

$form = Initialize-Controls
$script:Form = $form
AddRep ('controls built; cacheRoot=' + $state.CacheRoot)

# ---- build a test tree ----
$srcDir = 'F:\_progtest_src'
$cacheRoot = 'E:\_progtest_cache'
if (Test-Path $srcDir) { Remove-Item -LiteralPath $srcDir -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $cacheRoot) { Remove-Item -LiteralPath $cacheRoot -Recurse -Force -ErrorAction SilentlyContinue }
$null = New-Item -ItemType Directory -Path $srcDir -Force
$null = New-Item -ItemType Directory -Path $cacheRoot -Force
$oneMB = New-Object byte[] (1MB)
(New-Object Random 42).NextBytes($oneMB)
for ($f = 1; $f -le 300; $f++) {
    [IO.File]::WriteAllBytes((Join-Path $srcDir ('file-{0:D3}.bin' -f $f)), $oneMB)
}
$sz = (Get-ChildItem -LiteralPath $srcDir -File | Measure-Object -Property Length -Sum).Sum
$cnt = (Get-ChildItem -LiteralPath $srcDir -File).Count
AddRep ('test tree: ' + $cnt + ' files, ' + $sz + ' bytes')
$state.CacheRoot = $cacheRoot
$script:CacheRootBox.Text = $cacheRoot

# ---- run the operation ----
Start-Operation -Mode Promote -Paths @($srcDir) -Root $cacheRoot -Sizes @([int64]$sz) -Counts @([int64]$cnt) -TotalBytes ([int64]$sz)
AddRep ('after Start-Operation: OpBusy=' + $state.OpBusy + ' OpTotalBytes=' + $script:OpTotalBytes + ' OpTotalFiles=' + $script:OpTotalFiles)

$deadline = (Get-Date).AddSeconds(120)
$tick = 0
while ((Get-Date) -lt $deadline) {
    $tick++
    try { Poll-Operation } catch { AddRep ('TICK ' + $tick + ' POLL THREW: ' + $_.Exception.Message) }
    $m = $script:OpMeas
    $pb = $script:ProgressBar.Value
    AddRep ('tick ' + $tick + ' busy=' + $state.OpBusy + ' | measBusy=' + $m.Busy + ' cachePath=' + $m.CachePath + ' dirSize=' + $m.SizeBytes + ' fileTotal=' + $m.FileTotal + ' doneBytes=' + $m.DoneBytes + ' filesBase=' + $m.FilesDoneBase + ' | bar=' + $pb + ' pct=[' + $script:PercentLabel.Text + '] cnt=[' + $script:CountLabel.Text + '] line=[' + $script:OpStatusLabel.Text + ']')
    if ($null -ne $script:OpPS) {
        $raw = @($script:OpPS.Streams.Progress)
        for ($ri = 0; $ri -lt $raw.Count; $ri++) {
            $rr = $raw[$ri]
            if ($null -eq $rr) { continue }
            AddRep ('   raw[' + $ri + '] id=' + $rr.ActivityId + ' act=[' + $rr.Activity + '] st=[' + $rr.StatusDescription + '] cur=[' + $rr.CurrentOperation + '] pct=' + $rr.PercentComplete + ' type=' + $rr.RecordType)
        }
    }
    if (-not $state.OpBusy) { AddRep ('operation ended at tick ' + $tick); break }
    Start-Sleep -Milliseconds 700
}

AddRep '==== phase 2: demote ===='
Start-Operation -Mode Demote -Paths @($srcDir) -Root $cacheRoot -Sizes @([int64]$sz) -Counts @([int64]$cnt) -TotalBytes ([int64]$sz)
$tick = 0
while ((Get-Date) -lt $deadline) {
    $tick++
    try { Poll-Operation } catch { AddRep ('DEMOTE TICK ' + $tick + ' POLL THREW: ' + $_.Exception.Message) }
    $m = $script:OpMeas
    AddRep ('demote tick ' + $tick + ' busy=' + $state.OpBusy + ' | cachePath=' + $m.CachePath + ' dirSize=' + $m.SizeBytes + ' | bar=' + $script:ProgressBar.Value + ' cnt=[' + $script:CountLabel.Text + '] line=[' + $script:OpStatusLabel.Text + ']')
    if (-not $state.OpBusy) { AddRep ('demote ended at tick ' + $tick); break }
    Start-Sleep -Milliseconds 700
}

AddRep '---- log box ----'
AddRep $script:LogBox.Text
AddRep '---- on disk ----'
AddRep ('cache exists: ' + (Test-Path $cacheRoot))
try {
    $it = Get-Item -LiteralPath $srcDir -Force
    AddRep ('src attributes: ' + $it.Attributes)
    AddRep ('src target: ' + $it.Target)
} catch { AddRep ('item error: ' + $_.Exception.Message) }

[IO.File]::WriteAllText('E:\Work\ssd-cache-manager\_e2e_report.txt', ($script:report -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
'written'
