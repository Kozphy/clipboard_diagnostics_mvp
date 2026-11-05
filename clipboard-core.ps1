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

function ConvertTo-OperationalToken {
    param($Value)
    if ($null -eq $Value) {
        return ''
    }
    $text = [string]$Value
    $text = $text.Replace("`r", ' ').Replace("`n", ' ')
    return $text.Replace('|', '/')
}

function Format-OperationalMessage {
    param([Parameter(Mandatory = $true)][hashtable]$Fields)
    $allowed = @('Level', 'EventId', 'Mode', 'Process', 'Pid', 'FormatsBefore', 'FormatsAfter', 'CharCount', 'Sequence', 'Reason')
    foreach ($key in @($Fields.Keys)) {
        if ($allowed -notcontains [string]$key) {
            throw "Operational log field not allowed: $key"
        }
    }
    foreach ($required in @('Level', 'EventId', 'Mode')) {
        if (-not $Fields.ContainsKey($required)) {
            throw "Operational log field missing: $required"
        }
    }
    $process = ''
    if ($Fields.ContainsKey('Process') -and $null -ne $Fields['Process']) {
        $process = [string]$Fields['Process']
    }
    if ($process.IndexOf('\') -ge 0 -or $process.IndexOf('/') -ge 0) {
        throw 'Process must be a process name, not a path'
    }
    $before = @()
    if ($Fields.ContainsKey('FormatsBefore') -and $null -ne $Fields['FormatsBefore']) {
        $before = @($Fields['FormatsBefore'] | ForEach-Object { ConvertTo-OperationalToken $_ })
    }
    $after = @()
    if ($Fields.ContainsKey('FormatsAfter') -and $null -ne $Fields['FormatsAfter']) {
        $after = @($Fields['FormatsAfter'] | ForEach-Object { ConvertTo-OperationalToken $_ })
    }
    $charCount = -1
    if ($Fields.ContainsKey('CharCount') -and $null -ne $Fields['CharCount']) {
        $charCount = [int]$Fields['CharCount']
    }
    $processId = 0
    if ($Fields.ContainsKey('Pid') -and $null -ne $Fields['Pid']) {
        $processId = [int]$Fields['Pid']
    }
    $sequence = [int64]0
    if ($Fields.ContainsKey('Sequence') -and $null -ne $Fields['Sequence']) {
        $sequence = [int64]$Fields['Sequence']
    }
    $reason = ''
    if ($Fields.ContainsKey('Reason') -and $null -ne $Fields['Reason']) {
        $reason = ConvertTo-OperationalToken $Fields['Reason']
    }
    return ('level={0} eventId={1} mode={2} process={3} pid={4} formatsBefore={5} formatsAfter={6} charCount={7} sequence={8} reason={9}' -f `
            (ConvertTo-OperationalToken $Fields['Level']), `
            [int]$Fields['EventId'], `
            (ConvertTo-OperationalToken $Fields['Mode']), `
            (ConvertTo-OperationalToken $process), `
            $processId, `
            ($before -join '|'), `
            ($after -join '|'), `
            $charCount, `
            $sequence, `
            $reason)
}

function Get-ClipboardEventEntryType {
    param([int]$EventId)
    if ($EventId -ge 2000 -and $EventId -le 2001) {
        return 'Warning'
    }
    if ($EventId -ge 3000 -and $EventId -le 3002) {
        return 'Error'
    }
    return 'Information'
}

function Test-ClipboardEventLogSource {
    try {
        return [bool][System.Diagnostics.EventLog]::SourceExists('ClipboardDiagnosticsMvp')
    }
    catch {
        return $false
    }
}

function Initialize-ClipboardEventLog {
    try {
        if (Test-ClipboardEventLogSource) {
            return [pscustomobject]@{ Ready = $true; Status = 'registered' }
        }
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Status = 'unavailable' }
    }
    try {
        New-EventLog -LogName Application -Source 'ClipboardDiagnosticsMvp' -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Status = 'unavailable' }
    }
    try {
        if (Test-ClipboardEventLogSource) {
            return [pscustomobject]@{ Ready = $true; Status = 'registered' }
        }
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Status = 'unavailable' }
    }
    return [pscustomobject]@{ Ready = $false; Status = 'unavailable' }
}

function New-LoggingProvider {
    param(
        [string]$LogDirectory,
        [bool]$FileEnabled = $true,
        [bool]$EventLogEnabled = $true,
        [scriptblock]$EventLogWriter,
        [int]$RotateBytes = 1048576
    )
    $logger = [pscustomobject]@{
        Ring            = New-Object 'System.Collections.Generic.List[pscustomobject]'
        FileEnabled     = [bool]$FileEnabled
        EventLogEnabled = [bool]$EventLogEnabled
        LogDirectory    = $LogDirectory
        RotateBytes     = $RotateBytes
        EventLogWriter  = $EventLogWriter
    }
    $logger | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param($Fields)
        $body = Format-OperationalMessage -Fields $Fields
        $record = [ordered]@{
            Level          = $null
            EventId        = $null
            Mode           = $null
            Process        = $null
            Pid            = $null
            FormatsBefore  = $null
            FormatsAfter   = $null
            CharCount      = $null
            Sequence       = $null
            Reason         = $null
        }
        foreach ($key in @($Fields.Keys)) {
            $record[$key] = $Fields[$key]
        }
        $this.Ring.Add([pscustomobject]$record)
        while ($this.Ring.Count -gt 20) {
            $this.Ring.RemoveAt(0)
        }
        if ($this.FileEnabled) {
            [void][System.IO.Directory]::CreateDirectory($this.LogDirectory)
            $path = Join-Path $this.LogDirectory 'operational.log'
            $stamp = [DateTime]::UtcNow.ToString('o')
            $utf8 = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::AppendAllText($path, ("{0} {1}`n" -f $stamp, $body), $utf8)
            if ((Get-Item -LiteralPath $path).Length -ge [int64]$this.RotateBytes) {
                $nameStamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfff')
                $rotated = Join-Path $this.LogDirectory ("operational-{0}.log" -f $nameStamp)
                $suffix = 0
                while (Test-Path -LiteralPath $rotated) {
                    $suffix++
                    $rotated = Join-Path $this.LogDirectory ("operational-{0}-{1}.log" -f $nameStamp, $suffix)
                }
                [System.IO.File]::Move($path, $rotated)
                $rotatedFiles = @(Get-ChildItem -LiteralPath $this.LogDirectory -Filter 'operational-*.log' | Sort-Object LastWriteTimeUtc -Descending)
                for ($index = 5; $index -lt $rotatedFiles.Count; $index++) {
                    Remove-Item -LiteralPath $rotatedFiles[$index].FullName -Force
                }
            }
        }
        if ($this.EventLogEnabled) {
            $entryType = Get-ClipboardEventEntryType -EventId ([int]$Fields['EventId'])
            if ($null -ne $this.EventLogWriter) {
                & $this.EventLogWriter $entryType ([int]$Fields['EventId']) $body
            }
            elseif (Test-ClipboardEventLogSource) {
                Write-EventLog -LogName Application -Source 'ClipboardDiagnosticsMvp' -EventId ([int]$Fields['EventId']) -EntryType $entryType -Message $body
            }
        }
    }
    return $logger
}

function Publish-ClipboardStoreEvents {
    param($SettingsResult, $StateResult, $Logger)
    $sent = @{}
    $emit = {
        param($Level, $EventId, $Reason)
        if ($sent.ContainsKey($Reason)) {
            return
        }
        $sent[$Reason] = $true
        $Logger.Write(@{
                Level   = $Level
                EventId = $EventId
                Mode    = 'Store'
                Reason  = $Reason
            })
    }
    if ($null -ne $SettingsResult -and $SettingsResult.Corrupt) {
        & $emit 'ERROR' 3001 'SettingsCorrupt'
    }
    if ($null -ne $SettingsResult -and $SettingsResult.Unsupported) {
        & $emit 'ERROR' 3001 'SettingsVersionUnsupported'
    }
    if ($null -ne $StateResult -and $StateResult.Corrupt) {
        & $emit 'ERROR' 3001 'StateCorrupt'
    }
    if ($null -ne $StateResult -and $StateResult.Unsupported) {
        & $emit 'ERROR' 3001 'SettingsVersionUnsupported'
    }
    if ($null -ne $SettingsResult -and $SettingsResult.Clamped) {
        & $emit 'INFO' 1107 'SettingsClamped'
    }
}
