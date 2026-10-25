<#
    build-exe.ps1 - Build a single-file SSDCacheManager.exe

    WHAT IT DOES
      1. Reads SSDCacheGUI.ps1 and SSDCacheLib.psm1
      2. Produces a merged, self-contained script:
           - the whole library source is inlined as real code (so the main
             script has every function without Import-Module)
           - the same library source is also embedded as a here-string
             ($script:LibSource) so background runspaces can be assembled
             at runtime
           - Import-Module / module-path dependencies are removed
      3. Invokes ps2exe with -noConsole (no black window) and -requireAdmin
         (UAC prompt on double-click, replaces Start-SSDCacheManager.cmd)

    OUTPUT
      build\SSDCacheManager.exe        single file, no dependencies
      build\SSDCacheManager-src.ps1    the merged script (for inspection)

    NOTE ON ANTIVIRUS
      ps2exe-generated executables are frequently flagged by heuristic
      scanners as a false positive. If that happens, either add an
      exclusion for the exe or just keep using Start-SSDCacheManager.cmd,
      which runs the same code from plain script files.
#>

[CmdletBinding()]
param(
    [string]$ProjectRoot = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# $PSScriptRoot can come through empty under some nested-host invocations
# (seen when the build is launched by another PowerShell process), which then
# fails much later with an unrelated "empty string" Path binding error.
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ProjectRoot) { throw '$ProjectRoot could not be determined; pass -ProjectRoot explicitly.' }

$guiPath = Join-Path $ProjectRoot 'SSDCacheGUI.ps1'
$libPath = Join-Path $ProjectRoot 'SSDCacheLib.psm1'
$outDir  = Join-Path $ProjectRoot 'build'

foreach ($f in @($guiPath, $libPath)) {
    if (-not (Test-Path -LiteralPath $f)) { throw ("Missing input file: " + $f) }
}

$gui = [IO.File]::ReadAllText($guiPath)
$lib = [IO.File]::ReadAllText($libPath)

# ---- 1. trim the library: everything from Export-ModuleMember on is module-only
$cut = $lib.IndexOf('Export-ModuleMember')
if ($cut -lt 0) { throw 'Export-ModuleMember not found in library source.' }
$libCode = $lib.Substring(0, $cut).TrimEnd()

# ---- 2. strip the psm1 header comment block? keep it; it documents behavior.

# ---- 3. rewrite the GUI launcher block
#   a) drop the psm1 path line (regex: tolerant to line-ending style)
$patPath = '\$script:LibPath = Join-Path \$PSScriptRoot .SSDCacheLib\.psm1.\r?\n'
$rxPath = [regex]$patPath
$mmPath = $rxPath.Match($gui)
if (-not $mmPath.Success) { throw 'LibPath line not found in GUI source.' }
$gui = $gui.Remove($mmPath.Index, $mmPath.Length)
if ($gui.Length -eq 0) { throw 'GUI rewrite failed (empty).' }

#   b) drop the runtime read of the psm1 (exe embeds the source below)
$newRead = ''
$patRead = '(?s)if \(Test-Path -LiteralPath \$script:LibPath\) \{\r?\n\s*\$script:LibSource = \[IO\.File\]::ReadAllText\(\$script:LibPath\)\r?\n\}\r?\n'
$rxRead = [regex]$patRead
$mmRead = $rxRead.Match($gui)
if (-not $mmRead.Success) { throw 'Runtime read block not found in GUI source.' }
$gui = $gui.Remove($mmRead.Index, $mmRead.Length)

#   c) drop the module check + Import-Module in the startup try block
#      (regex: tolerant to line-ending style)
$pat = '(?s)    if \(-not \(Test-Path -LiteralPath \$script:LibPath\)\) \{.*?\}\r?\n    Import-Module \$script:LibPath -Force\r?\n\r?\n'
$rx = [regex]$pat
$mm = $rx.Match($gui)
if (-not $mm.Success) { throw 'Import-Module block not found in GUI source.' }
$gui = $gui.Remove($mm.Index, $mm.Length)

# ---- 4. inject the library: real code for the UI thread + here-string for workers
$inject = $libCode + [Environment]::NewLine + [Environment]::NewLine +
          '$script:LibSource = @' + "'" + [Environment]::NewLine +
          $libCode + [Environment]::NewLine +
          "'" + '@' + [Environment]::NewLine

$anchor = '$state = @{'
if (-not $gui.Contains($anchor)) { throw 'State anchor not found in GUI source.' }
$gui = $gui.Replace($anchor, $inject + [Environment]::NewLine + $anchor)

# ---- 5. write the merged script (UTF-8 with BOM: the file contains Chinese text)
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$mergedPath = Join-Path $outDir 'SSDCacheManager-src.ps1'
[IO.File]::WriteAllText($mergedPath, $gui, (New-Object System.Text.UTF8Encoding($true)))

Write-Host ("Merged script written: " + $mergedPath)

# ---- 6. sanity check: the merged script must parse
$err = $null; $tok = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($mergedPath, [ref]$tok, [ref]$err)
if ($err -and $err.Count -gt 0) {
    foreach ($e in ($err | Select-Object -First 5)) {
        Write-Host ("  parse error L" + $e.Extent.StartLineNumber + ": " + $e.Message)
    }
    throw 'Merged script has syntax errors.'
}
Write-Host 'Merged script parses cleanly.'

# ---- 7. compile with ps2exe
Import-Module ps2exe -Force -ErrorAction Stop

$exePath = Join-Path $outDir 'SSDCacheManager.exe'
if (Test-Path -LiteralPath $exePath) {
    # Remove-Item 会被部分环境的 endpoint protection 静默拦截（不抛异常但
    # 文件仍在），所以每一步之后都要验证，最终仍存在则换名输出。
    try { Remove-Item -LiteralPath $exePath -Force -ErrorAction SilentlyContinue } catch { }
    if (Test-Path -LiteralPath $exePath) {
        try { [IO.File]::Delete($exePath) } catch { }
    }
    if (Test-Path -LiteralPath $exePath) {
        $exePath = Join-Path $outDir ('SSDCacheManager-{0:yyyyMMdd-HHmmss}.exe' -f (Get-Date))
        Write-Host ("目标文件被占用，改输出到: " + $exePath)
    }
}

$params = @{
    inputFile    = $mergedPath
    outputFile   = $exePath
    noConsole    = $true
    requireAdmin = $true
    title        = 'SSD Cache Manager'
    description  = 'Directory-level SSD acceleration via NTFS junctions'
    product      = 'SSD Cache Manager'
    copyright    = 'Internal tool'
    version      = '1.1.0.0'
}
Invoke-ps2exe @params

if (-not (Test-Path -LiteralPath $exePath)) { throw 'ps2exe did not produce the exe.' }
Write-Host ''
Write-Host ("DONE: " + $exePath + "  (" + [math]::Round((Get-Item $exePath).Length / 1KB, 1) + " KB)")
Write-Host 'Double-click to run; UAC prompt appears once because the exe requires admin.'