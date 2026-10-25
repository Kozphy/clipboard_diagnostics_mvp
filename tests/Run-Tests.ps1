<#
SAFETY HEADER
=============
Purpose:      Plain-assert unit tests for the pure helpers in clipboard-test.ps1
              (JSONC stripping, Windows Terminal keybinding resolution, VS Code
              keybinding overrides, vim.handleKeys merge/repair, paste verdicts).
Side effects: Creates and deletes a scratch directory under -TempRoot only.
              Never reads or writes real editor/terminal settings and never
              touches the clipboard. The script under test is parsed, not run.
Requirements: Windows PowerShell 5.1+ (no Pester, no admin, no network).
Exit codes:   0 all tests passed, 1 one or more tests failed, 2 harness error.
#>

<#
.SYNOPSIS
    Run the clipboard-test.ps1 unit tests with plain assertions.
.PARAMETER ScriptPath
    Path to clipboard-test.ps1. Defaults to the parent folder of this file.
.PARAMETER TempRoot
    Directory under which a unique scratch folder is created and removed.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
.NOTES
    Functions are extracted from the script's AST and defined in this scope,
    so the script's main body (which would touch the clipboard) never runs.
    Output helpers and Confirm-Change are replaced by stubs.
    Audit Notes: the only filesystem writes are inside the scratch folder,
    which is deleted in a finally block.
#>
[CmdletBinding()]
param(
    [string]$ScriptPath,
    [string]$TempRoot = [System.IO.Path]::GetTempPath()
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'clipboard-test.ps1'
}
$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]
$script:CurrentTest = ''

function Assert-True {
    <#
    .SYNOPSIS
        Count one assertion, or record a failure when the condition is false.
    .DESCRIPTION
        Args:
            Condition (bool): Assertion result.
            Message (string): Failure text, prefixed with the current test name.

        Returns:
            None.
    .NOTES
        Side effects: increments $script:Passed or appends to $script:Failed.
        Audit Notes: test harness only; no clipboard or settings access.
    #>
    param([bool]$Condition, [string]$Message)
    if ($Condition) {
        $script:Passed++
    }
    else {
        $script:Failed.Add("[$script:CurrentTest] $Message")
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    <#
    .SYNOPSIS
        Assert that two values have the same string form, including null.
    .DESCRIPTION
        Args:
            Expected (object): Expected value. Compared with -ceq after string conversion.
            Actual (object): Value under test.
            Message (string): Assertion label. The expected and actual values are appended on failure.

        Returns:
            None.
    .NOTES
        Side effects: delegates to Assert-True.
        Audit Notes: test harness only.
    #>
    param($Expected, $Actual, [string]$Message)
    $ok = ($null -eq $Expected -and $null -eq $Actual) -or ($null -ne $Expected -and $null -ne $Actual -and [string]$Expected -ceq [string]$Actual)
    Assert-True $ok "$Message (expected '$Expected', got '$Actual')"
}

function Invoke-Test {
    <#
    .SYNOPSIS
        Run one named test and record an unexpected throw as a failure.
    .DESCRIPTION
        Args:
            Name (string): Test name printed before the body runs.
            Body (scriptblock): Assertions for this test.

        Returns:
            None. Does not rethrow.
    .NOTES
        Side effects: sets $script:CurrentTest and writes PASS/FAIL lines via assertions.
        Audit Notes: a throw inside Body is caught so later tests still run.
    #>
    param([string]$Name, [scriptblock]$Body)
    $script:CurrentTest = $Name
    Write-Host "TEST  $Name"
    try {
        & $Body
    }
    catch {
        $script:Failed.Add("[$Name] threw: $($_.Exception.Message)")
        Write-Host "  FAIL  threw: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "ERROR script under test not found: $ScriptPath" -ForegroundColor Red
    exit 2
}

$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    Write-Host "ERROR script has $($parseErrors.Count) parse error(s): $($parseErrors[0].Message)" -ForegroundColor Red
    exit 2
}

$wanted = @(
    'Remove-JsonComments', 'Test-JsonHasCommentsOrTrailingCommas', 'ConvertTo-NormalizedChord',
    'Get-WtCommandName', 'Resolve-WindowsTerminalBindings', 'Get-VsCodeTerminalKeybindingOverrides',
    'Get-MissingVimClipboardKeys', 'Merge-VimHandleKeys', 'ConvertTo-EditorSettingsJson',
    'Get-PasteVerdict', 'Read-EditorSettingsFile', 'Get-EditorVimDiagnosis',
    'Repair-EditorVimKeys', 'Backup-File', 'Get-BrowserFamily', 'Get-BrowserTestPage',
    'Get-BrowserPasteTestPage'
)
$functionAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($name in $wanted) {
    $fn = $functionAsts | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($null -eq $fn) {
        Write-Host "ERROR function $name not found in $ScriptPath" -ForegroundColor Red
        exit 2
    }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$fallbackAst = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:WtBuiltInDefaultsFallback' }, $false) | Select-Object -First 1
$wtFallbackDefaults = $null
if ($null -ne $fallbackAst) {
    $wtFallbackDefaults = $fallbackAst.Right.Expression.Value
}

$script:Output = New-Object System.Collections.Generic.List[string]
$script:FixesApplied = New-Object System.Collections.Generic.List[string]
$script:Stamp = '20990101-000000'
$script:ScriptRoot = $null
function Write-Pass { param([string]$Message) $script:Output.Add("PASS $Message") }
function Write-Fail { param([string]$Message) $script:Output.Add("FAIL $Message") }
function Write-Err { param([string]$Message) $script:Output.Add("ERROR $Message") }
function Write-Info { param([string]$Message) $script:Output.Add("INFO $Message") }
function Write-WarnLine { param([string]$Message) $script:Output.Add("WARN $Message") }
function Confirm-Change { param([string]$Target, [string]$Action) return $true }

$scratch = Join-Path $TempRoot ("clipdiag-tests-" + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($scratch)

try {
    Invoke-Test 'Remove-JsonComments strips comments but keeps strings' {
        $text = @'
{
  // line comment
  "url": "https://example.com/a//b", /* block */
  "quote": "say \"hi\" // not a comment",
  "arr": [1, 2, ],
  /* multi
     line */
  "last": true,
}
'@
        $clean = Remove-JsonComments -Text $text
        $obj = $clean | ConvertFrom-Json
        Assert-Equal 'https://example.com/a//b' $obj.url 'URL with // preserved'
        Assert-Equal 'say "hi" // not a comment' $obj.quote 'escaped quote and // inside string preserved'
        Assert-Equal 2 @($obj.arr).Count 'trailing comma in array removed'
        Assert-Equal 'True' $obj.last 'trailing comma in object removed'
        Assert-True ($clean -notmatch 'line comment') 'line comment removed'
        Assert-True ($clean -notmatch 'multi') 'block comment removed'
    }

    Invoke-Test 'Remove-JsonComments leaves plain JSON unchanged' {
        $plain = '{"a": "b/c", "d": [1, 2], "e": {"f": "/*x*/"}}'
        Assert-Equal $plain (Remove-JsonComments -Text $plain) 'plain JSON round-trips byte-for-byte'
        Assert-Equal '' (Remove-JsonComments -Text '') 'empty string'
        Assert-True ($null -eq (Remove-JsonComments -Text $null) -or (Remove-JsonComments -Text $null) -eq '') 'null input'
    }

    Invoke-Test 'Test-JsonHasCommentsOrTrailingCommas' {
        Assert-True (-not (Test-JsonHasCommentsOrTrailingCommas -Text '{"a": "http://x"}')) 'URL is not a comment'
        Assert-True (Test-JsonHasCommentsOrTrailingCommas -Text "{`"a`": 1 // c`n}") 'line comment detected'
        Assert-True (Test-JsonHasCommentsOrTrailingCommas -Text '{"a": 1,}') 'trailing comma detected'
        Assert-True (-not (Test-JsonHasCommentsOrTrailingCommas -Text '')) 'empty is not JSONC'
    }

    Invoke-Test 'ConvertTo-NormalizedChord' {
        Assert-Equal 'ctrl+shift+v' (ConvertTo-NormalizedChord -Keys 'Shift+Ctrl+V') 'modifier order'
        Assert-Equal 'shift+insert' (ConvertTo-NormalizedChord -Keys 'shift+ins') 'ins alias'
        Assert-Equal 'ctrl+v' (ConvertTo-NormalizedChord -Keys 'Control + v') 'control alias and spaces'
        Assert-Equal '' (ConvertTo-NormalizedChord -Keys '') 'empty'
    }

    Invoke-Test 'Resolve-WindowsTerminalBindings: modern format (actions + keybindings)' {
        $defaults = '{"actions":[{"command":"paste","id":"Terminal.PasteFromClipboard"}],"keybindings":[{"id":"Terminal.PasteFromClipboard","keys":"ctrl+shift+v"},{"id":"Terminal.PasteFromClipboard","keys":"shift+insert"}]}'
        $user = @'
{
  // user settings
  "copyOnSelect": false,
  "warning.multiLinePaste": true,
  "actions": [ { "command": { "action": "copy", "singleLine": false }, "id": "User.copy" } ],
  "keybindings": [
    { "id": "Terminal.PasteFromClipboard", "keys": "ctrl+v" },
    { "id": "User.copy", "keys": "ctrl+c" },
  ],
  "profiles": { "defaults": { "trimPaste": true }, "list": [ { "name": "PowerShell", "rightClickContextMenu": true } ] }
}
'@
        $r = Resolve-WindowsTerminalBindings -UserSettingsText $user -DefaultsText $defaults
        Assert-Equal 0 @($r.Errors).Count 'no parse errors'
        $ctrlV = $r.Bindings | Where-Object Chord -eq 'ctrl+v'
        Assert-Equal 'paste' $ctrlV.Action 'ctrl+v resolves to paste through id'
        Assert-Equal 'user' $ctrlV.Source 'ctrl+v comes from user layer'
        Assert-True $ctrlV.IsPaste 'ctrl+v IsPaste'
        $csv = $r.Bindings | Where-Object Chord -eq 'ctrl+shift+v'
        Assert-Equal 'defaults' $csv.Source 'ctrl+shift+v from defaults'
        Assert-Equal 'paste' $csv.Action 'ctrl+shift+v is paste'
        $names = @($r.Options | ForEach-Object { $_.Name })
        Assert-True ($names -contains 'copyOnSelect') 'copyOnSelect option collected'
        Assert-True ($names -contains 'warning.multiLinePaste') 'multiLinePaste option collected'
        Assert-True ($names -contains 'trimPaste') 'trimPaste from profiles.defaults collected'
        Assert-True ($names -contains 'rightClickContextMenu') 'per-profile option collected'
    }

    Invoke-Test 'Resolve-WindowsTerminalBindings: legacy format and explicit unbind' {
        $defaults = '{"actions":[{"command":"paste","keys":"ctrl+v"},{"command":"paste","keys":"ctrl+shift+v"},{"command":"paste","keys":"shift+insert"}]}'
        $user = '{"actions":[{"command":"unbound","keys":"ctrl+v"},{"command":null,"keys":"shift+insert"},{"command":{"action":"sendInput","input":"x"},"keys":"ctrl+shift+v"}]}'
        $r = Resolve-WindowsTerminalBindings -UserSettingsText $user -DefaultsText $defaults
        Assert-Equal 'unbound' ($r.Bindings | Where-Object Chord -eq 'ctrl+v').Action 'command unbound'
        Assert-Equal 'unbound' ($r.Bindings | Where-Object Chord -eq 'shift+insert').Action 'command null is unbound'
        Assert-Equal 'sendInput' ($r.Bindings | Where-Object Chord -eq 'ctrl+shift+v').Action 'object command action name'
        Assert-True (-not ($r.Bindings | Where-Object Chord -eq 'ctrl+v').IsPaste) 'unbound is not paste'
    }

    Invoke-Test 'Resolve-WindowsTerminalBindings: id null unbinds, unknown ids, bad JSON' {
        $defaults = '{"actions":[{"command":"paste","id":"Terminal.PasteFromClipboard","keys":"ctrl+v"}]}'
        $user = '{"keybindings":[{"id":null,"keys":"ctrl+v"},{"id":"User.missing","keys":"shift+insert"}]}'
        $r = Resolve-WindowsTerminalBindings -UserSettingsText $user -DefaultsText $defaults
        Assert-Equal 'unbound' ($r.Bindings | Where-Object Chord -eq 'ctrl+v').Action 'id null unbinds'
        Assert-True (($r.Bindings | Where-Object Chord -eq 'shift+insert').Action -like '(unknown id*') 'unknown id reported'
        Assert-Equal 'not bound' ($r.Bindings | Where-Object Chord -eq 'ctrl+shift+v').Action 'unmapped chord'
        $bad = Resolve-WindowsTerminalBindings -UserSettingsText '{"actions": [' -DefaultsText $defaults
        Assert-Equal 1 @($bad.Errors).Count 'parse error returned, not thrown'
        Assert-Equal 'paste' ($bad.Bindings | Where-Object Chord -eq 'ctrl+v').Action 'defaults still apply when user JSON is broken'
    }

    Invoke-Test 'Built-in WT defaults fallback matches shipped defaults.json' {
        Assert-True (-not [string]::IsNullOrWhiteSpace($wtFallbackDefaults)) 'fallback JSON present in script'
        $r = Resolve-WindowsTerminalBindings -UserSettingsText '' -DefaultsText $wtFallbackDefaults
        foreach ($c in @('ctrl+shift+v', 'shift+insert')) {
            Assert-True ($r.Bindings | Where-Object Chord -eq $c).IsPaste "$c is paste in fallback defaults"
        }
        Assert-Equal 'not bound' ($r.Bindings | Where-Object Chord -eq 'ctrl+v').Action 'ctrl+v comes from the user settings template, not defaults'
    }

    Invoke-Test 'Get-VsCodeTerminalKeybindingOverrides' {
        $kb = @'
// Place your key bindings in this file
[
  { "key": "ctrl+v", "command": "-workbench.action.terminal.paste", "when": "terminalFocus" },
  { "key": "ctrl+shift+v", "command": "workbench.action.terminal.sendSequence", "when": "terminalFocus" },
  { "key": "ctrl+v", "command": "editor.action.clipboardPasteAction", "when": "editorTextFocus" },
  { "key": "shift+insert", "command": "workbench.action.terminal.paste" },
]
'@
        $r = @(Get-VsCodeTerminalKeybindingOverrides -KeybindingsText $kb)
        Assert-Equal 3 $r.Count 'three terminal-relevant entries'
        Assert-True ($r[0].Removes) 'leading minus marks removal'
        Assert-Equal 'ctrl+shift+v' $r[1].Key 'terminal-scoped chord override detected'
        Assert-Equal 0 @(Get-VsCodeTerminalKeybindingOverrides -KeybindingsText '').Count 'empty text'
        $threw = $false
        try { [void](Get-VsCodeTerminalKeybindingOverrides -KeybindingsText '[{') } catch { $threw = $true }
        Assert-True $threw 'invalid JSON throws for the caller to report'
    }

    Invoke-Test 'Get-MissingVimClipboardKeys / Merge-VimHandleKeys' {
        $s = '{"editor.fontSize": 14, "vim.handleKeys": {"<C-d>": true, "<C-c>": true}}' | ConvertFrom-Json
        $missing = @(Get-MissingVimClipboardKeys -Settings $s)
        Assert-Equal '<C-c>,<C-v>' ($missing -join ',') 'true and absent both count as missing'
        $m = Merge-VimHandleKeys -Settings $s
        Assert-True $m.Changed 'merge reports change'
        Assert-Equal 'False' $m.Settings.'vim.handleKeys'.'<C-c>' '<C-c> set false'
        Assert-Equal 'False' $m.Settings.'vim.handleKeys'.'<C-v>' '<C-v> added false'
        Assert-Equal 'True' $m.Settings.'vim.handleKeys'.'<C-d>' 'unrelated vim key kept'
        Assert-Equal 14 $m.Settings.'editor.fontSize' 'unrelated setting kept'
        $again = Merge-VimHandleKeys -Settings $m.Settings
        Assert-True (-not $again.Changed) 'second merge is a no-op (idempotent)'
        Assert-Equal 0 @(Get-MissingVimClipboardKeys -Settings $again.Settings).Count 'nothing missing after merge'

        $empty = Merge-VimHandleKeys -Settings ([pscustomobject]@{})
        Assert-True $empty.Changed 'creates vim.handleKeys when absent'
        $weird = Merge-VimHandleKeys -Settings ('{"vim.handleKeys": "oops"}' | ConvertFrom-Json)
        Assert-Equal 'False' $weird.Settings.'vim.handleKeys'.'<C-v>' 'non-object handleKeys replaced'
    }

    Invoke-Test 'ConvertTo-EditorSettingsJson keeps <, >, &, quote readable' {
        $s = [pscustomobject]@{ 'vim.handleKeys' = [pscustomobject]@{ '<C-c>' = $false }; 'x' = "a&b 'q'"; 'esc' = 'lit \u003c' }
        $json = ConvertTo-EditorSettingsJson -Settings $s
        Assert-True ($json.Contains('"<C-c>"')) 'angle brackets unescaped'
        Assert-True ($json.Contains("a&b 'q'")) 'ampersand and apostrophe unescaped'
        $back = $json | ConvertFrom-Json
        Assert-Equal 'lit \u003c' $back.esc 'literal backslash-u text survives round trip'
        Assert-Equal 'False' $back.'vim.handleKeys'.'<C-c>' 'round trip value'
    }

    Invoke-Test 'Get-PasteVerdict' {
        $t = 'PASTETEST-CTRLV-1a2b3c4d'
        Assert-Equal 'exact' (Get-PasteVerdict -Expected $t -Received $t) 'exact'
        Assert-Equal 'exact-whitespace' (Get-PasteVerdict -Expected $t -Received " $t ") 'whitespace'
        Assert-Equal 'contains' (Get-PasteVerdict -Expected $t -Received "x$t") 'contains'
        Assert-Equal 'partial' (Get-PasteVerdict -Expected $t -Received 'PASTETEST-CT') 'partial'
        Assert-Equal 'empty' (Get-PasteVerdict -Expected $t -Received '') 'empty'
        Assert-Equal 'empty' (Get-PasteVerdict -Expected $t -Received $null) 'null'
        Assert-Equal 'different' (Get-PasteVerdict -Expected $t -Received 'hello') 'different'
    }

    Invoke-Test 'Get-BrowserFamily / Get-BrowserTestPage' {
        $edge = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0'
        $chrome = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
        $cursor = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Cursor/3.21.18 Chrome/148.0.7778.280 Electron/42.10.0 Safari/537.36'
        Assert-Equal 'edge' (Get-BrowserFamily -UserAgent $edge) 'Edge UA'
        Assert-Equal 'chrome' (Get-BrowserFamily -UserAgent $chrome) 'Chrome UA'
        Assert-Equal 'electron' (Get-BrowserFamily -UserAgent $cursor) 'Cursor embedded browser is electron, not chrome'
        Assert-Equal 'none' (Get-BrowserFamily -UserAgent '') 'empty UA'
        $page = Get-BrowserTestPage -Token 'BROWSER-CLIPTEST-abc123'
        Assert-True ($page.Contains('var TOKEN = "BROWSER-CLIPTEST-abc123"')) 'token embedded in page script'
        Assert-True (-not $page.Contains('__TOKEN__')) 'placeholder fully replaced'
        Assert-True ($page.Contains('autofocus')) 'button autofocused so Enter is a user gesture'
    }

    Invoke-Test 'Get-BrowserPasteTestPage privacy contract' {
        $page = Get-BrowserPasteTestPage -RunId 'paste123'
        Assert-True ($page.Contains('Clipboard paste test [paste123]')) 'run id embedded in title'
        Assert-True ($page.Contains('e.preventDefault();')) 'paste is prevented from inserting content'
        Assert-True ($page.Contains('textLengths[type] = clipboard.getData(type).length')) 'only text lengths are extracted'
        Assert-True ($page.Contains('types: types, textLengths: textLengths')) 'only format names and text lengths are reported'
        Assert-True (-not $page.Contains('<textarea')) 'page has no content-bearing textarea'
        Assert-True (-not $page.Contains('body: clipboard')) 'clipboard data is never posted directly'
    }

    Invoke-Test 'Editor vim diagnosis and repair on temp paths only' {
        $editorRoot = Join-Path $scratch 'editor'
        $backupDir = Join-Path $scratch 'backups'
        $ext = Join-Path $editorRoot 'extensions'
        [void][System.IO.Directory]::CreateDirectory((Join-Path $ext 'vscodevim.vim-1.30.1'))
        $plainPath = Join-Path $editorRoot 'plain\settings.json'
        $jsoncPath = Join-Path $editorRoot 'jsonc\settings.json'
        $newPath = Join-Path $editorRoot 'new\settings.json'
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $plainPath))
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $jsoncPath))
        [System.IO.File]::WriteAllText($plainPath, '{"editor.fontSize": 13, "vim.handleKeys": {"<C-c>": true}}')
        $jsoncText = "{`n  // keep me`n  `"editor.fontSize`": 13`n}"
        [System.IO.File]::WriteAllText($jsoncPath, $jsoncText)

        $targets = @(
            [pscustomobject]@{ Name = 'Plain'; Settings = $plainPath; Extensions = $ext },
            [pscustomobject]@{ Name = 'Jsonc'; Settings = $jsoncPath; Extensions = $ext },
            [pscustomobject]@{ Name = 'New'; Settings = $newPath; Extensions = $ext },
            [pscustomobject]@{ Name = 'NoVim'; Settings = $plainPath; Extensions = (Join-Path $scratch 'missing') }
        )
        $diag = @(Get-EditorVimDiagnosis -Targets $targets)
        Assert-Equal 3 $diag.Count 'editor without VSCodeVim is skipped'
        $plain = $diag | Where-Object Editor -eq 'Plain'
        $jsonc = $diag | Where-Object Editor -eq 'Jsonc'
        $new = $diag | Where-Object Editor -eq 'New'
        Assert-Equal '<C-c>,<C-v>' (@($plain.MissingKeys) -join ',') 'plain settings missing both keys'
        Assert-True ($jsonc.HasComments -and -not $jsonc.Parseable) 'JSONC flagged and not parseable'
        Assert-True ((-not $new.Exists) -and $new.Parseable) 'missing settings.json is creatable'

        Assert-True (Repair-EditorVimKeys -Diagnosis $plain -BackupDirectory $backupDir) 'plain repair succeeded'
        $after = [System.IO.File]::ReadAllText($plainPath) | ConvertFrom-Json
        Assert-Equal 'False' $after.'vim.handleKeys'.'<C-v>' 'plain file now has <C-v> false'
        Assert-Equal 13 $after.'editor.fontSize' 'plain file kept other settings'
        $backups = @(Get-ChildItem -LiteralPath $backupDir -File)
        Assert-Equal 1 $backups.Count 'exactly one backup created'
        Assert-True ($backups[0].Name -like 'settings_Plain_20990101-000000*.json') 'backup name has label and stamp'
        Assert-True (([System.IO.File]::ReadAllText($backups[0].FullName)) -match '"<C-c>": true') 'backup holds the original content'

        Assert-True (-not (Repair-EditorVimKeys -Diagnosis $jsonc -BackupDirectory $backupDir)) 'JSONC repair refused'
        Assert-Equal $jsoncText ([System.IO.File]::ReadAllText($jsoncPath)) 'JSONC file untouched'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $backupDir -File).Count 'no backup for refused file'

        Assert-True (Repair-EditorVimKeys -Diagnosis $new -BackupDirectory $backupDir) 'new settings.json created'
        Assert-True (Test-Path -LiteralPath $newPath) 'new file exists'

        $beforeSecond = [System.IO.File]::ReadAllText($plainPath)
        Assert-True (Repair-EditorVimKeys -Diagnosis $plain -BackupDirectory $backupDir) 'second repair reports success'
        Assert-Equal $beforeSecond ([System.IO.File]::ReadAllText($plainPath)) 'second repair does not rewrite (idempotent)'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $backupDir -File | Where-Object Name -like 'settings_Plain_*').Count 'second repair makes no new backup'
    }

    Invoke-Test 'Backup-File never overwrites an existing backup' {
        $src = Join-Path $scratch 'src.json'
        $dir = Join-Path $scratch 'bk'
        [System.IO.File]::WriteAllText($src, '{}')
        $a = Backup-File -Path $src -Label 'demo label' -Directory $dir
        $b = Backup-File -Path $src -Label 'demo label' -Directory $dir
        Assert-True ($a -ne $b) 'distinct backup paths'
        Assert-True ((Split-Path -Leaf $a) -eq 'demo_label_20990101-000000.json') 'label sanitized, stamp appended'
        Assert-True ((Split-Path -Leaf $b) -eq 'demo_label_20990101-000000-1.json') 'numeric suffix on collision'
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
