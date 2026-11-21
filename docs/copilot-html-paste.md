# Copilot HTML paste into Cursor and HyperFrames

Edge Copilot copies are not a single string. Windows receives several representations at once:

- plain Unicode text (`CF_UNICODETEXT`)
- an `HTML Format` document (styled chat-bubble markup, with CF_HTML header fields and often a SourceURL)
- Chromium-only private formats (`Chromium internal source URL`, `Chromium Web Custom MIME Data Format`, and similar)

The paste target chooses which format to read. Notepad only understands plain text, so it works. HyperFrames Studio and Cursor are Chromium/Electron apps. Chromium prefers `HTML Format` when it is present.

Copilot's HTML is a chat bubble, not a document those editors expect. The editor can sanitize it down to nothing (a blank paste). In HyperFrames, Ctrl+V with the canvas or timeline focused is an element-paste path, which can report "Nothing to paste" or refuse markup. This is a format-preference problem. On the machine where this was diagnosed, Edge, Copilot, HyperFrames, and Cursor all ran at Medium integrity, so it is not an integrity-level mismatch.

The fix already in this repo is to strip the rich formats and leave Unicode text before you paste. `clipboard-tray.ps1` does that continuously. `clipboard-test.ps1 -PlainText` does it for a timed session. Both call `clipboard-core.ps1`. Do not run the tray and `clipboard-test.ps1 -PlainText` at the same time. The second one sees the tray mutex and refuses to start. A separate watcher is not included, because a second rewriter would race the first.

`-Formats` and `-SetTestClipboard` do not rewrite. They only list formats or place a marker payload.

## Commands

List what is on the clipboard right now. The listing is metadata: format id, name, byte size, a Chromium flag, and HTML header fields (`Version`, `StartHTML`, `EndHTML`, `StartFragment`, `EndFragment`, and SourceURL reduced to scheme, host, and path). The HTML body is not printed.

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Formats
```

Repeat the list on each clipboard change for 60 seconds. Esc stops early. This still does not rewrite.

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Formats -Seconds 60
```

Place a payload whose plain text and HTML differ:

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -SetTestClipboard -Chromium
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -Formats
```

`-SetTestClipboard` replaces the clipboard and does not restore the previous contents. `-Clear` empties it. `-WhatIf` prints the marker names and does not write.

Run the rewriter only when you want HTML removed:

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1 -PlainText -Seconds 600
```

Or leave `clipboard-tray.ps1` running. Image and file-drop copies stay intact, including TIFF and metafile data under the names Windows PowerShell actually reports.

## How to verify whether an app reads HTML instead of text

1. Quit the tray, and do not start `-PlainText`, so the crafted HTML survives.
2. Run `clipboard-test.ps1 -SetTestClipboard`.
3. Run `clipboard-test.ps1 -Formats` and confirm both `CF_UNICODETEXT` and `HTML Format` are present.
4. Click the target field and press Ctrl+V.

| What you see | Meaning |
| --- | --- |
| `PLAIN-MARKER` | The app read Unicode text. |
| `HTML-MARKER` (possibly bold) | The app read `HTML Format` and rendered it. |
| Blank / nothing | The app chose `HTML Format` and sanitized or rejected it. This matches the Copilot to HyperFrames / Cursor symptom. |
| A toast such as "Nothing to paste" | Focus was probably on the HyperFrames canvas or timeline, not the chat box. Click the text field and try again. |

Repeat the paste with the tray running, or after `-PlainText` has rewritten the clipboard. `-Formats` should then show the text family only (`CF_UNICODETEXT`, and Windows may synthesize `CF_TEXT`, `CF_OEMTEXT`, and `CF_LOCALE`) and no `HTML Format`. The target should paste `PLAIN-MARKER`.

A one-off workaround without the rewriter is **Ctrl+Shift+V** (Chromium "Paste as plain text"), with the chat box focused.

## Electron and HyperFrames notes

Observed on the machine where this was diagnosed:

- HyperFrames Studio is an Electron/Chromium desktop app (`%LOCALAPPDATA%\Programs\HyperFrames\HyperFrames.exe`, `app.asar`, Electron 44.10.0). Cursor is also Electron. Both prefer `HTML Format` when it is present.
- In HyperFrames, click the chat / "Make something" text box before pasting. Ctrl+V on the canvas or timeline is an element-paste path, not a prompt-paste path.
- HyperFrames keeps Chromium caches under `%APPDATA%\HyperFrames\` (`Cache`, `Code Cache`, `GPUCache`, `GPUPersistentCache`). Only consider deleting those while the app is fully closed. That is worth trying if paste is still wrong after a plain-text rewrite. It is not the first fix.
- HyperFrames can check for updates in the app (**Settings > Updates**), per HeyGen's own docs.

Worth trying, as standard Chromium/Electron behavior. These were not confirmed as a named setting in each app's UI:

- **Ctrl+Shift+V** pastes as plain text. It is the fastest manual workaround.
- Launch with `--disable-gpu` on a shortcut if you already see GPU issues. A `gpu-crashed` marker was present historically in one HyperFrames profile. It is not required for the clipboard bug.
- In Cursor, open Settings and search for "paste". VS Code-compatible editors may expose `editor.pasteAs.enabled` and `editor.pasteAs.showPasteSelector`. Cursor is a VS Code fork, so those keys are worth checking. They were not verified as currently enabled.
- In Cursor, **Ctrl+Shift+I** opens DevTools on many Electron builds. Watch the console while you paste for clipboard or sanitizer errors. A red error will not always appear.

Updating the app is reasonable. The failure is in how Chromium chooses a clipboard format, so an update alone may not fix it.

## Layer-isolation test plan

Goal: blame one layer. Run each cell with the tray quit and `-PlainText` not running, unless the row says otherwise. After each paste, record `PLAIN-MARKER`, `HTML-MARKER`, blank, or a toast. Between tests, run `clipboard-test.ps1 -Formats` so you know whether `HTML Format` was actually present.

### A. Bypass Copilot and Edge entirely

`-SetTestClipboard` writes HTML and plain text from PowerShell, so a failure here cannot be Copilot's fault.

Paste into:

1. Notepad. Expect `PLAIN-MARKER` (text-only app).
2. WordPad or Word. Often `HTML-MARKER` or a bold rendering (HTML-aware).
3. Visual Studio Code (plain Electron/Chromium editor). Note which marker you get. Ctrl+Shift+V should force `PLAIN-MARKER`.
4. Cursor agent / editor field. Compare with VS Code.
5. HyperFrames chat box. Compare with Cursor. Then click the canvas and paste once more to see if a toast appears.

Interpretation:

- Notepad works, Word or WordPad shows HTML, and Cursor or HyperFrames is blank: the Windows clipboard is fine. Chromium/Electron HTML preference, plus each app's sanitizer, is the cause.
- Cursor is blank but VS Code shows a marker, or the reverse: the paste handler is app-specific, not "all Electron."
- HyperFrames is blank in the chat box and blank or toasting on the canvas, while Cursor shows `PLAIN-MARKER`: HyperFrames-specific (focus, or an element-paste / sanitizer path).
- Everything including Notepad is blank: the clipboard was empty or overwritten. Run `-Formats` again.

Then start the tray or `-PlainText`, run `-SetTestClipboard -Chromium` again, confirm `-Formats` no longer shows `HTML Format`, and re-paste into Cursor and HyperFrames. Text fields should show `PLAIN-MARKER`. If the tray is running it may strip the payload as soon as it is set. That is the race the mutex is there to describe: use one rewriter, and turn it off when you need the HTML marker to survive.

### B. Vary the source

Use the same targets each time (HyperFrames chat box, plus Notepad as the control).

| Source | What it isolates |
| --- | --- |
| Copilot in Edge (the reported path) | Full original stack |
| Copilot in Chrome (same Copilot web UI, different browser) | If Chrome copies fail the same way, blame Copilot's HTML, not Edge specifically. If only Edge fails, blame Edge's clipboard write. |
| Windows Copilot app | If this succeeds while Edge Copilot fails, blame the Edge/Copilot-web copy path. |
| A plain web page in Edge (ordinary article text, not Copilot's Copy button) | If this pastes into HyperFrames and Cursor, blame Copilot's payload. If this is also blank, blame Edge HTML copies into Electron. |

Always paste the same copy into Notepad. If Notepad gets text, the Windows clipboard is transporting Unicode text.

### C. How to assign blame

- **Microsoft Copilot.** Edge ordinary text pastes fine. Only Copilot Copy produces HTML that Electron sanitizes to blank. Chrome Copilot behaves the same.
- **Edge.** Chrome Copilot (or another browser) is fine. Only Edge's clipboard write misbehaves.
- **Windows Clipboard.** Notepad is also blank, or `-Formats` shows no `CF_UNICODETEXT` after a Copy. That was not the case in the original diagnosis: Notepad worked and Unicode text was present.
- **Electron.** VS Code, Cursor, and HyperFrames all go blank on the same HTML-plus-text clipboard, while Notepad and Word work.
- **HyperFrames.** Cursor and VS Code paste the test markers, but HyperFrames does not, or it fails only when the canvas is focused.
- **Cursor.** HyperFrames and VS Code are fine. Only Cursor's agent or editor field is blank.

If the tray or `-PlainText` makes every text field work, you have a working fix regardless of which layer preferred the HTML.

## What the rewriter will not do

- It will not invent text when both Unicode text and extractable HTML are empty.
- It leaves bitmap, TIFF, metafile, and file-drop copies alone, so screenshots and Explorer files are not turned into text.
- `Chromium internal source URL` by itself is not a rewrite trigger. A copy that is only Unicode text plus that URL stays untouched. The format list still flags the name as Chromium.
- Rich Text Format alone is not a trigger. RTF plus `HTML Format` follows the HTML rule, and the rewrite writes Unicode text only.
- It is not a security boundary. It only changes which format a paste will see.

## What CI can check

`tests/Run-CoreTests.ps1` covers format classification, HTML header parsing, and marker construction without reading a clipboard. `tests/Run-Tests.ps1` covers the older diagnose helpers. Neither harness opens the Win32 clipboard. Linux has no Win32 clipboard, and `clipboard-test.ps1` itself expects Windows profile paths, so `-Formats` and `-SetTestClipboard` are not executed in Linux CI.
