$script:ClipboardCoreVersion = '1.0.0'

function Get-ClipboardDiagnosticsRoot {
    Join-Path $env:LOCALAPPDATA 'clipboard_diagnostics_mvp'
}

function Get-ClipboardDiagnosticsDefaults {
    [pscustomobject]@{
        version          = 1
        paused           = $false
        startWithWindows = $false
        notifications    = [pscustomobject]@{ toastOnFail = $true }
        logging          = [pscustomobject]@{ file = $true; eventLog = $true }
        plainText        = [pscustomobject]@{ pollIntervalMs = 400 }
    }
}

function Get-ClipboardDiagnosticsStateDefaults {
    [pscustomobject]@{
        version           = 1
        rewriteCountTotal = 0
        lastActivityUtc   = $null
        lastRewriteUtc    = $null
        lastOutcome       = $null
        lastReason        = $null
        lastCharCount     = $null
        lastOwnerName     = $null
    }
}

function Resolve-ClipboardStoreRoot {
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Get-ClipboardDiagnosticsRoot
    }
    [void][System.IO.Directory]::CreateDirectory($Root)
    return $Root
}

function Get-StoredJsonVersion {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return 1
    }
    try {
        $parsed = [System.IO.File]::ReadAllText($Path) | ConvertFrom-Json
    }
    catch {
        return 1
    }
    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return 1
    }
    $prop = $parsed.PSObject.Properties['version']
    if ($null -eq $prop -or $null -eq $prop.Value -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
        return 1
    }
    $number = 0
    if (-not [int]::TryParse([string]$prop.Value, [ref]$number)) {
        return 1
    }
    return $number
}

function Write-ClipboardJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Object
    )
    $json = $Object | ConvertTo-Json -Depth 10
    $tmp = "$Path.tmp"
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tmp, $json, $utf8)
    if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tmp, $Path, $null)
    }
    else {
        [System.IO.File]::Move($tmp, $Path)
    }
    return $true
}

function Add-MissingNote {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )
    if ($null -eq $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Repair-ClipboardSettingsShape {
    param([Parameter(Mandatory = $true)]$Settings)
    $clamped = $false
    Add-MissingNote -Object $Settings -Name 'paused' -Value $false
    if ($null -eq $Settings.paused) { $Settings.paused = $false }
    Add-MissingNote -Object $Settings -Name 'startWithWindows' -Value $false
    if ($null -eq $Settings.startWithWindows) { $Settings.startWithWindows = $false }
    if ($null -eq $Settings.PSObject.Properties['notifications'] -or $null -eq $Settings.notifications) {
        $Settings | Add-Member -NotePropertyName 'notifications' -NotePropertyValue ([pscustomobject]@{ toastOnFail = $true }) -Force
    }
    else {
        Add-MissingNote -Object $Settings.notifications -Name 'toastOnFail' -Value $true
        if ($null -eq $Settings.notifications.toastOnFail) { $Settings.notifications.toastOnFail = $true }
    }
    if ($null -eq $Settings.PSObject.Properties['logging'] -or $null -eq $Settings.logging) {
        $Settings | Add-Member -NotePropertyName 'logging' -NotePropertyValue ([pscustomobject]@{ file = $true; eventLog = $true }) -Force
    }
    else {
        Add-MissingNote -Object $Settings.logging -Name 'file' -Value $true
        Add-MissingNote -Object $Settings.logging -Name 'eventLog' -Value $true
        if ($null -eq $Settings.logging.file) { $Settings.logging.file = $true }
        if ($null -eq $Settings.logging.eventLog) { $Settings.logging.eventLog = $true }
    }
    if ($null -eq $Settings.PSObject.Properties['plainText'] -or $null -eq $Settings.plainText) {
        $Settings | Add-Member -NotePropertyName 'plainText' -NotePropertyValue ([pscustomobject]@{ pollIntervalMs = 400 }) -Force
    }
    else {
        $hasPoll = $null -ne $Settings.plainText.PSObject.Properties['pollIntervalMs']
        $stored = $null
        if ($hasPoll) { $stored = $Settings.plainText.pollIntervalMs }
        $number = 0
        $parsed = $hasPoll -and $null -ne $stored -and [int]::TryParse([string]$stored, [ref]$number)
        if (-not $hasPoll -or $null -eq $stored) {
            if (-not $hasPoll) {
                $Settings.plainText | Add-Member -NotePropertyName 'pollIntervalMs' -NotePropertyValue 400
            }
            else {
                $Settings.plainText.pollIntervalMs = 400
            }
        }
        elseif (-not $parsed) {
            $Settings.plainText.pollIntervalMs = 400
        }
        else {
            $adjusted = $number
            if ($adjusted -lt 200) { $adjusted = 200 }
            elseif ($adjusted -gt 5000) { $adjusted = 5000 }
            if ($adjusted -ne $number) {
                $clamped = $true
                $Settings.plainText.pollIntervalMs = $adjusted
            }
        }
    }
    return $clamped
}

function Repair-ClipboardStateShape {
    param([Parameter(Mandatory = $true)]$State)
    Add-MissingNote -Object $State -Name 'rewriteCountTotal' -Value 0
    if ($null -eq $State.rewriteCountTotal) { $State.rewriteCountTotal = 0 }
    foreach ($name in @('lastActivityUtc', 'lastRewriteUtc', 'lastOutcome', 'lastReason', 'lastCharCount', 'lastOwnerName')) {
        Add-MissingNote -Object $State -Name $name -Value $null
    }
}

function Read-ClipboardJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$InvalidPrefix
    )
    $result = [pscustomobject]@{
        Parsed       = $null
        Corrupt      = $false
        Unsupported  = $false
        MissingFile  = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $result.MissingFile = $true
        return $result
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    $parsed = $null
    $failed = $false
    try {
        $parsed = $raw | ConvertFrom-Json
    }
    catch {
        $failed = $true
    }
    if ($failed -or $null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
        $invalid = Join-Path (Split-Path -Parent $Path) ("{0}-{1}.json" -f $InvalidPrefix, $stamp)
        [System.IO.File]::Move($Path, $invalid)
        $result.Corrupt = $true
        return $result
    }
    $prop = $parsed.PSObject.Properties['version']
    $hasVersion = $null -ne $prop -and $null -ne $prop.Value -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value)
    if ($hasVersion) {
        $number = 0
        if ([int]::TryParse([string]$prop.Value, [ref]$number) -and $number -gt 1) {
            $result.Unsupported = $true
            return $result
        }
    }
    else {
        if ($null -eq $prop) {
            $parsed | Add-Member -NotePropertyName 'version' -NotePropertyValue 1
        }
        else {
            $parsed.version = 1
        }
    }
    $result.Parsed = $parsed
    return $result
}

function Read-ClipboardDiagnosticsSettings {
    param([string]$Root)
    $Root = Resolve-ClipboardStoreRoot -Root $Root
    $path = Join-Path $Root 'settings.json'
    $loaded = Read-ClipboardJsonFile -Path $path -InvalidPrefix 'settings.invalid'
    $corrupt = [bool]$loaded.Corrupt
    $unsupported = [bool]$loaded.Unsupported
    $clamped = $false
    if ($loaded.MissingFile -or $loaded.Corrupt -or $loaded.Unsupported) {
        $settings = Get-ClipboardDiagnosticsDefaults
        if ($loaded.Corrupt) {
            [void](Save-ClipboardDiagnosticsSettings -Settings $settings -Root $Root)
        }
    }
    else {
        $clamped = [bool](Repair-ClipboardSettingsShape -Settings $loaded.Parsed)
        $settings = $loaded.Parsed
    }
    $pausedEffective = $unsupported -or [bool]$settings.paused
    [pscustomobject]@{
        Settings         = $settings
        Unsupported      = $unsupported
        Corrupt          = $corrupt
        Clamped          = $clamped
        PausedEffective  = $pausedEffective
    }
}

function Save-ClipboardDiagnosticsSettings {
    param(
        $Settings,
        [string]$Root
    )
    $Root = Resolve-ClipboardStoreRoot -Root $Root
    $dest = Join-Path $Root 'settings.json'
    $objectVersion = 1
    if ($null -ne $Settings -and $null -ne $Settings.PSObject.Properties['version'] -and $null -ne $Settings.version) {
        $parsed = 0
        if ([int]::TryParse([string]$Settings.version, [ref]$parsed)) { $objectVersion = $parsed }
    }
    else {
        if ($null -eq $Settings.PSObject.Properties['version']) {
            $Settings | Add-Member -NotePropertyName 'version' -NotePropertyValue 1
        }
        else {
            $Settings.version = 1
        }
    }
    if ($objectVersion -gt 1 -or (Get-StoredJsonVersion -Path $dest) -gt 1) {
        return $false
    }
    return [bool](Write-ClipboardJsonAtomic -Path $dest -Object $Settings)
}

function Read-ClipboardDiagnosticsState {
    param([string]$Root)
    $Root = Resolve-ClipboardStoreRoot -Root $Root
    $path = Join-Path $Root 'state.json'
    $loaded = Read-ClipboardJsonFile -Path $path -InvalidPrefix 'state.invalid'
    $corrupt = [bool]$loaded.Corrupt
    $unsupported = [bool]$loaded.Unsupported
    if ($loaded.MissingFile -or $loaded.Corrupt -or $loaded.Unsupported) {
        $state = Get-ClipboardDiagnosticsStateDefaults
        if ($loaded.Corrupt) {
            [void](Save-ClipboardDiagnosticsState -State $state -Root $Root)
        }
    }
    else {
        Repair-ClipboardStateShape -State $loaded.Parsed
        $state = $loaded.Parsed
    }
    [pscustomobject]@{
        State        = $state
        Unsupported  = $unsupported
        Corrupt      = $corrupt
    }
}

function Save-ClipboardDiagnosticsState {
    param(
        $State,
        [string]$Root
    )
    $Root = Resolve-ClipboardStoreRoot -Root $Root
    $dest = Join-Path $Root 'state.json'
    $objectVersion = 1
    if ($null -ne $State -and $null -ne $State.PSObject.Properties['version'] -and $null -ne $State.version) {
        $parsed = 0
        if ([int]::TryParse([string]$State.version, [ref]$parsed)) { $objectVersion = $parsed }
    }
    else {
        if ($null -eq $State.PSObject.Properties['version']) {
            $State | Add-Member -NotePropertyName 'version' -NotePropertyValue 1
        }
        else {
            $State.version = 1
        }
    }
    if ($objectVersion -gt 1 -or (Get-StoredJsonVersion -Path $dest) -gt 1) {
        return $false
    }
    return [bool](Write-ClipboardJsonAtomic -Path $dest -Object $State)
}

function Get-ClipboardRuntimeGate {
    param($SettingsResult, $StateResult)
    $paused = $false
    if ($null -ne $SettingsResult -and ($SettingsResult.PausedEffective -or $SettingsResult.Unsupported)) {
        $paused = $true
    }
    if ($null -ne $StateResult -and $StateResult.Unsupported) {
        $paused = $true
    }
    [pscustomobject]@{
        PausedEffective = $paused
    }
}

function Resolve-ClipboardPolicySignal {
    param($HklmNames, $HkcuNames)
    $source = 'None'
    $names = @()
    if ($null -ne $HklmNames) {
        $source = 'HKLM'
        $names = @($HklmNames)
    }
    elseif ($null -ne $HkcuNames) {
        $source = 'HKCU'
        $names = @($HkcuNames)
    }
    [pscustomobject]@{
        Present    = ($source -ne 'None')
        Applied    = $false
        Source     = $source
        ValueNames = $names
    }
}

function Read-ClipboardPolicyKeyDefault {
    $hklmPath = 'HKLM:\Software\Policies\ClipboardDiagnosticsMvp'
    if (Test-Path -LiteralPath $hklmPath) {
        return @((Get-Item -LiteralPath $hklmPath).GetValueNames())
    }
    $hkcuPath = 'HKCU:\Software\Policies\ClipboardDiagnosticsMvp'
    if (Test-Path -LiteralPath $hkcuPath) {
        return @((Get-Item -LiteralPath $hkcuPath).GetValueNames())
    }
    return $null
}

function Get-ClipboardPolicySignal {
    param([scriptblock]$ReadKey)
    if ($null -ne $ReadKey) {
        $read = & $ReadKey
        if ($null -ne $read -and $read.PSObject.Properties.Name -contains 'HklmNames') {
            return Resolve-ClipboardPolicySignal -HklmNames $read.HklmNames -HkcuNames $read.HkcuNames
        }
        return Resolve-ClipboardPolicySignal -HklmNames $null -HkcuNames $null
    }
    $hklmNames = $null
    $hkcuNames = $null
    $hklmPath = 'HKLM:\Software\Policies\ClipboardDiagnosticsMvp'
    if (Test-Path -LiteralPath $hklmPath) {
        $hklmNames = @((Get-Item -LiteralPath $hklmPath).GetValueNames())
    }
    $hkcuPath = 'HKCU:\Software\Policies\ClipboardDiagnosticsMvp'
    if (Test-Path -LiteralPath $hkcuPath) {
        $hkcuNames = @((Get-Item -LiteralPath $hkcuPath).GetValueNames())
    }
    return Resolve-ClipboardPolicySignal -HklmNames $hklmNames -HkcuNames $hkcuNames
}
