param(
    [switch]$InstallStartup,
    [switch]$UninstallStartup,
    [switch]$RegisterEventLog
)

$script:TrayRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $script:TrayRoot 'clipboard-core.ps1')

$script:TraySwitches = @()
if ($InstallStartup) { $script:TraySwitches += '-InstallStartup' }
if ($UninstallStartup) { $script:TraySwitches += '-UninstallStartup' }
if ($RegisterEventLog) { $script:TraySwitches += '-RegisterEventLog' }
if ($script:TraySwitches.Count -gt 1) {
    Write-Host 'ERROR: Choose one tray switch at a time.'
    exit 2
}

$apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
if ($apartment -eq [System.Threading.ApartmentState]::MTA -and -not $env:CLIPBOARD_TRAY_STA_CHILD) {
    $env:CLIPBOARD_TRAY_STA_CHILD = '1'
    $relaunch = Get-StaRelaunchArguments -ScriptPath $PSCommandPath -Arguments $script:TraySwitches
    $hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $hostExe)) {
        $found = Get-Command powershell -ErrorAction SilentlyContinue
        if ($null -eq $found) { $found = Get-Command pwsh -ErrorAction SilentlyContinue }
        if ($null -eq $found) {
            Write-Host 'ERROR: powershell host was not found for STA relaunch.'
            exit 2
        }
        $hostExe = $found.Source
    }
    $child = Start-Process -FilePath $hostExe -ArgumentList $relaunch -Wait -PassThru -NoNewWindow
    exit $child.ExitCode
}

if ($RegisterEventLog) {
    $registration = Initialize-ClipboardEventLog
    if ($registration.Status -eq 'registered') {
        Write-Host 'PASS Event Log source ClipboardDiagnosticsMvp is registered.'
        exit 0
    }
    Write-Host 'ERROR: Event Log registration needs an elevated Windows PowerShell. Re-run clipboard-tray.ps1 -RegisterEventLog from an elevated prompt.'
    exit 2
}
if ($InstallStartup -or $UninstallStartup) {
    $startupSettings = Read-ClipboardDiagnosticsSettings
    $startupProvider = Get-StartupProvider -TrayScriptPath (Join-Path $script:TrayRoot 'clipboard-tray.ps1')
    $startupToggle = Invoke-StartupToggle -Provider $startupProvider -SettingsResult $startupSettings -Enable:([bool]$InstallStartup) -Root (Get-ClipboardDiagnosticsRoot)
    Write-Host $startupToggle.TaskResult
    if ($startupToggle.ExitCode -eq 2 -and $startupSettings.Unsupported) {
        Write-Host 'ERROR SettingsVersionUnsupported'
    }
    exit $startupToggle.ExitCode
}

$script:TrayMutexName = 'Local\ClipboardDiagnosticsMvp.Tray'
$script:TrayMutex = $null
$script:TrayMutexHeld = $false
try {
    $script:TrayMutex = New-Object System.Threading.Mutex($false, $script:TrayMutexName)
    $script:TrayMutexHeld = $script:TrayMutex.WaitOne(0)
}
catch {
    Write-Host 'ERROR: tray mutex could not be created.'
    exit 2
}
if (-not $script:TrayMutexHeld) {
    Write-Host 'Tray already running.'
    exit 0
}

$script:TrayToolVersion = '3.0.0'
$script:SessionRewrites = 0
$script:RewriteInProgress = $false
$script:ListenerMode = 'Poll'
$script:HealthForm = $null
$script:HealthText = $null

function New-ClipboardTrayIconBitmap {
    param([bool]$Paused)
    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $color = if ($Paused) { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::FromArgb(32, 120, 72) }
    $brush = New-Object System.Drawing.SolidBrush $color
    $graphics.FillEllipse($brush, 1, 1, 14, 14)
    $brush.Dispose()
    $graphics.Dispose()
    return $bitmap
}

function Update-ClipboardTrayIcon {
    if ($null -eq $script:TrayNotifyIcon) { return }
    if ($null -ne $script:TrayBitmap) { $script:TrayBitmap.Dispose() }
    $script:TrayBitmap = New-ClipboardTrayIconBitmap -Paused $script:Paused
    $drawingIcon = [type]('System.Drawing.' + 'Icon')
    $iconProperty = 'Icon'
    $script:TrayNotifyIcon.$iconProperty = $drawingIcon::FromHandle($script:TrayBitmap.GetHicon())
    $script:TrayNotifyIcon.Text = Get-ClipboardTrayTooltip -Paused $script:Paused
    if ($null -ne $script:PauseMenuItem) {
        $script:PauseMenuItem.Text = if ($script:Paused) { 'Resume' } else { 'Pause' }
    }
}

function Get-TrayStartupInstalled {
    if ($null -eq $script:StartupProvider) { return $false }
    try {
        $status = ConvertFrom-StartupMethodResult -Value $script:StartupProvider.GetStatus.Invoke()
        if ($null -eq $status -or $null -eq $status.PSObject.Properties['Installed']) { return $false }
        return [bool]$status.Installed
    }
    catch {
        return $false
    }
}

function Get-TrayHealthRows {
    $eventReady = $false
    try { $eventReady = [bool](Test-ClipboardEventLogSource) } catch { $eventReady = $false }
    $policyPresent = $false
    try {
        $signal = Get-ClipboardPolicySignal
        if ($null -ne $signal) { $policyPresent = [bool]$signal.Present }
    }
    catch { $policyPresent = $false }
    $poll = 400
    if ($null -ne $script:SettingsResult.Settings.plainText) {
        $poll = [int]$script:SettingsResult.Settings.plainText.pollIntervalMs
    }
    Get-ClipboardHealthRows -Paused:$script:Paused -ListenerMode $script:ListenerMode -PollIntervalMs $poll -StartWithWindows:(Get-TrayStartupInstalled) -TaskAction '' -SessionRewrites $script:SessionRewrites -TotalRewrites $script:StateResult.State.rewriteCountTotal -LastActivityUtc $script:StateResult.State.lastActivityUtc -LastRewriteUtc $script:StateResult.State.lastRewriteUtc -LastOutcome $script:StateResult.State.lastOutcome -LastReason $script:StateResult.State.lastReason -LastCharCount $script:StateResult.State.lastCharCount -LastOwnerName $script:StateResult.State.lastOwnerName -EventLogReady:$eventReady -PolicyPresent:$policyPresent -ToolVersion $script:TrayToolVersion -CoreVersion $script:ClipboardCoreVersion
}

function Update-ClipboardTrayHealthText {
    if ($null -eq $script:HealthText) { return }
    $lines = New-Object System.Collections.Generic.List[string]
    $rows = Get-TrayHealthRows
    foreach ($key in $rows.Keys) {
        $lines.Add(('{0}: {1}' -f $key, $rows[$key]))
    }
    $script:HealthText.Text = ($lines -join [Environment]::NewLine)
}

function Show-ClipboardTrayHealth {
    if ($null -ne $script:HealthForm -and -not $script:HealthForm.IsDisposed) {
        Update-ClipboardTrayHealthText
        $script:HealthForm.Show()
        $script:HealthForm.Activate()
        return
    }
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Clipboard diagnostics — Health'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.ClientSize = New-Object System.Drawing.Size 460, 380
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Vertical'
    $box.Dock = 'Fill'
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = 'Refresh'
    $refresh.Dock = 'Bottom'
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Close'
    $close.Dock = 'Bottom'
    $refresh.Add_Click({
            try { $script:StateResult = Read-ClipboardDiagnosticsState } catch { }
            Update-ClipboardTrayHealthText
        })
    $close.Add_Click({ $form.Hide() })
    $form.Controls.Add($box)
    $form.Controls.Add($refresh)
    $form.Controls.Add($close)
    $script:HealthForm = $form
    $script:HealthText = $box
    Update-ClipboardTrayHealthText
    [void]$form.Show()
}

function Save-TrayActivity {
    param([string]$Outcome, [string]$Reason, $CharCount, [string]$OwnerName, [bool]$Rewritten)
    $script:StateResult.State.lastActivityUtc = [DateTime]::UtcNow.ToString('o')
    if ($Rewritten) {
        $script:SessionRewrites = [int]$script:SessionRewrites + 1
        $script:StateResult.State.rewriteCountTotal = [int]$script:StateResult.State.rewriteCountTotal + 1
        $script:StateResult.State.lastRewriteUtc = [DateTime]::UtcNow.ToString('o')
        $script:StateResult.State.lastOutcome = $Outcome
        $script:StateResult.State.lastReason = $Reason
        $script:StateResult.State.lastCharCount = $CharCount
        $script:StateResult.State.lastOwnerName = $OwnerName
    }
    if (-not $script:StoreUnsupported) {
        [void](Save-ClipboardDiagnosticsState -State $script:StateResult.State)
    }
}

function Invoke-TrayClipboardObservation {
    param($CurrentSequence)
    if ($null -eq $CurrentSequence) { return }
    $observation = Invoke-PlainTextObservation -PreviousSequence $script:LastSequence -CurrentSequence $CurrentSequence -Paused:$script:Paused -RewriteLockHeld:$false -Rewrite {
        $script:RewriteInProgress = $true
        try { return Invoke-ClipboardPlainTextRewrite }
        finally { $script:RewriteInProgress = $false }
    }
    if ($null -eq $observation) { return }
    $script:LastSequence = $CurrentSequence
    if ($observation.Activity) {
        if ($script:Paused -or $observation.Outcome -eq 'Skip' -or $observation.Outcome -eq 'Dropped') {
            $script:StateResult.State.lastActivityUtc = [DateTime]::UtcNow.ToString('o')
            if (-not $script:StoreUnsupported) {
                [void](Save-ClipboardDiagnosticsState -State $script:StateResult.State)
            }
        }
    }
    if ($observation.Outcome -eq 'PASS') {
        Save-TrayActivity -Outcome 'PASS' -Reason 'Rewritten' -CharCount $observation.CharCount -OwnerName $observation.SourceProcess -Rewritten $true
        $script:TrayLogger.Write(@{ Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Reason = 'Rewritten'; CharCount = [int]$observation.CharCount; Process = [string]$observation.SourceProcess; FormatsBefore = @($observation.FormatsBefore); FormatsAfter = @($observation.FormatsAfter); Sequence = [int64]$observation.SequenceAfter })
        $script:TrayNotifier.Send('PASS', 'Clipboard plain-text rewrite', 'Rewritten')
    }
    elseif ($observation.Outcome -eq 'FAIL') {
        $script:TrayLogger.Write(@{ Level = 'FAIL'; EventId = 2000; Mode = 'Tray'; Reason = [string]$observation.Reason; CharCount = [int]$observation.CharCount; Process = [string]$observation.SourceProcess })
        $toast = Get-ClipboardToastText -Level 'FAIL' -Reason $observation.Reason -CharCount ([int]$observation.CharCount)
        $script:TrayNotifier.Send('FAIL', $toast.Title, $toast.Body)
    }
    elseif ($observation.Outcome -eq 'ERROR') {
        $script:TrayLogger.Write(@{ Level = 'ERROR'; EventId = 3000; Mode = 'Tray'; Reason = [string]$observation.Reason; CharCount = -1 })
        $toast = Get-ClipboardToastText -Level 'ERROR' -Reason $observation.Reason -CharCount -1
        $script:TrayNotifier.Send('ERROR', $toast.Title, $toast.Body)
    }
}

function Start-TrayClipboardListener {
    $script:ListenerMode = 'Poll'
    $registered = $false
    try {
        if (-not ('TrayClipboardWindow' -as [type])) {
            Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public class TrayClipboardWindow : NativeWindow {
    public event EventHandler ClipboardUpdated;
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool AddClipboardFormatListener(IntPtr hwnd);
    public bool Listen() {
        CreateParams cp = new CreateParams();
        cp.Parent = new IntPtr(-3);
        CreateHandle(cp);
        return AddClipboardFormatListener(Handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x031D && ClipboardUpdated != null) ClipboardUpdated(this, EventArgs.Empty);
        base.WndProc(ref m);
    }
}
'@ -ErrorAction Stop
        }
        $script:TrayWindow = New-Object TrayClipboardWindow
        $registered = [bool]$script:TrayWindow.Listen()
        if ($registered) {
            $script:ListenerMode = 'Listener'
            $script:TrayWindow.add_ClipboardUpdated({
                    try { Invoke-TrayClipboardObservation -CurrentSequence (Get-ClipboardSequenceNumber) } catch { }
                })
        }
    }
    catch { $registered = $false }
    if (-not $registered) {
        $script:ListenerMode = 'Poll'
        $interval = 400
        if ($null -ne $script:SettingsResult.Settings.plainText) {
            $interval = [int]$script:SettingsResult.Settings.plainText.pollIntervalMs
        }
        $script:TrayTimer = New-Object System.Windows.Forms.Timer
        $script:TrayTimer.Interval = $interval
        $script:TrayTimer.Add_Tick({
                try { Invoke-TrayClipboardObservation -CurrentSequence (Get-ClipboardSequenceNumber) } catch { }
            })
        $script:TrayTimer.Start()
    }
}

function Stop-ClipboardTray {
    $waited = 0
    while ($script:RewriteInProgress -and $waited -lt 2000) {
        Start-Sleep -Milliseconds 50
        $waited += 50
    }
    try {
        $script:TrayLogger.Write(@{ Level = 'INFO'; EventId = 1101; Mode = 'Tray'; Reason = 'Quit' })
    }
    catch { }
    if ($null -ne $script:TrayTimer) { $script:TrayTimer.Stop(); $script:TrayTimer.Dispose() }
    if ($null -ne $script:TrayNotifyIcon) {
        $script:TrayNotifyIcon.Visible = $false
        $script:TrayNotifyIcon.Dispose()
    }
    if ($null -ne $script:TrayBitmap) { $script:TrayBitmap.Dispose() }
    if ($null -ne $script:HealthForm) { $script:HealthForm.Dispose() }
    if ($script:TrayMutexHeld -and $null -ne $script:TrayMutex) {
        try { [void]$script:TrayMutex.ReleaseMutex() } catch { }
    }
    if ($null -ne $script:TrayMutex) { $script:TrayMutex.Dispose() }
    [System.Windows.Forms.Application]::Exit()
}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}
catch {
    Write-Host 'ERROR: WinForms is not available in this session.'
    if ($script:TrayMutexHeld -and $null -ne $script:TrayMutex) {
        try { [void]$script:TrayMutex.ReleaseMutex() } catch { }
    }
    exit 2
}

$script:SettingsResult = Read-ClipboardDiagnosticsSettings
$script:StateResult = Read-ClipboardDiagnosticsState
$script:StoreUnsupported = [bool]($script:SettingsResult.Unsupported -or $script:StateResult.Unsupported)
$logDirectory = Join-Path (Get-ClipboardDiagnosticsRoot) 'logs'
$fileLogging = $true
$eventLogging = $true
$toastOnFail = $true
if ($null -ne $script:SettingsResult.Settings.logging) {
    if ($null -ne $script:SettingsResult.Settings.logging.file) { $fileLogging = [bool]$script:SettingsResult.Settings.logging.file }
    if ($null -ne $script:SettingsResult.Settings.logging.eventLog) { $eventLogging = [bool]$script:SettingsResult.Settings.logging.eventLog }
}
if ($null -ne $script:SettingsResult.Settings.notifications -and $null -ne $script:SettingsResult.Settings.notifications.toastOnFail) {
    $toastOnFail = [bool]$script:SettingsResult.Settings.notifications.toastOnFail
}
$script:TrayLogger = New-LoggingProvider -LogDirectory $logDirectory -FileEnabled $fileLogging -EventLogEnabled $eventLogging
$script:TrayNotifier = New-NotificationProvider -Kind Toast -ToastOnFail $toastOnFail
Publish-ClipboardStoreEvents -SettingsResult $script:SettingsResult -StateResult $script:StateResult -Logger $script:TrayLogger
$gate = Get-ClipboardRuntimeGate -SettingsResult $script:SettingsResult -StateResult $script:StateResult
$script:Paused = [bool]$gate.PausedEffective
$script:LastSequence = Get-ClipboardSequenceNumber
$script:TrayLogger.Write(@{ Level = 'INFO'; EventId = 1100; Mode = 'Tray'; Reason = 'Started' })
$script:StartupProvider = Get-StartupProvider -TrayScriptPath (Join-Path $script:TrayRoot 'clipboard-tray.ps1')
$script:StartupInstalled = Get-TrayStartupInstalled
$startupSync = Sync-StartWithWindowsSetting -SettingsResult $script:SettingsResult -TaskInstalled $script:StartupInstalled
if ($startupSync.Changed -and -not $script:SettingsResult.Unsupported) {
    [void](Save-ClipboardDiagnosticsSettings -Settings $startupSync.Settings)
}

$script:TrayNotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:TrayBitmap = $null
Update-ClipboardTrayIcon
$script:TrayNotifyIcon.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:PauseMenuItem = $menu.Items.Add($(if ($script:Paused) { 'Resume' } else { 'Pause' }))
[void]$menu.Items.Add('Health Status…')
[void]$menu.Items.Add('Export Diagnostics…')
$script:StartupMenuItem = $menu.Items.Add('Start with Windows')
$script:StartupMenuItem.Checked = [bool]$script:StartupInstalled
[void]$menu.Items.Add('Quit')
$script:PauseMenuItem.Add_Click({
        if ($script:StoreUnsupported) { return }
        $script:Paused = -not $script:Paused
        $script:SettingsResult.Settings.paused = $script:Paused
        if (-not $script:SettingsResult.Unsupported) {
            [void](Save-ClipboardDiagnosticsSettings -Settings $script:SettingsResult.Settings)
        }
        $eventId = if ($script:Paused) { 1102 } else { 1103 }
        $reason = if ($script:Paused) { 'Paused' } else { 'Resumed' }
        $script:TrayLogger.Write(@{ Level = 'INFO'; EventId = $eventId; Mode = 'Tray'; Reason = $reason })
        Update-ClipboardTrayIcon
    })
$menu.Items[1].Add_Click({ Show-ClipboardTrayHealth })
$menu.Items[2].Add_Click({
        [void][System.Windows.Forms.MessageBox]::Show('Export Diagnostics arrives in a later task. No zip was written.', 'Clipboard diagnostics')
    })
$menu.Items[3].Add_Click({
        $enable = -not [bool]$script:StartupMenuItem.Checked
        [void](Invoke-StartupToggle -Provider $script:StartupProvider -SettingsResult $script:SettingsResult -Enable:$enable -Root (Get-ClipboardDiagnosticsRoot))
        $script:StartupInstalled = Get-TrayStartupInstalled
        $script:StartupMenuItem.Checked = [bool]$script:StartupInstalled
    })
$menu.Items[4].Add_Click({ Stop-ClipboardTray })
$script:TrayNotifyIcon.ContextMenuStrip = $menu
$script:TrayNotifyIcon.Add_DoubleClick({ Show-ClipboardTrayHealth })
Start-TrayClipboardListener
[System.Windows.Forms.Application]::Run()
