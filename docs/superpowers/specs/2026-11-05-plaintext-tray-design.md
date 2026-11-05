# Plain-text tray design (Edge Copilot → Cursor Agent)

Status: **locked**. This document is the design for the next implementation. It does not change runtime behavior by itself.

Date: 2026-11-05

Baseline: `clipboard-test.ps1` version `2.1.0` (single-script MVP). That script has no `-PlainText` switch, no tray, and no background persistence. `-Seconds` already exists for `-Watch`, range `5..3600`, default **120**. Keep that default.

## Summary

Edge Copilot (Chromium inside `msedge`) places HTML and Chromium web-custom formats on the Windows clipboard alongside Unicode text. Cursor Agent’s paste path prefers those rich formats and then inserts nothing. Notepad, which reads `CF_UNICODETEXT` only, pastes the same copy successfully. This repository cannot patch Cursor.

The fix is local and user-scoped: when a clipboard snapshot contains those rich text formats and a non-empty plain-text extraction, replace the clipboard with Unicode text only. Cursor then has nothing to prefer over plain text, so Ctrl+V inserts the copy.

Chosen approach: **B+C hybrid**.

- `clipboard-core.ps1` holds rewrite, detection, settings, logging, notifications, Event Log helpers, startup, and export packaging. No UI.
- `clipboard-test.ps1` keeps today’s diagnostics and adds a foreground, time-bounded `-PlainText` mode that calls the core.
- `clipboard-tray.ps1` is an always-on NotifyIcon helper that calls the same core.
- Auto-start is a current-user Scheduled Task at logon, created by `-InstallStartup` / `-UninstallStartup` and by a tray menu toggle.
- A `StartupProvider` seam is the only extension point for a future GPO/Intune replacement. The MVP ships the Scheduled Task provider only.

Success for a copy means the clipboard’s trigger formats are gone and the Unicode character count matches what was written. The text itself is never written to the console, a toast, the Event Log, Health, Export, or the JSON report.

## Goals

- Rewrite Copilot/Chromium HTML clipboard copies to plain Unicode so Cursor Agent can Ctrl+V the text.
- Offer both an always-on tray and a timed foreground session. Timed mode is the same rewrite, not a second algorithm.
- Keep `-Seconds` default at **120**. Document timed plain-text sessions with **600** (10 minutes).
- On PASS, stay quiet for the user (no toast). On FAIL and ERROR, show a toast. Record PASS, FAIL, and ERROR in the operational file log and, when available, the Windows Application Event Log.
- Persist Pause across reboot. Persist a rewrite counter and last-activity timestamps for Health and Export.
- Export a diagnostics zip of status, settings, counters, and recent logs with no clipboard payloads.
- Stay dependency-free: Windows PowerShell 5.1, WinForms, WinRT toast, inbox Scheduled Task, inbox Event Log, inbox `System.IO.Compression`. No NuGet, no BurntToast, no network.

## Non-goals

- This change does not patch, wrap, or configure Cursor. Image paste into Cursor Agent stays the existing `-ExportForCursor` workaround.
- No code signing, MSI/Intune package, AppLocker policy, ADMX/CSP, or managed updater.
- No GPO/Intune enforcement. The policy key below is observed and recorded, not applied.
- No rewrite of image, metafile, or file-drop clipboards.
- No Windows service and no session-0 host. The interactive user session owns the clipboard and the tray icon.
- No cloud account, telemetry endpoint, or clipboard sync.
- `-ShowText` does not extend to plain-text mode.
- The default for `-Seconds` does not change, including for `-Watch`.

## Current baseline

| Item | Today |
| --- | --- |
| Entrypoint | `clipboard-test.ps1` only |
| Timed switch | `-Watch -Seconds` (default 120, range 5..3600) |
| Plain-text rewrite | Not implemented |
| Persistence | None. Header states no background persistence |
| Reports | `.\reports\report-<stamp>.json` unless `-NoReport` |
| Exit codes | `0` no remaining issues, `1` remaining issues, `2` hard error or invalid mode combination |
| Privacy | Payloads are not printed or saved unless `-ShowText` |
| Tests | `tests/Run-Tests.ps1` loads selected functions from the script AST and never touches the clipboard |
| Native helper | In-script `ClipDiagV2` for diagnose and watch |

`-PlainText` is a new mutually exclusive mode. It does not replace `-Watch`. Diagnose, `-Fix`, browser tests, and `-ExportForCursor` stay as they are.

## Architecture

```
clipboard-test.ps1  --dot-source-->  clipboard-core.ps1
clipboard-tray.ps1  --dot-source-->  clipboard-core.ps1
                                           |
                                           +--> %LOCALAPPDATA%\clipboard_diagnostics_mvp\
                                           |       settings.json
                                           |       state.json
                                           |       logs\operational.log
                                           |
                                           +--> Application Event Log source
                                           |    ClipboardDiagnosticsMvp (best effort)
                                           |
                                           +--> Toast, FAIL/ERROR only
                                           |
                                           +--> Scheduled Task
                                                \ClipboardDiagnosticsMvp\PlainTextTray
```

Dot-sourcing the core must not touch the clipboard, the Event Log, the network, or the task scheduler. The core file has no `param` block and no top-level statements other than function definitions and:

```powershell
$script:ClipboardCoreVersion = '1.0.0'
```

`Add-Type` runs inside functions on first use, not at dot-source time. The tray and the timed mode both call `Invoke-ClipboardPlainTextRewrite`. They do not each implement format rules.

`ClipDiagV2` stays inside `clipboard-test.ps1` for diagnose and `-Watch`. The plain-text path does not depend on it. Do not compile two types with the same name. Core native helpers, if any, use a new namespace `ClipDiagCore` and only what rewrite needs (`GetClipboardSequenceNumber`, clipboard open/read/write). Prefer the WinForms clipboard API already used by `Save-ClipboardState` for the rewrite itself.

### Process model

- The tray is a single interactive process. Mutex: `Local\ClipboardDiagnosticsMvp.Tray` (session-local, so one tray per Windows session).
- A second tray launch exits `0` and does not open another icon. If a console is attached, it prints one line: `Tray already running.`
- Rewrite work also takes `Local\ClipboardDiagnosticsMvp.Rewrite` for the duration of one rewrite so a timed session and the tray cannot interleave `SetDataObject`.
- Timed `-PlainText` holds `Local\ClipboardDiagnosticsMvp.PlainTextSession` for the whole session.
- If `-PlainText` starts while the tray mutex is held: do not rewrite. Print one console WARN: `Tray already running; timed plain-text session not started.` Write Event Log / file INFO `1106`. Exit `0`. No toast. The end state the user asked for (a live rewriter) is already true.
- If the tray starts while a timed session holds `PlainTextSession`, the tray still starts. Both sides take `Rewrite` only around one write, so the second observer sees `AlreadyPlain`. No toast and no extra event.
- The tray message loop is a WinForms `ApplicationContext` plus `NotifyIcon`. A message-only window (`HWND_MESSAGE`) calls `AddClipboardFormatListener`. If that registration fails, a WinForms timer polls every `plainText.pollIntervalMs` (default 400).
- Timed `-PlainText` uses the same listener-or-poll choice for at most `-Seconds`, then prints a summary and exits. It does not show an icon.

Apartment: WinForms clipboard calls require STA. The scheduled task launches Windows PowerShell 5.1, which is STA by default, and still passes `-STA`. If either entrypoint finds MTA, it re-launches itself with the same engine and `-STA`, then exits the MTA process. Supported host for the tray task is:

`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`

PowerShell 7 is supported only when the process is STA (the re-launch path). The task does not point at `pwsh.exe`.

## Components

### `clipboard-core.ps1`

Shared, no UI. Responsibilities:

| Area | Functions |
| --- | --- |
| Paths | `Get-ClipboardDiagnosticsRoot` returns `%LOCALAPPDATA%\clipboard_diagnostics_mvp` |
| Settings | `Get-ClipboardDiagnosticsDefaults`, `Read-ClipboardDiagnosticsSettings`, `Save-ClipboardDiagnosticsSettings`. Read and save take optional `-Root` (default `Get-ClipboardDiagnosticsRoot`) so tests can use a temp directory |
| State | `Read-ClipboardDiagnosticsState`, `Save-ClipboardDiagnosticsState`, same optional `-Root` |
| Policy seam | `Get-ClipboardPolicySignal` (observe only) |
| Detection | `Test-ClipboardNeedsPlainText` |
| HTML | `ConvertFrom-ClipboardHtmlBytes` |
| Rewrite | `Invoke-ClipboardPlainTextRewrite` |
| Notifications | `New-NotificationProvider` |
| Logging | `Format-OperationalMessage`, `New-LoggingProvider` |
| Event Log | `Initialize-ClipboardEventLog`, `Test-ClipboardEventLogSource` |
| Startup | `Get-StartupProvider` |
| Export | `Export-ClipboardDiagnosticsBundle` |

`Invoke-ClipboardPlainTextRewrite` returns metadata only. The returned object must not contain properties named `Text`, `Preview`, `Html`, `Payload`, `SourceUrl`, or `WindowTitle`. Callers discard the in-memory string after `SetDataObject` and the length check. The string is not stored on `$script:` scope.

### `clipboard-test.ps1`

Keeps every current mode and exit-code rule. Adds `-PlainText`:

- Mutually exclusive with `-Fix`, `-Watch`, `-TerminalPaste`, `-BrowserTest`, `-BrowserPasteTest`, and `-ExportForCursor`. A combination exits `2` before any clipboard write, same as other invalid combinations.
- Uses existing `-Seconds` (default **120**, range **5..3600**) and existing `-NoReport` / `-WhatIf`.
- Does not run diagnose round-trips, so it does not save and restore the previous clipboard. The rewrite is the intended side effect: rich formats are removed so the next Ctrl+V is plain text.
- `-WhatIf` reports the decision (reason, format names, character count, source process) and does not call `SetDataObject`.
- `-ShowText` is ignored in this mode. Print one INFO line: `-ShowText is ignored for -PlainText.` No preview field is added to the report.
- If `settings.paused` is true at start, print one INFO line: `Plain-text rewrite is paused.` Do not rewrite. Exit `0` when the timer ends unless an ERROR occurred while reading settings. The tray Resume action (or setting `paused` to false) is how the user turns rewriting back on.
- PASS lines go to the console only as user-facing output. Toasts are not shown for PASS. FAIL and ERROR also go to the console, a toast, the file log, and the Event Log.
- On duration end, Ctrl+C, or Esc: stop the listener, write the summary, write the JSON report unless `-NoReport` or `-WhatIf`, exit with the codes below.
- Idle session (zero copies) is exit `0`.

Help text for `-Seconds` must say it applies to `-Watch` and `-PlainText`, default 120.

Timed session exit codes:

| Code | When |
| --- | --- |
| `0` | No FAIL and no ERROR (including zero rewrites) |
| `1` | One or more FAIL, no ERROR |
| `2` | One or more ERROR, or an invalid mode combination |

JSON report (existing report writer, metadata only):

```json
{
  "mode": "PlainText",
  "seconds": 600,
  "rewriteCount": 3,
  "failCount": 0,
  "errorCount": 0,
  "events": [
    {
      "time": "2026-11-05T12:00:00.0000000Z",
      "outcome": "PASS",
      "reason": "Rewritten",
      "charCount": 842,
      "formatsBefore": ["HTML Format", "CF_UNICODETEXT", "Chromium Web Custom MIME Data Format"],
      "formatsAfter": ["CF_UNICODETEXT", "CF_TEXT", "CF_OEMTEXT", "CF_LOCALE"],
      "sourceProcess": "msedge",
      "sequenceBefore": 100,
      "sequenceAfter": 101
    }
  ]
}
```

`seconds` in the report is the value used for that run (120 when the user omits the switch).

README example to add in the implementation change (do not add it before `-PlainText` exists):

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText -Seconds 600
```

That example is the documented 10-minute session. The parameter default stays 120 so a short run remains the default for `-Watch` and for `-PlainText`.

### `clipboard-tray.ps1`

Always-on tray app. Parameters, mutually exclusive, and none of them starts the icon:

| Switch | Behavior |
| --- | --- |
| `-InstallStartup` | Register the Scheduled Task, set `startWithWindows` to true when the settings file may be written, exit `0` (or `2` on failure) |
| `-UninstallStartup` | Remove the Scheduled Task, set `startWithWindows` to false when the settings file may be written, exit `0` (or `2` on failure) |
| `-RegisterEventLog` | Create the Application source. Exit `0` if created or already present. Exit `2` with a console ERROR if access is denied, telling the user to re-run that switch in an elevated Windows PowerShell |

No switch: acquire the tray mutex, sync the startup checkbox from the task, honor `settings.paused`, run the message loop until Quit.

Context menu:

| Item | Action |
| --- | --- |
| Pause or Resume | Flips `settings.paused` and saves immediately. The label shows the action available now (Pause while running, Resume while paused) |
| Health Status… | Opens the Health form |
| Export Diagnostics… | Save-file dialog, then `Export-ClipboardDiagnosticsBundle` |
| Start with Windows | Checked state mirrors the Scheduled Task. Toggle calls the startup provider and saves `startWithWindows` |
| Quit | Disposes the icon, flushes state, logs stop, exits `0`. Does not remove the Scheduled Task |

Double-click the icon opens Health Status.

Tooltip (`NotifyIcon.Text`, 63-character limit): `Clipboard diagnostics: Running` or `Clipboard diagnostics: Paused`.

Icon: a 16×16 bitmap drawn with `System.Drawing` (no `.ico` file). Filled circle while running, dimmed circle while paused. There is no balloon on start, on PASS, or on Quit.

On startup, the task is the source of truth for the checkbox: if the task exists, set `startWithWindows` true; if it does not, set it false; save only when the value changed and the settings file version is supported. A missing task is not recreated until the user checks the menu or runs `-InstallStartup`. When the settings version is unsupported, do not save: still install or remove the task, print one line with the task result (`installed` or `removed` or the task error) plus ERROR `SettingsVersionUnsupported`, and exit `2` from the install switches. The tray in that state runs paused and shows the task’s real installed state in Health without writing `settings.json`.

Paused is not “stopped”. The process still listens so Resume is immediate and Health can show that the listener is up. While paused, sequence changes update `lastActivityUtc` and do not call `SetDataObject`.

Quit waits up to 2 seconds if a rewrite is in progress, then exits. It does not kill the process mid-`SetDataObject` when the wait succeeds.

Single-instance, startup switches, and Event Log registration do not require Administrator except `-RegisterEventLog` when the source is missing.

## Data flow

1. A clipboard listener (or the fallback poll) observes `GetClipboardSequenceNumber`.
2. If the sequence is unchanged, return.
3. Update `lastActivityUtc` (memory and `state.json`).
4. If paused, stop. Reason for the in-memory ring: `Paused`.
5. Take the rewrite mutex. If the other entrypoint holds it, drop this one cycle (the holder will finish the rewrite).
6. Call `Invoke-ClipboardPlainTextRewrite`.
7. The function opens the clipboard with the existing retry budget: 10 attempts, 50 ms apart.
8. It enumerates format names and normalizes them (ordinal, case-insensitive).
9. `Test-ClipboardNeedsPlainText` classifies the snapshot.
10. Skip paths leave the clipboard unchanged and do not log an operational PASS/FAIL/ERROR (they would fire on every ordinary copy).
11. On `NeedsRewrite`, the function chooses the plain string (rules below), writes a `DataObject` that contains only Unicode text, then reads Unicode text back.
12. Ordinal equality of the in-memory string and the read-back string, plus a changed sequence number, is PASS. One retry on mismatch, then FAIL `ReadBackMismatch`. Do not put HTML or Chromium formats back.
13. Release the mutex.
14. Fan out through the notification and logging providers.
15. On PASS, increment the session counter and `state.rewriteCountTotal`, set `lastRewriteUtc`, and save state.
16. The listener will see the rewrite’s own sequence change. The second pass classifies as `AlreadyPlain` and stops. That is the loop brake.

Our own rewrite must not include a trigger format. Windows may synthesize `CF_TEXT`, `CF_OEMTEXT`, and `CF_LOCALE`. Those are not triggers.

Extra brake: if three PASS results in two seconds share the same `charCount`, suppress further rewrites for 10 seconds, log one FAIL `RewriteLoopSuppressed`, and toast once for that window. This covers a host that immediately re-adds HTML.

### When to rewrite

`Test-ClipboardNeedsPlainText` is pure. It takes the normalized format-name list and a boolean `HasExtractableText`. It does not read the clipboard and it does not receive the text.

Trigger formats (any one is enough):

- `HTML Format`
- `text/html`
- `Chromium Web Custom MIME Data Format`

Protected formats (any one suppresses rewrite, even if a trigger is present):

- `CF_BITMAP`, `CF_DIB`, `CF_DIBV5`, `CF_TIFF`, `CF_HDROP`, `CF_ENHMETAFILE`, `CF_METAFILEPICT`
- WinForms names: `Bitmap`, `System.Drawing.Bitmap`, `DeviceIndependentBitmap`, `Format17`, `FileDrop`, `FileName`, `FileNameW`
- `PNG`, `image/png`

`Chromium Internal Source URL` is not a trigger. A copy that is only Unicode text plus that URL stays untouched.

Normalization used before the test:

| Incoming name | Class |
| --- | --- |
| `UnicodeText`, `CF_UNICODETEXT`, `System.String` | plain text |
| `Text`, `CF_TEXT`, `OEMText`, `CF_OEMTEXT`, `Locale`, `CF_LOCALE` | synthesized text, not a trigger |
| trigger list above | trigger |
| protected list above | protected |

Reason codes from the pure test:

| Reason | `NeedsRewrite` | Caller action |
| --- | --- | --- |
| `NeedsRewrite` | true | Write Unicode text |
| `EmptyClipboard` | false | Skip, no operational event |
| `AlreadyPlain` | false | Skip, no operational event |
| `ProtectedFormat` | false | Skip, no operational event. Screenshots and file copies stay intact for `-ExportForCursor` and Explorer |
| `NoExtractableText` | false | FAIL, clipboard unchanged, toast. Trigger formats were present and both Unicode text and HTML extraction were empty |

`HasExtractableText` is computed by the rewrite function before the pure test: true when Unicode text trims to a non-empty string, or when HTML extraction trims to a non-empty string. The pure test returns `NoExtractableText` only when a trigger is present, no protected format is present, and `HasExtractableText` is false.

Evaluation order inside `Test-ClipboardNeedsPlainText`:

1. No format names → `EmptyClipboard`.
2. Any protected format → `ProtectedFormat` (wins over a trigger, so an Edge image copy that also carries HTML is left alone).
3. Any trigger and `HasExtractableText` false → `NoExtractableText`.
4. Any trigger and `HasExtractableText` true → `NeedsRewrite`.
5. Otherwise → `AlreadyPlain`.

`Rich Text Format` is not a trigger and not protected. RTF alone is `AlreadyPlain`. RTF together with `HTML Format` follows the trigger rule and the rewrite writes Unicode text only, so that RTF is not put back. Copilot copies that include RTF plus HTML are in this second group.

### Which string is written

1. If `CF_UNICODETEXT` / `UnicodeText` trims to a non-empty string, write that original string unchanged, including its own leading and trailing whitespace.
2. Otherwise decode HTML Format bytes with `ConvertFrom-ClipboardHtmlBytes` and write that derived string.
3. Otherwise, if a `text/html` format is present as UTF-8 bytes, run the same converter.
4. Otherwise return FAIL `NoExtractableText` and do not clear the clipboard.

Preferring existing Unicode text is deliberate. Copilot’s blank-paste failure is the extra HTML / custom MIME data, not a bad Unicode payload. Notepad already shows that Unicode payload. HTML extraction is the fallback for the case where Unicode text is missing.

HTML converter (no external parser):

1. Input is the raw clipboard bytes of `HTML Format` (CF_HTML is UTF-8).
2. Read ASCII header lines for `StartFragment:` and `EndFragment:` byte offsets.
3. If the offsets are in range and end is greater than start, UTF-8-decode that slice.
4. Otherwise search the decoded string for `<!--StartFragment-->` … `<!--EndFragment-->`.
5. Otherwise use the decoded body after the header.
6. Drop the contents of `script` and `style` elements, strip tags, decode `&amp; &lt; &gt; &quot; &apos; &nbsp;` and numeric character references (`&#NNN;`, `&#xHH;`). Unknown entities stay as literal text.
7. `nbsp` becomes U+0020. Trim the ends of the derived string. Preserve internal newlines.
8. Do not read or log `SourceURL`. It can carry query tokens.

A synthetic CF_HTML fixture in unit tests is enough. Do not capture a real Copilot copy into the repo.

### Rewrite result

| Outcome | Reason | Clipboard |
| --- | --- | --- |
| Skip | `EmptyClipboard`, `AlreadyPlain`, `ProtectedFormat`, `Paused` | unchanged |
| PASS | `Rewritten` | Unicode text only (plus formats Windows synthesizes) |
| FAIL | `NoExtractableText`, `OpenFailed`, `ReadBackMismatch`, `RewriteLoopSuppressed` | unchanged, except `ReadBackMismatch` which leaves the last `SetDataObject` result and does not restore HTML |
| ERROR | `Exception` plus the exception type name in `reason` detail, not the clipboard | unchanged unless the throw happened after `SetDataObject`; then same as mismatch (do not restore HTML) |

`OpenFailed` is the 10×50 ms open budget exhausted. `sourceProcess` is the clipboard owner’s process name before the write (`msedge` for Copilot). After a PASS the owner is PowerShell; logs keep the before-name.

There is no process-name allow list. Format classification is the gate. That covers Edge, Edge WebView, and Chrome. Process name is metadata only.

## Settings and state

Root: `%LOCALAPPDATA%\clipboard_diagnostics_mvp\`

Created on first read if missing. This directory is outside the git repo. The repo `.gitignore` already ignores `*.json`; these files are not committed anyway.

### `settings.json` (user intent)

```json
{
  "version": 1,
  "paused": false,
  "startWithWindows": false,
  "notifications": {
    "toastOnFail": true
  },
  "logging": {
    "file": true,
    "eventLog": true
  },
  "plainText": {
    "pollIntervalMs": 400
  }
}
```

| Field | Rule |
| --- | --- |
| `version` | `1` for this design. Missing version is treated as 1 and written back on the next save |
| `paused` | Source of truth for Pause. Tray and timed mode both honor it. Timed mode still exits when the clock runs out |
| `startWithWindows` | Mirrored from the Scheduled Task at tray start, and written when the menu or `-InstallStartup` / `-UninstallStartup` changes the task |
| `notifications.toastOnFail` | `false` forces the silent notification provider for FAIL/ERROR too. Event Log and file log are unchanged. Default `true` |
| `logging.file` / `logging.eventLog` | Turn off that sink. The in-memory ring still records the last 20 metadata events |
| `plainText.pollIntervalMs` | Fallback poll only. Integer, clamp to 200..5000. Default 400. Clamping logs one INFO event `1107` reason `SettingsClamped` |

Unknown properties are preserved on save. Saves are atomic: write `settings.json.tmp` in the same directory, then replace. A corrupt file is renamed to `settings.invalid-<utcstamp>.json`, defaults are written, and one ERROR `SettingsCorrupt` is logged. The tray keeps running.

If `version` is a number greater than `1`, do not rewrite the file. Run with in-memory defaults and **paused true** for that process, and log one ERROR `SettingsVersionUnsupported`. A newer file must not be rewritten by an older script, and it must not rewrite clipboards under rules the script does not know.

### `state.json` (counters)

Separate from settings so a Pause save cannot reset counters.

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

Session rewrite count lives only in process memory. `rewriteCountTotal` is monotonic across reboots. `lastActivityUtc` updates on every observed sequence change while the process is running, including while paused. `lastRewriteUtc` updates only on PASS. Corrupt state is renamed and recreated at zeros, with one ERROR `StateCorrupt`. A newer `version` is left on disk and ignored the same way as settings (paused, defaults).

### In-memory ring

Always on. Last 20 operational metadata records (the same fields as the file log line, no text). Health can show the last one via `state.json`. Export always includes the ring as `recent-memory.json`.

## Startup

MVP provider id: `ScheduledTask`.

| Item | Value |
| --- | --- |
| Task path | `\ClipboardDiagnosticsMvp\` |
| Task name | `PlainTextTray` |
| Full name | `\ClipboardDiagnosticsMvp\PlainTextTray` |
| Principal | Current user, interactive logon, limited (not elevated, not SYSTEM) |
| Trigger | At logon of that user |
| Run conditions | Allow start on batteries; do not stop on batteries; start when available; do not store a password |
| Multiple instances | Ignore new |
| Execution time limit | Unlimited |
| Action | `"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "<full path of clipboard-tray.ps1>"` |
| Working directory | The directory that contains `clipboard-tray.ps1` |
| Description | `Rewrites Chromium HTML clipboard copies to plain Unicode for local paste. Does not record clipboard text.` |

`Get-StartupProvider` returns one object:

| Member | MVP |
| --- | --- |
| `Id` | `ScheduledTask` |
| `Managed` | `$false` |
| `TaskPath` | `\ClipboardDiagnosticsMvp\` |
| `TaskName` | `PlainTextTray` |
| `Test` | `$true` when that task exists |
| `Install` | `Register-ScheduledTask` for the current user |
| `Uninstall` | `Unregister-ScheduledTask -Confirm:$false` |
| `GetStatus` | `Installed`, `Managed`, `TaskPath`, `TaskName`, `LastTaskResult`, `ActionPath` |

If the `ScheduledTasks` module cannot be imported, `Install` / `Uninstall` / `Test` use `schtasks.exe`:

- Create: `schtasks /Create /F /TN "\ClipboardDiagnosticsMvp\PlainTextTray" /SC ONLOGON /IT /RL LIMITED /TR "<action>"`
- Delete: `schtasks /Delete /F /TN "\ClipboardDiagnosticsMvp\PlainTextTray"`
- Query: `schtasks /Query /TN "\ClipboardDiagnosticsMvp\PlainTextTray"`

`/IT` keeps the task on the interactive token and avoids storing a password. The action string quotes `powershell.exe` and the `-File` path.

The tray menu calls this provider. It does not shell out on its own. `-InstallStartup` and `-UninstallStartup` call the same provider, then exit. They do not require the tray mutex.

Moving or renaming the clone breaks the task action until the user toggles Start with Windows or runs `-InstallStartup` again. Health shows `ActionPath` so that mismatch is visible. There is no copy into Program Files in this MVP.

### Future `StartupProvider` (do not implement)

A later provider may use id `Policy` with `Managed = $true`. Its `Install` and `Uninstall` return a result reason `ManagedByPolicy` and do not edit the task. The tray then disables Start with Windows and shows `Managed by policy` in Health. Nothing in the MVP constructs that provider. `Get-StartupProvider` always returns `ScheduledTask`.

Reserved policy values, not read for behavior in the MVP:

| Name | Type | Future meaning |
| --- | --- | --- |
| `StartupMode` | `REG_SZ` | `UserChoice` (today’s behavior), `Required` (task forced on, toggle disabled), `Disabled` (task forced off, toggle disabled) |
| `SettingsOverridePath` | `REG_SZ` | Absolute path of a JSON object merged over `settings.json` |

Registry keys, both optional:

- `HKLM\Software\Policies\ClipboardDiagnosticsMvp` (wins when both exist)
- `HKCU\Software\Policies\ClipboardDiagnosticsMvp`

`Get-ClipboardPolicySignal` returns:

```powershell
[pscustomobject]@{
  Present    = $false   # true when the winning key exists
  Applied    = $false   # always false in this MVP
  Source     = 'None'   # 'None' | 'HKLM' | 'HKCU'
  ValueNames = @()      # names only, never the data
}
```

Log and export value names only. Do not copy `SettingsOverridePath` or any other value into logs, toasts, or the zip; a path can point at a sensitive file. Health shows `Policy: none` or `Policy: present (not applied)`.

## Notifications and logging

These are separate providers. Toast is user-facing. The file log and the Event Log are operational. A PASS is a successful rewrite or a clean timed-session summary. A skip is not a PASS.

### Notification provider

`New-NotificationProvider -Kind Toast|Silent` returns an object with `Name` and `Send($Level, $Title, $Message)`.

`$Level` is `PASS`, `FAIL`, `ERROR`, or `INFO`.

| Kind | PASS | INFO | FAIL | ERROR |
| --- | --- | --- | --- | --- |
| `Toast` | no-op | no-op | toast, if `toastOnFail` | toast, if `toastOnFail` |
| `Silent` | no-op | no-op | no-op | no-op |

Callers may call `Send` for every outcome. The Toast kind drops PASS and INFO, which is what “silent PASS” means. There is no balloon (`NotifyIcon.ShowBalloonTip` is not used).

Toast implementation, inbox WinRT only:

- Ensure a shortcut exists at `%APPDATA%\Microsoft\Windows\Start Menu\Programs\ClipboardDiagnosticsMvp.lnk`.
- Set its `System.AppUserModel.ID` property to `ClipboardDiagnosticsMvp.PlainText`.
- Target the shortcut at the same `powershell.exe -File clipboard-tray.ps1` action as the task.
- Show a `ToastText02` payload through `Windows.UI.Notifications.ToastNotificationManager` and `Windows.Data.Xml.Dom.XmlDocument` with that AppUserModelID.
- XML-escape the title and body.
- If the WinRT call throws, log one ERROR `ToastUnavailable` per process and continue. A failed toast must not fail a rewrite and must not change the exit code of an otherwise successful timed session. The FAIL/ERROR itself is still logged.

The shortcut is a Start Menu entry so Windows accepts the AppUserModelID. `-UninstallStartup` and Quit do not delete it; timed mode still toasts FAIL/ERROR without a tray. Document the shortcut path in the export README.

Toast copy, metadata only:

| Level | Title | Body |
| --- | --- | --- |
| FAIL | `Clipboard plain-text rewrite failed` | `Could not rewrite the clipboard ({Reason}). The clipboard was left unchanged. Characters available: {CharCount}.` `{CharCount}` is `-1` when the clipboard could not be read |
| ERROR | `Clipboard diagnostics error` | `Plain-text helper hit an error ({Reason}). See the operational log.` |

`ReadBackMismatch` uses the FAIL title and this body instead: `Clipboard rewrite could not be verified ({Reason}). Rich formats were not restored.` That is the one FAIL that may have changed the clipboard.

Do not include clipboard text, HTML, source URL, window title, or command line.

### Logging provider

`New-LoggingProvider` accepts optional `-LogDirectory` (default `%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs`) and writes through `Format-OperationalMessage` to:

1. The file sink, when `logging.file` is true.
2. The Event Log sink, when `logging.eventLog` is true and the source is registered.

`Format-OperationalMessage` is pure. It accepts only these fields: `Level`, `EventId`, `Mode`, `Process`, `Pid`, `FormatsBefore`, `FormatsAfter`, `CharCount`, `Sequence`, `Reason`. Any other field name throws. That includes `Text`, `Preview`, `Html`, `Payload`, `SourceUrl`, and `WindowTitle`. Newlines in a value are replaced with spaces. Format lists are joined with `|`. A format name that itself contains `|` is stored with `/` instead. `Process` is a process name, never a path.

File line (UTC timestamp, one physical line):

```
2026-11-05T12:00:00.0000000Z level=PASS eventId=1000 mode=Tray process=msedge pid=4123 formatsBefore=HTML Format|CF_UNICODETEXT|Chromium Web Custom MIME Data Format formatsAfter=CF_UNICODETEXT|CF_TEXT charCount=842 sequence=101 reason=Rewritten
```

File path: `%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs\operational.log`

When the file reaches 1 MB, rename it to `operational-<utcstamp>.log` and start a new file. Keep the 5 newest rotated files and delete older ones. Rotation counts filenames only; it does not parse log text.

### Event Log

| Item | Value |
| --- | --- |
| Log | `Application` |
| Source | `ClipboardDiagnosticsMvp` |

Creating that source writes HKLM and needs Administrator once. Normal runs do not require elevation.

`Initialize-ClipboardEventLog`:

- If the source exists, return ready.
- Otherwise try `New-EventLog -LogName Application -Source ClipboardDiagnosticsMvp`.
- On access denied, set status `unavailable` and continue. Timed mode prints one console WARN for the session. The tray does not toast for this. Health shows `Event Log: not registered`.
- `-RegisterEventLog` is the supported registration step. It prints the elevation requirement on access denied and exits `2`.

Event IDs:

| ID | Entry type | When |
| --- | --- | --- |
| 1000 | Information | PASS rewrite (tray or timed) |
| 1001 | Information | Timed session ended with zero FAIL and zero ERROR |
| 1100 | Information | Tray process started |
| 1101 | Information | Tray Quit |
| 1102 | Information | Pause saved |
| 1103 | Information | Resume saved |
| 1104 | Information | Startup task installed |
| 1105 | Information | Startup task removed |
| 1106 | Information | Timed `-PlainText` exited because the tray is already running |
| 1107 | Information | A setting was clamped (`SettingsClamped`) |
| 2000 | Warning | FAIL (`NoExtractableText`, `OpenFailed`, `ReadBackMismatch`, `RewriteLoopSuppressed`) |
| 2001 | Warning | Timed session ended with one or more FAIL and zero ERROR |
| 3000 | Error | ERROR during rewrite or listener |
| 3001 | Error | Settings, state, or startup hard failure (`SettingsCorrupt`, `SettingsVersionUnsupported`, `StateCorrupt`, task registration failure) |
| 3002 | Error | Toast infrastructure failed (`ToastUnavailable`) |

The Event Log message is the same single line as the file log, without the leading timestamp (the log record has its own time).

### Outcome matrix

| Event | Timed console | Toast | File | Event Log |
| --- | --- | --- | --- | --- |
| PASS rewrite | PASS line (count, formats, process) | no | 1000 | 1000 |
| Skip (`AlreadyPlain`, empty, protected, paused) | no | no | no | no |
| FAIL | FAIL line | yes | 2000 | 2000 |
| ERROR | ERROR line | yes | 3000 | 3000 |
| Timed session clean | summary | no | 1001 | 1001 |
| Timed session with FAIL and no ERROR | summary | no extra toast | 2001 | 2001 |
| Timed session with any ERROR | summary | no extra toast | 3000 reason `SessionError` (per-error 3000 events were already written) | 3000 |
| Tray start / quit / pause / resume / task change | n/a (no console; the install switches print one line) | no | matching 1100–1105 | matching 1100–1105 |
| Timed mode overlapped by tray | WARN line | no | 1106 | 1106 |

“Console only” for PASS means the user-facing notification is silent. PASS is still an operational log event. The tray has no console, so a tray PASS is file + Event Log only.

Per-event toasts are the user signal. Session-summary events are not toasted again.

## Health Status

A fixed, non-resizable WinForms form, title `Clipboard diagnostics — Health`. Opened from the menu or a double-click. Read-only. Buttons: Refresh, Close.

| Label | Source |
| --- | --- |
| Status | `Running` or `Paused` |
| Listener | `Clipboard listener` or `Polling every {n} ms` |
| Start with Windows | `Yes` or `No`, from task `Test` |
| Task | `\ClipboardDiagnosticsMvp\PlainTextTray` |
| Task action | Action path from `GetStatus`, or `not installed` |
| Session rewrites | In-memory counter |
| Total rewrites | `state.rewriteCountTotal` |
| Last activity | `lastActivityUtc` converted to local time, or `never` |
| Last rewrite | `lastRewriteUtc` as local time, or `never` |
| Last result | `lastOutcome` and `lastReason`, or `none` |
| Last character count | `lastCharCount`, or `n/a` |
| Last source process | `lastOwnerName`, or `n/a` |
| Event Log | `registered` or `not registered` |
| Policy | `none` or `present (not applied)` |
| Log folder | `%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs` |
| Versions | `clipboard-test.ps1` tool version and `ClipboardCoreVersion` |

No text preview, no HTML, no source URL, no window title.

## Export Diagnostics

Menu item opens a save dialog. Default file name: `clipboard-diagnostics-export-yyyyMMdd-HHmmss.zip`. Default directory: the user’s Documents folder. The zip is written only where the user confirms.

`Export-ClipboardDiagnosticsBundle -DestinationPath` uses `System.IO.Compression.ZipArchive` (`System.IO.Compression.FileSystem`, inbox). Staging directory: `%LOCALAPPDATA%\clipboard_diagnostics_mvp\tmp\<guid>\`, deleted in `finally`.

Zip contents:

| Entry | Contents |
| --- | --- |
| `README.txt` | States that the bundle has no clipboard text, HTML, or source URLs, and lists the shortcut and task names |
| `status.json` | The Health fields, plus `exportedAtUtc`, `psVersion`, OS caption, `policyPresent`, `policyApplied` (`false`), `eventLogStatus`, session and total counters |
| `settings.json` | Current settings file |
| `state.json` | Current state file |
| `recent-memory.json` | The 20-entry ring |
| `logs/operational.log` and rotated files | Newest bytes first, stop at 512 KB combined |

Do not put these in the zip: clipboard text, diagnose reports from `.\reports\` (those can contain `-ShowText` previews), PowerToys settings, Cursor settings, the HTML converter input, or registry value data.

`status.json` uses the OS caption from `Win32_OperatingSystem.Caption` only. Do not add the computer name, user name, or user profile path beyond the known diagnostics root already visible as the log folder.

## Privacy and safety

This matches the current README boundaries and extends them to the tray.

- The tool is not a Cursor patch, a malware scanner, or a SaaS product. A failed paste does not prove malware, surveillance, or compromise.
- It does not modify Cursor binaries or Cursor settings.
- It does not phone home. No HTTP client is added on the plain-text path. Browser-test loopback stays limited to those existing modes.
- Clipboard text exists only in memory inside `Invoke-ClipboardPlainTextRewrite` and is discarded after the write and the length check.
- Toasts, Event Log messages, file logs, Health, Export, console PASS/FAIL/ERROR lines, and `.\reports\report-*.json` for `-PlainText` carry metadata only: outcome, reason code, character count, format names, process name, pid, sequence numbers, timestamps.
- `-ShowText` cannot turn that metadata into a preview for `-PlainText`.
- Image and file-drop clipboards are not rewritten, so a screenshot the user copied for `-ExportForCursor` is not destroyed.
- Pause, Quit, and `-UninstallStartup` are the user controls. Quit leaves the task in place. `-UninstallStartup` leaves settings, logs, and the Start Menu shortcut in place. Deleting `%LOCALAPPDATA%\clipboard_diagnostics_mvp` is the local data reset and is documented in the implementation README.
- Diagnose mode’s save/restore behavior is unchanged. `-PlainText` and the tray intentionally do not restore HTML after a successful rewrite. Restoring it would bring the blank paste back.
- The Scheduled Task runs as the current user, interactive, not elevated. It cannot see other users’ clipboards.
- Event Log registration is the only step that needs Administrator, and only until the source exists.

## Error handling

| Condition | Behavior |
| --- | --- |
| Clipboard busy | Retry 10×50 ms, then FAIL `OpenFailed`, clipboard unchanged |
| Trigger formats, no text | FAIL `NoExtractableText`, clipboard unchanged |
| Read-back mismatch | One retry, then FAIL `ReadBackMismatch`, do not restore HTML |
| Rewrite throws | ERROR, reason includes exception type name only |
| Toast throws | ERROR `ToastUnavailable` once per process; rewrite result stands |
| Event source missing | File log only; one WARN on the timed console; Health shows not registered |
| Settings or state corrupt | Rename aside, recreate defaults, ERROR, keep running |
| Settings or state version newer | Leave the file, run paused on defaults, ERROR |
| Task registration fails | ERROR on the install switch, exit `2`, tray not started |
| Tray already running | Second process exits `0` |
| Timed mode while tray running | WARN, event 1106, exit `0`, no second rewriter |
| Rewrite loop (3 identical counts in 2 s) | FAIL `RewriteLoopSuppressed`, 10 s suppression, one toast |
| Invalid mode combination | Exit `2`, no clipboard write |
| `-WhatIf` | No `SetDataObject` |

## Testing plan

### Unit tests (`tests/Run-CoreTests.ps1`)

New harness. Dot-source `clipboard-core.ps1`. Do not load `clipboard-test.ps1`, do not call WinForms, do not read the real clipboard. Existing `tests/Run-Tests.ps1` stays on the diagnose helpers and must still pass unchanged.

Cases:

- `Test-ClipboardNeedsPlainText` for: HTML + Unicode; Chromium web custom MIME + Unicode; `text/html` only with `HasExtractableText`; Unicode only (`AlreadyPlain`); empty list (`EmptyClipboard`); HTML + `FileDrop` (`ProtectedFormat`); HTML + `PNG` (`ProtectedFormat`); HTML + `Chromium Internal Source URL` + extractable text (`NeedsRewrite`); trigger present and `HasExtractableText` false (`NoExtractableText`); case differences (`html format`).
- `ConvertFrom-ClipboardHtmlBytes` with a synthetic CF_HTML header and offsets; fragment markers when offsets are zero; entity decoding; `script`/`style` dropped; empty fragment returns empty; `SourceURL` absent from the return value’s checks (the return value is only the plain string).
- `Format-OperationalMessage` exact line for a PASS record; throw when `Text` or `Html` is supplied; newline in `Reason` becomes a space; `|` inside a format name becomes `/`.
- Settings round-trip preserves an unknown property; corrupt JSON recovery renames the file (use a temp directory parameter, not the real LocalAppData); version `2` does not rewrite the file and the reader reports unsupported.
- Poll interval `50` clamps to `200`; `9000` clamps to `5000`.
- Startup action string quotes a path that contains a space. Test the string builder, not a real `schtasks` registration.
- Result object of a fake rewrite record (constructed, not from the clipboard) has no forbidden property names. Export staging rejects a record that contains one.

### Implementation checks on a Windows desktop

These are the soak tests required before anyone calls the work Production Tested. They are manual because they need Edge, Cursor, and an interactive clipboard.

1. Copy an Edge Copilot answer. With the tray running, Ctrl+V into Cursor Agent inserts the text. Notepad inserts the same text.
2. Quit the tray. Run `-PlainText -Seconds 600`. Copy from Copilot again. Cursor Agent Ctrl+V inserts the text. The report `seconds` value is 600. Exit code `0` if nothing failed.
3. Run `-PlainText` with `-Seconds` omitted and confirm the banner and the report show 120.
4. Win+Shift+S screenshot while the tray is running: formats still include a bitmap or PNG afterward, and `-ExportForCursor` still writes a PNG.
5. Copy a file in Explorer: `FileDrop` remains, the path still pastes into Explorer.
6. Copy ordinary Notepad text: clipboard stays plain, `rewriteCountTotal` does not increase.
7. Pause, copy from Copilot, confirm the rich formats remain, Resume, copy again, confirm a rewrite. Reboot with Pause set and the task installed: tray process is up, Health says Paused, and a Copilot copy is not rewritten until Resume.
8. Start with Windows off, reboot: no tray process and the task is absent. Turn it on, reboot: tray process is present and the task exists.
9. Export a zip after a known Copilot copy. Search the zip for a unique phrase from that copy. The phrase must be absent. The zip must contain `status.json`, `settings.json`, `state.json`, `recent-memory.json`, and `README.txt`.
10. PASS does not show a toast. Force `OpenFailed` by holding the clipboard open from another STA process: one FAIL toast, one event 2000 or the file-log equivalent, clipboard contents unchanged.
11. With no Event Log source, file log still receives the PASS line and Health says not registered. After an elevated `-RegisterEventLog`, the next PASS is in the Application log under source `ClipboardDiagnosticsMvp` and the message has no copied sentence.
12. Launch the tray twice: one icon, second process exit code `0`.
13. While the tray runs, start `-PlainText -Seconds 30`: WARN, exit `0`, no double rewrite (one sequence step, one total-count increment).
14. Ctrl+C during a clean timed session writes the report and exits `0`. A session that hit `NoExtractableText` exits `1`.
15. `-PlainText -Watch` exits `2` and does not change the clipboard.
16. `-PlainText -WhatIf` prints a would-rewrite line and leaves HTML Format in place.
17. `-ShowText -PlainText` prints the ignore line and the report has no `preview` property.

## Readiness

| Gate | Ready? | What is true at that gate |
| --- | --- | --- |
| MVP ready | Yes | The design covers local Copilot-to-Cursor text rewrite, tray, timed mode, `-Seconds` default 120, a documented 600-second example, silent PASS, toast on FAIL/ERROR, file log, Event Log, Health, Export without payloads, Pause across reboot, and a current-user logon task. That set is the MVP. It is not built in this change |
| Production Tested | No | The 17 desktop checks above have not been run. Listener-vs-poll fallback, battery logon, and a locked-clipboard FAIL still need a soak on Windows 10 and Windows 11, PowerShell 5.1 |
| Production Validated | No | No Authenticode signature, no operator runbook, no rehearsed rollback, no separate privacy review of the toast and Event Log templates against a real export |
| Enterprise Ready | No | No signing story for AppLocker, no real GPO/Intune, no ADMX/CSP, no multi-session soak (RDS/Citrix), no managed updates. `Local\` mutexes are already per session, and the policy key is a seam only |

Rollback after implementation, for the runbook that does not exist yet: Quit the tray, run `-UninstallStartup`, delete `%LOCALAPPDATA%\clipboard_diagnostics_mvp` if local logs should go too, and delete the Start Menu shortcut if toasts should stop. The next copy is a normal Windows clipboard again. Cursor is untouched throughout.

## Migration from the single-script MVP

- Add `clipboard-core.ps1` and `clipboard-tray.ps1` beside `clipboard-test.ps1`. Do not move diagnose, `-Fix`, browser tests, or `-ExportForCursor` into the core.
- Leave `ClipDiagV2` in `clipboard-test.ps1`. Plain-text code calls the core only.
- Bump `clipboard-test.ps1` `$script:ToolVersion` from `2.1.0` to `3.0.0` in the implementation change. Set `$script:ClipboardCoreVersion` to `1.0.0`.
- Extend the mode-exclusivity check and the safety header with `-PlainText`: foreground, time-bounded, rewrites matching copies in place, does not restore HTML, does not record payloads.
- Point the `-Seconds` comment-based help at `-Watch` and `-PlainText`. Default remains 120.
- In the implementation README, add the 600-second example, the tray usage, Pause, Export, and the elevation note for `-RegisterEventLog`. State the new files in the architecture tree. Keep the current safety wording: not a Cursor patch, not a malware scanner, not a SaaS product.
- Add `tests/Run-CoreTests.ps1`. Do not point the old AST harness at the tray script.
- Runtime files stay under `%LOCALAPPDATA%\clipboard_diagnostics_mvp\`. Do not write tray logs into the repo `reports\` directory. Timed mode still writes `.\reports\report-<stamp>.json` unless `-NoReport`.
- Update the Engineering Notes line that says background persistence is not implemented, so it describes the tray as the supported persistence and still rejects global hooks and telemetry.

## Implementation plan

One follow-up change, in this order. No second design pass.

1. Add `clipboard-core.ps1` with the functions in this document. Pure functions first: classification, HTML conversion, message formatting, settings read/write against a root parameter.
2. Add `tests/Run-CoreTests.ps1` and make the unit list above pass.
3. Add providers: silent and toast notifications, file log with rotation, Event Log best-effort, startup provider, export zip.
4. Add `-PlainText` to `clipboard-test.ps1`. Wire the outcome matrix, report JSON, `-WhatIf`, `-ShowText` ignore, and exit codes. Do not change other modes.
5. Add `clipboard-tray.ps1`: mutex, listener with poll fallback, menu, Health form, export dialog, Pause, startup toggle, Quit.
6. Update the README in that same change: 600-second example, tray section, link to this spec, architecture tree, Event Log elevation note.
7. Run `tests/Run-Tests.ps1` and `tests/Run-CoreTests.ps1`. Run the desktop soak list before calling the result Production Tested. Do not add signing, Intune, or policy enforcement in that change.

## Decisions

Closed here so implementation does not reopen them:

| Topic | Decision |
| --- | --- |
| Approach | Separate tray script, current-user logon task, shared core |
| Seconds | Default stays 120. Docs and the README example use 600 for a timed plain-text session |
| Text source | Existing non-empty Unicode text wins. HTML extraction is the fallback |
| Scope | No process allow list. Trigger formats only. Images and file drops are protected |
| PASS noise | No toast and no balloon. PASS is still file log and Event Log 1000 |
| Tray PASS | Same, without a console |
| Skips | Not operational events |
| `-ShowText` | Ignored for `-PlainText` |
| Overlap | Tray wins. Timed mode exits 0 with WARN and event 1106 |
| Event source | Best effort. `-RegisterEventLog` is the elevated step. Rewrite works without it |
| Policy | Keys are observed, values are not applied and not copied into logs |
| GPO/Intune | Interface only. `Get-StartupProvider` returns the task provider |
| Icon | Drawn in memory. No binary asset |
| State file | Separate `state.json` so Pause does not reset counters |
| Newer settings | Run paused and do not rewrite the file |
| HTML restore | Never, after a rewrite attempt that called `SetDataObject` |
| Task host | Windows PowerShell 5.1 `powershell.exe`, `-STA`, interactive limited user |
| Core side effects on import | None |

## Open questions

None. The implementation plan can proceed from this document without further product decisions.
