<#
    SSDCacheGUI.ps1 - 目录级 SSD 加速管理器（图形界面）

    启动方式：
      双击 Start-SSDCacheManager.cmd（自动提权），或：
      powershell -ExecutionPolicy Bypass -File .\SSDCacheGUI.ps1

    界面布局：
      左侧：驱动器 / 目录树（复选框多选，懒加载）
      右侧：当前缓存清单（已创建的联接点）
      底部：操作日志

    权限要求：
      创建 NTFS 联接点需要管理员权限，启动时会检查。

    编码说明：
      本文件包含中文字符串，必须以 UTF-8 带 BOM 的形式保存。
      Windows PowerShell 5.1 在无 BOM 时会按系统 ANSI 代码页解析脚本，
      导致中文乱码甚至引号配对错误。
#>

[CmdletBinding()]
param(
    [string]$CacheRoot = 'E:\SSDCache'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 执行策略会阻止导入模块，此处仅对当前进程放行。
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop } catch { }

# 核心库源文本：独立 runspace 的 worker 无法访问主脚本已导入的函数，
# 需要把库源文本拼进 worker 脚本执行。
# - 命令行运行：从同目录 SSDCacheLib.psm1 读取
# - exe 版：构建脚本把库源内嵌为字面量（LibSource 非空，此处跳过读取）
$script:LibSource = ''

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- 全局异常处理 ----
# 注意：SetUnhandledExceptionMode 必须在创建任何控件之前调用，
# 否则抛出"只要在线程上创建了任何控件，则线程异常模式将不能再有任何更改"。
# 没有这套处理，事件处理器里的未捕获异常会弹 JIT 调试对话框，崩溃原因不可见。
function Write-CrashLog {
    param([string]$Where, [Exception]$Ex)
    try {
        $file = Join-Path $env:TEMP 'SSDCacheManager_crash.log'
        $line = "[{0}] {1}: {2}`n{3}`n{4}`n{5}" -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Where, `
            $Ex.Message, $Ex.GetType().FullName, $Ex.StackTrace, ('-' * 70)
        [IO.File]::AppendAllText($file, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    } catch { }
}

[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-CrashLog -Where 'UI线程' -Ex $e.Exception
    try {
        if ($null -ne $script:LogBox) {
            Write-Log ("界面异常：{0}（详情见 %TEMP%\SSDCacheManager_crash.log）" -f $e.Exception.Message) '错误'
        }
    } catch { }
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($s, $e)
    $ex = $null
    try { $ex = $e.ExceptionObject -as [Exception] } catch { }
    if ($ex) { Write-CrashLog -Where 'AppDomain' -Ex $ex }
})

<#
    SSDCacheLib.psm1 - Core module for directory-level SSD acceleration via NTFS junctions.

    DESIGN NOTE
      A junction is an NTFS reparse point resolved in user mode, so it is NOT
      blocked by HVCI / VBS. Cache tools that hook the kernel (PrimoCache,
      StarWind L2, O&O CleverCache, Storage Spaces cache) cannot load when
      HVCI=1. This module therefore uses junctions only.

    ORDERING RULES THAT MUST NOT BE BROKEN
      Promote: robocopy /MOVE empties the source, leaving a bare folder.
               Remove that empty shell BEFORE creating the junction,
               otherwise New-Item -ItemType Junction fails.
      Demote : Remove the junction FIRST, then write data back.
               Writing while the junction is in place creates a loop and
               leaves the HDD empty. This was a real defect in v1.0, found
               during an on-machine trial.

    ASCII ONLY
      Windows PowerShell 5.1 decodes .ps1 as ANSI when there is no BOM, which
      corrupts non-ASCII literals and breaks quote pairing. Keep this file
      pure ASCII; all user-facing strings are English for that reason.
#>

Set-StrictMode -Version Latest

$script:MarkerName = '.ssdcache_root'
$script:LogRelPath = 'ssdcache.log'

#region private helpers

function Get-MarkerName { return $script:MarkerName }

function Get-DriveRoots {
    <# Returns usable local fixed drives (e.g. F:), excluding removable media. #>
    $out = @()
    try {
        $drives = [IO.DriveInfo]::GetDrives()
    } catch {
        return $out
    }
    foreach ($d in $drives) {
        try {
            if ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) {
                $out += $d.Name   # e.g. "F:\"
            }
        } catch { }
    }
    return $out
}

function Get-DirSize {
    <# Total bytes of all files under a path. Returns [int64]0 on any problem. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return [int64]0 }
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return [int64]0 }

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }

    try {
        $files = Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Force -ErrorAction SilentlyContinue
    } catch {
        return [int64]0
    }
    if ($null -eq $files) { return [int64]0 }

    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Get-FreeBytes {
    param([Parameter(Mandatory)][string]$DriveLetter)
    try {
        $v = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        return [int64]$v.SizeRemaining
    } catch {
        $d = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
        if ($d) { return [int64]$d.Free }
        return [int64]0
    }
}

function Test-Junction {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $false }
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $false }
    try {
        $i = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        return (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Get-JunctionTarget {
    <#
      Reads a junction target. Get-Item.Target works on Windows PowerShell 5.1;
      DirectoryInfo.ResolveLinkTarget does NOT exist before PowerShell 6, so it
      must not be used here or every call raises a terminating error on 5.1.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    try {
        $i = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($null -ne $i.PSObject.Properties['Target'] -and $i.Target) {
            return @($i.Target)[0]
        }
    } catch { }
    return $null
}

function Get-ChildDirectories {
    <# Lists immediate subdirectories, never following junctions (avoids loops). #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $out = @()
    try {
        $items = Get-ChildItem -LiteralPath $LiteralPath -Directory -Force -ErrorAction SilentlyContinue
    } catch {
        return $out
    }
    foreach ($i in @($items)) {
        $out += [pscustomobject]@{
            Name      = $i.Name
            Path      = $i.FullName
            IsJunction = (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            Target    = $(if ((($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Get-JunctionTarget -LiteralPath $i.FullName } else { $null })
        }
    }
    return $out
}

function ConvertTo-SafeTargetPath {
    <#
      Normalises and validates a user-supplied path.
      Refuses: empty, missing, whole-volume roots, and anything on C:.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { throw 'Path is empty.' }

    try { $full = [IO.Path]::GetFullPath($LiteralPath) }
    catch { throw ("Invalid path: {0}" -f $LiteralPath) }

    if (-not (Test-Path -LiteralPath $full)) { throw ("Path not found: {0}" -f $full) }

    if ($full -like 'C:\*') { throw ("Refusing to operate on the system drive C: -> {0}" -f $full) }

    $norm = $full.TrimEnd('\')
    try { $driveRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\') } catch { $driveRoot = '' }
    if ($norm -eq $driveRoot) {
        throw ("Refusing to operate on a volume root: {0}. Select a subfolder." -f $full)
    }

    return $full
}

function New-MarkerFile {
    param([string]$CachePath, [string]$OriginalPath)
    $meta = [ordered]@{
        OriginalPath = $OriginalPath
        CreatedAt    = (Get-Date).ToString('o')
        Tool         = 'SSDCacheManager'
        Version      = '1.1'
    }
    ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $CachePath $script:MarkerName) -Encoding UTF8
}

function Remove-CacheFolderSafe {
    <#
      Removes a cache folder after the data has been written back.

      Remove-Item -Recurse is unreliable here: endpoint protection software may
      veto or "abort" the delete, and on this class of machine that error
      escapes as a non-terminating error that callers cannot suppress cleanly.
      robocopy mirroring an empty folder into the target empties it without
      invoking the blocked delete path, then the shell itself is removed.

      Returns $true when the folder is gone.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }

    $nullDir = [IO.Path]::Combine($env:TEMP, ('ssdcache_empty_{0}' -f ([guid]::NewGuid().ToString('N'))))
    try {
        New-Item -ItemType Directory -Path $nullDir -Force -ErrorAction Stop | Out-Null
        $null = & robocopy $nullDir $LiteralPath /MIR /R:1 /W:1 /XJ /NP /NFL /NDL 2>&1
    } catch {
        # Fall through; the shell removal below may still succeed.
    } finally {
        try { if (Test-Path -LiteralPath $nullDir) { Remove-Item -LiteralPath $nullDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }

    # Remove the (now empty) shell.
    try {
        [System.IO.Directory]::Delete($LiteralPath, $false)
    } catch {
        try { Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue } catch { }
    }

    return (-not (Test-Path -LiteralPath $LiteralPath))
}

function Remove-EmptyParents {
    <#
      Prunes empty folders inside the cache root, stopping at the root itself
      or at the first non-empty folder. Prevents leftover shells like
      E:\SSDCache\F after a full demote.
    #>
    param(
        [Parameter(Mandatory)][string]$StartDir,
        [Parameter(Mandatory)][string]$Root
    )

    $removed = @()
    if ([string]::IsNullOrWhiteSpace($Root)) { return $removed }

    $rootNorm = $Root.TrimEnd('\')
    $node = $StartDir

    while ($node) {
        $norm = $node.TrimEnd('\')
        if ($norm.Length -le $rootNorm.Length) { break }
        if (-not $norm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { break }
        if (-not (Test-Path -LiteralPath $norm)) { $node = Split-Path -Parent $norm; continue }

        $kids = @(Get-ChildItem -LiteralPath $norm -Force -ErrorAction SilentlyContinue)
        if ($kids.Count -ne 0) { break }

        # Empty-folder pruning is cosmetic. Use the .NET API so that endpoint
        # protection wrapping Remove-Item cannot veto it and abort the demote.
        try {
            [System.IO.Directory]::Delete($norm, $false)
        } catch {
            break
        }
        if (Test-Path -LiteralPath $norm) { break }
        $removed += $norm
        $node = Split-Path -Parent $norm
    }
    return $removed
}

function Invoke-RoboMove {
    <#
      Moves a directory tree with robocopy.
      Returns an object with Success, Code and LogPath.

      ExcludeList is deliberately NOT implemented via /XF. Excluding files
      with /XF while /MOVE is active makes robocopy abort with code 16 and
      leaves the source half-copied. Callers must delete unwanted bookkeeping
      files from the source first, then call this without exclusions.
    #>
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string]$LogPath
    )

    $args = @(
        $From, $To,
        '/E', '/MOVE', '/COPY:DAT', '/DCOPY:T',
        '/MT:8', '/R:2', '/W:2', '/XJ', '/NP', '/NFL', '/NDL'
    )
    if ($LogPath) { $args += ("/LOG+:{0}" -f $LogPath) }

    try {
        $null = & robocopy @args 2>&1
    } catch {
        return [pscustomobject]@{ Success = $false; Code = -1; LogPath = $LogPath; Error = $_.Exception.Message }
    }
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        Success = ($code -lt 8)
        Code    = $code
        LogPath = $LogPath
        Error   = $null
    }
}

function Get-CachePathFor {
    <# Maps F:\a\b to <root>\F\a\b, so different drives never collide. #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Root
    )
    $qual = (Split-Path -Qualifier $SourcePath).TrimEnd(':')
    if ($SourcePath.Length -le 3) { return (Join-Path (Join-Path $Root $qual) '_root') }
    $rel = $SourcePath.Substring(3).TrimStart('\')
    return (Join-Path (Join-Path $Root $qual) $rel)
}

#endregion

#region public API

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-JunctionInventory {
    <#
      Scans the given roots and returns one record per managed junction:
        Path, Target, SizeBytes, IsValid, Status

      Scope note: results are collected in a List[object] because the
      recursive helper writes from a CHILD scope. "$results += ..." inside
      Scan-Level would silently create a local variable and the parent would
      always return an empty array, no matter how many junctions exist.
    #>
    param(
        [string[]]$Roots,
        [int]$MaxDepth = 5
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Roots -or @($Roots).Count -eq 0) { return @($results) }

    function Scan-Level {
        param([string]$Dir, [int]$Depth)

        if ($Depth -gt $MaxDepth) { return }

        # Skip recycle bins and volume metadata: junctions found there are
        # deleted leftovers pointing at removed cache roots, they are noise.
        $name = [IO.Path]::GetFileName($Dir.TrimEnd('\'))
        if ($name -eq '$RECYCLE.BIN' -or $name -eq 'System Volume Information') { return }

        # NOTE: deliberately uses raw Get-ChildItem instead of
        # Get-ChildDirectories. During debugging the wrapper returned an empty
        # list when called from this nested scope, while the identical raw call
        # returned the full directory list (13 vs 0 on the same volume in the
        # same session). Root cause not fully identified, so the scan keeps to
        # the primitive that is proven to work here.
        $items = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($i in $items) {
            $isJ = (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isJ) {
                $t = $null
                try { $t = Get-JunctionTarget -LiteralPath $i.FullName } catch { $t = $null }
                if ([string]::IsNullOrEmpty($t)) {
                    # Windows system junctions (Documents and Settings, All
                    # Users, ...) expose an empty Target. They are managed by
                    # the OS, never by this tool; report them as System.
                    $results.Add([pscustomobject]@{
                        Path      = $i.FullName
                        Target    = $t
                        SizeBytes = [int64]0
                        FileCount = 0
                        IsValid   = $true
                        Status    = 'System'
                    })
                } else {
                    $valid = ($t -and (Test-Path -LiteralPath $t))
                    $results.Add([pscustomobject]@{
                        Path      = $i.FullName
                        Target    = $t
                        SizeBytes = $(if ($valid) { Get-DirSize -LiteralPath $t } else { [int64]0 })
                        FileCount = $(if ($valid) { @(Get-ChildItem -LiteralPath $t -Recurse -File -Force -ErrorAction SilentlyContinue).Count } else { 0 })
                        IsValid   = $valid
                        Status    = $(if ($valid) { 'Cached' } else { 'TargetMissing' })
                    })
                }
            } else {
                Scan-Level -Dir $i.FullName -Depth ($Depth + 1)
            }
        }
    }

    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r) { Scan-Level -Dir $r -Depth 1 }
    }
    # ToArray, not @(): enumerating the List through @() at this boundary was
    # observed to yield an empty array in one test, while ToArray() always
    # carried the full content.
    return $results.ToArray()
}

function Get-CacheStatus {
    <# Summary of one path: whether cached, and where. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    $isJ = Test-Junction -LiteralPath $LiteralPath
    $t = $null
    if ($isJ) { $t = Get-JunctionTarget -LiteralPath $LiteralPath }

    return [pscustomobject]@{
        Path       = $LiteralPath
        IsJunction = $isJ
        Target     = $t
        SizeBytes  = $(if ($isJ -and $t -and (Test-Path -LiteralPath $t)) { Get-DirSize -LiteralPath $t } elseif (-not $isJ) { Get-DirSize -LiteralPath $LiteralPath } else { [int64]0 })
        TargetOk   = $(if ($isJ) { [bool]($t -and (Test-Path -LiteralPath $t)) } else { $true })
    }
}

function Invoke-CachePromote {
    <#
      Moves data to SSD and leaves a junction at the original path.
      All-or-nothing: on any failure the original location is restored.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$CacheRoot
    )

    $src = ConvertTo-SafeTargetPath -LiteralPath $SourcePath

    if (Test-Junction -LiteralPath $src) {
        # All early-exit branches carry the same fields as the normal return,
        # so callers can read e.g. SizeBytes / CacheCleanupError without
        # tripping Set-StrictMode on a missing property.
        return [pscustomobject]@{ Success = $true; AlreadyCached = $true; Path = $src; Target = (Get-JunctionTarget -LiteralPath $src); SizeBytes = [int64]0; Message = 'Already a junction.' }
    }

    $cachePath = Get-CachePathFor -SourcePath $src -Root $CacheRoot
    if (Test-Path -LiteralPath $cachePath) {
        throw ("Cache target already exists. Demote or remove it first: {0}" -f $cachePath)
    }

    $size = Get-DirSize -LiteralPath $src
    $cacheDrive = ([IO.Path]::GetPathRoot($CacheRoot)).TrimEnd('\').TrimEnd(':')
    $free = Get-FreeBytes -DriveLetter $cacheDrive

    if ($size -gt 0 -and $size -gt ($free * 0.9)) {
        throw ("Not enough space on the cache drive. Need {0} GB, have {1} GB." -f ([math]::Round($size / 1GB, 2)), ([math]::Round($free / 1GB, 2)))
    }

    $parent = Split-Path -Parent $cachePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $logPath = Join-Path $CacheRoot $script:LogRelPath
    $mv = Invoke-RoboMove -From $src -To $cachePath -LogPath $logPath

    if (-not $mv.Success) {
        throw ("Data migration failed (robocopy code {0}). Source unchanged. See {1}" -f $mv.Code, $logPath)
    }

    New-MarkerFile -CachePath $cachePath -OriginalPath $src

    # robocopy /MOVE leaves an empty shell behind; remove it before mklink.
    if (Test-Path -LiteralPath $src) {
        $left = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $src -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    try {
        New-Item -ItemType Junction -Path $src -Value $cachePath -ErrorAction Stop | Out-Null
    } catch {
        # roll data back to the original location
        $rb = Invoke-RoboMove -From $cachePath -To $src -LogPath $logPath
        if ($rb.Success) {
            Remove-Item -LiteralPath $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw ("Could not create the junction; data was rolled back to {0}. Underlying error: {1}" -f $src, $_.Exception.Message)
    }

    if (-not (Test-Junction -LiteralPath $src)) {
        throw ("Junction verification failed at {0}." -f $src)
    }

    return [pscustomobject]@{
        Success = $true
        AlreadyCached = $false
        Path = $src
        Target = $cachePath
        SizeBytes = $size
        Message = ('Promoted. {0} GB now served from {1}.' -f [math]::Round($size / 1GB, 3), $cacheDrive)
    }
}

function Invoke-CacheDemote {
    <#
      Writes data back to the HDD and removes the junction.
      Order matters: junction removed first, data second.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$CacheRoot
    )

    $src = ConvertTo-SafeTargetPath -LiteralPath $SourcePath

    if (-not (Test-Junction -LiteralPath $src)) {
        return [pscustomobject]@{ Success = $true; WasCached = $false; Path = $src; SizeBytes = [int64]0; CacheRemoved = $false; CacheCleanupError = $null; PrunedFolders = @(); Message = 'Not a junction; nothing to do.' }
    }

    $cachePath = Get-JunctionTarget -LiteralPath $src
    if (-not $cachePath -or -not (Test-Path -LiteralPath $cachePath)) {
        throw ("Junction target is missing; inspect manually: {0}" -f $src)
    }

    $size = Get-DirSize -LiteralPath $cachePath
    $homeDrive = ([IO.Path]::GetPathRoot($src)).TrimEnd('\').TrimEnd(':')
    $free = Get-FreeBytes -DriveLetter $homeDrive
    if ($size -gt 0 -and $size -gt ($free * 0.9)) {
        throw ("Not enough space on {0}. Need {1} GB, have {2} GB." -f $homeDrive, [math]::Round($size / 1GB, 2), [math]::Round($free / 1GB, 2))
    }

    # Read the marker BEFORE moving it, so ownership can still be verified later.
    $marker = Join-Path $cachePath $script:MarkerName
    $meta = $null
    if (Test-Path -LiteralPath $marker) {
        try { $meta = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { $meta = $null }
    }

    # 1) Remove the junction. Writing through it would loop back into the cache.
    [System.IO.Directory]::Delete($src, $false)
    if (Test-Junction -LiteralPath $src) {
        throw ("Failed to remove the junction at {0}. Aborting to protect data." -f $src)
    }

    # 2) Relocate our bookkeeping file out of the cache folder before the move.
    #    Two constraints force this design:
    #      - /XF exclusion under /MOVE makes robocopy abort with code 16
    #      - Remove-Item on the marker may be blocked by security software
    #    Moving it to a scratch folder avoids both problems.
    $markerParked = $null
    if (Test-Path -LiteralPath $marker) {
        $scratch = $null
        foreach ($candidate in @($CacheRoot, $env:TEMP, $env:TMP)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $scratch = $candidate
                break
            }
        }
        if ($scratch) {
            $markerParked = Join-Path $scratch ("ssdcache_marker_{0}.json" -f ([guid]::NewGuid().ToString('N')))
            try {
                Move-Item -LiteralPath $marker -Destination $markerParked -Force -ErrorAction Stop
            } catch {
                Write-Warning ("Could not relocate the marker file; it will be skipped during the move. Path: {0}" -f $_.Exception.Message)
                $markerParked = $null
            }
        }
    }

    # 3) Write data back.
    $logPath = $null
    if ($CacheRoot) { $logPath = Join-Path $CacheRoot $script:LogRelPath }
    $mv = Invoke-RoboMove -From $cachePath -To $src -LogPath $logPath
    if (-not $mv.Success) {
        $rebuild = ("New-Item -ItemType Junction -Path '{0}' -Value '{1}'" -f $src, $cachePath)
        throw ("Write-back failed (robocopy code {0}). Data is safe in the cache at {1}. To restore access run: {2}" -f $mv.Code, $cachePath, $rebuild)
    }

    # 4) Safety net: never leave our marker in the user's folder.
    $leaked = Join-Path $src $script:MarkerName
    if (Test-Path -LiteralPath $leaked) {
        try { Remove-Item -LiteralPath $leaked -Force -ErrorAction SilentlyContinue } catch { }
    }

    # 5) Verify before deleting the cache copy. After a successful /MOVE the
    #    cache tree may already be gone, so probe existence before enumerating.
    $srcFiles = 0
    if (Test-Path -LiteralPath $src) {
        $srcFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    $cacheExists = Test-Path -LiteralPath $cachePath
    $cacheFiles = 0
    if ($cacheExists) {
        $cacheFiles = @(Get-ChildItem -LiteralPath $cachePath -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    if ($cacheFiles -gt 0 -and $srcFiles -eq 0) {
        throw ("Verification failed: HDD copy is empty while the cache still holds {0} file(s). Cache kept at {1}" -f $cacheFiles, $cachePath)
    }

    # 6) Delete the cache folder only if the marker confirms ownership.
    #    Security software can veto Remove-Item here; that must NOT fail the
    #    operation because the data is already safely back on the HDD. The
    #    leftover folder is reported so the GUI can surface it.
    $removedCache = $false
    $cacheCleanupError = $null
    if ($null -ne $meta -and $meta.OriginalPath -eq $src) {
        $removedCache = Remove-CacheFolderSafe -LiteralPath $cachePath
        if (-not $removedCache) { $cacheCleanupError = 'The cache folder is empty but could not be removed.' }
    }

    # 7) Prune empty folders left inside the cache root.
    $pruned = @()
    if ($CacheRoot) { $pruned = Remove-EmptyParents -StartDir (Split-Path -Parent $cachePath) -Root $CacheRoot }

    $msg = ('Demoted. {0} GB restored to {1}.' -f [math]::Round($size / 1GB, 3), $homeDrive)
    if ($cacheCleanupError) {
        Write-Warning ("Data was restored successfully, but the cache folder could not be deleted: {0}" -f $cacheCleanupError)
        $msg += " Data is safe on the HDD; the empty cache folder can be removed manually."
    }

    return [pscustomobject]@{
        Success = $true
        WasCached = $true
        Path = $src
        SizeBytes = $size
        CacheRemoved = $removedCache
        CacheCleanupError = $cacheCleanupError
        PrunedFolders = $pruned
        Message = $msg
    }
}

function Get-DriveSpaceInfo {
    <# Free / total bytes per fixed drive, for the GUI status bar. #>
    $out = @()
    foreach ($root in (Get-DriveRoots)) {
        $letter = $root.TrimEnd('\').TrimEnd(':')
        $free = Get-FreeBytes -DriveLetter $letter
        $total = [int64]0
        try {
            $d = [IO.DriveInfo]::new($root)
            $total = [int64]$d.TotalSize
        } catch { }
        $out += [pscustomobject]@{
            Drive     = $letter
            Root      = $root
            FreeBytes = $free
            TotalBytes = $total
            IsNTFS    = $(try { [IO.DriveInfo]::new($root).DriveFormat -eq 'NTFS' } catch { $false })
        }
    }
    return $out
}

$script:LibSource = @'
<#
    SSDCacheLib.psm1 - Core module for directory-level SSD acceleration via NTFS junctions.

    DESIGN NOTE
      A junction is an NTFS reparse point resolved in user mode, so it is NOT
      blocked by HVCI / VBS. Cache tools that hook the kernel (PrimoCache,
      StarWind L2, O&O CleverCache, Storage Spaces cache) cannot load when
      HVCI=1. This module therefore uses junctions only.

    ORDERING RULES THAT MUST NOT BE BROKEN
      Promote: robocopy /MOVE empties the source, leaving a bare folder.
               Remove that empty shell BEFORE creating the junction,
               otherwise New-Item -ItemType Junction fails.
      Demote : Remove the junction FIRST, then write data back.
               Writing while the junction is in place creates a loop and
               leaves the HDD empty. This was a real defect in v1.0, found
               during an on-machine trial.

    ASCII ONLY
      Windows PowerShell 5.1 decodes .ps1 as ANSI when there is no BOM, which
      corrupts non-ASCII literals and breaks quote pairing. Keep this file
      pure ASCII; all user-facing strings are English for that reason.
#>

Set-StrictMode -Version Latest

$script:MarkerName = '.ssdcache_root'
$script:LogRelPath = 'ssdcache.log'

#region private helpers

function Get-MarkerName { return $script:MarkerName }

function Get-DriveRoots {
    <# Returns usable local fixed drives (e.g. F:), excluding removable media. #>
    $out = @()
    try {
        $drives = [IO.DriveInfo]::GetDrives()
    } catch {
        return $out
    }
    foreach ($d in $drives) {
        try {
            if ($d.DriveType -eq [IO.DriveType]::Fixed -and $d.IsReady) {
                $out += $d.Name   # e.g. "F:\"
            }
        } catch { }
    }
    return $out
}

function Get-DirSize {
    <# Total bytes of all files under a path. Returns [int64]0 on any problem. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return [int64]0 }
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return [int64]0 }

    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return [int64]0 }
    if (-not $item.PSIsContainer) { return [int64]$item.Length }

    try {
        $files = Get-ChildItem -LiteralPath $LiteralPath -Recurse -File -Force -ErrorAction SilentlyContinue
    } catch {
        return [int64]0
    }
    if ($null -eq $files) { return [int64]0 }

    $sum = ($files | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [int64]0 }
    return [int64]$sum
}

function Get-FreeBytes {
    param([Parameter(Mandatory)][string]$DriveLetter)
    try {
        $v = Get-Volume -DriveLetter $DriveLetter -ErrorAction Stop
        return [int64]$v.SizeRemaining
    } catch {
        $d = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
        if ($d) { return [int64]$d.Free }
        return [int64]0
    }
}

function Test-Junction {
    param([Parameter(Mandatory)][string]$LiteralPath)
    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { return $false }
    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $false }
    try {
        $i = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        return (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    } catch {
        return $false
    }
}

function Get-JunctionTarget {
    <#
      Reads a junction target. Get-Item.Target works on Windows PowerShell 5.1;
      DirectoryInfo.ResolveLinkTarget does NOT exist before PowerShell 6, so it
      must not be used here or every call raises a terminating error on 5.1.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    try {
        $i = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
        if ($null -ne $i.PSObject.Properties['Target'] -and $i.Target) {
            return @($i.Target)[0]
        }
    } catch { }
    return $null
}

function Get-ChildDirectories {
    <# Lists immediate subdirectories, never following junctions (avoids loops). #>
    param([Parameter(Mandatory)][string]$LiteralPath)
    $out = @()
    try {
        $items = Get-ChildItem -LiteralPath $LiteralPath -Directory -Force -ErrorAction SilentlyContinue
    } catch {
        return $out
    }
    foreach ($i in @($items)) {
        $out += [pscustomobject]@{
            Name      = $i.Name
            Path      = $i.FullName
            IsJunction = (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            Target    = $(if ((($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { Get-JunctionTarget -LiteralPath $i.FullName } else { $null })
        }
    }
    return $out
}

function ConvertTo-SafeTargetPath {
    <#
      Normalises and validates a user-supplied path.
      Refuses: empty, missing, whole-volume roots, and anything on C:.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if ([string]::IsNullOrWhiteSpace($LiteralPath)) { throw 'Path is empty.' }

    try { $full = [IO.Path]::GetFullPath($LiteralPath) }
    catch { throw ("Invalid path: {0}" -f $LiteralPath) }

    if (-not (Test-Path -LiteralPath $full)) { throw ("Path not found: {0}" -f $full) }

    if ($full -like 'C:\*') { throw ("Refusing to operate on the system drive C: -> {0}" -f $full) }

    $norm = $full.TrimEnd('\')
    try { $driveRoot = [IO.Path]::GetPathRoot($full).TrimEnd('\') } catch { $driveRoot = '' }
    if ($norm -eq $driveRoot) {
        throw ("Refusing to operate on a volume root: {0}. Select a subfolder." -f $full)
    }

    return $full
}

function New-MarkerFile {
    param([string]$CachePath, [string]$OriginalPath)
    $meta = [ordered]@{
        OriginalPath = $OriginalPath
        CreatedAt    = (Get-Date).ToString('o')
        Tool         = 'SSDCacheManager'
        Version      = '1.1'
    }
    ($meta | ConvertTo-Json) | Set-Content -LiteralPath (Join-Path $CachePath $script:MarkerName) -Encoding UTF8
}

function Remove-CacheFolderSafe {
    <#
      Removes a cache folder after the data has been written back.

      Remove-Item -Recurse is unreliable here: endpoint protection software may
      veto or "abort" the delete, and on this class of machine that error
      escapes as a non-terminating error that callers cannot suppress cleanly.
      robocopy mirroring an empty folder into the target empties it without
      invoking the blocked delete path, then the shell itself is removed.

      Returns $true when the folder is gone.
    #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    if (-not (Test-Path -LiteralPath $LiteralPath)) { return $true }

    $nullDir = [IO.Path]::Combine($env:TEMP, ('ssdcache_empty_{0}' -f ([guid]::NewGuid().ToString('N'))))
    try {
        New-Item -ItemType Directory -Path $nullDir -Force -ErrorAction Stop | Out-Null
        $null = & robocopy $nullDir $LiteralPath /MIR /R:1 /W:1 /XJ /NP /NFL /NDL 2>&1
    } catch {
        # Fall through; the shell removal below may still succeed.
    } finally {
        try { if (Test-Path -LiteralPath $nullDir) { Remove-Item -LiteralPath $nullDir -Recurse -Force -ErrorAction SilentlyContinue } } catch { }
    }

    # Remove the (now empty) shell.
    try {
        [System.IO.Directory]::Delete($LiteralPath, $false)
    } catch {
        try { Remove-Item -LiteralPath $LiteralPath -Force -ErrorAction SilentlyContinue } catch { }
    }

    return (-not (Test-Path -LiteralPath $LiteralPath))
}

function Remove-EmptyParents {
    <#
      Prunes empty folders inside the cache root, stopping at the root itself
      or at the first non-empty folder. Prevents leftover shells like
      E:\SSDCache\F after a full demote.
    #>
    param(
        [Parameter(Mandatory)][string]$StartDir,
        [Parameter(Mandatory)][string]$Root
    )

    $removed = @()
    if ([string]::IsNullOrWhiteSpace($Root)) { return $removed }

    $rootNorm = $Root.TrimEnd('\')
    $node = $StartDir

    while ($node) {
        $norm = $node.TrimEnd('\')
        if ($norm.Length -le $rootNorm.Length) { break }
        if (-not $norm.StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { break }
        if (-not (Test-Path -LiteralPath $norm)) { $node = Split-Path -Parent $norm; continue }

        $kids = @(Get-ChildItem -LiteralPath $norm -Force -ErrorAction SilentlyContinue)
        if ($kids.Count -ne 0) { break }

        # Empty-folder pruning is cosmetic. Use the .NET API so that endpoint
        # protection wrapping Remove-Item cannot veto it and abort the demote.
        try {
            [System.IO.Directory]::Delete($norm, $false)
        } catch {
            break
        }
        if (Test-Path -LiteralPath $norm) { break }
        $removed += $norm
        $node = Split-Path -Parent $norm
    }
    return $removed
}

function Invoke-RoboMove {
    <#
      Moves a directory tree with robocopy.
      Returns an object with Success, Code and LogPath.

      ExcludeList is deliberately NOT implemented via /XF. Excluding files
      with /XF while /MOVE is active makes robocopy abort with code 16 and
      leaves the source half-copied. Callers must delete unwanted bookkeeping
      files from the source first, then call this without exclusions.
    #>
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [string]$LogPath
    )

    $args = @(
        $From, $To,
        '/E', '/MOVE', '/COPY:DAT', '/DCOPY:T',
        '/MT:8', '/R:2', '/W:2', '/XJ', '/NP', '/NFL', '/NDL'
    )
    if ($LogPath) { $args += ("/LOG+:{0}" -f $LogPath) }

    try {
        $null = & robocopy @args 2>&1
    } catch {
        return [pscustomobject]@{ Success = $false; Code = -1; LogPath = $LogPath; Error = $_.Exception.Message }
    }
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        Success = ($code -lt 8)
        Code    = $code
        LogPath = $LogPath
        Error   = $null
    }
}

function Get-CachePathFor {
    <# Maps F:\a\b to <root>\F\a\b, so different drives never collide. #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$Root
    )
    $qual = (Split-Path -Qualifier $SourcePath).TrimEnd(':')
    if ($SourcePath.Length -le 3) { return (Join-Path (Join-Path $Root $qual) '_root') }
    $rel = $SourcePath.Substring(3).TrimStart('\')
    return (Join-Path (Join-Path $Root $qual) $rel)
}

#endregion

#region public API

function Test-Administrator {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-JunctionInventory {
    <#
      Scans the given roots and returns one record per managed junction:
        Path, Target, SizeBytes, IsValid, Status

      Scope note: results are collected in a List[object] because the
      recursive helper writes from a CHILD scope. "$results += ..." inside
      Scan-Level would silently create a local variable and the parent would
      always return an empty array, no matter how many junctions exist.
    #>
    param(
        [string[]]$Roots,
        [int]$MaxDepth = 5
    )

    $results = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Roots -or @($Roots).Count -eq 0) { return @($results) }

    function Scan-Level {
        param([string]$Dir, [int]$Depth)

        if ($Depth -gt $MaxDepth) { return }

        # Skip recycle bins and volume metadata: junctions found there are
        # deleted leftovers pointing at removed cache roots, they are noise.
        $name = [IO.Path]::GetFileName($Dir.TrimEnd('\'))
        if ($name -eq '$RECYCLE.BIN' -or $name -eq 'System Volume Information') { return }

        # NOTE: deliberately uses raw Get-ChildItem instead of
        # Get-ChildDirectories. During debugging the wrapper returned an empty
        # list when called from this nested scope, while the identical raw call
        # returned the full directory list (13 vs 0 on the same volume in the
        # same session). Root cause not fully identified, so the scan keeps to
        # the primitive that is proven to work here.
        $items = @(Get-ChildItem -LiteralPath $Dir -Directory -Force -ErrorAction SilentlyContinue)
        foreach ($i in $items) {
            $isJ = (($i.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isJ) {
                $t = $null
                try { $t = Get-JunctionTarget -LiteralPath $i.FullName } catch { $t = $null }
                if ([string]::IsNullOrEmpty($t)) {
                    # Windows system junctions (Documents and Settings, All
                    # Users, ...) expose an empty Target. They are managed by
                    # the OS, never by this tool; report them as System.
                    $results.Add([pscustomobject]@{
                        Path      = $i.FullName
                        Target    = $t
                        SizeBytes = [int64]0
                        FileCount = 0
                        IsValid   = $true
                        Status    = 'System'
                    })
                } else {
                    $valid = ($t -and (Test-Path -LiteralPath $t))
                    $results.Add([pscustomobject]@{
                        Path      = $i.FullName
                        Target    = $t
                        SizeBytes = $(if ($valid) { Get-DirSize -LiteralPath $t } else { [int64]0 })
                        FileCount = $(if ($valid) { @(Get-ChildItem -LiteralPath $t -Recurse -File -Force -ErrorAction SilentlyContinue).Count } else { 0 })
                        IsValid   = $valid
                        Status    = $(if ($valid) { 'Cached' } else { 'TargetMissing' })
                    })
                }
            } else {
                Scan-Level -Dir $i.FullName -Depth ($Depth + 1)
            }
        }
    }

    foreach ($r in $Roots) {
        if (Test-Path -LiteralPath $r) { Scan-Level -Dir $r -Depth 1 }
    }
    # ToArray, not @(): enumerating the List through @() at this boundary was
    # observed to yield an empty array in one test, while ToArray() always
    # carried the full content.
    return $results.ToArray()
}

function Get-CacheStatus {
    <# Summary of one path: whether cached, and where. #>
    param([Parameter(Mandatory)][string]$LiteralPath)

    $isJ = Test-Junction -LiteralPath $LiteralPath
    $t = $null
    if ($isJ) { $t = Get-JunctionTarget -LiteralPath $LiteralPath }

    return [pscustomobject]@{
        Path       = $LiteralPath
        IsJunction = $isJ
        Target     = $t
        SizeBytes  = $(if ($isJ -and $t -and (Test-Path -LiteralPath $t)) { Get-DirSize -LiteralPath $t } elseif (-not $isJ) { Get-DirSize -LiteralPath $LiteralPath } else { [int64]0 })
        TargetOk   = $(if ($isJ) { [bool]($t -and (Test-Path -LiteralPath $t)) } else { $true })
    }
}

function Invoke-CachePromote {
    <#
      Moves data to SSD and leaves a junction at the original path.
      All-or-nothing: on any failure the original location is restored.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$CacheRoot
    )

    $src = ConvertTo-SafeTargetPath -LiteralPath $SourcePath

    if (Test-Junction -LiteralPath $src) {
        # All early-exit branches carry the same fields as the normal return,
        # so callers can read e.g. SizeBytes / CacheCleanupError without
        # tripping Set-StrictMode on a missing property.
        return [pscustomobject]@{ Success = $true; AlreadyCached = $true; Path = $src; Target = (Get-JunctionTarget -LiteralPath $src); SizeBytes = [int64]0; Message = 'Already a junction.' }
    }

    $cachePath = Get-CachePathFor -SourcePath $src -Root $CacheRoot
    if (Test-Path -LiteralPath $cachePath) {
        throw ("Cache target already exists. Demote or remove it first: {0}" -f $cachePath)
    }

    $size = Get-DirSize -LiteralPath $src
    $cacheDrive = ([IO.Path]::GetPathRoot($CacheRoot)).TrimEnd('\').TrimEnd(':')
    $free = Get-FreeBytes -DriveLetter $cacheDrive

    if ($size -gt 0 -and $size -gt ($free * 0.9)) {
        throw ("Not enough space on the cache drive. Need {0} GB, have {1} GB." -f ([math]::Round($size / 1GB, 2)), ([math]::Round($free / 1GB, 2)))
    }

    $parent = Split-Path -Parent $cachePath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $logPath = Join-Path $CacheRoot $script:LogRelPath
    $mv = Invoke-RoboMove -From $src -To $cachePath -LogPath $logPath

    if (-not $mv.Success) {
        throw ("Data migration failed (robocopy code {0}). Source unchanged. See {1}" -f $mv.Code, $logPath)
    }

    New-MarkerFile -CachePath $cachePath -OriginalPath $src

    # robocopy /MOVE leaves an empty shell behind; remove it before mklink.
    if (Test-Path -LiteralPath $src) {
        $left = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $src -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    try {
        New-Item -ItemType Junction -Path $src -Value $cachePath -ErrorAction Stop | Out-Null
    } catch {
        # roll data back to the original location
        $rb = Invoke-RoboMove -From $cachePath -To $src -LogPath $logPath
        if ($rb.Success) {
            Remove-Item -LiteralPath $cachePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw ("Could not create the junction; data was rolled back to {0}. Underlying error: {1}" -f $src, $_.Exception.Message)
    }

    if (-not (Test-Junction -LiteralPath $src)) {
        throw ("Junction verification failed at {0}." -f $src)
    }

    return [pscustomobject]@{
        Success = $true
        AlreadyCached = $false
        Path = $src
        Target = $cachePath
        SizeBytes = $size
        Message = ('Promoted. {0} GB now served from {1}.' -f [math]::Round($size / 1GB, 3), $cacheDrive)
    }
}

function Invoke-CacheDemote {
    <#
      Writes data back to the HDD and removes the junction.
      Order matters: junction removed first, data second.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$CacheRoot
    )

    $src = ConvertTo-SafeTargetPath -LiteralPath $SourcePath

    if (-not (Test-Junction -LiteralPath $src)) {
        return [pscustomobject]@{ Success = $true; WasCached = $false; Path = $src; SizeBytes = [int64]0; CacheRemoved = $false; CacheCleanupError = $null; PrunedFolders = @(); Message = 'Not a junction; nothing to do.' }
    }

    $cachePath = Get-JunctionTarget -LiteralPath $src
    if (-not $cachePath -or -not (Test-Path -LiteralPath $cachePath)) {
        throw ("Junction target is missing; inspect manually: {0}" -f $src)
    }

    $size = Get-DirSize -LiteralPath $cachePath
    $homeDrive = ([IO.Path]::GetPathRoot($src)).TrimEnd('\').TrimEnd(':')
    $free = Get-FreeBytes -DriveLetter $homeDrive
    if ($size -gt 0 -and $size -gt ($free * 0.9)) {
        throw ("Not enough space on {0}. Need {1} GB, have {2} GB." -f $homeDrive, [math]::Round($size / 1GB, 2), [math]::Round($free / 1GB, 2))
    }

    # Read the marker BEFORE moving it, so ownership can still be verified later.
    $marker = Join-Path $cachePath $script:MarkerName
    $meta = $null
    if (Test-Path -LiteralPath $marker) {
        try { $meta = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { $meta = $null }
    }

    # 1) Remove the junction. Writing through it would loop back into the cache.
    [System.IO.Directory]::Delete($src, $false)
    if (Test-Junction -LiteralPath $src) {
        throw ("Failed to remove the junction at {0}. Aborting to protect data." -f $src)
    }

    # 2) Relocate our bookkeeping file out of the cache folder before the move.
    #    Two constraints force this design:
    #      - /XF exclusion under /MOVE makes robocopy abort with code 16
    #      - Remove-Item on the marker may be blocked by security software
    #    Moving it to a scratch folder avoids both problems.
    $markerParked = $null
    if (Test-Path -LiteralPath $marker) {
        $scratch = $null
        foreach ($candidate in @($CacheRoot, $env:TEMP, $env:TMP)) {
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                $scratch = $candidate
                break
            }
        }
        if ($scratch) {
            $markerParked = Join-Path $scratch ("ssdcache_marker_{0}.json" -f ([guid]::NewGuid().ToString('N')))
            try {
                Move-Item -LiteralPath $marker -Destination $markerParked -Force -ErrorAction Stop
            } catch {
                Write-Warning ("Could not relocate the marker file; it will be skipped during the move. Path: {0}" -f $_.Exception.Message)
                $markerParked = $null
            }
        }
    }

    # 3) Write data back.
    $logPath = $null
    if ($CacheRoot) { $logPath = Join-Path $CacheRoot $script:LogRelPath }
    $mv = Invoke-RoboMove -From $cachePath -To $src -LogPath $logPath
    if (-not $mv.Success) {
        $rebuild = ("New-Item -ItemType Junction -Path '{0}' -Value '{1}'" -f $src, $cachePath)
        throw ("Write-back failed (robocopy code {0}). Data is safe in the cache at {1}. To restore access run: {2}" -f $mv.Code, $cachePath, $rebuild)
    }

    # 4) Safety net: never leave our marker in the user's folder.
    $leaked = Join-Path $src $script:MarkerName
    if (Test-Path -LiteralPath $leaked) {
        try { Remove-Item -LiteralPath $leaked -Force -ErrorAction SilentlyContinue } catch { }
    }

    # 5) Verify before deleting the cache copy. After a successful /MOVE the
    #    cache tree may already be gone, so probe existence before enumerating.
    $srcFiles = 0
    if (Test-Path -LiteralPath $src) {
        $srcFiles = @(Get-ChildItem -LiteralPath $src -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    $cacheExists = Test-Path -LiteralPath $cachePath
    $cacheFiles = 0
    if ($cacheExists) {
        $cacheFiles = @(Get-ChildItem -LiteralPath $cachePath -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    if ($cacheFiles -gt 0 -and $srcFiles -eq 0) {
        throw ("Verification failed: HDD copy is empty while the cache still holds {0} file(s). Cache kept at {1}" -f $cacheFiles, $cachePath)
    }

    # 6) Delete the cache folder only if the marker confirms ownership.
    #    Security software can veto Remove-Item here; that must NOT fail the
    #    operation because the data is already safely back on the HDD. The
    #    leftover folder is reported so the GUI can surface it.
    $removedCache = $false
    $cacheCleanupError = $null
    if ($null -ne $meta -and $meta.OriginalPath -eq $src) {
        $removedCache = Remove-CacheFolderSafe -LiteralPath $cachePath
        if (-not $removedCache) { $cacheCleanupError = 'The cache folder is empty but could not be removed.' }
    }

    # 7) Prune empty folders left inside the cache root.
    $pruned = @()
    if ($CacheRoot) { $pruned = Remove-EmptyParents -StartDir (Split-Path -Parent $cachePath) -Root $CacheRoot }

    $msg = ('Demoted. {0} GB restored to {1}.' -f [math]::Round($size / 1GB, 3), $homeDrive)
    if ($cacheCleanupError) {
        Write-Warning ("Data was restored successfully, but the cache folder could not be deleted: {0}" -f $cacheCleanupError)
        $msg += " Data is safe on the HDD; the empty cache folder can be removed manually."
    }

    return [pscustomobject]@{
        Success = $true
        WasCached = $true
        Path = $src
        SizeBytes = $size
        CacheRemoved = $removedCache
        CacheCleanupError = $cacheCleanupError
        PrunedFolders = $pruned
        Message = $msg
    }
}

function Get-DriveSpaceInfo {
    <# Free / total bytes per fixed drive, for the GUI status bar. #>
    $out = @()
    foreach ($root in (Get-DriveRoots)) {
        $letter = $root.TrimEnd('\').TrimEnd(':')
        $free = Get-FreeBytes -DriveLetter $letter
        $total = [int64]0
        try {
            $d = [IO.DriveInfo]::new($root)
            $total = [int64]$d.TotalSize
        } catch { }
        $out += [pscustomobject]@{
            Drive     = $letter
            Root      = $root
            FreeBytes = $free
            TotalBytes = $total
            IsNTFS    = $(try { [IO.DriveInfo]::new($root).DriveFormat -eq 'NTFS' } catch { $false })
        }
    }
    return $out
}
'@

$state = @{
    CacheRoot  = $CacheRoot
    Nodes      = @{}      # 路径 -> TreeNode
    Inventory  = @()
    ScanBusy   = $false   # 后台扫描是否正在进行
    OpBusy     = $false   # 长任务（提升/回写）是否正在进行
}
# 注意：Set-StrictMode Latest 下读取 hashtable 未定义的键会抛
# "找不到属性"异常（赋值不抛、读取抛）。所有被读取的键必须在此初始化。

# 勾选级联防递归标志，用 $script: 前缀明确绑定脚本会话状态
$script:CheckGuard = $false

# 长任务（提升/回写）后台执行状态
# 注意：这些必须在脚本顶层初始化为 $null/默认值。若只在 Start-Operation
# 里赋值，用户未执行过任务就关闭窗体时，Stop-Operation 读取它们会抛
# "检索不到变量"（Set-StrictMode Latest 对未定义的 $script: 变量读取抛错），
# 且异常发生在 FormClosing 里会阻止窗口关闭。
$script:OpPS            = $null   # 后台 [powershell] 实例
$script:OpAsyncResult   = $null
$script:OpTimer         = $null
$script:OpProgressRead  = 0       # Streams.Progress 已读取的记录数
$script:OpLastSizeAt    = [DateTime]::MinValue
$script:OpMode          = ''      # Promote / Demote
$script:OpCacheRoot     = ''
$script:OpTotalBytes    = [int64]0
$script:OpMeas          = @{ Busy = $false; PS = $null; Ar = $null; CachePath = $null; DoneBytes = [int64]0; LastShown = '' }

# 后台扫描执行状态（同理：必须顶层预初始化）
$script:ScanPS          = $null
$script:ScanAsyncResult = $null
$script:ScanTimer       = $null

# 状态值映射：核心库返回英文状态，界面显示中文
$script:StatusText = @{
    'Cached'        = '已缓存'
    'TargetMissing' = '目标丢失'
    'System'        = '系统联接'
}

#region 辅助

function Set-SplitterSafe {
    <#
      构造期安全设置 SplitContainer 的最小尺寸。

      SplitterDistance 在控件获得实际尺寸之前赋值必然抛出
      "SplitterDistance 必须在 Panel1MinSize 和 Width - Panel2MinSize 之间"，
      因此构造期只设置 MinSize（这是安全的），实际分割位置
      由 Apply-SplitterDistances 在窗体显示之后应用。
    #>
    param(
        [System.Windows.Forms.SplitContainer]$Split,
        [int]$Panel1Min,
        [int]$Panel2Min
    )
    try { if ($Panel1Min -gt 0) { $Split.Panel1MinSize = $Panel1Min } } catch { }
    try { if ($Panel2Min -gt 0) { $Split.Panel2MinSize = $Panel2Min } } catch { }
}

function Apply-SplitterDistances {
    <# 在窗体显示并完成布局之后，按比例应用分割位置。 #>
    param([System.Windows.Forms.Form]$Form)

    $targets = @(
        @{ Split = $script:SplitTop; Distance = [int]($Form.ClientSize.Width * 0.42) },
        @{ Split = $script:SplitMain; Distance = [int]($Form.ClientSize.Height * 0.58) },
        @{ Split = $script:LeftMid;  Distance = [int]($script:LeftMid.Width * 0.55) }
    )

    foreach ($t in $targets) {
        $s = $t.Split
        if ($null -eq $s) { continue }
        try {
            $max = $s.Width - $s.Panel2MinSize
            $d = [Math]::Max($s.Panel1MinSize, [Math]::Min($t.Distance, $max))
            if ($d -gt 0 -and $d -lt $s.Width) { $s.SplitterDistance = $d }
        } catch { }
    }
}

function InvokeOnUiThread {
    <#
      把脚本块封送回拥有窗体控件的 UI 线程执行。

      后台线程绝不能直接操作控件。这里用窗体自身的 Invoke()，
      这是 WinForms 官方文档化的封送方式，且不依赖任何需要
      特殊类型名解析的同步上下文对象。
      InvokeRequired 为假时（已在 UI 线程）直接内联执行，避免死锁。
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    $f = $script:Form
    if ($null -eq $f) { & $Action; return }

    try {
        if ($f.IsDisposed -or -not $f.IsHandleCreated) { & $Action; return }
    } catch {
        & $Action
        return
    }

    try {
        if ($f.InvokeRequired) {
            $f.Invoke($Action)
        } else {
            & $Action
        }
    } catch {
        # 窗体正在关闭时封送可能失败；此时忽略，不应向后台线程抛出。
    }
}

function Write-Log {
    param([string]$Text, [string]$Level = '信息')
    if ($null -eq $script:LogBox) { return }
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = "[{0}] {1,-4} {2}" -f $stamp, $Level, $Text
    $script:LogBox.AppendText($line + [Environment]::NewLine)
    $script:LogBox.SelectionStart = $script:LogBox.Text.Length
    $script:LogBox.ScrollToCaret()
}

function Format-SizeGB {
    param([double]$Bytes)
    return ('{0:N2} GB' -f ($Bytes / 1GB))
}

#endregion

#region 界面构建

function Initialize-Controls {

    # ---- 日志框 ----
    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = 'Vertical'
    $script:LogBox.Dock = 'Fill'
    $script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:LogBox.BackColor = [System.Drawing.Color]::White

    # ---- 目录树 ----
    $script:Tree = New-Object System.Windows.Forms.TreeView
    $script:Tree.CheckBoxes = $true
    $script:Tree.Dock = 'Fill'
    $script:Tree.HideSelection = $false
    $script:Tree.Font = New-Object System.Drawing.Font('微软雅黑', 9)

    # ---- 缓存清单 ----
    $script:Inventory = New-Object System.Windows.Forms.ListView
    $script:Inventory.View = 'Details'
    $script:Inventory.FullRowSelect = $true
    $script:Inventory.GridLines = $true
    $script:Inventory.HideSelection = $false
    $script:Inventory.Dock = 'Fill'
    $script:Inventory.Font = New-Object System.Drawing.Font('微软雅黑', 9)
    $null = $script:Inventory.Columns.Add('原路径', 250)
    $null = $script:Inventory.Columns.Add('缓存位置', 250)
    $null = $script:Inventory.Columns.Add('大小', 80)
    $null = $script:Inventory.Columns.Add('文件数', 60)
    $null = $script:Inventory.Columns.Add('状态', 80)

    # ---- 已缓存目录树（右侧下半） ----
    $script:CachedTree = New-Object System.Windows.Forms.TreeView
    $script:CachedTree.Dock = 'Fill'
    $script:CachedTree.Font = New-Object System.Drawing.Font('微软雅黑', 9)

    # ---- 缓存根目录输入框 ----
    $script:CacheRootBox = New-Object System.Windows.Forms.TextBox
    $script:CacheRootBox.Text = $state.CacheRoot
    $script:CacheRootBox.Dock = 'Fill'
    $script:CacheRootBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)

    # ---- 按钮 ----
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = '刷新目录'
    $btnRefresh.Width = 96
    $btnRefresh.Height = 30
    $btnRefresh.Add_Click({ Refresh-SelectionPanel })
    $script:BtnRefresh = $btnRefresh

    $btnExpand = New-Object System.Windows.Forms.Button
    $btnExpand.Text = '展开磁盘'
    $btnExpand.Width = 96
    $btnExpand.Height = 30
    $btnExpand.Add_Click({ Expand-All })

    $btnCollapse = New-Object System.Windows.Forms.Button
    $btnCollapse.Text = '全部折叠'
    $btnCollapse.Width = 90
    $btnCollapse.Height = 30
    $btnCollapse.Add_Click({ Collapse-All })

    $btnRescan = New-Object System.Windows.Forms.Button
    $btnRescan.Text = '扫描缓存'
    $btnRescan.Width = 96
    $btnRescan.Height = 30
    $btnRescan.Add_Click({ Refresh-Inventory })
    $script:BtnRescan = $btnRescan

    $btnDemoteOne = New-Object System.Windows.Forms.Button
    $btnDemoteOne.Text = '回写选中行'
    $btnDemoteOne.Width = 110
    $btnDemoteOne.Height = 30
    $btnDemoteOne.Add_Click({ Invoke-DemoteHighlighted })
    $script:BtnDemoteOne = $btnDemoteOne

    $btnPromote = New-Object System.Windows.Forms.Button
    $btnPromote.Text = '提升到 SSD'
    $btnPromote.Width = 130
    $btnPromote.Height = 34
    $btnPromote.BackColor = [System.Drawing.Color]::FromArgb(226, 239, 218)
    $btnPromote.Add_Click({ Invoke-PromoteSelected })
    $script:BtnPromote = $btnPromote

    $btnDemote = New-Object System.Windows.Forms.Button
    $btnDemote.Text = '回写勾选目录'
    $btnDemote.Width = 130
    $btnDemote.Height = 34
    $btnDemote.BackColor = [System.Drawing.Color]::FromArgb(252, 235, 235)
    $btnDemote.Add_Click({ Invoke-DemoteSelected })
    $script:BtnDemote = $btnDemote

    # ---- 标签 ----
    $lblCacheRoot = New-Object System.Windows.Forms.Label
    $lblCacheRoot.Text = '缓存根目录:'
    $lblCacheRoot.AutoSize = $true
    $lblCacheRoot.Dock = 'Left'
    $lblCacheRoot.Width = 90
    $lblCacheRoot.TextAlign = 'MiddleLeft'
    $lblCacheRoot.Font = New-Object System.Drawing.Font('微软雅黑', 9)

    $script:HintLabel = New-Object System.Windows.Forms.Label
    $script:HintLabel.Text = '提示：在目录树中勾选要加速的文件夹，点击复选框会级联选中整个分支；日志区下方显示操作结果。'
    $script:HintLabel.Dock = 'Top'
    $script:HintLabel.Height = 22
    $script:HintLabel.TextAlign = 'MiddleLeft'
    $script:HintLabel.ForeColor = [System.Drawing.Color]::DimGray
    $script:HintLabel.Font = New-Object System.Drawing.Font('微软雅黑', 8.5)

    $script:LblDrives = New-Object System.Windows.Forms.Label
    $script:LblDrives.Dock = 'Bottom'
    $script:LblDrives.Height = 22
    $script:LblDrives.Font = New-Object System.Drawing.Font('微软雅黑', 8.5)
    $script:LblDrives.ForeColor = [System.Drawing.Color]::DimGray

    # ---- 布局 ----

    # 左侧面板：按钮行 + 目录树/已缓存树
    $leftPanel = New-Object System.Windows.Forms.Panel
    $leftPanel.Dock = 'Fill'
    $leftPanel.Padding = New-Object System.Windows.Forms.Padding(6)

    $leftTop = New-Object System.Windows.Forms.FlowLayoutPanel
    $leftTop.Dock = 'Top'
    $leftTop.Height = 82
    $leftTop.FlowDirection = 'LeftToRight'
    # 两行布局：第一行 = 目录树操作（刷新/展开/折叠），第二行 = 数据操作
    # （提升/回写）。SetFlowBreak 在「全部折叠」后强制换行——若靠宽度
    # 自动换行，「提升到 SSD」会被挤进第一行行尾，与回写按钮拆开。
    $leftTop.WrapContents = $true
    $leftTop.Controls.AddRange(@($btnRefresh, $btnExpand, $btnCollapse, $btnPromote, $btnDemote))
    $leftTop.SetFlowBreak($btnCollapse, $true)

    $leftMid = New-Object System.Windows.Forms.SplitContainer
    $leftMid.Dock = 'Fill'
    $leftMid.Orientation = 'Vertical'
    Set-SplitterSafe -Split $leftMid -Panel1Min 160 -Panel2Min 140
    $leftMid.Panel1.Controls.Add($script:Tree)
    $leftMid.Panel2.Controls.Add($script:CachedTree)
    $script:LeftMid = $leftMid

    $leftPanel.Controls.Add($leftMid)
    $leftPanel.Controls.Add($leftTop)

    # 右侧面板：按钮行 + 缓存清单
    $rightPanel = New-Object System.Windows.Forms.Panel
    $rightPanel.Dock = 'Fill'
    $rightPanel.Padding = New-Object System.Windows.Forms.Padding(6)

    $rightTop = New-Object System.Windows.Forms.FlowLayoutPanel
    $rightTop.Dock = 'Top'
    $rightTop.Height = 36
    $rightTop.FlowDirection = 'LeftToRight'
    $rightTop.Controls.AddRange(@($btnRescan, $btnDemoteOne))

    $rightPanel.Controls.Add($script:Inventory)
    $rightPanel.Controls.Add($rightTop)

    # 底部日志区：提示行 + 日志框
    $bottomPanel = New-Object System.Windows.Forms.Panel
    $bottomPanel.Dock = 'Fill'
    $bottomPanel.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 6)
    $bottomPanel.Controls.Add($script:LogBox)

    # 进度条 + 状态文字（提升/回写长任务时显示）
    $script:OpStatusLabel = New-Object System.Windows.Forms.Label
    $script:OpStatusLabel.Dock = 'Right'
    $script:OpStatusLabel.Width = 380
    $script:OpStatusLabel.TextAlign = 'MiddleLeft'
    $script:OpStatusLabel.Font = New-Object System.Drawing.Font('微软雅黑', 8.5)
    $script:OpStatusLabel.ForeColor = [System.Drawing.Color]::DarkSlateBlue

    $script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:ProgressBar.Dock = 'Fill'
    $script:ProgressBar.Height = 22

    $script:ProgressPanel = New-Object System.Windows.Forms.Panel
    $script:ProgressPanel.Dock = 'Top'
    $script:ProgressPanel.Height = 26
    $script:ProgressPanel.Controls.Add($script:ProgressBar)
    $script:ProgressPanel.Controls.Add($script:OpStatusLabel)
    $script:ProgressPanel.Visible = $false

    $bottomPanel.Controls.Add($script:ProgressPanel)
    $bottomPanel.Controls.Add($script:HintLabel)

    # 主分割：上=目录树+清单，下=日志
    $splitMain = New-Object System.Windows.Forms.SplitContainer
    $splitMain.Dock = 'Fill'
    $splitMain.Orientation = 'Horizontal'
    Set-SplitterSafe -Split $splitMain -Panel1Min 260 -Panel2Min 120
    $script:SplitMain = $splitMain

    # 上部分割：左=目录树，右=清单
    $splitTop = New-Object System.Windows.Forms.SplitContainer
    $splitTop.Dock = 'Fill'
    $splitTop.Orientation = 'Vertical'
    Set-SplitterSafe -Split $splitTop -Panel1Min 300 -Panel2Min 360
    $script:SplitTop = $splitTop
    $splitTop.Panel1.Controls.Add($leftPanel)
    $splitTop.Panel2.Controls.Add($rightPanel)

    $splitMain.Panel1.Controls.Add($splitTop)
    $splitMain.Panel2.Controls.Add($bottomPanel)

    # 根面板：缓存根输入行（顶）+ 主分割（填充）+ 磁盘状态（底）
    $cacheRootPanel = New-Object System.Windows.Forms.Panel
    $cacheRootPanel.Dock = 'Top'
    $cacheRootPanel.Height = 30
    $cacheRootPanel.Controls.Add($script:CacheRootBox)
    $cacheRootPanel.Controls.Add($lblCacheRoot)

    $rootPanel = New-Object System.Windows.Forms.Panel
    $rootPanel.Dock = 'Fill'
    $rootPanel.Controls.Add($splitMain)
    $rootPanel.Controls.Add($cacheRootPanel)
    $rootPanel.Controls.Add($script:LblDrives)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SSD 缓存管理器（基于目录联接，兼容内核隔离）'
    $form.Width = 1200
    $form.Height = 780
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object System.Drawing.Font('微软雅黑', 9)
    $form.Controls.Add($rootPanel)

    return $form
}

#endregion

#region 目录树

function Add-TreeNodeLazy {
    <# 创建带占位子节点的树节点，使其显示展开箭头，展开时才真正枚举。 #>
    param(
        [System.Windows.Forms.TreeNodeCollection]$Collection,
        [string]$Text,
        [string]$Path,
        [hashtable]$Map
    )
    $n = New-Object System.Windows.Forms.TreeNode($Text)
    $n.Tag = $Path
    $null = $Collection.Add($n)
    $null = $n.Nodes.Add('...')
    $Map[$Path] = $n
    return $n
}

function Expand-Node {
    <#
      展开一个节点。只枚举子目录并检测联接点属性，绝不调用
      Get-CacheStatus / Get-DirSize——那会对整个磁盘做递归统计，
      在数 TB 机械盘上耗时数秒，造成界面冻结。
    #>
    param([System.Windows.Forms.TreeNode]$Node)

    if ($null -eq $Node) { return }
    if ($Node.Nodes.Count -eq 1 -and $Node.Nodes[0].Text -eq '...') {
        $Node.Nodes.Clear()
        $path = $Node.Tag
        try {
            # 只做廉价的属性判断，不做任何递归统计
            if (Test-Junction -LiteralPath $path) {
                $t = Get-JunctionTarget -LiteralPath $path
                $Node.Text = "$path  ->  $t  [已缓存]"
                $Node.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 20)
                $Node.Nodes.Clear()
            } else {
                foreach ($child in (Get-ChildDirectories -LiteralPath $path)) {
                    $label = $child.Name
                    if ($child.IsJunction) {
                        $label = "$($child.Name)  ->  $($child.Target)  [已缓存]"
                        $n = New-Object System.Windows.Forms.TreeNode($label)
                        $n.Tag = $child.Path
                        $n.ForeColor = [System.Drawing.Color]::FromArgb(60, 120, 20)
                        $null = $Node.Nodes.Add($n)
                        $state.Nodes[$child.Path] = $n
                    } else {
                        $null = (Add-TreeNodeLazy -Collection $Node.Nodes -Text $label -Path $child.Path -Map $state.Nodes)
                    }
                }
            }
        } catch {
            $Node.Text = "$path  （无法读取）"
            $Node.ForeColor = [System.Drawing.Color]::Gray
        }
    }
}

function Build-Tree {
    $script:Tree.BeginUpdate()
    $script:Tree.Nodes.Clear()
    $state.Nodes.Clear()

    foreach ($root in (Get-DriveRoots)) {
        $letter = $root.TrimEnd('\')
        $label = $letter
        try {
            $d = [IO.DriveInfo]::new($root)
            $label = "{0}   剩余 {1} GB / 共 {2} GB" -f $letter, [math]::Round($d.AvailableFreeSpace / 1GB, 1), [math]::Round($d.TotalSize / 1GB, 1)
        } catch { }

        $node = New-Object System.Windows.Forms.TreeNode($label)
        $node.Tag = $root
        $node.Nodes.Add('...')
        $null = $script:Tree.Nodes.Add($node)
        $state.Nodes[$root] = $node

        # 磁盘根节点不预先展开。预先展开会触发对整盘的枚举与统计，
        # 这是此前"界面未响应"的直接原因。
    }
    $script:Tree.EndUpdate()

    $parts = @()
    foreach ($d in (Get-DriveSpaceInfo)) {
        $parts += ("{0}: 剩余 {1} GB" -f $d.Drive, [math]::Round($d.FreeBytes / 1GB, 0))
    }
    $script:LblDrives.Text = '  ' + ($parts -join '      ')
}

function Expand-All {
    <# 只展开磁盘根节点。全量展开会读取大量不需要的目录。 #>
    foreach ($n in $script:Tree.Nodes) {
        try { $n.Expand() } catch { }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Collapse-All { $script:Tree.CollapseAll() }

function Get-CheckedPaths {
    $out = @()
    foreach ($kvp in $state.Nodes.GetEnumerator()) {
        $node = $kvp.Value
        if ($node.Checked -and $node.Tag) {
            $out += [pscustomobject]@{ Path = $node.Tag; Node = $node }
        }
    }
    return $out
}

#endregion

#region 操作

function Refresh-SelectionPanel {
    Build-Tree
    Write-Log '目录树已刷新。'
    Refresh-Inventory
}

function Start-InventoryScan {
    <#
      在独立 Runspace 中后台扫描联接点，用 Timer 轮询结果。

      为什么不能用 ThreadPool + scriptblock：
        PowerShell scriptblock 绑定创建它的 runspace。线程池线程没有自己的
        runspace，只能借用 UI 线程的 runspace。扫描期间用户点击目录树时，
        UI 线程也在调用核心库函数，两个线程同时争用同一个 runspace，
        状态损坏后随机崩溃——这正是"一点击就崩溃"的根因。

      这里用 [powershell]::Create() 给 worker 一个独立 runspace，
      UI 线程与 worker 彻底隔离。worker 结果通过 WinForms Timer 在
      UI 线程上轮询收取，控件更新天然线程安全。
    #>
    param()

    if ($state.ScanBusy) { Write-Log '扫描正在进行中。' '警告'; return }
    $state.ScanBusy = $true
    $script:Inventory.Enabled = $false
    Write-Log '正在后台扫描缓存目录 ...'

    $roots = @(Get-DriveRoots) | Where-Object { $_ -notlike 'C:*' }

    # 独立 runspace 执行扫描。AddScript 传命令文本而非 scriptblock，
    # 避免任何对当前会话状态的隐式绑定；库源文本直接拼入脚本。
    $scanScript = 'param($roots)' + [Environment]::NewLine + $script:LibSource + [Environment]::NewLine + '@(Get-JunctionInventory -Roots $roots -MaxDepth 3)'
    $ps = [powershell]::Create()
    $null = $ps.AddScript($scanScript)
    $null = $ps.AddArgument($roots)

    $script:ScanPS = $ps
    $script:ScanAsyncResult = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({ Test-ScanCompletion })
    $script:ScanTimer = $timer
    $timer.Start()
}

function Test-ScanCompletion {
    <# 在 UI 线程上由 Timer 触发，检查后台扫描是否完成并收取结果。 #>
    try {
        if ($null -eq $script:ScanAsyncResult -or -not $script:ScanAsyncResult.IsCompleted) { return }

        $script:ScanTimer.Stop()

        $found = @()
        $errMsg = $null
        try {
            $out = $script:ScanPS.EndInvoke($script:ScanAsyncResult)
            if ($null -ne $out) { $found = @($out) }
        } catch {
            $errMsg = $_.Exception.Message
            if ($_.Exception.InnerException) { $errMsg = $_.Exception.InnerException.Message }
        }

        try { $script:ScanPS.Dispose() } catch { }
        $script:ScanPS = $null
        $script:ScanAsyncResult = $null

        $state.ScanBusy = $false
        $script:Inventory.Enabled = $true

        if ($errMsg) {
            Write-Log ("扫描失败：" + $errMsg) '错误'
        } else {
            $total = 0
            foreach ($f in $found) { $total += $f.SizeBytes }
            Write-Log ("扫描完成：{0} 个缓存目录，共 {1}。" -f $found.Count, (Format-SizeGB $total))
        }
        Update-InventoryUi -Items $found
    } catch {
        $state.ScanBusy = $false
        $script:Inventory.Enabled = $true
        Write-Log ("收取扫描结果时异常：" + $_.Exception.Message) '错误'
    }
}

function Stop-InventoryScan {
    <# 窗体关闭时中止仍在进行的后台扫描，避免线程泄漏。 #>
    try {
        if ($null -ne $script:ScanTimer) { $script:ScanTimer.Stop(); $script:ScanTimer.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:ScanPS) { $script:ScanPS.Stop(); $script:ScanPS.Dispose() }
    } catch { }
    $script:ScanPS = $null
    $script:ScanAsyncResult = $null
}

function Update-InventoryUi {
    param([object[]]$Items)

    $found = @()
    if ($null -ne $Items) { $found = @($Items) }
    $state.Inventory = $found

    $script:Inventory.BeginUpdate()
    try {
        $script:Inventory.Items.Clear()
        foreach ($f in $found) {
            $statusText = $f.Status
            if ($script:StatusText.ContainsKey($f.Status)) { $statusText = $script:StatusText[$f.Status] }

            $row = New-Object System.Windows.Forms.ListViewItem($f.Path)
            $null = $row.SubItems.Add($(if ($f.Target) { $f.Target } else { '（丢失）' }))
            $null = $row.SubItems.Add((Format-SizeGB $f.SizeBytes))
            $null = $row.SubItems.Add([string]$f.FileCount)
            $null = $row.SubItems.Add($statusText)
            $row.Tag = $f
            if ($f.Status -eq 'TargetMissing') { $row.ForeColor = [System.Drawing.Color]::Firebrick }
            elseif ($f.Status -eq 'System') { $row.ForeColor = [System.Drawing.Color]::Gray }
            $null = $script:Inventory.Items.Add($row)
        }

        $script:CachedTree.Nodes.Clear()
        foreach ($f in $found) {
            $statusText = $f.Status
            if ($script:StatusText.ContainsKey($f.Status)) { $statusText = $script:StatusText[$f.Status] }
            $n = New-Object System.Windows.Forms.TreeNode("$($f.Path)   [$statusText]")
            $n.Tag = $f.Path
            $n.ForeColor = $(if ($f.Status -eq 'Cached') { [System.Drawing.Color]::FromArgb(60, 120, 20) } elseif ($f.Status -eq 'System') { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::Firebrick })
            $null = $script:CachedTree.Nodes.Add($n)
        }
    } finally {
        $script:Inventory.EndUpdate()
    }
}

function Refresh-Inventory {
    <# 启动后台扫描（独立 runspace），立即返回。 #>
    Start-InventoryScan
}

function Set-OpUi {
    <# 操作期间禁用会互相干扰的按钮，并显示/隐藏进度区。 #>
    param([bool]$Busy)
    $script:BtnPromote.Enabled = -not $Busy
    $script:BtnDemote.Enabled = -not $Busy
    $script:BtnDemoteOne.Enabled = -not $Busy
    $script:BtnRescan.Enabled = -not $Busy
    $script:BtnRefresh.Enabled = -not $Busy
    $script:ProgressPanel.Visible = $Busy
    if ($Busy) { $script:ProgressBar.Value = 0 }
}

function Start-Operation {
    <#
      把提升/回写序列放到独立 runspace 执行，立即返回。

      worker 通过 Write-Progress 报告目录级进度（第 N/M 个 + 当前路径 +
      预估大小），UI 侧的 Timer 轮询 Streams.Progress 更新进度条，
      并周期性测量目标目录已写入的大小，让大目录迁移过程可见。
    #>
    param(
        [Parameter(Mandatory)][string]$Mode,
        [Parameter(Mandatory)][string[]]$Paths,
        [Parameter(Mandatory)][string]$Root,
        [long[]]$Sizes,
        [long]$TotalBytes = 0
    )

    if ($state.OpBusy) { Write-Log '已有任务在执行。' '警告'; return }
    $state.OpBusy = $true
    $script:OpMode = $Mode
    $script:OpCacheRoot = $Root
    $script:OpProgressRead = 0
    $script:OpLastSizeAt = [DateTime]::MinValue
    $script:OpTotalBytes = $TotalBytes
    $script:OpMeas = @{ Busy = $false; PS = $null; Ar = $null; CachePath = $null; DoneBytes = [int64]0; LastShown = '' }

    Set-OpUi -Busy $true
    $modeText = $(if ($Mode -eq 'Promote') { '提升到 SSD' } else { '回写机械盘' })
    $script:OpStatusLabel.Text = "准备中..."
    Write-Log ("开始{0}，共 {1} 个目录，{2}。" -f $modeText, $Paths.Count, (Format-SizeGB $TotalBytes))

    # worker 逻辑：here-string 保存（单引号不插值），运行时与库源文本拼接。
    # 拼接顺序：param 行 -> 库源（Set-StrictMode + 全部函数定义）-> 任务体。
    # 库源里的 $script: 变量赋值会在 worker runspace 顶层执行，函数运行时
    # 引用它们自洽，无需 Import-Module。
    $workerBody = @'
$out = New-Object System.Collections.Generic.List[object]
$total = @($paths).Count
$done = [int64]0
for ($i = 0; $i -lt $total; $i++) {
    $p = @($paths)[$i]
    $sz = [int64]0
    if ($null -ne $sizes -and $i -lt @($sizes).Count) { $sz = [int64]@($sizes)[$i] }
    $pct = [int](100 * $i / [Math]::Max($total, 1))
    try {
        if ($mode -eq 'Promote') {
            $cp = Get-CachePathFor -SourcePath $p -CacheRoot $root
            # CurrentOperation 编码供 UI 侧测量: 缓存路径|本目录字节|此前已完成字节
            Write-Progress -Id 1 -Activity 'Promote' -Status ("[{0}/{1}] {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}" -f $cp, $sz, $done) -PercentComplete $pct
            $r = Invoke-CachePromote -SourcePath $p -CacheRoot $root
            $done += $sz
            $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = $r.AlreadyCached; SizeBytes = $r.SizeBytes; Message = $r.Message })
        } else {
            Write-Progress -Id 1 -Activity 'Demote' -Status ("[{0}/{1}] {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}" -f $p, $sz, $done) -PercentComplete $pct
            $r = Invoke-CacheDemote -SourcePath $p -CacheRoot $root
            $done += $sz
            $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = (-not $r.WasCached); SizeBytes = $r.SizeBytes; Message = $r.Message; CacheCleanupError = $r.CacheCleanupError })
        }
    } catch {
        $out.Add([pscustomobject]@{ Path = $p; Success = $false; AlreadyCached = $false; SizeBytes = [int64]0; Message = $_.Exception.Message; CacheCleanupError = $null })
    }
}
Write-Progress -Id 1 -Activity 'SSD' -Completed
return $out.ToArray()
'@
    $opScript = 'param($mode, $paths, $root, $sizes)' + [Environment]::NewLine + $script:LibSource + [Environment]::NewLine + $workerBody

    $ps = [powershell]::Create()
    $null = $ps.AddScript($opScript)
    $null = $ps.AddArgument($Mode)
    $null = $ps.AddArgument($Paths)
    $null = $ps.AddArgument($Root)
    $null = $ps.AddArgument($Sizes)

    $script:OpPS = $ps
    $script:OpAsyncResult = $ps.BeginInvoke()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 700
    $timer.Add_Tick({ Poll-Operation })
    $script:OpTimer = $timer
    $timer.Start()
}

function Start-OpMeasure {
    <#
      在独立 runspace 中测量目录当前大小。测量遍历文件树，若在 UI 线程
      做会冻结界面；若在 worker 里做会与 robocopy 争抢 IO。专用短命
      runspace 每 3 秒一次，开销可控且两不干扰。
    #>
    param([string]$Dir)

    $measureScript = 'param($measureDir)' + [Environment]::NewLine + $script:LibSource + [Environment]::NewLine + 'Get-DirSize -LiteralPath $measureDir'
    $ps = [powershell]::Create()
    $null = $ps.AddScript($measureScript)
    $null = $ps.AddArgument($Dir)
    $null = $ps.AddArgument($Dir)
    $script:OpMeas.PS = $ps
    $script:OpMeas.Ar = $ps.BeginInvoke()
}

function Poll-Operation {
    <# UI 线程 Timer：读取 worker 的进度流、周期测量已迁移大小、收取结果。 #>
    try {
        if ($null -eq $script:OpPS) { return }

        # 1) 消费新增的进度记录
        $prog = $script:OpPS.Streams.Progress
        $cur = $null
        while ($script:OpProgressRead -lt @($prog).Count) {
            $rec = $prog[$script:OpProgressRead]
            $script:OpProgressRead++
            if ($null -eq $rec) { continue }
            $cur = $rec
            if ($rec.PercentComplete -ge 0) {
                # 目录级进度仅作兜底显示；真实进度由测量数据计算
                $opText = $(if ($script:OpMode -eq 'Promote') { '提升' } else { '回写' })
                $script:OpStatusLabel.Text = "$opText 中   " + $rec.StatusDescription
            }
        }

        $opText = $(if ($script:OpMode -eq 'Promote') { '提升' } else { '回写' })

        # 2) 从最新进度记录解析当前目录的测量参数
        if ($null -ne $cur -and $cur.CurrentOperation) {
            $parts = ($cur.CurrentOperation -split '\|')
            if ($parts.Count -ge 3) {
                $script:OpMeas.CachePath = $parts[0]
                $script:OpMeas.SizeBytes = [int64]$parts[1]
                $script:OpMeas.DoneBytes = [int64]$parts[2]
            }
        }

        # 3) 数据量进度：后台测量"当前目录已写入量"，与已完成字节合并
        $m = $script:OpMeas
        if ($m.Busy -and $null -ne $m.Ar -and $m.Ar.IsCompleted) {
            $measured = [int64]0
            try { $measured = [int64]($m.PS.EndInvoke($m.Ar)) } catch { $measured = [int64]0 }
            try { $m.PS.Dispose() } catch { }
            $m.PS = $null; $m.Ar = $null; $m.Busy = $false

            if ($script:OpMode -eq 'Promote' -and $script:OpTotalBytes -gt 0) {
                $doneAll = $m.DoneBytes + [Math]::Min($measured, $m.SizeBytes)
                $pct = [int](100 * $doneAll / $script:OpTotalBytes)
                $pct = [Math]::Min(99, [Math]::Max(0, $pct))
                $script:ProgressBar.Value = $pct
                $shown = ("{0} 进度 {1}%（已迁移 {2} / {3}）" -f $opText, $pct, (Format-SizeGB $doneAll), (Format-SizeGB $script:OpTotalBytes))
                if ($shown -ne $m.LastShown) {
                    $m.LastShown = $shown
                    $script:OpStatusLabel.Text = $shown
                }
            } elseif ($script:OpMode -eq 'Demote') {
                $script:OpStatusLabel.Text = ("回写中   [已恢复 {0}]" -f (Format-SizeGB ($m.DoneBytes + $measured)))
            }
        }
        if (-not $m.Busy -and $m.CachePath -and (Test-Path -LiteralPath $m.CachePath)) {
            Start-OpMeasure -Dir $m.CachePath
        }

        # 4) 完成收取
        if ($script:OpAsyncResult.IsCompleted) {
            $results = @()
            $errMsg = $null
            try {
                $out = $script:OpPS.EndInvoke($script:OpAsyncResult)
                if ($null -ne $out) { $results = @($out) }
            } catch {
                $errMsg = $_.Exception.Message
            }
            Finish-Operation -Results $results -Error $errMsg
        }
    } catch {
        Finish-Operation -Results @() -Error $_.Exception.Message
    }
}

function Finish-Operation {
    param([object[]]$Results, [string]$Error)

    try {
        if ($null -ne $script:OpTimer) { $script:OpTimer.Stop(); $script:OpTimer.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:OpPS) { $script:OpPS.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:OpMeas.PS) { $script:OpMeas.PS.Dispose() }
    } catch { }
    $script:OpPS = $null
    $script:OpAsyncResult = $null
    $script:OpMeas.Busy = $false
    $script:OpMeas.PS = $null
    $script:OpMeas.Ar = $null
    $state.OpBusy = $false

    $okCount = 0
    $failCount = 0
    foreach ($r in @($Results)) {
        if ($r.Success) {
            if ($r.AlreadyCached) {
                Write-Log ("{0}：已是缓存目录，跳过。" -f $r.Path) '警告'
            } else {
                Write-Log ("{0}：{1}" -f $r.Path, $r.Message) '完成'
                if ($r.CacheCleanupError) {
                    Write-Log ("{0}：数据已就位，但缓存目录未能自动删除，可手动清理。" -f $r.Path) '警告'
                }
            }
            $okCount++
        } else {
            Write-Log ("{0}：失败 - {1}" -f $r.Path, $r.Message) '错误'
            $failCount++
        }
    }

    $modeText = $(if ($script:OpMode -eq 'Promote') { '提升' } else { '回写' })
    if ($Error) {
        Write-Log ("{0}任务异常中断：{1}" -f $modeText, $Error) '错误'
    }
    Write-Log ("{0}结束。成功 {1} 个，失败 {2} 个。" -f $modeText, $okCount, $failCount)

    $script:ProgressBar.Value = 100
    $script:OpStatusLabel.Text = "完成：成功 $okCount / 失败 $failCount"

    Set-OpUi -Busy $false
    Build-Tree
    Refresh-Inventory
}

function Stop-Operation {
    <# 窗体关闭时中止长任务。 #>
    try {
        if ($null -ne $script:OpTimer) { $script:OpTimer.Stop(); $script:OpTimer.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:OpPS -and $script:OpPS.InvocationStateInfo.State -eq 'Running') { $script:OpPS.Stop() }
        if ($null -ne $script:OpPS) { $script:OpPS.Dispose() }
    } catch { }
    try {
        if ($null -ne $script:OpMeas.PS) { $script:OpMeas.PS.Dispose() }
    } catch { }
    $script:OpPS = $null
    $script:OpAsyncResult = $null
    $script:OpMeas.PS = $null
    $script:OpMeas.Ar = $null
    Stop-InventoryScan
}

function Invoke-PromoteSelected {
    $checked = @(Get-CheckedPaths)
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在目录树中勾选至少一个文件夹。', '未选择任何项') | Out-Null
        return
    }

    $root = $script:CacheRootBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($root)) {
        [System.Windows.Forms.MessageBox]::Show('请先设置缓存根目录。', '缺少缓存根目录') | Out-Null
        return
    }

    Write-Log '正在统计所选文件夹大小（大目录可能需要一些时间）...'
    [System.Windows.Forms.Application]::DoEvents()

    $lines = @()
    $grand = 0
    foreach ($c in $checked) {
        try {
            $sz = Get-DirSize -LiteralPath $c.Path
            $grand += $sz
            $lines += ("  {0}   {1}" -f $c.Path, (Format-SizeGB $sz))
        } catch {
            $lines += ("  {0}   （无法读取）" -f $c.Path)
        }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $msg = "缓存根目录：$root`n`n将提升以下文件夹（后台执行，期间可继续操作界面）：`n" + ($lines -join "`n") + "`n`n合计：{0}`n`n是否继续？" -f (Format-SizeGB $grand)
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '确认提升', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { Write-Log '已取消提升。'; return }

    $paths = @($checked | ForEach-Object { $_.Path })
    $sizes = New-Object System.Collections.Generic.List[long]
    foreach ($p in $paths) {
        $sz = [int64]0
        try { $sz = Get-DirSize -LiteralPath $p } catch { $sz = [int64]0 }
        $sizes.Add($sz)
    }
    Start-Operation -Mode 'Promote' -Paths $paths -Root $root -Sizes $sizes.ToArray() -TotalBytes $grand
}

function Invoke-DemoteSelected {
    $checked = @(Get-CheckedPaths)
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在目录树中勾选至少一个文件夹。', '未选择任何项') | Out-Null
        return
    }

    $cached = @()
    foreach ($c in $checked) {
        if (Test-Junction -LiteralPath $c.Path) { $cached += $c.Path }
    }
    if ($cached.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('勾选的文件夹中没有处于缓存状态的目录。', '无需回写') | Out-Null
        return
    }

    $lines = @()
    foreach ($p in $cached) { $lines += ("  {0}" -f $p) }
    $msg = "将以下缓存目录回写到机械硬盘？`n`n" + ($lines -join "`n") + "`n`n是否继续？"
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '确认回写', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { Write-Log '已取消回写。'; return }

    $root = $script:CacheRootBox.Text.Trim()
    Start-Operation -Mode 'Demote' -Paths $cached -Root $root
}

function Invoke-DemoteHighlighted {
    if ($script:Inventory.SelectedItems.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在缓存清单中选中一行。', '未选择任何项') | Out-Null
        return
    }
    $rec = $script:Inventory.SelectedItems[0].Tag
    if ($null -eq $rec) { return }

    $ans = [System.Windows.Forms.MessageBox]::Show(("将该缓存目录回写到机械硬盘？`n`n  {0}`n`n是否继续？" -f $rec.Path), '确认回写', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return }

    Start-Operation -Mode 'Demote' -Paths @($rec.Path) -Root $script:CacheRootBox.Text.Trim()
}

#endregion

#region 启动

try {
    if (-not (Test-Administrator)) {
        $msg = @"
需要管理员权限。

创建 NTFS 目录联接需要提权，本工具无法在没有管理员权限的情况下工作。

请右键 PowerShell 选择"以管理员身份运行"，再重新启动本脚本。
"@
        [System.Windows.Forms.MessageBox]::Show($msg, '需要管理员权限', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        exit 1
    }
} catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '无法启动', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    exit 1
}

$form = Initialize-Controls

# 记录窗体引用，供后台任务通过 Control.Invoke 封送 UI 更新
$script:Form = $form

# 勾选级联：挂在 AfterCheck 事件上，而不是 NodeMouseClick。
# 原先挂在 NodeMouseClick 上会导致点击展开箭头也切换勾选状态，
# 表现为"一展开就被勾选"。
$script:Tree.add_AfterCheck({
    param($s, $e)
    if ($script:CheckGuard) { return }
    $script:CheckGuard = $true
    try {
        $want = $e.Node.Checked
        $stack = New-Object System.Collections.Stack
        $stack.Push($e.Node)
        while ($stack.Count -gt 0) {
            $n = $stack.Pop()
            if ($n.Text -ne '...') { $n.Checked = $want }
            foreach ($c in $n.Nodes) { $stack.Push($c) }
        }
    } finally {
        $script:CheckGuard = $false
    }
})

$script:Tree.add_BeforeExpand({ param($s, $e) Expand-Node -Node $e.Node })

# 分割位置只能在容器获得实际尺寸之后设置，因此放在 Shown 事件里。
$form.add_Shown({
    Apply-SplitterDistances -Form $form
    Build-Tree
    Write-Log '就绪。请展开磁盘并勾选要加速的文件夹。'
    Refresh-Inventory
})

$form.add_Resize({
    try { Apply-SplitterDistances -Form $form } catch { }
})

$form.add_FormClosing({
    param($s, $e)
    Stop-Operation
    try { Remove-Item (Join-Path $state.CacheRoot 'ssdcache.log') -ErrorAction SilentlyContinue } catch { }
})

[System.Windows.Forms.Application]::Run($form) | Out-Null

#endregion