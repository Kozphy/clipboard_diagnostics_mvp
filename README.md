# Windows Clipboard Diagnostics MVP

Minimal utility that checks whether Windows can write to and read from the clipboard.

It performs a simple round-trip: write a unique test string with `Set-Clipboard`, wait briefly, then read it back with `Get-Clipboard`. Matching content means the clipboard path is working for basic text.

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or PowerShell 7+

## Installation

1. Clone or copy this project to a local folder.
2. Open a terminal in the project directory.
3. No packages or dependencies are required.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\clipboard-test.ps1
```

## Results

| Result | Meaning |
|--------|---------|
| **PASS** | Clipboard write/read succeeded |
| **FAIL** | Clipboard content did not match |
| **ERROR** | PowerShell encountered an exception |

## Privacy warning

- The script temporarily replaces the current clipboard contents.
- The current version does not restore the original clipboard contents.
- Do not run it while sensitive clipboard content is present.

## Troubleshooting

- Test copy and paste in Notepad.
- Press Windows + V to check clipboard history.
- Restart Windows Explorer.
- Check whether the problem happens in all applications or only one.

## Important limitation

A clipboard failure does not prove malware, surveillance, hacking, or system compromise.

## Future improvements

- Restore the original clipboard
- Add Unicode and multiline tests
- Add JSON report export
- Add automated PowerShell tests

## License

MIT License — see [LICENSE](LICENSE).
