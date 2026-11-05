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
