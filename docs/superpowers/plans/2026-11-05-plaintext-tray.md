# PlainText Tray Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a dependency-free plain-Unicode clipboard rewrite, a timed `-PlainText` mode, and an always-on tray so Edge Copilot copies paste into Cursor Agent with Ctrl+V.

**Architecture:** `clipboard-core.ps1` holds settings, state, detection, rewrite, logging, toasts, the Scheduled Task provider, and export packaging, and it does nothing on dot-source. `clipboard-test.ps1` keeps today's diagnostics and calls that core for a foreground `-PlainText` session. `clipboard-tray.ps1` is the NotifyIcon host for the same core. Behavior is the locked spec at `docs/superpowers/specs/2026-11-05-plaintext-tray-design.md`.

**Tech Stack:** Windows PowerShell 5.1+/7+, WinForms NotifyIcon, WinRT toast, Windows Event Log, Scheduled Task (current user)

## Global Constraints

- Dependency-free: Windows PowerShell 5.1 or PowerShell 7+, WinForms, WinRT toast, inbox Scheduled Task, inbox Event Log, inbox `System.IO.Compression`. No NuGet, no BurntToast, no network client on the plain-text path.
- No clipboard text in UI, logs, toasts, the Event Log, Health, Export, console lines, or the `-PlainText` JSON report. Metadata only: outcome, reason code, character count, format names, process name, pid, sequence numbers, timestamps.
- `-Seconds` default stays **120** (range 5..3600) for `-Watch` and for `-PlainText`.
- Docs and examples use **600** for a timed PlainText session. Do not add that example to the README before `-PlainText` exists (Task 9).
- Silent PASS: timed console + file log + Event Log only. No toast and no balloon. The tray has no console, so a tray PASS is file + Event Log only.
- Toast only on FAIL and ERROR, and only when `notifications.toastOnFail` is true. There is no `-ToastOnPass` switch.
- Scheduled Task full name `\ClipboardDiagnosticsMvp\PlainTextTray`.
- Settings and state under `%LOCALAPPDATA%\clipboard_diagnostics_mvp\`.
- GPO/Intune is a seam only. `Get-StartupProvider` always returns the Scheduled Task provider. Policy keys are observed, not applied, and their values are not copied into logs or the zip.
- This repository cannot patch Cursor. Do not modify Cursor binaries or Cursor settings. Image paste stays `-ExportForCursor`.

Every task includes these constraints. Do not modify `tests/Run-Tests.ps1`. After every task, that existing harness must still pass.

---

## File Structure

```
clipboard-core.ps1          Create. Shared library. No param block. No UI forms.
clipboard-test.ps1          Modify. Add -PlainText. Leave ClipDiagV2 and other modes in place.
clipboard-tray.ps1          Create. NotifyIcon, Health form, menu, startup switches.
tests/Run-CoreTests.ps1     Create. Dot-sources the core. Never calls WinForms or the real clipboard.
tests/Run-Tests.ps1         Do not modify.
README.md                   Task 9 only, after -PlainText exists. Design link already exists.
```

Runtime files (never committed; tests pass `-Root` / `-LogDirectory` pointing at a temp directory):

```
%LOCALAPPDATA%\clipboard_diagnostics_mvp\settings.json
%LOCALAPPDATA%\clipboard_diagnostics_mvp\state.json
%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs\operational.log
%LOCALAPPDATA%\clipboard_diagnostics_mvp\tmp\<guid>\     export staging, deleted in finally
```

`settings.json` schema (version 1):

```json
{
  "version": 1,
  "paused": false,
  "startWithWindows": false,
  "notifications": { "toastOnFail": true },
  "logging": { "file": true, "eventLog": true },
  "plainText": { "pollIntervalMs": 400 }
}
```

`state.json` schema (version 1):

```json
{
  "version": 1,
  "rewriteCountTotal": 0,
  "lastActivityUtc": null,
  "lastRewriteUtc": null,
  "lastOutcome": null,
  "lastReason": null,
  "lastCharCount": null,
  "lastOwnerName": null
}
```

Test command for every core task (Windows PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'exact test name'
```

Omit `-TestName` to run the whole core harness. Exit `0` all passed, `1` an assertion failed, `2` the harness or the core file cannot be loaded. Existing diagnose tests:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

---

### Task 1: Core scaffolding, settings, and state

**Files:**
- Create: `clipboard-core.ps1`
- Create: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `$script:ClipboardCoreVersion = '1.0.0'`
  - `Get-ClipboardDiagnosticsRoot` → `[string]` `%LOCALAPPDATA%\clipboard_diagnostics_mvp`
  - `Get-ClipboardDiagnosticsDefaults` → settings `[pscustomobject]`
  - `Get-ClipboardDiagnosticsStateDefaults` → state `[pscustomobject]`
  - `Read-ClipboardDiagnosticsSettings -Root [string]` → `[pscustomobject]` with `Settings`, `Unsupported`, `Corrupt`, `Clamped`, `PausedEffective`
  - `Save-ClipboardDiagnosticsSettings -Settings -Root` → `[bool]` (`$false` when version is greater than 1; file untouched)
  - `Read-ClipboardDiagnosticsState -Root` → `[pscustomobject]` with `State`, `Unsupported`, `Corrupt`
  - `Save-ClipboardDiagnosticsState -State -Root` → `[bool]`
  - `Get-ClipboardRuntimeGate -SettingsResult -StateResult` → `PausedEffective` true when settings are paused or either store version is unsupported
  - `Resolve-ClipboardPolicySignal -HklmNames -HkcuNames` → `Present`, `Applied` (always `$false`), `Source` (`None`/`HKLM`/`HKCU`), `ValueNames`
  - `Get-ClipboardPolicySignal -ReadKey` → calls `Resolve-ClipboardPolicySignal`. Default `-ReadKey` reads `HKLM\Software\Policies\ClipboardDiagnosticsMvp` then `HKCU\Software\Policies\ClipboardDiagnosticsMvp` and returns value names only.

- [ ] **Step 1: Write the failing test**

Create `tests/Run-CoreTests.ps1` with the same assertion style as `tests/Run-Tests.ps1` (`Assert-True`, `Assert-Equal`, `Invoke-Test`, exit 0/1/2). Dot-source `clipboard-core.ps1`. Do not parse `clipboard-test.ps1` and do not call WinForms.

```powershell
param(
    [string]$CorePath,
    [string]$TempRoot = [System.IO.Path]::GetTempPath(),
    [string]$TestName = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CorePath)) {
    $CorePath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'clipboard-core.ps1'
}
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:CurrentTest = ''
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:Passed++ } else {
        $script:Failed.Add("[$script:CurrentTest] $Message")
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}
function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    $ok = ($null -eq $Expected -and $null -eq $Actual) -or ($null -ne $Expected -and $null -ne $Actual -and [string]$Expected -ceq [string]$Actual)
    Assert-True $ok "$Message (expected '$Expected', got '$Actual')"
}
function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    if (-not [string]::IsNullOrWhiteSpace($TestName) -and $Name -cne $TestName) { return }
    $script:CurrentTest = $Name
    Write-Host "TEST  $Name"
    try { & $Body } catch {
        $script:Failed.Add("[$Name] threw: $($_.Exception.Message)")
        Write-Host "  FAIL  threw: $($_.Exception.Message)" -ForegroundColor Red
    }
}
if (-not (Test-Path -LiteralPath $CorePath)) {
    Write-Host "ERROR script under test not found: $CorePath" -ForegroundColor Red
    exit 2
}
. $CorePath
$scratch = Join-Path $TempRoot ("clipcore-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($scratch)
try {
    Invoke-Test 'core top-level statements are only the version assignment' {
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($CorePath, [ref]$null, [ref]$parseErrors)
        Assert-Equal 0 @($parseErrors).Count 'core parses'
        Assert-True ($null -eq $ast.ParamBlock) 'core has no param block'
        $nonFn = @($ast.EndBlock.Statements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] })
        Assert-Equal 1 $nonFn.Count 'one non-function statement'
        Assert-True ($nonFn[0].Extent.Text -match 'ClipboardCoreVersion') 'version assignment'
        Assert-Equal '1.0.0' $script:ClipboardCoreVersion 'core version'
    }
    Invoke-Test 'settings round-trip preserves unknown property' {
        $root = Join-Path $scratch 'roundtrip'
        $first = Read-ClipboardDiagnosticsSettings -Root $root
        Assert-Equal 'False' $first.Settings.paused 'default paused'
        Assert-Equal 400 $first.Settings.plainText.pollIntervalMs 'default poll'
        $first.Settings | Add-Member -NotePropertyName extraFlag -NotePropertyValue $true -Force
        Assert-True (Save-ClipboardDiagnosticsSettings -Settings $first.Settings -Root $root) 'save ok'
        $again = Read-ClipboardDiagnosticsSettings -Root $root
        Assert-Equal 'True' $again.Settings.extraFlag 'unknown property kept'
        Assert-True (-not (Test-Path (Join-Path $root 'settings.json.tmp'))) 'no tmp left behind'
    }
    Invoke-Test 'corrupt settings are replaced and version 2 is not rewritten' {
        $root = Join-Path $scratch 'bad'
        [void][System.IO.Directory]::CreateDirectory($root)
        [System.IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{')
        $bad = Read-ClipboardDiagnosticsSettings -Root $root
        Assert-Equal 'True' $bad.Corrupt 'corrupt flag'
        Assert-Equal 'False' $bad.Settings.paused 'defaults restored in memory'
        $renamed = @(Get-ChildItem -LiteralPath $root -Filter 'settings.invalid-*.json')
        Assert-Equal 1 $renamed.Count 'corrupt file renamed'
        $verRoot = Join-Path $scratch 'ver2'
        [void][System.IO.Directory]::CreateDirectory($verRoot)
        $verPath = Join-Path $verRoot 'settings.json'
        [System.IO.File]::WriteAllText($verPath, '{"version":2,"paused":false,"custom":"keep-me"}')
        $before = [System.IO.File]::ReadAllText($verPath)
        $newer = Read-ClipboardDiagnosticsSettings -Root $verRoot
        Assert-Equal 'True' $newer.Unsupported 'unsupported flag'
        Assert-Equal 'True' $newer.PausedEffective 'run paused'
        Assert-Equal $before ([System.IO.File]::ReadAllText($verPath)) 'version 2 file not rewritten'
        Assert-True (-not (Save-ClipboardDiagnosticsSettings -Settings $newer.Settings -Root $verRoot)) 'save refused'
        Assert-Equal $before ([System.IO.File]::ReadAllText($verPath)) 'refused save left the file'
    }
    Invoke-Test 'poll interval 50 clamps to 200 and 9000 clamps to 5000' {
        foreach ($pair in @(@(50, 200), @(9000, 5000), @(200, 200), @(5000, 5000))) {
            $root = Join-Path $scratch ("poll-" + $pair[0])
            [void][System.IO.Directory]::CreateDirectory($root)
            $json = '{"version":1,"paused":false,"startWithWindows":false,"notifications":{"toastOnFail":true},"logging":{"file":true,"eventLog":true},"plainText":{"pollIntervalMs":' + $pair[0] + '}}'
            [System.IO.File]::WriteAllText((Join-Path $root 'settings.json'), $json)
            $read = Read-ClipboardDiagnosticsSettings -Root $root
            Assert-Equal $pair[1] $read.Settings.plainText.pollIntervalMs "clamp $($pair[0])"
            $expectClamp = ($pair[0] -ne $pair[1])
            Assert-Equal ([string]$expectClamp) ([string]$read.Clamped) "clamped flag $($pair[0])"
            Assert-True (([System.IO.File]::ReadAllText((Join-Path $root 'settings.json'))) -match ('"pollIntervalMs":' + $pair[0] + '|"pollIntervalMs": ' + $pair[0])) 'read does not rewrite the file'
        }
    }
    Invoke-Test 'state defaults are separate from settings and version 2 state is kept' {
        $root = Join-Path $scratch 'state'
        $state = Read-ClipboardDiagnosticsState -Root $root
        Assert-Equal 0 $state.State.rewriteCountTotal 'zero total'
        $state.State.rewriteCountTotal = 4
        Assert-True (Save-ClipboardDiagnosticsState -State $state.State -Root $root) 'state save'
        $settings = Read-ClipboardDiagnosticsSettings -Root $root
        Assert-Equal 'False' $settings.Settings.paused 'pause save is not required for this assertion'
        $settings.Settings.paused = $true
        Assert-True (Save-ClipboardDiagnosticsSettings -Settings $settings.Settings -Root $root) 'settings save'
        $stateAgain = Read-ClipboardDiagnosticsState -Root $root
        Assert-Equal 4 $stateAgain.State.rewriteCountTotal 'pause save did not reset counters'
        $ver = Join-Path $scratch 'state2'
        [void][System.IO.Directory]::CreateDirectory($ver)
        $path = Join-Path $ver 'state.json'
        [System.IO.File]::WriteAllText($path, '{"version":2,"rewriteCountTotal":9}')
        $before = [System.IO.File]::ReadAllText($path)
        $newer = Read-ClipboardDiagnosticsState -Root $ver
        Assert-Equal 'True' $newer.Unsupported 'state unsupported'
        Assert-Equal 0 $newer.State.rewriteCountTotal 'in-memory zeros'
        Assert-Equal $before ([System.IO.File]::ReadAllText($path)) 'state file kept'
        $gate = Get-ClipboardRuntimeGate -SettingsResult (Read-ClipboardDiagnosticsSettings -Root $root) -StateResult $newer
        Assert-Equal 'True' $gate.PausedEffective 'unsupported state forces pause'
    }
    Invoke-Test 'policy signal reports names only and HKLM wins' {
        $none = Resolve-ClipboardPolicySignal -HklmNames $null -HkcuNames $null
        Assert-Equal 'False' $none.Present 'absent'
        Assert-Equal 'False' $none.Applied 'never applied'
        Assert-Equal 'None' $none.Source 'source none'
        $hkcu = Resolve-ClipboardPolicySignal -HklmNames $null -HkcuNames @('StartupMode')
        Assert-Equal 'HKCU' $hkcu.Source 'hkcu'
        Assert-Equal 'StartupMode' (@($hkcu.ValueNames) -join ',') 'names only'
        $secret = 'C:\secret\override.json'
        $both = Resolve-ClipboardPolicySignal -HklmNames @('SettingsOverridePath') -HkcuNames @('StartupMode')
        Assert-Equal 'HKLM' $both.Source 'hklm wins'
        Assert-Equal 'False' $both.Applied 'applied stays false'
        Assert-True ((ConvertTo-Json $both) -notmatch [regex]::Escape($secret)) 'value data is not a result field'
        $def = ${function:Read-ClipboardPolicyKeyDefault}.ToString()
        Assert-True ($def.IndexOf('HKLM') -ge 0 -and $def.IndexOf('HKLM') -lt $def.IndexOf('HKCU')) 'default reader checks HKLM first'
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ''
if ($script:Failed.Count -eq 0) {
    Write-Host ("PASS  {0} assertions passed" -f $script:Passed) -ForegroundColor Green
    exit 0
}
Write-Host ("FAIL  {0} assertion(s) failed, {1} passed" -f $script:Failed.Count, $script:Passed) -ForegroundColor Red
$script:Failed | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'settings round-trip preserves unknown property'`

Expected: exit `2` and `ERROR script under test not found:` ending in `clipboard-core.ps1`.

- [ ] **Step 3: Write minimal implementation**

Create `clipboard-core.ps1`. The only top-level statement is the version assignment. `Add-Type` is not called at top level. `Read-*` creates `$Root` on first use. Saves write `*.json.tmp` in that directory and then `[System.IO.File]::Replace` when the destination exists, otherwise `Move`. A missing `version` is treated as 1 and is written on the next successful save. `pollIntervalMs` values below 200 become 200, above 5000 become 5000, and non-numeric values become 400; `Clamped` is true only when the stored number changed; `Read-*` does not write the file back. Corrupt JSON is renamed to `settings.invalid-<utc-yyyyMMddHHmmssfff>.json` or `state.invalid-<utc>.json`, then defaults are written. Version greater than 1 sets `Unsupported`, does not rename or write, and `Save-*` returns `$false`. `PausedEffective` is true when `Settings.paused` is true or `Unsupported` is true. `Get-ClipboardRuntimeGate` returns `PausedEffective` true if settings are effectively paused or state is unsupported. `Resolve-ClipboardPolicySignal` uses HKLM when that argument is not `$null` (an empty array means the key exists), else HKCU, else `None`. `Applied` is always `$false`. `Read-ClipboardPolicyKeyDefault` uses `Get-Item` on `HKLM:\Software\Policies\ClipboardDiagnosticsMvp` and then `HKCU:\...` and returns `GetValueNames()` only. `Get-ClipboardPolicySignal` passes those names into `Resolve-ClipboardPolicySignal`. Logging of `SettingsCorrupt`, `SettingsVersionUnsupported`, `StateCorrupt`, and `SettingsClamped` is not done in this task; the flags are the contract Task 2 logs.

`Get-ClipboardDiagnosticsRoot` joins `$env:LOCALAPPDATA` and `clipboard_diagnostics_mvp`. Defaults match the schema above, with `paused` `$false`, `startWithWindows` `$false`, `toastOnFail` `$true`, both logging flags `$true`, and `pollIntervalMs` 400. State defaults are version 1 and `rewriteCountTotal` 0, with the timestamp and last-* properties `$null`.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0` and a final line `PASS  N assertions passed`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`. Diagnose behavior is unchanged.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add clipboard core settings and state store"
```

---

### Task 2: LoggingProvider (file + Application Event Log)

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: Task 1 settings flags `Corrupt`, `Unsupported`, `Clamped`, and state `Corrupt` / `Unsupported`
- Produces:
  - `Format-OperationalMessage -Fields [hashtable]` → one metadata line, no timestamp
  - `New-LoggingProvider -LogDirectory -FileEnabled -EventLogEnabled -EventLogWriter -RotateBytes` → object with `Write($Fields)`, `Ring` (max 20), `FileEnabled`, `EventLogEnabled`
  - `Test-ClipboardEventLogSource` → `[bool]`
  - `Initialize-ClipboardEventLog` → `[pscustomobject]@{ Ready; Status }` where `Status` is `registered` or `unavailable`
  - `Publish-ClipboardStoreEvents -SettingsResult -StateResult -Logger` writes event `3001` reason `SettingsCorrupt`, `SettingsVersionUnsupported`, or `StateCorrupt`, and event `1107` reason `SettingsClamped`, once per call when the flag is set
  - Allowed field names: `Level`, `EventId`, `Mode`, `Process`, `Pid`, `FormatsBefore`, `FormatsAfter`, `CharCount`, `Sequence`, `Reason`
  - Event ids: `1000` PASS rewrite, `1001` clean session, `1100` tray start, `1101` tray quit, `1102` pause, `1103` resume, `1104` task installed, `1105` task removed, `1106` timed session skipped, `1107` settings clamped, `2000` FAIL, `2001` session FAIL, `3000` ERROR, `3001` store/startup ERROR, `3002` toast infrastructure ERROR

- [ ] **Step 1: Write the failing test**

Append these `Invoke-Test` blocks inside the `try` of `tests/Run-CoreTests.ps1`, before the `finally`.

```powershell
Invoke-Test 'Format-OperationalMessage emits the PASS metadata line' {
    $line = Format-OperationalMessage -Fields @{
        Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Process = 'msedge'; Pid = 4123
        FormatsBefore = @('HTML Format', 'CF_UNICODETEXT', 'Chromium Web Custom MIME Data Format')
        FormatsAfter = @('CF_UNICODETEXT', 'CF_TEXT'); CharCount = 842; Sequence = 101; Reason = 'Rewritten'
    }
    Assert-Equal 'level=PASS eventId=1000 mode=Tray process=msedge pid=4123 formatsBefore=HTML Format|CF_UNICODETEXT|Chromium Web Custom MIME Data Format formatsAfter=CF_UNICODETEXT|CF_TEXT charCount=842 sequence=101 reason=Rewritten' $line 'exact body'
}
Invoke-Test 'Format-OperationalMessage rejects clipboard fields and sanitizes reason' {
    $threwText = $false
    try { Format-OperationalMessage -Fields @{ Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Text = 'secret' } } catch { $threwText = $true }
    Assert-True $threwText 'Text rejected'
    $threwHtml = $false
    try { Format-OperationalMessage -Fields @{ Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Html = '<b>x</b>' } } catch { $threwHtml = $true }
    Assert-True $threwHtml 'Html rejected'
    $line = Format-OperationalMessage -Fields @{
        Level = 'FAIL'; EventId = 2000; Mode = 'Timed'; Process = 'msedge'; Reason = "one`nline"; FormatsBefore = @('a|b')
    }
    Assert-True ($line -match 'reason=one line') 'newline becomes space'
    Assert-True ($line -match 'formatsBefore=a/b') 'pipe in a format name becomes slash'
    $threwPath = $false
    try { Format-OperationalMessage -Fields @{ Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Process = 'C:\Windows\msedge.exe' } } catch { $threwPath = $true }
    Assert-True $threwPath 'process path rejected'
}
Invoke-Test 'file log rotates and the ring stays at 20 without a payload' {
    $dir = Join-Path $scratch 'logs'
    $writes = New-Object System.Collections.Generic.List[object]
    $logger = New-LoggingProvider -LogDirectory $dir -FileEnabled $true -EventLogEnabled $true -RotateBytes 80 -EventLogWriter {
        param($EntryType, $EventId, $Message) $writes.Add([pscustomobject]@{ EntryType = $EntryType; EventId = $EventId; Message = $Message })
    }
    $secret = 'COPILOT-SECRET-PHRASE'
    for ($i = 1; $i -le 21; $i++) {
        $logger.Write(@{ Level = 'PASS'; EventId = 1000; Mode = 'Tray'; Process = 'msedge'; CharCount = $i; Reason = 'Rewritten' })
    }
    Assert-Equal 20 @($logger.Ring).Count 'ring cap'
    Assert-Equal 21 $logger.Ring[-1].CharCount 'newest kept'
    $raw = Get-ChildItem -LiteralPath $dir -Filter 'operational*.log' | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }
    $joined = $raw -join "`n"
    Assert-True ($joined -notmatch [regex]::Escape($secret)) 'secret absent from logs'
    Assert-True ($joined -match 'level=PASS') 'pass line stored'
    Assert-True (@(Get-ChildItem -LiteralPath $dir -Filter 'operational-*.log').Count -ge 1) 'rotation renamed a file'
    Assert-Equal 21 $writes.Count 'event writer saw every record'
    Assert-Equal 1000 $writes[0].EventId 'event id preserved'
    Assert-True ($writes[0].Message -notmatch 'T00') 'event message has no timestamp prefix'
}
Invoke-Test 'disabled sinks still fill the ring and store flags publish once' {
    $dir = Join-Path $scratch 'silent-logs'
    $logger = New-LoggingProvider -LogDirectory $dir -FileEnabled $false -EventLogEnabled $false -EventLogWriter { throw 'should not be called' }
    $logger.Write(@{ Level = 'INFO'; EventId = 1107; Mode = 'Tray'; Reason = 'SettingsClamped' })
    Assert-Equal 1 @($logger.Ring).Count 'ring records when sinks are off'
    Assert-True (-not (Test-Path (Join-Path $dir 'operational.log'))) 'file sink off'
    $root = Join-Path $scratch 'clamp-log'
    [void][System.IO.Directory]::CreateDirectory($root)
    [System.IO.File]::WriteAllText((Join-Path $root 'settings.json'), '{"version":1,"plainText":{"pollIntervalMs":50}}')
    $settings = Read-ClipboardDiagnosticsSettings -Root $root
    Publish-ClipboardStoreEvents -SettingsResult $settings -StateResult (Read-ClipboardDiagnosticsState -Root $root) -Logger $logger
    Assert-True (@($logger.Ring | Where-Object { $_.Reason -eq 'SettingsClamped' -and $_.EventId -eq 1107 }).Count -ge 1) 'clamp event'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'Format-OperationalMessage emits the PASS metadata line'`

Expected: exit `1` and `FAIL  threw:` containing `Format-OperationalMessage` and `is not recognized`.

- [ ] **Step 3: Write minimal implementation**

Add the functions to `clipboard-core.ps1`. `Format-OperationalMessage` throws on any key outside the allow list, throws when `Level`, `EventId`, or `Mode` is missing, replaces CR/LF with a space, replaces `|` inside a single field with `/`, and throws when `Process` contains `\` or `/`. The returned line is exactly `level= eventId= mode= process= pid= formatsBefore= formatsAfter= charCount= sequence= reason=` in that order. Missing `CharCount` is `-1`. Missing `Pid` and `Sequence` are `0`.

`New-LoggingProvider` appends every accepted record to `Ring` and drops the oldest past 20, whether or not the sinks are enabled. When `FileEnabled`, it appends `<utc-roundtrip> ` plus the body to `operational.log`. When that file's length is at least `-RotateBytes` (default `1048576`) after the append, it renames the file to `operational-<utc-yyyyMMddHHmmssfff>.log`, starts a new `operational.log`, and deletes rotated files beyond the newest 5. When `EventLogEnabled` and `-EventLogWriter` is set, it calls the writer with the Event Log entry type (`Information` for 1000-1107, `Warning` for 2000-2001, `Error` for 3000-3002) and the body without a timestamp. When `-EventLogWriter` is omitted, the default writer calls `Write-EventLog -LogName Application -Source ClipboardDiagnosticsMvp` only if `Test-ClipboardEventLogSource` is true, and otherwise skips that sink.

`Test-ClipboardEventLogSource` returns `[System.Diagnostics.EventLog]::SourceExists('ClipboardDiagnosticsMvp')` and catches exceptions as `$false`. `Initialize-ClipboardEventLog` returns `registered` when the source exists. Otherwise it calls `New-EventLog -LogName Application -Source ClipboardDiagnosticsMvp`. Access denied returns `Ready=$false` and `Status='unavailable'` without throwing.

`Publish-ClipboardStoreEvents` writes at most one record per reason per call: `SettingsCorrupt` / `SettingsVersionUnsupported` / `StateCorrupt` use event `3001` and level `ERROR`; `SettingsClamped` uses event `1107` and level `INFO`. It does not include file paths that came from registry values.

Wire `Read-ClipboardDiagnosticsSettings` and `Read-ClipboardDiagnosticsState` so they do not log by themselves. Callers in later tasks call `Publish-ClipboardStoreEvents` after each read.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`, `PASS  N assertions passed`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add operational logging without clipboard payloads"
```

---

### Task 3: NotificationProvider (toast FAIL/ERROR, silent PASS)

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: `New-LoggingProvider` from Task 2 for the one-time `3002` / `ToastUnavailable` record
- Produces:
  - `Get-ClipboardToastText -Level -Reason -CharCount` → `Title`, `Body`
  - `ConvertTo-ToastXml -Title -Body` → `ToastText02` XML
  - `Get-ClipboardToastLaunchArguments -TrayScriptPath` → quoted `-File` action
  - `New-NotificationProvider -Kind Toast|Silent -ToastOnFail -ToastSender -FailureLogger` → `Send($Level, $Title, $Message)`, `Sent`, `ToastFailures`
  - Shortcut path constant `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClipboardDiagnosticsMvp.lnk`
  - AppUserModelID `ClipboardDiagnosticsMvp.PlainText`
  - Do not add a `-ToastOnPass` parameter. PASS is silent because `Send` drops `PASS` and `INFO`.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'toast text is metadata and ReadBackMismatch uses the verify body' {
    $fail = Get-ClipboardToastText -Level 'FAIL' -Reason 'OpenFailed' -CharCount -1
    Assert-Equal 'Clipboard plain-text rewrite failed' $fail.Title 'fail title'
    Assert-Equal 'Could not rewrite the clipboard (OpenFailed). The clipboard was left unchanged. Characters available: -1.' $fail.Body 'open failed body'
    $mismatch = Get-ClipboardToastText -Level 'FAIL' -Reason 'ReadBackMismatch' -CharCount 12
    Assert-Equal 'Clipboard rewrite could not be verified (ReadBackMismatch). Rich formats were not restored.' $mismatch.Body 'mismatch body'
    $err = Get-ClipboardToastText -Level 'ERROR' -Reason 'Exception IOException' -CharCount -1
    Assert-Equal 'Clipboard diagnostics error' $err.Title 'error title'
    Assert-Equal 'Plain-text helper hit an error (Exception IOException). See the operational log.' $err.Body 'error body'
    $xml = ConvertTo-ToastXml -Title 'A & B' -Body '1 < 2'
    Assert-True ($xml -match 'ToastText02') 'template'
    Assert-True ($xml -match 'A &amp; B') 'title escaped'
    Assert-True ($xml -match '1 &lt; 2') 'body escaped'
    Assert-True ($xml -notmatch '1 < 2') 'raw less-than absent'
    $args = Get-ClipboardToastLaunchArguments -TrayScriptPath 'C:\Program Files\clipboard_diagnostics_mvp\clipboard-tray.ps1'
    Assert-True ($args -match '-File "C:\\Program Files\\clipboard_diagnostics_mvp\\clipboard-tray.ps1"') 'path with spaces is quoted'
}
Invoke-Test 'Toast provider drops PASS and INFO and sends FAIL once per call' {
    $sent = New-Object System.Collections.Generic.List[string]
    $toast = New-NotificationProvider -Kind Toast -ToastOnFail $true -ToastSender { param($Xml) $sent.Add($Xml) }
    $toast.Send('PASS', 'ignored', 'ignored')
    $toast.Send('INFO', 'ignored', 'ignored')
    $fail = Get-ClipboardToastText -Level 'FAIL' -Reason 'NoExtractableText' -CharCount 0
    $toast.Send('FAIL', $fail.Title, $fail.Body)
    Assert-Equal 1 $sent.Count 'only the fail was built'
    Assert-Equal 0 @($toast.Sent | Where-Object { $_.Level -eq 'PASS' }).Count 'sent list has no pass toast'
    $silent = New-NotificationProvider -Kind Silent -ToastOnFail $true -ToastSender { throw 'silent must not send' }
    $silent.Send('FAIL', $fail.Title, $fail.Body)
    Assert-Equal 0 @($silent.Sent).Count 'silent sends nothing'
    $off = New-NotificationProvider -Kind Toast -ToastOnFail $false -ToastSender { throw 'toastOnFail false' }
    $off.Send('ERROR', 'Clipboard diagnostics error', 'body')
    Assert-Equal 0 @($off.Sent).Count 'toastOnFail false suppresses FAIL and ERROR'
}
Invoke-Test 'toast infrastructure failure is recorded once per provider' {
    $failures = 0
    $attempts = 0
    $toast = New-NotificationProvider -Kind Toast -ToastOnFail $true -ToastSender {
        param($Xml) $script:ToastAttempts++; throw 'winrt down'
    } -FailureLogger { param($Message) $script:ToastFailureLogs++ }
    $script:ToastAttempts = 0
    $script:ToastFailureLogs = 0
    $toast.Send('FAIL', 'Clipboard plain-text rewrite failed', 'Could not rewrite the clipboard (OpenFailed). The clipboard was left unchanged. Characters available: -1.')
    $toast.Send('FAIL', 'Clipboard plain-text rewrite failed', 'Could not rewrite the clipboard (OpenFailed). The clipboard was left unchanged. Characters available: -1.')
    Assert-Equal 2 $script:ToastAttempts 'later sends still try'
    Assert-Equal 1 $script:ToastFailureLogs 'one failure log'
    Assert-Equal 1 $toast.ToastFailures 'counter stays at one'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'toast text is metadata and ReadBackMismatch uses the verify body'`

Expected: exit `1` and `FAIL  threw:` containing `Get-ClipboardToastText`.

- [ ] **Step 3: Write minimal implementation**

`Get-ClipboardToastText` returns the titles and bodies from the spec. `ReadBackMismatch` uses the verify sentence. Every other FAIL uses the "left unchanged" sentence with `{CharCount}` rendered as the integer, including `-1`. `ConvertTo-ToastXml` wraps `ToastText02` and XML-escapes `&`, `<`, `>`, and `"`. `Get-ClipboardToastLaunchArguments` returns `-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "<TrayScriptPath>"`.

`New-NotificationProvider` of kind `Toast` calls `-ToastSender` only for `FAIL` and `ERROR` when `-ToastOnFail` is true (default `$true`). `PASS` and `INFO` return immediately. Kind `Silent` always returns immediately. Successful sends append `@{ Level; Title; Message }` to `Sent`. A throwing sender increments an internal attempt, sets `ToastFailures` to 1 on the first failure, and calls `-FailureLogger` only on that first failure. The default failure logger, when omitted, writes event `3002` reason `ToastUnavailable` through a `New-LoggingProvider` pointed at the diagnostics log directory. The default `-ToastSender`, when omitted, ensures the Start Menu shortcut exists (WScript.Shell shortcut whose target is `powershell.exe` and whose `System.AppUserModel.ID` property is `ClipboardDiagnosticsMvp.PlainText`), loads `Windows.UI.Notifications` and `Windows.Data.Xml.Dom` from WinRT, and calls `ToastNotificationManager.CreateToastNotifier('ClipboardDiagnosticsMvp.PlainText')`. Unit tests always pass `-ToastSender` and never load WinRT. Shortcut creation is not invoked by the tests. `-UninstallStartup` and Quit must not delete that shortcut; this function does not delete it either.

Do not call `NotifyIcon.ShowBalloonTip` anywhere.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add silent-pass toast notifications"
```

---

### Task 4: Plain-text rewrite helpers and timed `-PlainText`

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `clipboard-test.ps1` (param block near the existing `[int]$Seconds = 120`, safety header, mode switch near the `$selectedModes` block around the current `if ($Watch)` lines, `Show-Summary` privacy switch, new `Invoke-PlainTextSession`)
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`
- Do not move `ClipDiagV2`. Do not change `-Watch`, diagnose, `-Fix` (except the new "combined with `-PlainText`" exit), browser modes, or `-ExportForCursor`.

**Interfaces:**
- Consumes: Task 1 stores, Task 2 logger, Task 3 notification provider
- Produces:
  - `Test-ClipboardNeedsPlainText -FormatNames [string[]] -HasExtractableText [bool]` → `NeedsRewrite`, `Reason` (`NeedsRewrite`, `EmptyClipboard`, `AlreadyPlain`, `ProtectedFormat`, `NoExtractableText`)
  - `ConvertFrom-ClipboardHtmlBytes -Bytes [byte[]]` → `[string]` plain text only
  - `Select-ClipboardPlainText -UnicodeText -HtmlFormatBytes -TextHtmlBytes` → `Text`, `Source` (`UnicodeText`, `Html`, `None`). This helper is the only rewrite function allowed to return the string.
  - `New-ClipboardRewriteResult` → `Outcome`, `Reason`, `CharCount`, `FormatsBefore`, `FormatsAfter`, `SourceProcess`, `SequenceBefore`, `SequenceAfter`. No `Text`, `Preview`, `Html`, `Payload`, `SourceUrl`, or `WindowTitle`.
  - `Reset-ClipboardRewriteLoopState`
  - `Invoke-ClipboardPlainTextRewrite -WhatIf -ReadSnapshot -WriteUnicodeText -Now` → a `New-ClipboardRewriteResult`. Default snapshot/writer use WinForms inside the function (10 attempts, 50 ms) and are not called by unit tests.
  - `Get-ClipboardRunMode` → `Mode`, `ExitCode` (`2` when `-PlainText` is combined with any other mode or with `-Fix`)
  - `Get-PlainTextSessionExitCode -FailCount -ErrorCount -InvalidMode`
  - `New-PlainTextReport -Seconds -Events -RewriteCount -FailCount -ErrorCount`
  - `Format-PlainTextConsoleLine -Result`
  - `Get-ClipboardMutexName -Kind Tray|Rewrite|PlainTextSession`
  - `Invoke-PlainTextObservation -PreviousSequence -CurrentSequence -Paused -RewriteLockHeld -Rewrite`
  - `Get-StaRelaunchArguments -ScriptPath -Arguments`
  - `clipboard-test.ps1` switch `-PlainText`, `$script:ToolVersion = '3.0.0'`, dot-source of `clipboard-core.ps1` after `$script:ScriptRoot` is set

Trigger formats, ordinal case-insensitive: `HTML Format`, `text/html`, `Chromium Web Custom MIME Data Format`.

Protected formats: `CF_BITMAP`, `CF_DIB`, `CF_DIBV5`, `CF_TIFF`, `CF_HDROP`, `CF_ENHMETAFILE`, `CF_METAFILEPICT`, `Bitmap`, `System.Drawing.Bitmap`, `DeviceIndependentBitmap`, `Format17`, `FileDrop`, `FileName`, `FileNameW`, `PNG`, `image/png`.

Evaluation order: no names → `EmptyClipboard`; any protected → `ProtectedFormat`; any trigger without extractable text → `NoExtractableText`; any trigger with extractable text → `NeedsRewrite`; otherwise `AlreadyPlain`. `Rich Text Format` and `Chromium Internal Source URL` are neither trigger nor protected.

Text choice: if Unicode text trims to non-empty, write that original string unchanged. Else CF_HTML bytes, else `text/html` bytes, via `ConvertFrom-ClipboardHtmlBytes`. Else FAIL `NoExtractableText` and do not clear the clipboard.

HTML converter: UTF-8 bytes; use `StartFragment`/`EndFragment` when end is greater than start and both are inside the buffer; else `<!--StartFragment-->`…`<!--EndFragment-->`; else the body after the header. Drop `script` and `style` contents, strip tags, decode the named entities `&amp; &lt; &gt; &quot; &apos; &nbsp;` and numeric references. `nbsp` becomes U+0020. Trim ends only. Never return `SourceURL`.

Rewrite: one retry on read-back mismatch (ordinal string equality and a changed sequence). Do not put HTML back. Three PASS results with the same `CharCount` inside 2 seconds set a 10-second suppression; the next call returns FAIL `RewriteLoopSuppressed` and does not write. `-WhatIf` does not call the writer.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'Test-ClipboardNeedsPlainText classifies trigger and protected sets' {
    $html = Test-ClipboardNeedsPlainText -FormatNames @('HTML Format', 'UnicodeText') -HasExtractableText $true
    Assert-Equal 'True' $html.NeedsRewrite 'html plus unicode'
    Assert-Equal 'NeedsRewrite' $html.Reason 'needs reason'
    $mime = Test-ClipboardNeedsPlainText -FormatNames @('Chromium Web Custom MIME Data Format') -HasExtractableText $true
    Assert-Equal 'NeedsRewrite' $mime.Reason 'chromium mime'
    $textHtml = Test-ClipboardNeedsPlainText -FormatNames @('text/html') -HasExtractableText $true
    Assert-Equal 'NeedsRewrite' $textHtml.Reason 'text/html'
    $plain = Test-ClipboardNeedsPlainText -FormatNames @('UnicodeText', 'CF_TEXT') -HasExtractableText $true
    Assert-Equal 'AlreadyPlain' $plain.Reason 'unicode only'
    $empty = Test-ClipboardNeedsPlainText -FormatNames @() -HasExtractableText $false
    Assert-Equal 'EmptyClipboard' $empty.Reason 'empty'
    $file = Test-ClipboardNeedsPlainText -FormatNames @('HTML Format', 'FileDrop') -HasExtractableText $true
    Assert-Equal 'ProtectedFormat' $file.Reason 'file drop wins'
    $png = Test-ClipboardNeedsPlainText -FormatNames @('html format', 'PNG') -HasExtractableText $true
    Assert-Equal 'ProtectedFormat' $png.Reason 'png wins and html match is case-insensitive'
    $url = Test-ClipboardNeedsPlainText -FormatNames @('HTML Format', 'Chromium Internal Source URL', 'UnicodeText') -HasExtractableText $true
    Assert-Equal 'NeedsRewrite' $url.Reason 'source url is not protected'
    $rtf = Test-ClipboardNeedsPlainText -FormatNames @('Rich Text Format', 'UnicodeText') -HasExtractableText $true
    Assert-Equal 'AlreadyPlain' $rtf.Reason 'rtf alone is not a trigger'
    $none = Test-ClipboardNeedsPlainText -FormatNames @('HTML Format') -HasExtractableText $false
    Assert-Equal 'NoExtractableText' $none.Reason 'trigger without text'
    Assert-Equal 'False' $none.NeedsRewrite 'no rewrite flag'
}
Invoke-Test 'ConvertFrom-ClipboardHtmlBytes reads the fragment and drops source URL' {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $fragment = 'A &amp; B &lt;tag&gt; &quot;q&quot; &apos;z&apos;&nbsp;&#65;&#x42;'
    $html = "Version:0.9`r`nStartFragment:0000000097`r`nEndFragment:0000000000`r`nSourceURL:https://secret.example/token`r`n<html><body><!--StartFragment-->$fragment<!--EndFragment--></body></html>"
    # Zero EndFragment forces the marker fallback. The secret URL stays in the header.
    $text = ConvertFrom-ClipboardHtmlBytes -Bytes $utf8.GetBytes($html)
    Assert-Equal "A & B <tag> `"q`" 'z' AB" $text 'entities decoded'
    Assert-True ($text -notmatch 'secret.example') 'source url not returned'
    Assert-True ($text -notmatch '<') 'tags stripped'
    $scripted = $utf8.GetBytes("<html><!--StartFragment-->keep<script>SECRETCODE</script><style>SECRETSTYLE</style><!--EndFragment--></html>")
    $kept = ConvertFrom-ClipboardHtmlBytes -Bytes $scripted
    Assert-Equal 'keep' $kept 'script and style dropped'
    $offsets = "Version:0.9`r`nStartFragment:{0:D10}`r`nEndFragment:{1:D10}`r`nSourceURL:https://secret.example/token`r`n"
    $body = '<html><!--StartFragment-->offset-text<!--EndFragment--></html>'
    $prefix = $offsets
    # Build a real offset header in a second string once the prefix length is known.
    $header = 'Version:0.9' + "`r`n"
    $startLine = 'StartFragment:0000000000' + "`r`n"
    $endLine = 'EndFragment:0000000000' + "`r`n"
    $src = 'SourceURL:https://secret.example/token' + "`r`n"
    $payload = $header + $startLine + $endLine + $src + '<!--StartFragment-->offset-text<!--EndFragment-->'
    $bytes = $utf8.GetBytes($payload)
    $start = $utf8.GetBytes($header + $startLine + $endLine + $src + '<!--StartFragment-->').Length
    $end = $start + $utf8.GetBytes('offset-text').Length
    $fixed = $payload.Replace('StartFragment:0000000000', ('StartFragment:{0:D10}' -f $start)).Replace('EndFragment:0000000000', ('EndFragment:{0:D10}' -f $end))
    Assert-Equal 'offset-text' (ConvertFrom-ClipboardHtmlBytes -Bytes $utf8.GetBytes($fixed)) 'byte offsets'
    Assert-Equal '' (ConvertFrom-ClipboardHtmlBytes -Bytes $utf8.GetBytes('<!--StartFragment-->   <!--EndFragment-->')) 'empty fragment'
}
Invoke-Test 'Select-ClipboardPlainText prefers original Unicode text including whitespace' {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $html = $utf8.GetBytes('<!--StartFragment-->from-html<!--EndFragment-->')
    $preferred = Select-ClipboardPlainText -UnicodeText '  hello  ' -HtmlFormatBytes $html -TextHtmlBytes $null
    Assert-Equal '  hello  ' $preferred.Text 'whitespace kept'
    Assert-Equal 'UnicodeText' $preferred.Source 'unicode wins'
    $fallback = Select-ClipboardPlainText -UnicodeText '   ' -HtmlFormatBytes $html -TextHtmlBytes $null
    Assert-Equal 'from-html' $fallback.Text 'html fallback'
    $none = Select-ClipboardPlainText -UnicodeText $null -HtmlFormatBytes $null -TextHtmlBytes $null
    Assert-True ($null -eq $none.Text) 'nothing to write'
}
Invoke-Test 'rewrite result has no payload and retries read-back once' {
    Reset-ClipboardRewriteLoopState
    $secret = 'COPILOT-SECRET-PHRASE'
    $writes = 0
    $pass = Invoke-ClipboardPlainTextRewrite -Now ([datetime]'2026-11-05T12:00:00Z') -ReadSnapshot {
        [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format','UnicodeText'); UnicodeText = $secret; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'msedge'; Sequence = 10 }
    } -WriteUnicodeText {
        param($Text) $script:RewriteWrites++; [pscustomobject]@{ UnicodeText = $Text; Sequence = 11; FormatNames = @('UnicodeText','Text') }
    }
    Assert-Equal 'PASS' $pass.Outcome 'pass'
    Assert-Equal 'Rewritten' $pass.Reason 'rewritten'
    Assert-Equal $secret.Length $pass.CharCount 'count only'
    Assert-Equal 'msedge' $pass.SourceProcess 'owner before write'
    Assert-True ((ConvertTo-Json $pass) -notmatch [regex]::Escape($secret)) 'json has no phrase'
    foreach ($bad in @('Text','Preview','Html','Payload','SourceUrl','WindowTitle')) {
        Assert-True (@($pass.PSObject.Properties.Name) -notcontains $bad) "no $bad"
    }
    $script:RewriteWrites = 0
    Reset-ClipboardRewriteLoopState
    $mismatch = Invoke-ClipboardPlainTextRewrite -Now ([datetime]'2026-11-05T12:00:01Z') -ReadSnapshot {
        [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format'); UnicodeText = 'abc'; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'msedge'; Sequence = 1 }
    } -WriteUnicodeText {
        param($Text) $script:RewriteWrites++; [pscustomobject]@{ UnicodeText = 'DIFFERENT'; Sequence = 1; FormatNames = @('HTML Format') }
    }
    Assert-Equal 'FAIL' $mismatch.Outcome 'mismatch outcome'
    Assert-Equal 'ReadBackMismatch' $mismatch.Reason 'mismatch reason'
    Assert-Equal 2 $script:RewriteWrites 'one retry'
    $script:RewriteWrites = 0
    $open = Invoke-ClipboardPlainTextRewrite -ReadSnapshot {
        [pscustomobject]@{ Opened = $false; FormatNames = @(); UnicodeText = $null; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = ''; Sequence = 0 }
    } -WriteUnicodeText { param($Text) $script:RewriteWrites++; throw 'must not write' }
    Assert-Equal 'OpenFailed' $open.Reason 'open failed'
    Assert-Equal -1 $open.CharCount 'unknown count'
    Assert-Equal 0 $script:RewriteWrites 'no write'
    $empty = Invoke-ClipboardPlainTextRewrite -ReadSnapshot {
        [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format'); UnicodeText = ''; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'msedge'; Sequence = 3 }
    } -WriteUnicodeText { param($Text) throw 'must not clear' }
    Assert-Equal 'NoExtractableText' $empty.Reason 'no text'
    Assert-Equal 'FAIL' $empty.Outcome 'fail outcome'
    $protected = Invoke-ClipboardPlainTextRewrite -ReadSnapshot {
        [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format','FileDrop'); UnicodeText = 'path'; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'explorer'; Sequence = 4 }
    } -WriteUnicodeText { param($Text) throw 'must not touch file drop' }
    Assert-Equal 'Skip' $protected.Outcome 'protected skip'
    Assert-Equal 'ProtectedFormat' $protected.Reason 'protected reason'
    $script:WhatIfWrites = 0
    $what = Invoke-ClipboardPlainTextRewrite -WhatIf -ReadSnapshot {
        [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format','UnicodeText'); UnicodeText = 'abc'; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'msedge'; Sequence = 5 }
    } -WriteUnicodeText {
        param($Text) $script:WhatIfWrites++; [pscustomobject]@{ UnicodeText = $Text; Sequence = 6; FormatNames = @('UnicodeText') }
    }
    Assert-Equal 'WhatIf' $what.Outcome 'whatif'
    Assert-Equal 3 $what.CharCount 'whatif count'
    Assert-Equal 0 $script:WhatIfWrites 'whatif does not write'
    Assert-True ((ConvertTo-Json $what) -notmatch 'abc') 'whatif has no text'
}
Invoke-Test 'three identical passes suppress the next rewrite for 10 seconds' {
    Reset-ClipboardRewriteLoopState
    $script:LoopWrites = 0
    $now = [datetime]'2026-11-05T12:00:00Z'
    $read = { [pscustomobject]@{ Opened = $true; FormatNames = @('HTML Format'); UnicodeText = 'same'; HtmlFormatBytes = $null; TextHtmlBytes = $null; SourceProcess = 'msedge'; Sequence = 1 } }
    $write = { param($Text) $script:LoopWrites++; [pscustomobject]@{ UnicodeText = $Text; Sequence = 2; FormatNames = @('UnicodeText') } }
    foreach ($i in 1..3) {
        $one = Invoke-ClipboardPlainTextRewrite -Now $now -ReadSnapshot $read -WriteUnicodeText $write
        Assert-Equal 'PASS' $one.Outcome "pass $i"
    }
    $blocked = Invoke-ClipboardPlainTextRewrite -Now $now.AddSeconds(1) -ReadSnapshot $read -WriteUnicodeText $write
    Assert-Equal 'RewriteLoopSuppressed' $blocked.Reason 'suppressed'
    Assert-Equal 3 $script:LoopWrites 'no fourth write'
}
Invoke-Test 'run mode, exit codes, report, console line, and mutex names' {
    $ok = Get-ClipboardRunMode -PlainText $true -Watch $false -Fix $false -ExportForCursor $false -TerminalPaste $false -BrowserTest $false -BrowserPasteTest $false
    Assert-Equal 'PlainText' $ok.Mode 'plain text mode'
    Assert-Equal 0 $ok.ExitCode 'valid'
    $bad = Get-ClipboardRunMode -PlainText $true -Watch $true -Fix $false -ExportForCursor $false -TerminalPaste $false -BrowserTest $false -BrowserPasteTest $false
    Assert-Equal 2 $bad.ExitCode 'plain text plus watch'
    $fix = Get-ClipboardRunMode -PlainText $true -Watch $false -Fix $true -ExportForCursor $false -TerminalPaste $false -BrowserTest $false -BrowserPasteTest $false
    Assert-Equal 2 $fix.ExitCode 'plain text plus fix'
    $watchFix = Get-ClipboardRunMode -PlainText $false -Watch $true -Fix $true -ExportForCursor $false -TerminalPaste $false -BrowserTest $false -BrowserPasteTest $false
    Assert-Equal 'Watch' $watchFix.Mode 'watch plus fix stays watch'
    Assert-Equal 0 $watchFix.ExitCode 'existing fix warning behavior is unchanged'
    Assert-Equal 0 (Get-PlainTextSessionExitCode -FailCount 0 -ErrorCount 0 -InvalidMode $false) 'idle is success'
    Assert-Equal 1 (Get-PlainTextSessionExitCode -FailCount 1 -ErrorCount 0 -InvalidMode $false) 'fail'
    Assert-Equal 2 (Get-PlainTextSessionExitCode -FailCount 1 -ErrorCount 1 -InvalidMode $false) 'error wins'
    $report = New-PlainTextReport -Seconds 600 -RewriteCount 1 -FailCount 0 -ErrorCount 0 -Events @(
        [pscustomobject]@{ time = '2026-11-05T12:00:00.0000000Z'; outcome = 'PASS'; reason = 'Rewritten'; charCount = 3; formatsBefore = @('HTML Format'); formatsAfter = @('CF_UNICODETEXT'); sourceProcess = 'msedge'; sequenceBefore = 1; sequenceAfter = 2 }
    )
    Assert-Equal 'PlainText' $report.mode 'report mode'
    Assert-Equal 600 $report.seconds 'documented seconds pass through'
    Assert-True (@($report.events[0].PSObject.Properties.Name) -notcontains 'preview') 'no preview property'
    $line = Format-PlainTextConsoleLine -Result ([pscustomobject]@{ Outcome = 'PASS'; Reason = 'Rewritten'; CharCount = 3; FormatsBefore = @('HTML Format'); FormatsAfter = @('CF_UNICODETEXT'); SourceProcess = 'msedge' })
    Assert-Equal 'PASS rewrote clipboard chars=3 formats=HTML Format -> CF_UNICODETEXT source=msedge' $line 'console metadata'
    Assert-True ($line -notmatch 'hello') 'no payload in the sample'
    Assert-Equal 'Local\ClipboardDiagnosticsMvp.Tray' (Get-ClipboardMutexName -Kind Tray) 'tray mutex'
    Assert-Equal 'Local\ClipboardDiagnosticsMvp.Rewrite' (Get-ClipboardMutexName -Kind Rewrite) 'rewrite mutex'
    Assert-Equal 'Local\ClipboardDiagnosticsMvp.PlainTextSession' (Get-ClipboardMutexName -Kind PlainTextSession) 'session mutex'
    $relaunch = Get-StaRelaunchArguments -ScriptPath 'C:\Program Files\clipboard_diagnostics_mvp\clipboard-test.ps1' -Arguments @('-PlainText','-Seconds','600')
    Assert-True ($relaunch -match '-STA') 'sta flag'
    Assert-True ($relaunch -match '-File "C:\\Program Files\\clipboard_diagnostics_mvp\\clipboard-test.ps1"') 'script quoted'
    Assert-True ($relaunch -match '-PlainText -Seconds 600') 'args preserved'
}
Invoke-Test 'observation updates activity when paused and does not rewrite' {
    $script:ObsCalled = $false
    $paused = Invoke-PlainTextObservation -PreviousSequence 1 -CurrentSequence 2 -Paused $true -RewriteLockHeld $false -Rewrite { $script:ObsCalled = $true }
    Assert-Equal 'Skip' $paused.Outcome 'paused skip'
    Assert-Equal 'Paused' $paused.Reason 'paused reason'
    Assert-Equal 'True' $paused.Activity 'activity stamped'
    Assert-True (-not $script:ObsCalled) 'rewrite not called'
    $same = Invoke-PlainTextObservation -PreviousSequence 2 -CurrentSequence 2 -Paused $false -RewriteLockHeld $false -Rewrite { throw 'unchanged sequence' }
    Assert-True ($null -eq $same) 'unchanged sequence returns null'
    $busy = Invoke-PlainTextObservation -PreviousSequence 2 -CurrentSequence 3 -Paused $false -RewriteLockHeld $true -Rewrite { throw 'lock held' }
    Assert-Equal 'Dropped' $busy.Outcome 'mutex busy drops the cycle'
}
Invoke-Test 'clipboard-test.ps1 declares PlainText and keeps Seconds at 120' {
    $entry = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'clipboard-test.ps1'
    $text = [System.IO.File]::ReadAllText($entry)
    Assert-True ($text -match '\[int\]\$Seconds = 120') 'default 120'
    Assert-True ($text -match '\[switch\]\$PlainText') 'switch'
    Assert-True ($text -match "ToolVersion = '3.0.0'") 'tool version'
    Assert-True ($text -match 'clipboard-core\.ps1') 'dot-sources core'
    Assert-True ($text -match 'namespace ClipDiagV2') 'ClipDiagV2 stayed'
    Assert-True ($text -match '-ShowText is ignored for -PlainText\.') 'showtext sentence'
    Assert-True ($text -match 'Plain-text rewrite is paused\.') 'paused sentence'
    Assert-True ($text -match 'Tray already running; timed plain-text session not started\.') 'overlap sentence'
    Assert-True ($text -notmatch 'ShowBalloonTip') 'timed mode has no balloon'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'Test-ClipboardNeedsPlainText classifies trigger and protected sets'`

Expected: exit `1` and `FAIL  threw:` containing `Test-ClipboardNeedsPlainText`.

- [ ] **Step 3: Write minimal implementation**

Add the core functions listed above. `ConvertFrom-ClipboardHtmlBytes` follows the converter rules in this task's interface. `Invoke-ClipboardPlainTextRewrite` uses the injected scriptblocks when present. The default `-ReadSnapshot` and `-WriteUnicodeText` call private functions `Get-ClipboardPlainTextSnapshot` and `Set-ClipboardUnicodeOnly`, which `Add-Type` `System.Windows.Forms` on first use and compile namespace `ClipDiagCore` (not `ClipDiagV2`) for `GetClipboardSequenceNumber`, `GetClipboardOwner`, and `GetWindowThreadProcessId` only. `Set-ClipboardUnicodeOnly` builds a `DataObject`, calls `SetData` for `UnicodeText` only, then `SetDataObject($obj, $true, 10, 50)`, then reads Unicode text and the new sequence back. It does not set `HTML Format`. Open failure after 10×50 ms returns `Opened=$false`.

`Invoke-PlainTextObservation` returns `$null` when the sequence is unchanged. When paused, it returns Skip/`Paused` and `Activity=$true` without calling `-Rewrite`. When `-RewriteLockHeld`, it returns `Dropped` without calling `-Rewrite`. Otherwise it returns the rewrite result and `Activity=$true`.

In `clipboard-test.ps1`:

- Add `[switch]$PlainText` next to the other mode switches.
- Change the `.PARAMETER Seconds` help to: `Duration of -Watch and -PlainText (5..3600, default 120).`
- Set `$script:ToolVersion = '3.0.0'`.
- After `$script:ScriptRoot` is assigned, dot-source `Join-Path $script:ScriptRoot 'clipboard-core.ps1'`.
- Extend the safety header: `-PlainText` is foreground and time-bounded, rewrites matching copies in place, does not restore HTML, and does not record payloads.
- Build `$selectedModes` with `PlainText` included. Call `Get-ClipboardRunMode`. If `ExitCode` is 2, print `ERROR: Choose one mode at a time.` and `exit 2` before any clipboard write. Keep the existing " `-Fix` ignored for non-diagnose modes" warning for modes other than `PlainText`.
- Add a `switch` arm `'PlainText' { Invoke-PlainTextSession -Seconds $Seconds -ShowText $ShowText.IsPresent -WhatIf:$WhatIfPreference }`.
- Add a privacy sentence for mode `PlainText`: `Privacy: plain-text mode rewrites HTML and Chromium web formats to Unicode text and records character counts, format names, and process names only.`
- If the current apartment is not STA, re-launch with `Get-StaRelaunchArguments` and `exit` the MTA process before the session starts.

`Invoke-PlainTextSession` behavior:

1. `Publish-ClipboardStoreEvents` after reading settings and state. If `Get-ClipboardRuntimeGate` says `PausedEffective` because the user paused, print `Plain-text rewrite is paused.` and still wait out `-Seconds` without rewriting, then exit using `Get-PlainTextSessionExitCode` (0 unless a store ERROR was recorded).
2. If `-ShowText`, print `-ShowText is ignored for -PlainText.`
3. If the tray mutex `Get-ClipboardMutexName -Kind Tray` is already held, print `Tray already running; timed plain-text session not started.`, write event `1106` level `INFO` through `New-LoggingProvider`, release nothing that this process did not acquire, and return exit 0. Do not toast.
4. Hold `PlainTextSession` for the whole function (`finally` releases it).
5. Poll `GetClipboardSequenceNumber` at `plainText.pollIntervalMs` until `-Seconds` elapses, or until Ctrl+C / Esc. Each change calls `Invoke-PlainTextObservation`. Skip outcomes are not logged and not toasted. `PASS` prints `Format-PlainTextConsoleLine`, writes event `1000`, calls `Send('PASS', ...)`, increments the in-memory session counter and `rewriteCountTotal`, and sets `lastRewriteUtc`. `FAIL` prints a FAIL line, writes event `2000`, and `Send`s the Task 3 toast text. `ERROR` prints an ERROR line, writes event `3000`, and sends the ERROR toast. `WhatIf` prints `INFO -WhatIf would rewrite chars={CharCount} formats={FormatsBefore} source={SourceProcess}` and does not write the clipboard.
6. On the way out, write event `1001` when fail and error counts are 0, event `2001` when there is a FAIL and no ERROR, or event `3000` reason `SessionError` when any ERROR occurred. Do not toast the summary. Store events on `$script:Report.plainText` via `New-PlainTextReport` (the `seconds` field is the `-Seconds` value actually used, so an omitted switch records 120). `Write-JsonReport` already serializes `$script:Report` unless `-NoReport` or `-WhatIf`.
7. Map `HadError` / `Issues` so the existing exit block returns `Get-PlainTextSessionExitCode`.

The default WinForms path is manual-only. Unit tests never call it.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`. The AST harness still finds the diagnose helpers.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 clipboard-test.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add timed plain-text clipboard rewrite"
```

---

### Task 5: StartupProvider seam and Scheduled Task install

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: nothing from the tray yet
- Produces:
  - `Get-ScheduledTaskExecutable` → `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`
  - `Get-ScheduledTaskActionArgument -TrayScriptPath`
  - `Get-SchtasksCreateArguments -TrayScriptPath`
  - `Get-StartupProvider -TrayScriptPath -TaskBackend` → `Id='ScheduledTask'`, `Managed=$false`, `TaskPath='\ClipboardDiagnosticsMvp\'`, `TaskName='PlainTextTray'`, `Test`, `Install`, `Uninstall`, `GetStatus`
  - `GetStatus` returns `Installed`, `Managed`, `TaskPath`, `TaskName`, `LastTaskResult`, `ActionPath`
  - Description string: `Rewrites Chromium HTML clipboard copies to plain Unicode for local paste. Does not record clipboard text.`
  - The provider never returns `Id='Policy'`. No `ManagedByPolicy` implementation.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'scheduled task action quotes a path that contains a space' {
    $exe = Get-ScheduledTaskExecutable
    Assert-True ($exe -match 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$') 'windows powershell 5.1 host'
    $tray = 'C:\Program Files\clipboard_diagnostics_mvp\clipboard-tray.ps1'
    $arg = Get-ScheduledTaskActionArgument -TrayScriptPath $tray
    Assert-Equal '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Program Files\clipboard_diagnostics_mvp\clipboard-tray.ps1"' $arg 'argument'
    $create = Get-SchtasksCreateArguments -TrayScriptPath $tray
    Assert-True ($create -match '/Create /F /TN "\\ClipboardDiagnosticsMvp\\PlainTextTray"') 'task name'
    Assert-True ($create -match '/SC ONLOGON /IT /RL LIMITED') 'interactive limited logon'
    Assert-True ($create -match '/TR ".*powershell\.exe.*"') 'tr quotes the executable'
    Assert-True ($create -match 'Program Files') 'space path survives'
}
Invoke-Test 'Get-StartupProvider is only the scheduled task backend' {
    $calls = New-Object System.Collections.Generic.List[object]
    $provider = Get-StartupProvider -TrayScriptPath 'C:\Program Files\clipboard_diagnostics_mvp\clipboard-tray.ps1' -TaskBackend {
        param($Operation, $Spec) $script:StartupCalls.Add([pscustomobject]@{ Operation = $Operation; TaskName = $Spec.TaskName; TaskPath = $Spec.TaskPath; Description = $Spec.Description })
        if ($Operation -eq 'Query') { return [pscustomobject]@{ Installed = $true; LastTaskResult = 0; ActionPath = $Spec.ActionPath } }
        return [pscustomobject]@{ Ok = $true }
    }
    Assert-Equal 'ScheduledTask' $provider.Id 'id'
    Assert-Equal 'False' $provider.Managed 'not managed'
    Assert-Equal '\ClipboardDiagnosticsMvp\' $provider.TaskPath 'path'
    Assert-Equal 'PlainTextTray' $provider.TaskName 'name'
    $script:StartupCalls = $calls
    [void]$provider.Install.Invoke()
    [void]$provider.Uninstall.Invoke()
    $status = $provider.GetStatus.Invoke()
    Assert-Equal 'Install' $calls[0].Operation 'install'
    Assert-Equal 'PlainTextTray' $calls[0].TaskName 'install name'
    Assert-Equal '\ClipboardDiagnosticsMvp\' $calls[0].TaskPath 'install path'
    Assert-Equal 'Rewrites Chromium HTML clipboard copies to plain Unicode for local paste. Does not record clipboard text.' $calls[0].Description 'description'
    Assert-Equal 'Uninstall' $calls[1].Operation 'uninstall'
    Assert-Equal 'True' $status.Installed 'query'
    Assert-Equal 'False' $status.Managed 'status not managed'
    Assert-True ($provider.Id -ne 'Policy') 'no policy provider'
}
```

Initialize `$script:StartupCalls = $calls` before `Install` is invoked; the snippet above does that.

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'scheduled task action quotes a path that contains a space'`

Expected: exit `1` and `FAIL  threw:` containing `Get-ScheduledTaskExecutable`.

- [ ] **Step 3: Write minimal implementation**

`Get-ScheduledTaskExecutable` joins `$env:SystemRoot` with `System32\WindowsPowerShell\v1.0\powershell.exe`. `Get-ScheduledTaskActionArgument` returns the exact `-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "<path>"` string. `Get-SchtasksCreateArguments` returns one `schtasks.exe` argument string using `/Create /F /TN "\ClipboardDiagnosticsMvp\PlainTextTray" /SC ONLOGON /IT /RL LIMITED /TR "<quoted exe> <action>"`.

`Get-StartupProvider` always sets `Id` to `ScheduledTask` and `Managed` to `$false`. `Install`, `Uninstall`, `Test`, and `GetStatus` are script methods. When `-TaskBackend` is supplied, they call it with `Install`, `Uninstall`, or `Query` and a spec hashtable containing `TaskName`, `TaskPath`, `Description`, `Execute` (the 5.1 host), `Argument` (the action argument), `WorkingDirectory` (the tray script's directory), and `ActionPath` (execute plus argument). When `-TaskBackend` is omitted, try `Import-Module ScheduledTasks` and `Register-ScheduledTask` / `Unregister-ScheduledTask -Confirm:$false` / `Get-ScheduledTask`. The principal is the current user, `LogonType Interactive`, `RunLevel Limited`. Settings: allow start on batteries, do not stop on batteries, start when available, multiple instances `IgnoreNew`, execution limit `[TimeSpan]::Zero`. If the module import fails, call `schtasks.exe` with `Get-SchtasksCreateArguments`, `schtasks /Delete /F /TN "\ClipboardDiagnosticsMvp\PlainTextTray"`, and `schtasks /Query /TN "\ClipboardDiagnosticsMvp\PlainTextTray"`. Unit tests always pass `-TaskBackend` and do not register a real task.

Do not construct a Policy provider. Do not read policy values into the task spec.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add scheduled-task startup provider"
```

---

### Task 6: Tray icon, pause/resume, Health Status, Quit

**Files:**
- Create: `clipboard-tray.ps1`
- Modify: `clipboard-core.ps1` (health and tooltip helpers only)
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: Tasks 1–5 (`Read`/`Save` settings and state, logger, `Invoke-PlainTextObservation`, `Invoke-ClipboardPlainTextRewrite`, `Get-ClipboardMutexName`, `Get-StaRelaunchArguments`, `Test-ClipboardEventLogSource`, `Initialize-ClipboardEventLog`, `Get-ClipboardPolicySignal`, `Get-StartupProvider`)
- Produces:
  - `Get-ClipboardTrayTooltip -Paused` → `Clipboard diagnostics: Running` or `Clipboard diagnostics: Paused` (63 characters or fewer)
  - `Get-ClipboardHealthRows` → the label/value map below
  - `clipboard-tray.ps1` parameters `-InstallStartup`, `-UninstallStartup`, `-RegisterEventLog` (install/uninstall behavior is finished in Task 7; this task must accept the switches and, for `-RegisterEventLog` only, perform registration)
  - Menu labels: `Pause` or `Resume`, `Health Status…`, `Export Diagnostics…`, `Start with Windows`, `Quit`
  - Health form title `Clipboard diagnostics — Health`, buttons `Refresh` and `Close`
  - Mutex `Local\ClipboardDiagnosticsMvp.Tray`. Second process prints `Tray already running.` and exits `0`.

Health rows (`Get-ClipboardHealthRows`):

| Key | Value |
| --- | --- |
| Status | `Running` or `Paused` |
| Listener | `Clipboard listener` or `Polling every {n} ms` |
| Start with Windows | `Yes` or `No` |
| Task | `\ClipboardDiagnosticsMvp\PlainTextTray` |
| Task action | action path, or `not installed` |
| Session rewrites | session counter |
| Total rewrites | `rewriteCountTotal` |
| Last activity | local time, or `never` |
| Last rewrite | local time, or `never` |
| Last result | `lastOutcome lastReason`, or `none` |
| Last character count | number, or `n/a` |
| Last source process | process name, or `n/a` |
| Event Log | `registered` or `not registered` |
| Policy | `none` or `present (not applied)` |
| Log folder | `%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs` |
| Versions | tool version and `ClipboardCoreVersion` |

No row contains clipboard text. The form is read-only, fixed, and not resizable. Double-click opens it. There is no call to `ShowBalloonTip`.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'tooltip and health rows are metadata' {
    Assert-Equal 'Clipboard diagnostics: Running' (Get-ClipboardTrayTooltip -Paused $false) 'running tip'
    Assert-Equal 'Clipboard diagnostics: Paused' (Get-ClipboardTrayTooltip -Paused $true) 'paused tip'
    Assert-True ((Get-ClipboardTrayTooltip -Paused $false).Length -le 63) 'tip length'
    $rows = Get-ClipboardHealthRows -Paused $false -ListenerMode 'Listener' -PollIntervalMs 400 -StartWithWindows $true -TaskAction '' -SessionRewrites 2 -TotalRewrites 9 -LastActivityUtc $null -LastRewriteUtc $null -LastOutcome $null -LastReason $null -LastCharCount $null -LastOwnerName $null -EventLogReady $false -PolicyPresent $false -ToolVersion '3.0.0' -CoreVersion '1.0.0'
    Assert-Equal 'Running' $rows.Status 'status'
    Assert-Equal 'Clipboard listener' $rows.Listener 'listener'
    Assert-Equal 'Yes' $rows['Start with Windows'] 'startup'
    Assert-Equal '\ClipboardDiagnosticsMvp\PlainTextTray' $rows.Task 'task'
    Assert-Equal 'not installed' $rows['Task action'] 'missing action'
    Assert-Equal '2' $rows['Session rewrites'] 'session'
    Assert-Equal '9' $rows['Total rewrites'] 'total'
    Assert-Equal 'never' $rows['Last activity'] 'activity'
    Assert-Equal 'never' $rows['Last rewrite'] 'rewrite'
    Assert-Equal 'none' $rows['Last result'] 'result'
    Assert-Equal 'n/a' $rows['Last character count'] 'chars'
    Assert-Equal 'n/a' $rows['Last source process'] 'process'
    Assert-Equal 'not registered' $rows['Event Log'] 'event log'
    Assert-Equal 'none' $rows.Policy 'policy'
    Assert-True ($rows.Versions -match '3\.0\.0') 'tool version'
    Assert-True ($rows.Versions -match '1\.0\.0') 'core version'
    $poll = Get-ClipboardHealthRows -Paused $true -ListenerMode 'Poll' -PollIntervalMs 400 -StartWithWindows $false -TaskAction 'C:\tray.ps1' -SessionRewrites 0 -TotalRewrites 0 -LastActivityUtc ([datetime]'2026-11-05T12:00:00Z') -LastRewriteUtc $null -LastOutcome 'FAIL' -LastReason 'OpenFailed' -LastCharCount -1 -LastOwnerName 'msedge' -EventLogReady $true -PolicyPresent $true -ToolVersion '3.0.0' -CoreVersion '1.0.0'
    Assert-Equal 'Paused' $poll.Status 'paused'
    Assert-Equal 'Polling every 400 ms' $poll.Listener 'poll label'
    Assert-Equal 'No' $poll['Start with Windows'] 'off'
    Assert-Equal 'FAIL OpenFailed' $poll['Last result'] 'result pair'
    Assert-Equal '-1' $poll['Last character count'] 'count'
    Assert-Equal 'msedge' $poll['Last source process'] 'owner'
    Assert-Equal 'registered' $poll['Event Log'] 'registered'
    Assert-Equal 'present (not applied)' $poll.Policy 'policy present'
    Assert-True ((ConvertTo-Json $poll) -notmatch 'COPILOT-SECRET-PHRASE') 'no payload slot'
}
Invoke-Test 'tray script has no balloon and registers the event source switch' {
    $tray = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'clipboard-tray.ps1'
    $text = [System.IO.File]::ReadAllText($tray)
    Assert-True ($text -notmatch 'ShowBalloonTip') 'no balloon'
    Assert-True ($text -notmatch '\.ico') 'no icon file'
    Assert-True ($text -match 'Clipboard diagnostics — Health') 'health title'
    Assert-True ($text -match 'Tray already running\.') 'second instance line'
    Assert-True ($text -match 'RegisterEventLog') 'event log switch'
    Assert-True ($text -match 'Local\\ClipboardDiagnosticsMvp\.Tray') 'tray mutex'
    Assert-True ($text -match 'Quit') 'quit item'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'tooltip and health rows are metadata'`

Expected: exit `1` and `FAIL  threw:` containing `Get-ClipboardTrayTooltip`.

- [ ] **Step 3: Write minimal implementation**

Add `Get-ClipboardTrayTooltip` and `Get-ClipboardHealthRows` to the core. Local-time conversion uses `ToLocalTime()` when the input is UTC; `$null` timestamps render `never`. `Last result` is `none` when outcome is null, otherwise `"{Outcome} {Reason}"`. Character count `$null` renders `n/a`; a present integer, including `-1`, is printed as that integer.

Create `clipboard-tray.ps1`:

- Dot-source `clipboard-core.ps1` from the same directory. No work before the STA check.
- If the apartment is not STA, re-launch via `Get-StaRelaunchArguments` and exit.
- Parameters: `[switch]$InstallStartup`, `[switch]$UninstallStartup`, `[switch]$RegisterEventLog`. More than one switch prints `ERROR: Choose one tray switch at a time.` and exits `2`.
- `-RegisterEventLog` calls `Initialize-ClipboardEventLog`. `registered` prints `PASS Event Log source ClipboardDiagnosticsMvp is registered.` and exits `0`. `unavailable` prints `ERROR: Event Log registration needs an elevated Windows PowerShell. Re-run clipboard-tray.ps1 -RegisterEventLog from an elevated prompt.` and exits `2`.
- `-InstallStartup` and `-UninstallStartup` in this task only print `ERROR: startup toggle is not wired` and exit `2` if you have not yet done Task 7. Task 7 replaces those two arms. Do not start the icon when any switch is present.
- With no switch: try to create the mutex `Local\ClipboardDiagnosticsMvp.Tray` with zero timeout. If it is already held, print `Tray already running.` and exit `0`.
- Read settings and state with `-Root` omitted (the real LocalAppData root). Call `Publish-ClipboardStoreEvents`. If settings or state are `Unsupported`, keep running with `PausedEffective` and do not save.
- Log event `1100` on start.
- Build a 16×16 `System.Drawing.Bitmap` in memory (filled circle when running, dimmed when paused) and assign it to `NotifyIcon`. Tooltip from `Get-ClipboardTrayTooltip`. Context menu items use the labels above. `Export Diagnostics…` can show a dialog that says the export function arrives in Task 8; do not write a zip in this task.
- `Pause`/`Resume` flips `settings.paused`, calls `Save-ClipboardDiagnosticsSettings` when the version is supported, logs `1102` or `1103`, and updates the tooltip and icon. While paused, sequence changes still call `Invoke-PlainTextObservation -Paused $true`, which updates `lastActivityUtc` and `state.json`, and they do not call `SetDataObject`.
- While running, the message-only window (`HWND_MESSAGE`, parent `-3`) calls `AddClipboardFormatListener`. On `WM_CLIPBOARDUPDATE` (`0x031D`), run one observation/rewrite. If registration fails, use a WinForms timer at `pollIntervalMs` and set the health listener mode to `Poll`.
- Health form binds `Get-ClipboardHealthRows`. `Refresh` re-reads state, the startup `GetStatus` (Task 7 may still be a stub returning `Installed=$false`), and `Test-ClipboardEventLogSource`. `Close` hides the form. Double-click the icon shows the form.
- `Quit` waits up to 2000 ms while a rewrite flag is set, logs `1101`, disposes the icon, releases the mutex, and exits `0`. It does not remove the Scheduled Task or the Start Menu shortcut.
- A PASS rewrite uses the Task 4 counter updates and the Task 2/3 providers. No toast on PASS. No balloon on start, PASS, or Quit.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 clipboard-tray.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: add plain-text tray health and pause"
```

---

### Task 7: Start with Windows toggle

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `clipboard-tray.ps1` (replace the Task 6 stub arms and the menu check handler)
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: `Get-StartupProvider`, `Read-ClipboardDiagnosticsSettings`, `Save-ClipboardDiagnosticsSettings`
- Produces:
  - `Sync-StartWithWindowsSetting -SettingsResult -TaskInstalled` → `Changed`, and the settings object to save. `Changed` is `$false` when `Unsupported` is true.
  - `Invoke-StartupToggle -Provider -SettingsResult -Enable -Root` → `ExitCode`, `TaskResult` (`installed`, `removed`, or `error`), `Saved`
  - Tray menu item `Start with Windows` checked state matches `GetStatus.Installed`
  - `-InstallStartup` / `-UninstallStartup` call `Invoke-StartupToggle` and do not start the icon

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'startup sync and toggle honor an unsupported settings file' {
    $root = Join-Path $scratch 'startup'
    $ready = Read-ClipboardDiagnosticsSettings -Root $root
    $synced = Sync-StartWithWindowsSetting -SettingsResult $ready -TaskInstalled $true
    Assert-Equal 'True' $synced.Changed 'task installs the flag'
    Assert-Equal 'True' $synced.Settings.startWithWindows 'flag true'
    $same = Sync-StartWithWindowsSetting -SettingsResult (Read-ClipboardDiagnosticsSettings -Root $root) -TaskInstalled $false
    Assert-Equal 'False' $same.Changed 'unsaved disk copy is still false while the task is absent'
    $again = Sync-StartWithWindowsSetting -SettingsResult $ready -TaskInstalled $true
    Assert-Equal 'False' $again.Changed 'second sync of the mutated object is stable'
    $ver = Join-Path $scratch 'startup-ver'
    [void][System.IO.Directory]::CreateDirectory($ver)
    [System.IO.File]::WriteAllText((Join-Path $ver 'settings.json'), '{"version":2,"paused":false,"startWithWindows":false}')
    $before = [System.IO.File]::ReadAllText((Join-Path $ver 'settings.json'))
    $newer = Read-ClipboardDiagnosticsSettings -Root $ver
    $blocked = Sync-StartWithWindowsSetting -SettingsResult $newer -TaskInstalled $true
    Assert-Equal 'False' $blocked.Changed 'unsupported does not save'
    $calls = New-Object System.Collections.Generic.List[string]
    $provider = Get-StartupProvider -TrayScriptPath 'C:\Program Files\clipboard_diagnostics_mvp\clipboard-tray.ps1' -TaskBackend {
        param($Operation, $Spec) $script:ToggleOps.Add($Operation)
        return [pscustomobject]@{ Ok = $true; Installed = ($Operation -eq 'Install' -or $Operation -eq 'Query'); LastTaskResult = 0; ActionPath = $Spec.ActionPath }
    }
    $script:ToggleOps = $calls
    $done = Invoke-StartupToggle -Provider $provider -SettingsResult $newer -Enable $true -Root $ver
    Assert-Equal 2 $done.ExitCode 'unsupported settings exit 2'
    Assert-Equal 'installed' $done.TaskResult 'task still installed'
    Assert-Equal 'False' $done.Saved 'file not saved'
    Assert-Equal 'Install' $calls[0] 'backend install ran'
    Assert-Equal $before ([System.IO.File]::ReadAllText((Join-Path $ver 'settings.json'))) 'version 2 bytes kept'
    $ok = Invoke-StartupToggle -Provider $provider -SettingsResult $ready -Enable $false -Root $root
    Assert-Equal 0 $ok.ExitCode 'supported uninstall'
    Assert-Equal 'removed' $ok.TaskResult 'removed'
    Assert-Equal 'True' $ok.Saved 'saved'
    Assert-Equal 'False' (Read-ClipboardDiagnosticsSettings -Root $root).Settings.startWithWindows 'flag cleared'
}
Invoke-Test 'uninstall does not delete the toast shortcut' {
    $tray = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'clipboard-tray.ps1'
    $text = [System.IO.File]::ReadAllText($tray)
    Assert-True ($text -match 'InstallStartup') 'install switch'
    Assert-True ($text -match 'UninstallStartup') 'uninstall switch'
    Assert-True ($text -match 'Start with Windows') 'menu label'
    Assert-True ($text -notmatch 'ClipboardDiagnosticsMvp\.lnk') 'tray does not delete the shortcut'
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'startup sync and toggle honor an unsupported settings file'`

Expected: exit `1` and `FAIL  threw:` containing `Sync-StartWithWindowsSetting`.

- [ ] **Step 3: Write minimal implementation**

`Sync-StartWithWindowsSetting` compares `TaskInstalled` with `Settings.startWithWindows`. On a supported file it assigns the bool and returns `Changed` true only when the value flipped. On `Unsupported` it returns `Changed` false and does not assign.

`Invoke-StartupToggle` calls `provider.Install` or `provider.Uninstall`. `TaskResult` is `installed` or `removed` when the backend returns `Ok=$true`, otherwise `error`. When the backend fails, `ExitCode` is 2 and `Saved` is false. When the backend succeeds and settings are supported, save and log event `1104` (install) or `1105` (uninstall), `ExitCode` 0, `Saved` true. When the backend succeeds and settings are unsupported, do not save, `ExitCode` 2, `Saved` false, `TaskResult` still `installed` or `removed`.

On tray startup, call `Sync-StartWithWindowsSetting` with `GetStatus.Installed` and save only when `Changed` is true. Do not recreate a missing task during that sync. The menu item is checked when `Installed` is true. Clicking it calls `Invoke-StartupToggle` and then refreshes the check. `-InstallStartup` and `-UninstallStartup` call `Invoke-StartupToggle` and exit with its `ExitCode`. They print one line: `installed`, `removed`, or `error`, and when `ExitCode` is 2 because of an unsupported file they also print `ERROR SettingsVersionUnsupported`. They do not acquire the tray mutex and do not delete logs or the toast shortcut.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 clipboard-tray.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: wire tray startup toggle to the scheduled task"
```

---

### Task 8: Export Diagnostics

**Files:**
- Modify: `clipboard-core.ps1`
- Modify: `clipboard-tray.ps1` (replace the Task 6 export stub)
- Modify: `tests/Run-CoreTests.ps1`
- Test: `tests/Run-CoreTests.ps1`

**Interfaces:**
- Consumes: `Get-ClipboardHealthRows`, settings, state, logger `Ring`
- Produces:
  - `Get-ClipboardExportFileName -Now` → `clipboard-diagnostics-export-yyyyMMdd-HHmmss.zip`
  - `Export-ClipboardDiagnosticsBundle -DestinationPath -Root -Status -Ring -MaxLogBytes -StagingParent`
  - Zip entries: `README.txt`, `status.json`, `settings.json`, `state.json`, `recent-memory.json`, and `logs/operational.log` plus rotated files capped at 512 KB combined
  - Tray save dialog default directory: `[Environment]::GetFolderPath('MyDocuments')`. Default file name from `Get-ClipboardExportFileName`. The zip is written only after the user confirms; unit tests call the core function directly.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'export zip has metadata only and caps logs' {
    Assert-Equal 'clipboard-diagnostics-export-20261105-120000.zip' (Get-ClipboardExportFileName -Now ([datetime]'2026-11-05T12:00:00')) 'file name'
    $root = Join-Path $scratch 'export'
    $settings = Read-ClipboardDiagnosticsSettings -Root $root
    $state = Read-ClipboardDiagnosticsState -Root $root
    $logDir = Join-Path $root 'logs'
    [void][System.IO.Directory]::CreateDirectory($logDir)
    $secret = 'COPILOT-SECRET-PHRASE'
    [System.IO.File]::WriteAllText((Join-Path $logDir 'operational.log'), ('x' * 40))
    [System.IO.File]::WriteAllText((Join-Path $logDir 'operational-20261105T000000000Z.log'), ('y' * 40))
    [System.IO.File]::WriteAllText((Join-Path $root 'reports-should-not-copy.txt'), $secret)
    $status = [pscustomobject]@{
        status = 'Running'; listener = 'Clipboard listener'; startWithWindows = 'No'
        task = '\ClipboardDiagnosticsMvp\PlainTextTray'; taskAction = 'not installed'
        sessionRewrites = 0; totalRewrites = 0; lastActivity = 'never'; lastRewrite = 'never'
        lastResult = 'none'; lastCharCount = 'n/a'; lastSourceProcess = 'n/a'
        eventLog = 'not registered'; policy = 'none'
        logFolder = (Join-Path $root 'logs'); toolVersion = '3.0.0'; coreVersion = '1.0.0'
        exportedAtUtc = '2026-11-05T12:00:00.0000000Z'; psVersion = '5.1'; osCaption = 'Microsoft Windows 11 Pro'
        policyPresent = $false; policyApplied = $false; eventLogStatus = 'not registered'
    }
    $dest = Join-Path $scratch 'out.zip'
    Export-ClipboardDiagnosticsBundle -DestinationPath $dest -Root $root -Status $status -Ring @(@{ Level = 'PASS'; EventId = 1000; Reason = 'Rewritten'; CharCount = 3 }) -MaxLogBytes 32 -StagingParent (Join-Path $scratch 'stage')
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($dest)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        foreach ($required in @('README.txt','status.json','settings.json','state.json','recent-memory.json')) {
            Assert-True ($names -contains $required) "entry $required"
        }
        Assert-True ($names -notcontains 'reports-should-not-copy.txt') 'repo reports are not bundled'
        $readme = (New-Object System.IO.StreamReader($zip.GetEntry('README.txt').Open())).ReadToEnd()
        Assert-True ($readme -match 'no clipboard text') 'readme privacy line'
        Assert-True ($readme -match 'ClipboardDiagnosticsMvp\\PlainTextTray') 'task name in readme'
        $statusJson = (New-Object System.IO.StreamReader($zip.GetEntry('status.json').Open())).ReadToEnd()
        Assert-True ($statusJson -match '"policyApplied": false' -or $statusJson -match '"policyApplied":false') 'policy not applied'
        Assert-True ($statusJson -notmatch 'ComputerName') 'no computer name field'
        Assert-True ($statusJson -notmatch [regex]::Escape($secret)) 'secret absent from status'
        $logBytes = 0
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -like 'logs/*') { $logBytes += $entry.Length }
        }
        Assert-True ($logBytes -le 32) 'log cap'
    }
    finally { $zip.Dispose() }
    Assert-True (-not (Test-Path (Join-Path $scratch 'stage'))) 'staging parent empty of leftovers is acceptable'
    $threw = $false
    try {
        Export-ClipboardDiagnosticsBundle -DestinationPath (Join-Path $scratch 'bad.zip') -Root $root -Status $status -Ring @(@{ Text = $secret; Level = 'PASS' }) -MaxLogBytes 32 -StagingParent (Join-Path $scratch 'stage2')
    } catch { $threw = $true }
    Assert-True $threw 'forbidden Text field rejected'
    Assert-True (-not (Test-Path (Join-Path $scratch 'bad.zip'))) 'no zip after rejection'
}
```

The staging assertion is: the guid directory created under `-StagingParent` does not exist after the call. Assert that with `@(Get-ChildItem -LiteralPath (Join-Path $scratch 'stage') -ErrorAction SilentlyContinue).Count -eq 0`.

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'export zip has metadata only and caps logs'`

Expected: exit `1` and `FAIL  threw:` containing `Get-ClipboardExportFileName`.

- [ ] **Step 3: Write minimal implementation**

`Get-ClipboardExportFileName` formats `clipboard-diagnostics-export-yyyyMMdd-HHmmss.zip` from the local time of `-Now`.

`Export-ClipboardDiagnosticsBundle` rejects a ring record or a status property named `Text`, `Preview`, `Html`, `Payload`, `SourceUrl`, or `WindowTitle` before it creates the zip, and throws `Export record contains forbidden field: <name>`. It stages under `-StagingParent` (default `%LOCALAPPDATA%\clipboard_diagnostics_mvp\tmp`) in a new guid directory and deletes that directory in `finally`. `README.txt` states that the bundle has no clipboard text, HTML, or source URLs, and lists the task `\ClipboardDiagnosticsMvp\PlainTextTray`, the shortcut `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClipboardDiagnosticsMvp.lnk`, and the AppUserModelID `ClipboardDiagnosticsMvp.PlainText`. `status.json` is `-Status` serialized. `settings.json` and `state.json` are copied from `-Root`. `recent-memory.json` is the ring, capped at 20 items. Log files are ordered newest first; whole files are added until `-MaxLogBytes` (default `524288`) is exhausted, and the last included file is the newest tail that fits. Do not copy `.\reports\`, PowerToys settings, or Cursor settings. Do not add `ComputerName` or `UserName`.

The tray menu handler opens `System.Windows.Forms.SaveFileDialog` with that file name and `MyDocuments`, and on OK calls `Export-ClipboardDiagnosticsBundle` with the live health status object (the same fields as the test's `$status`), the logger ring, and the real root. Build `osCaption` from `Win32_OperatingSystem.Caption` only.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add clipboard-core.ps1 clipboard-tray.ps1 tests/Run-CoreTests.ps1
git commit -m "feat: export diagnostics without clipboard payloads"
```

---

### Task 9: README and the 600-second example

**Files:**
- Modify: `README.md`
- Test: `tests/Run-CoreTests.ps1` (one source assertion)

**Interfaces:**
- Consumes: the shipped switches from Tasks 4–8
- Produces: a README that documents the working commands. The Design / Roadmap link to `docs/superpowers/specs/2026-11-05-plaintext-tray-design.md` stays. Add a link to this plan only as the historical implementation plan; do not describe the features as unimplemented after this task.

- [ ] **Step 1: Write the failing test**

```powershell
Invoke-Test 'README documents the 600 second plain-text example' {
    $readme = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'README.md'
    $text = [System.IO.File]::ReadAllText($readme)
    Assert-True ($text -match 'clipboard-test\.ps1 -PlainText -Seconds 600') '600 second example'
    Assert-True ($text -match 'default 120') 'default still documented'
    Assert-True ($text -match 'clipboard-tray\.ps1') 'tray usage'
    Assert-True ($text -match '-RegisterEventLog') 'elevation note'
    Assert-True ($text -match 'clipboard-core\.ps1') 'architecture lists the core'
    Assert-True ($text -match '2026-11-05-plaintext-tray-design\.md') 'design link remains'
    Assert-True ($text -match 'not a Cursor patch') 'safety wording remains'
    Assert-True ($text -match 'does not prove malware') 'malware wording remains'
}
```

Keep the existing sentence `This repository is **not** a Cursor patch, installer, SaaS product, malware scanner, or cloud service.` The new usage text must contain the literal substring `default 120` so the assertion above matches.

- [ ] **Step 2: Run test to verify it fails**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1 -TestName 'README documents the 600 second plain-text example'`

Expected: exit `1` and a FAIL whose message contains `600 second example` (the command is not in the README yet).

- [ ] **Step 3: Write minimal implementation**

Update `README.md`:

- Architecture tree includes `clipboard-core.ps1`, `clipboard-test.ps1`, and `clipboard-tray.ps1`.
- Usage section adds:

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText -Seconds 600
```

  State that omitting `-Seconds` uses default 120, and that 600 is the 10-minute session shown in the docs. The words `default 120` must appear verbatim.
- Tray section: start with `powershell -ExecutionPolicy Bypass -File .\clipboard-tray.ps1`. Document Pause / Resume (persisted under `%LOCALAPPDATA%\clipboard_diagnostics_mvp\settings.json`), Health Status, Export Diagnostics, Start with Windows, and Quit. Document `-InstallStartup`, `-UninstallStartup`, and `-RegisterEventLog`. Say that `-RegisterEventLog` must be re-run from an elevated Windows PowerShell when it prints the access-denied error, and that rewrite still works without the Event Log source.
- Say PASS does not toast. FAIL and ERROR toast. Logs and the Event Log do not contain clipboard text.
- Engineering Notes: replace the "background persistence is not implemented" claim with the tray as the supported persistence. Keep the rejection of global hooks, network telemetry, and patching Cursor.
- Keep the Design link. Local data reset is: Quit, `-UninstallStartup`, delete `%LOCALAPPDATA%\clipboard_diagnostics_mvp`, and delete the Start Menu shortcut `ClipboardDiagnosticsMvp.lnk` if toasts should stop.

- [ ] **Step 4: Run test to verify it passes**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

- [ ] **Step 5: Commit**

```bash
git add README.md tests/Run-CoreTests.ps1
git commit -m "docs: document timed plain-text mode and the tray"
```

---

### Task 10: Soak notes and the MVP readiness checklist

**Files:**
- Create: `docs/superpowers/plans/2026-11-05-plaintext-tray-soak.md` only after the automated tests pass. Record each manual check as `PASS`, `FAIL`, or `NOT RUN` with one sentence. Do not mark Production Tested unless every item is `PASS` on Windows 10 and Windows 11 with Windows PowerShell 5.1.
- Do not add signing, an Intune package, ADMX, or a Policy startup provider.

**Interfaces:**
- Consumes: the binaries from Tasks 1–9
- Produces: a soak record. Automated tests are the gate before any manual check.

- [ ] **Step 1: Write the failing test**

There is no new unit test. The gate is the existing harnesses.

- [ ] **Step 2: Run the automated tests**

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-CoreTests.ps1`

Expected: exit `0`.

Run: `powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1`

Expected: exit `0`.

If either exits non-zero, stop. Do not start the manual list.

- [ ] **Step 3: Run the manual checks on an interactive Windows desktop**

Record each line in `docs/superpowers/plans/2026-11-05-plaintext-tray-soak.md`.

1. With the tray running, copy an Edge Copilot answer. Ctrl+V into Cursor Agent inserts the text. Notepad inserts the same text.
2. Quit the tray. Run `powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText -Seconds 600`. Copy from Copilot again. Cursor Agent receives the text. The report's `seconds` value is 600. Exit code `0` when nothing failed.
3. Run `powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText` with `-Seconds` omitted. The banner and the report show 120.
4. Win+Shift+S while the tray is running leaves a bitmap or PNG on the clipboard, and `-ExportForCursor` still writes a PNG.
5. Copy a file in Explorer. `FileDrop` remains and the path still pastes.
6. Copy Notepad text. `rewriteCountTotal` does not increase.
7. Pause, copy from Copilot, confirm the rich formats remain. Resume, copy again, confirm a rewrite. Reboot with Pause set and the task installed: Health says `Paused` and a Copilot copy is not rewritten until Resume.
8. Start with Windows off, reboot: no tray process and the task is absent. Turn it on, reboot: the tray process and `\ClipboardDiagnosticsMvp\PlainTextTray` exist.
9. Export a zip after a Copilot copy that contains a unique phrase. That phrase is absent from the zip. The zip contains `status.json`, `settings.json`, `state.json`, `recent-memory.json`, and `README.txt`.
10. A PASS shows no toast. Hold the clipboard open from another STA process: one FAIL toast, one event `2000` or the matching file-log line, and the clipboard is unchanged.
11. With no Event Log source, the file log still receives the PASS line and Health says `not registered`. After an elevated `-RegisterEventLog`, the next PASS is in the Application log under source `ClipboardDiagnosticsMvp` and the message has no copied sentence.
12. Launch the tray twice. One icon. The second process exits `0` and prints `Tray already running.`
13. While the tray runs, start `-PlainText -Seconds 30`. WARN text is the overlap sentence, exit code is `0`, and `rewriteCountTotal` increments once for one copy.
14. Ctrl+C during a clean timed session writes the report and exits `0`. A session that hit `NoExtractableText` exits `1`.
15. `powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText -Watch` exits `2` and does not change the clipboard.
16. `-PlainText -WhatIf` prints a would-rewrite line and leaves `HTML Format` in place.
17. `-ShowText -PlainText` prints `-ShowText is ignored for -PlainText.` and the report has no `preview` property.

- [ ] **Step 4: Write the readiness lines in the soak file**

```text
MVP implemented: yes/no (yes only when Tasks 1-9 are committed and both harnesses exit 0)
Production Tested: no (unless all 17 items are PASS on Windows 10 and Windows 11, PowerShell 5.1)
Production Validated: no (no Authenticode signature, no operator runbook beyond the README reset steps, no separate privacy review of a real export)
Enterprise Ready: no (no AppLocker signing story, no GPO/Intune enforcement, no ADMX/CSP, no multi-session soak, no managed updates)
```

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/plans/2026-11-05-plaintext-tray-soak.md
git commit -m "docs: record plain-text tray soak results"
```

Skip the commit when every manual item is `NOT RUN` and the file would only repeat this plan. The automated harnesses are still required to exit `0` before the work is called implemented.

---

## Spec coverage self-review

| Locked requirement | Task |
| --- | --- |
| `clipboard-core.ps1` dot-sourced, version `1.0.0`, no param block, no side effects on import | 1 |
| Settings schema, `%LOCALAPPDATA%\clipboard_diagnostics_mvp\`, atomic save, unknown properties | 1 |
| Corrupt settings/state renamed; version greater than 1 not rewritten; run paused | 1, logged in 2 |
| `pollIntervalMs` clamp 200..5000, default 400, event `1107` | 1 (clamp flag), 2 (event) |
| `state.json` counters independent of Pause | 1, updated on PASS in 4 and 6 |
| `Get-ClipboardPolicySignal` / `Resolve-ClipboardPolicySignal`, HKLM wins, values not copied, `Applied` false | 1, displayed in 6, excluded from export values in 8 |
| `Format-OperationalMessage` allow list, no clipboard text, no process path | 2 |
| File log, 1 MB rotation, 5 files, ring of 20 even when sinks are off | 2 |
| Application log source `ClipboardDiagnosticsMvp`, best-effort, `-RegisterEventLog` | 2 (API), 6 (tray switch) |
| Event ids `1000`–`1107`, `2000`, `2001`, `3000`–`3002` | 2 (writer), 3 (`3002`), 4 (session ids), 6 (`1100`–`1103`), 7 (`1104`–`1105`) |
| Toast FAIL/ERROR only, silent PASS, no `-ToastOnPass`, no balloon | 3, 6 |
| Toast copy, `ReadBackMismatch` body, XML escape, AppUserModelID `ClipboardDiagnosticsMvp.PlainText` | 3 |
| `ToastUnavailable` logged once, rewrite result kept | 3 |
| `notifications.toastOnFail` false forces silent FAIL/ERROR | 3 |
| `Test-ClipboardNeedsPlainText` triggers, protected formats, evaluation order, RTF and Chromium source URL | 4 |
| `ConvertFrom-ClipboardHtmlBytes` and Unicode-first `Select-ClipboardPlainText` | 4 |
| `Invoke-ClipboardPlainTextRewrite`, 10×50 ms, one retry, no HTML restore, loop suppression | 4 |
| No process allow list; `sourceProcess` is metadata | 4 |
| Timed `-PlainText`, `-Seconds` default 120, range unchanged, mutual exclusion including `-Fix`, exit 0/1/2 | 4 |
| `-WhatIf`, `-ShowText` ignore sentence, paused sentence, report JSON without `preview` | 4 |
| Tray overlap event `1106`, exit 0, exact WARN sentence | 4 |
| `ClipDiagV2` stays in `clipboard-test.ps1`; core native namespace is `ClipDiagCore` | 4 |
| Tool version `3.0.0` | 4 |
| STA re-launch and Windows PowerShell 5.1 task host | 4 (helper), 5 (task exe), 6 (tray) |
| Scheduled Task `\ClipboardDiagnosticsMvp\PlainTextTray`, `/IT`, limited, batteries allowed, schtasks fallback | 5 |
| Startup provider id `ScheduledTask` only; Policy provider not implemented | 5 |
| Tray mutex, second instance exit 0, Pause/Resume persisted, Health labels, Quit waits 2 s and leaves the task | 6 |
| In-memory icon, no `.ico`, no `ShowBalloonTip` | 6 |
| Listener with poll fallback, paused observations still stamp `lastActivityUtc` | 4 (observation), 6 (window) |
| Start with Windows checkbox, `-InstallStartup` / `-UninstallStartup`, unsupported file exit 2 after the task change | 7 |
| Uninstall does not delete the toast shortcut or logs | 7 |
| Export entries, 512 KB log cap, no payloads, no computer name, Documents default name | 8 |
| README example `-PlainText -Seconds 600`, tray, elevation, architecture, safety wording, design link | 9 |
| `tests/Run-Tests.ps1` unchanged and still passing | 1–10 |
| `tests/Run-CoreTests.ps1` does not touch the real clipboard or WinForms | 1–9 |
| Soak list and readiness: MVP only; Production Tested / Validated / Enterprise Ready stay no until their gates are met | 10 |
| Cannot patch Cursor; image and file-drop clipboards are not rewritten | Global constraints, 4, 9 |
