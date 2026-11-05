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
