# PlainText Tray Soak Record

Recorded 2026-11-05 on branch `cursor/plaintext-tray-design-ef14` after Tasks 1–9. This file is the Task 10 soak record. It is not a second implementation plan.

Host: Linux CI, PowerShell 7.6.9. There is no interactive Windows desktop, so Windows PowerShell 5.1, Edge, Cursor Agent, Notepad, Explorer, Win+Shift+S, reboot, the notification area, Scheduled Tasks, and the Windows Event Log were not available.

No Authenticode signing, Intune package, ADMX, or Policy startup provider was added. `Get-StartupProvider` remains the Scheduled Task provider only.

## Automated gate

Ran before the manual list. Both harnesses must exit 0 or the manual list is not started.

```text
powershell -ExecutionPolicy Bypass -File ./tests/Run-CoreTests.ps1
```

`PASS  264 assertions passed`. Exit code `0`.

```text
powershell -ExecutionPolicy Bypass -File ./tests/Run-Tests.ps1
```

`PASS  100 assertions passed`. Exit code `0`. `tests/Run-Tests.ps1` was not modified.

Gate commit at the time of the run: `2d5913c935396d65bb3b34e568b489ea4a6778e3` (Task 9). The gate ran on PowerShell 7.6.9 on Linux, not on Windows PowerShell 5.1.

## Manual checks

Every item is `NOT RUN`. This host has no interactive Windows desktop.

1. **NOT RUN.** The tray, an Edge Copilot copy, and Ctrl+V into Cursor Agent and Notepad need an interactive Windows host, which this machine is not.
2. **NOT RUN.** Quitting the tray and running `clipboard-test.ps1 -PlainText -Seconds 600` against a live Copilot copy needs an interactive Windows host, which this machine is not.
3. **NOT RUN.** A live `clipboard-test.ps1 -PlainText` session with `-Seconds` omitted, including the 120-second banner and report, needs an interactive Windows host, which this machine is not.
4. **NOT RUN.** Win+Shift+S bitmap or PNG capture while the tray runs, and a follow-up `-ExportForCursor` PNG, need an interactive Windows host, which this machine is not.
5. **NOT RUN.** An Explorer file copy that must keep `FileDrop` and still paste the path needs an interactive Windows host, which this machine is not.
6. **NOT RUN.** A Notepad text copy that must leave `rewriteCountTotal` unchanged needs an interactive Windows host, which this machine is not.
7. **NOT RUN.** Pause, resume, a reboot with Pause stored, and a Health status of `Paused` need an interactive Windows host, which this machine is not.
8. **NOT RUN.** Reboot with Start with Windows off, then on, and checking `\ClipboardDiagnosticsMvp\PlainTextTray` need an interactive Windows host, which this machine is not.
9. **NOT RUN.** An export zip taken after a Copilot copy of a unique phrase, and a search of that zip, need an interactive Windows host, which this machine is not.
10. **NOT RUN.** A silent PASS, an STA process holding the clipboard, one FAIL toast, and event `2000` need an interactive Windows host, which this machine is not.
11. **NOT RUN.** File-log PASS with no Event Log source, Health `not registered`, and an elevated `-RegisterEventLog` check of the Application log need an interactive Windows host, which this machine is not.
12. **NOT RUN.** Launching the tray twice and confirming one icon plus `Tray already running.` need an interactive Windows host, which this machine is not.
13. **NOT RUN.** Starting `-PlainText -Seconds 30` while the tray is already running, including the overlap WARN, needs an interactive Windows host, which this machine is not.
14. **NOT RUN.** Ctrl+C during a clean timed session, and a session that hits `NoExtractableText`, need an interactive Windows host, which this machine is not.
15. **NOT RUN.** `clipboard-test.ps1 -PlainText -Watch` exiting `2` without changing the clipboard was left as a manual Windows check and was not run on this host, which has no interactive Windows desktop.
16. **NOT RUN.** `-PlainText -WhatIf` against a live `HTML Format` clipboard needs an interactive Windows host, which this machine is not.
17. **NOT RUN.** `-ShowText -PlainText` and a report with no `preview` property need an interactive Windows host, which this machine is not.

## Readiness

```text
MVP implemented: yes (Tasks 1-9 are committed and both harnesses exit 0)
Production Tested: no (unless all 17 items are PASS on Windows 10 and Windows 11, PowerShell 5.1)
Production Validated: no (no Authenticode signature, no operator runbook beyond the README reset steps, no separate privacy review of a real export)
Enterprise Ready: no (no AppLocker signing story, no GPO/Intune enforcement, no ADMX/CSP, no multi-session soak, no managed updates)
```

Production Tested stays **no**. None of the 17 manual items is `PASS` on Windows 10 or Windows 11 with Windows PowerShell 5.1. Local MVP means the committed Tasks 1–9 plus this automated gate. It does not mean a signed, managed, or operator-validated build.
