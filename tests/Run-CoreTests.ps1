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
        Assert-True ($text -notmatch '<html' -and $text -notmatch '<body' -and $text -notmatch '<script') 'document tags stripped'
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
        $entry = Join-Path (Split-Path -Parent $CorePath) 'clipboard-test.ps1'
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
