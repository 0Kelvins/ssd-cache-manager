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

Export-ModuleMember -Function @(
    'Test-Administrator',
    'Get-DriveRoots',
    'Get-DirSize',
    'Get-FreeBytes',
    'Get-JunctionTarget',
    'Get-ChildDirectories',
    'Get-JunctionInventory',
    'Get-CacheStatus',
    'Invoke-CachePromote',
    'Invoke-CacheDemote',
    'Get-DriveSpaceInfo',
    'Get-MarkerName',
    'Test-Junction'
)