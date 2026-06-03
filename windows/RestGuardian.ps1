Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

$script:HardMaxWorkMinutes = 50
$script:ProtectedRestSeconds = 5 * 60
$script:PauseRecoveryMultiplier = 5
$script:DataDir = Join-Path $env:APPDATA "Rest Guardian"
$script:SettingsPath = Join-Path $script:DataDir "rest-guardian-settings.json"
$script:LogPath = Join-Path $script:DataDir "rest-guardian-log.jsonl"

$script:Settings = $null
$script:Mode = "work"
$script:RemainingSeconds = 0
$script:SessionTotalSeconds = 0
$script:ContinuousWorkSeconds = 0
$script:RestElapsedSeconds = 0
$script:PauseElapsedSeconds = 0
$script:PauseRecoveredSeconds = 0
$script:PauseReducedContinuousSeconds = 0
$script:ManualWorkExtensionSeconds = 0
$script:ManualRestUndoSeconds = 0
$script:PausedWorkSecondsBeforeManualRest = 0
$script:PausedContinuousWorkSecondsBeforeManualRest = 0
$script:PausedManualWorkExtensionSecondsBeforeManualRest = 0
$script:Timer = $null
$script:TimerWindow = $null
$script:ModeLabel = $null
$script:CountdownLabel = $null
$script:AddOneButton = $null
$script:RestWindow = $null
$script:RestCountdownLabel = $null
$script:RestSuggestionLabel = $null
$script:ReturnToWorkButton = $null
$script:ManualRestUndoButton = $null
$script:SettingsWindow = $null
$script:ReminderWindow = $null
$script:ReminderTimer = $null
$script:WorkReminderIndex = 0
$script:RestSuggestionIndex = 0

$script:WorkExtensionMessages = @(
    "好，借你一分钟。椅子先记账。",
    "续一小口可以，别把休息鸽太久。",
    "这一分钟是加班券，用完要还给身体。",
    "可以，再敲一分钟，眼睛已经在旁边记小本了。",
    "加时成功，但腰背申请稍后开会。",
    "一分钟而已，但别让它变成连续剧。",
    "行，再冲一下。到点就别和休息讨价还价了。",
    "屏幕说还能顶，身体说你最好想清楚。",
    "加一。请珍惜这张临时通行证。",
    "这一分钟属于特别审批，不是无限续杯。"
)

$script:RestSuggestions = @(
    "离开屏幕，去当五分钟线下人类。",
    "给水杯一个被使用的机会。",
    "去厕所也算高质量中断。",
    "抬头看远处，别让眼睛继续加班。",
    "站起来伸个懒腰，身体不是外设。",
    "什么都不做也可以，大脑需要清缓存。",
    "在房间里走一圈，证明你还会离开椅子。",
    "把肩膀放下来，别一直端着。",
    "去窗边看看，外面的世界还在加载。",
    "起身晃两步，给血液一点存在感。",
    "摸一下水杯，它可能已经等你很久了。",
    "离开键盘，双手也想下班五分钟。",
    "看远一点，别把世界缩成这块屏幕。",
    "站起来，椅子也需要私人空间。",
    "去接点水，顺便刷新一下自己。",
    "闭眼十秒，假装系统正在维护。",
    "走到门口再回来，算一次短途旅行。",
    "给脖子转个弯，它不是固定支架。",
    "别急着回去，灵感通常不住在屏幕里。",
    "现在的任务：不操作任何电子设备。",
    "喝水、走路、发呆，任选一个低配幸福。",
    "让眼睛看看真实分辨率的世界。"
)

function New-ColorBrush {
    param([byte]$A, [byte]$R, [byte]$G, [byte]$B)
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($A, $R, $G, $B))
}

function Format-Time {
    param([int]$Seconds)
    $safe = [Math]::Max(0, $Seconds)
    $minutes = [Math]::Floor($safe / 60)
    $secondsLeft = $safe % 60
    return "{0:00}:{1:00}" -f $minutes, $secondsLeft
}

function Normalize-Settings {
    param([int]$WorkMinutes, [int]$RestMinutes, [int]$MaxWorkMinutes)
    $work = [Math]::Min($script:HardMaxWorkMinutes, [Math]::Max(1, $WorkMinutes))
    $rest = [Math]::Min(120, [Math]::Max(5, $RestMinutes))
    $maxWork = [Math]::Min($script:HardMaxWorkMinutes, [Math]::Max($work, $MaxWorkMinutes))
    return [pscustomobject]@{
        WorkMinutes = $work
        RestMinutes = $rest
        MaxWorkMinutes = $maxWork
    }
}

function Get-DefaultSettings {
    return Normalize-Settings -WorkMinutes 25 -RestMinutes 5 -MaxWorkMinutes 50
}

function Load-Settings {
    if (Test-Path $script:SettingsPath) {
        try {
            $stored = Get-Content -Raw -Path $script:SettingsPath | ConvertFrom-Json
            return Normalize-Settings -WorkMinutes ([int]$stored.WorkMinutes) -RestMinutes ([int]$stored.RestMinutes) -MaxWorkMinutes ([int]$stored.MaxWorkMinutes)
        } catch {
            return Get-DefaultSettings
        }
    }
    return Get-DefaultSettings
}

function Save-Settings {
    param($Settings)
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    }
    $Settings | ConvertTo-Json | Set-Content -Path $script:SettingsPath -Encoding UTF8
}

function Write-GuardianLog {
    param([string]$Event, [hashtable]$Details = @{})
    if (-not (Test-Path $script:DataDir)) {
        New-Item -ItemType Directory -Force -Path $script:DataDir | Out-Null
    }
    $entry = [pscustomobject]@{
        timestamp = (Get-Date).ToString("o")
        event = $Event
        mode = $script:Mode
        remainingSeconds = $script:RemainingSeconds
        details = $Details
    }
    Add-Content -Path $script:LogPath -Value ($entry | ConvertTo-Json -Compress) -Encoding UTF8
}

function New-Label {
    param(
        [string]$Text,
        [double]$Size,
        [string]$Weight = "Normal",
        $Brush = $null
    )
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.FontSize = $Size
    $label.FontFamily = "Microsoft YaHei UI"
    $label.FontWeight = if ($Weight -eq "Bold") { [System.Windows.FontWeights]::Bold } elseif ($Weight -eq "SemiBold") { [System.Windows.FontWeights]::SemiBold } else { [System.Windows.FontWeights]::Normal }
    $label.VerticalAlignment = "Center"
    $label.HorizontalAlignment = "Center"
    if ($Brush) { $label.Foreground = $Brush }
    return $label
}

function New-Button {
    param([string]$Text, [scriptblock]$OnClick, [double]$FontSize = 13)
    $button = New-Object System.Windows.Controls.Button
    $button.Content = $Text
    $button.FontFamily = "Microsoft YaHei UI"
    $button.FontSize = $FontSize
    $button.FontWeight = [System.Windows.FontWeights]::SemiBold
    $button.Margin = "5,0,0,0"
    $button.Padding = "12,5,12,5"
    $button.MinWidth = 48
    $button.Add_Click($OnClick)
    return $button
}

function Place-TopWindow {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $script:TimerWindow.Left = $workArea.Left + (($workArea.Width - $script:TimerWindow.Width) / 2)
    $script:TimerWindow.Top = $workArea.Top + 8
}

function Build-TimerWindow {
    $window = New-Object System.Windows.Window
    $window.Width = 430
    $window.Height = 48
    $window.WindowStyle = "None"
    $window.ResizeMode = "NoResize"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "22"
    $border.Padding = "14,7,12,7"
    $border.Background = New-ColorBrush 224 55 57 62

    $panel = New-Object System.Windows.Controls.DockPanel
    $panel.LastChildFill = $false

    $script:ModeLabel = New-Label "工作" 15 "SemiBold" (New-ColorBrush 255 255 167 38)
    $script:ModeLabel.Margin = "0,0,12,0"
    [System.Windows.Controls.DockPanel]::SetDock($script:ModeLabel, "Left")
    $panel.Children.Add($script:ModeLabel) | Out-Null

    $script:CountdownLabel = New-Label "25:00" 26 "Bold" (New-ColorBrush 255 255 255 255)
    $script:CountdownLabel.Margin = "0,0,22,0"
    [System.Windows.Controls.DockPanel]::SetDock($script:CountdownLabel, "Left")
    $panel.Children.Add($script:CountdownLabel) | Out-Null

    $quitButton = New-Button "×" { Close-App } 16
    [System.Windows.Controls.DockPanel]::SetDock($quitButton, "Right")
    $panel.Children.Add($quitButton) | Out-Null

    $settingsButton = New-Button "设置" { Show-SettingsWindow } 13
    [System.Windows.Controls.DockPanel]::SetDock($settingsButton, "Right")
    $panel.Children.Add($settingsButton) | Out-Null

    $restButton = New-Button "休息" { Start-Rest "manual" } 13
    [System.Windows.Controls.DockPanel]::SetDock($restButton, "Right")
    $panel.Children.Add($restButton) | Out-Null

    $pauseButton = New-Button "暂停" { Start-Pause } 13
    [System.Windows.Controls.DockPanel]::SetDock($pauseButton, "Right")
    $panel.Children.Add($pauseButton) | Out-Null

    $script:AddOneButton = New-Button "+1" { Add-OneMinuteWork } 14
    [System.Windows.Controls.DockPanel]::SetDock($script:AddOneButton, "Right")
    $panel.Children.Add($script:AddOneButton) | Out-Null

    $border.Child = $panel
    $window.Content = $border
    $script:TimerWindow = $window
    Place-TopWindow
    $window.Show()
}

function Build-OverlayWindow {
    $screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $window = New-Object System.Windows.Window
    $window.Left = $screen.Left
    $window.Top = $screen.Top
    $window.Width = $screen.Width
    $window.Height = $screen.Height
    $window.WindowStyle = "None"
    $window.ResizeMode = "NoResize"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false

    $root = New-Object System.Windows.Controls.Grid
    $root.Background = New-ColorBrush 214 0 0 0

    $card = New-Object System.Windows.Controls.Border
    $card.Width = 480
    $card.MinHeight = 320
    $card.CornerRadius = "24"
    $card.Padding = "34"
    $card.Background = New-ColorBrush 230 54 58 61
    $card.BorderBrush = New-ColorBrush 80 255 255 255
    $card.BorderThickness = "1"
    $card.HorizontalAlignment = "Center"
    $card.VerticalAlignment = "Center"

    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Orientation = "Vertical"

    $isPause = ($script:Mode -eq "pause")
    $title = New-Label $(if ($isPause) { "暂停中" } else { "休息中" }) 34 "Bold" (New-ColorBrush 255 255 255 255)
    $title.Margin = "0,0,0,18"
    $stack.Children.Add($title) | Out-Null

    $countdownBrush = if ($isPause) { New-ColorBrush 255 255 214 64 } else { New-ColorBrush 255 54 232 89 }
    $script:RestCountdownLabel = New-Label (Format-Time $script:RemainingSeconds) 58 "Bold" $countdownBrush
    $script:RestCountdownLabel.Margin = "0,0,0,18"
    $stack.Children.Add($script:RestCountdownLabel) | Out-Null

    $script:RestSuggestionLabel = New-Label "" 17 "SemiBold" (New-ColorBrush 255 81 208 255)
    $script:RestSuggestionLabel.TextWrapping = "Wrap"
    $script:RestSuggestionLabel.TextAlignment = "Center"
    $script:RestSuggestionLabel.Margin = "0,0,0,22"
    if ($isPause) {
        Update-PauseSuggestion
    } else {
        Update-RestSuggestion $false
    }
    $stack.Children.Add($script:RestSuggestionLabel) | Out-Null

    if ($isPause) {
        $resumeButton = New-Button "回到工作" { Return-FromPause } 16
        $resumeButton.HorizontalAlignment = "Center"
        $stack.Children.Add($resumeButton) | Out-Null
    } else {
        $extendButton = New-Button "没休息够？再来五分钟！" { Extend-RestFiveMinutes } 16
        $extendButton.Margin = "0,0,0,12"
        $extendButton.HorizontalAlignment = "Center"
        $stack.Children.Add($extendButton) | Out-Null

        $script:ReturnToWorkButton = New-Button "再休息 05:00 后可回到工作" { Return-ToWorkAfterEnoughRest } 15
        $script:ReturnToWorkButton.HorizontalAlignment = "Center"
        $stack.Children.Add($script:ReturnToWorkButton) | Out-Null
        Update-ReturnToWorkButton

        if ($script:ManualRestUndoSeconds -gt 0) {
            $script:ManualRestUndoButton = New-Button "" { Undo-ManualRest } 13
            $script:ManualRestUndoButton.HorizontalAlignment = "Center"
            $script:ManualRestUndoButton.Margin = "0,12,0,0"
            Update-ManualRestUndoButton
            $stack.Children.Add($script:ManualRestUndoButton) | Out-Null
        }
    }

    $card.Child = $stack
    $root.Children.Add($card) | Out-Null
    $window.Content = $root
    $script:RestWindow = $window
    $window.Show()
}

function Close-RestWindow {
    param([bool]$ClearManualUndo = $true)
    if ($script:RestWindow) {
        $script:RestWindow.Close()
        $script:RestWindow = $null
    }
    $script:RestCountdownLabel = $null
    $script:RestSuggestionLabel = $null
    $script:ReturnToWorkButton = $null
    $script:ManualRestUndoButton = $null
    if ($ClearManualUndo) {
        $script:ManualRestUndoSeconds = 0
        $script:PausedWorkSecondsBeforeManualRest = 0
        $script:PausedContinuousWorkSecondsBeforeManualRest = 0
        $script:PausedManualWorkExtensionSecondsBeforeManualRest = 0
    }
    $script:RestElapsedSeconds = 0
}

function Update-TimerWindow {
    if (-not $script:TimerWindow) { return }
    if ($script:Mode -eq "work") {
        $script:ModeLabel.Text = "工作"
        $script:ModeLabel.Foreground = New-ColorBrush 255 255 167 38
    } elseif ($script:Mode -eq "pause") {
        $script:ModeLabel.Text = "暂停"
        $script:ModeLabel.Foreground = New-ColorBrush 255 255 214 64
    } else {
        $script:ModeLabel.Text = "休息"
        $script:ModeLabel.Foreground = New-ColorBrush 255 54 232 89
    }
    $script:CountdownLabel.Text = Format-Time $script:RemainingSeconds
    $script:AddOneButton.IsEnabled = ($script:Mode -eq "work" -and (Get-WorkExtensionHeadroom) -ge 60)
}

function Update-RestSuggestion {
    param([bool]$Advance)
    if (-not $script:RestSuggestionLabel) { return }
    if ($Advance) {
        $script:RestSuggestionIndex += 1
    }
    $script:RestSuggestionLabel.Text = $script:RestSuggestions[($script:RestSuggestionIndex % $script:RestSuggestions.Count)]
}

function Update-ReturnToWorkButton {
    if (-not $script:ReturnToWorkButton) { return }
    $enabled = ($script:Mode -eq "rest" -and $script:RestElapsedSeconds -ge $script:ProtectedRestSeconds)
    $script:ReturnToWorkButton.IsEnabled = $enabled
    if ($enabled) {
        $script:ReturnToWorkButton.Content = "已休息够，回到工作"
    } else {
        $left = [Math]::Max(0, $script:ProtectedRestSeconds - $script:RestElapsedSeconds)
        $script:ReturnToWorkButton.Content = "再休息 $(Format-Time $left) 后可回到工作"
    }
}

function Update-ManualRestUndoButton {
    if (-not $script:ManualRestUndoButton) { return }
    if ($script:ManualRestUndoSeconds -gt 0) {
        $script:ManualRestUndoButton.Visibility = [System.Windows.Visibility]::Visible
        $script:ManualRestUndoButton.Content = "误触，回到工作（$($script:ManualRestUndoSeconds)s）"
    } else {
        $script:ManualRestUndoButton.Visibility = [System.Windows.Visibility]::Collapsed
        $script:PausedWorkSecondsBeforeManualRest = 0
        $script:PausedContinuousWorkSecondsBeforeManualRest = 0
        $script:PausedManualWorkExtensionSecondsBeforeManualRest = 0
        Write-GuardianLog "manual_rest_undo_expired"
    }
}

function Get-WorkSeconds {
    return ([int]$script:Settings.WorkMinutes) * 60
}

function Get-RestSeconds {
    return ([int]$script:Settings.RestMinutes) * 60
}

function Get-MaxWorkSeconds {
    return ([int]$script:Settings.MaxWorkMinutes) * 60
}

function Get-RemainingWorkAllowance {
    return [Math]::Max(0, (Get-MaxWorkSeconds) - $script:ContinuousWorkSeconds)
}

function Get-PauseRecoveryHeadroom {
    return [Math]::Max(0, (Get-MaxWorkSeconds) - $script:RemainingSeconds)
}

function Get-ManualWorkExtensionLimit {
    return [Math]::Max(0, (Get-MaxWorkSeconds) - (Get-WorkSeconds))
}

function Get-ManualWorkExtensionRemaining {
    return [Math]::Max(0, (Get-ManualWorkExtensionLimit) - $script:ManualWorkExtensionSeconds)
}

function Get-WorkExtensionHeadroom {
    $countdownHeadroom = [Math]::Max(0, (Get-MaxWorkSeconds) - $script:RemainingSeconds)
    return [Math]::Min($countdownHeadroom, (Get-ManualWorkExtensionRemaining))
}

function Start-Work {
    param([int]$Seconds, [string]$Reason)
    if ($Reason -ne "manual_rest_undo") {
        $script:ManualWorkExtensionSeconds = 0
    }

    $allowed = Get-RemainingWorkAllowance
    if ($allowed -le 0) {
        Write-GuardianLog "work_start_blocked_max_reached" @{ reason = $Reason }
        Start-Rest "max_work_reached"
        return
    }

    $actual = [Math]::Min($Seconds, $allowed)
    Close-RestWindow
    $script:Mode = "work"
    $script:RemainingSeconds = $actual
    $script:SessionTotalSeconds = $actual
    Update-TimerWindow
    Start-Ticker
    Write-GuardianLog "work_started" @{
        reason = $Reason
        seconds = "$actual"
        continuousWorkSeconds = "$script:ContinuousWorkSeconds"
        maxWorkSeconds = "$(Get-MaxWorkSeconds)"
    }
}

function Start-Rest {
    param([string]$Reason)
    $previousContinuous = $script:ContinuousWorkSeconds
    $isManualRest = ($Reason -eq "manual")
    $script:PausedWorkSecondsBeforeManualRest = if ($isManualRest) { $script:RemainingSeconds } else { 0 }
    $script:PausedContinuousWorkSecondsBeforeManualRest = if ($isManualRest) { $previousContinuous } else { 0 }
    $script:PausedManualWorkExtensionSecondsBeforeManualRest = if ($isManualRest) { $script:ManualWorkExtensionSeconds } else { 0 }
    $script:ManualRestUndoSeconds = if ($isManualRest) { 10 } else { 0 }
    $script:Mode = "rest"
    $script:RemainingSeconds = Get-RestSeconds
    $script:SessionTotalSeconds = $script:RemainingSeconds
    $script:ContinuousWorkSeconds = 0
    $script:RestElapsedSeconds = 0
    $script:RestSuggestionIndex = 0
    Close-RestWindow $false
    Build-OverlayWindow
    Update-TimerWindow
    Start-Ticker
    Write-GuardianLog "rest_started" @{
        reason = $Reason
        seconds = "$script:RemainingSeconds"
        previousContinuousWorkSeconds = "$previousContinuous"
    }
}

function Start-Ticker {
    if ($script:Timer) {
        $script:Timer.Stop()
    }
    $script:Timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:Timer.Interval = [TimeSpan]::FromSeconds(1)
    $script:Timer.Add_Tick({ Tick })
    $script:Timer.Start()
}

function Tick {
    if ($script:Mode -eq "pause") {
        $script:PauseElapsedSeconds += 1
        Recover-DuringPause
        Update-TimerWindow
        if ($script:RestCountdownLabel) {
            $script:RestCountdownLabel.Text = Format-Time $script:RemainingSeconds
        }
        Update-PauseSuggestion
        return
    }

    if ($script:Mode -eq "work") {
        $script:ContinuousWorkSeconds = [Math]::Min((Get-MaxWorkSeconds), $script:ContinuousWorkSeconds + 1)
    }

    $script:RemainingSeconds = [Math]::Max(0, $script:RemainingSeconds - 1)

    if ($script:Mode -eq "rest") {
        $script:RestElapsedSeconds += 1
        if ($script:ManualRestUndoSeconds -gt 0) {
            $script:ManualRestUndoSeconds -= 1
            Update-ManualRestUndoButton
        }
        if ($script:RemainingSeconds -gt 0 -and $script:RemainingSeconds % 6 -eq 0) {
            Update-RestSuggestion $true
        }
    }

    Update-TimerWindow
    if ($script:RestCountdownLabel) {
        $script:RestCountdownLabel.Text = Format-Time $script:RemainingSeconds
    }
    Update-ReturnToWorkButton

    if ($script:Mode -eq "work" -and $script:ContinuousWorkSeconds -ge (Get-MaxWorkSeconds)) {
        $script:Timer.Stop()
        Write-GuardianLog "max_work_reached" @{ maxWorkSeconds = "$(Get-MaxWorkSeconds)" }
        Start-Rest "max_work_reached"
        return
    }

    if ($script:RemainingSeconds -gt 0) {
        return
    }

    $script:Timer.Stop()
    if ($script:Mode -eq "work") {
        Write-GuardianLog "work_timer_finished" @{
            seconds = "$script:SessionTotalSeconds"
            continuousWorkSeconds = "$script:ContinuousWorkSeconds"
        }
        Start-Rest "work_timer_finished"
    } else {
        Write-GuardianLog "rest_completed" @{ seconds = "$script:SessionTotalSeconds" }
        Start-Work (Get-WorkSeconds) "rest_completed"
    }
}

function Add-OneMinuteWork {
    if ($script:Mode -ne "work") { return }
    if ((Get-WorkExtensionHeadroom) -lt 60) {
        Show-Reminder "这轮的加时额度用完了，到点就休息。"
        Write-GuardianLog "work_add_one_blocked_max_reached"
        return
    }
    $script:RemainingSeconds += 60
    $script:SessionTotalSeconds += 60
    $script:ManualWorkExtensionSeconds += 60
    Update-TimerWindow
    $message = $script:WorkExtensionMessages[($script:WorkReminderIndex % $script:WorkExtensionMessages.Count)]
    $script:WorkReminderIndex += 1
    Show-Reminder $message
    Write-GuardianLog "work_added_one_minute" @{
        remainingSeconds = "$script:RemainingSeconds"
        continuousWorkSeconds = "$script:ContinuousWorkSeconds"
        maxWorkSeconds = "$(Get-MaxWorkSeconds)"
        manualWorkExtensionSeconds = "$script:ManualWorkExtensionSeconds"
        manualWorkExtensionLimitSeconds = "$(Get-ManualWorkExtensionLimit)"
    }
}

function Extend-RestFiveMinutes {
    if ($script:Mode -ne "rest") { return }
    $script:RemainingSeconds += 5 * 60
    $script:SessionTotalSeconds += 5 * 60
    if ($script:RestCountdownLabel) {
        $script:RestCountdownLabel.Text = Format-Time $script:RemainingSeconds
    }
    Update-RestSuggestion $true
    Update-ReturnToWorkButton
    Write-GuardianLog "rest_extended_five_minutes" @{
        remainingSeconds = "$script:RemainingSeconds"
        restElapsedSeconds = "$script:RestElapsedSeconds"
    }
}

function Start-Pause {
    if ($script:Mode -ne "work") { return }
    $script:Mode = "pause"
    $script:PauseElapsedSeconds = 0
    $script:PauseRecoveredSeconds = 0
    $script:PauseReducedContinuousSeconds = 0
    $script:ManualRestUndoSeconds = 0
    $script:PausedWorkSecondsBeforeManualRest = 0
    $script:PausedContinuousWorkSecondsBeforeManualRest = 0
    $script:PausedManualWorkExtensionSecondsBeforeManualRest = 0
    Close-RestWindow
    Build-OverlayWindow
    Start-Ticker
    Update-TimerWindow
    Write-GuardianLog "work_paused" @{
        remainingSeconds = "$script:RemainingSeconds"
        continuousWorkSeconds = "$script:ContinuousWorkSeconds"
    }
}

function Return-FromPause {
    if ($script:Mode -ne "pause") { return }
    $elapsed = $script:PauseElapsedSeconds
    $recovered = $script:PauseRecoveredSeconds
    $reducedContinuous = $script:PauseReducedContinuousSeconds
    Close-RestWindow
    $script:Mode = "work"
    $script:PauseElapsedSeconds = 0
    $script:PauseRecoveredSeconds = 0
    $script:PauseReducedContinuousSeconds = 0
    Start-Ticker
    Update-TimerWindow
    Write-GuardianLog "work_resumed_from_pause" @{
        remainingSeconds = "$script:RemainingSeconds"
        continuousWorkSeconds = "$script:ContinuousWorkSeconds"
        pauseElapsedSeconds = "$elapsed"
        pauseRecoveredSeconds = "$recovered"
        pauseReducedContinuousSeconds = "$reducedContinuous"
    }
}

function Recover-DuringPause {
    $countdownRecovery = [Math]::Min($script:PauseRecoveryMultiplier, (Get-PauseRecoveryHeadroom))
    if ($countdownRecovery -gt 0) {
        $script:RemainingSeconds += $countdownRecovery
        $script:SessionTotalSeconds += $countdownRecovery
        $script:PauseRecoveredSeconds += $countdownRecovery
    }

    $continuousRecovery = [Math]::Min($script:PauseRecoveryMultiplier, $script:ContinuousWorkSeconds)
    if ($continuousRecovery -gt 0) {
        $script:ContinuousWorkSeconds -= $continuousRecovery
        $script:PauseReducedContinuousSeconds += $continuousRecovery
    }
}

function Update-PauseSuggestion {
    if (-not $script:RestSuggestionLabel -or $script:Mode -ne "pause") { return }
    if ((Get-PauseRecoveryHeadroom) -eq 0 -and $script:ContinuousWorkSeconds -eq 0) {
        $script:RestSuggestionLabel.Text = "工作倒计时已经补到 50 分钟，想回去随时可以。"
        return
    }
    if ((Get-PauseRecoveryHeadroom) -eq 0) {
        $script:RestSuggestionLabel.Text = "工作倒计时已经补到 50 分钟，再停一会儿也算休息。"
        return
    }
    if ($script:PauseRecoveredSeconds -ge 60) {
        $script:RestSuggestionLabel.Text = "已补回 $([Math]::Floor($script:PauseRecoveredSeconds / 60)) 分钟。每停 1 分钟，再补 5 分钟。"
    } else {
        $script:RestSuggestionLabel.Text = "每停 1 分钟，工作倒计时补 5 分钟。"
    }
}

function Undo-ManualRest {
    if ($script:ManualRestUndoSeconds -le 0 -or $script:PausedWorkSecondsBeforeManualRest -le 0) {
        return
    }
    $restoredRemainingSeconds = $script:PausedWorkSecondsBeforeManualRest
    $restoredManualWorkExtensionSeconds = $script:PausedManualWorkExtensionSecondsBeforeManualRest
    $script:ContinuousWorkSeconds = $script:PausedContinuousWorkSecondsBeforeManualRest
    $script:ManualWorkExtensionSeconds = $restoredManualWorkExtensionSeconds
    $script:PausedWorkSecondsBeforeManualRest = 0
    $script:PausedContinuousWorkSecondsBeforeManualRest = 0
    $script:PausedManualWorkExtensionSecondsBeforeManualRest = 0
    $script:ManualRestUndoSeconds = 0
    Write-GuardianLog "manual_rest_undone" @{
        restoredRemainingSeconds = "$restoredRemainingSeconds"
        restoredContinuousWorkSeconds = "$script:ContinuousWorkSeconds"
        restoredManualWorkExtensionSeconds = "$restoredManualWorkExtensionSeconds"
    }
    Start-Work $restoredRemainingSeconds "manual_rest_undo"
}

function Return-ToWorkAfterEnoughRest {
    if ($script:Mode -ne "rest") { return }
    if ($script:RestElapsedSeconds -lt $script:ProtectedRestSeconds) { return }
    Write-GuardianLog "rest_return_to_work_after_enough_rest" @{
        remainingSeconds = "$script:RemainingSeconds"
        restElapsedSeconds = "$script:RestElapsedSeconds"
    }
    Start-Work (Get-WorkSeconds) "rest_return_to_work"
}

function Show-Reminder {
    param([string]$Message)
    if ($script:ReminderTimer) {
        $script:ReminderTimer.Stop()
        $script:ReminderTimer = $null
    }
    if ($script:ReminderWindow) {
        $script:ReminderWindow.Close()
        $script:ReminderWindow = $null
    }

    $window = New-Object System.Windows.Window
    $window.Width = 520
    $window.Height = 62
    $window.WindowStyle = "None"
    $window.ResizeMode = "NoResize"
    $window.AllowsTransparency = $true
    $window.Background = [System.Windows.Media.Brushes]::Transparent
    $window.Topmost = $true
    $window.ShowInTaskbar = $false

    $border = New-Object System.Windows.Controls.Border
    $border.CornerRadius = "18"
    $border.Padding = "18,10,18,10"
    $border.Background = New-ColorBrush 235 40 43 47
    $border.Child = New-Label $Message 15 "SemiBold" (New-ColorBrush 255 255 255 255)
    $window.Content = $border

    $workArea = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $workArea.Left + (($workArea.Width - $window.Width) / 2)
    $window.Top = $workArea.Top + 64
    $script:ReminderWindow = $window
    $window.Show()

    $script:ReminderTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:ReminderTimer.Interval = [TimeSpan]::FromSeconds(2)
    $script:ReminderTimer.Add_Tick({
        if ($script:ReminderTimer) { $script:ReminderTimer.Stop() }
        if ($script:ReminderWindow) { $script:ReminderWindow.Close() }
        $script:ReminderTimer = $null
        $script:ReminderWindow = $null
    })
    $script:ReminderTimer.Start()
}

function Read-Minutes {
    param($TextBox)
    $value = 0
    if ([int]::TryParse($TextBox.Text, [ref]$value)) {
        return $value
    }
    return $null
}

function New-SettingsRow {
    param([string]$Title, [string]$Value)
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = "Horizontal"
    $row.Margin = "0,0,0,10"

    $label = New-Label $Title 14 "SemiBold" (New-ColorBrush 255 30 30 30)
    $label.Width = 130
    $label.HorizontalAlignment = "Left"
    $row.Children.Add($label) | Out-Null

    $box = New-Object System.Windows.Controls.TextBox
    $box.Text = $Value
    $box.FontSize = 16
    $box.FontFamily = "Consolas"
    $box.Width = 80
    $box.HorizontalContentAlignment = "Right"
    $row.Children.Add($box) | Out-Null

    return [pscustomobject]@{ Row = $row; Box = $box }
}

function Show-SettingsWindow {
    if ($script:SettingsWindow) {
        $script:SettingsWindow.Activate()
        return
    }

    $window = New-Object System.Windows.Window
    $window.Title = "Rest Guardian 设置"
    $window.Width = 430
    $window.Height = 340
    $window.ResizeMode = "NoResize"
    $window.Topmost = $true
    $window.WindowStartupLocation = "CenterScreen"

    $root = New-Object System.Windows.Controls.StackPanel
    $root.Margin = "24"

    $title = New-Label "休息监督设置" 22 "Bold" (New-ColorBrush 255 30 30 30)
    $title.HorizontalAlignment = "Left"
    $title.Margin = "0,0,0,8"
    $root.Children.Add($title) | Out-Null

    $subtitle = New-Label "保存只影响后续计时，不会重置当前工作轮。连续工作上限最高固定为 50 分钟，且不能小于每轮工作时间。" 13 "Normal" (New-ColorBrush 255 80 80 80)
    $subtitle.TextWrapping = "Wrap"
    $subtitle.TextAlignment = "Left"
    $subtitle.HorizontalAlignment = "Left"
    $subtitle.Margin = "0,0,0,16"
    $root.Children.Add($subtitle) | Out-Null

    $workRow = New-SettingsRow "每轮工作" "$($script:Settings.WorkMinutes)"
    $restRow = New-SettingsRow "每轮休息" "$($script:Settings.RestMinutes)"
    $maxRow = New-SettingsRow "连续工作上限" "$($script:Settings.MaxWorkMinutes)"
    $root.Children.Add($workRow.Row) | Out-Null
    $root.Children.Add($restRow.Row) | Out-Null
    $root.Children.Add($maxRow.Row) | Out-Null

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = "Horizontal"
    $buttons.HorizontalAlignment = "Right"
    $buttons.Margin = "0,14,0,0"
    $buttons.Children.Add((New-Button "取消" { Close-SettingsWindow } 14)) | Out-Null
    $buttons.Children.Add((New-Button "保存" {
        Save-SettingsFromWindow $workRow.Box $restRow.Box $maxRow.Box
    } 14)) | Out-Null
    $root.Children.Add($buttons) | Out-Null

    $window.Content = $root
    $window.Add_Closed({ $script:SettingsWindow = $null })
    $script:SettingsWindow = $window
    $window.Show()
    Write-GuardianLog "settings_opened"
}

function Close-SettingsWindow {
    if ($script:SettingsWindow) {
        $script:SettingsWindow.Close()
        $script:SettingsWindow = $null
    }
}

function Show-SettingsAlert {
    param([string]$Message)
    [System.Windows.MessageBox]::Show(
        $Message,
        "Rest Guardian 设置",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Warning
    ) | Out-Null
}

function Save-SettingsFromWindow {
    param($WorkBox, $RestBox, $MaxBox)
    $work = Read-Minutes $WorkBox
    $rest = Read-Minutes $RestBox
    $maxWork = Read-Minutes $MaxBox
    if ($null -eq $work -or $null -eq $rest -or $null -eq $maxWork) {
        Show-SettingsAlert "请输入有效的分钟数。"
        return
    }
    if ($work -gt $script:HardMaxWorkMinutes -or $maxWork -gt $script:HardMaxWorkMinutes) {
        Show-SettingsAlert "工作时间和连续工作上限都不能超过 50 分钟。"
        return
    }
    if ($maxWork -lt $work) {
        Show-SettingsAlert "连续工作上限不能小于每轮工作时间。"
        return
    }
    $settings = Normalize-Settings -WorkMinutes $work -RestMinutes $rest -MaxWorkMinutes $maxWork
    Save-Settings $settings
    $script:Settings = $settings
    Close-SettingsWindow
    Write-GuardianLog "settings_saved" @{
        workMinutes = "$($settings.WorkMinutes)"
        restMinutes = "$($settings.RestMinutes)"
        maxWorkMinutes = "$($settings.MaxWorkMinutes)"
        mode = "$script:Mode"
        remainingSeconds = "$script:RemainingSeconds"
        continuousWorkSeconds = "$script:ContinuousWorkSeconds"
    }
    Update-TimerWindow
    Update-ReturnToWorkButton
    if ($script:Mode -eq "work" -and $script:ContinuousWorkSeconds -ge (Get-MaxWorkSeconds)) {
        Write-GuardianLog "settings_saved_max_reached" @{ maxWorkSeconds = "$(Get-MaxWorkSeconds)" }
        Start-Rest "settings_saved_max_reached"
    }
}

function Close-App {
    Write-GuardianLog "app_quit"
    if ($script:Timer) { $script:Timer.Stop() }
    if ($script:RestWindow) { $script:RestWindow.Close() }
    if ($script:SettingsWindow) { $script:SettingsWindow.Close() }
    if ($script:ReminderWindow) { $script:ReminderWindow.Close() }
    if ($script:TimerWindow) { $script:TimerWindow.Close() }
    [System.Windows.Application]::Current.Shutdown()
}

$script:Settings = Load-Settings
$app = New-Object System.Windows.Application
Build-TimerWindow
Start-Work (Get-WorkSeconds) "app_started"
Write-GuardianLog "app_started"
$app.Run() | Out-Null
