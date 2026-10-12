################################################################################
# SAFETY HEADER — clipboard-test.ps1
# ------------------------------------------------------------------------------
# Purpose:
#   Local Windows clipboard / terminal-paste diagnostic and limited remediation
#   utility.
#
# Privileges:
#   Runs as the current interactive user. Does not require Administrator.
#   -Fix may stop/restart PowerToys processes owned by the current user.
#   -Fix -RestartExplorer restarts explorer.exe in the current session.
#   -Fix -RestartClipboardService tries to restart the per-user cbdhsvc_*
#   service and reports clearly when Windows denies that without Administrator.
#
# Modes (mutually exclusive):
#   Default            Diagnose clipboard owner/formats/lock holders, clipboard
#                      tools, history settings, and text/Unicode/image
#                      round-trips. Saves the clipboard (text, RTF, HTML,
#                      image, file-drop list) first and restores it afterwards
#                      unless -NoRestore.
#   -Fix               Default diagnose + remediation: PowerToys Mouse Without
#                      Borders Share Clipboard, VSCodeVim vim.handleKeys,
#                      optional -RestartExplorer / -RestartClipboardService.
#                      Every edited file is backed up to .\backups\ first.
#   -Watch             Opt-in, foreground, time-bounded (-Seconds) clipboard
#                      change recorder. Log: .\reports\watch-<stamp>.log.
#   -TerminalPaste     Terminal host/config inspection + interactive paste
#                      self-test (token pasted into a prompt in this terminal).
#   -BrowserTest       Temporary loopback page tests whether a browser can
#                      write to the clipboard; reads browser clipboard policies.
#   -BrowserPasteTest  Temporary loopback page checks whether a browser can
#                      receive pasted text; reports formats and lengths only.
#   -ExportForCursor   Read clipboard image/file-drop and write a PNG under
#                      .\output\. Does NOT run round-trip tests.
#
# Side effects (by mode):
#   Diagnose:       clipboard temporarily overwritten by test data, then
#                   restored; writes .\reports\report-<stamp>.json.
#   -Fix:           may edit %LOCALAPPDATA%\Microsoft\PowerToys\MouseWithoutBorders\settings.json
#                   and %APPDATA%\{Cursor,Code,Code - Insiders,VSCodium}\User\settings.json
#                   (backup first); may Stop-Process/Start-Process PowerToys*
#                   and explorer.exe; may Restart-Service cbdhsvc_*.
#   -Watch:         reads the clipboard after every change (like any clipboard
#                   listener); writes .\reports\watch-<stamp>.log + report.
#   -TerminalPaste: puts paste-test tokens on the clipboard, then restores it;
#                   may Import-Module PSReadLine and suppresses PSReadLine
#                   history for the test prompts (handler restored afterwards).
#   -BrowserTest:   opens a browser tab to http://127.0.0.1:<random port>/;
#                   the page writes a token to the clipboard; the listener is
#                   stopped afterwards and the clipboard restored.
#   -BrowserPasteTest: opens a loopback page; paste content is not displayed,
#                      transmitted, or saved. Only format names and text lengths
#                      are reported; clipboard contents are not changed.
#   -ExportForCursor: creates .\output\ if missing; writes
#                   clipboard-for-cursor-*.png; may Start-Process explorer.exe
#                   when -OpenFolder is set.
#   -WhatIf:        previews every change above (clipboard writes, file writes,
#                   backups, process/service restarts, browser launch,
#                   report/log files) without performing it. Read-only checks
#                   still run.
#
# Idempotency:
#   Diagnose/-TerminalPaste/-BrowserTest mutate the clipboard temporarily.
#   -Fix edits are idempotent: already-correct values are left untouched and
#   no backup is made for them. Reports, logs and exports are new timestamped
#   files per run.
#
# Safety boundaries:
#   Never changes settings without -Fix. Never prints or saves clipboard
#   payloads unless -ShowText (only lengths, formats, owners and generated
#   test tokens). Does not patch Cursor / VS Code / Windows Terminal. Does not
#   claim malware/compromise detection. No network access beyond a
#   loopback-only listener during browser tests. No background persistence.
#
# Recovery:
#   Settings: copy .\backups\<name>_<stamp>.json back over the original file.
#   Clipboard: if restore was skipped (-NoRestore) or failed, re-copy the data.
#   PowerToys: re-enable Share Clipboard in the PowerToys UI if needed.
#   Explorer: if it does not come back, run explorer.exe from Task Manager.
#   Delete .\output\, .\reports\, .\backups\ contents when finished.
#
# Exit codes:
#   0 = no remaining $script:Issues
#   1 = one or more remaining issues
#   2 = hard error recorded ($script:HadError) or invalid mode combination
################################################################################

<#
.SYNOPSIS
    Diagnose Windows clipboard and terminal paste problems, fix common
    blockers, and export clipboard images for Cursor Agent on Windows.

.DESCRIPTION
    Single-file entrypoint for local clipboard health checks on Windows.

    Responsibility:
      - Verify text/Unicode/image clipboard round-trips without destroying the
        user's clipboard (save -> test -> restore) and without false failures
        from transient clipboard locks (bounded read retries, 10 x 50 ms).
      - Explain who owns / holds the clipboard via P/Invoke
        (GetOpenClipboardWindow, GetClipboardOwner, GetClipboardSequenceNumber,
        CountClipboardFormats, EnumClipboardFormats, GetClipboardFormatName).
      - Record clipboard changes on demand (-Watch), test the terminal paste
        path (-TerminalPaste) and the browser write path (-BrowserTest).
      - Optionally remediate known blockers (-Fix) with timestamped backups.
      - Export clipboard images to PNG for Cursor Agent drag-and-drop.

    System position:
      Standalone script. No packages, services or databases. Network use is
      limited to a loopback-only TcpListener during -BrowserTest. Unit tests
      for the pure helpers live in tests\Run-Tests.ps1.

    Invariants:
      - Modes are mutually exclusive (see safety header).
      - Settings files are only written under -Fix, after a backup, and only
        when $PSCmdlet.ShouldProcess approves (so -WhatIf previews them).
      - Clipboard payloads are never printed or saved unless -ShowText.
      - Exit status is derived from $script:HadError and $script:Issues only.
      - ShareClipboard edits use a targeted regex replace to avoid rewriting
        unrelated PowerToys settings fields.

    Input assumptions:
      - Windows 10/11, Windows PowerShell 5.1 (primary) or PowerShell 7+.
      - Interactive desktop session; STA thread for WinForms clipboard APIs.
      - -TerminalPaste self-test and -Watch keyboard capture need an
        interactive console (skipped automatically when input is redirected).

    Output guarantees:
      - Console PASS/FAIL/WARN/INFO/ERROR lines describing each check.
      - .\reports\report-<stamp>.json with every check result (unless
        -NoReport or -WhatIf).
      - Process exit code 0, 1, or 2 as documented in the safety header.

.PARAMETER Fix
    Apply remediation for detected blockers (Mouse Without Borders Share
    Clipboard, VSCodeVim vim.handleKeys). Each modified file is backed up to
    .\backups\ first. Combine with -WhatIf to preview.

.PARAMETER NoRestore
    Do not restore the clipboard saved before destructive tests.

.PARAMETER RestartExplorer
    With -Fix: restart explorer.exe in the current session.

.PARAMETER RestartClipboardService
    With -Fix: try to restart the per-user clipboard service (cbdhsvc_*).
    Usually requires Administrator; access denied is reported clearly.

.PARAMETER Watch
    Record clipboard changes in the foreground for -Seconds seconds.

.PARAMETER Seconds
    Duration of -Watch (5..3600, default 120).

.PARAMETER ShowText
    Include up to the first 40 characters of clipboard text in -Watch output,
    in mismatch diagnostics and in the JSON report. Off by default (privacy).

.PARAMETER TerminalPaste
    Diagnose the terminal this script runs in and run an interactive paste
    self-test (Ctrl+V, Ctrl+Shift+V, Shift+Insert, right-click).

.PARAMETER SkipSelfTest
    With -TerminalPaste: only inspect configuration, skip the interactive test.

.PARAMETER BrowserTest
    Serve a one-page clipboard write test from 127.0.0.1 and report whether
    the token reached the Windows clipboard and which process wrote it.

.PARAMETER BrowserPasteTest
Serve a local paste-receiver page and report whether the browser received
text from the clipboard. Pasted content is not displayed or transmitted;
only clipboard format names and text lengths are reported.

.PARAMETER Browser
Browser for browser tests: default (system default), msedge, or chrome.

.PARAMETER BrowserTimeoutSeconds
    How long a browser test waits for the page interaction (5..600, default 30).

.PARAMETER InPrivate
    With -BrowserTest or -BrowserPasteTest and -Browser msedge|chrome: open the
    page in an InPrivate / incognito window to compare against the normal profile.

.PARAMETER ExportForCursor
    Save the current clipboard image to .\output\ as a PNG for drag-and-drop
    into Cursor. Does not run destructive clipboard tests.

.PARAMETER OpenFolder
    After -ExportForCursor, open File Explorer to the saved PNG.

.PARAMETER NoReport
    Do not write .\reports\report-<stamp>.json.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Fix -WhatIf

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -TerminalPaste

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Watch -Seconds 120

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -BrowserTest -Browser msedge

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -BrowserPasteTest -Browser msedge

.EXAMPLE
    # 1) Copy a screenshot  2) run this  3) drag the PNG into Cursor Agent
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -ExportForCursor -OpenFolder

.NOTES
    Engineering Notes:
      - Native clipboard calls live in an Add-Type C# helper (namespace
        ClipDiagV2) so lock sampling at 10 ms and the clipboard listener
        window run without PowerShell loop overhead. Bump the namespace when
        the C# source changes (types cannot be redefined in one session).
      - Reads retry on OpenClipboard failure and on empty/stale content,
        because clipboard listeners (explorer.exe, clipboard history) open
        the clipboard briefly after every change.
      - Regex-based ShareClipboard update preserves other settings (including
        secrets) better than ConvertTo-Json round-tripping on Windows
        PowerShell 5.1.
      - Export mode is separate from diagnose mode so a copied screenshot is
        not destroyed by the round-trip tests.

    Audit Notes:
      Critical mutations: clipboard overwrite + restore (diagnose,
      -TerminalPaste, -BrowserTest), settings.json edits with backups (-Fix),
      process/service restarts (-Fix), PNG/report/log writes.
      Detect via console summary lines, .\backups\, .\reports\, .\output\
      and the JSON report's checks/fixesApplied arrays.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Fix,
    [switch]$NoRestore,
    [switch]$RestartExplorer,
    [switch]$RestartClipboardService,
    [switch]$Watch,
    [ValidateRange(5, 3600)]
    [int]$Seconds = 120,
    [switch]$ShowText,
    [switch]$TerminalPaste,
    [switch]$SkipSelfTest,
    [switch]$BrowserTest,
    [switch]$BrowserPasteTest,
    [ValidateSet('default', 'msedge', 'chrome')]
    [string]$Browser = 'default',
    [ValidateRange(5, 600)]
    [int]$BrowserTimeoutSeconds = 30,
    [switch]$InPrivate,
    [switch]$ExportForCursor,
    [switch]$OpenFolder,
    [switch]$NoReport
)

$ErrorActionPreference = "Stop"
# Script-scoped run state used for summary, JSON report and exit codes.
$script:ToolVersion = '2.1.0'
$script:HadFailure = $false
$script:HadError = $false
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:FixesApplied = New-Object System.Collections.Generic.List[string]
$script:Checks = New-Object System.Collections.Generic.List[object]
$script:CurrentSection = ''
# Prefer $PSScriptRoot so output paths stay repo-relative even if cwd differs.
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:Cmdlet = $PSCmdlet
$script:NativeReady = $false
$script:NativeTried = $false
$script:VimClipboardKeys = @('<C-c>', '<C-v>')
$script:BrowserProcessNames = @('msedge', 'chrome', 'firefox', 'brave', 'opera', 'vivaldi', 'iexplore', 'arc')
$script:BoundParams = [ordered]@{}
foreach ($key in $PSBoundParameters.Keys) {
    $script:BoundParams[$key] = [string]$PSBoundParameters[$key]
}

$script:EditorTargets = @(
    [pscustomobject]@{ Name = 'Cursor';           Settings = (Join-Path $env:APPDATA 'Cursor\User\settings.json');          Keybindings = (Join-Path $env:APPDATA 'Cursor\User\keybindings.json');          Extensions = (Join-Path $env:USERPROFILE '.cursor\extensions') }
    [pscustomobject]@{ Name = 'VS Code';          Settings = (Join-Path $env:APPDATA 'Code\User\settings.json');            Keybindings = (Join-Path $env:APPDATA 'Code\User\keybindings.json');            Extensions = (Join-Path $env:USERPROFILE '.vscode\extensions') }
    [pscustomobject]@{ Name = 'VS Code Insiders'; Settings = (Join-Path $env:APPDATA 'Code - Insiders\User\settings.json'); Keybindings = (Join-Path $env:APPDATA 'Code - Insiders\User\keybindings.json'); Extensions = (Join-Path $env:USERPROFILE '.vscode-insiders\extensions') }
    [pscustomobject]@{ Name = 'VSCodium';         Settings = (Join-Path $env:APPDATA 'VSCodium\User\settings.json');        Keybindings = (Join-Path $env:APPDATA 'VSCodium\User\keybindings.json');        Extensions = (Join-Path $env:USERPROFILE '.vscode-oss\extensions') }
)

$script:KnownClipboardTools = @(
    [pscustomobject]@{ Name = 'Ditto (clipboard manager)';                 Processes = @('Ditto') }
    [pscustomobject]@{ Name = 'CopyQ (clipboard manager)';                 Processes = @('copyq') }
    [pscustomobject]@{ Name = 'ClipboardFusion';                           Processes = @('ClipboardFusion') }
    [pscustomobject]@{ Name = 'PowerToys Advanced Paste';                  Processes = @('PowerToys.AdvancedPaste') }
    [pscustomobject]@{ Name = 'PowerToys Mouse Without Borders';           Processes = @('PowerToys.MouseWithoutBorders', 'PowerToys.MouseWithoutBordersHelper', 'PowerToys.MouseWithoutBordersService') }
    [pscustomobject]@{ Name = 'AutoHotkey';                                Processes = @('AutoHotkey', 'AutoHotkey64', 'AutoHotkey32', 'AutoHotkeyU64', 'AutoHotkeyU32', 'AutoHotkeyA32', 'AutoHotkeyUX') }
    [pscustomobject]@{ Name = 'ShareX';                                    Processes = @('ShareX') }
    [pscustomobject]@{ Name = 'Remote Desktop clipboard (rdpclip)';        Processes = @('rdpclip') }
    [pscustomobject]@{ Name = 'VMware Tools';                              Processes = @('vmtoolsd') }
    [pscustomobject]@{ Name = 'VirtualBox Guest Additions';                Processes = @('VBoxTray') }
    [pscustomobject]@{ Name = 'TeamViewer';                                Processes = @('TeamViewer', 'TeamViewer_Service') }
    [pscustomobject]@{ Name = 'AnyDesk';                                   Processes = @('AnyDesk') }
    [pscustomobject]@{ Name = 'Phone Link';                                Processes = @('PhoneExperienceHost', 'YourPhone', 'YourPhoneServer') }
    [pscustomobject]@{ Name = 'KeePass / KeePassXC (clipboard auto-clear)'; Processes = @('KeePass', 'KeePassXC') }
    [pscustomobject]@{ Name = 'Other clipboard managers';                  Processes = @('Snipaste', 'ClipClip', 'Clipdiary', '1Clipboard', 'ClipAngel') }
)

$script:Report = [ordered]@{
    tool         = 'clipboard-test.ps1'
    version      = $script:ToolVersion
    timestamp    = (Get-Date).ToString('o')
    mode         = $null
    parameters   = $script:BoundParams
    environment  = [ordered]@{}
    checks       = $script:Checks
    clipboard    = [ordered]@{}
    config       = [ordered]@{}
    fixesApplied = $script:FixesApplied
    issues       = $script:Issues
    exitCode     = $null
}

# Windows Terminal built-in paste/copy bindings, used only when the packaged
# defaults.json cannot be read (e.g. PowerShell 7 without the Appx module).
$script:WtBuiltInDefaultsFallback = @'
{
  "actions": [
    { "command": "paste", "id": "Terminal.PasteFromClipboard" },
    { "command": { "action": "copy", "singleLine": false }, "id": "Terminal.CopyToClipboard" }
  ],
  "keybindings": [
    { "keys": "ctrl+shift+c", "id": "Terminal.CopyToClipboard" },
    { "keys": "ctrl+insert", "id": "Terminal.CopyToClipboard" },
    { "keys": "ctrl+shift+v", "id": "Terminal.PasteFromClipboard" },
    { "keys": "shift+insert", "id": "Terminal.PasteFromClipboard" }
  ],
  "trimPaste": true
}
'@

$script:NativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace ClipDiagV2
{
    public class ClipSnapshot
    {
        public DateTime Time;
        public uint Sequence;
        public int OwnerPid;
        public string OwnerName;
        public int OpenWindowPid;
        public string OpenWindowName;
        public int ForegroundPid;
        public string ForegroundName;
        public int FormatCount;
        public string[] Formats;
        public bool HasText;
        public int TextLength;
        public string Preview;
        public int OpenAttempts;
        public bool OpenFailed;
        public string Source;
    }

    public class ReadResult
    {
        public bool Matched;
        public int Attempts;
        public int OpenFailures;
        public int Mismatches;
        public int BlockerPid;
        public string BlockerName;
        public int LastLength;
        public string LastText;
    }

    public class LockEpisode
    {
        public DateTime Start;
        public int Pid;
        public string Name;
        public double DurationMs;
    }

    public class LockTotal
    {
        public int Pid;
        public string Name;
        public double TotalMs;
        public int Episodes;
        public double LongestMs;
    }

    public class FocusChange
    {
        public DateTime Time;
        public int Pid;
        public string Name;
    }

    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int ptX;
            public int ptY;
        }

        [DllImport("user32.dll")] public static extern IntPtr GetOpenClipboardWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner();
        [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")] public static extern int CountClipboardFormats();
        [DllImport("user32.dll", SetLastError = true)] public static extern uint EnumClipboardFormats(uint format);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClipboardFormatName(uint format, StringBuilder name, int maxCount);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool OpenClipboard(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool CloseClipboard();
        [DllImport("user32.dll")] public static extern bool IsClipboardFormatAvailable(uint format);
        [DllImport("user32.dll")] public static extern IntPtr GetClipboardData(uint format);
        [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr handle);
        [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr handle);
        [DllImport("kernel32.dll")] public static extern UIntPtr GlobalSize(IntPtr handle);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll", SetLastError = true)] public static extern bool AddClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll", SetLastError = true)] public static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern uint MsgWaitForMultipleObjects(uint count, IntPtr[] handles, bool waitAll, uint milliseconds, uint wakeMask);
        [DllImport("user32.dll")] public static extern bool PeekMessage(out MSG msg, IntPtr hwnd, uint filterMin, uint filterMax, uint removeMsg);
        [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG msg);
        [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG msg);
        [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint period);
        [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint period);
    }

    public class LockSampler
    {
        public Dictionary<int, LockTotal> Totals = new Dictionary<int, LockTotal>();
        public List<LockEpisode> Episodes = new List<LockEpisode>();
        public int Samples;
        public int LockedSamples;
        public int MaxEpisodes = 5000;
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private int curPid;
        private double curStartMs;
        private DateTime curStartTime;

        public void Sample()
        {
            Samples++;
            int pid = Clip.WindowPid(Native.GetOpenClipboardWindow());
            double now = clock.Elapsed.TotalMilliseconds;
            if (pid != 0) LockedSamples++;
            if (pid == curPid) return;
            if (curPid != 0) Close(now);
            if (pid != 0)
            {
                curPid = pid;
                curStartMs = now;
                curStartTime = DateTime.Now;
            }
        }

        private void Close(double now)
        {
            double dur = now - curStartMs;
            if (dur < 1) dur = 1;
            LockEpisode e = new LockEpisode();
            e.Start = curStartTime;
            e.Pid = curPid;
            e.Name = Clip.ProcName(curPid);
            e.DurationMs = dur;
            if (Episodes.Count < MaxEpisodes) Episodes.Add(e);
            LockTotal t;
            if (!Totals.TryGetValue(curPid, out t))
            {
                t = new LockTotal();
                t.Pid = curPid;
                t.Name = e.Name;
                Totals[curPid] = t;
            }
            t.TotalMs += dur;
            t.Episodes++;
            if (dur > t.LongestMs) t.LongestMs = dur;
            curPid = 0;
        }

        public void Finish()
        {
            if (curPid != 0) Close(clock.Elapsed.TotalMilliseconds);
        }

        public LockEpisode[] TakeEpisodes()
        {
            LockEpisode[] a = Episodes.ToArray();
            Episodes.Clear();
            return a;
        }

        public LockTotal[] GetTotals()
        {
            return new List<LockTotal>(Totals.Values).ToArray();
        }
    }

    public static class Clip
    {
        public const uint CF_UNICODETEXT = 13;
        private static readonly Dictionary<int, string> NameCache = new Dictionary<int, string>();

        public static string ProcName(int pid)
        {
            if (pid == 0) return "";
            if (pid < 0) return "(unknown)";
            string name;
            lock (NameCache)
            {
                if (NameCache.TryGetValue(pid, out name)) return name;
            }
            try
            {
                using (Process p = Process.GetProcessById(pid)) { name = p.ProcessName; }
            }
            catch (Exception)
            {
                name = "(exited)";
            }
            lock (NameCache) { NameCache[pid] = name; }
            return name;
        }

        public static int WindowPid(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return 0;
            uint pid;
            Native.GetWindowThreadProcessId(hwnd, out pid);
            return pid == 0 ? -1 : (int)pid;
        }

        public static string FormatName(uint f)
        {
            switch (f)
            {
                case 1: return "CF_TEXT";
                case 2: return "CF_BITMAP";
                case 3: return "CF_METAFILEPICT";
                case 4: return "CF_SYLK";
                case 5: return "CF_DIF";
                case 6: return "CF_TIFF";
                case 7: return "CF_OEMTEXT";
                case 8: return "CF_DIB";
                case 9: return "CF_PALETTE";
                case 10: return "CF_PENDATA";
                case 11: return "CF_RIFF";
                case 12: return "CF_WAVE";
                case 13: return "CF_UNICODETEXT";
                case 14: return "CF_ENHMETAFILE";
                case 15: return "CF_HDROP";
                case 16: return "CF_LOCALE";
                case 17: return "CF_DIBV5";
                case 0x80: return "CF_OWNERDISPLAY";
                case 0x81: return "CF_DSPTEXT";
                case 0x82: return "CF_DSPBITMAP";
                case 0x83: return "CF_DSPMETAFILEPICT";
                case 0x8E: return "CF_DSPENHMETAFILE";
            }
            if (f >= 0x200 && f <= 0x2FF) return "CF_PRIVATEFIRST+" + (f - 0x200);
            if (f >= 0x300 && f <= 0x3FF) return "CF_GDIOBJFIRST+" + (f - 0x300);
            StringBuilder sb = new StringBuilder(256);
            int n = Native.GetClipboardFormatName(f, sb, sb.Capacity);
            return n > 0 ? sb.ToString() : ("#" + f);
        }

        public static bool TryOpen(int maxAttempts, int delayMs, out int attempts)
        {
            attempts = 0;
            for (int i = 1; i <= maxAttempts; i++)
            {
                attempts = i;
                if (Native.OpenClipboard(IntPtr.Zero)) return true;
                if (i < maxAttempts) Thread.Sleep(delayMs);
            }
            return false;
        }

        private static string ReadUnicodeTextWhileOpen()
        {
            if (!Native.IsClipboardFormatAvailable(CF_UNICODETEXT)) return null;
            IntPtr h = Native.GetClipboardData(CF_UNICODETEXT);
            if (h == IntPtr.Zero) return null;
            IntPtr p = Native.GlobalLock(h);
            if (p == IntPtr.Zero) return null;
            try
            {
                long size = (long)Native.GlobalSize(h).ToUInt64();
                int maxChars = (int)Math.Min(size / 2, (long)int.MaxValue);
                if (maxChars <= 0) return "";
                string s = Marshal.PtrToStringUni(p, maxChars);
                int nul = s.IndexOf('\0');
                return nul >= 0 ? s.Substring(0, nul) : s;
            }
            finally
            {
                Native.GlobalUnlock(h);
            }
        }

        private static string[] FormatsWhileOpen()
        {
            List<string> list = new List<string>();
            uint f = 0;
            while ((f = Native.EnumClipboardFormats(f)) != 0)
            {
                list.Add(FormatName(f));
                if (list.Count > 200) break;
            }
            return list.ToArray();
        }

        public static string MakePreview(string text, int maxChars)
        {
            if (text == null) return null;
            string p = text.Length > maxChars ? text.Substring(0, maxChars) : text;
            p = p.Replace("\r", "\\r").Replace("\n", "\\n").Replace("\t", "\\t");
            if (text.Length > maxChars) p += "...";
            return p;
        }

        public static ClipSnapshot Snapshot(bool includeText, int previewChars, int maxAttempts, int delayMs)
        {
            ClipSnapshot s = new ClipSnapshot();
            s.Time = DateTime.Now;
            s.Sequence = Native.GetClipboardSequenceNumber();
            s.OwnerPid = WindowPid(Native.GetClipboardOwner());
            s.OwnerName = ProcName(s.OwnerPid);
            s.OpenWindowPid = WindowPid(Native.GetOpenClipboardWindow());
            s.OpenWindowName = ProcName(s.OpenWindowPid);
            s.ForegroundPid = WindowPid(Native.GetForegroundWindow());
            s.ForegroundName = ProcName(s.ForegroundPid);
            s.FormatCount = Native.CountClipboardFormats();
            s.TextLength = -1;
            s.Formats = new string[0];
            int attempts;
            if (TryOpen(maxAttempts, delayMs, out attempts))
            {
                s.OpenAttempts = attempts;
                try
                {
                    s.Formats = FormatsWhileOpen();
                    string t = ReadUnicodeTextWhileOpen();
                    if (t != null)
                    {
                        s.HasText = true;
                        s.TextLength = t.Length;
                        if (includeText) s.Preview = MakePreview(t, previewChars);
                    }
                }
                finally
                {
                    Native.CloseClipboard();
                }
            }
            else
            {
                s.OpenAttempts = attempts;
                s.OpenFailed = true;
            }
            return s;
        }

        // expected == null means "any text"; retries on open failure and on empty/stale content.
        public static ReadResult ReadTextExpect(string expected, int maxAttempts, int delayMs)
        {
            ReadResult r = new ReadResult();
            r.LastLength = -1;
            for (int i = 1; i <= maxAttempts; i++)
            {
                r.Attempts = i;
                if (Native.OpenClipboard(IntPtr.Zero))
                {
                    string t = null;
                    try { t = ReadUnicodeTextWhileOpen(); }
                    finally { Native.CloseClipboard(); }
                    r.LastText = t;
                    r.LastLength = t == null ? -1 : t.Length;
                    bool ok = expected == null ? t != null : string.Equals(t, expected, StringComparison.Ordinal);
                    if (ok)
                    {
                        r.Matched = true;
                        break;
                    }
                    r.Mismatches++;
                }
                else
                {
                    r.OpenFailures++;
                    int pid = WindowPid(Native.GetOpenClipboardWindow());
                    if (pid != 0) r.BlockerPid = pid;
                    else if (r.BlockerPid == 0) r.BlockerPid = -1;
                }
                if (i < maxAttempts) Thread.Sleep(delayMs);
            }
            r.BlockerName = ProcName(r.BlockerPid);
            return r;
        }

        public static LockSampler SampleLocks(int durationMs, int intervalMs)
        {
            LockSampler s = new LockSampler();
            bool raised = Native.timeBeginPeriod(1) == 0;
            try
            {
                Stopwatch sw = Stopwatch.StartNew();
                while (sw.ElapsedMilliseconds < durationMs)
                {
                    s.Sample();
                    Thread.Sleep(intervalMs);
                }
                s.Finish();
            }
            finally
            {
                if (raised) Native.timeEndPeriod(1);
            }
            return s;
        }
    }

    public class Watcher : NativeWindow, IDisposable
    {
        public bool UsingListener;
        public int ListenerError;
        public bool IncludeText;
        public int PreviewChars = 40;
        public LockSampler Locks = new LockSampler();
        public List<ClipSnapshot> Pending = new List<ClipSnapshot>();
        public List<FocusChange> PendingFocus = new List<FocusChange>();
        public Dictionary<string, double> FocusMs = new Dictionary<string, double>();
        private uint lastSeq;
        private int lastFgPid = -2;
        private string lastFgName = "";
        private readonly Stopwatch clock = Stopwatch.StartNew();
        private double lastTick;
        private bool timerRaised;
        private bool disposed;

        public Watcher(bool includeText, bool forcePolling)
        {
            IncludeText = includeText;
            CreateParams cp = new CreateParams();
            cp.Caption = "ClipDiagWatcher";
            cp.Parent = new IntPtr(-3); // HWND_MESSAGE: message-only, never visible
            CreateHandle(cp);
            if (!forcePolling)
            {
                UsingListener = Native.AddClipboardFormatListener(Handle);
                if (!UsingListener) ListenerError = Marshal.GetLastWin32Error();
            }
            lastSeq = Native.GetClipboardSequenceNumber();
            timerRaised = Native.timeBeginPeriod(1) == 0;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x031D) Capture("listener"); // WM_CLIPBOARDUPDATE
            base.WndProc(ref m);
        }

        private void Capture(string source)
        {
            ClipSnapshot s = Clip.Snapshot(IncludeText, PreviewChars, 10, 20);
            s.Source = source;
            lastSeq = s.Sequence;
            Pending.Add(s);
        }

        public void Pump(int milliseconds)
        {
            Stopwatch sw = Stopwatch.StartNew();
            while (sw.ElapsedMilliseconds < milliseconds)
            {
                Native.MsgWaitForMultipleObjects(0, null, false, 10, 0x04FF);
                Native.MSG msg;
                while (Native.PeekMessage(out msg, IntPtr.Zero, 0, 0, 1))
                {
                    Native.TranslateMessage(ref msg);
                    Native.DispatchMessage(ref msg);
                }
                if (!UsingListener)
                {
                    uint seq = Native.GetClipboardSequenceNumber();
                    if (seq != lastSeq) Capture("poll");
                }
                Locks.Sample();
                SampleFocus();
            }
        }

        private void SampleFocus()
        {
            double now = clock.Elapsed.TotalMilliseconds;
            double dt = now - lastTick;
            lastTick = now;
            if (lastFgName.Length > 0)
            {
                double v;
                FocusMs.TryGetValue(lastFgName, out v);
                FocusMs[lastFgName] = v + dt;
            }
            int pid = Clip.WindowPid(Native.GetForegroundWindow());
            if (pid != lastFgPid)
            {
                lastFgPid = pid;
                lastFgName = Clip.ProcName(pid);
                FocusChange f = new FocusChange();
                f.Time = DateTime.Now;
                f.Pid = pid;
                f.Name = lastFgName;
                PendingFocus.Add(f);
            }
        }

        public ClipSnapshot[] TakeChanges()
        {
            ClipSnapshot[] a = Pending.ToArray();
            Pending.Clear();
            return a;
        }

        public FocusChange[] TakeFocus()
        {
            FocusChange[] a = PendingFocus.ToArray();
            PendingFocus.Clear();
            return a;
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            Locks.Finish();
            if (UsingListener) Native.RemoveClipboardFormatListener(Handle);
            DestroyHandle();
            if (timerRaised) Native.timeEndPeriod(1);
        }
    }
}
'@

#region Output helpers

function Add-CheckRecord {
    <#
    .SYNOPSIS
        Append a console result line to the in-memory check list (JSON report).
    .NOTES
        Side effects: mutates $script:Checks only (tolerates it being absent,
        e.g. when helpers are loaded by tests).
        Audit Notes: messages must never contain clipboard payloads; callers
        only pass tokens, lengths, formats, owners and paths.
    #>
    param([string]$Level, [string]$Message)
    if ($null -ne $script:Checks) {
        $script:Checks.Add([pscustomobject]@{ section = $script:CurrentSection; level = $Level; message = $Message })
    }
}

function Write-Section {
    param([string]$Title)
    $script:CurrentSection = $Title
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
    Add-CheckRecord -Level 'PASS' -Message $Message
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:HadFailure = $true
    Add-CheckRecord -Level 'FAIL' -Message $Message
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    $script:HadError = $true
    Add-CheckRecord -Level 'ERROR' -Message $Message
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message"
    Add-CheckRecord -Level 'INFO' -Message $Message
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host "WARN: $Message" -ForegroundColor Yellow
    Add-CheckRecord -Level 'WARN' -Message $Message
}

function Add-Issue {
    <#
    .SYNOPSIS
        Record a remaining issue once (drives exit code 1).
    .NOTES
        Side effects: mutates $script:Issues. Audit Notes: issue text is shown
        in the summary and saved in the JSON report.
    #>
    param([string]$Text)
    if (-not $script:Issues.Contains($Text)) {
        $script:Issues.Add($Text)
    }
}

function Confirm-Change {
    <#
    .SYNOPSIS
        Central ShouldProcess gate so every change honors -WhatIf / -Confirm.
    .OUTPUTS
        System.Boolean - $true when the change may proceed.
    .NOTES
        Uses the script-level $PSCmdlet captured at startup. Returns $true when
        no cmdlet context exists (helpers loaded by tests).
        Audit Notes: every clipboard write, file write, backup, process or
        service restart and browser launch must be wrapped by this function.
    #>
    param([string]$Target, [string]$Action)
    if ($null -eq $script:Cmdlet) {
        return $true
    }
    return $script:Cmdlet.ShouldProcess($Target, $Action)
}

function Format-ProcessLabel {
    <#
    .SYNOPSIS
        Render "name (pid)" or "(none)" for a process id.
    .NOTES
        Pure function. Audit Notes: no side effects.
    #>
    param([int]$ProcessId, [string]$Name)
    if ($ProcessId -eq 0) {
        return '(none)'
    }
    if ([string]::IsNullOrEmpty($Name)) {
        $Name = '(unknown)'
    }
    return "$Name ($ProcessId)"
}

#endregion

#region Pure helpers (covered by tests\Run-Tests.ps1)

function Remove-JsonComments {
    <#
    .SYNOPSIS
        Strip // and /* */ comments and trailing commas from JSONC text.
    .DESCRIPTION
        String literals (including escaped quotes and URLs containing //) are
        preserved verbatim. Text without comments/trailing commas is returned
        unchanged, which callers use to detect JSONC.
    .OUTPUTS
        System.String
    .NOTES
        Pure function. Unterminated block comments are left in place so the
        subsequent JSON parse fails visibly instead of silently losing data.
        Audit Notes: no side effects.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $keepStrings = [System.Text.RegularExpressions.MatchEvaluator] {
        param($m)
        if ($m.Groups[1].Success) { return $m.Value }
        return ''
    }
    $noComments = [regex]::Replace($Text, '("(?:\\.|[^"\\])*")|(//[^\r\n]*)|(/\*[\s\S]*?\*/)', $keepStrings)
    return [regex]::Replace($noComments, '("(?:\\.|[^"\\])*")|,(?=\s*[\}\]])', $keepStrings)
}

function Test-JsonHasCommentsOrTrailingCommas {
    <#
    .SYNOPSIS
        True when the text contains JSONC-only syntax (comments/trailing commas).
    .NOTES
        Pure function. Used to refuse automatic edits of commented settings
        files (a rewrite would drop the comments). Audit Notes: no side effects.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) {
        return $false
    }
    return ((Remove-JsonComments -Text $Text) -cne $Text)
}

function ConvertTo-NormalizedChord {
    <#
    .SYNOPSIS
        Normalize a key chord ("Shift+Ctrl+V") to "ctrl+shift+v".
    .NOTES
        Pure function. Modifier order: ctrl, alt, shift, win.
        Audit Notes: no side effects.
    #>
    param([AllowNull()][AllowEmptyString()][string]$Keys)
    if ([string]::IsNullOrWhiteSpace($Keys)) {
        return ''
    }
    $alias = @{ 'control' = 'ctrl'; 'ins' = 'insert'; 'windows' = 'win' }
    $modifierOrder = @('ctrl', 'alt', 'shift', 'win')
    $mods = New-Object System.Collections.Generic.List[string]
    $key = ''
    foreach ($raw in ($Keys.ToLowerInvariant() -split '\+')) {
        $part = $raw.Trim()
        if ($part -eq '') { continue }
        if ($alias.ContainsKey($part)) { $part = $alias[$part] }
        if ($modifierOrder -contains $part) {
            if (-not $mods.Contains($part)) { $mods.Add($part) }
        }
        else {
            $key = $part
        }
    }
    $ordered = @($modifierOrder | Where-Object { $mods.Contains($_) })
    if ($key) {
        $ordered += $key
    }
    return ($ordered -join '+')
}

function Get-WtCommandName {
    <#
    .SYNOPSIS
        Extract the action name from a Windows Terminal "command" value.
    .NOTES
        Pure function. String commands return as-is; object commands return
        their "action" property. Audit Notes: no side effects.
    #>
    param([AllowNull()][object]$Command)
    if ($null -eq $Command) {
        return $null
    }
    if ($Command -is [string]) {
        return $Command
    }
    if ($null -ne $Command.PSObject.Properties['action'] -and $Command.action) {
        return [string]$Command.action
    }
    return $null
}

function Resolve-WindowsTerminalBindings {
    <#
    .SYNOPSIS
        Resolve what Windows Terminal key chords are bound to (defaults + user).
    .DESCRIPTION
        Supports both settings formats:
          - legacy:  "actions": [ { "command": "paste", "keys": "ctrl+v" } ]
          - modern:  "actions": [ { "command": ..., "id": "User.x" } ] plus
                     "keybindings": [ { "id": "Terminal.PasteFromClipboard", "keys": "ctrl+v" } ]
        User entries override defaults per chord. "id": null or
        "command": "unbound"/null means the chord is explicitly unbound.
        Also collects paste-related options (copyOnSelect, trimPaste,
        warning.multiLinePaste, warning.largePaste, rightClick*, ...).
    .OUTPUTS
        PSCustomObject { Bindings[]; Options[]; Errors[] }
    .NOTES
        Pure function (text in, objects out). JSONC is stripped first.
        Audit Notes: no side effects; parse errors are returned, not thrown.
    #>
    param(
        [AllowNull()][AllowEmptyString()][string]$UserSettingsText,
        [AllowNull()][AllowEmptyString()][string]$DefaultsText,
        [string[]]$Chords = @('ctrl+v', 'ctrl+shift+v', 'shift+insert')
    )
    $errors = New-Object System.Collections.Generic.List[string]
    $actionsById = @{}
    $bindings = @{ defaults = @{}; user = @{} }
    $options = [ordered]@{}
    $optionPattern = '(?i)paste|copyOnSelect|copyFormatting|rightClick'

    foreach ($layer in @(@{ Name = 'defaults'; Text = $DefaultsText }, @{ Name = 'user'; Text = $UserSettingsText })) {
        if ([string]::IsNullOrWhiteSpace($layer.Text)) { continue }
        try {
            $json = (Remove-JsonComments -Text $layer.Text) | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            $errors.Add("$($layer.Name): $($_.Exception.Message)")
            continue
        }
        if ($null -eq $json) { continue }

        foreach ($arrName in @('actions', 'keybindings')) {
            if ($null -eq $json.PSObject.Properties[$arrName]) { continue }
            foreach ($entry in @($json.$arrName)) {
                if ($null -eq $entry -or $entry -is [string]) { continue }
                $props = $entry.PSObject.Properties
                $hasCommand = $null -ne $props['command']
                $hasId = $null -ne $props['id']
                $cmd = $null
                if ($hasCommand) {
                    $cmd = Get-WtCommandName -Command $entry.command
                    if ($null -eq $entry.command) { $cmd = 'unbound' }
                }
                if ($hasId -and $entry.id -and $cmd) {
                    $actionsById[[string]$entry.id] = $cmd
                }
                if ($null -eq $props['keys'] -or $null -eq $entry.keys) { continue }
                foreach ($k in @($entry.keys)) {
                    $chord = ConvertTo-NormalizedChord -Keys ([string]$k)
                    if (-not $chord) { continue }
                    $bindings[$layer.Name][$chord] = [pscustomobject]@{
                        Id       = $(if ($hasId) { $entry.id } else { $null })
                        IdIsNull = ($hasId -and $null -eq $entry.id)
                        Command  = $cmd
                    }
                }
            }
        }

        $scopes = New-Object System.Collections.Generic.List[object]
        $scopes.Add(@{ Obj = $json; Label = $layer.Name })
        $profilesObj = $null
        if ($null -ne $json.PSObject.Properties['profiles']) { $profilesObj = $json.profiles }
        if ($null -ne $profilesObj -and -not ($profilesObj -is [array])) {
            if ($null -ne $profilesObj.PSObject.Properties['defaults'] -and $null -ne $profilesObj.defaults) {
                $scopes.Add(@{ Obj = $profilesObj.defaults; Label = "$($layer.Name) profiles.defaults" })
            }
        }
        foreach ($scope in $scopes) {
            foreach ($p in $scope.Obj.PSObject.Properties) {
                if ($p.Name -match $optionPattern) {
                    $options[$p.Name] = [pscustomobject]@{ Name = $p.Name; Value = $p.Value; Source = $scope.Label }
                }
            }
        }
        $profileList = $null
        if ($profilesObj -is [array]) { $profileList = $profilesObj }
        elseif ($null -ne $profilesObj -and $null -ne $profilesObj.PSObject.Properties['list']) { $profileList = $profilesObj.list }
        foreach ($prof in @($profileList)) {
            if ($null -eq $prof) { continue }
            foreach ($p in $prof.PSObject.Properties) {
                if ($p.Name -match $optionPattern) {
                    $options["$($p.Name)@$($prof.name)"] = [pscustomobject]@{ Name = $p.Name; Value = $p.Value; Source = "$($layer.Name) profile '$($prof.name)'" }
                }
            }
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Chords) {
        $n = ConvertTo-NormalizedChord -Keys $c
        $entry = $null
        $source = 'none'
        if ($bindings.user.ContainsKey($n)) { $entry = $bindings.user[$n]; $source = 'user' }
        elseif ($bindings.defaults.ContainsKey($n)) { $entry = $bindings.defaults[$n]; $source = 'defaults' }
        $action = $null
        if ($null -ne $entry) {
            if ($entry.Command) { $action = $entry.Command }
            elseif ($entry.IdIsNull) { $action = 'unbound' }
            elseif ($entry.Id -and $actionsById.ContainsKey([string]$entry.Id)) { $action = $actionsById[[string]$entry.Id] }
            elseif ($entry.Id) { $action = "(unknown id $($entry.Id))" }
        }
        $results.Add([pscustomobject]@{
            Chord   = $n
            Action  = $(if ($action) { $action } else { 'not bound' })
            Id      = $(if ($null -ne $entry) { $entry.Id } else { $null })
            Source  = $source
            IsPaste = ($action -eq 'paste')
        })
    }

    return [pscustomobject]@{
        Bindings = $results.ToArray()
        Options  = @($options.Values)
        Errors   = $errors.ToArray()
    }
}

function Get-VsCodeTerminalKeybindingOverrides {
    <#
    .SYNOPSIS
        Find keybindings.json entries that affect terminal paste in VS Code/Cursor.
    .OUTPUTS
        PSCustomObject[] { Key; Command; When; Removes }
    .NOTES
        Pure function (text in, objects out). Throws on invalid JSON so the
        caller can report it. Audit Notes: no side effects.
    #>
    param([AllowNull()][AllowEmptyString()][string]$KeybindingsText)
    if ([string]::IsNullOrWhiteSpace($KeybindingsText)) {
        return @()
    }
    $arr = (Remove-JsonComments -Text $KeybindingsText) | ConvertFrom-Json -ErrorAction Stop
    $pasteChords = @('ctrl+v', 'ctrl+shift+v', 'shift+insert')
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($entry in @($arr)) {
        if ($null -eq $entry -or $entry -is [string]) { continue }
        $cmd = [string]$entry.command
        $chord = ConvertTo-NormalizedChord -Keys ([string]$entry.key)
        $when = [string]$entry.when
        $isPasteCommand = $cmd -match '^-?workbench\.action\.terminal\.paste'
        $isPasteChordInTerminal = ($pasteChords -contains $chord) -and ($when -match 'terminal')
        if ($isPasteCommand -or $isPasteChordInTerminal) {
            $found.Add([pscustomobject]@{ Key = $chord; Command = $cmd; When = $when; Removes = $cmd.StartsWith('-') })
        }
    }
    return $found.ToArray()
}

function Get-MissingVimClipboardKeys {
    <#
    .SYNOPSIS
        List vim.handleKeys entries that are not explicitly false.
    .NOTES
        Pure function. Ported from chinese-ime-fix\Fix-ChineseImeWordSelection.ps1.
        Audit Notes: no side effects.
    #>
    param([object]$Settings, [string[]]$Keys = @('<C-c>', '<C-v>'))
    $handle = $null
    if ($null -ne $Settings -and $null -ne $Settings.PSObject.Properties['vim.handleKeys']) {
        $handle = $Settings.'vim.handleKeys'
    }
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Keys) {
        $value = $null
        if ($null -ne $handle -and $null -ne $handle.PSObject.Properties[$k]) {
            $value = $handle.$k
        }
        if (-not ($value -is [bool] -and $value -eq $false)) {
            $missing.Add($k)
        }
    }
    return $missing.ToArray()
}

function Merge-VimHandleKeys {
    <#
    .SYNOPSIS
        Set vim.handleKeys.<key> = false for each key, keeping all other settings.
    .OUTPUTS
        PSCustomObject { Settings; Changed }
    .NOTES
        Mutates and returns the given settings object (in memory only).
        Idempotent: Changed is $false when every key is already false.
        Audit Notes: no file I/O; callers persist and back up.
    #>
    param([Parameter(Mandatory = $true)][object]$Settings, [string[]]$Keys = @('<C-c>', '<C-v>'))
    $changed = $false
    $handle = $null
    if ($null -ne $Settings.PSObject.Properties['vim.handleKeys']) {
        $handle = $Settings.'vim.handleKeys'
    }
    if ($null -eq $handle -or $handle -is [string] -or $handle -is [ValueType]) {
        $handle = [pscustomobject]@{}
        $Settings | Add-Member -NotePropertyName 'vim.handleKeys' -NotePropertyValue $handle -Force
        $changed = $true
    }
    foreach ($k in $Keys) {
        $prop = $handle.PSObject.Properties[$k]
        if ($null -ne $prop) {
            if (-not ($prop.Value -is [bool] -and $prop.Value -eq $false)) {
                $prop.Value = $false
                $changed = $true
            }
        }
        else {
            $handle | Add-Member -NotePropertyName $k -NotePropertyValue $false
            $changed = $true
        }
    }
    return [pscustomobject]@{ Settings = $Settings; Changed = $changed }
}

function ConvertTo-EditorSettingsJson {
    <#
    .SYNOPSIS
        Serialize editor settings to JSON, undoing PS 5.1 escaping of < > & '.
    .NOTES
        Pure function. Windows PowerShell's ConvertTo-Json emits \u003c etc.;
        those are restored so settings.json stays readable.
        Audit Notes: no side effects.
    #>
    param([Parameter(Mandatory = $true)][object]$Settings)
    $json = $Settings | ConvertTo-Json -Depth 32
    return ($json -replace '(?<!\\)\\u003c', '<' -replace '(?<!\\)\\u003e', '>' -replace '(?<!\\)\\u0026', '&' -replace '(?<!\\)\\u0027', "'")
}

function Get-PasteVerdict {
    <#
    .SYNOPSIS
        Classify a pasted line against the expected token.
    .OUTPUTS
        System.String - exact | exact-whitespace | contains | partial | empty | different
    .NOTES
        Pure function. Audit Notes: no side effects.
    #>
    param([string]$Expected, [AllowNull()][AllowEmptyString()][string]$Received)
    if ([string]::IsNullOrWhiteSpace($Received)) { return 'empty' }
    if ($Received -ceq $Expected) { return 'exact' }
    if ($Received.Trim() -ceq $Expected) { return 'exact-whitespace' }
    if ($Received.Contains($Expected)) { return 'contains' }
    if ($Expected.StartsWith($Received.Trim(), [System.StringComparison]::Ordinal)) { return 'partial' }
    return 'different'
}

#endregion

#region Clipboard primitives

function Initialize-ClipboardAssemblies {
    <#
    .SYNOPSIS
        Load WinForms/Drawing assemblies required for image clipboard APIs.
    .NOTES
        Side effects: loads System.Windows.Forms and System.Drawing into the
        current PowerShell process (idempotent if already loaded).
        Throws if Add-Type fails (missing desktop assemblies / constrained runspace).
        Audit Notes: no external state change.
    #>
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}

function Initialize-NativeClipboard {
    <#
    .SYNOPSIS
        Compile the ClipDiagV2 P/Invoke helper (once per session).
    .OUTPUTS
        System.Boolean - $true when native clipboard diagnostics are available.
    .NOTES
        Side effects: Add-Type compiles an in-memory assembly (no files).
        On failure the script continues with reduced diagnostics.
        Audit Notes: no external state change; failure is reported as ERROR.
    #>
    if ($script:NativeTried) {
        return $script:NativeReady
    }
    $script:NativeTried = $true
    try {
        Initialize-ClipboardAssemblies
        if (-not ('ClipDiagV2.Clip' -as [type])) {
            Add-Type -TypeDefinition $script:NativeSource -ReferencedAssemblies System.Windows.Forms -ErrorAction Stop
        }
        $script:NativeReady = $true
    }
    catch {
        Write-Err "Native clipboard helper could not be compiled; owner/lock/watch diagnostics unavailable. $($_.Exception.Message)"
        $script:NativeReady = $false
    }
    return $script:NativeReady
}

function Set-ClipboardText {
    <#
    .SYNOPSIS
        Put Unicode text on the clipboard (WinForms, 10 retries x 50 ms).
    .NOTES
        Side effects: OVERWRITES the Windows clipboard. Callers must have
        passed Confirm-Change and saved the clipboard first.
        Audit Notes: data persists after exit (copy=true).
    #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $obj = New-Object System.Windows.Forms.DataObject
    $obj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $true, $Text)
    [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true, 10, 50)
}

function Read-ClipboardTextExpect {
    <#
    .SYNOPSIS
        Read clipboard text with bounded retries until it equals Expected.
    .DESCRIPTION
        Retries on OpenClipboard failure (another process holds the clipboard)
        and on empty/stale content. Default 10 attempts x 50 ms.
    .OUTPUTS
        ClipDiagV2.ReadResult (or an equivalent PSCustomObject fallback).
    .NOTES
        Side effects: briefly opens the clipboard for reading.
        Audit Notes: LastText holds clipboard content; callers must not print
        it unless -ShowText.
    #>
    param([AllowNull()][string]$Expected, [int]$MaxAttempts = 10, [int]$DelayMs = 50)
    if ($script:NativeReady) {
        return [ClipDiagV2.Clip]::ReadTextExpect($Expected, $MaxAttempts, $DelayMs)
    }
    $result = [pscustomobject]@{ Matched = $false; Attempts = 0; OpenFailures = 0; Mismatches = 0; BlockerPid = 0; BlockerName = ''; LastLength = -1; LastText = $null }
    for ($i = 1; $i -le $MaxAttempts; $i++) {
        $result.Attempts = $i
        try {
            $text = [System.Windows.Forms.Clipboard]::GetText([System.Windows.Forms.TextDataFormat]::UnicodeText)
            $result.LastText = $text
            $result.LastLength = $text.Length
            if (($null -eq $Expected -and $text.Length -gt 0) -or ($text -ceq $Expected)) {
                $result.Matched = $true
                break
            }
            $result.Mismatches++
        }
        catch {
            $result.OpenFailures++
        }
        Start-Sleep -Milliseconds $DelayMs
    }
    return $result
}

function Save-ClipboardState {
    <#
    .SYNOPSIS
        Capture the current clipboard (text, RTF, HTML, image, file-drop list).
    .OUTPUTS
        PSCustomObject state consumed by Restore-ClipboardState.
    .NOTES
        Read-only. Holds clipboard data in memory only (never written to disk).
        Formats other than the five above (custom app formats, PNG stream,
        "cut" drop effect) are listed but not restorable.
        Throws when the clipboard cannot be read (caller then skips
        destructive tests to avoid data loss).
        Audit Notes: Summary contains only counts/sizes, never content.
    #>
    Initialize-ClipboardAssemblies
    $state = [pscustomobject]@{
        Empty        = $true
        Text         = $null
        Rtf          = $null
        Html         = $null
        Image        = $null
        FileDrop     = $null
        Formats      = @()
        OtherFormats = @()
        Summary      = 'empty'
    }
    $data = [System.Windows.Forms.Clipboard]::GetDataObject()
    if ($null -eq $data) {
        return $state
    }
    $formats = @($data.GetFormats($false))
    $state.Formats = $formats
    if ($formats.Count -eq 0) {
        return $state
    }
    $state.Empty = $false
    $df = [System.Windows.Forms.DataFormats]
    try {
        if ($data.GetDataPresent($df::UnicodeText, $false)) { $state.Text = [string]$data.GetData($df::UnicodeText, $false) }
        elseif ($data.GetDataPresent($df::Text, $true)) { $state.Text = [string]$data.GetData($df::Text, $true) }
    }
    catch { }
    try { if ($data.GetDataPresent($df::Rtf, $false)) { $state.Rtf = [string]$data.GetData($df::Rtf, $false) } } catch { }
    try { if ($data.GetDataPresent($df::Html, $false)) { $state.Html = [string]$data.GetData($df::Html, $false) } } catch { }
    try { if ([System.Windows.Forms.Clipboard]::ContainsImage()) { $state.Image = [System.Windows.Forms.Clipboard]::GetImage() } } catch { }
    try { if ($data.GetDataPresent($df::FileDrop, $false)) { $state.FileDrop = [string[]]@($data.GetData($df::FileDrop, $false)) } } catch { }

    $restorable = @('UnicodeText', 'Text', 'System.String', 'OEMText', 'Locale', 'Rich Text Format', 'HTML Format',
        'Bitmap', 'System.Drawing.Bitmap', 'DeviceIndependentBitmap', 'Format17', 'FileDrop', 'FileName', 'FileNameW')
    $state.OtherFormats = @($formats | Where-Object { $restorable -notcontains $_ })

    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $state.Text) { $parts.Add("text ($($state.Text.Length) chars)") }
    if ($null -ne $state.Rtf) { $parts.Add('RTF') }
    if ($null -ne $state.Html) { $parts.Add('HTML') }
    if ($null -ne $state.Image) { $parts.Add("image ($($state.Image.Width)x$($state.Image.Height))") }
    if ($null -ne $state.FileDrop) { $parts.Add("$($state.FileDrop.Count) file path(s)") }
    if ($state.OtherFormats.Count -gt 0) { $parts.Add("$($state.OtherFormats.Count) other format(s) not restorable") }
    $state.Summary = if ($parts.Count) { $parts -join ', ' } else { "only non-restorable formats: $($formats -join ', ')" }
    return $state
}

function Restore-ClipboardState {
    <#
    .SYNOPSIS
        Put a saved clipboard state back (unless -NoRestore) and verify text.
    .NOTES
        Side effects: OVERWRITES the clipboard with the saved data; disposes
        the saved image. Clears the clipboard if it was empty before.
        Failure modes: clipboard locked for >500 ms; unrestorable formats.
        Audit Notes: PASS/WARN line states what was restored (counts only).
        Recovery: re-copy the original content manually.
    #>
    param([object]$State, [string]$Context = 'the tests')
    if ($null -eq $State) {
        return
    }
    try {
        if ($NoRestore) {
            Write-WarnLine "Clipboard NOT restored (-NoRestore). It still holds test data from $Context."
            return
        }
        if (-not $State.Empty -and $null -eq $State.Text -and $null -eq $State.Rtf -and $null -eq $State.Html -and $null -eq $State.Image -and $null -eq $State.FileDrop) {
            Write-WarnLine "Prior clipboard held only formats this tool cannot restore ($($State.Formats -join ', ')); clipboard cleared instead."
            [System.Windows.Forms.Clipboard]::Clear()
            return
        }
        if ($State.Empty) {
            [System.Windows.Forms.Clipboard]::Clear()
            Write-Pass "Clipboard restored (it was empty before $Context)."
            return
        }
        $df = [System.Windows.Forms.DataFormats]
        $obj = New-Object System.Windows.Forms.DataObject
        if ($null -ne $State.Text) { $obj.SetData($df::UnicodeText, $true, $State.Text) }
        if ($null -ne $State.Rtf) { $obj.SetData($df::Rtf, $false, $State.Rtf) }
        if ($null -ne $State.Html) { $obj.SetData($df::Html, $false, $State.Html) }
        if ($null -ne $State.Image) { $obj.SetData($df::Bitmap, $true, $State.Image) }
        if ($null -ne $State.FileDrop) { $obj.SetData($df::FileDrop, $true, [string[]]$State.FileDrop) }
        [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true, 10, 50)

        if ($null -ne $State.Text -and $State.Text.Length -gt 0) {
            $check = Read-ClipboardTextExpect -Expected $State.Text
            if (-not $check.Matched) {
                Write-WarnLine "Clipboard restore wrote data, but the text read back did not match. Re-copy your content if needed."
                return
            }
        }
        Write-Pass "Clipboard restored after $Context ($($State.Summary))."
    }
    catch {
        Write-Err "Could not restore the clipboard after $Context. $($_.Exception.Message)"
        Add-Issue "Clipboard restore failed; re-copy your content."
    }
    finally {
        if ($null -ne $State.Image) {
            $State.Image.Dispose()
            $State.Image = $null
        }
    }
}

function ConvertTo-ReportSnapshot {
    <#
    .SYNOPSIS
        Convert a ClipDiagV2.ClipSnapshot into a JSON-friendly object.
    .NOTES
        Pure function. The text preview is included only with -ShowText.
        Audit Notes: privacy gate for the JSON report.
    #>
    param([object]$Snapshot)
    if ($null -eq $Snapshot) {
        return $null
    }
    $o = [ordered]@{
        time         = $Snapshot.Time.ToString('o')
        sequence     = [int64]$Snapshot.Sequence
        owner        = (Format-ProcessLabel -ProcessId $Snapshot.OwnerPid -Name $Snapshot.OwnerName)
        openBy       = (Format-ProcessLabel -ProcessId $Snapshot.OpenWindowPid -Name $Snapshot.OpenWindowName)
        foreground   = (Format-ProcessLabel -ProcessId $Snapshot.ForegroundPid -Name $Snapshot.ForegroundName)
        formatCount  = $Snapshot.FormatCount
        formats      = @($Snapshot.Formats)
        textLength   = $Snapshot.TextLength
        openFailed   = $Snapshot.OpenFailed
        openAttempts = $Snapshot.OpenAttempts
        source       = $Snapshot.Source
    }
    if ($ShowText -and $null -ne $Snapshot.Preview) {
        $o.preview = $Snapshot.Preview
    }
    return [pscustomobject]$o
}

#endregion

#region Diagnose mode

function Test-HostPrerequisites {
    <#
    .SYNOPSIS
        Report PowerShell edition, apartment state, elevation and session type.
    .NOTES
        Read-only. WinForms clipboard APIs need an STA thread (Windows
        PowerShell 5.1 console default). Audit Notes: no side effects.
    #>
    Write-Section "Environment"
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    $isAdmin = $false
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { }
    $script:Report.environment = [ordered]@{
        psVersion       = $PSVersionTable.PSVersion.ToString()
        psEdition       = $(if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' })
        os              = [Environment]::OSVersion.VersionString
        apartment       = [string]$apartment
        elevated        = $isAdmin
        hostName        = $Host.Name
        sessionName     = $env:SESSIONNAME
        inputRedirected = [Console]::IsInputRedirected
    }
    Write-Info "PowerShell $($PSVersionTable.PSVersion) ($($script:Report.environment.psEdition)), host '$($Host.Name)', thread $apartment, elevated: $isAdmin, session: $env:SESSIONNAME"
    if ($apartment -ne 'STA') {
        Write-WarnLine "Clipboard APIs need an STA thread. Use Windows PowerShell 5.1 (powershell.exe) or pwsh -STA."
    }
    if ($env:SESSIONNAME -like 'RDP-*') {
        Write-Info "Remote Desktop session: rdpclip.exe synchronizes the clipboard with the client and can hold it open."
    }
}

function Show-ClipboardState {
    <#
    .SYNOPSIS
        Print sequence number, owner, open-window holder and formats.
    .NOTES
        Side effects: opens the clipboard briefly to enumerate formats.
        Text length is shown; content only with -ShowText.
        Audit Notes: snapshot saved to the JSON report (no payload by default).
    #>
    param([string]$Label = 'current')
    $snap = [ClipDiagV2.Clip]::Snapshot($ShowText.IsPresent, 40, 10, 20)
    $script:Report.clipboard["snapshot_$Label"] = ConvertTo-ReportSnapshot -Snapshot $snap
    Write-Info "Clipboard sequence number: $($snap.Sequence)"
    Write-Info "Owner (process that last emptied/wrote the clipboard): $(Format-ProcessLabel -ProcessId $snap.OwnerPid -Name $snap.OwnerName)"
    if ($snap.OpenWindowPid -ne 0) {
        Write-Info "Clipboard currently held open by: $(Format-ProcessLabel -ProcessId $snap.OpenWindowPid -Name $snap.OpenWindowName)"
    }
    else {
        Write-Info "Clipboard not held open by any window right now."
    }
    if ($snap.OpenFailed) {
        Write-WarnLine "Could not open the clipboard to list formats after $($snap.OpenAttempts) attempts."
    }
    else {
        $list = if ($snap.Formats.Length) { $snap.Formats -join ', ' } else { '(empty)' }
        Write-Info "Formats ($($snap.FormatCount)): $list"
        if ($snap.HasText) {
            $line = "Text present: $($snap.TextLength) chars"
            if ($ShowText) { $line += " preview=`"$($snap.Preview)`"" }
            Write-Info $line
        }
        else {
            Write-Info "No CF_UNICODETEXT on the clipboard."
        }
    }
    return $snap
}

function Test-ClipboardLocks {
    <#
    .SYNOPSIS
        Sample GetOpenClipboardWindow for a few seconds and total hold times.
    .DESCRIPTION
        Apps with short retry windows (browsers ~25 ms, some terminals) fail
        to copy/paste silently when another process keeps the clipboard open.
    .NOTES
        Read-only. Accuracy ~ one sample interval. Processes that call
        OpenClipboard(NULL) are invisible to GetOpenClipboardWindow.
        Audit Notes: totals saved to the JSON report.
    #>
    param([int]$DurationMs = 3000, [int]$IntervalMs = 10)
    Write-Section "Clipboard lock holders (${DurationMs} ms at ${IntervalMs} ms)"
    $sampler = [ClipDiagV2.Clip]::SampleLocks($DurationMs, $IntervalMs)
    $totals = @($sampler.GetTotals() | Sort-Object TotalMs -Descending)
    $ratio = if ($sampler.Samples -gt 0) { [math]::Round(100.0 * $sampler.LockedSamples / $sampler.Samples, 1) } else { 0 }
    $script:Report.clipboard.lockSample = [ordered]@{
        durationMs    = $DurationMs
        intervalMs    = $IntervalMs
        samples       = $sampler.Samples
        lockedSamples = $sampler.LockedSamples
        lockedPercent = $ratio
        holders       = @($totals | ForEach-Object { [ordered]@{ process = (Format-ProcessLabel -ProcessId $_.Pid -Name $_.Name); totalMs = [math]::Round($_.TotalMs); episodes = $_.Episodes; longestMs = [math]::Round($_.LongestMs) } })
    }
    if ($totals.Count -eq 0) {
        Write-Pass "No process held the clipboard open during the sample ($($sampler.Samples) samples)."
        return
    }
    foreach ($t in $totals) {
        Write-Info ("{0}: held the clipboard {1} ms in total over {2} episode(s), longest {3} ms" -f (Format-ProcessLabel -ProcessId $t.Pid -Name $t.Name), [math]::Round($t.TotalMs), $t.Episodes, [math]::Round($t.LongestMs))
    }
    $longest = ($totals | Measure-Object -Property LongestMs -Maximum).Maximum
    if ($ratio -ge 20) {
        Write-Fail "The clipboard was held open $ratio% of the time. Browsers and terminals that retry only briefly will copy/paste nothing."
        Add-Issue "Clipboard held open $ratio% of the sample by $($totals[0].Name)."
    }
    elseif ($longest -ge 500) {
        Write-WarnLine "A process held the clipboard for $([math]::Round($longest)) ms at once; copies/pastes during that window can fail."
    }
    else {
        Write-Pass "Only brief clipboard locks ($ratio% of samples) - normal listener behavior."
    }
    Write-Info "Note: processes that open the clipboard without a window are not visible to this check."
}

function Test-ClipboardTools {
    <#
    .SYNOPSIS
        List running known clipboard tools (managers, sync, remote, auto-clear).
    .NOTES
        Read-only (Get-Process). Running is not proof of interference; it
        tells you what to disable temporarily when isolating.
        Audit Notes: list saved to the JSON report.
    #>
    Write-Section "Clipboard tools"
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($tool in $script:KnownClipboardTools) {
        $procs = @(Get-Process -Name $tool.Processes -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 0) {
            $label = ($procs | ForEach-Object { "$($_.ProcessName) ($($_.Id))" }) -join ', '
            $found.Add([pscustomobject]@{ tool = $tool.Name; processes = $label })
            Write-Info "Running: $($tool.Name) - $label"
        }
    }
    $script:Report.config.clipboardTools = $found.ToArray()
    if ($found.Count -eq 0) {
        Write-Pass "No known third-party clipboard tools are running."
    }
    else {
        Write-Info "If paste fails, temporarily exit these tools one at a time and re-test."
    }
}

function Test-ClipboardHistorySettings {
    <#
    .SYNOPSIS
        Report Windows clipboard history / cloud sync settings and policies.
    .NOTES
        Read-only registry access (HKCU\Software\Microsoft\Clipboard and
        HKLM\SOFTWARE\Policies\Microsoft\Windows\System).
        Audit Notes: values saved to the JSON report.
    #>
    Write-Section "Windows clipboard history / sync"
    $settings = [ordered]@{}
    $key = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Clipboard' -ErrorAction SilentlyContinue
    if ($null -ne $key) {
        foreach ($p in $key.PSObject.Properties) {
            if ($p.Name -notlike 'PS*') { $settings[$p.Name] = $p.Value }
        }
    }
    $policy = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -ErrorAction SilentlyContinue
    foreach ($name in @('AllowClipboardHistory', 'AllowCrossDeviceClipboard')) {
        if ($null -ne $policy -and $null -ne $policy.PSObject.Properties[$name]) {
            $settings["policy:$name"] = $policy.$name
        }
    }
    $service = Get-Service -Name 'cbdhsvc_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $service) {
        $settings['service'] = "$($service.Name) $($service.Status)"
    }
    $script:Report.config.clipboardHistory = $settings
    if ($settings.Count -eq 0) {
        Write-Info "No clipboard history/sync values set (Windows defaults: history off, sync off)."
        return
    }
    foreach ($k in $settings.Keys) {
        Write-Info "$k = $($settings[$k])"
    }
    if ($settings.Contains('service') -and $settings['service'] -notmatch 'Running') {
        Write-WarnLine "Clipboard user service is not running: $($settings['service'])."
    }
}

function Write-RoundTripResult {
    <#
    .SYNOPSIS
        Report a round-trip read result, explaining retries instead of failing.
    .NOTES
        Console + report only. Received content is printed only with -ShowText.
        Audit Notes: no external state change.
    #>
    param([string]$Name, [string]$Expected, [object]$Result, [string]$IssueText, [int]$MaxAttempts = 10)
    $entry = [ordered]@{
        test         = $Name
        matched      = [bool]$Result.Matched
        attempts     = $Result.Attempts
        openFailures = $Result.OpenFailures
        mismatches   = $Result.Mismatches
        blocker      = (Format-ProcessLabel -ProcessId $Result.BlockerPid -Name $Result.BlockerName)
    }
    if (-not $script:Report.clipboard.Contains('roundTrips')) {
        $script:Report.clipboard.roundTrips = New-Object System.Collections.Generic.List[object]
    }
    $script:Report.clipboard.roundTrips.Add([pscustomobject]$entry)

    if ($Result.Matched) {
        Write-Pass "$Name write/read is working (read succeeded on attempt $($Result.Attempts) of $MaxAttempts)."
        $retries = $Result.Attempts - 1
        if ($retries -gt 0) {
            $who = if ($Result.BlockerPid -ne 0) { Format-ProcessLabel -ProcessId $Result.BlockerPid -Name $Result.BlockerName } else { 'no visible window' }
            Write-Info "Needed $retries retr$(if ($retries -eq 1) { 'y' } else { 'ies' }) x 50 ms ($($Result.OpenFailures) open failure(s), holder: $who; $($Result.Mismatches) empty/stale read(s)). A brief lock right after a change is normal, not a failure."
        }
        return
    }
    Write-Fail "$Name clipboard content did not match after $($Result.Attempts) attempts."
    Write-Info "Expected $($Expected.Length) chars; last read: $(if ($Result.LastLength -lt 0) { 'no text' } else { "$($Result.LastLength) chars" }); open failures: $($Result.OpenFailures); holder: $(Format-ProcessLabel -ProcessId $Result.BlockerPid -Name $Result.BlockerName)"
    if ($ShowText) {
        Write-Host "  Expected: $Expected"
        Write-Host "  Received: $([ClipDiagV2.Clip]::MakePreview($Result.LastText, 40))"
    }
    else {
        Write-Info "Received content hidden (use -ShowText to print the first 40 characters)."
    }
    Add-Issue $IssueText
}

function Test-TextClipboard {
    <#
    .SYNOPSIS
        Round-trip a unique ASCII token through the clipboard with retries.
    .NOTES
        Side effects: OVERWRITES the Windows clipboard with CLIPBOARD_TEST_<guid>
        (caller saves and restores it).
        Failure modes: content mismatch after 10 x 50 ms; exceptions.
        Audit Notes: PASS/FAIL lines include attempt counts and lock holder.
        A FAIL here indicates OS/session clipboard text path problems, not malware.
    #>
    Write-Section "Text clipboard"
    $test = "CLIPBOARD_TEST_" + [guid]::NewGuid().ToString("N")
    try {
        Set-ClipboardText -Text $test
        $result = Read-ClipboardTextExpect -Expected $test
        Write-RoundTripResult -Name 'Text' -Expected $test -Result $result -IssueText 'Text clipboard round-trip failed.'
        if ($result.Matched) {
            Write-Info "Test value: $test"
        }
    }
    catch {
        Write-Err "Text clipboard test failed. $($_.Exception.Message)"
        Add-Issue "Text clipboard threw an exception."
    }
}

function Test-UnicodeTextClipboard {
    <#
    .SYNOPSIS
        Round-trip CJK, accented, emoji, CRLF and tab characters.
    .NOTES
        Side effects: OVERWRITES the clipboard (caller saves/restores).
        Built from char codes so the script stays encoding-safe.
        Audit Notes: same reporting as Test-TextClipboard.
    #>
    Write-Section "Unicode / multiline clipboard"
    $test = "CLIPBOARD_UNICODE_" + [guid]::NewGuid().ToString("N").Substring(0, 8) + " " +
        [char]0x4E2D + [char]0x6587 + " " + [char]0x00E9 + [char]0x2713 + " " + [char]0xD83D + [char]0xDE00 +
        "`r`nsecond line`ttab"
    try {
        Set-ClipboardText -Text $test
        $result = Read-ClipboardTextExpect -Expected $test
        Write-RoundTripResult -Name 'Unicode/multiline text' -Expected $test -Result $result -IssueText 'Unicode/multiline clipboard round-trip failed.'
    }
    catch {
        Write-Err "Unicode clipboard test failed. $($_.Exception.Message)"
        Add-Issue "Unicode clipboard threw an exception."
    }
}

function Test-ImageClipboard {
    <#
    .SYNOPSIS
        Round-trip a 32x32 solid-color bitmap through the WinForms clipboard.
    .NOTES
        Side effects: Clipboard.Clear then Clipboard.SetImage (caller saves and
        restores the prior clipboard).
        Success criterion: ContainsImage() becomes true within 10 x 50 ms.
        Failure modes: ContainsImage false; assembly load errors; GDI+ failures.
        Audit Notes: PASS includes dimensions and retries; FAIL lists formats.
    #>
    Write-Section "Image clipboard"
    try {
        Initialize-ClipboardAssemblies
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        try {
            $graphics = [System.Drawing.Graphics]::FromImage($bmp)
            try {
                $graphics.Clear([System.Drawing.Color]::FromArgb(255, 0, 120, 215))
            }
            finally {
                $graphics.Dispose()
            }
            [System.Windows.Forms.Clipboard]::Clear()
            [System.Windows.Forms.Clipboard]::SetImage($bmp)

            $hasImage = $false
            $attempt = 0
            for ($attempt = 1; $attempt -le 10; $attempt++) {
                try {
                    if ([System.Windows.Forms.Clipboard]::ContainsImage()) { $hasImage = $true; break }
                }
                catch { }
                Start-Sleep -Milliseconds 50
            }
            $formats = @()
            $dataObject = [System.Windows.Forms.Clipboard]::GetDataObject()
            if ($null -ne $dataObject) {
                $formats = @($dataObject.GetFormats())
            }

            if ($hasImage) {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                try {
                    Write-Pass "Image write/read is working. ($($img.Width)x$($img.Height), attempt $attempt of 10)"
                    Write-Info ("Formats: " + ($formats -join ", "))
                }
                finally {
                    if ($null -ne $img) {
                        $img.Dispose()
                    }
                }
            }
            else {
                Write-Fail "Image clipboard content was not available after write (10 x 50 ms)."
                Write-Info ("Formats: " + ($(if ($formats.Count) { $formats -join ", " } else { "(none)" })))
                Add-Issue "Image clipboard round-trip failed."
            }
        }
        finally {
            $bmp.Dispose()
        }
    }
    catch {
        Write-Err "Image clipboard test failed. $($_.Exception.Message)"
        Add-Issue "Image clipboard threw an exception."
    }
}

#endregion

#region Exports (Cursor workaround)

function Get-OutputDirectory {
    <#
    .SYNOPSIS
        Resolve and ensure the repo-local .\output directory exists.
    .OUTPUTS
        System.String - absolute path to the output directory.
    .NOTES
        Side effects: creates .\output under $script:ScriptRoot when missing.
        Idempotent directory creation. Audit Notes: caller gates with
        Confirm-Change.
    #>
    $dir = Join-Path $script:ScriptRoot "output"
    [void][System.IO.Directory]::CreateDirectory($dir)
    return $dir
}

function Export-ClipboardImageForCursor {
    <#
    .SYNOPSIS
        Export the current clipboard image (or first image file-drop) to a PNG.
    .DESCRIPTION
        Workaround for Cursor Agent on Windows ignoring Ctrl+V for clipboard
        images. Reads clipboard state; does not clear or replace clipboard data.
    .NOTES
        Inputs: Windows clipboard must contain Bitmap/image data OR a file-drop
        list whose first matching path ends in png/jpeg/jpg/gif/bmp/webp.
        Timestamp format for filenames uses the local machine clock
        (yyyyMMdd-HHmmss); no timezone conversion is applied.
        Outputs: .\output\clipboard-for-cursor-<stamp>.png; updates
        $script:FixesApplied / $script:Issues; may launch explorer.exe.
        Failure modes: empty/non-image clipboard; unsupported file-drop;
        assembly load failure; I/O errors on save/copy.
        Recovery: copy a real image (e.g. Win+Shift+S), re-run with
        -ExportForCursor; delete sensitive PNGs under .\output\ when done.

        Audit Notes:
          External state change = new PNG under .\output\ (+ optional Explorer),
          gated by Confirm-Change (-WhatIf previews).
          Detect via PASS line with full path and filesystem listing of output\.
          Does not delete prior exports (non-destructive to older PNGs).
    #>
    Write-Section "Cursor Agent workaround (Windows)"
    Write-Info "Cursor Agent on Windows often ignores Ctrl+V for images (known client bug)."
    Write-Info "This tool cannot patch Cursor. It exports your clipboard image to a PNG for drag-and-drop."

    try {
        Initialize-ClipboardAssemblies
        $outPath = Join-Path (Join-Path $script:ScriptRoot "output") ("clipboard-for-cursor-{0}.png" -f $script:Stamp)
        $saved = $false

        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
            if (Confirm-Change $outPath 'Write clipboard image as PNG') {
                [void](Get-OutputDirectory)
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                try {
                    $img.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
                    $saved = $true
                    Write-Pass "Saved clipboard image ($($img.Width)x$($img.Height)) to:"
                    Write-Host "  $outPath"
                }
                finally {
                    if ($null -ne $img) {
                        $img.Dispose()
                    }
                }
            }
        }
        elseif ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
            $imageFile = $files | Where-Object {
                $_ -match '\.(png|jpe?g|gif|bmp|webp)$'
            } | Select-Object -First 1

            if ($imageFile -and (Test-Path -LiteralPath $imageFile)) {
                if (Confirm-Change $outPath "Copy clipboard image file $imageFile") {
                    [void](Get-OutputDirectory)
                    [System.IO.File]::Copy($imageFile, $outPath, $true)
                    $saved = $true
                    Write-Pass "Clipboard held an image file. Copied to:"
                    Write-Host "  $outPath"
                    Write-Info "Source: $imageFile"
                }
            }
            else {
                Write-Fail "Clipboard has files, but none look like a supported image."
                Add-Issue "No exportable image file on the clipboard."
            }
        }
        else {
            Write-Fail "No image found on the clipboard."
            Write-Info "Copy a screenshot or image first, then re-run with -ExportForCursor."
            Add-Issue "Clipboard did not contain an image to export for Cursor."
        }

        if ($saved) {
            $script:FixesApplied.Add("Exported clipboard image for Cursor drag-and-drop.")
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Cyan
            Write-Host "  1. Focus the Cursor Agent chat input"
            Write-Host "  2. Drag this PNG into the input (do not rely on Ctrl+V)"
            Write-Host "  3. Or type @ and browse to the file"
            Write-Host ""

            if ($OpenFolder -and (Confirm-Change 'explorer.exe' "Open File Explorer at $outPath")) {
                Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
                Write-Info "Opened File Explorer to the exported PNG."
            }
        }
    }
    catch {
        Write-Err "Could not export clipboard image. $($_.Exception.Message)"
        Add-Issue "Clipboard image export for Cursor failed."
    }
}

function Show-CursorPasteGuidance {
    <#
    .SYNOPSIS
        Print Cursor Agent Windows Ctrl+V image-paste limitation and workaround.
    .NOTES
        Side effects: console output only. No clipboard or filesystem mutation.
        Audit Notes: informational.
    #>
    Write-Section "Cursor Agent (Windows)"
    Write-WarnLine "Cursor Agent often ignores Ctrl+V for clipboard images on Windows (known bug)."
    Write-Info "OS clipboard can be healthy while Cursor paste still fails."
    Write-Info "Workaround: copy your image, then run:"
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -ExportForCursor -OpenFolder'
    Write-Info "Then drag the PNG from .\output\ into the Agent panel."
    Write-Info "Forum: https://forum.cursor.com/t/agent-chat-clipboard-image-paste-ctrl-v-context-menu-does-not-work-drag-and-drop-file-works/156818"
}

#endregion

#region Fixes (-Fix)

function Backup-File {
    <#
    .SYNOPSIS
        Copy a file to .\backups\<label>_<stamp><ext> before it is modified.
    .OUTPUTS
        System.String - backup path.
    .NOTES
        Side effects: creates the backups directory and a new file. Never
        overwrites an existing backup (adds a numeric suffix).
        Callers must already be inside an approved Confirm-Change block.
        Audit Notes: INFO line prints the backup path; restore by copying back.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$Directory = (Join-Path $script:ScriptRoot 'backups')
    )
    [void][System.IO.Directory]::CreateDirectory($Directory)
    $safe = $Label -replace '[^A-Za-z0-9._-]', '_'
    $ext = [System.IO.Path]::GetExtension($Path)
    $dest = Join-Path $Directory ("{0}_{1}{2}" -f $safe, $script:Stamp, $ext)
    $n = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $Directory ("{0}_{1}-{2}{3}" -f $safe, $script:Stamp, $n, $ext)
        $n++
    }
    [System.IO.File]::Copy($Path, $dest, $false)
    Write-Info "Backup: $dest"
    return $dest
}

function Get-MouseWithoutBordersSettingsPath {
    <#
    .SYNOPSIS
        Build the per-user PowerToys Mouse Without Borders settings.json path.
    .OUTPUTS
        System.String - expected settings path (file may not exist).
    .NOTES
        No I/O. Path is under $env:LOCALAPPDATA for the current user only.
        Audit Notes: no side effects.
    #>
    Join-Path $env:LOCALAPPDATA "Microsoft\PowerToys\MouseWithoutBorders\settings.json"
}

function Get-MouseWithoutBordersShareClipboard {
    <#
    .SYNOPSIS
        Read Mouse Without Borders ShareClipboard.value from settings.json.
    .OUTPUTS
        System.Boolean when readable; $null if missing, unreadable, or malformed.
    .NOTES
        Expected JSON shape (subset):
          { "properties": { "ShareClipboard": { "value": true|false } }, ... }
        Missing/malformed data returns $null and may emit WARN - callers must
        treat $null as "unknown", not as disabled.
        Side effects: reads settings file; may Write-WarnLine on parse errors.
        Does not log unrelated settings fields (avoids leaking secrets).
        Audit Notes: read-only.
    #>
    $path = Get-MouseWithoutBordersSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json.properties -or $null -eq $json.properties.ShareClipboard) {
            return $null
        }
        return [bool]$json.properties.ShareClipboard.value
    }
    catch {
        Write-WarnLine "Could not parse Mouse Without Borders settings: $($_.Exception.Message)"
        return $null
    }
}

function Set-MouseWithoutBordersShareClipboard {
    <#
    .SYNOPSIS
        Set Mouse Without Borders ShareClipboard.value via targeted text replace.
    .PARAMETER Enabled
        $true to enable Share Clipboard; $false to disable.
    .NOTES
        Side effects: overwrites settings.json on disk (UTF-8, preserving the
        original BOM / no-BOM choice). Caller backs the file up first.
        Throws if file missing, ShareClipboard block missing, or replace no-ops.
        Idempotency: writing the same bool twice leaves equivalent on-disk value.
        Constraint: only the first ShareClipboard value match is replaced.

        Audit Notes:
          What could go wrong: wrong file path; regex miss; PowerToys rewrite on
          next UI save; process still using old in-memory setting until restart.
          Detect: re-read via Get-MouseWithoutBordersShareClipboard; compare file.
          Recover: set Share Clipboard in PowerToys UI, or copy the backup from
          .\backups\MouseWithoutBorders_settings_<stamp>.json back into place.
    #>
    param([bool]$Enabled)

    $path = Get-MouseWithoutBordersSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Mouse Without Borders settings file not found: $path"
    }

    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($raw -notmatch '"ShareClipboard"\s*:\s*\{') {
        throw "ShareClipboard property missing from Mouse Without Borders settings."
    }

    $boolText = if ($Enabled) { "true" } else { "false" }
    $updated = [regex]::Replace(
        $raw,
        '("ShareClipboard"\s*:\s*\{\s*"value"\s*:\s*)(true|false)',
        ('${1}' + $boolText),
        1
    )

    if ($updated -eq $raw) {
        throw "Could not update ShareClipboard value in Mouse Without Borders settings."
    }

    [System.IO.File]::WriteAllText($path, $updated, (New-Object System.Text.UTF8Encoding $hasBom))
}

function Restart-MouseWithoutBordersModule {
    <#
    .SYNOPSIS
        Restart PowerToys.MouseWithoutBorders so settings changes take effect.
    .DESCRIPTION
        Stops PowerToys.MouseWithoutBorders. If it does not auto-respawn, stops
        and relaunches the PowerToys runner from its previous executable path.
    .NOTES
        Side effects: Stop-Process on PowerToys.MouseWithoutBorders and possibly
        PowerToys; Start-Process on the PowerToys executable; sleeps 2-4 seconds.
        Failure modes: process stop denied; Start-Process path missing; module
        never returns - callers still continue.
        Idempotency: safe to call when module already stopped; may briefly
        interrupt other PowerToys modules if the runner is restarted.

        Audit Notes:
          Detect via Get-Process PowerToys / PowerToys.MouseWithoutBorders and
          console timing around -Fix. Recover by starting PowerToys from Start Menu.
    #>
    $mwb = Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue
    if ($mwb) {
        Stop-Process -Name "PowerToys.MouseWithoutBorders" -Force -Confirm:$false -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if (-not (Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue)) {
        $powerToys = Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $powerToys -and $powerToys.Path) {
            $ptPath = $powerToys.Path
            Stop-Process -Name "PowerToys" -Force -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            if (Test-Path -LiteralPath $ptPath) {
                Start-Process -FilePath $ptPath | Out-Null
                Start-Sleep -Seconds 4
            }
        }
    }
}

function Test-KnownClipboardBlockers {
    <#
    .SYNOPSIS
        Detect known local clipboard blockers; optionally remediate with -Fix.
    .DESCRIPTION
        Decision intent: flag PowerToys Mouse Without Borders Share Clipboard
        when enabled, because it often breaks image paste while text still works.
        Also notes if PowerToys Advanced Paste is running (informational only).
    .NOTES
        Inputs: process list; ShareClipboard setting (bool or unknown/$null).
        Constraints: only automates MWB ShareClipboard disable; does not disable
        Advanced Paste automatically.
        Verify: console FAIL/PASS for ShareClipboard; re-test image paste in Paint.
        Recovery if wrong: re-enable Share Clipboard in PowerToys, or restore
        the backup from .\backups\.
        Audit Notes: -Fix path backs up and mutates settings.json and may
        restart PowerToys; both are gated by Confirm-Change (-WhatIf previews).
    #>
    Write-Section "Known blockers (PowerToys)"

    $mwbProcess = Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue
    $shareClipboard = Get-MouseWithoutBordersShareClipboard
    $script:Report.config.mouseWithoutBordersShareClipboard = $shareClipboard
    $issue = "Mouse Without Borders Share Clipboard is enabled."

    if ($null -eq $shareClipboard -and -not $mwbProcess) {
        Write-Info "PowerToys Mouse Without Borders not detected."
    }
    elseif ($null -eq $shareClipboard) {
        Write-WarnLine "Mouse Without Borders appears to be installed/running, but ShareClipboard could not be read."
    }
    elseif ($shareClipboard) {
        Write-Fail "PowerToys Mouse Without Borders has Share Clipboard enabled."
        Write-Info "This often breaks image copy/paste while text still works."
        Add-Issue $issue

        if ($Fix) {
            $path = Get-MouseWithoutBordersSettingsPath
            if (Confirm-Change $path 'Back up, set ShareClipboard=false and restart Mouse Without Borders') {
                try {
                    Write-Info "Applying fix: disabling Share Clipboard..."
                    [void](Backup-File -Path $path -Label 'MouseWithoutBorders_settings')
                    Set-MouseWithoutBordersShareClipboard -Enabled $false
                    Restart-MouseWithoutBordersModule

                    $after = Get-MouseWithoutBordersShareClipboard
                    if ($after -eq $false) {
                        Write-Pass "Disabled Mouse Without Borders Share Clipboard and restarted the module."
                        $script:FixesApplied.Add("Disabled Mouse Without Borders Share Clipboard.")
                        [void]$script:Issues.Remove($issue)
                    }
                    else {
                        Write-Fail "Attempted to disable Share Clipboard, but it is still enabled."
                    }
                }
                catch {
                    Write-Err "Could not apply Mouse Without Borders fix. $($_.Exception.Message)"
                }
            }
        }
        else {
            Write-WarnLine "Re-run with -Fix to disable Share Clipboard automatically (a backup is made first)."
            Write-Info 'Example: powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Fix'
        }
    }
    else {
        Write-Pass "Mouse Without Borders Share Clipboard is already disabled."
    }

    $advancedPaste = Get-Process -Name "PowerToys.AdvancedPaste" -ErrorAction SilentlyContinue
    if ($advancedPaste) {
        Write-Info "PowerToys Advanced Paste is running. If paste still fails in one app, try disabling it temporarily."
    }
}

function Read-EditorSettingsFile {
    <#
    .SYNOPSIS
        Read an editor settings.json and classify it (missing/JSONC/parsed).
    .OUTPUTS
        PSCustomObject { Exists; HasComments; Parseable; Settings; Error }
    .NOTES
        Read-only. JSONC (comments/trailing commas) is reported as not
        parseable on purpose: rewriting it would drop the comments.
        Audit Notes: no side effects.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    $state = [pscustomobject]@{ Exists = $false; HasComments = $false; Parseable = $false; Settings = $null; Error = $null }
    if (-not (Test-Path -LiteralPath $Path)) {
        $state.Parseable = $true
        $state.Settings = [pscustomobject]@{}
        return $state
    }
    $state.Exists = $true
    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        $state.Error = $_.Exception.Message
        return $state
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $state.Parseable = $true
        $state.Settings = [pscustomobject]@{}
        return $state
    }
    if (Test-JsonHasCommentsOrTrailingCommas -Text $raw) {
        $state.HasComments = $true
        return $state
    }
    try {
        $state.Settings = $raw | ConvertFrom-Json -ErrorAction Stop
        $state.Parseable = $true
    }
    catch {
        $state.Error = $_.Exception.Message
    }
    return $state
}

function Get-EditorVimDiagnosis {
    <#
    .SYNOPSIS
        For each editor with VSCodeVim installed, report missing vim.handleKeys.
    .PARAMETER Targets
        Objects with Name, Settings, Extensions paths (tests pass temp paths).
    .OUTPUTS
        PSCustomObject[] { Editor; SettingsPath; VimExtension; Exists;
        HasComments; Parseable; Error; MissingKeys }
    .NOTES
        Read-only. Ported from Get-ClipboardDiagnosis in
        chinese-ime-fix\Fix-ChineseImeWordSelection.ps1.
        Audit Notes: no side effects.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Targets, [string[]]$Keys = @('<C-c>', '<C-v>'))
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Targets) {
        if (-not (Test-Path -LiteralPath $t.Extensions)) { continue }
        $vim = Get-ChildItem -LiteralPath $t.Extensions -Directory -Filter 'vscodevim.vim-*' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $vim) { continue }
        $state = Read-EditorSettingsFile -Path $t.Settings
        $missing = @()
        if ($state.Parseable) {
            $missing = @(Get-MissingVimClipboardKeys -Settings $state.Settings -Keys $Keys)
        }
        $out.Add([pscustomobject]@{
            Editor       = $t.Name
            SettingsPath = $t.Settings
            VimExtension = $vim.Name
            Exists       = $state.Exists
            HasComments  = $state.HasComments
            Parseable    = $state.Parseable
            Error        = $state.Error
            MissingKeys  = $missing
        })
    }
    return $out.ToArray()
}

function Repair-EditorVimKeys {
    <#
    .SYNOPSIS
        Set vim.handleKeys <C-c>/<C-v> = false in one editor settings.json.
    .OUTPUTS
        System.Boolean - $true when the file now passes Ctrl+C/Ctrl+V through.
    .NOTES
        Side effects: backup to .\backups\settings_<editor>_<stamp>.json, then
        rewrites settings.json (UTF-8 without BOM) preserving other keys.
        Skips JSONC files (prints manual instructions instead).
        Gated by Confirm-Change (-WhatIf previews). Ported from
        Repair-EditorClipboard in chinese-ime-fix.
        Audit Notes: detect via backup file + PASS line; recover by copying
        the backup back. Reload the editor window afterwards.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Diagnosis,
        [string[]]$Keys = @('<C-c>', '<C-v>'),
        [string]$BackupDirectory = (Join-Path $script:ScriptRoot 'backups')
    )
    $path = $Diagnosis.SettingsPath
    if (-not (Confirm-Change $path "Back up and set vim.handleKeys $($Keys -join '/') = false")) {
        return $false
    }
    try {
        $state = Read-EditorSettingsFile -Path $path
        if (-not $state.Parseable) {
            Write-WarnLine "$($Diagnosis.Editor): settings.json is not plain JSON; not edited."
            return $false
        }
        $merged = Merge-VimHandleKeys -Settings $state.Settings -Keys $Keys
        if ($state.Exists -and -not $merged.Changed) {
            Write-Pass "$($Diagnosis.Editor): vim.handleKeys $($Keys -join ', ') already false; not rewritten."
            return $true
        }
        if ($state.Exists) {
            [void](Backup-File -Path $path -Label "settings_$($Diagnosis.Editor)" -Directory $BackupDirectory)
        }
        else {
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $path))
        }
        $json = ConvertTo-EditorSettingsJson -Settings $merged.Settings
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))

        $verify = Read-EditorSettingsFile -Path $path
        $stillMissing = @(Get-MissingVimClipboardKeys -Settings $verify.Settings -Keys $Keys)
        if ($verify.Parseable -and $stillMissing.Count -eq 0) {
            Write-Pass "$($Diagnosis.Editor): set vim.handleKeys $($Keys -join ', ') = false. Reload the editor window."
            $script:FixesApplied.Add("$($Diagnosis.Editor): vim.handleKeys <C-c>/<C-v> = false.")
            return $true
        }
        Write-Fail "$($Diagnosis.Editor): settings.json written but verification failed."
        return $false
    }
    catch {
        Write-Err "$($Diagnosis.Editor): could not update settings.json. $($_.Exception.Message)"
        return $false
    }
}

function Test-EditorVimClipboard {
    <#
    .SYNOPSIS
        Check (and with -Fix repair) VSCodeVim swallowing Ctrl+C / Ctrl+V.
    .NOTES
        Editors: Cursor, VS Code, VS Code Insiders, VSCodium (user settings).
        Audit Notes: diagnosis saved to the JSON report; -Fix edits are backed
        up and gated by Confirm-Change.
    #>
    Write-Section "Editor Vim extension (Ctrl+C / Ctrl+V)"
    $diag = @(Get-EditorVimDiagnosis -Targets $script:EditorTargets -Keys $script:VimClipboardKeys)
    $script:Report.config.editorVim = @($diag | ForEach-Object {
            [ordered]@{ editor = $_.Editor; settingsPath = $_.SettingsPath; vimExtension = $_.VimExtension; parseable = $_.Parseable; hasComments = $_.HasComments; missingKeys = @($_.MissingKeys) }
        })
    if ($diag.Count -eq 0) {
        Write-Info "VSCodeVim is not installed in Cursor / VS Code / VS Code Insiders / VSCodium."
        return
    }
    foreach ($d in $diag) {
        if (-not $d.Parseable) {
            $why = if ($d.HasComments) { 'has comments/trailing commas' } else { "could not be parsed ($($d.Error))" }
            Write-WarnLine "$($d.Editor): VSCodeVim installed but settings.json $why; not edited automatically."
            Write-Info "  Add manually to $($d.SettingsPath):  `"vim.handleKeys`": { `"<C-c>`": false, `"<C-v>`": false }"
            continue
        }
        if ($d.MissingKeys.Count -eq 0) {
            Write-Pass "$($d.Editor): vim.handleKeys passes Ctrl+C/Ctrl+V to the editor ($($d.VimExtension))."
            continue
        }
        $issue = "$($d.Editor): VSCodeVim intercepts $($d.MissingKeys -join ', ') (Ctrl+C/Ctrl+V in the editor can silently fail)."
        Write-Fail $issue
        Add-Issue $issue
        if ($Fix) {
            if (Repair-EditorVimKeys -Diagnosis $d -Keys $script:VimClipboardKeys) {
                [void]$script:Issues.Remove($issue)
            }
        }
        else {
            Write-WarnLine "Re-run with -Fix to set vim.handleKeys <C-c>/<C-v> = false in $($d.SettingsPath) (backup first)."
        }
    }
}

function Restart-WindowsExplorer {
    <#
    .SYNOPSIS
        Restart explorer.exe in the current session (-Fix -RestartExplorer).
    .NOTES
        Side effects: taskbar and open folder windows close briefly. Waits up
        to 8 s for Windows to respawn the shell, else starts explorer.exe.
        Gated by Confirm-Change. Audit Notes: detect via PASS line and
        Get-Process explorer; recover by running explorer.exe from Task Manager.
    #>
    Write-Section "Restart Windows Explorer"
    if (-not (Confirm-Change 'explorer.exe (current session)' 'Restart Windows Explorer')) {
        return
    }
    try {
        $session = (Get-Process -Id $PID).SessionId
        $procs = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
        foreach ($p in $procs) {
            Stop-Process -Id $p.Id -Force -Confirm:$false -ErrorAction Stop
        }
        $back = $false
        for ($i = 0; $i -lt 16; $i++) {
            Start-Sleep -Milliseconds 500
            if (Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) { $back = $true; break }
        }
        if (-not $back) {
            Start-Process -FilePath (Join-Path $env:WINDIR 'explorer.exe')
        }
        Write-Pass "Windows Explorer restarted."
        $script:FixesApplied.Add("Restarted Windows Explorer.")
    }
    catch {
        Write-Err "Could not restart Windows Explorer. $($_.Exception.Message)"
    }
}

function Restart-ClipboardUserService {
    <#
    .SYNOPSIS
        Try to restart the per-user clipboard service cbdhsvc_<luid>.
    .NOTES
        Side effects: Restart-Service. Windows usually denies this without
        Administrator; that is reported as WARN + issue with alternatives.
        Gated by Confirm-Change. Audit Notes: detect via Get-Service cbdhsvc_*.
    #>
    Write-Section "Restart clipboard user service"
    $svc = Get-Service -Name 'cbdhsvc_*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $svc) {
        Write-WarnLine "Per-user clipboard service (cbdhsvc_*) not found."
        return
    }
    if (-not (Confirm-Change $svc.Name 'Restart clipboard user service')) {
        return
    }
    try {
        Restart-Service -InputObject $svc -Force -Confirm:$false -ErrorAction Stop
        Write-Pass "Restarted $($svc.Name)."
        $script:FixesApplied.Add("Restarted $($svc.Name).")
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match '(?i)denied|cannot open|permission') {
            Write-WarnLine "Access denied restarting $($svc.Name): Windows requires Administrator for this service. Use -RestartExplorer, or sign out and back in."
        }
        else {
            Write-WarnLine "Could not restart $($svc.Name): $msg"
        }
        Add-Issue "Clipboard user service $($svc.Name) was not restarted."
    }
}

#endregion

#region -TerminalPaste

function Get-ProcessChain {
    <#
    .SYNOPSIS
        Walk the parent process chain of a process and find attached console hosts.
    .OUTPUTS
        PSCustomObject { Chain[]; ConsoleHosts[] }
    .NOTES
        Read-only (Win32_Process via CIM, no admin needed). Stops at PID reuse
        (parent created after child) and loops. Audit Notes: no side effects.
    #>
    param([int]$StartProcessId = $PID, [int]$MaxDepth = 12)
    $all = @{}
    foreach ($p in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate -ErrorAction Stop)) {
        $all[[int]$p.ProcessId] = $p
    }
    $chain = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $cur = $StartProcessId
    while ($chain.Count -lt $MaxDepth -and $all.ContainsKey($cur) -and -not $seen.ContainsKey($cur)) {
        $seen[$cur] = $true
        $p = $all[$cur]
        $chain.Add([pscustomobject]@{ ProcessId = [int]$p.ProcessId; Name = [string]$p.Name; ParentProcessId = [int]$p.ParentProcessId })
        $parentId = [int]$p.ParentProcessId
        if ($all.ContainsKey($parentId) -and $null -ne $all[$parentId].CreationDate -and $null -ne $p.CreationDate -and $all[$parentId].CreationDate -gt $p.CreationDate) {
            break
        }
        $cur = $parentId
    }
    $hosts = @($all.Values | Where-Object { ($_.Name -eq 'conhost.exe' -or $_.Name -eq 'OpenConsole.exe') -and $seen.ContainsKey([int]$_.ParentProcessId) } |
            ForEach-Object { [pscustomobject]@{ ProcessId = [int]$_.ProcessId; Name = [string]$_.Name; ParentProcessId = [int]$_.ParentProcessId } })
    return [pscustomobject]@{ Chain = $chain.ToArray(); ConsoleHosts = $hosts }
}

function Get-TerminalHostInfo {
    <#
    .SYNOPSIS
        Identify the terminal hosting this shell (WT / VS Code-family / conhost).
    .DESCRIPTION
        Order: TERM_PROGRAM=vscode -> VS Code/Cursor integrated terminal;
        WT_SESSION -> Windows Terminal (verified against the parent chain,
        because WT_SESSION is inherited by apps launched from WT); else conhost.
    .OUTPUTS
        PSCustomObject { Kind; Detail; Chain; ConsoleHosts; Evidence[] }
    .NOTES
        Read-only. Audit Notes: no side effects.
    #>
    $info = Get-ProcessChain
    $names = @($info.Chain | ForEach-Object { $_.Name.ToLowerInvariant() })
    $evidence = New-Object System.Collections.Generic.List[string]
    $kind = 'conhost'
    $detail = 'Windows Console Host (conhost.exe)'
    $hasWtInChain = $names -contains 'windowsterminal.exe'
    $hasOpenConsole = @($info.ConsoleHosts | Where-Object { $_.Name -eq 'OpenConsole.exe' }).Count -gt 0

    if ($env:TERM_PROGRAM -eq 'vscode') {
        $kind = 'vscode'
        $evidence.Add('TERM_PROGRAM=vscode')
        if ($names -contains 'cursor.exe') { $detail = 'Cursor integrated terminal' }
        elseif ($names -contains 'code - insiders.exe') { $detail = 'VS Code Insiders integrated terminal' }
        elseif ($names -contains 'codium.exe' -or $names -contains 'vscodium.exe') { $detail = 'VSCodium integrated terminal' }
        elseif ($names -contains 'code.exe') { $detail = 'VS Code integrated terminal' }
        else { $detail = 'VS Code-family integrated terminal' }
    }
    elseif ($env:WT_SESSION) {
        $evidence.Add('WT_SESSION is set')
        if ($hasWtInChain -or $hasOpenConsole) {
            $kind = 'wt'
            $detail = 'Windows Terminal'
        }
        else {
            $evidence.Add('but WindowsTerminal.exe is not in the parent chain (WT_SESSION may be inherited)')
            if (@($info.ConsoleHosts | Where-Object { $_.Name -eq 'conhost.exe' }).Count -gt 0) {
                $kind = 'conhost'
                $detail = 'conhost (WT_SESSION inherited from a parent launched in Windows Terminal)'
            }
            else {
                $kind = 'unknown'
                $detail = 'Unknown host (WT_SESSION inherited; no attached console host found)'
            }
        }
    }
    elseif ($hasWtInChain) {
        $kind = 'wt'
        $detail = 'Windows Terminal (WT_SESSION missing but WindowsTerminal.exe is an ancestor)'
        $evidence.Add('WindowsTerminal.exe in parent chain')
    }
    else {
        $evidence.Add('no WT_SESSION / TERM_PROGRAM')
    }
    return [pscustomobject]@{ Kind = $kind; Detail = $detail; Chain = $info.Chain; ConsoleHosts = $info.ConsoleHosts; Evidence = $evidence.ToArray() }
}

function Get-WindowsTerminalInstallations {
    <#
    .SYNOPSIS
        Locate Windows Terminal settings.json files and the matching defaults.json.
    .NOTES
        Read-only. defaults.json is read from the package install folder via
        Get-AppxPackage (no admin needed); $null when unavailable.
        Audit Notes: no side effects.
    #>
    $candidates = @(
        @{ Label = 'Windows Terminal'; Package = 'Microsoft.WindowsTerminal'; Settings = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') }
        @{ Label = 'Windows Terminal Preview'; Package = 'Microsoft.WindowsTerminalPreview'; Settings = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json') }
        @{ Label = 'Windows Terminal (unpackaged)'; Package = $null; Settings = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json') }
    )
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c.Settings)) { continue }
        $defaults = $null
        if ($c.Package) {
            try {
                $pkg = Get-AppxPackage -Name $c.Package -ErrorAction Stop | Select-Object -First 1
                if ($null -ne $pkg) {
                    $d = Join-Path $pkg.InstallLocation 'defaults.json'
                    if (Test-Path -LiteralPath $d) { $defaults = $d }
                }
            }
            catch { }
        }
        [pscustomobject]@{ Label = $c.Label; SettingsPath = $c.Settings; DefaultsPath = $defaults }
    }
}

function Test-WindowsTerminalConfig {
    <#
    .SYNOPSIS
        Report what ctrl+v / ctrl+shift+v / shift+insert do in Windows Terminal.
    .NOTES
        Read-only; tolerant JSONC parsing. FAIL only when the current host is
        Windows Terminal. Audit Notes: bindings/options saved to the report.
    #>
    param([string]$HostKind)
    Write-Section "Windows Terminal settings"
    $installs = @(Get-WindowsTerminalInstallations)
    $reportList = New-Object System.Collections.Generic.List[object]
    if ($installs.Count -eq 0) {
        Write-Info "Windows Terminal settings.json not found."
        $script:Report.config.windowsTerminal = @()
        return
    }
    foreach ($inst in $installs) {
        Write-Info "$($inst.Label): $($inst.SettingsPath)"
        $userText = [System.IO.File]::ReadAllText($inst.SettingsPath, [System.Text.Encoding]::UTF8)
        $defaultsText = $script:WtBuiltInDefaultsFallback
        if ($inst.DefaultsPath) {
            try { $defaultsText = [System.IO.File]::ReadAllText($inst.DefaultsPath, [System.Text.Encoding]::UTF8) }
            catch { Write-WarnLine "Could not read $($inst.DefaultsPath); using built-in defaults." }
            Write-Info "Defaults: $($inst.DefaultsPath)"
        }
        else {
            Write-Info "defaults.json not readable; using documented built-in paste bindings."
        }
        $res = Resolve-WindowsTerminalBindings -UserSettingsText $userText -DefaultsText $defaultsText
        foreach ($e in $res.Errors) {
            Write-WarnLine "Could not parse $e"
        }
        foreach ($b in $res.Bindings) {
            $line = "{0,-13} -> {1}{2} [{3}]" -f $b.Chord, $b.Action, $(if ($b.Id) { " ($($b.Id))" } else { '' }), $b.Source
            if ($b.IsPaste) {
                Write-Pass $line
            }
            elseif ($HostKind -eq 'wt' -and $b.Chord -eq 'ctrl+v') {
                Write-Fail "$line - Ctrl+V does not paste in Windows Terminal."
                Add-Issue "Windows Terminal: ctrl+v is bound to '$($b.Action)', not paste."
            }
            else {
                Write-WarnLine $line
            }
        }
        foreach ($o in $res.Options) {
            Write-Info ("option {0} = {1} [{2}]" -f $o.Name, ($o.Value | ConvertTo-Json -Compress -Depth 3), $o.Source)
        }
        $reportList.Add([ordered]@{
            label        = $inst.Label
            settingsPath = $inst.SettingsPath
            defaultsPath = $inst.DefaultsPath
            bindings     = $res.Bindings
            options      = @($res.Options | ForEach-Object { [ordered]@{ name = $_.Name; value = $_.Value; source = $_.Source } })
            errors       = $res.Errors
        })
    }
    $script:Report.config.windowsTerminal = $reportList.ToArray()
}

function Test-ConhostConfig {
    <#
    .SYNOPSIS
        Report HKCU\Console settings that control Ctrl+V / right-click paste.
    .NOTES
        Read-only registry access. Per-app subkeys under HKCU\Console override
        the root values for that executable/shortcut title.
        Audit Notes: values saved to the report.
    #>
    param([string]$HostKind)
    Write-Section "Console host (conhost) settings"
    $names = @('ForceV2', 'CtrlKeyShortcutsDisabled', 'QuickEdit', 'InterceptCopyPaste')
    $root = Get-ItemProperty -Path 'HKCU:\Console' -ErrorAction SilentlyContinue
    $rootValues = [ordered]@{}
    foreach ($n in $names) {
        if ($null -ne $root -and $null -ne $root.PSObject.Properties[$n]) { $rootValues[$n] = $root.$n }
    }
    $overrides = New-Object System.Collections.Generic.List[object]
    foreach ($sub in @(Get-ChildItem -Path 'HKCU:\Console' -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty -Path $sub.PSPath -ErrorAction SilentlyContinue
        foreach ($n in $names) {
            if ($null -ne $props -and $null -ne $props.PSObject.Properties[$n]) {
                $overrides.Add([pscustomobject]@{ Key = $sub.PSChildName; Name = $n; Value = $props.$n })
            }
        }
    }
    $startup = Get-ItemProperty -Path 'HKCU:\Console\%%Startup' -ErrorAction SilentlyContinue
    $delegation = $null
    if ($null -ne $startup -and $null -ne $startup.PSObject.Properties['DelegationTerminal']) {
        $delegation = [string]$startup.DelegationTerminal
    }
    $script:Report.config.conhost = [ordered]@{ root = $rootValues; overrides = $overrides.ToArray(); delegationTerminal = $delegation }

    $relevant = ($HostKind -eq 'conhost')
    $forceV2 = if ($rootValues.Contains('ForceV2')) { $rootValues['ForceV2'] } else { 1 }
    $ctrlDisabled = if ($rootValues.Contains('CtrlKeyShortcutsDisabled')) { $rootValues['CtrlKeyShortcutsDisabled'] } else { 0 }
    $quickEdit = if ($rootValues.Contains('QuickEdit')) { $rootValues['QuickEdit'] } else { 1 }

    if ($forceV2 -eq 1) { Write-Pass "ForceV2 = 1 (new console; Ctrl+V paste supported)" }
    elseif ($relevant) { Write-Fail "ForceV2 = 0 (legacy console: Ctrl+V does not paste)"; Add-Issue "conhost legacy mode (ForceV2=0) disables Ctrl+V paste." }
    else { Write-WarnLine "ForceV2 = 0 (legacy console)" }

    if ($ctrlDisabled -eq 0) { Write-Pass "CtrlKeyShortcutsDisabled = 0 (Ctrl+C/Ctrl+V shortcuts enabled)" }
    elseif ($relevant) { Write-Fail "CtrlKeyShortcutsDisabled = 1 (Ctrl+V paste disabled in conhost)"; Add-Issue "conhost Ctrl key shortcuts are disabled." }
    else { Write-WarnLine "CtrlKeyShortcutsDisabled = 1" }

    if ($quickEdit -eq 1) { Write-Pass "QuickEdit = 1 (right-click pastes in conhost)" }
    else { Write-Info "QuickEdit = 0 (right-click opens the menu instead of pasting in conhost)" }

    if ($rootValues.Contains('InterceptCopyPaste')) {
        Write-Info "InterceptCopyPaste = $($rootValues['InterceptCopyPaste']) (1 = Ctrl+Shift+C/V copy/paste in conhost)"
    }
    foreach ($o in $overrides) {
        $bad = ($o.Name -eq 'ForceV2' -and $o.Value -eq 0) -or ($o.Name -eq 'CtrlKeyShortcutsDisabled' -and $o.Value -eq 1)
        $msg = "Per-app override HKCU\Console\$($o.Key): $($o.Name) = $($o.Value)"
        if ($bad) { Write-WarnLine "$msg (disables Ctrl+V paste for that app)" } else { Write-Info $msg }
    }
    if ($delegation) {
        $label = switch ($delegation.ToUpperInvariant()) {
            '{00000000-0000-0000-0000-000000000000}' { 'Let Windows decide' }
            '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}' { 'Windows Console Host' }
            '{E12CFF52-A866-4C77-9A90-F570A7AA2C6B}' { 'Windows Terminal' }
            '{86633F1F-6454-40EC-89CE-DA4EBA977EE2}' { 'Windows Terminal Preview' }
            default { 'custom' }
        }
        Write-Info "Default terminal application: $label $delegation"
    }
}

function Test-PSReadLineConfig {
    <#
    .SYNOPSIS
        Report PSReadLine version and Ctrl+V / Shift+Insert key handlers.
    .NOTES
        Side effects: may Import-Module PSReadLine into this session (needed
        when the script runs via -File). Does not change key bindings.
        No defect is claimed for any version; the self-test verifies behavior.
        Audit Notes: version/handlers saved to the report.
    #>
    param([string]$HostKind)
    Write-Section "PSReadLine"
    $available = @(Get-Module -Name PSReadLine -ListAvailable -ErrorAction SilentlyContinue | ForEach-Object { $_.Version.ToString() } | Select-Object -Unique)
    $mod = Get-Module -Name PSReadLine
    if ($null -eq $mod -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected) {
        try {
            Import-Module PSReadLine -ErrorAction Stop -WarningAction SilentlyContinue
            $mod = Get-Module -Name PSReadLine
        }
        catch { }
    }
    $handlers = @()
    if ($null -ne $mod) {
        try {
            $handlers = @(Get-PSReadLineKeyHandler -Bound -ErrorAction Stop | Where-Object { $_.Key -match '^(Ctrl\+(Shift\+)?v|Shift\+Insert)$' } |
                    ForEach-Object { [pscustomobject]@{ Key = $_.Key; Function = $_.Function } })
        }
        catch { }
    }
    $script:Report.config.psreadline = [ordered]@{
        loaded    = $(if ($mod) { $mod.Version.ToString() } else { $null })
        available = $available
        handlers  = $handlers
    }
    if ($null -eq $mod) {
        Write-Info "PSReadLine not loaded in this session (available: $(if ($available.Count) { $available -join ', ' } else { 'none' }))."
        return
    }
    Write-Info "PSReadLine $($mod.Version) loaded (available: $($available -join ', '))."
    if ($mod.Version -lt [version]'2.1.0') {
        Write-Info "This is the version that ships with Windows PowerShell 5.1. Newer releases exist (Install-Module PSReadLine -Scope CurrentUser); no paste defect is assumed - the self-test checks the prompt path."
    }
    $ctrlV = $handlers | Where-Object { $_.Key -cmatch '^Ctrl\+[vV]$' } | Select-Object -First 1
    foreach ($h in $handlers) {
        Write-Info "$($h.Key) -> $($h.Function)"
    }
    if ($null -eq $ctrlV -or $ctrlV.Function -ne 'Paste') {
        $msg = "PSReadLine Ctrl+v is not bound to Paste."
        if ($HostKind -eq 'conhost') { Write-Fail "$msg In conhost the key reaches PSReadLine, so Ctrl+V will not paste at the prompt."; Add-Issue $msg }
        else { Write-WarnLine "$msg Only matters when the terminal passes Ctrl+V through to the shell." }
    }
    else {
        Write-Pass "PSReadLine binds Ctrl+v to Paste (used only when the terminal passes the key through)."
    }
}

function Test-EditorTerminalConfig {
    <#
    .SYNOPSIS
        Report VS Code/Cursor settings and keybindings that affect terminal paste.
    .NOTES
        Read-only; JSONC tolerated. Checks workbench.action.terminal.paste
        overrides, terminal.integrated.sendKeybindingsToShell,
        terminal.integrated.commandsToSkipShell, rightClickBehavior and
        vim.handleKeys. Audit Notes: findings saved to the report.
    #>
    param([string]$HostKind)
    Write-Section "VS Code / Cursor terminal settings"
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($t in $script:EditorTargets) {
        $hasSettings = Test-Path -LiteralPath $t.Settings
        $hasKeys = Test-Path -LiteralPath $t.Keybindings
        if (-not $hasSettings -and -not $hasKeys) { continue }
        $entry = [ordered]@{ editor = $t.Name; settings = [ordered]@{}; keybindings = @(); errors = @() }
        $errs = New-Object System.Collections.Generic.List[string]
        if ($hasSettings) {
            try {
                $raw = [System.IO.File]::ReadAllText($t.Settings, [System.Text.Encoding]::UTF8)
                $s = if ([string]::IsNullOrWhiteSpace($raw)) { [pscustomobject]@{} } else { (Remove-JsonComments -Text $raw) | ConvertFrom-Json -ErrorAction Stop }
                foreach ($name in @('terminal.integrated.sendKeybindingsToShell', 'terminal.integrated.commandsToSkipShell', 'terminal.integrated.rightClickBehavior', 'terminal.integrated.enableMultiLinePasteWarning', 'vim.handleKeys')) {
                    if ($null -ne $s.PSObject.Properties[$name]) { $entry.settings[$name] = $s.$name }
                }
            }
            catch { $errs.Add("settings.json: $($_.Exception.Message)") }
        }
        if ($hasKeys) {
            try {
                $entry.keybindings = @(Get-VsCodeTerminalKeybindingOverrides -KeybindingsText ([System.IO.File]::ReadAllText($t.Keybindings, [System.Text.Encoding]::UTF8)))
            }
            catch { $errs.Add("keybindings.json: $($_.Exception.Message)") }
        }
        $entry.errors = $errs.ToArray()
        $list.Add($entry)

        $isCurrent = ($HostKind -eq 'vscode')
        Write-Info "$($t.Name): settings $(if ($hasSettings) { 'found' } else { 'missing' }), keybindings.json $(if ($hasKeys) { 'found' } else { 'missing' })"
        foreach ($e in $errs) { Write-WarnLine "$($t.Name) $e" }
        $sendKeys = $entry.settings['terminal.integrated.sendKeybindingsToShell']
        if ($sendKeys -eq $true) {
            Write-WarnLine "$($t.Name): terminal.integrated.sendKeybindingsToShell = true - Ctrl+V goes to the shell (PSReadLine) instead of the editor's paste command."
        }
        $skip = @($entry.settings['terminal.integrated.commandsToSkipShell'])
        if ($skip -contains '-workbench.action.terminal.paste') {
            Write-WarnLine "$($t.Name): commandsToSkipShell removes workbench.action.terminal.paste - Ctrl+V is sent to the shell."
        }
        foreach ($kb in $entry.keybindings) {
            $msg = "$($t.Name) keybindings.json: key=$($kb.Key) command=$($kb.Command) when=$($kb.When)"
            if ($kb.Removes -or ($kb.Key -eq 'ctrl+v' -and $kb.Command -notmatch '^workbench\.action\.terminal\.paste')) {
                if ($isCurrent) { Write-Fail "$msg - overrides terminal paste."; Add-Issue "$($t.Name): keybindings.json overrides terminal paste ($($kb.Key))." }
                else { Write-WarnLine "$msg - overrides terminal paste." }
            }
            else { Write-Info $msg }
        }
        if ($entry.settings.Contains('vim.handleKeys')) {
            $vimJson = ($entry.settings['vim.handleKeys'] | ConvertTo-Json -Compress) -replace '\\u003c', '<' -replace '\\u003e', '>'
            Write-Info "$($t.Name): vim.handleKeys = $vimJson (affects the editor, not the integrated terminal)"
        }
        if ($entry.settings.Contains('terminal.integrated.rightClickBehavior')) {
            Write-Info "$($t.Name): terminal.integrated.rightClickBehavior = $($entry.settings['terminal.integrated.rightClickBehavior'])"
        }
    }
    $script:Report.config.editorTerminal = $list.ToArray()
    if ($list.Count -eq 0) {
        Write-Info "No VS Code-family user settings found."
    }
}

function Initialize-PasteReader {
    <#
    .SYNOPSIS
        Choose how the self-test reads a line: PSReadLine (like the real prompt)
        or Read-Host.
    .NOTES
        Side effects: may Import-Module PSReadLine; temporarily sets
        AddToHistoryHandler to reject lines so test tokens never reach
        PSReadLine history (restored by Restore-PasteReader).
        Audit Notes: reader kind is recorded in the self-test results.
    #>
    $reader = [pscustomobject]@{ Kind = 'Read-Host'; Restore = $false; OriginalHandler = $null }
    if ($Host.Name -ne 'ConsoleHost') {
        return $reader
    }
    $mod = Get-Module -Name PSReadLine
    if ($null -eq $mod) {
        try { Import-Module PSReadLine -ErrorAction Stop -WarningAction SilentlyContinue; $mod = Get-Module -Name PSReadLine } catch { return $reader }
    }
    try {
        $reader.OriginalHandler = (Get-PSReadLineOption).AddToHistoryHandler
        Set-PSReadLineOption -AddToHistoryHandler { param([string]$line) return $false }
        $reader.Restore = $true
        $reader.Kind = "PSReadLine $($mod.Version)"
    }
    catch { }
    return $reader
}

function Restore-PasteReader {
    <#
    .SYNOPSIS
        Restore PSReadLine's AddToHistoryHandler after the self-test.
    .NOTES
        Side effects: Set-PSReadLineOption (session only, not persisted).
        Audit Notes: failure prints WARN; a new session resets it anyway.
    #>
    param([object]$Reader)
    if ($null -eq $Reader -or -not $Reader.Restore) {
        return
    }
    try {
        Set-PSReadLineOption -AddToHistoryHandler $Reader.OriginalHandler
    }
    catch {
        Write-WarnLine "Could not restore PSReadLine AddToHistoryHandler (session only): $($_.Exception.Message)"
    }
}

function Read-PasteLine {
    <#
    .SYNOPSIS
        Prompt and read one line using the selected reader.
    .NOTES
        Falls back to Read-Host if PSReadLine's ReadLine is unavailable.
        Audit Notes: console interaction only.
    #>
    param([object]$Reader, [string]$Prompt)
    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    if ($Reader.Kind -like 'PSReadLine*') {
        try {
            return [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext)
        }
        catch [System.Management.Automation.MethodException] {
            try {
                return [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext, $null)
            }
            catch {
                $Reader.Kind = 'Read-Host (PSReadLine ReadLine failed)'
            }
        }
        catch {
            $Reader.Kind = 'Read-Host (PSReadLine ReadLine failed)'
        }
    }
    return (Read-Host)
}

function Invoke-PasteSelfTest {
    <#
    .SYNOPSIS
        Interactive test: put a token on the clipboard, user pastes it with a
        named method into a prompt in THIS terminal, compare.
    .NOTES
        Side effects: overwrites the clipboard with tokens (saved first and
        restored afterwards unless -NoRestore); PSReadLine history suppressed
        during the prompts. Gated by Confirm-Change.
        Skipped when input is redirected or -SkipSelfTest.
        Audit Notes: results table saved to the report (tokens only).
    #>
    param([object]$HostInfo)
    Write-Section "Interactive paste self-test"
    if ($SkipSelfTest) {
        Write-Info "Skipped (-SkipSelfTest)."
        return
    }
    if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
        Write-WarnLine "Skipped: needs an interactive terminal (input is redirected). Run this script directly in the terminal you want to test."
        return
    }
    if (-not (Confirm-Change 'Windows clipboard' 'Overwrite with paste-test tokens (saved and restored afterwards)')) {
        return
    }
    try {
        $saved = Save-ClipboardState
    }
    catch {
        Write-Fail "Could not read the current clipboard to save it ($($_.Exception.Message)); self-test skipped to avoid data loss."
        Add-Issue "Clipboard could not be read before the paste self-test."
        return
    }
    $methods = @(
        [pscustomobject]@{ Name = 'Ctrl+V'; Slug = 'CTRLV'; How = 'press Ctrl+V' }
        [pscustomobject]@{ Name = 'Ctrl+Shift+V'; Slug = 'CTRLSHIFTV'; How = 'press Ctrl+Shift+V' }
        [pscustomobject]@{ Name = 'Shift+Insert'; Slug = 'SHIFTINS'; How = 'press Shift+Insert' }
        [pscustomobject]@{ Name = 'Right-click'; Slug = 'RIGHTCLICK'; How = 'right-click inside this window (nothing selected)' }
    )
    $results = New-Object System.Collections.Generic.List[object]
    $reader = Initialize-PasteReader
    Write-Info "Input reader: $($reader.Kind) (PSReadLine = same path as your prompt)."
    Write-Host ""
    Write-Host "For each step a new token is put on the clipboard. Paste it ONLY with the named method, then press Enter." -ForegroundColor Cyan
    Write-Host "Press Enter without pasting to record 'empty'. Type s then Enter to skip a method." -ForegroundColor Cyan
    try {
        $i = 0
        foreach ($m in $methods) {
            $i++
            $token = "PASTETEST-$($m.Slug)-" + [guid]::NewGuid().ToString('N').Substring(0, 8)
            Set-ClipboardText -Text $token
            $check = Read-ClipboardTextExpect -Expected $token
            $owner = ''
            if ($script:NativeReady) {
                $ownerPid = [ClipDiagV2.Clip]::WindowPid([ClipDiagV2.Native]::GetClipboardOwner())
                $owner = Format-ProcessLabel -ProcessId $ownerPid -Name ([ClipDiagV2.Clip]::ProcName($ownerPid))
            }
            Write-Host ""
            Write-Host "[$i/$($methods.Count)] Token on clipboard: $token" -ForegroundColor Gray
            $typed = Read-PasteLine -Reader $reader -Prompt "[$i/$($methods.Count)] $($m.How), then Enter: "
            if ($null -eq $typed) { $typed = '' }
            $verdict = if ($typed.Trim() -eq 's') { 'skipped' } else { Get-PasteVerdict -Expected $token -Received $typed }
            $after = Read-ClipboardTextExpect -Expected $token -MaxAttempts 3 -DelayMs 30
            $results.Add([pscustomobject]@{
                Method          = $m.Name
                TokenOnClip     = [bool]$check.Matched
                PastedChars     = $(if ($verdict -eq 'skipped') { 0 } else { $typed.Length })
                Verdict         = $verdict
                ClipAfter       = $(if ($after.Matched) { 'token' } else { 'changed' })
                ClipboardOwner  = $owner
                Token           = $token
            })
        }
    }
    finally {
        Restore-PasteReader -Reader $reader
        Restore-ClipboardState -State $saved -Context 'the paste self-test'
    }

    Write-Host ""
    $results | Format-Table Method, TokenOnClip, PastedChars, Verdict, ClipAfter, ClipboardOwner -AutoSize | Out-String -Width 200 | Write-Host
    $script:Report.config.selfTest = [ordered]@{ reader = $reader.Kind; host = $HostInfo.Detail; results = $results.ToArray() }

    $tested = @($results | Where-Object { $_.Verdict -ne 'skipped' })
    $good = @($tested | Where-Object { $_.Verdict -like 'exact*' })
    $bad = @($tested | Where-Object { $_.Verdict -notlike 'exact*' })
    foreach ($r in $tested) {
        if ($r.Verdict -like 'exact*') { Write-Pass "$($r.Method) delivered the token ($($r.Verdict))." }
        elseif (-not $r.TokenOnClip) { Write-Fail "$($r.Method): the token never reached the clipboard (clipboard write problem, not terminal paste)." }
        else { Write-Fail "$($r.Method): clipboard held the token but the terminal delivered '$($r.Verdict)'." }
    }
    if ($tested.Count -eq 0) {
        Write-Info "All methods skipped."
        return
    }
    Write-Section "Terminal paste verdict"
    if ($bad.Count -eq 0) {
        Write-Pass "Every tested paste method works in $($HostInfo.Detail). If paste was blank earlier, the source app never put text on the clipboard (run -Watch / -BrowserTest)."
    }
    elseif ($good.Count -eq 0) {
        Write-Fail "No paste method delivered the token although the clipboard held it: the terminal's paste path is broken, not the clipboard."
        Add-Issue "Terminal paste delivered nothing for: $(($bad | ForEach-Object { $_.Method }) -join ', ')."
        Write-Info "Next: close and reopen the terminal window; check the lock-holder section of the default diagnose; try another terminal (conhost/Windows Terminal) to compare."
    }
    else {
        Write-Fail "Works: $(($good | ForEach-Object { $_.Method }) -join ', '). Fails: $(($bad | ForEach-Object { $_.Method }) -join ', ')."
        Add-Issue "Terminal paste fails for: $(($bad | ForEach-Object { $_.Method }) -join ', ')."
        Write-Info "Because other methods work with the same clipboard, the failing ones are key-binding / key-handling problems in the terminal (see the bindings above)."
    }
}

function Invoke-TerminalPasteDiagnosis {
    <#
    .SYNOPSIS
        -TerminalPaste entrypoint: host detection, config checks, self-test.
    .NOTES
        Read-only except the self-test's temporary clipboard use.
        Audit Notes: everything saved under config.* in the JSON report.
    #>
    Write-Section "Terminal host"
    $hostInfo = Get-TerminalHostInfo
    Write-Info "Detected: $($hostInfo.Detail) [kind=$($hostInfo.Kind)]"
    Write-Info "Evidence: $($hostInfo.Evidence -join '; ')"
    Write-Info "Parent chain: $(($hostInfo.Chain | ForEach-Object { "$($_.Name)($($_.ProcessId))" }) -join ' <- ')"
    if ($hostInfo.ConsoleHosts.Count -gt 0) {
        $hostGroups = @($hostInfo.ConsoleHosts | Group-Object Name | ForEach-Object { "$($_.Count) x $($_.Name)" })
        Write-Info "Console host processes started by this chain (one per tab/pane/console app; not only this tab): $($hostGroups -join ', ')"
    }
    $script:Report.config.terminalHost = [ordered]@{
        kind         = $hostInfo.Kind
        detail       = $hostInfo.Detail
        evidence     = $hostInfo.Evidence
        chain        = @($hostInfo.Chain | ForEach-Object { "$($_.Name)($($_.ProcessId))" })
        consoleHosts = @($hostInfo.ConsoleHosts | ForEach-Object { "$($_.Name)($($_.ProcessId))" })
    }
    Test-WindowsTerminalConfig -HostKind $hostInfo.Kind
    Test-ConhostConfig -HostKind $hostInfo.Kind
    Test-PSReadLineConfig -HostKind $hostInfo.Kind
    Test-EditorTerminalConfig -HostKind $hostInfo.Kind
    if (Initialize-NativeClipboard) {
        Write-Section "Clipboard state"
        [void](Show-ClipboardState -Label 'terminalPaste')
    }
    Invoke-PasteSelfTest -HostInfo $hostInfo
}

#endregion

#region -Watch

function Invoke-ClipboardWatch {
    <#
    .SYNOPSIS
        Foreground, time-bounded clipboard change recorder (-Watch).
    .DESCRIPTION
        Uses AddClipboardFormatListener on a hidden message-only window,
        falling back to GetClipboardSequenceNumber polling. Logs each change
        (time, sequence, owner, foreground app, formats, text length), lock
        episodes, foreground switches and - when the console is interactive -
        text pasted into this window, compared with the clipboard.
    .NOTES
        Side effects: reads the clipboard after each change (like explorer's
        clipboard history does); writes .\reports\watch-<stamp>.log (gated by
        Confirm-Change). Ends after -Seconds, Ctrl+C or Esc. Nothing keeps
        running afterwards.
        Privacy: text content (first 40 chars) only with -ShowText.
        Audit Notes: log + report contain metadata only by default.
    #>
    Write-Section "Clipboard watch ($Seconds s)"
    if (-not (Initialize-NativeClipboard)) {
        Add-Issue "Watch mode unavailable (native helper failed)."
        return
    }
    $logPath = Join-Path (Join-Path $script:ScriptRoot 'reports') ("watch-{0}.log" -f $script:Stamp)
    $writer = $null
    if (Confirm-Change $logPath 'Write clipboard watch log') {
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $logPath))
        $writer = New-Object System.IO.StreamWriter($logPath, $false, (New-Object System.Text.UTF8Encoding $false))
        $writer.AutoFlush = $true
        $writer.WriteLine("# clipboard-test.ps1 $($script:ToolVersion) watch started $((Get-Date).ToString('o')) seconds=$Seconds showText=$($ShowText.IsPresent)")
    }
    $interactive = -not [Console]::IsInputRedirected
    $log = {
        param([string]$Line, [string]$Color)
        if ($Color) { Write-Host $Line -ForegroundColor $Color } else { Write-Host $Line }
        if ($null -ne $writer) { $writer.WriteLine($Line) }
    }

    Write-Host "Guided steps (recording for $Seconds s; Ctrl+C or Esc stops early):" -ForegroundColor Cyan
    Write-Host "  1. Switch to the browser and click the Copy button/icon (e.g. GitHub 'Copy URL to clipboard')."
    if ($interactive) {
        Write-Host "  2. Come back to THIS terminal window and press Ctrl+V once (then try Ctrl+Shift+V / right-click)."
    }
    else {
        Write-Host "  2. Paste in your terminal (input capture is off here because input is redirected)."
    }
    Write-Host "  3. Every clipboard change prints a CHANGE line naming the writing process."
    Write-Host "     No CHANGE line after clicking Copy = the browser never wrote to the Windows clipboard."
    if ($interactive) {
        Write-Host "     Text pasted into this window prints an INPUT line; no INPUT line after Ctrl+V = the terminal pasted nothing."
    }
    Write-Host ""

    $events = New-Object System.Collections.Generic.List[object]
    $inputs = New-Object System.Collections.Generic.List[object]
    $watcher = $null
    $oldTreat = $false
    $lockLines = 0
    $lockLimit = 60
    $stopReason = 'time limit'
    try {
        $watcher = New-Object ClipDiagV2.Watcher($ShowText.IsPresent, $false)
        if ($watcher.UsingListener) {
            & $log "Mode: AddClipboardFormatListener (hidden message-only window)" ''
        }
        else {
            & $log "Mode: sequence-number polling every 10 ms (listener unavailable, Win32 error $($watcher.ListenerError))" 'Yellow'
        }
        $start = [ClipDiagV2.Clip]::Snapshot($ShowText.IsPresent, 40, 10, 20)
        & $log ("[{0}] START  seq={1} owner={2} formats=[{3}] text={4}" -f $start.Time.ToString('HH:mm:ss.fff'), $start.Sequence, (Format-ProcessLabel -ProcessId $start.OwnerPid -Name $start.OwnerName), ($start.Formats -join ', '), $(if ($start.TextLength -ge 0) { "$($start.TextLength) chars" } else { 'none' })) 'Gray'

        if ($interactive) {
            $oldTreat = [Console]::TreatControlCAsInput
            [Console]::TreatControlCAsInput = $true
        }
        $burst = New-Object System.Text.StringBuilder
        $lastKey = Get-Date
        $deadline = (Get-Date).AddSeconds($Seconds)
        $nextProgress = (Get-Date).AddSeconds(15)
        $stop = $false
        while (-not $stop -and (Get-Date) -lt $deadline) {
            $watcher.Pump(100)
            foreach ($f in $watcher.TakeFocus()) {
                & $log ("[{0}] FOCUS  {1}" -f $f.Time.ToString('HH:mm:ss.fff'), (Format-ProcessLabel -ProcessId $f.Pid -Name $f.Name)) 'DarkGray'
            }
            foreach ($c in $watcher.TakeChanges()) {
                $events.Add($c)
                $txt = if ($c.TextLength -ge 0) { "$($c.TextLength) chars" } else { 'no text' }
                $line = "[{0}] CHANGE seq={1} owner={2} foreground={3} formats=[{4}] text={5}" -f $c.Time.ToString('HH:mm:ss.fff'), $c.Sequence,
                (Format-ProcessLabel -ProcessId $c.OwnerPid -Name $c.OwnerName), (Format-ProcessLabel -ProcessId $c.ForegroundPid -Name $c.ForegroundName),
                $(if ($c.Formats.Length) { $c.Formats -join ', ' } else { '(none read)' }), $txt
                if ($ShowText -and $null -ne $c.Preview) { $line += " preview=`"$($c.Preview)`"" }
                if ($c.OpenFailed) { $line += " (clipboard stayed locked; formats unread)" }
                & $log $line 'Green'
            }
            foreach ($ep in $watcher.Locks.TakeEpisodes()) {
                $lockLines++
                if ($lockLines -le $lockLimit) {
                    & $log ("[{0}] LOCK   {1} held the clipboard {2} ms" -f $ep.Start.ToString('HH:mm:ss.fff'), (Format-ProcessLabel -ProcessId $ep.Pid -Name $ep.Name), [math]::Round($ep.DurationMs)) 'DarkYellow'
                }
                elseif ($lockLines -eq $lockLimit + 1) {
                    & $log "(further LOCK lines suppressed; totals are in the summary)" 'DarkYellow'
                }
            }
            if ($interactive) {
                while ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
                    if (($ctrl -and $k.Key -eq [ConsoleKey]::C) -or $k.Key -eq [ConsoleKey]::Escape) {
                        $stop = $true
                        $stopReason = 'stopped by user'
                        break
                    }
                    if ($ctrl -and $k.Key -eq [ConsoleKey]::V) {
                        & $log ("[{0}] INPUT  Ctrl+V reached the console as a raw key: the terminal did not perform a paste itself" -f (Get-Date).ToString('HH:mm:ss.fff')) 'Magenta'
                        $inputs.Add([pscustomobject]@{ time = (Get-Date).ToString('o'); chars = 0; match = 'raw Ctrl+V key' })
                        continue
                    }
                    [void]$burst.Append($k.KeyChar)
                    $lastKey = Get-Date
                }
                if ($burst.Length -gt 0 -and ((Get-Date) - $lastKey).TotalMilliseconds -gt 150) {
                    $typedText = $burst.ToString()
                    [void]$burst.Clear()
                    $clip = [ClipDiagV2.Clip]::ReadTextExpect($null, 5, 20)
                    $norm = { param([string]$s) if ($null -eq $s) { return $null }; return (($s -replace "[`r`n]", '').Trim()) }
                    $a = & $norm $typedText
                    $b = & $norm $clip.LastText
                    $match = if ($null -eq $b) { 'clipboard has no text' } elseif ($a -ceq $b) { 'yes' } elseif ($b.Contains($a) -or $a.Contains($b)) { 'partial' } else { 'no' }
                    $line = "[{0}] INPUT  {1} chars arrived in this window; matches clipboard text ({2}): {3}" -f (Get-Date).ToString('HH:mm:ss.fff'), $typedText.Length, $(if ($clip.LastLength -ge 0) { "$($clip.LastLength) chars" } else { 'none' }), $match
                    if ($ShowText) { $line += " preview=`"$([ClipDiagV2.Clip]::MakePreview($typedText, 40))`"" }
                    & $log $line 'Magenta'
                    $inputs.Add([pscustomobject]@{ time = (Get-Date).ToString('o'); chars = $typedText.Length; match = $match })
                }
            }
            if ((Get-Date) -ge $nextProgress) {
                $left = [math]::Max(0, [math]::Round(($deadline - (Get-Date)).TotalSeconds))
                Write-Host "... recording, $left s left (Ctrl+C or Esc to stop)" -ForegroundColor DarkGray
                $nextProgress = (Get-Date).AddSeconds(15)
            }
        }
    }
    finally {
        if ($interactive) {
            [Console]::TreatControlCAsInput = $oldTreat
        }
        if ($null -ne $watcher) {
            $watcher.Dispose()
        }
    }

    Write-Section "Watch summary"
    & $log "Watch ended ($stopReason). Clipboard changes recorded: $($events.Count)." ''
    $byOwner = @($events | Group-Object OwnerName | Sort-Object Count -Descending)
    foreach ($g in $byOwner) {
        $name = if ($g.Name) { $g.Name } else { '(no owner window)' }
        & $log "  written by ${name}: $($g.Count)" ''
    }
    $totals = @($watcher.Locks.GetTotals() | Sort-Object TotalMs -Descending)
    foreach ($t in $totals) {
        & $log ("  lock holder {0}: {1} ms total, {2} episode(s), longest {3} ms" -f (Format-ProcessLabel -ProcessId $t.Pid -Name $t.Name), [math]::Round($t.TotalMs), $t.Episodes, [math]::Round($t.LongestMs)) ''
    }
    $focusTable = @()
    foreach ($key in $watcher.FocusMs.Keys) {
        $focusTable += [pscustomobject]@{ Name = $key; Seconds = [math]::Round($watcher.FocusMs[$key] / 1000.0, 1) }
    }
    foreach ($ft in ($focusTable | Sort-Object Seconds -Descending)) {
        & $log "  foreground: $($ft.Name) $($ft.Seconds) s" ''
    }

    $browsersFocused = @($focusTable | Where-Object { $script:BrowserProcessNames -contains $_.Name.ToLowerInvariant() })
    if ($browsersFocused.Count -eq 0) {
        Write-Info "No browser was in the foreground during the watch; nothing to conclude about browser copy."
    }
    foreach ($bf in $browsersFocused) {
        $writes = @($events | Where-Object { $_.OwnerName -eq $bf.Name -or ($_.OwnerPid -eq 0 -and $_.ForegroundName -eq $bf.Name) })
        if ($writes.Count -gt 0) {
            Write-Pass "$($bf.Name) wrote to the clipboard $($writes.Count) time(s) (it was in the foreground $($bf.Seconds) s)."
        }
        else {
            Write-Fail "$($bf.Name) was in the foreground for $($bf.Seconds) s but never wrote to the Windows clipboard."
            Add-Issue "$($bf.Name) did not write to the clipboard during the watch (copy click never reached Windows)."
            Write-Info "Run -BrowserTest -Browser $($bf.Name) to see the browser-side error."
        }
    }
    if ($interactive) {
        if ($inputs.Count -eq 0) {
            Write-Info "No text arrived in this window during the watch (if you pressed Ctrl+V here, the terminal pasted nothing)."
        }
        else {
            Write-Info "Input bursts received in this window: $($inputs.Count) (matches: $(@($inputs | Where-Object { $_.match -eq 'yes' }).Count))."
        }
    }
    $script:Report.clipboard.watch = [ordered]@{
        seconds       = $Seconds
        listener      = $watcher.UsingListener
        stopReason    = $stopReason
        changes       = @($events | ForEach-Object { ConvertTo-ReportSnapshot -Snapshot $_ })
        lockHolders   = @($totals | ForEach-Object { [ordered]@{ process = (Format-ProcessLabel -ProcessId $_.Pid -Name $_.Name); totalMs = [math]::Round($_.TotalMs); episodes = $_.Episodes; longestMs = [math]::Round($_.LongestMs) } })
        foreground    = $focusTable
        terminalInput = $inputs.ToArray()
        logPath       = $(if ($null -ne $writer) { $logPath } else { $null })
    }
    if ($null -ne $writer) {
        $writer.WriteLine("# watch ended $((Get-Date).ToString('o'))")
        $writer.Dispose()
        Write-Info "Watch log: $logPath"
    }
}

#region -BrowserTest
function Invoke-BrowserPasteTest {
    <#
    .SYNOPSIS
        -BrowserPasteTest entrypoint: can the browser receive copied text?
    .DESCRIPTION
        Serves a paste-receiver page from a random loopback-only route. The
        paste handler prevents insertion and sends only clipboard format names
        and text lengths. It does not modify the Windows clipboard.
    .NOTES
        Side effects: opens a browser tab and temporarily listens on loopback.
        Gated by Confirm-Change. Audit Notes: clipboard payloads are not sent,
        displayed, or saved.
    #>
    Write-Section "Browser clipboard paste receive test"
    $browserLabel = if ($Browser -eq 'default') { 'the default browser' } else { $Browser }
    if ($InPrivate -and $Browser -ne 'default') { $browserLabel += ' (InPrivate/incognito)' }
    if (-not (Confirm-Change "Windows clipboard / $browserLabel" 'Open a 127.0.0.1 paste test page (clipboard contents are not changed)')) {
        Write-Info "Browser paste test not run (-WhatIf or confirmation declined)."
        return
    }

    $basePath = '/p/' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $pageBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-BrowserPasteTestPage -RunId $runId))
    $results = New-Object System.Collections.Generic.List[object]
    $state = @{ PageServed = $false; PageServedAt = $null; Requests = (New-Object System.Collections.Generic.List[object]); BadResults = 0 }
    $expectedFamily = switch ($Browser) { 'msedge' { 'edge' } 'chrome' { 'chrome' } default { $null } }
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $started = Get-Date
    $pasteResult = $null
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $url = "http://127.0.0.1:$port$basePath/"
        Write-Info "Listener started on 127.0.0.1 port $port (loopback only; page served on a random secret path)."
        switch ($Browser) {
            'msedge' { Start-Process -FilePath 'msedge.exe' -ArgumentList $(if ($InPrivate) { @('--inprivate', $url) } else { $url }) }
            'chrome' { Start-Process -FilePath 'chrome.exe' -ArgumentList $(if ($InPrivate) { @('--incognito', $url) } else { $url }) }
            default {
                if ($InPrivate) { Write-WarnLine "-InPrivate needs -Browser msedge or chrome; opening the default browser normally." }
                Start-Process -FilePath $url
            }
        }
        Write-Host "A page titled 'Clipboard paste test [$runId]' opened in $browserLabel. Copy text from HackMD, focus the page's box, and press Ctrl+V." -ForegroundColor Cyan
        Write-Host "The page discards pasted content and reports only clipboard formats and text lengths. Waiting up to $BrowserTimeoutSeconds s..." -ForegroundColor Cyan
        $deadline = $started.AddSeconds($BrowserTimeoutSeconds)
        while ((Get-Date) -lt $deadline -and $null -eq $pasteResult) {
            while ($listener.Pending()) {
                Invoke-BrowserTestRequest -Client $listener.AcceptTcpClient() -PageBytes $pageBytes -Results $results -State $state -BasePath $basePath
            }
            $candidate = $results | Where-Object { $_.phase -eq 'paste' } | Select-Object -First 1
            if ($null -ne $candidate -and $candidate.client -ne 'electron' -and ($null -eq $expectedFamily -or $candidate.client -eq $expectedFamily)) {
                $pasteResult = $candidate
            }
            Start-Sleep -Milliseconds 50
        }
        while ($listener.Pending()) {
            Invoke-BrowserTestRequest -Client $listener.AcceptTcpClient() -PageBytes $pageBytes -Results $results -State $state -BasePath $basePath
        }
        if ($null -eq $pasteResult) {
            $candidate = $results | Where-Object { $_.phase -eq 'paste' } | Select-Object -First 1
            if ($null -ne $candidate -and $candidate.client -ne 'electron' -and ($null -eq $expectedFamily -or $candidate.client -eq $expectedFamily)) {
                $pasteResult = $candidate
            }
        }
    }
    catch {
        Write-Err "Browser paste test failed: $($_.Exception.Message)"
        Add-Issue "Browser paste test encountered an error."
    }
    finally {
        $listener.Stop()
        Write-Info "Listener stopped."
    }

    $script:Report.clipboard.browserPasteTest = [ordered]@{
        browser = $Browser
        inPrivate = [bool]$InPrivate
        pageServed = [bool]$state.PageServed
        pasteReceived = ($null -ne $pasteResult)
        formats = $(if ($null -ne $pasteResult) { @($pasteResult.types) } else { @() })
        textLengths = $(if ($null -ne $pasteResult) { $pasteResult.textLengths } else { [ordered]@{} })
        textAvailable = $(if ($null -ne $pasteResult) { [bool]$pasteResult.hasText } else { $null })
    }

    if ($null -ne $pasteResult) {
        $formats = @($pasteResult.types) -join ', '
        Write-Info "Paste event received from $($pasteResult.client); clipboard formats: $(if ($formats) { $formats } else { '(none reported)' })."
        Write-Info "Text lengths: $($pasteResult.textLengths | ConvertTo-Json -Compress -Depth 3)."
        if ($pasteResult.errors.Count -gt 0) {
            Write-WarnLine "The browser reported an error reading clipboard metadata: $($pasteResult.errors -join '; ')."
        }
        if ($pasteResult.hasText) {
            Write-Pass "The browser received non-empty text from the clipboard. This points away from a general browser paste failure; test Google Keep next."
        }
        else {
            Write-WarnLine "The browser received a paste event but no non-empty plain or HTML text was available."
            Add-Issue "Browser paste event contained no readable text."
        }
    }
    elseif (-not $state.PageServed) {
        Write-Fail "$browserLabel did not load the local test page within $BrowserTimeoutSeconds s."
        Add-Issue "Browser paste test page was not loaded."
    }
    else {
        Write-WarnLine "No paste event was received within $BrowserTimeoutSeconds s. Confirm the test box had focus and Ctrl+V was pressed after copying from HackMD."
        Add-Issue "No browser paste event was received; the test is inconclusive if Ctrl+V was not completed."
    }
}

function Get-BrowserFamily {
    <#
    .SYNOPSIS
        Classify a User-Agent string: edge | chrome | electron | firefox | other | none.
    .NOTES
        Pure function. Electron apps (Cursor, VS Code) embed Chromium and must
        not be mistaken for the browser under test. Audit Notes: no side effects.
    #>
    param([AllowNull()][AllowEmptyString()][string]$UserAgent)
    if ([string]::IsNullOrWhiteSpace($UserAgent)) { return 'none' }
    if ($UserAgent -match 'Electron/') { return 'electron' }
    if ($UserAgent -match 'Edg(e|A|iOS)?/') { return 'edge' }
    if ($UserAgent -match 'Firefox/') { return 'firefox' }
    if ($UserAgent -match 'Chrome/') { return 'chrome' }
    return 'other'
}

function Get-BrowserTestPage {
    <#
    .SYNOPSIS
        Build the HTML test page that writes Token to the clipboard.
    .NOTES
        Pure function. The page tries navigator.clipboard.writeText once on
        load (no user gesture) and again on the button click, falls back to
        document.execCommand('copy'), shows the exact error, and POSTs each
        outcome to /result on the same loopback origin.
        Audit Notes: no side effects; token is a random test value.
    #>
    param([Parameter(Mandatory = $true)][string]$Token, [string]$RunId = 'run')
    $html = @'
<!doctype html>
<html><head><meta charset="utf-8"><title>Clipboard write test [__RUNID__]</title>
<style>
body{font-family:"Segoe UI",sans-serif;margin:40px;max-width:760px;color:#222}
button{font-size:20px;padding:12px 22px;cursor:pointer}
code{background:#f2f2f2;padding:2px 6px}
#log div{margin:6px 0;font-family:Consolas,monospace}
.ok{color:#107c10}.bad{color:#c50f1f}
</style></head>
<body>
<h1>Clipboard write test</h1>
<p>Token: <code>__TOKEN__</code></p>
<p><button id="btn" autofocus>Copy token to clipboard</button></p>
<p>Click the button (or press Enter - the button has focus), then return to the PowerShell window. This page only talks to 127.0.0.1.</p>
<div id="log"></div>
<script>
var TOKEN = "__TOKEN__";
var RESULT_URL = location.pathname.replace(/\/$/, "") + "/result";
function log(cls, msg) { var d = document.createElement("div"); d.className = cls; d.textContent = msg; document.getElementById("log").appendChild(d); }
function report(o) {
  o.secure = window.isSecureContext; o.focused = document.hasFocus(); o.ua = navigator.userAgent;
  o.activation = !!(navigator.userActivation && navigator.userActivation.isActive);
  try { fetch(RESULT_URL, { method: "POST", headers: { "Content-Type": "text/plain" }, body: JSON.stringify(o) }); } catch (e) {}
}
function execCopy(phase) {
  var ta = document.createElement("textarea"); ta.value = TOKEN; document.body.appendChild(ta); ta.select();
  var ok = false, err = "";
  try { ok = document.execCommand("copy"); } catch (e) { err = String(e); }
  document.body.removeChild(ta);
  if (!ok && !err) { err = "execCommand('copy') returned false"; }
  log(ok ? "ok" : "bad", "[" + phase + "] execCommand('copy') " + (ok ? "returned true" : "failed: " + err));
  report({ phase: phase, api: "execCommand", ok: ok, error: err });
  document.getElementById("btn").focus();
}
function tryCopy(phase) {
  if (!navigator.clipboard || !navigator.clipboard.writeText) {
    log("bad", "[" + phase + "] navigator.clipboard.writeText is unavailable");
    report({ phase: phase, api: "clipboard", ok: false, error: "navigator.clipboard unavailable" });
    execCopy(phase); return;
  }
  var settled = false, t0 = Date.now();
  var timer = setTimeout(function () {
    if (settled) { return; }
    log("bad", "[" + phase + "] navigator.clipboard.writeText still pending after 3 s");
    report({ phase: phase, api: "clipboard", ok: false, pending: true, ms: Date.now() - t0, error: "writeText promise still pending after 3 s" });
  }, 3000);
  navigator.clipboard.writeText(TOKEN).then(function () {
    settled = true; clearTimeout(timer);
    log("ok", "[" + phase + "] navigator.clipboard.writeText resolved after " + (Date.now() - t0) + " ms (browser reports success)");
    report({ phase: phase, api: "clipboard", ok: true, ms: Date.now() - t0, error: "" });
  }, function (e) {
    settled = true; clearTimeout(timer);
    var m = (e && e.name ? e.name + ": " : "") + (e && e.message ? e.message : String(e));
    log("bad", "[" + phase + "] navigator.clipboard.writeText rejected: " + m);
    report({ phase: phase, api: "clipboard", ok: false, ms: Date.now() - t0, error: m });
    execCopy(phase);
  });
}
function perm() {
  if (navigator.permissions && navigator.permissions.query) {
    navigator.permissions.query({ name: "clipboard-write" }).then(function (p) {
      log("", "clipboard-write permission: " + p.state);
      report({ phase: "permission", api: "permissions", ok: true, error: "", permission: p.state });
    }, function (e) { report({ phase: "permission", api: "permissions", ok: false, error: String(e), permission: "unsupported" }); });
  }
}
document.getElementById("btn").addEventListener("click", function () { tryCopy("click"); });
window.addEventListener("load", function () {
  report({ phase: "loaded", api: "page", ok: true, error: "" });
  perm(); setTimeout(function () { tryCopy("auto"); }, 400);
});
</script>
</body></html>
'@
    return $html.Replace('__TOKEN__', $Token).Replace('__RUNID__', $RunId)
}

function Get-BrowserPasteTestPage {
    <#
    .SYNOPSIS
        Build a local page that receives paste events without exposing content.
    .NOTES
        The handler prevents insertion and reports only format names and
        text/plain or text/html character counts. Audit Notes: no clipboard
        writes and no clipboard payloads are sent to the listener.
    #>
    param([string]$RunId = 'run')
    $html = @'
<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Clipboard paste test [__RUNID__]</title>
<style>
body{font-family:"Segoe UI",sans-serif;margin:40px;max-width:760px;color:#222}
#target{border:2px dashed #777;border-radius:8px;padding:32px;text-align:center;background:#fafafa}
#log{margin-top:20px;font-family:Consolas,monospace}
</style></head>
<body>
<h1>Clipboard paste receive test</h1>
<p>Copy the relevant text from HackMD, click the box, then press Ctrl+V.</p>
<p>The pasted text will not appear in this page, be sent to the listener, or be saved. Only clipboard format names and text lengths are reported.</p>
<div id="target" tabindex="0">Click here, then press Ctrl+V</div>
<div id="log" role="status" aria-live="polite"></div>
<script>
var RESULT_URL = location.pathname.replace(/\/$/, "") + "/result";
function log(message) { document.getElementById("log").textContent = message; }
function report(o) {
  o.ua = navigator.userAgent;
  fetch(RESULT_URL, { method: "POST", headers: { "Content-Type": "text/plain" }, body: JSON.stringify(o) })
    .catch(function () { log("Could not report paste metadata to the local test listener."); });
}
document.getElementById("target").addEventListener("paste", function (e) {
  e.preventDefault();
  var clipboard = e.clipboardData;
  var types = clipboard ? Array.from(clipboard.types || []) : [];
  var textLengths = {};
  var errors = [];
  ["text/plain", "text/html"].forEach(function (type) {
    if (types.indexOf(type) !== -1) {
      try { textLengths[type] = clipboard.getData(type).length; }
      catch (err) { errors.push(type + ": " + String(err)); }
    }
  });
  var hasText = Object.keys(textLengths).some(function (type) { return textLengths[type] > 0; });
  report({ phase: "paste", api: "paste-event", ok: true, types: types, textLengths: textLengths, hasText: hasText, errors: errors });
  log("Paste event received. Text available: " + hasText + ". Format names and text lengths were reported; content was discarded.");
});
window.addEventListener("load", function () {
  report({ phase: "loaded", api: "page", ok: true });
});
</script>
</body></html>
'@
    return $html.Replace('__RUNID__', $RunId)
}

function Send-HttpResponse {
    <#
    .SYNOPSIS
        Write a minimal HTTP/1.1 response with Connection: close.
    .NOTES
        Side effects: writes to the given network stream only.
        Audit Notes: loopback-only connection.
    #>
    param([System.IO.Stream]$Stream, [int]$Status, [string]$Reason, [string]$ContentType, [byte[]]$Body)
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $header = "HTTP/1.1 $Status $Reason`r`nContent-Type: $ContentType`r`nContent-Length: $($Body.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($header)
    $Stream.Write($hb, 0, $hb.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Invoke-BrowserTestRequest {
    <#
    .SYNOPSIS
        Serve one HTTP request on the loopback test listener.
    .NOTES
        Routes: GET <BasePath>/ -> test page; POST <BasePath>/result -> JSON
        outcome appended to Results; anything else -> 404. BasePath is a
        random per-run secret so editor link previews or port scanners that
        probe "/" never load the page. Idle/preconnect sockets time out after
        1.5 s and are closed silently. Every request is logged to
        State.Requests (method, route, user-agent family) for the report.
        Audit Notes: request bodies are page results (no clipboard payloads).
    #>
    param([System.Net.Sockets.TcpClient]$Client, [byte[]]$PageBytes, [System.Collections.Generic.List[object]]$Results, [hashtable]$State, [string]$BasePath)
    try {
        $Client.ReceiveTimeout = 1500
        $Client.SendTimeout = 1500
        $stream = $Client.GetStream()
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object byte[] 8192
        $headerEnd = -1
        while ($headerEnd -lt 0 -and $ms.Length -lt 65536) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
            $headerEnd = [System.Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
        }
        if ($headerEnd -lt 0) { return }
        $all = $ms.ToArray()
        $lines = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd) -split "`r`n"
        $requestLine = $lines[0] -split ' '
        $method = $requestLine[0]
        $path = if ($requestLine.Count -gt 1) { $requestLine[1] } else { '/' }
        $contentLength = 0
        $userAgent = ''
        foreach ($l in $lines) {
            if ($l -match '^(?i)content-length:\s*(\d+)') { $contentLength = [int]$Matches[1] }
            elseif ($l -match '^(?i)user-agent:\s*(.*)$') { $userAgent = $Matches[1] }
        }
        $body = New-Object System.IO.MemoryStream
        $bodyStart = $headerEnd + 4
        if ($all.Length -gt $bodyStart) { $body.Write($all, $bodyStart, $all.Length - $bodyStart) }
        while ($body.Length -lt $contentLength -and $contentLength -le 65536) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $body.Write($buf, 0, $n)
        }
        $route = 'other'
        if ($method -eq 'GET' -and ($path -eq "$BasePath/" -or $path -eq $BasePath)) { $route = 'page' }
        elseif ($method -eq 'POST' -and $path -eq "$BasePath/result") { $route = 'result' }
        $State.Requests.Add([pscustomobject]@{
            time   = (Get-Date).ToString('o')
            method = $method
            route  = $route
            client = (Get-BrowserFamily -UserAgent $userAgent)
        })
        switch ($route) {
            'page' {
                Send-HttpResponse -Stream $stream -Status 200 -Reason 'OK' -ContentType 'text/html; charset=utf-8' -Body $PageBytes
                $State.PageServed = $true
                if ($null -eq $State.PageServedAt) { $State.PageServedAt = Get-Date }
            }
            'result' {
                try {
                    $obj = [System.Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json -ErrorAction Stop
                    $obj | Add-Member -NotePropertyName receivedAt -NotePropertyValue (Get-Date).ToString('o') -Force
                    $obj | Add-Member -NotePropertyName client -NotePropertyValue (Get-BrowserFamily -UserAgent ([string]$obj.ua)) -Force
                    $Results.Add($obj)
                }
                catch {
                    $State.BadResults++
                }
                Send-HttpResponse -Stream $stream -Status 204 -Reason 'No Content' -ContentType 'text/plain' -Body $null
            }
            default {
                Send-HttpResponse -Stream $stream -Status 404 -Reason 'Not Found' -ContentType 'text/plain' -Body ([System.Text.Encoding]::ASCII.GetBytes('not found'))
            }
        }
    }
    catch {
        Write-Verbose "Browser test request ignored: $($_.Exception.Message)"
    }
    finally {
        $Client.Close()
    }
}

function Get-BrowserClipboardPolicies {
    <#
    .SYNOPSIS
        Read Edge/Chrome clipboard policies from HKLM/HKCU.
    .OUTPUTS
        PSCustomObject[] { Browser; Hive; DefaultClipboardSetting; Allowed; Blocked }
    .NOTES
        Read-only registry access. DefaultClipboardSetting: 2 = block,
        3 = ask. Audit Notes: no side effects.
    #>
    $roots = @(
        @{ Browser = 'Edge'; Path = 'SOFTWARE\Policies\Microsoft\Edge' }
        @{ Browser = 'Chrome'; Path = 'SOFTWARE\Policies\Google\Chrome' }
    )
    foreach ($hive in @('HKEY_LOCAL_MACHINE', 'HKEY_CURRENT_USER')) {
        foreach ($r in $roots) {
            $base = "Registry::$hive\$($r.Path)"
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $props = Get-ItemProperty -LiteralPath $base -ErrorAction SilentlyContinue
            $default = $null
            if ($null -ne $props -and $null -ne $props.PSObject.Properties['DefaultClipboardSetting']) { $default = $props.DefaultClipboardSetting }
            $lists = @{}
            foreach ($listName in @('ClipboardAllowedForUrls', 'ClipboardBlockedForUrls')) {
                $lists[$listName] = @()
                $sub = Join-Path $base $listName
                if (Test-Path -LiteralPath $sub) {
                    $item = Get-Item -LiteralPath $sub
                    $lists[$listName] = @($item.GetValueNames() | ForEach-Object { [string]$item.GetValue($_) })
                }
            }
            if ($null -ne $default -or $lists.ClipboardAllowedForUrls.Count -or $lists.ClipboardBlockedForUrls.Count) {
                [pscustomobject]@{
                    Browser                 = $r.Browser
                    Hive                    = $(if ($hive -eq 'HKEY_LOCAL_MACHINE') { 'HKLM' } else { 'HKCU' })
                    DefaultClipboardSetting = $default
                    Allowed                 = $lists.ClipboardAllowedForUrls
                    Blocked                 = $lists.ClipboardBlockedForUrls
                }
            }
        }
    }
}

function Test-BrowserClipboardPolicies {
    <#
    .SYNOPSIS
        Report browser clipboard policies and how to check Edge site permissions.
    .NOTES
        Read-only. Audit Notes: policies saved to the report.
    #>
    Write-Section "Browser clipboard policies"
    $policies = @(Get-BrowserClipboardPolicies)
    $script:Report.config.browserPolicies = $policies
    if ($policies.Count -eq 0) {
        Write-Pass "No Edge/Chrome clipboard policies (DefaultClipboardSetting, ClipboardAllowedForUrls, ClipboardBlockedForUrls) are set."
    }
    foreach ($p in $policies) {
        $label = "$($p.Hive) $($p.Browser)"
        if ($null -ne $p.DefaultClipboardSetting) {
            $meaning = switch ([int]$p.DefaultClipboardSetting) { 2 { 'block' } 3 { 'ask' } default { 'other' } }
            $msg = "${label}: DefaultClipboardSetting = $($p.DefaultClipboardSetting) ($meaning). This policy governs the clipboard site permission (mainly reading)."
            if ([int]$p.DefaultClipboardSetting -eq 2) { Write-WarnLine $msg } else { Write-Info $msg }
        }
        if ($p.Blocked.Count) {
            $msg = "${label}: ClipboardBlockedForUrls = $($p.Blocked -join ', ')"
            if (($p.Blocked -join ' ') -match 'github|\*') { Write-Fail $msg; Add-Issue "$label clipboard policy blocks sites matching github/*." } else { Write-WarnLine $msg }
        }
        if ($p.Allowed.Count) { Write-Info "${label}: ClipboardAllowedForUrls = $($p.Allowed -join ', ')" }
    }
    $progId = $null
    $choice = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction SilentlyContinue
    if ($null -ne $choice) { $progId = $choice.ProgId }
    $script:Report.config.defaultBrowserProgId = $progId
    if ($progId) { Write-Info "Default browser ProgId for https: $progId" }
    Write-Info "Edge site permission for github.com: open https://github.com, click the icon left of the address bar -> 'Permissions for this site' -> Clipboard (or edge://settings/content/clipboard)."
}

function Invoke-BrowserClipboardTest {
    <#
    .SYNOPSIS
        -BrowserTest entrypoint: can the browser write to the Windows clipboard?
    .DESCRIPTION
        Starts a TcpListener on 127.0.0.1 with a random port (localhost is a
        secure context; no HttpListener URL ACL needed), opens the test page
        in the chosen browser, watches GetClipboardSequenceNumber for the
        token, and reports arrival time, owner process and the page's own
        success/error reports. Stops the listener in all cases.
    .NOTES
        Side effects: browser tab opens; the page overwrites the clipboard
        with a token; clipboard saved first and restored afterwards unless
        -NoRestore. Gated by Confirm-Change.
        Audit Notes: report contains token, owner, page results; no payloads.
    #>
    Test-BrowserClipboardPolicies
    Write-Section "Browser clipboard write test"
    if (-not (Initialize-NativeClipboard)) {
        Add-Issue "Browser test unavailable (native helper failed)."
        return
    }
    $browserLabel = if ($Browser -eq 'default') { 'the default browser' } else { $Browser }
    if ($InPrivate -and $Browser -ne 'default') { $browserLabel += ' (InPrivate/incognito)' }
    if (-not (Confirm-Change "Windows clipboard / $browserLabel" 'Open a 127.0.0.1 test page that writes a token to the clipboard (clipboard saved and restored)')) {
        return
    }
    try {
        $saved = Save-ClipboardState
    }
    catch {
        Write-Fail "Could not read the current clipboard to save it ($($_.Exception.Message)); browser test skipped to avoid data loss."
        Add-Issue "Clipboard could not be read before the browser test."
        return
    }
    $token = 'BROWSER-CLIPTEST-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $basePath = '/t/' + [guid]::NewGuid().ToString('N').Substring(0, 16)
    $runId = [guid]::NewGuid().ToString('N').Substring(0, 6)
    $pageBytes = [System.Text.Encoding]::UTF8.GetBytes((Get-BrowserTestPage -Token $token -RunId $runId))
    $results = New-Object System.Collections.Generic.List[object]
    $state = @{ PageServed = $false; PageServedAt = $null; Requests = (New-Object System.Collections.Generic.List[object]); BadResults = 0 }
    $expectedFamily = switch ($Browser) { 'msedge' { 'edge' } 'chrome' { 'chrome' } default { $null } }
    $arrival = $null
    $otherChanges = New-Object System.Collections.Generic.List[object]
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $started = Get-Date
    try {
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $url = "http://127.0.0.1:$port$basePath/"
        Write-Info "Listener started on 127.0.0.1 port $port (loopback only; page served on a random secret path)."
        switch ($Browser) {
            'msedge' { Start-Process -FilePath 'msedge.exe' -ArgumentList $(if ($InPrivate) { @('--inprivate', $url) } else { $url }) }
            'chrome' { Start-Process -FilePath 'chrome.exe' -ArgumentList $(if ($InPrivate) { @('--incognito', $url) } else { $url }) }
            default {
                if ($InPrivate) { Write-WarnLine "-InPrivate needs -Browser msedge or chrome; opening the default browser normally." }
                Start-Process -FilePath $url
            }
        }
        Write-Host "A page titled 'Clipboard write test [$runId]' opened in $browserLabel. Click 'Copy token to clipboard' there, or press Enter in that tab (it also tries once automatically)." -ForegroundColor Cyan
        Write-Host "Waiting up to $BrowserTimeoutSeconds s for the token to reach the Windows clipboard..." -ForegroundColor Cyan

        $lastSeq = [ClipDiagV2.Native]::GetClipboardSequenceNumber()
        $deadline = $started.AddSeconds($BrowserTimeoutSeconds)
        $graceUntil = $null
        while ((Get-Date) -lt $deadline) {
            while ($listener.Pending()) {
                Invoke-BrowserTestRequest -Client $listener.AcceptTcpClient() -PageBytes $pageBytes -Results $results -State $state -BasePath $basePath
            }
            if ($null -eq $graceUntil) {
                $firstClick = $results | Where-Object { $_.phase -eq 'click' } | Select-Object -First 1
                if ($null -ne $firstClick) {
                    $graceUntil = (Get-Date).AddSeconds(4)
                }
            }
            $seq = [ClipDiagV2.Native]::GetClipboardSequenceNumber()
            if ($seq -ne $lastSeq) {
                $lastSeq = $seq
                $read = [ClipDiagV2.Clip]::ReadTextExpect($token, 10, 30)
                $snap = [ClipDiagV2.Clip]::Snapshot($false, 0, 5, 20)
                if ($read.Matched -and $null -eq $arrival) {
                    $arrival = [pscustomobject]@{ Time = Get-Date; Snapshot = $snap; Attempts = $read.Attempts }
                    $graceUntil = (Get-Date).AddSeconds(2)
                    Write-Info "Token arrived after $([math]::Round(((Get-Date) - $started).TotalSeconds, 1)) s; clipboard owner: $(Format-ProcessLabel -ProcessId $snap.OwnerPid -Name $snap.OwnerName)."
                }
                elseif (-not $read.Matched) {
                    $otherChanges.Add([pscustomobject]@{ owner = (Format-ProcessLabel -ProcessId $snap.OwnerPid -Name $snap.OwnerName); formats = @($snap.Formats) })
                    Write-Info "Clipboard changed but does not hold the token (owner: $(Format-ProcessLabel -ProcessId $snap.OwnerPid -Name $snap.OwnerName))."
                }
            }
            if ($null -ne $graceUntil -and (Get-Date) -ge $graceUntil) { break }
            Start-Sleep -Milliseconds 50
        }
        while ($listener.Pending()) {
            Invoke-BrowserTestRequest -Client $listener.AcceptTcpClient() -PageBytes $pageBytes -Results $results -State $state -BasePath $basePath
        }
    }
    catch {
        Write-Err "Browser test failed: $($_.Exception.Message)"
    }
    finally {
        $listener.Stop()
        Write-Info "Listener stopped."
    }

    $foreign = @($state.Requests | Where-Object { $_.route -eq 'other' })
    if ($foreign.Count -gt 0) {
        Write-Info "$($foreign.Count) request(s) to other paths got 404 (favicon.ico, or an editor link preview probing the port): $((@($foreign | ForEach-Object { $_.client }) | Sort-Object -Unique) -join ', ')."
    }
    if ($state.BadResults -gt 0) {
        Write-WarnLine "$($state.BadResults) page result(s) could not be parsed."
    }
    $relevant = New-Object System.Collections.Generic.List[object]
    foreach ($r in $results) {
        $isTarget = ($r.client -ne 'electron') -and ($null -eq $expectedFamily -or $r.client -eq $expectedFamily)
        if (-not $isTarget) {
            Write-Info "Ignored result from a non-target client ($($r.client)): [$($r.phase)] $($r.api)."
            continue
        }
        $relevant.Add($r)
        switch ([string]$r.phase) {
            'loaded' { Write-Info "Page loaded in $($r.client) (focused=$($r.focused), secureContext=$($r.secure))." }
            'permission' { Write-Info "Browser clipboard-write permission state: $($r.permission)" }
            default {
                $elapsed = if ($null -ne $r.PSObject.Properties['ms'] -and $null -ne $r.ms) { " after $($r.ms) ms" } else { '' }
                $msg = "Page [$($r.phase)] $($r.api): $(if ($r.ok) { 'reported success' } else { "error: $($r.error)" })$elapsed (focused=$($r.focused), userActivation=$($r.activation))"
                if ($r.ok) { Write-Info $msg }
                elseif ($r.phase -eq 'auto') { Write-Info "$msg - the on-load attempt has no user gesture; only a click/Enter result is conclusive" }
                else { Write-WarnLine $msg }
            }
        }
    }
    $ua = ($relevant | Where-Object { $_.ua } | Select-Object -First 1).ua
    if ($ua) { Write-Info "User agent: $ua" }

    $writer = $null
    $clickResults = @($relevant | Where-Object { $_.phase -eq 'click' })
    $targetLoaded = @($relevant | Where-Object { $_.phase -eq 'loaded' }).Count -gt 0
    if ($null -ne $arrival) {
        $writer = Format-ProcessLabel -ProcessId $arrival.Snapshot.OwnerPid -Name $arrival.Snapshot.OwnerName
        Write-Pass "The browser CAN write to the Windows clipboard: token arrived; owner $writer."
        if ($clickResults.Count -eq 0) { Write-Info "The automatic on-load write succeeded (no click needed)." }
        $slowest = @($relevant | Where-Object { $_.api -eq 'clipboard' -and $_.ok -and $null -ne $_.PSObject.Properties['ms'] } | Sort-Object { [int]$_.ms } -Descending) | Select-Object -First 1
        if ($null -ne $slowest -and [int]$slowest.ms -ge 1000) {
            Write-WarnLine "But the write was slow: writeText took $($slowest.ms) ms to resolve. Until it resolves, the copy button may already show a check mark while Windows still holds the previous clipboard (or nothing). An overloaded browser (many tabs/extensions) is the usual cause."
            Add-Issue "Browser clipboard writes are slow ($($slowest.ms) ms); paste right after clicking a copy icon can come up blank/stale."
        }
    }
    elseif (-not $state.PageServed -or -not $targetLoaded) {
        Write-Fail "$browserLabel never loaded the test page within $BrowserTimeoutSeconds s (browser did not open or could not reach 127.0.0.1)."
        Add-Issue "Browser test page was not loaded by $browserLabel."
    }
    elseif ($clickResults.Count -eq 0) {
        Write-WarnLine "Inconclusive: the page loaded but the button was not clicked within $BrowserTimeoutSeconds s, and the on-load attempt did not reach the clipboard."
        Add-Issue "Browser clipboard test inconclusive (button not clicked)."
    }
    else {
        $clickOk = @($clickResults | Where-Object { $_.ok })
        $clickPending = @($clickResults | Where-Object { $_.pending })
        $clickErr = @($clickResults | Where-Object { -not $_.ok -and -not $_.pending })
        if ($clickOk.Count -gt 0) {
            Write-Fail "The page reported success (check mark) but the token never reached the Windows clipboard: the browser-to-Windows clipboard write is being dropped. This matches 'check mark shown, paste blank'."
            Add-Issue "Browser reported a successful copy but Windows never received it."
        }
        elseif ($clickPending.Count -gt 0) {
            Write-Fail "navigator.clipboard.writeText never settled after a user gesture: the browser could not complete the clipboard write."
            Add-Issue "Browser clipboard write hung (writeText promise pending)."
        }
        else {
            $last = ($clickErr | Select-Object -Last 1).error
            Write-Fail "The browser refused the clipboard write after a user gesture: $last"
            Add-Issue "Browser clipboard write rejected: $last"
        }
    }
    $script:Report.clipboard.browserTest = [ordered]@{
        browser      = $Browser
        inPrivate    = [bool]$InPrivate
        token        = $token
        pageServed   = $state.PageServed
        arrived      = ($null -ne $arrival)
        arrivalSecs  = $(if ($null -ne $arrival) { [math]::Round(($arrival.Time - $started).TotalSeconds, 2) } else { $null })
        owner        = $writer
        requests     = $state.Requests.ToArray()
        pageResults  = $results.ToArray()
        otherChanges = $otherChanges.ToArray()
    }
    Restore-ClipboardState -State $saved -Context 'the browser test'
}

#endregion

#region Main

function Invoke-Diagnose {
    <#
    .SYNOPSIS
        Default mode: read-only diagnostics, then save -> round-trips -> restore,
        then blocker checks (with -Fix remediation).
    .NOTES
        Destructive round-trips are skipped (with a FAIL) when the clipboard
        cannot be saved, unless -NoRestore was given.
        Audit Notes: see the safety header for every side effect.
    #>
    Test-HostPrerequisites
    if (Initialize-NativeClipboard) {
        Write-Section "Clipboard owner and formats"
        [void](Show-ClipboardState -Label 'beforeTests')
        Test-ClipboardLocks -DurationMs 3000 -IntervalMs 10
    }
    Test-ClipboardTools
    Test-ClipboardHistorySettings

    if (Confirm-Change 'Windows clipboard' 'Overwrite with diagnostic test data (saved first, restored afterwards)') {
        $saved = $null
        $canRun = $true
        try {
            $saved = Save-ClipboardState
            Write-Info "Saved current clipboard: $($saved.Summary)."
        }
        catch {
            if ($NoRestore) {
                Write-WarnLine "Could not save the clipboard ($($_.Exception.Message)); continuing because -NoRestore was given."
            }
            else {
                Write-Fail "Could not read the clipboard to save it ($($_.Exception.Message)). Round-trip tests skipped to avoid destroying your data; re-run with -NoRestore to force them."
                Add-Issue "Clipboard could not be read for saving."
                $canRun = $false
            }
        }
        if ($canRun) {
            try {
                Test-TextClipboard
                Test-UnicodeTextClipboard
                Test-ImageClipboard
            }
            finally {
                Write-Section "Restore clipboard"
                Restore-ClipboardState -State $saved -Context 'the round-trip tests'
            }
        }
    }
    else {
        Write-Info "Round-trip tests not run (-WhatIf)."
    }

    Test-KnownClipboardBlockers
    Test-EditorVimClipboard
    if ($Fix) {
        if ($RestartExplorer) { Restart-WindowsExplorer }
        if ($RestartClipboardService) { Restart-ClipboardUserService }
    }
    elseif ($RestartExplorer -or $RestartClipboardService) {
        Write-WarnLine "-RestartExplorer / -RestartClipboardService only take effect together with -Fix."
    }
    Show-CursorPasteGuidance
}

function Write-JsonReport {
    <#
    .SYNOPSIS
        Write .\reports\report-<stamp>.json with every check result.
    .NOTES
        Side effects: creates .\reports\ and one new file (gated by
        Confirm-Change; skipped with -NoReport). No clipboard payloads unless
        -ShowText. Audit Notes: path printed on success.
    #>
    param([int]$ExitCode)
    if ($NoReport) {
        return
    }
    $script:Report.exitCode = $ExitCode
    $dir = Join-Path $script:ScriptRoot 'reports'
    $path = Join-Path $dir ("report-{0}.json" -f $script:Stamp)
    if (-not (Confirm-Change $path 'Write JSON diagnostic report')) {
        return
    }
    try {
        [void][System.IO.Directory]::CreateDirectory($dir)
        $json = $script:Report | ConvertTo-Json -Depth 10
        [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "Report: $path"
    }
    catch {
        Write-Host "WARN: Could not write JSON report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Show-Summary {
    <#
    .SYNOPSIS
        Print applied fixes, remaining issues, next steps and privacy notices.
    .NOTES
        Side effects: console output only. Reads $script:* run state and
        mode switches for privacy wording. Audit Notes: informational.
    #>
    param([string]$Mode)
    Write-Section "Summary"

    if ($script:FixesApplied.Count -gt 0) {
        Write-Host "Fixes applied:" -ForegroundColor Green
        foreach ($item in $script:FixesApplied) {
            Write-Host "  - $item"
        }
    }

    if ($script:Issues.Count -gt 0) {
        Write-Host "Remaining issues:" -ForegroundColor Yellow
        foreach ($issue in $script:Issues) {
            Write-Host "  - $issue"
        }
    }
    elseif (-not $script:HadError) {
        Write-Host "PASS: No clipboard issues detected by this diagnostic." -ForegroundColor Green
    }

    if ($Mode -eq 'Diagnose') {
        Write-Host ""
        Write-Host "Next steps for paste problems:" -ForegroundColor Cyan
        Write-Host "  -TerminalPaste   run inside the terminal where Ctrl+V pastes blank"
        Write-Host "  -BrowserTest     check whether the browser can write to the clipboard"
        Write-Host "  -BrowserPasteTest check whether the browser receives copied text without exposing its contents"
        Write-Host "  -Watch           record a real copy (e.g. GitHub copy icon) and paste"
    }

    Write-Host ""
    $privacy = switch ($Mode) {
        'Diagnose' {
            if ($WhatIfPreference) { 'Privacy: -WhatIf - the clipboard was not modified.' }
            elseif ($NoRestore) { 'Privacy: -NoRestore - the clipboard still holds test data.' }
            else { 'Privacy: your clipboard (text/RTF/HTML/image/file list) was saved in memory and restored; other formats cannot be restored. Content was not printed or saved.' }
        }
        'Watch' { 'Privacy: watch mode logged owners, formats and text lengths only' + $(if ($ShowText) { ' plus the first 40 characters (-ShowText).' } else { '.' }) }
        'TerminalPaste' { 'Privacy: only generated test tokens were placed on the clipboard; your clipboard was restored afterwards.' }
        'BrowserTest' { 'Privacy: only a generated token was copied by the test page; your clipboard was restored afterwards.' }
        'BrowserPasteTest' { 'Privacy: the browser test reports clipboard format names and text lengths only; clipboard contents are neither modified nor saved.' }
        default { 'Privacy: export mode reads the current clipboard image and writes a PNG under .\output\.' }
    }
    Write-Host $privacy -ForegroundColor DarkYellow
    Write-Host "Limitation: a clipboard failure does not prove malware or system compromise." -ForegroundColor DarkYellow
    Write-Host "Limitation: this repo cannot patch the Cursor Windows Ctrl+V image-paste bug." -ForegroundColor DarkYellow
}

$selectedModes = @()
if ($ExportForCursor) { $selectedModes += 'ExportForCursor' }
if ($Watch) { $selectedModes += 'Watch' }
if ($TerminalPaste) { $selectedModes += 'TerminalPaste' }
if ($BrowserTest) { $selectedModes += 'BrowserTest' }
if ($BrowserPasteTest) { $selectedModes += 'BrowserPasteTest' }

Write-Host "Windows Clipboard Diagnostics $($script:ToolVersion)" -ForegroundColor Cyan
if ($selectedModes.Count -gt 1) {
    Write-Host "ERROR: Choose one mode at a time: $($selectedModes -join ', ')." -ForegroundColor Red
    exit 2
}
$mode = if ($selectedModes.Count -eq 1) { $selectedModes[0] } else { 'Diagnose' }
$script:Report.mode = $mode
Write-Host "Mode: $(if ($mode -eq 'Diagnose') { if ($Fix) { 'Diagnose + Fix' } else { 'Diagnose only' } } else { $mode })"
if ($WhatIfPreference) {
    Write-Info "-WhatIf: changes are previewed, not performed."
}
if ($Fix -and $mode -ne 'Diagnose') {
    Write-WarnLine "-Fix only applies to the default diagnose mode; ignored for -$mode."
}

try {
    switch ($mode) {
        'ExportForCursor' { Export-ClipboardImageForCursor }
        'Watch' { Test-HostPrerequisites; Invoke-ClipboardWatch }
        'TerminalPaste' { Test-HostPrerequisites; Invoke-TerminalPasteDiagnosis }
        'BrowserTest' { Test-HostPrerequisites; Invoke-BrowserClipboardTest }
        'BrowserPasteTest' { Invoke-BrowserPasteTest }
        default { Invoke-Diagnose }
    }
}
catch {
    Write-Err "Unexpected error: $($_.Exception.Message)"
}

Show-Summary -Mode $mode

$exitCode = 0
if ($script:HadError) {
    $exitCode = 2
}
elseif ($script:Issues.Count -gt 0) {
    $exitCode = 1
}
Write-JsonReport -ExitCode $exitCode
exit $exitCode

#endregion
