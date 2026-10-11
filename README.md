# SSD Cache Manager

Directory-level SSD acceleration for Windows 11 using NTFS junctions. Works on
26H2 with HVCI (Memory Integrity) enabled.

## Why junctions

Windows 11 26H2 enables VBS with HVCI by default. HVCI validates kernel drivers
**before they load**, so every kernel-level cache tool is blocked:

| Tool | Blocked by HVCI |
|---|---|
| PrimoCache, StarWind L2, O&O CleverCache | yes (kernel filter drivers) |
| Windows Storage Spaces cache | yes (kernel driver) |
| AMD StoreMI | requires an AMD platform |

A junction is an NTFS reparse point resolved in **user mode**. HVCI does not
touch it, so the tool works on 26H2 without weakening security.

Trade-off: the tool is not transparent. You choose which folders to accelerate.

## Requirements

- Windows 10 / 11, NTFS volumes
- Administrator rights (creating a junction requires elevation)
- A faster target volume than the source (e.g. an SSD cache root)

## Files

| File | Role |
|---|---|
| `Start-SSDCacheManager.cmd` | Launcher. Self-elevates and bypasses the execution policy. **Use this.** |
| `SSDCacheGUI.ps1` | WinForms front end |
| `SSDCacheLib.psm1` | Core module (also usable on its own) |

## Usage

Double-click `Start-SSDCacheManager.cmd` and accept the UAC prompt.

1. Set the **cache root** at the top (e.g. `E:\SSDCache`).
2. Expand the drive you want, then tick the folders to accelerate.
3. Click **Promote selected**. Confirm.
4. Use **Demote selected** or **Demote highlighted cache** to move data back.

The tree shows cached folders in green with their target, so you always know
what is accelerated.

## Performance notes

The window stays responsive even on a multi-terabyte HDD:

- **Drive roots are not expanded at startup.** Expanding a root recursively
  measures every folder on it, which took about 6 seconds per drive. Open only
  the drives you need.
- **The cache scan runs on a background thread.** It walks the tree looking for
  junctions and can take several seconds on a slow drive; the log reports the
  result when it finishes.
- **Folder sizes are measured when you promote**, not while browsing, because
  sizing a directory requires reading it.
- `Expand drives` opens the drive roots only. Expanding every branch at once
  would read directories you do not need.

## Command line usage

The module can be driven without the GUI:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

Import-Module .\SSDCacheLib.psm1

# what is currently cached
Get-JunctionInventory -Roots 'F:\'

# accelerate
Invoke-CachePromote -SourcePath 'F:\Books' -CacheRoot 'E:\SSDCache'

# move back
Invoke-CacheDemote  -SourcePath 'F:\Books' -CacheRoot 'E:\SSDCache'
```

## Behaviour worth knowing

**A demote removes the junction before writing data back.** The reverse order
would send the data straight back into the cache through the junction and leave
the HDD empty. This ordering is mandatory.

**Safety rules enforced in code**

- Paths on `C:` and whole-volume roots are refused.
- If migration fails, data is rolled back to the original location.
- If write-back fails, the junction is left removed and the error message
  includes the exact command to restore access. Data stays in the cache.
- The cache folder is deleted only after verifying the data arrived on the HDD.
- A marker file records the original path; the cache folder is only removed when
  that marker confirms ownership.

**The marker file.** Each cached folder contains `.ssdcache_root`, a small JSON
bookkeeping file. It is relocated away before write-back so it never lands back
in your real folder.

## Troubleshooting

**"Running scripts is disabled on this system"**
Use `Start-SSDCacheManager.cmd`, or run
`Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` first.

**"Administrator privileges are required"**
Right-click PowerShell, choose *Run as administrator*.

**A cached folder shows `TargetMissing`**
The cache root was moved, renamed, or the SSD was unplugged. Run
`Demote` after restoring the original location, or copy the data back manually.

**Cannot remove an empty cache folder**
Endpoint protection software may veto folder deletion. The data is already back
on the HDD, so this is harmless; delete the empty folder manually.