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

$script:LibPath = Join-Path $PSScriptRoot 'SSDCacheLib.psm1'
# 核心库源文本：独立 runspace 的 worker 无法访问主脚本已导入的函数，
# 需要把库源文本拼进 worker 脚本执行。
# - 命令行运行：从同目录 SSDCacheLib.psm1 读取
# - exe 版：构建脚本把库源内嵌为字面量（LibSource 非空，此处跳过读取）
$script:LibSource = ''
if (Test-Path -LiteralPath $script:LibPath) {
    $script:LibSource = [IO.File]::ReadAllText($script:LibPath)
}

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
$script:OpTotalFiles    = [int64]0   # 全部所选目录的文件总数（全局文件进度用）
$script:OpPaths         = $null   # 当前任务路径列表（手动终止后续传用）
$script:OpSizes         = $null
$script:OpCounts        = $null   # 各路径的文件总数（逐文件进度用）
$script:OpResumePaths   = $null   # 手动终止时正在处理的目录（显式续传候选）
$script:OpStopping      = $false  # 防止「终止任务」按钮重入
$script:OpMeasLogged    = $false  # 进度测量异常只记一次日志
$script:OpMeasStartLogged = $false # 首次启动测量时记一条日志（确认链路已通）
$script:OpCurDirText    = ''      # 当前目录序号文本，如 "[1/1] F:\Game\X"
$script:OpCurDirPath    = ''      # 当前目录源路径（测量路径的兜底推导用）
$script:OpMeas          = @{ Busy = $false; PS = $null; Ar = $null; CachePath = $null; SizeBytes = [int64]0; FileTotal = [int64]0; FilesDoneBase = [int64]0; DoneBytes = [int64]0; LatestFile = ''; LastShown = '' }

# 版本号：同时写进标题栏与启动日志。
# 目的：远程排查时先确认"跑的是哪个构建"——否则改了几轮仍在看旧进程，
# 会被现象误导。见 2026-10-25 的「已完成 1/1」排查。
$script:AppVersion = '1.1'

# 后台扫描执行状态（同理：必须顶层预初始化）
$script:ScanPS          = $null
$script:ScanAsyncResult = $null
$script:ScanTimer       = $null

# 状态值映射：核心库返回英文状态，界面显示中文
$script:StatusText = @{
    'Cached'        = '已缓存'
    'TargetMissing' = '目标丢失'
    'System'        = '系统联接'
    'Caching'       = '正在缓存'
    'Demoting'      = '正在回写'
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

function Format-ShortName {
    <# 超长文件名中间省略，保留首尾以便辨认。 #>
    param([string]$Name, [int]$Max = 60)
    if ([string]::IsNullOrEmpty($Name)) { return '' }
    if ($Name.Length -le $Max) { return $Name }
    $keep = [int](($Max - 1) / 2)
    return ($Name.Substring(0, $keep) + '…' + $Name.Substring($Name.Length - $keep))
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

    # 手动终止：放在进度条面板右侧，用 × 表示；仅操作期间可见/可用。
    # 终止后自动从断点续传，不丢数据。
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = [string][char]0x00D7
    $btnStop.Width = 34
    $btnStop.Height = 22
    $btnStop.Dock = 'Right'
    $btnStop.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnStop.FlatAppearance.BorderSize = 0
    $btnStop.BackColor = [System.Drawing.Color]::FromArgb(255, 224, 178)
    $btnStop.ForeColor = [System.Drawing.Color]::Firebrick
    $btnStop.Font = New-Object System.Drawing.Font('微软雅黑', 10.5, [System.Drawing.FontStyle]::Bold)
    $btnStop.Enabled = $false
    $btnStop.Add_Click({ Invoke-StopOperationManual })
    $script:BtnStop = $btnStop

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

    # 状态明细行（进度条下方：目录序号 + 路径 + 正在复制的文件名）
    # AutoSize 必须显式关闭：Label 默认 AutoSize=true，与 Dock 组合时会被
    # 文本尺寸覆盖，导致整行高度塌陷、文字不可见。
    $script:OpStatusLabel = New-Object System.Windows.Forms.Label
    $script:OpStatusLabel.AutoSize = $false
    $script:OpStatusLabel.Dock = 'Bottom'
    $script:OpStatusLabel.Height = 20
    $script:OpStatusLabel.TextAlign = 'MiddleLeft'
    $script:OpStatusLabel.Font = New-Object System.Drawing.Font('微软雅黑', 8)
    $script:OpStatusLabel.ForeColor = [System.Drawing.Color]::DimGray
    $script:OpStatusLabel.BackColor = [System.Drawing.Color]::WhiteSmoke
    $script:OpStatusLabel.Text = '准备中…'

    # 进度行：进度条（填充）+ 百分比（右）+ × 终止（最右）
    $script:ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $script:ProgressBar.Dock = 'Fill'
    $script:ProgressBar.Height = 22

    $script:PercentLabel = New-Object System.Windows.Forms.Label
    $script:PercentLabel.Dock = 'Right'
    $script:PercentLabel.Width = 56
    $script:PercentLabel.TextAlign = 'MiddleRight'
    $script:PercentLabel.Font = New-Object System.Drawing.Font('Consolas', 9.5, [System.Drawing.FontStyle]::Bold)
    $script:PercentLabel.ForeColor = [System.Drawing.Color]::DarkSlateBlue
    $script:PercentLabel.Text = ''

    # 合计进度：字节 + 文件数（全部所选目录的累计）
    $script:CountLabel = New-Object System.Windows.Forms.Label
    $script:CountLabel.Dock = 'Right'
    $script:CountLabel.Width = 250
    $script:CountLabel.TextAlign = 'MiddleRight'
    $script:CountLabel.Font = New-Object System.Drawing.Font('微软雅黑', 8)
    $script:CountLabel.ForeColor = [System.Drawing.Color]::DimGray
    $script:CountLabel.Text = ''

    $script:ProgressRow = New-Object System.Windows.Forms.Panel
    $script:ProgressRow.Dock = 'Fill'
    $script:ProgressRow.Height = 24
    $script:ProgressRow.Controls.Add($script:ProgressBar)
    $script:ProgressRow.Controls.Add($script:PercentLabel)
    $script:ProgressRow.Controls.Add($script:CountLabel)
    # × 最后加入：停靠按加入的逆序布局，最后加入者最先停靠（最右缘）
    $script:ProgressRow.Controls.Add($btnStop)

    # 两行固定高度的 TableLayoutPanel：彻底避开 Label.AutoSize 与 Dock 的
    # 布局歧义（AutoSize 会覆盖 Fill，导致明细行挤到进度条同一行）。
    $script:ProgressPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $script:ProgressPanel.Dock = 'Top'
    $script:ProgressPanel.Height = 48
    $script:ProgressPanel.ColumnCount = 1
    $script:ProgressPanel.RowCount = 2
    $null = $script:ProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26)))
    $null = $script:ProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 22)))
    $script:ProgressRow.Dock = 'Fill'
    $script:OpStatusLabel.Dock = 'Fill'
    $script:ProgressPanel.Controls.Add($script:ProgressRow, 0, 0)
    $script:ProgressPanel.Controls.Add($script:OpStatusLabel, 0, 1)
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
    # 标题带版本号：远程排查时第一眼就能确认运行的是哪个构建。
    $form.Text = ('SSD 缓存管理器 v{0}（基于目录联接，兼容内核隔离）' -f $script:AppVersion)
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
        if (-not $errMsg) { Save-InventoryCache -Items $found }
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
            $isPending = ($f.Status -eq 'Caching' -or $f.Status -eq 'Demoting')
            $null = $row.SubItems.Add($(if ($isPending) { '—' } else { Format-SizeGB $f.SizeBytes }))
            $null = $row.SubItems.Add($(if ($isPending) { '—' } else { [string]$f.FileCount }))
            $null = $row.SubItems.Add($statusText)
            $row.Tag = $f
            if ($f.Status -eq 'TargetMissing') { $row.ForeColor = [System.Drawing.Color]::Firebrick }
            elseif ($isPending) { $row.ForeColor = [System.Drawing.Color]::DarkOrange }
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

#region 清单快照缓存

function Get-InventoryCachePath {
    <# 快照存放位置：%LOCALAPPDATA%\SSDCacheManager\inventory.json #>
    $dir = Join-Path $env:LOCALAPPDATA 'SSDCacheManager'
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    } catch { }
    return (Join-Path $dir 'inventory.json')
}

function Save-InventoryCache {
    <#
      把扫描结果写入本地快照。下次启动先显示快照，避免每次等全量扫描。
      仅保存展示所需字段，避免把无关对象序列化进文件。
    #>
    param([object[]]$Items)

    try {
        $rows = @()
        foreach ($i in @($Items)) {
            if ($null -eq $i) { continue }
            $rows += [pscustomobject]@{
                Path      = [string]$i.Path
                Target    = $(if ($i.Target) { [string]$i.Target } else { $null })
                SizeBytes = [int64]$i.SizeBytes
                FileCount = [int64]$i.FileCount
                IsValid   = [bool]$i.IsValid
                Status    = [string]$i.Status
            }
        }
        $payload = [pscustomobject]@{
            SavedAt = (Get-Date).ToString('o')
            Tool    = 'SSDCacheManager'
            Version = '1.1'
            Items   = $rows
        }
        ($payload | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath (Get-InventoryCachePath) -Encoding UTF8
    } catch {
        Write-Log ("写入缓存清单快照失败：" + $_.Exception.Message) '警告'
    }
}

function Load-InventoryCache {
    <#
      读取快照并逐项做低成本校验：
        - 路径已不是联接（已回写/被人工删除）        -> 丢弃
        - 联接目标不可达（缓存盘未挂载/被移动）      -> 标记目标丢失
      大目录大小沿用快照值，随后由后台全量扫描覆盖。
    #>
    $path = Get-InventoryCachePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $data = $null
    try { $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return @() }
    if ($null -eq $data -or $null -eq $data.Items) { return @() }

    $out = @()
    foreach ($it in @($data.Items)) {
        if ([string]::IsNullOrWhiteSpace([string]$it.Path)) { continue }
        $isJ = $false
        try { $isJ = Test-Junction -LiteralPath $it.Path } catch { $isJ = $false }
        if (-not $isJ) { continue }
        $targetOk = $false
        try { $targetOk = [bool]($it.Target -and (Test-Path -LiteralPath $it.Target)) } catch { $targetOk = $false }
        $out += [pscustomobject]@{
            Path      = [string]$it.Path
            Target    = $(if ($it.Target) { [string]$it.Target } else { $null })
            SizeBytes = [int64]$it.SizeBytes
            FileCount = [int64]$it.FileCount
            IsValid   = $targetOk
            Status    = $(if ($targetOk) { 'Cached' } else { 'TargetMissing' })
        }
    }
    return $out
}

#endregion

function Refresh-Inventory {
    <# 启动后台扫描（独立 runspace），立即返回。 #>
    Start-InventoryScan
}

function Add-InventoryPending {
    <#
      提升/回写开始时先把目标路径插入清单，状态为「正在缓存 / 正在回写」，
      让用户立刻看到任务涉及哪些目录；完成后由 Complete-InventoryPending
      改写为最终状态，再由后台扫描覆盖为权威结果。
    #>
    param([string]$Mode, [string[]]$Paths)

    $root = $script:CacheRootBox.Text.Trim()
    $pending = @()
    foreach ($p in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $tgt = $null
        try { if ($root) { $tgt = Get-CachePathFor -SourcePath $p -Root $root } } catch { $tgt = $null }
        $pending += [pscustomobject]@{
            Path      = [string]$p
            Target    = $(if ($tgt) { [string]$tgt } else { $null })
            SizeBytes = [int64]0
            FileCount = 0
            IsValid   = $true
            Status    = $(if ($Mode -eq 'Promote') { 'Caching' } else { 'Demoting' })
        }
    }
    if ($pending.Count -eq 0) { return }

    # 同路径的旧行先移除，避免出现重复条目
    $kept = @()
    foreach ($e in @($state.Inventory)) {
        $dup = $false
        foreach ($i in $pending) { if ([string]$e.Path -eq $i.Path) { $dup = $true; break } }
        if (-not $dup) { $kept += $e }
    }
    Update-InventoryUi -Items (@($pending) + $kept)
}

function Complete-InventoryPending {
    <#
      用任务结果收尾清单：
        提升成功 -> 状态改为「已缓存」，大小取实际迁移量
        提升失败 -> 移除占位行（数据未迁移）
        回写成功 -> 移除该行（已不在缓存中）
        回写失败 -> 保留
      未出现在结果中的占位行一并清除，随后由扫描写入权威数据。
    #>
    param([string]$Mode, [object[]]$Results)

    $inv = @($state.Inventory)
    if ($inv.Count -eq 0) { return }

    $byPath = @{}
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $pp = $r.PSObject.Properties['Path']
        if (-not $pp) { continue }
        $byPath[[string]$pp.Value] = $r
    }

    $out = @()
    foreach ($e in $inv) {
        $key = [string]$e.Path
        $isPending = ($e.Status -eq 'Caching' -or $e.Status -eq 'Demoting')

        if (-not $byPath.ContainsKey($key)) {
            if (-not $isPending) { $out += $e }
            continue
        }

        $r = $byPath[$key]
        $okProp = $r.PSObject.Properties['Success']
        $ok = ($null -eq $okProp -or [bool]$okProp.Value)

        if ($Mode -eq 'Demote') {
            if ($ok) { continue }
            $out += $e
            continue
        }

        if (-not $ok) { continue }
        $sizeProp = $r.PSObject.Properties['SizeBytes']
        $out += [pscustomobject]@{
            Path      = $key
            Target    = $(if ($e.Target) { [string]$e.Target } else { $null })
            SizeBytes = $(if ($sizeProp) { [int64]$sizeProp.Value } else { [int64]0 })
            FileCount = [int64]$e.FileCount
            IsValid   = $true
            Status    = 'Cached'
        }
    }
    Update-InventoryUi -Items $out
}

function Set-OpUi {
    <# 操作期间禁用会互相干扰的按钮，并显示/隐藏进度区。 #>
    param([bool]$Busy)
    $script:BtnPromote.Enabled = -not $Busy
    $script:BtnDemote.Enabled = -not $Busy
    $script:BtnDemoteOne.Enabled = -not $Busy
    $script:BtnRescan.Enabled = -not $Busy
    $script:BtnRefresh.Enabled = -not $Busy
    $script:BtnStop.Enabled = $Busy
    $script:ProgressPanel.Visible = $Busy
    if ($Busy) {
        $script:ProgressBar.Value = 0
        $script:PercentLabel.Text = '0%'
        $script:CountLabel.Text = ''
    }
}

function Reset-OpRuntime {
    <# 停止并释放任务相关的全部后台资源（timer / worker / 测量 runspace）。 #>
    try { if ($null -ne $script:OpTimer) { $script:OpTimer.Stop(); $script:OpTimer.Dispose() } } catch { }
    try {
        if ($null -ne $script:OpPS -and $script:OpPS.InvocationStateInfo.State -eq 'Running') { $script:OpPS.Stop() }
        if ($null -ne $script:OpPS) { $script:OpPS.Dispose() }
    } catch { }
    try { if ($null -ne $script:OpMeas.PS) { $script:OpMeas.PS.Dispose() } } catch { }
    $script:OpPS = $null
    $script:OpAsyncResult = $null
    $script:OpMeas.Busy = $false
    $script:OpMeas.PS = $null
    $script:OpMeas.Ar = $null
    $script:OpMeas.CachePath = $null
}

function Invoke-StopOperationManual {
    <#
      手动终止当前任务，然后从断点自动续传。

      直接杀 robocopy /MOVE 会让数据分居两侧（部分已复制到缓存、部分还在
      源盘），因此终止不是终点：杀完进程后用同一批参数重新拉起任务，
      worker 的续传分支会对每个目录做判定——
        已是联接点        -> 秒级跳过（之前已完成）
        源+缓存都有数据    -> robocopy /E /MOVE 幂等续传，补齐后建联接
        全新目录          -> 正常提升/回写
    #>
    if (-not $state.OpBusy) { return }
    if ($script:OpStopping) { return }

    $modeText = $(if ($script:OpMode -eq 'Promote') { '提升' } else { '回写' })
    $ans = [System.Windows.Forms.MessageBox]::Show(
        ("将终止当前的{0}任务。`n`n数据安全流程：`n1. 停止任务并结束复制进程；`n2. 自动从断点续传：已复制部分保留，剩余部分补齐后建立联接（提升）或完成写回（回写）；`n3. 不会丢失任何数据。`n`n是否终止？" -f $modeText),
        '终止任务', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $script:OpStopping = $true
    try {
        Write-Log '正在终止任务……' '警告'
        # 1) 请求 worker 管线停止
        try {
            if ($null -ne $script:OpPS -and $script:OpPS.InvocationStateInfo.State -eq 'Running') { $script:OpPS.Stop() }
        } catch { }

        # 2) 按命令行里的日志路径精确匹配本操作的 robocopy 并结束。
        #    管线完全停下之前 worker 可能又拉起一个新的 robocopy，
        #    因此循环清除直到连续一轮无匹配。
        $logFile = ''
        if ($script:OpCacheRoot) { $logFile = Join-Path $script:OpCacheRoot 'ssdcache.log' }
        if ($logFile) {
            for ($attempt = 0; $attempt -lt 6; $attempt++) {
                $killed = $false
                $procs = @()
                try { $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'robocopy.exe'" -ErrorAction Stop) } catch { }
                foreach ($proc in $procs) {
                    if ($proc.CommandLine -and $proc.CommandLine.Contains($logFile)) {
                        try {
                            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
                            $killed = $true
                            Write-Log ("已结束复制进程 (PID {0})。" -f $proc.ProcessId) '警告'
                        } catch { }
                    }
                }
                if (-not $killed) { break }
                Start-Sleep -Milliseconds 400
            }
        }

        # 3) 复位运行时并重启同一任务（续传接管）
        Reset-OpRuntime
        $state.OpBusy = $false
        $script:OpStatusLabel.Text = '已手动终止，正在从断点恢复……'
    } finally {
        $script:OpStopping = $false
    }

    # 从进度文本解析被中断的目录，作为显式续传候选
    $resumePaths = $null
    if ($script:OpCurDirText) {
        $cand = ($script:OpCurDirText -replace '^\[[^\]]+\]\s*', '' -replace '^续传\s*', '')
        if ($cand) { $resumePaths = @($cand) }
    }

    Write-Log ('正在从断点恢复{0}任务（已完成目录自动跳过，被中断目录补齐数据）……' -f $modeText) '警告'
    Start-Operation -Mode $script:OpMode -Paths $script:OpPaths -Root $script:OpCacheRoot -Sizes $script:OpSizes -Counts $script:OpCounts -TotalBytes $script:OpTotalBytes -ResumePaths $resumePaths
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
        [long[]]$Counts,
        [long]$TotalBytes = 0,
        [string[]]$ResumePaths
    )

    if ($state.OpBusy) { Write-Log '已有任务在执行。' '警告'; return }
    $state.OpBusy = $true
    $script:OpMode = $Mode
    $script:OpCacheRoot = $Root
    $script:OpPaths = $Paths
    $script:OpSizes = $Sizes
    $script:OpCounts = $Counts
    $script:OpResumePaths = $ResumePaths
    $script:OpProgressRead = 0
    $script:OpCurDirText = ''
    $script:OpCurDirPath = ''
    $script:OpMeasLogged = $false
    $script:OpMeasStartLogged = $false
    $script:OpLastSizeAt = [DateTime]::MinValue
    $script:OpTotalBytes = $TotalBytes
    $script:OpTotalFiles = [int64]0
    if ($null -ne $Counts) {
        foreach ($c in $Counts) { $script:OpTotalFiles += [int64]$c }
    }
    $script:OpMeas = @{ Busy = $false; PS = $null; Ar = $null; CachePath = $null; SizeBytes = [int64]0; FileTotal = [int64]0; FilesDoneBase = [int64]0; DoneBytes = [int64]0; LatestFile = ''; LastShown = '' }

    Set-OpUi -Busy $true
    $modeText = $(if ($Mode -eq 'Promote') { '提升到 SSD' } else { '回写机械盘' })
    $script:OpStatusLabel.Text = "准备中..."
    # 立即把涉及路径放进清单（状态：正在缓存 / 正在回写）
    try { Add-InventoryPending -Mode $Mode -Paths $Paths } catch { }
    Write-Log ("开始{0}，共 {1} 个目录，{2}。" -f $modeText, $Paths.Count, (Format-SizeGB $TotalBytes))

    # worker 逻辑：here-string 保存（单引号不插值），运行时与库源文本拼接。
    # 拼接顺序：param 行 -> 库源（Set-StrictMode + 全部函数定义）-> 任务体。
    # 库源里的 $script: 变量赋值会在 worker runspace 顶层执行，函数运行时
    # 引用它们自洽，无需 Import-Module。
    $workerBody = @'
$out = New-Object System.Collections.Generic.List[object]
$total = @($paths).Count
$done = [int64]0
$doneFiles = [int64]0
$resumeList = @()
if ($null -ne $resume) { $resumeList = @($resume) }
$log = $null
if ($root) { $log = Join-Path $root 'ssdcache.log' }
for ($i = 0; $i -lt $total; $i++) {
    $p = @($paths)[$i]
    $sz = [int64]0
    if ($null -ne $sizes -and $i -lt @($sizes).Count) { $sz = [int64]@($sizes)[$i] }
    $cnt = [int64]0
    if ($null -ne $counts -and $i -lt @($counts).Count) { $cnt = [int64]@($counts)[$i] }
    $pct = [int](100 * $i / [Math]::Max($total, 1))
    try {
        if ($mode -eq 'Promote') {
            $cp = Get-CachePathFor -SourcePath $p -Root $root
            $resumed = $false
            # 续传仅对显式候选（手动终止时正在处理的目录）生效：
            # 缓存路径已存在也可能是子目录提升留下的宿主目录，不能据此判定为续传。
            $isResume = $resumeList -contains $p
            if ($isResume -and -not (Test-Junction -LiteralPath $p) -and (Test-Path -LiteralPath $cp)) {
                # 断点续传：上次任务被手动终止，缓存目录已有部分数据。
                # robocopy /E /MOVE 幂等：已复制的跳过，源侧剩余补齐，随后补建联接。
                Write-Progress -Id 1 -Activity 'Promote' -Status ("[{0}/{1}] 续传 {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}|{3}|{4}" -f $cp, $sz, $done, $cnt, $doneFiles) -PercentComplete $pct
                if (Test-Path -LiteralPath $p) {
                    $mv = Invoke-RoboMove -From $p -To $cp -LogPath $log
                    if (-not $mv.Success) { throw ("续传失败（robocopy 代码 {0}）。数据分居两侧：{1} <-> {2}" -f $mv.Code, $p, $cp) }
                }
                New-MarkerFile -CachePath $cp -OriginalPath $p
                if (Test-Path -LiteralPath $p) {
                    # 指向自身缓存路径内部的子联接可安全删除：数据已在缓存里，
                    # 父联接建立后经父路径解析到同一位置。
                    $kids = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
                    foreach ($k in $kids) {
                        if (($k.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                            $kt = $null
                            try { $kt = Get-JunctionTarget -LiteralPath $k.FullName } catch { $kt = $null }
                            if ($kt -and $kt.StartsWith($cp, [StringComparison]::OrdinalIgnoreCase)) {
                                # 用 .NET API 而非 Remove-Item：终端防护会否决 cmdlet 删除重解析点
                                try { [System.IO.Directory]::Delete($k.FullName, $false) } catch { }
                            }
                        }
                    }
                    $left = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
                    if ($left.Count -eq 0) {
                        try { Remove-Item -LiteralPath $p -Force -Recurse -ErrorAction SilentlyContinue } catch { }
                        if (Test-Path -LiteralPath $p) { try { [System.IO.Directory]::Delete($p, $false) } catch { } }
                    }
                }
                if (-not (Test-Junction -LiteralPath $p)) {
                    try {
                        New-Item -ItemType Junction -Path $p -Value $cp -ErrorAction Stop | Out-Null
                    } catch {
                        $rb = Invoke-RoboMove -From $cp -To $p -LogPath $log
                        $keepNote = ''
                        if ($rb.Success) {
                            # 绝不在缓存树仍有文件时递归删除：源端含指向缓存内部的
                            # 子联接时数据无法写回，盲目删除会造成不可恢复的数据丢失。
                            $leftFiles = @(Get-ChildItem -LiteralPath $cp -Recurse -File -Force -ErrorAction SilentlyContinue)
                            if ($leftFiles.Count -eq 0) {
                                Remove-Item -LiteralPath $cp -Recurse -Force -ErrorAction SilentlyContinue
                            } else {
                                $keepNote = (" 部分数据无法写回，已保留在缓存中，请勿删除：{0}" -f $cp)
                            }
                        }
                        throw ("续传后建联接失败，数据已回滚到 {0}。{1} 原因: {2}" -f $p, $keepNote, $_.Exception.Message)
                    }
                }
                $done += $sz
                $doneFiles += $cnt
                $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = $false; SizeBytes = [int64]$sz; Message = '已从断点续传完成提升。'; CacheCleanupError = $null })
                $resumed = $true
            }
            if (-not $resumed) {
                # CurrentOperation 编码供 UI 侧测量: 缓存路径|本目录字节|此前已完成字节|本目录文件数|此前已完成文件数
                Write-Progress -Id 1 -Activity 'Promote' -Status ("[{0}/{1}] {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}|{3}|{4}" -f $cp, $sz, $done, $cnt, $doneFiles) -PercentComplete $pct
                $r = Invoke-CachePromote -SourcePath $p -CacheRoot $root
                $done += $sz
                $doneFiles += $cnt
                $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = $r.AlreadyCached; SizeBytes = $r.SizeBytes; Message = $r.Message; CacheCleanupError = $null })
            }
        } else {
            if (-not (Test-Junction -LiteralPath $p)) {
                $cp = Get-CachePathFor -SourcePath $p -Root $root
                if (Test-Path -LiteralPath $cp) {
                    # 断点续传（回写）：联接点已被拆除但数据分居两侧。
                    # 仅当缓存目录的标记文件（或回写前被移入 TEMP 的标记）确认归属时才继续，
                    # 防止把无关目录误搬进用户文件夹。
                    Write-Progress -Id 1 -Activity 'Demote' -Status ("[{0}/{1}] 续传 {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}" -f $p, $sz, $done) -PercentComplete $pct
                    $meta = $null
                    $marker = Join-Path $cp (Get-MarkerName)
                    if (Test-Path -LiteralPath $marker) {
                        try { $meta = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json } catch { $meta = $null }
                    }
                    if ($null -eq $meta) {
                        $parked = @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'ssdcache_marker_*.json' -File -ErrorAction SilentlyContinue)
                        foreach ($f in $parked) {
                            try {
                                $m2 = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
                                if ($m2.OriginalPath -eq $p) { $meta = $m2; break }
                            } catch { }
                        }
                    }
                    if ($null -eq $meta -or $meta.OriginalPath -ne $p) {
                        throw ("缓存目录存在但标记无法确认归属，拒绝续传以免误搬数据: {0}" -f $cp)
                    }
                    $mv = Invoke-RoboMove -From $cp -To $p -LogPath $log
                    if (-not $mv.Success) { throw ("回写续传失败（robocopy 代码 {0}）。数据保留在缓存 {1}" -f $mv.Code, $cp) }
                    $null = Remove-LeakedMarkers -Root $p
                    Remove-CacheFolderSafe -LiteralPath $cp | Out-Null
                    if ($root) { Remove-EmptyParents -StartDir (Split-Path -Parent $cp) -Root $root | Out-Null }
                    $done += $sz
                    $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = $false; SizeBytes = [int64]$sz; Message = '已从断点续传完成回写。'; CacheCleanupError = $null })
                } else {
                    Write-Progress -Id 1 -Activity 'Demote' -Status ("[{0}/{1}] {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}" -f $p, $sz, $done) -PercentComplete $pct
                    $done += $sz
                    $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = $true; SizeBytes = [int64]0; Message = '不是联接点且无缓存残留，跳过。'; CacheCleanupError = $null })
                }
            } else {
                Write-Progress -Id 1 -Activity 'Demote' -Status ("[{0}/{1}] {2}" -f ($i + 1), $total, $p) -CurrentOperation ("{0}|{1}|{2}" -f $p, $sz, $done) -PercentComplete $pct
                $r = Invoke-CacheDemote -SourcePath $p -CacheRoot $root
                $done += $sz
                $out.Add([pscustomobject]@{ Path = $p; Success = $true; AlreadyCached = (-not $r.WasCached); SizeBytes = $r.SizeBytes; Message = $r.Message; CacheCleanupError = $r.CacheCleanupError })
            }
        }
    } catch {
        $out.Add([pscustomobject]@{ Path = $p; Success = $false; AlreadyCached = $false; SizeBytes = [int64]0; Message = $_.Exception.Message; CacheCleanupError = $null })
    }
}
Write-Progress -Id 1 -Activity 'SSD' -Completed
return $out.ToArray()
'@
    $opScript = 'param($mode, $paths, $root, $sizes, $counts, $resume)' + [Environment]::NewLine + $script:LibSource + [Environment]::NewLine + $workerBody

    $ps = [powershell]::Create()
    $null = $ps.AddScript($opScript)
    $null = $ps.AddArgument($Mode)
    $null = $ps.AddArgument($Paths)
    $null = $ps.AddArgument($Root)
    $null = $ps.AddArgument($Sizes)
    $null = $ps.AddArgument($Counts)
    $null = $ps.AddArgument($ResumePaths)

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
      runspace 每 3 秒一次（节流由 Poll-Operation 用 OpLastSizeAt 控制），
      开销可控且两不干扰。

      必须置 Busy = $true：Poll-Operation 只在 Busy 期间消费测量结果，
      漏掉它会让测量值永远无法反映到进度条上。
    #>
    param([string]$Dir)

    $measureScript = 'param($measureDir)' + [Environment]::NewLine + $script:LibSource + [Environment]::NewLine + 'Get-DirStats -LiteralPath $measureDir'
    $ps = [powershell]::Create()
    $null = $ps.AddScript($measureScript)
    $null = $ps.AddArgument($Dir)
    $script:OpMeas.PS = $ps
    $script:OpMeas.Busy = $true
    try {
        $script:OpMeas.Ar = $ps.BeginInvoke()
    } catch {
        # BeginInvoke 同步失败：不让异常冒到 Poll 的兜底 catch（那会直接结束任务），
        # 复位状态并记一次日志，下一轮再试。
        $script:OpMeas.Busy = $false
        $script:OpMeas.PS = $null
        $script:OpMeas.Ar = $null
        if (-not $script:OpMeasLogged) {
            $script:OpMeasLogged = $true
            Write-Log ("进度测量无法启动（详细文件进度不可用）：" + $_.Exception.Message) '警告'
        }
        return
    }
    if (-not $script:OpMeasStartLogged) {
        $script:OpMeasStartLogged = $true
        Write-Log ("进度测量已启动：{0}" -f $Dir)
    }
}

function Poll-Operation {
    <# UI 线程 Timer：读取 worker 的进度流、周期测量已迁移大小、收取结果。 #>
    try {
        if ($null -eq $script:OpPS) { return }

        # 1) 消费新增的进度记录
        #
        #    只认本任务自己写的记录（-Id 1 且 Activity 为 Promote/Demote）。
        #    runspace 里模块自动加载也会写进度记录：实测出现过
        #       ActivityId=0        「正在准备首次使用模块。」
        #       ActivityId=509923147「Get-Volume -DriveLetter ... / 已完成 1/1」
        #    这些记录的 CurrentOperation 是空的。如果按"本 tick 最后一条"解析，
        #    当它们与我们的记录落在同一个 700ms 窗口内时，缓存路径永远拿不到，
        #    后台测量一次都不会启动 —— 表现为进度条恒 0%、文件数空白、
        #    明细行显示"已完成 1/1"。这就是本 bug 的根因。
        $prog = $script:OpPS.Streams.Progress
        $opText = $(if ($script:OpMode -eq 'Promote') { '提升' } else { '回写' })
        while ($script:OpProgressRead -lt @($prog).Count) {
            $rec = $prog[$script:OpProgressRead]
            $script:OpProgressRead++
            if ($null -eq $rec) { continue }
            if ($rec.ActivityId -ne 1) { continue }
            if ($rec.Activity -ne 'Promote' -and $rec.Activity -ne 'Demote') { continue }

            # 目录序号与源路径：StatusDescription 形如 "[1/2] F:\Game\X" 或 "[1/2] 续传 F:\Game\X"
            if ($rec.StatusDescription) {
                $script:OpCurDirText = $rec.StatusDescription
                if ($rec.StatusDescription -match '^\[(\d+)/(\d+)\]\s*(?:续传\s*)?(.+)$') {
                    $script:OpCurDirPath = $matches[3].Trim()
                    $script:OpStatusLabel.Text = ("{0} 中   第 {1}/{2} 个目录 {3}" -f $opText, $matches[1], $matches[2], $script:OpCurDirPath)
                }
            }

            # 编码串：缓存路径|本目录字节|此前已完成字节|本目录文件数|此前已完成文件数
            if ($rec.CurrentOperation -and $rec.CurrentOperation.Contains('|')) {
                $parts = ($rec.CurrentOperation -split '\|')
                if ($parts.Count -ge 3) {
                    if ($parts[0] -ne $script:OpMeas.CachePath) { $script:OpMeas.LatestFile = '' }
                    $script:OpMeas.CachePath = $parts[0]
                    $script:OpMeas.SizeBytes = [int64]$parts[1]
                    $script:OpMeas.DoneBytes = [int64]$parts[2]
                }
                if ($parts.Count -ge 5) {
                    $script:OpMeas.FileTotal = [int64]$parts[3]
                    $script:OpMeas.FilesDoneBase = [int64]$parts[4]
                }
            }
        }

        # 2) 测量目标：优先用 worker 编码的缓存路径；缺失时由 UI 自己推导，
        #    避免任何一条记录的字段异常把整条进度链路掐死。
        $m = $script:OpMeas
        if (-not $m.CachePath -and $script:OpCurDirPath) {
            if ($script:OpMode -eq 'Promote') {
                try { $m.CachePath = Get-CachePathFor -SourcePath $script:OpCurDirPath -Root $script:OpCacheRoot } catch { }
            } else {
                $m.CachePath = $script:OpCurDirPath
            }
        }

        # 3) 数据量进度：后台测量"当前目录已写入量"，与已完成字节合并
        if ($m.Busy -and $null -ne $m.Ar -and $m.Ar.IsCompleted) {
            $mSize = [int64]0
            $mFiles = [int64]0
            $mCurFile = ''
            try {
                $tmp = $m.PS.EndInvoke($m.Ar)
                if ($null -ne $tmp) { $tmp = @($tmp)[0] }
                if ($null -ne $tmp) {
                    $pSize = $tmp.PSObject.Properties['SizeBytes']
                    $pFiles = $tmp.PSObject.Properties['FileCount']
                    $pNewest = $tmp.PSObject.Properties['NewestFile']
                    if ($pSize) { $mSize = [int64]$pSize.Value }
                    if ($pFiles) { $mFiles = [int64]$pFiles.Value }
                    if ($pNewest -and $pNewest.Value) { $mCurFile = [string]$pNewest.Value }
                }
            } catch {
                $mSize = [int64]0; $mFiles = [int64]0; $mCurFile = ''
                if (-not $script:OpMeasLogged) {
                    $script:OpMeasLogged = $true
                    Write-Log ("进度测量失败（详细文件进度不可用）：" + $_.Exception.Message) '警告'
                }
            }
            if ($mCurFile) { $m.LatestFile = $mCurFile } else { $mCurFile = [string]$m.LatestFile }
            try { $m.PS.Dispose() } catch { }
            $m.PS = $null; $m.Ar = $null; $m.Busy = $false

            if ($script:OpMode -eq 'Promote' -and $script:OpTotalBytes -gt 0) {
                $doneAll = $m.DoneBytes + [Math]::Min($mSize, $m.SizeBytes)
                $pct = [int](100 * $doneAll / $script:OpTotalBytes)
                $pct = [Math]::Min(99, [Math]::Max(0, $pct))
                $script:ProgressBar.Value = $pct
                $script:PercentLabel.Text = ("{0}%" -f $pct)
                # 右侧合计：字节 + 全部所选目录的文件数进度
                $cntText = ("已迁移 {0} / {1}" -f (Format-SizeGB $doneAll), (Format-SizeGB $script:OpTotalBytes))
                if ($script:OpTotalFiles -gt 0) {
                    $curFiles = [Math]::Min($mFiles, $m.FileTotal)
                    $allFiles = [int64]$m.FilesDoneBase + $curFiles
                    $cntText += (" · 文件 {0} / {1}" -f $allFiles, $script:OpTotalFiles)
                }
                $script:CountLabel.Text = $cntText
                # 明细行：目录序号 + 本目录文件进度 + 正在复制的文件名
                $leaf = ''
                if ($mCurFile) { try { $leaf = [IO.Path]::GetFileName($mCurFile) } catch { $leaf = $mCurFile } }
                $curFileText = ''
                if ($leaf) { $curFileText = ' · 正在复制 ' + (Format-ShortName $leaf 48) }
                $filesText = ''
                if ($m.FileTotal -gt 0) {
                    $filesText = (" · 本目录文件 {0}/{1}" -f [Math]::Min($mFiles, $m.FileTotal), $m.FileTotal)
                }
                $shown = ("{0}中 {1}{2}{3}" -f $opText, $script:OpCurDirText, $filesText, $curFileText)
                if ($shown -ne $m.LastShown) {
                    $m.LastShown = $shown
                    $script:OpStatusLabel.Text = $shown
                }
            } elseif ($script:OpMode -eq 'Demote') {
                # 回写同样按数据量推进进度条（此前回写期间进度条一直是 0%）
                $doneAll = $m.DoneBytes + [Math]::Min($mSize, $m.SizeBytes)
                if ($script:OpTotalBytes -gt 0) {
                    $pct = [int](100 * $doneAll / $script:OpTotalBytes)
                    $pct = [Math]::Min(99, [Math]::Max(0, $pct))
                    $script:ProgressBar.Value = $pct
                    $script:PercentLabel.Text = ("{0}%" -f $pct)
                }
                $script:CountLabel.Text = ("已恢复 {0} / {1} · 文件 {2}" -f (Format-SizeGB $doneAll), (Format-SizeGB $script:OpTotalBytes), $mFiles)
                $leaf = ''
                if ($mCurFile) { try { $leaf = [IO.Path]::GetFileName($mCurFile) } catch { $leaf = $mCurFile } }
                $curFileText = ''
                if ($leaf) { $curFileText = ' · 正在写回 ' + (Format-ShortName $leaf 48) }
                $shown = ("回写中 {0}{1}" -f $script:OpCurDirText, $curFileText)
                if ($shown -ne $m.LastShown) {
                    $m.LastShown = $shown
                    $script:OpStatusLabel.Text = $shown
                }
            }
        }
        if (-not $m.Busy -and $m.CachePath -and ((Get-Date) - $script:OpLastSizeAt).TotalSeconds -ge 2 -and (Test-Path -LiteralPath $m.CachePath)) {
            $script:OpLastSizeAt = Get-Date
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

    Reset-OpRuntime
    $state.OpBusy = $false

    $okCount = 0
    $failCount = 0
    foreach ($r in @($Results)) {
        if ($r.Success) {
            if ($r.AlreadyCached) {
                Write-Log ("{0}：已是缓存目录，跳过。" -f $r.Path) '警告'
            } else {
                Write-Log ("{0}：{1}" -f $r.Path, $r.Message) '完成'
                # 防御式读取：exe 内联库源后 Set-StrictMode 作用于全局，
                # 直接访问不存在的属性会抛错并中断整个收尾流程。
                $ccErr = $null
                $ccProp = $r.PSObject.Properties['CacheCleanupError']
                if ($ccProp) { $ccErr = $ccProp.Value }
                if ($ccErr) {
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
    $script:PercentLabel.Text = '100%'
    $script:CountLabel.Text = ''
    $script:OpStatusLabel.Text = "完成：成功 $okCount / 失败 $failCount"

    try { Complete-InventoryPending -Mode $script:OpMode -Results $Results } catch { }
    Set-OpUi -Busy $false
    Build-Tree
    Refresh-Inventory
}

function Stop-Operation {
    <# 窗体关闭时中止长任务。 #>
    Reset-OpRuntime
    Stop-InventoryScan
}

function Invoke-PromoteSelected {
    $checked = @(Get-CheckedPaths)
    if ($checked.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('请先在目录树中勾选至少一个文件夹。', '未选择任何项') | Out-Null
        return
    }

    # 只保留最顶层勾选：父目录被提升时子目录随数据一起进入缓存；
    # 逐个提升会在父子之间产生联接/缓存路径冲突（F:\Books 案例的根因）。
    $topLevel = @()
    foreach ($c in $checked) {
        $isDescendant = $false
        $cp2 = $c.Path.TrimEnd('\')
        foreach ($o in $checked) {
            if ($o.Path -ne $c.Path) {
                $op2 = $o.Path.TrimEnd('\')
                if ($cp2.StartsWith($op2 + '\', [StringComparison]::OrdinalIgnoreCase)) { $isDescendant = $true; break }
            }
        }
        if (-not $isDescendant) { $topLevel += $c }
    }
    $checked = @($topLevel)

    # 已被缓存中的父联接覆盖的目录跳过（数据已在 SSD 上）
    $notCovered = @()
    foreach ($c in $checked) {
        $covered = $false
        $node = Split-Path -Parent $c.Path.TrimEnd('\')
        while ($node -and $node.Length -gt 3) {
            if (Test-Junction -LiteralPath $node) { $covered = $true; break }
            $node = Split-Path -Parent $node
        }
        if (-not $covered) { $notCovered += $c }
    }
    if ($notCovered.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('所选目录已通过其父目录处于加速状态，无需重复提升。', '无需提升') | Out-Null
        return
    }
    $checked = @($notCovered)

    $root = $script:CacheRootBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($root)) {
        [System.Windows.Forms.MessageBox]::Show('请先设置缓存根目录。', '缺少缓存根目录') | Out-Null
        return
    }

    Write-Log '正在统计所选文件夹大小（大目录可能需要一些时间）...'
    [System.Windows.Forms.Application]::DoEvents()

    # 一次遍历同时拿到大小与文件数：大小用于总进度，文件数用于逐文件进度。
    $paths = New-Object System.Collections.Generic.List[string]
    $sizes = New-Object System.Collections.Generic.List[long]
    $counts = New-Object System.Collections.Generic.List[long]
    $lines = @()
    $grand = 0
    foreach ($c in $checked) {
        $sz = [int64]0
        $cnt = [int64]0
        try {
            $st = Get-DirStats -LiteralPath $c.Path
            $sz = [int64]$st.SizeBytes
            $cnt = [int64]$st.FileCount
            $lines += ("  {0}   {1}（{2} 个文件）" -f $c.Path, (Format-SizeGB $sz), $cnt)
        } catch {
            $lines += ("  {0}   （无法读取）" -f $c.Path)
        }
        $grand += $sz
        $paths.Add([string]$c.Path)
        $sizes.Add($sz)
        $counts.Add($cnt)
        [System.Windows.Forms.Application]::DoEvents()
    }

    $msg = "缓存根目录：$root`n`n将提升以下文件夹（后台执行，期间可继续操作界面）：`n" + ($lines -join "`n") + "`n`n合计：{0}`n`n是否继续？" -f (Format-SizeGB $grand)
    $ans = [System.Windows.Forms.MessageBox]::Show($msg, '确认提升', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -ne [System.Windows.Forms.DialogResult]::OK) { Write-Log '已取消提升。'; return }

    Start-Operation -Mode 'Promote' -Paths $paths.ToArray() -Root $root -Sizes $sizes.ToArray() -Counts $counts.ToArray() -TotalBytes $grand
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
    # 只回写最顶层联接：子联接的数据位于父缓存目录内部，回写父目录时一并恢复；
    # 先回写子联接会掏空父缓存目录，随后父目录回写会报「目标丢失」。
    $topMost = @()
    foreach ($p in $cached) {
        $isDescendant = $false
        $pn = $p.TrimEnd('\')
        foreach ($q in $cached) {
            if ($q -ne $p -and $pn.StartsWith($q.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $isDescendant = $true; break }
        }
        if (-not $isDescendant) { $topMost += $p }
    }
    $cached = @($topMost)
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
    if (-not (Test-Path -LiteralPath $script:LibPath)) {
        throw ("未找到核心模块：{0}" -f $script:LibPath)
    }
    Import-Module $script:LibPath -Force

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
# 每一步独立 try/catch：exe 内联库源后 Set-StrictMode 作用于全局，
# 前面任何一步抛错都会吞掉后续步骤——曾导致打开时自动扫描不执行。
$form.add_Shown({
    # 版本 + 运行文件：远程排查先确认"跑的是哪个构建"（标题栏同样带版本号）
    try {
        $runPath = ''
        try { $runPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
        if (-not $runPath) { try { $runPath = $PSCommandPath } catch { $runPath = '未知' } }
        Write-Log ("SSD 缓存管理器 v{0} 启动（PowerShell {1}，运行文件：{2}）" -f $script:AppVersion, $PSVersionTable.PSVersion, $runPath)
    } catch { }
    # 先显示上次扫描的快照（秒开），再启动后台全量扫描校正
    try {
        $snap = @(Load-InventoryCache)
        if ($snap.Count -gt 0) {
            Update-InventoryUi -Items $snap
            Write-Log ("已从本地快照载入 {0} 个缓存目录，正在后台校正…" -f $snap.Count)
        }
    } catch { }
    try { Refresh-Inventory } catch { Write-Log ("启动扫描失败：" + $_.Exception.Message) '错误' }
    try { Apply-SplitterDistances -Form $form } catch { }
    try { Build-Tree } catch { }
    Write-Log '就绪。已开始后台扫描缓存目录，可展开磁盘并勾选要加速的文件夹。'
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