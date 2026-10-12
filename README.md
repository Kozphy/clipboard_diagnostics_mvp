# Windows Clipboard Diagnostics MVP

Local, dependency-free PowerShell utility for diagnosing Windows clipboard problems. It tests clipboard text/image round-trips, checks known clipboard blockers, diagnoses terminal and browser paste paths, optionally repairs a PowerToys Mouse Without Borders setting, and exports clipboard images as a workaround for Cursor Agent on Windows.

This repository is **not** a Cursor patch, installer, SaaS product, malware scanner, or cloud service.

## Architecture

```
clipboard_diagnostics_mvp/
├── clipboard-test.ps1   # Single entrypoint for diagnostics and optional repair
├── README.md            # Usage, safety, troubleshooting, audit notes
├── LICENSE              # MIT (Kozphy, 2026)
├── .gitignore           # Ignores logs, reports/, output/, editor junk
├── tests/
│   └── Run-Tests.ps1     # Dependency-free pure-helper tests
└── output/              # Created at runtime for exported PNGs (gitignored)
```

| Component | Responsibility | Used by |
|-----------|----------------|---------|
| `clipboard-test.ps1` | All runtime behavior: tests, remediation, export, exit codes | Human operator / local shell |
| `.\output\` | Timestamped PNG exports for Cursor drag-and-drop | `-ExportForCursor` |
| `.\reports\` and `.\backups\` | Optional diagnostic reports and settings backups | Default report / `-Fix` |
| PowerToys MWB `settings.json` | External config read/optionally edited when `-Fix` runs | `-Fix` path only |

**Control flow (verified in script):**

1. `-ExportForCursor`, `-Watch`, `-TerminalPaste`, `-BrowserTest`, and `-BrowserPasteTest` each select a dedicated mode.
2. Without a mode switch, run clipboard round-trips, known-blocker checks, editor checks, optional `-Fix` remediation, then show guidance and a summary.

Exit codes: `0` no remaining issues, `1` remaining issues, `2` hard error (`$script:HadError`).

## Important: Cursor Ctrl+V limitation

This project **cannot patch Cursor itself**. On Windows, Cursor Agent often ignores `Ctrl+V` for clipboard images even when the OS clipboard is healthy (known client bug). Apps like OpenAI may still accept the same paste.

**Workaround provided by this repo:** export the clipboard image to a PNG, then drag it into the Agent panel.

Forum reference: [Agent chat clipboard image paste does not work](https://forum.cursor.com/t/agent-chat-clipboard-image-paste-ctrl-v-context-menu-does-not-work-drag-and-drop-file-works/156818)

## What it checks / does

1. **Clipboard health** — text, Unicode/multiline text, image, clipboard owner, formats, locks, and known blockers.
2. **Paste paths** — terminal paste checks and browser clipboard write/receive tests.
3. **Editor checks** — known terminal and editor keybinding/clipboard settings.
4. **PowerToys repair** — optionally disable Mouse Without Borders **Share Clipboard** with `-Fix`.
5. **Cursor workaround** — export the current clipboard image to `.\output\` for drag-and-drop.

## Requirements

- Windows 10 or Windows 11  
- Windows PowerShell 5.1 or PowerShell 7+  
- Interactive desktop session (clipboard APIs)  
- No Administrator elevation required for normal use  
- No NuGet/npm/pip packages  

## Installation

1. Clone or copy this project to a local folder.  
2. Open a terminal in the project directory.  
3. No packages or dependencies are required.  

## Usage

### Diagnose only

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1
```

**Side effects:** saves supported clipboard formats in memory, performs temporary round-trip tests, and restores supported formats afterward. Windows may not permit restoration of every format; the script reports this. Use `-NoReport` to skip the JSON report.

### Diagnose and fix PowerToys Share Clipboard

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Fix
```

**Side effects:** performs the same temporary clipboard tests as diagnose; if Share Clipboard is enabled, creates a settings backup, writes `ShareClipboard.value=false` into the current user's Mouse Without Borders `settings.json`, and may stop/restart PowerToys processes.

### Diagnose HackMD-to-Google-Keep paste in Edge

This test distinguishes a browser clipboard-receive problem from a Google Keep-specific problem. It opens a temporary `127.0.0.1` page in Edge; it does not contact HackMD or Google Keep, alter the clipboard, or create a browser profile.

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -BrowserPasteTest -Browser msedge -NoReport
```

1. When the local page opens, switch back to HackMD and copy the note text.
2. Return to the test page, click its box, and press **Ctrl+V**. The text will not appear in the page.
3. Read the result in PowerShell:
   - **Non-empty text received:** Edge received text from the clipboard. Try pasting the same copied text into Keep; if it still fails, the issue is likely specific to Keep or its page context.
   - **Paste event, but no text:** Edge received a paste action but exposed no non-empty plain/HTML text.
   - **No event:** inconclusive unless the test box had focus and Ctrl+V was pressed after copying.

The page sends only clipboard format names and the character lengths of plain/HTML text to its short-lived loopback listener. It prevents insertion; clipboard text is never included in the request, displayed, or saved. The listener stops when the test ends. Use `-InPrivate` to compare with Edge InPrivate without changing profiles.

### Test browser clipboard writes

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -BrowserTest -Browser msedge
```

This separate test writes a generated token from the local page to the Windows clipboard and restores supported clipboard formats afterward. It does not test paste into Google Keep.

### Export clipboard image for Cursor Agent (recommended workaround)

1. Copy your screenshot / image first (must be real image data, not only a URL/text).  
2. Run:

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -ExportForCursor -OpenFolder
```

3. Drag the PNG from `.\output\` into the Cursor Agent input (do **not** rely on `Ctrl+V`).  
4. Or attach it with `@` / the paperclip.  

`-ExportForCursor` does **not** run the destructive text/image tests, so it will not overwrite your copied picture before export.

**Idempotency:** each export creates a **new** timestamped file (`clipboard-for-cursor-yyyyMMdd-HHmmss.png` using local time). Prior PNGs are left in place.

## Results

| Result | Meaning |
|--------|---------|
| **PASS** | That check succeeded |
| **FAIL** | That check failed or a known blocker was found |
| **ERROR** | PowerShell encountered an exception |
| **WARN** | Guidance or a fixable issue |

Exit codes:

| Code | Meaning |
|------|---------|
| `0` | No remaining issues |
| `1` | One or more failures / remaining issues |
| `2` | A hard error occurred |

## Safety boundaries

- **Diagnose / `-Fix` mode** temporarily replaces clipboard contents and restores supported saved formats afterward; some formats cannot be restored through Windows clipboard APIs.
- **`-BrowserPasteTest`** does not modify the clipboard. It reports format names and text lengths only and serves the page/listener on loopback.
- **`-BrowserTest` / `-TerminalPaste`** use generated test data and restore supported clipboard formats afterward.
- **`-ExportForCursor` mode** reads the clipboard and writes a PNG under `.\output\`; it does not clear the clipboard on the success path before save.  
- Does **not** modify the Cursor IDE binary or settings.  
- Does **not** prove malware, surveillance, hacking, or compromise.  
- `-Fix` only automates disabling Mouse Without Borders **Share Clipboard**; it does not auto-disable Advanced Paste.  
- Settings edit uses a **targeted regex** on `ShareClipboard` only (avoids full JSON rewrite that could disturb other fields).  
- Script does **not** create backups of PowerToys settings before `-Fix`.  

## Privacy warning

- Diagnose and `-Fix` save supported clipboard formats in memory while testing. Avoid running them when clipboard content is sensitive, and use `-NoRestore` only if you intentionally want to leave test data on the clipboard.
- Exported images in `.\output\` may be sensitive; delete them when finished. That folder is gitignored.  
- The script does not print or save prior clipboard text payloads. Reports are metadata-oriented; use `-NoReport` to suppress report creation.

## Troubleshooting

- Test copy and paste in Notepad (text) and Paint (image).  
- If Paint works but Cursor Agent does not, use `-ExportForCursor` and drag-and-drop.  
- If `-ExportForCursor` reports no image, the clipboard may hold **text/URL only** (common when “copying” from some apps). Use **Win+Shift+S** or an explicit **Copy image** action.  
- Press Windows + V to check clipboard history.  
- Restart Windows Explorer.  
- Check whether the problem happens in all applications or only one.  
- For HackMD-to-Keep failures in Edge, run `-BrowserPasteTest -Browser msedge`. A successful receive confirms Edge can read the copied text at the browser page level; if Keep still rejects it, investigate Keep/page-specific behavior next.
- If you use PowerToys Mouse Without Borders and need cross-PC clipboard sharing, turn Share Clipboard back on only when required.  
- PowerToys Advanced Paste can also interfere in some apps; try disabling it temporarily.  

## Audit Notes

Critical paths that change external state:

| Path | External effect | How to detect | Safe recovery |
|------|-----------------|---------------|---------------|
| Text/image diagnose | Temporarily replaces and restores supported clipboard formats | Console PASS/FAIL and restore status | Re-copy any format Windows could not restore |
| `-BrowserPasteTest` | Opens a loopback page; reports format names and text lengths | Browser page and PowerShell result | Close the test tab; listener stops at completion |
| `-Fix` ShareClipboard | Backs up and edits MWB `settings.json` | Re-read setting / PowerToys UI | Restore the backup or re-enable Share Clipboard in PowerToys |
| `-Fix` restart | Stops/starts PowerToys processes | Task Manager / `Get-Process` | Start PowerToys from Start Menu |
| `-ExportForCursor` | Writes PNG under `.\output\` | File on disk + PASS path line | Delete PNG if sensitive |
| `-OpenFolder` | Launches Explorer | Explorer window | Close Explorer window |

Evidence available for review: console transcript of the run; `.\output\*.png` timestamps; on-disk `ShareClipboard` value. No append-only audit log file is written by this MVP.

## Engineering Notes

- **Single-script MVP** keeps install surface zero and makes behavior auditable in one file.  
- **Export mode is isolated** from diagnose mode so round-trip tests cannot destroy a screenshot the user just copied for Cursor.  
- **Regex settings patch** preferred over `ConvertTo-Json` round-trip on Windows PowerShell 5.1 to reduce risk of reformatting/secret field churn in PowerToys settings.  
- **Not implemented:** patching Cursor, global hooks, background persistence, network telemetry, automated Advanced Paste disable.

## Important limitation

A clipboard failure does not prove malware, surveillance, hacking, or system compromise.

This repository cannot modify or hot-fix the Cursor IDE binary. The Cursor image-paste issue must be fixed by Cursor; this tool only provides a practical workaround.

## License

MIT License — see [LICENSE](LICENSE).
