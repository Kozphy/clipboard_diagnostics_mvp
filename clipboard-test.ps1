################################################################################
# SAFETY HEADER — clipboard-test.ps1
# ------------------------------------------------------------------------------
# Purpose:
#   Local Windows clipboard diagnostic and limited remediation utility (MVP).
#
# Privileges:
#   Runs as the current interactive user. Does not require Administrator.
#   May stop/restart PowerToys processes owned by the current user when -Fix
#   triggers Mouse Without Borders remediation.
#
# Modes:
#   Default / -Fix     Diagnose text+image clipboard; optionally disable MWB
#                      Share Clipboard. OVERWRITES the Windows clipboard.
#   -ExportForCursor   Read current clipboard image/file-drop and write a PNG
#                      under .\output\. Does NOT run destructive round-trip tests.
#   -OpenFolder        With -ExportForCursor, open Explorer selecting the PNG.
#
# Side effects (by mode):
#   Diagnose/-Fix: Set-Clipboard / Clipboard.Clear / Clipboard.SetImage;
#                  may edit %LOCALAPPDATA%\Microsoft\PowerToys\MouseWithoutBorders\settings.json;
#                  may Stop-Process / Start-Process PowerToys*.
#   Export:        Creates .\output\ if missing; writes clipboard-for-cursor-*.png;
#                  may Start-Process explorer.exe when -OpenFolder is set.
#
# Idempotency:
#   Diagnose round-trips always mutate clipboard (not idempotent).
#   -Fix disabling ShareClipboard is idempotent if already false.
#   Export creates a NEW timestamped PNG each run (append-only file creation).
#
# Safety boundaries:
#   Does not restore prior clipboard contents after diagnose/-Fix.
#   Does not patch Cursor IDE. Does not claim malware/compromise detection.
#   Does not print prior clipboard text/image payloads except the diagnose
#   test GUID and export path metadata.
#
# Recovery:
#   Re-copy needed clipboard data after diagnose/-Fix.
#   Re-enable PowerToys Mouse Without Borders Share Clipboard in PowerToys UI
#   if cross-PC clipboard sharing is required again.
#   Delete sensitive files under .\output\ when finished.
#
# Exit codes:
#   0 = no remaining $script:Issues
#   1 = one or more remaining issues
#   2 = hard error recorded ($script:HadError)
################################################################################

<#
.SYNOPSIS
    Diagnose Windows clipboard text/image round-trips, fix common blockers, and
    export clipboard images for Cursor Agent on Windows.

.DESCRIPTION
    Single-file MVP entrypoint for local clipboard health checks on Windows.

    Responsibility:
      Validate that Windows can round-trip text and bitmap clipboard data,
      detect a known PowerToys Mouse Without Borders Share Clipboard blocker,
      optionally disable that setting, and optionally export the current
      clipboard image to a PNG for drag-and-drop into Cursor Agent (Windows),
      which often ignores Ctrl+V for images.

    System position:
      Standalone script. No packages, services, databases, or network APIs.
      Invoked manually from a shell in this repository root.

    Invariants:
      - Diagnose/-Fix paths replace clipboard contents and do not restore them.
      - -ExportForCursor skips destructive round-trip tests.
      - Exit status is derived from $script:HadError and $script:Issues only.
      - ShareClipboard edits use a targeted regex replace to avoid rewriting
        unrelated PowerToys settings fields.

    Input assumptions:
      - Windows 10/11 with PowerShell 5.1+ (or PowerShell 7+).
      - Interactive desktop session with a usable clipboard.
      - For -Fix: PowerToys Mouse Without Borders settings.json may exist under
        the current user's LocalAppData.
      - For -ExportForCursor: clipboard already holds an image or image file drop.

    Output guarantees:
      - Console PASS/FAIL/ERROR/WARN/INFO lines describing each check.
      - Process exit code 0, 1, or 2 as documented in the safety header.
      - -ExportForCursor may create .\output\clipboard-for-cursor-<timestamp>.png.

.PARAMETER Fix
    When Mouse Without Borders Share Clipboard is enabled, disable it and
    restart the Mouse Without Borders module (may restart PowerToys).

.PARAMETER ExportForCursor
    Save the current clipboard image to .\output\ as a PNG for drag-and-drop
    into Cursor. Does not run destructive clipboard tests (so your copied
    image is preserved until export).

.PARAMETER OpenFolder
    After -ExportForCursor, open File Explorer to the saved PNG.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Fix

.EXAMPLE
    # 1) Copy a screenshot  2) run this  3) drag the PNG into Cursor Agent
    powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -ExportForCursor -OpenFolder

.NOTES
    Engineering Notes:
      - Regex-based ShareClipboard update preserves other settings (including
        secrets) better than ConvertTo-Json round-tripping on Windows PowerShell 5.1.
      - Export mode is separate from diagnose mode so a copied screenshot is not
        destroyed by the text/image round-trip tests.

    Audit Notes:
      Critical mutations: clipboard overwrite (diagnose/-Fix), PNG write (export),
      PowerToys settings.json edit (-Fix), process stop/start (-Fix).
      Detect via console summary lines, presence of .\output\ PNGs, and the
      ShareClipboard value in Mouse Without Borders settings.json.
#>
[CmdletBinding()]
param(
    [switch]$Fix,
    [switch]$ExportForCursor,
    [switch]$OpenFolder
)

$ErrorActionPreference = "Stop"
# Script-scoped run state used for summary + exit codes (not persisted to disk).
$script:HadFailure = $false
$script:HadError = $false
$script:Issues = New-Object System.Collections.Generic.List[string]
$script:FixesApplied = New-Object System.Collections.Generic.List[string]
# Prefer $PSScriptRoot so export paths stay repo-relative even if cwd differs.
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Pass {
    param([string]$Message)
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Write-Fail {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:HadFailure = $true
}

function Write-Err {
    param([string]$Message)
    Write-Host "ERROR: $Message" -ForegroundColor Red
    $script:HadError = $true
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO: $Message"
}

function Write-WarnLine {
    param([string]$Message)
    Write-Host "WARN: $Message" -ForegroundColor Yellow
}

function Initialize-ClipboardAssemblies {
    <#
    .SYNOPSIS
        Load WinForms/Drawing assemblies required for image clipboard APIs.
    .NOTES
        Side effects: loads System.Windows.Forms and System.Drawing into the
        current PowerShell process (idempotent if already loaded).
        Throws if Add-Type fails (missing desktop assemblies / constrained runspace).
    #>
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
}

function Get-OutputDirectory {
    <#
    .SYNOPSIS
        Resolve and ensure the repo-local .\output directory exists.
    .OUTPUTS
        System.String — absolute path to the output directory.
    .NOTES
        Side effects: creates .\output under $script:ScriptRoot when missing.
        Idempotent directory creation.
    #>
    $dir = Join-Path $script:ScriptRoot "output"
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    return $dir
}

function Export-ClipboardImageForCursor {
    <#
    .SYNOPSIS
        Export the current clipboard image (or first image file-drop) to a PNG.
    .DESCRIPTION
        Workaround for Cursor Agent on Windows ignoring Ctrl+V for clipboard
        images. Reads clipboard state; does not clear or replace clipboard data
        on the success path before save.
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
          External state change = new PNG under .\output\ (+ optional Explorer).
          Detect via PASS line with full path and filesystem listing of output\.
          Does not delete prior exports (non-destructive to older PNGs).
    #>
    Write-Section "Cursor Agent workaround (Windows)"
    Write-Info "Cursor Agent on Windows often ignores Ctrl+V for images (known client bug)."
    Write-Info "This tool cannot patch Cursor. It exports your clipboard image to a PNG for drag-and-drop."

    try {
        Initialize-ClipboardAssemblies

        $outputDir = Get-OutputDirectory
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $outPath = Join-Path $outputDir ("clipboard-for-cursor-{0}.png" -f $stamp)
        $saved = $false

        if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
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
        elseif ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
            $files = @([System.Windows.Forms.Clipboard]::GetFileDropList())
            $imageFile = $files | Where-Object {
                $_ -match '\.(png|jpe?g|gif|bmp|webp)$'
            } | Select-Object -First 1

            if ($imageFile -and (Test-Path -LiteralPath $imageFile)) {
                Copy-Item -LiteralPath $imageFile -Destination $outPath -Force
                $saved = $true
                Write-Pass "Clipboard held an image file. Copied to:"
                Write-Host "  $outPath"
                Write-Info "Source: $imageFile"
            }
            else {
                Write-Fail "Clipboard has files, but none look like a supported image."
                $script:Issues.Add("No exportable image file on the clipboard.")
            }
        }
        else {
            Write-Fail "No image found on the clipboard."
            Write-Info "Copy a screenshot or image first, then re-run with -ExportForCursor."
            $script:Issues.Add("Clipboard did not contain an image to export for Cursor.")
        }

        if ($saved) {
            $script:FixesApplied.Add("Exported clipboard image for Cursor drag-and-drop.")
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Cyan
            Write-Host "  1. Focus the Cursor Agent chat input"
            Write-Host "  2. Drag this PNG into the input (do not rely on Ctrl+V)"
            Write-Host "  3. Or type @ and browse to the file"
            Write-Host ""

            if ($OpenFolder) {
                Start-Process explorer.exe -ArgumentList "/select,`"$outPath`""
                Write-Info "Opened File Explorer to the exported PNG."
            }
        }
    }
    catch {
        Write-Err "Could not export clipboard image. $($_.Exception.Message)"
        $script:Issues.Add("Clipboard image export for Cursor failed.")
    }
}

function Show-CursorPasteGuidance {
    <#
    .SYNOPSIS
        Print Cursor Agent Windows Ctrl+V image-paste limitation and workaround.
    .NOTES
        Side effects: console output only. No clipboard or filesystem mutation.
    #>
    Write-Section "Cursor Agent (Windows)"
    Write-WarnLine "Cursor Agent often ignores Ctrl+V for clipboard images on Windows (known bug)."
    Write-Info "OS clipboard can be healthy while Cursor paste still fails."
    Write-Info "Workaround: copy your image, then run:"
    Write-Host '  powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -ExportForCursor -OpenFolder'
    Write-Info "Then drag the PNG from .\output\ into the Agent panel."
    Write-Info "Forum: https://forum.cursor.com/t/agent-chat-clipboard-image-paste-ctrl-v-context-menu-does-not-work-drag-and-drop-file-works/156818"
}

function Test-TextClipboard {
    <#
    .SYNOPSIS
        Round-trip a unique GUID string through Set-Clipboard / Get-Clipboard.
    .NOTES
        Side effects: OVERWRITES the Windows clipboard with CLIPBOARD_TEST_<guid>.
        Does not restore prior clipboard contents.
        Failure modes: content mismatch after 500ms; cmdlet exceptions.
        Audit Notes: detect via PASS/FAIL lines and Expected/Received output.
        A FAIL here indicates OS/session clipboard text path problems, not malware.
    #>
    Write-Section "Text clipboard"
    $test = "CLIPBOARD_TEST_" + [guid]::NewGuid().ToString("N")

    try {
        Set-Clipboard -Value $test
        Start-Sleep -Milliseconds 500
        $result = Get-Clipboard -Raw

        if ($null -eq $result) {
            $result = ""
        }

        if ($result.Trim() -eq $test) {
            Write-Pass "Text write/read is working."
            Write-Host "Test value: $result"
        }
        else {
            Write-Fail "Text clipboard content did not match."
            Write-Host "Expected: $test"
            Write-Host "Received: $result"
            $script:Issues.Add("Text clipboard round-trip failed.")
        }
    }
    catch {
        Write-Err "Text clipboard test failed. $($_.Exception.Message)"
        $script:Issues.Add("Text clipboard threw an exception.")
    }
}

function Test-ImageClipboard {
    <#
    .SYNOPSIS
        Round-trip a 32x32 solid-color bitmap through the WinForms clipboard.
    .NOTES
        Side effects: Clipboard.Clear then Clipboard.SetImage — destroys prior
        clipboard contents (text and image). Does not restore them.
        Success criterion: ContainsImage() is true after write; formats are logged.
        Failure modes: ContainsImage false; assembly load errors; GDI+ failures.
        Audit Notes: PASS includes dimensions; FAIL lists observed formats.
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
            Start-Sleep -Milliseconds 200
            [System.Windows.Forms.Clipboard]::SetImage($bmp)
            Start-Sleep -Milliseconds 500

            $hasImage = [System.Windows.Forms.Clipboard]::ContainsImage()
            $formats = @()
            $dataObject = [System.Windows.Forms.Clipboard]::GetDataObject()
            if ($null -ne $dataObject) {
                $formats = @($dataObject.GetFormats())
            }

            if ($hasImage) {
                $img = [System.Windows.Forms.Clipboard]::GetImage()
                try {
                    Write-Pass "Image write/read is working. ($($img.Width)x$($img.Height))"
                    Write-Info ("Formats: " + ($formats -join ", "))
                }
                finally {
                    if ($null -ne $img) {
                        $img.Dispose()
                    }
                }
            }
            else {
                Write-Fail "Image clipboard content was not available after write."
                Write-Info ("Formats: " + ($(if ($formats.Count) { $formats -join ", " } else { "(none)" })))
                $script:Issues.Add("Image clipboard round-trip failed.")
            }
        }
        finally {
            $bmp.Dispose()
        }
    }
    catch {
        Write-Err "Image clipboard test failed. $($_.Exception.Message)"
        $script:Issues.Add("Image clipboard threw an exception.")
    }
}

function Get-MouseWithoutBordersSettingsPath {
    <#
    .SYNOPSIS
        Build the per-user PowerToys Mouse Without Borders settings.json path.
    .OUTPUTS
        System.String — expected settings path (file may not exist).
    .NOTES
        No I/O. Path is under $env:LOCALAPPDATA for the current user only.
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
        Missing/malformed data returns $null and may emit WARN — callers must
        treat $null as "unknown", not as disabled.
        Side effects: reads settings file; may Write-WarnLine on parse errors.
        Does not log unrelated settings fields (avoids leaking secrets).
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
        Side effects: overwrites settings.json on disk (UTF-8).
        Throws if file missing, ShareClipboard block missing, or replace no-ops.
        Idempotency: writing the same bool twice leaves equivalent on-disk value.
        Constraint: only the first ShareClipboard value match is replaced.

        Audit Notes:
          What could go wrong: wrong file path; regex miss; PowerToys rewrite on
          next UI save; process still using old in-memory setting until restart.
          Detect: re-read via Get-MouseWithoutBordersShareClipboard; compare file.
          Recover: set Share Clipboard in PowerToys UI; restore settings from backup
          if the user keeps one (this script does not create backups).
    #>
    param([bool]$Enabled)

    $path = Get-MouseWithoutBordersSettingsPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Mouse Without Borders settings file not found: $path"
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
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

    Set-Content -LiteralPath $path -Value $updated -Encoding UTF8
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
        PowerToys; Start-Process on the PowerToys executable; sleeps 2–4 seconds.
        Failure modes: process stop denied; Start-Process path missing; module
        never returns — callers still continue.
        Idempotency: safe to call when module already stopped; may briefly
        interrupt other PowerToys modules if the runner is restarted.

        Audit Notes:
          Detect via Get-Process PowerToys / PowerToys.MouseWithoutBorders and
          console timing around -Fix. Recover by starting PowerToys from Start Menu.
    #>
    $mwb = Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue
    if ($mwb) {
        Stop-Process -Name "PowerToys.MouseWithoutBorders" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    if (-not (Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue)) {
        $powerToys = Get-Process -Name "PowerToys" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $powerToys -and $powerToys.Path) {
            $ptPath = $powerToys.Path
            Stop-Process -Name "PowerToys" -Force -ErrorAction SilentlyContinue
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
        Recovery if wrong: re-enable Share Clipboard in PowerToys when needed.
        Audit Notes: -Fix path mutates settings.json and may restart PowerToys.
    #>
    Write-Section "Known blockers"

    $mwbProcess = Get-Process -Name "PowerToys.MouseWithoutBorders" -ErrorAction SilentlyContinue
    $shareClipboard = Get-MouseWithoutBordersShareClipboard

    if ($null -eq $shareClipboard -and -not $mwbProcess) {
        Write-Info "PowerToys Mouse Without Borders not detected."
    }
    elseif ($null -eq $shareClipboard) {
        Write-WarnLine "Mouse Without Borders appears to be installed/running, but ShareClipboard could not be read."
    }
    elseif ($shareClipboard) {
        Write-Fail "PowerToys Mouse Without Borders has Share Clipboard enabled."
        Write-Info "This often breaks image copy/paste while text still works."
        $script:Issues.Add("Mouse Without Borders Share Clipboard is enabled.")

        if ($Fix) {
            try {
                Write-Info "Applying fix: disabling Share Clipboard..."
                Set-MouseWithoutBordersShareClipboard -Enabled $false
                Restart-MouseWithoutBordersModule

                $after = Get-MouseWithoutBordersShareClipboard
                if ($after -eq $false) {
                    Write-Pass "Disabled Mouse Without Borders Share Clipboard and restarted the module."
                    $script:FixesApplied.Add("Disabled Mouse Without Borders Share Clipboard.")
                    [void]$script:Issues.Remove("Mouse Without Borders Share Clipboard is enabled.")
                }
                else {
                    Write-Fail "Attempted to disable Share Clipboard, but it is still enabled."
                }
            }
            catch {
                Write-Err "Could not apply Mouse Without Borders fix. $($_.Exception.Message)"
            }
        }
        else {
            Write-WarnLine "Re-run with -Fix to disable Share Clipboard automatically."
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

function Show-Summary {
    <#
    .SYNOPSIS
        Print applied fixes, remaining issues, and privacy/limitation notices.
    .NOTES
        Side effects: console output only. Reads $script:* run state and
        $ExportForCursor switch for privacy wording.
    #>
    Write-Section "Summary"

    if ($script:FixesApplied.Count -gt 0) {
        Write-Host "Fixes applied:" -ForegroundColor Green
        foreach ($fix in $script:FixesApplied) {
            Write-Host "  - $fix"
        }
    }

    if ($script:Issues.Count -gt 0) {
        Write-Host "Remaining issues:" -ForegroundColor Yellow
        foreach ($issue in $script:Issues) {
            Write-Host "  - $issue"
        }
    }
    elseif (-not $script:HadError) {
        Write-Pass "No clipboard issues detected by this diagnostic."
    }

    Write-Host ""
    if (-not $ExportForCursor) {
        Write-Host "Privacy: diagnose mode replaces your clipboard contents and does not restore them." -ForegroundColor DarkYellow
    }
    else {
        Write-Host "Privacy: export mode reads the current clipboard image and writes a PNG under .\output\." -ForegroundColor DarkYellow
    }
    Write-Host "Limitation: a clipboard failure does not prove malware or system compromise." -ForegroundColor DarkYellow
    Write-Host "Limitation: this repo cannot patch the Cursor Windows Ctrl+V image-paste bug." -ForegroundColor DarkYellow
}

Write-Host "Windows Clipboard Diagnostics MVP" -ForegroundColor Cyan

if ($ExportForCursor) {
    Write-Host "Mode: Export clipboard image for Cursor Agent"
    Export-ClipboardImageForCursor
    Show-Summary
}
else {
    Write-Host "Mode: $(if ($Fix) { 'Diagnose + Fix' } else { 'Diagnose only' })"
    Test-TextClipboard
    Test-ImageClipboard
    Test-KnownClipboardBlockers
    Show-CursorPasteGuidance
    Show-Summary
}

if ($script:HadError) {
    exit 2
}
if ($script:Issues.Count -gt 0) {
    exit 1
}
exit 0
