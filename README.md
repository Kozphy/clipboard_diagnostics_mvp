# Windows Clipboard Diagnostics MVP

Local, dependency-free PowerShell utility that **diagnoses** Windows clipboard text/image round-trips, **optionally disables** a known PowerToys Mouse Without Borders clipboard-sharing blocker, and **exports** clipboard images to PNG as a workaround for Cursor Agent on Windows (which often ignores `Ctrl+V` for images).

This repository is **not** a Cursor patch, installer, SaaS product, malware scanner, or cloud service.

## Architecture

```
clipboard_diagnostics_mvp/
├── clipboard-test.ps1   # Single entrypoint: diagnose | -Fix | -ExportForCursor
├── README.md            # Usage, safety, troubleshooting, audit notes
├── LICENSE              # MIT (Kozphy, 2026)
├── .gitignore           # Ignores logs, reports/, output/, editor junk
└── output/              # Created at runtime for exported PNGs (gitignored)
```

| Component | Responsibility | Used by |
|-----------|----------------|---------|
| `clipboard-test.ps1` | All runtime behavior: tests, remediation, export, exit codes | Human operator / local shell |
| `.\output\` | Timestamped PNG exports for Cursor drag-and-drop | `-ExportForCursor` |
| PowerToys MWB `settings.json` | External config read/optionally edited when `-Fix` runs | `-Fix` path only |

**Control flow (verified in script):**

1. If `-ExportForCursor` → export clipboard image/file-drop → summary → exit  
2. Else → text round-trip → image round-trip → known-blocker check (`-Fix` may mutate MWB settings + restart processes) → Cursor guidance → summary → exit  

Exit codes: `0` no remaining issues, `1` remaining issues, `2` hard error (`$script:HadError`).

## Important: Cursor Ctrl+V limitation

This project **cannot patch Cursor itself**. On Windows, Cursor Agent often ignores `Ctrl+V` for clipboard images even when the OS clipboard is healthy (known client bug). Apps like OpenAI may still accept the same paste.

**Workaround provided by this repo:** export the clipboard image to a PNG, then drag it into the Agent panel.

Forum reference: [Agent chat clipboard image paste does not work](https://forum.cursor.com/t/agent-chat-clipboard-image-paste-ctrl-v-context-menu-does-not-work-drag-and-drop-file-works/156818)

## What it checks / does

1. **Text round-trip** — write a unique string, read it back  
2. **Image round-trip** — write a small bitmap, confirm the clipboard still contains an image  
3. **Known blocker** — PowerToys Mouse Without Borders **Share Clipboard**  
4. **Cursor workaround** — export the current clipboard image to `.\output\` for drag-and-drop  

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

**Side effects:** overwrites the Windows clipboard; does not restore prior contents.

### Diagnose and fix PowerToys Share Clipboard

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Fix
```

**Side effects:** same clipboard overwrite as diagnose; if Share Clipboard is enabled, writes `ShareClipboard.value=false` into the current user's Mouse Without Borders `settings.json` and may stop/restart `PowerToys.MouseWithoutBorders` / `PowerToys`.

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

- **Diagnose / `-Fix` mode** replaces clipboard contents and does **not** restore them.  
- **`-ExportForCursor` mode** reads the clipboard and writes a PNG under `.\output\`; it does not clear the clipboard on the success path before save.  
- Does **not** modify the Cursor IDE binary or settings.  
- Does **not** prove malware, surveillance, hacking, or compromise.  
- `-Fix` only automates disabling Mouse Without Borders **Share Clipboard**; it does not auto-disable Advanced Paste.  
- Settings edit uses a **targeted regex** on `ShareClipboard` only (avoids full JSON rewrite that could disturb other fields).  
- Script does **not** create backups of PowerToys settings before `-Fix`.  

## Privacy warning

- Do not run diagnose/`-Fix` while sensitive clipboard content is present.  
- Exported images in `.\output\` may be sensitive; delete them when finished. That folder is gitignored.  
- The script does not intentionally dump prior clipboard text payloads; diagnose prints only the generated test GUID.  

## Troubleshooting

- Test copy and paste in Notepad (text) and Paint (image).  
- If Paint works but Cursor Agent does not, use `-ExportForCursor` and drag-and-drop.  
- If `-ExportForCursor` reports no image, the clipboard may hold **text/URL only** (common when “copying” from some apps). Use **Win+Shift+S** or an explicit **Copy image** action.  
- Press Windows + V to check clipboard history.  
- Restart Windows Explorer.  
- Check whether the problem happens in all applications or only one.  
- If you use PowerToys Mouse Without Borders and need cross-PC clipboard sharing, turn Share Clipboard back on only when required.  
- PowerToys Advanced Paste can also interfere in some apps; try disabling it temporarily.  

## Audit Notes

Critical paths that change external state:

| Path | External effect | How to detect | Safe recovery |
|------|-----------------|---------------|---------------|
| Text/image diagnose | Clipboard overwritten | Console PASS/FAIL; clipboard no longer holds prior data | Re-copy needed content |
| `-Fix` ShareClipboard | Edits MWB `settings.json` | Re-read setting / PowerToys UI | Re-enable Share Clipboard in PowerToys |
| `-Fix` restart | Stops/starts PowerToys processes | Task Manager / `Get-Process` | Start PowerToys from Start Menu |
| `-ExportForCursor` | Writes PNG under `.\output\` | File on disk + PASS path line | Delete PNG if sensitive |
| `-OpenFolder` | Launches Explorer | Explorer window | Close Explorer window |

Evidence available for review: console transcript of the run; `.\output\*.png` timestamps; on-disk `ShareClipboard` value. No append-only audit log file is written by this MVP.

## Engineering Notes

- **Single-script MVP** keeps install surface zero and makes behavior auditable in one file.  
- **Export mode is isolated** from diagnose mode so round-trip tests cannot destroy a screenshot the user just copied for Cursor.  
- **Regex settings patch** preferred over `ConvertTo-Json` round-trip on Windows PowerShell 5.1 to reduce risk of reformatting/secret field churn in PowerToys settings.  
- **Rejected (not implemented):** patching Cursor, global hooks, background watchers, network telemetry, automated Advanced Paste disable.  

## Important limitation

A clipboard failure does not prove malware, surveillance, hacking, or system compromise.

This repository cannot modify or hot-fix the Cursor IDE binary. The Cursor image-paste issue must be fixed by Cursor; this tool only provides a practical workaround.

## Future improvements

- Restore the original clipboard after diagnose mode  
- Add Unicode and multiline tests  
- Add JSON report export  
- Add automated PowerShell tests  
- Detect additional clipboard hooks beyond Mouse Without Borders  

## License

MIT License — see [LICENSE](LICENSE).
