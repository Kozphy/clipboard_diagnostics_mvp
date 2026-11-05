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

function Test-ClipboardNeedsPlainText {
    param(
        [string[]]$FormatNames = @(),
        [bool]$HasExtractableText = $false
    )
    $names = @($FormatNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($names.Count -eq 0) {
        return [pscustomobject]@{ NeedsRewrite = $false; Reason = 'EmptyClipboard' }
    }
    $protected = @(
        'CF_BITMAP', 'CF_DIB', 'CF_DIBV5', 'CF_TIFF', 'CF_HDROP', 'CF_ENHMETAFILE', 'CF_METAFILEPICT',
        'Bitmap', 'System.Drawing.Bitmap', 'DeviceIndependentBitmap', 'Format17',
        'FileDrop', 'FileName', 'FileNameW', 'PNG', 'image/png'
    )
    $triggers = @('HTML Format', 'text/html', 'Chromium Web Custom MIME Data Format')
    $isProtected = $false
    $isTrigger = $false
    foreach ($name in $names) {
        foreach ($item in $protected) {
            if ([string]::Equals($name, $item, [System.StringComparison]::OrdinalIgnoreCase)) { $isProtected = $true }
        }
        foreach ($item in $triggers) {
            if ([string]::Equals($name, $item, [System.StringComparison]::OrdinalIgnoreCase)) { $isTrigger = $true }
        }
    }
    if ($isProtected) { return [pscustomobject]@{ NeedsRewrite = $false; Reason = 'ProtectedFormat' } }
    if ($isTrigger -and -not $HasExtractableText) { return [pscustomobject]@{ NeedsRewrite = $false; Reason = 'NoExtractableText' } }
    if ($isTrigger -and $HasExtractableText) { return [pscustomobject]@{ NeedsRewrite = $true; Reason = 'NeedsRewrite' } }
    return [pscustomobject]@{ NeedsRewrite = $false; Reason = 'AlreadyPlain' }
}

function ConvertFrom-HtmlCharacterReferences {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $decoded = [regex]::Replace($Text, '&#x([0-9A-Fa-f]+);', {
            param($match)
            [string]([char][Convert]::ToInt32($match.Groups[1].Value, 16))
        })
    $decoded = [regex]::Replace($decoded, '&#(\d+);', {
            param($match)
            [string]([char][int]$match.Groups[1].Value)
        })
    $decoded = $decoded.Replace('&lt;', '<').Replace('&gt;', '>').Replace('&quot;', '"').Replace('&apos;', "'").Replace('&nbsp;', ' ').Replace('&amp;', '&')
    return $decoded.Replace([string]([char]0x00A0), ' ')
}

function ConvertFrom-ClipboardHtmlBytes {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $decoded = $utf8.GetString($Bytes)
    $slice = $null
    $startMatch = [regex]::Match($decoded, 'StartFragment:(\d+)')
    $endMatch = [regex]::Match($decoded, 'EndFragment:(\d+)')
    if ($startMatch.Success -and $endMatch.Success) {
        $start = 0
        $end = 0
        $startOk = [int]::TryParse($startMatch.Groups[1].Value, [ref]$start)
        $endOk = [int]::TryParse($endMatch.Groups[1].Value, [ref]$end)
        if ($startOk -and $endOk -and $end -gt $start -and $start -ge 0 -and $end -le $Bytes.Length) {
            $slice = $utf8.GetString($Bytes, $start, $end - $start)
        }
    }
    if ([string]::IsNullOrEmpty($slice)) {
        $marker = [regex]::Match($decoded, '(?s)<!--StartFragment-->(.*)<!--EndFragment-->')
        if ($marker.Success) { $slice = $marker.Groups[1].Value }
    }
    if ([string]::IsNullOrEmpty($slice)) {
        $markup = $decoded.IndexOf('<')
        $slice = if ($markup -ge 0) { $decoded.Substring($markup) } else { $decoded }
    }
    $slice = [regex]::Replace($slice, '(?is)<script[^>]*>.*?</script>', '')
    $slice = [regex]::Replace($slice, '(?is)<style[^>]*>.*?</style>', '')
    $slice = [regex]::Replace($slice, '(?s)<[^>]+>', '')
    return (ConvertFrom-HtmlCharacterReferences -Text $slice).Trim()
}

function Select-ClipboardPlainText {
    param(
        [AllowNull()][string]$UnicodeText,
        [AllowNull()][byte[]]$HtmlFormatBytes,
        [AllowNull()][byte[]]$TextHtmlBytes
    )
    if ($null -ne $UnicodeText -and $UnicodeText.Trim().Length -gt 0) {
        return [pscustomobject]@{ Text = [string]$UnicodeText; Source = 'UnicodeText' }
    }
    foreach ($candidate in @($HtmlFormatBytes, $TextHtmlBytes)) {
        if ($null -eq $candidate) { continue }
        $derived = ConvertFrom-ClipboardHtmlBytes -Bytes $candidate
        if (-not [string]::IsNullOrWhiteSpace($derived)) {
            return [pscustomobject]@{ Text = $derived; Source = 'Html' }
        }
    }
    return [pscustomobject]@{ Text = $null; Source = 'None' }
}

function New-ClipboardRewriteResult {
    param(
        $Outcome,
        $Reason,
        $CharCount,
        $FormatsBefore,
        $FormatsAfter,
        $SourceProcess,
        $SequenceBefore,
        $SequenceAfter
    )
    [pscustomobject]@{
        Outcome         = [string]$Outcome
        Reason          = [string]$Reason
        CharCount       = [int]$CharCount
        FormatsBefore   = @($FormatsBefore)
        FormatsAfter    = @($FormatsAfter)
        SourceProcess   = [string]$SourceProcess
        SequenceBefore  = [int64]$SequenceBefore
        SequenceAfter   = [int64]$SequenceAfter
    }
}

function Reset-ClipboardRewriteLoopState {
    $script:PlainTextRewritePasses = New-Object System.Collections.Generic.List[object]
    $script:PlainTextSuppressUntil = $null
}

function Initialize-ClipboardPlainTextNative {
    if ($script:ClipboardPlainTextNativeReady) { return $true }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        if (-not ('ClipDiagCore.Native' -as [type])) {
            $source = @'
using System;
using System.Runtime.InteropServices;
namespace ClipDiagCore {
    public static class Native {
        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();
        [DllImport("user32.dll")]
        public static extern IntPtr GetClipboardOwner();
        [DllImport("user32.dll")]
        public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    }
}
'@
            Add-Type -TypeDefinition $source -ErrorAction Stop
        }
        $script:ClipboardPlainTextNativeReady = $true
        return $true
    }
    catch {
        $script:ClipboardPlainTextNativeReady = $false
        return $false
    }
}

function Get-ClipboardSequenceNumber {
    if (-not (Initialize-ClipboardPlainTextNative)) { return [uint32]0 }
    try { return [uint32][ClipDiagCore.Native]::GetClipboardSequenceNumber() }
    catch { return [uint32]0 }
}

function Get-ClipboardPlainTextSnapshot {
    $empty = [pscustomobject]@{
        Opened          = $false
        FormatNames     = @()
        UnicodeText     = $null
        HtmlFormatBytes = $null
        TextHtmlBytes   = $null
        SourceProcess   = ''
        Sequence        = [uint32]0
    }
    if (-not (Initialize-ClipboardPlainTextNative)) { return $empty }
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $data = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $data = [System.Windows.Forms.Clipboard]::GetDataObject()
            break
        }
        catch {
            if ($attempt -lt 10) { Start-Sleep -Milliseconds 50 }
        }
    }
    if ($null -eq $data) { return $empty }
    $formats = @($data.GetFormats())
    $unicode = $null
    try {
        if ($data.GetDataPresent([System.Windows.Forms.DataFormats]::UnicodeText)) {
            $unicode = [string]$data.GetData([System.Windows.Forms.DataFormats]::UnicodeText)
        }
    }
    catch { }
    $htmlBytes = $null
    $textHtmlBytes = $null
    foreach ($pair in @(
            @{ Name = 'HTML Format'; Target = 'html' },
            @{ Name = 'text/html'; Target = 'texthtml' }
        )) {
        try {
            if (-not $data.GetDataPresent($pair.Name)) { continue }
            $raw = $data.GetData($pair.Name)
            $asBytes = $null
            if ($raw -is [byte[]]) { $asBytes = $raw }
            elseif ($null -ne $raw) { $asBytes = $utf8.GetBytes([string]$raw) }
            if ($pair.Target -eq 'html') { $htmlBytes = $asBytes } else { $textHtmlBytes = $asBytes }
        }
        catch { }
    }
    $processName = ''
    $sequence = [uint32]0
    try {
        $sequence = [uint32][ClipDiagCore.Native]::GetClipboardSequenceNumber()
        $owner = [ClipDiagCore.Native]::GetClipboardOwner()
        $ownerProcessId = [uint32]0
        [void][ClipDiagCore.Native]::GetWindowThreadProcessId($owner, [ref]$ownerProcessId)
        if ($ownerProcessId -gt 0) {
            $processName = (Get-Process -Id ([int]$ownerProcessId) -ErrorAction Stop).ProcessName
        }
    }
    catch { }
    return [pscustomobject]@{
        Opened          = $true
        FormatNames     = $formats
        UnicodeText     = $unicode
        HtmlFormatBytes = $htmlBytes
        TextHtmlBytes   = $textHtmlBytes
        SourceProcess   = $processName
        Sequence        = $sequence
    }
}

function Set-ClipboardUnicodeOnly {
    param([AllowNull()][string]$Text)
    $failed = [pscustomobject]@{ UnicodeText = $null; Sequence = [uint32]0; FormatNames = @() }
    if (-not (Initialize-ClipboardPlainTextNative)) { return $failed }
    try {
        $obj = New-Object System.Windows.Forms.DataObject
        $obj.SetData([System.Windows.Forms.DataFormats]::UnicodeText, $Text)
        [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true, 10, 50)
    }
    catch {
        return $failed
    }
    $readBack = Get-ClipboardPlainTextSnapshot
    return [pscustomobject]@{
        UnicodeText = $readBack.UnicodeText
        Sequence    = $readBack.Sequence
        FormatNames = @($readBack.FormatNames)
    }
}

function Invoke-ClipboardPlainTextRewrite {
    param(
        [switch]$WhatIf,
        [scriptblock]$ReadSnapshot,
        [scriptblock]$WriteUnicodeText,
        [datetime]$Now
    )
    if ($Now -eq [datetime]::MinValue -or $PSBoundParameters.ContainsKey('Now') -eq $false) {
        if (-not $PSBoundParameters.ContainsKey('Now')) { $Now = Get-Date }
    }
    if ($null -eq $script:PlainTextRewritePasses) { Reset-ClipboardRewriteLoopState }
    if ($null -ne $script:PlainTextSuppressUntil -and $Now -lt $script:PlainTextSuppressUntil) {
        return New-ClipboardRewriteResult -Outcome 'FAIL' -Reason 'RewriteLoopSuppressed' -CharCount -1 -FormatsBefore @() -FormatsAfter @() -SourceProcess '' -SequenceBefore 0 -SequenceAfter 0
    }
    if ($null -eq $ReadSnapshot) { $ReadSnapshot = { Get-ClipboardPlainTextSnapshot } }
    $snap = & $ReadSnapshot
    if (-not $snap.Opened) {
        $sourceName = ''
        $sequence = [int64]0
        if ($null -ne $snap.SourceProcess) { $sourceName = [string]$snap.SourceProcess }
        if ($null -ne $snap.Sequence) { $sequence = [int64]$snap.Sequence }
        return New-ClipboardRewriteResult -Outcome 'FAIL' -Reason 'OpenFailed' -CharCount -1 -FormatsBefore @() -FormatsAfter @() -SourceProcess $sourceName -SequenceBefore $sequence -SequenceAfter $sequence
    }
    $selected = Select-ClipboardPlainText -UnicodeText $snap.UnicodeText -HtmlFormatBytes $snap.HtmlFormatBytes -TextHtmlBytes $snap.TextHtmlBytes
    $hasText = $null -ne $selected.Text
    $decision = Test-ClipboardNeedsPlainText -FormatNames @($snap.FormatNames) -HasExtractableText $hasText
    if (-not $decision.NeedsRewrite) {
        $outcome = if ($decision.Reason -eq 'NoExtractableText') { 'FAIL' } else { 'Skip' }
        $count = if ($decision.Reason -eq 'NoExtractableText') { 0 } else { -1 }
        return New-ClipboardRewriteResult -Outcome $outcome -Reason $decision.Reason -CharCount $count -FormatsBefore @($snap.FormatNames) -FormatsAfter @() -SourceProcess $snap.SourceProcess -SequenceBefore $snap.Sequence -SequenceAfter $snap.Sequence
    }
    if ($WhatIf) {
        return New-ClipboardRewriteResult -Outcome 'WhatIf' -Reason 'NeedsRewrite' -CharCount $selected.Text.Length -FormatsBefore @($snap.FormatNames) -FormatsAfter @() -SourceProcess $snap.SourceProcess -SequenceBefore $snap.Sequence -SequenceAfter $snap.Sequence
    }
    if ($null -eq $WriteUnicodeText) { $WriteUnicodeText = { param($Text) Set-ClipboardUnicodeOnly -Text $Text } }
    $written = & $WriteUnicodeText $selected.Text
    $matched = ($null -ne $written.UnicodeText -and $written.UnicodeText -ceq $selected.Text -and [int64]$written.Sequence -ne [int64]$snap.Sequence)
    if (-not $matched) {
        $written = & $WriteUnicodeText $selected.Text
        $matched = ($null -ne $written.UnicodeText -and $written.UnicodeText -ceq $selected.Text -and [int64]$written.Sequence -ne [int64]$snap.Sequence)
    }
    if (-not $matched) {
        return New-ClipboardRewriteResult -Outcome 'FAIL' -Reason 'ReadBackMismatch' -CharCount $selected.Text.Length -FormatsBefore @($snap.FormatNames) -FormatsAfter @($written.FormatNames) -SourceProcess $snap.SourceProcess -SequenceBefore $snap.Sequence -SequenceAfter $written.Sequence
    }
    $result = New-ClipboardRewriteResult -Outcome 'PASS' -Reason 'Rewritten' -CharCount $selected.Text.Length -FormatsBefore @($snap.FormatNames) -FormatsAfter @($written.FormatNames) -SourceProcess $snap.SourceProcess -SequenceBefore $snap.Sequence -SequenceAfter $written.Sequence
    $script:PlainTextRewritePasses.Add([pscustomobject]@{ Time = $Now; CharCount = $selected.Text.Length })
    $recent = @($script:PlainTextRewritePasses | Where-Object {
            $_.CharCount -eq $selected.Text.Length -and ($Now - $_.Time).TotalSeconds -ge 0 -and ($Now - $_.Time).TotalSeconds -le 2
        })
    if ($recent.Count -ge 3) {
        $script:PlainTextSuppressUntil = $Now.AddSeconds(10)
    }
    return $result
}

function Get-ClipboardRunMode {
    param(
        [bool]$PlainText,
        [bool]$Watch,
        [bool]$Fix,
        [bool]$ExportForCursor,
        [bool]$TerminalPaste,
        [bool]$BrowserTest,
        [bool]$BrowserPasteTest
    )
    $modes = New-Object System.Collections.Generic.List[string]
    if ($ExportForCursor) { $modes.Add('ExportForCursor') }
    if ($Watch) { $modes.Add('Watch') }
    if ($TerminalPaste) { $modes.Add('TerminalPaste') }
    if ($BrowserTest) { $modes.Add('BrowserTest') }
    if ($BrowserPasteTest) { $modes.Add('BrowserPasteTest') }
    if ($PlainText) { $modes.Add('PlainText') }
    if ($PlainText -and ($Fix -or $modes.Count -gt 1)) {
        return [pscustomobject]@{ Mode = 'PlainText'; ExitCode = 2 }
    }
    if ($modes.Count -gt 1) {
        return [pscustomobject]@{ Mode = $modes[0]; ExitCode = 2 }
    }
    if ($modes.Count -eq 1) {
        return [pscustomobject]@{ Mode = $modes[0]; ExitCode = 0 }
    }
    return [pscustomobject]@{ Mode = 'Diagnose'; ExitCode = 0 }
}

function Get-PlainTextSessionExitCode {
    param(
        [int]$FailCount,
        [int]$ErrorCount,
        [bool]$InvalidMode
    )
    if ($InvalidMode -or $ErrorCount -gt 0) { return 2 }
    if ($FailCount -gt 0) { return 1 }
    return 0
}

function New-PlainTextReport {
    param(
        [int]$Seconds,
        $Events,
        [int]$RewriteCount,
        [int]$FailCount,
        [int]$ErrorCount
    )
    [pscustomobject]@{
        mode         = 'PlainText'
        seconds      = $Seconds
        rewriteCount = $RewriteCount
        failCount    = $FailCount
        errorCount   = $ErrorCount
        events       = @($Events)
    }
}

function Format-PlainTextConsoleLine {
    param($Result)
    $before = @($Result.FormatsBefore) -join ', '
    $after = @($Result.FormatsAfter) -join ', '
    return "PASS rewrote clipboard chars=$($Result.CharCount) formats=$before -> $after source=$($Result.SourceProcess)"
}

function Get-ClipboardMutexName {
    param([Parameter(Mandatory = $true)][ValidateSet('Tray', 'Rewrite', 'PlainTextSession')][string]$Kind)
    switch ($Kind) {
        'Tray' { return 'Local\ClipboardDiagnosticsMvp.Tray' }
        'Rewrite' { return 'Local\ClipboardDiagnosticsMvp.Rewrite' }
        'PlainTextSession' { return 'Local\ClipboardDiagnosticsMvp.PlainTextSession' }
    }
    return $null
}

function Invoke-PlainTextObservation {
    param(
        $PreviousSequence,
        $CurrentSequence,
        [bool]$Paused,
        [bool]$RewriteLockHeld,
        [scriptblock]$Rewrite
    )
    if ([uint64]$PreviousSequence -eq [uint64]$CurrentSequence) { return $null }
    if ($Paused) {
        return [pscustomobject]@{ Outcome = 'Skip'; Reason = 'Paused'; Activity = $true }
    }
    if ($RewriteLockHeld) {
        return [pscustomobject]@{ Outcome = 'Dropped'; Reason = 'RewriteLockHeld'; Activity = $true }
    }
    $result = & $Rewrite
    if ($null -eq $result) {
        return [pscustomobject]@{ Outcome = 'Skip'; Reason = 'AlreadyPlain'; Activity = $true }
    }
    $result | Add-Member -NotePropertyName Activity -NotePropertyValue $true -Force
    return $result
}

function Get-StaRelaunchArguments {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )
    $rendered = @($Arguments | ForEach-Object {
            if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ }
        }) -join ' '
    $suffix = ''
    if (-not [string]::IsNullOrWhiteSpace($rendered)) { $suffix = ' ' + $rendered }
    return "-NoProfile -STA -ExecutionPolicy Bypass -File `"$ScriptPath`"$suffix"
}

function ConvertTo-ToastXmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function Get-ClipboardToastText {
    param(
        [string]$Level,
        [string]$Reason,
        [int]$CharCount
    )
    if ($Level -eq 'ERROR') {
        return [pscustomobject]@{
            Title = 'Clipboard diagnostics error'
            Body  = "Plain-text helper hit an error ($Reason). See the operational log."
        }
    }
    $title = 'Clipboard plain-text rewrite failed'
    if ($Reason -eq 'ReadBackMismatch') {
        $body = "Clipboard rewrite could not be verified ($Reason). Rich formats were not restored."
    }
    else {
        $body = "Could not rewrite the clipboard ($Reason). The clipboard was left unchanged. Characters available: $CharCount."
    }
    return [pscustomobject]@{
        Title = $title
        Body  = $body
    }
}

function ConvertTo-ToastXml {
    param(
        [string]$Title,
        [string]$Body
    )
    $safeTitle = ConvertTo-ToastXmlText -Text $Title
    $safeBody = ConvertTo-ToastXmlText -Text $Body
    return ('<toast><visual><binding template="ToastText02"><text id="1">{0}</text><text id="2">{1}</text></binding></visual></toast>' -f $safeTitle, $safeBody)
}

function Get-ClipboardToastLaunchArguments {
    param([Parameter(Mandatory = $true)][string]$TrayScriptPath)
    return "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScriptPath`""
}

function Get-ClipboardToastShortcutPath {
    Join-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') 'ClipboardDiagnosticsMvp.lnk'
}

function Set-ClipboardToastAppUserModelId {
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$AppUserModelId
    )
    if (-not ('ClipboardToastLink' -as [type])) {
        $source = @'
using System;
using System.Runtime.InteropServices;

public static class ClipboardToastLink {
    public static void SetAppId(string linkPath, string appId) {
        IPersistFile file = (IPersistFile)new CShellLink();
        file.Load(linkPath, 0);
        IPropertyStore store = (IPropertyStore)file;
        PropertyKey key = new PropertyKey();
        key.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
        key.pid = 5;
        PropVariant value = new PropVariant();
        value.SetString(appId);
        store.SetValue(ref key, ref value);
        store.Commit();
        file.Save(linkPath, true);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    private class CShellLink { }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
    private interface IPersistFile {
        void GetClassID(out Guid pClassID);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, bool fRemember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
        void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    private interface IPropertyStore {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PropertyKey {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PropVariant {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointer;
        public void SetString(string value) {
            vt = 31;
            pointer = Marshal.StringToCoTaskMemUni(value);
        }
    }
}
'@
        Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
    }
    [ClipboardToastLink]::SetAppId($LinkPath, $AppUserModelId)
}

function Send-ClipboardDefaultToast {
    param([Parameter(Mandatory = $true)][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
        throw 'Toast shortcut is unavailable because APPDATA is not set.'
    }
    $shortcutPath = Get-ClipboardToastShortcutPath
    $programs = Split-Path -Parent $shortcutPath
    if (-not (Test-Path -LiteralPath $programs)) {
        [void][System.IO.Directory]::CreateDirectory($programs)
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershellExe)) {
        $found = Get-Command powershell -ErrorAction SilentlyContinue
        if ($null -eq $found) {
            throw 'powershell.exe was not found for the toast shortcut.'
        }
        $powershellExe = $found.Source
    }
    $shortcut.TargetPath = $powershellExe
    $shortcut.Description = 'ClipboardDiagnosticsMvp.PlainText'
    $shortcut.Save()
    Set-ClipboardToastAppUserModelId -LinkPath $shortcutPath -AppUserModelId 'ClipboardDiagnosticsMvp.PlainText'
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime]
    $document = New-Object Windows.Data.Xml.Dom.XmlDocument
    $document.LoadXml($Xml)
    $notification = [Windows.UI.Notifications.ToastNotification]::new($document)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('ClipboardDiagnosticsMvp.PlainText').Show($notification)
}

function Write-ClipboardToastUnavailable {
    param([string]$Message)
    try {
        $directory = Join-Path (Get-ClipboardDiagnosticsRoot) 'logs'
        $logger = New-LoggingProvider -LogDirectory $directory -FileEnabled $true -EventLogEnabled $true
        $logger.Write(@{
                Level   = 'ERROR'
                EventId = 3002
                Mode    = 'Toast'
                Reason  = 'ToastUnavailable'
            })
    }
    catch {
        return
    }
}

function New-NotificationProvider {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Toast', 'Silent')]
        [string]$Kind,
        [bool]$ToastOnFail = $true,
        [scriptblock]$ToastSender,
        [scriptblock]$FailureLogger
    )
    if ($null -eq $FailureLogger) {
        $FailureLogger = { param($Message) Write-ClipboardToastUnavailable -Message $Message }
    }
    $provider = [pscustomobject]@{
        Kind           = $Kind
        ToastOnFail    = [bool]$ToastOnFail
        ToastSender    = $ToastSender
        FailureLogger  = $FailureLogger
        Sent           = New-Object 'System.Collections.Generic.List[pscustomobject]'
        ToastFailures  = 0
        Attempts       = 0
    }
    $provider | Add-Member -MemberType ScriptMethod -Name Send -Value {
        param($Level, $Title, $Message)
        if ($this.Kind -eq 'Silent') { return }
        if ($Level -eq 'PASS' -or $Level -eq 'INFO') { return }
        if (-not $this.ToastOnFail) { return }
        if ($Level -ne 'FAIL' -and $Level -ne 'ERROR') { return }
        $this.Attempts = [int]$this.Attempts + 1
        $xml = ConvertTo-ToastXml -Title $Title -Body $Message
        try {
            if ($null -eq $this.ToastSender) {
                Send-ClipboardDefaultToast -Xml $xml
            }
            else {
                & $this.ToastSender $xml
            }
            $this.Sent.Add([pscustomobject]@{
                    Level   = $Level
                    Title   = $Title
                    Message = $Message
                })
        }
        catch {
            if ([int]$this.ToastFailures -lt 1) {
                $this.ToastFailures = 1
                if ($null -ne $this.FailureLogger) {
                    & $this.FailureLogger $_.Exception.Message
                }
            }
        }
    }
    return $provider
}

function Get-ScheduledTaskExecutable {
    $root = [string]$env:SystemRoot
    $root = $root.TrimEnd('\', '/')
    return ($root + '\System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Get-ScheduledTaskActionArgument {
    param([Parameter(Mandatory = $true)][string]$TrayScriptPath)
    return "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TrayScriptPath`""
}

function Get-SchtasksCreateArguments {
    param([Parameter(Mandatory = $true)][string]$TrayScriptPath)
    $executable = Get-ScheduledTaskExecutable
    $action = Get-ScheduledTaskActionArgument -TrayScriptPath $TrayScriptPath
    return ('/Create /F /TN "\ClipboardDiagnosticsMvp\PlainTextTray" /SC ONLOGON /IT /RL LIMITED /TR "{0} {1}"' -f $executable, $action)
}

function Get-ClipboardStartupDescription {
    'Rewrites Chromium HTML clipboard copies to plain Unicode for local paste. Does not record clipboard text.'
}

function New-ClipboardStartupSpec {
    param([Parameter(Mandatory = $true)][string]$TrayScriptPath)
    $execute = Get-ScheduledTaskExecutable
    $argument = Get-ScheduledTaskActionArgument -TrayScriptPath $TrayScriptPath
    @{
        TaskName         = 'PlainTextTray'
        TaskPath         = '\ClipboardDiagnosticsMvp\'
        Description      = (Get-ClipboardStartupDescription)
        Execute          = $execute
        Argument         = $argument
        WorkingDirectory = (Split-Path -Parent $TrayScriptPath)
        ActionPath       = ($execute + ' ' + $argument)
        TrayScriptPath   = $TrayScriptPath
    }
}

function Invoke-ClipboardSchtasks {
    param([Parameter(Mandatory = $true)][string]$ArgumentLine)
    $executable = 'schtasks.exe'
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $candidate = ($env:SystemRoot.TrimEnd('\', '/') + '\System32\schtasks.exe')
        if (Test-Path -LiteralPath $candidate) { $executable = $candidate }
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $executable
    $startInfo.Arguments = $ArgumentLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $process.WaitForExit()
    return [int]$process.ExitCode
}

function Invoke-ClipboardScheduledTaskOperation {
    param($Operation, $Spec)
    $taskFullName = '\ClipboardDiagnosticsMvp\PlainTextTray'
    $moduleReady = $false
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $moduleReady = $true
    }
    catch {
        $moduleReady = $false
    }
    if ($moduleReady) {
        try {
            $userName = $env:USERNAME
            if ([string]::IsNullOrWhiteSpace($userName)) { $userName = $env:USER }
            if ($Operation -eq 'Install') {
                $action = New-ScheduledTaskAction -Execute $Spec.Execute -Argument $Spec.Argument -WorkingDirectory $Spec.WorkingDirectory
                $trigger = New-ScheduledTaskTrigger -AtLogOn
                $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
                $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
                Register-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description $Spec.Description -Force | Out-Null
                return [pscustomobject]@{ Ok = $true; Installed = $true; LastTaskResult = 0; ActionPath = $Spec.ActionPath }
            }
            if ($Operation -eq 'Uninstall') {
                Unregister-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath -Confirm:$false -ErrorAction Stop
                return [pscustomobject]@{ Ok = $true; Installed = $false; LastTaskResult = 0; ActionPath = $Spec.ActionPath }
            }
            $task = Get-ScheduledTask -TaskName $Spec.TaskName -TaskPath $Spec.TaskPath -ErrorAction Stop
            $info = $task | Get-ScheduledTaskInfo
            $last = 0
            if ($null -ne $info -and $null -ne $info.LastTaskResult) { $last = $info.LastTaskResult }
            return [pscustomobject]@{ Ok = $true; Installed = $true; LastTaskResult = $last; ActionPath = $Spec.ActionPath }
        }
        catch {
            $moduleReady = $false
        }
    }
    try {
        if ($Operation -eq 'Install') {
            $code = Invoke-ClipboardSchtasks -ArgumentLine (Get-SchtasksCreateArguments -TrayScriptPath $Spec.TrayScriptPath)
            return [pscustomobject]@{ Ok = ($code -eq 0); Installed = ($code -eq 0); LastTaskResult = $code; ActionPath = $Spec.ActionPath }
        }
        if ($Operation -eq 'Uninstall') {
            $code = Invoke-ClipboardSchtasks -ArgumentLine ('/Delete /F /TN "{0}"' -f $taskFullName)
            return [pscustomobject]@{ Ok = ($code -eq 0); Installed = $false; LastTaskResult = $code; ActionPath = $Spec.ActionPath }
        }
        $code = Invoke-ClipboardSchtasks -ArgumentLine ('/Query /TN "{0}"' -f $taskFullName)
        return [pscustomobject]@{ Ok = ($code -eq 0); Installed = ($code -eq 0); LastTaskResult = $code; ActionPath = $Spec.ActionPath }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Installed = $false; LastTaskResult = 1; ActionPath = $Spec.ActionPath }
    }
}

function Get-StartupProvider {
    param(
        [Parameter(Mandatory = $true)][string]$TrayScriptPath,
        [scriptblock]$TaskBackend
    )
    $spec = New-ClipboardStartupSpec -TrayScriptPath $TrayScriptPath
    $provider = [pscustomobject]@{
        Id          = 'ScheduledTask'
        Managed     = $false
        TaskPath    = '\ClipboardDiagnosticsMvp\'
        TaskName    = 'PlainTextTray'
        Spec        = $spec
        TaskBackend = $TaskBackend
    }
    $provider | Add-Member -MemberType ScriptMethod -Name InvokeBackend -Value {
        param([string]$Operation)
        if ($null -ne $this.TaskBackend) {
            return (& $this.TaskBackend $Operation $this.Spec)
        }
        return (Invoke-ClipboardScheduledTaskOperation -Operation $Operation -Spec $this.Spec)
    }
    $provider | Add-Member -MemberType ScriptMethod -Name Install -Value {
        $this.InvokeBackend('Install')
    }
    $provider | Add-Member -MemberType ScriptMethod -Name Uninstall -Value {
        $this.InvokeBackend('Uninstall')
    }
    $provider | Add-Member -MemberType ScriptMethod -Name Test -Value {
        $queried = $this.InvokeBackend('Query')
        return [bool]$queried.Installed
    }
    $provider | Add-Member -MemberType ScriptMethod -Name GetStatus -Value {
        $queried = $this.InvokeBackend('Query')
        $installed = $false
        $last = $null
        $actionPath = $this.Spec.ActionPath
        if ($null -ne $queried) {
            if ($null -ne $queried.Installed) { $installed = [bool]$queried.Installed }
            $last = $queried.LastTaskResult
            if ($null -ne $queried.ActionPath) { $actionPath = $queried.ActionPath }
        }
        [pscustomobject]@{
            Installed      = $installed
            Managed        = $false
            TaskPath       = $this.TaskPath
            TaskName       = $this.TaskName
            LastTaskResult = $last
            ActionPath     = $actionPath
        }
    }
    return $provider
}

function Get-ClipboardTrayTooltip {
    param([bool]$Paused)
    if ($Paused) { return 'Clipboard diagnostics: Paused' }
    return 'Clipboard diagnostics: Running'
}

function Format-ClipboardHealthInstant {
    param($Value)
    if ($null -eq $Value) { return 'never' }
    $instant = [datetime]$Value
    if ($instant -eq [datetime]::MinValue) { return 'never' }
    if ($instant.Kind -eq [System.DateTimeKind]::Utc) { $instant = $instant.ToLocalTime() }
    return $instant.ToString('yyyy-MM-dd HH:mm:ss')
}

function Get-ClipboardHealthRows {
    param(
        [bool]$Paused,
        [string]$ListenerMode,
        [int]$PollIntervalMs,
        [bool]$StartWithWindows,
        [AllowEmptyString()][string]$TaskAction,
        $SessionRewrites,
        $TotalRewrites,
        $LastActivityUtc,
        $LastRewriteUtc,
        $LastOutcome,
        $LastReason,
        $LastCharCount,
        $LastOwnerName,
        [bool]$EventLogReady,
        [bool]$PolicyPresent,
        [string]$ToolVersion,
        [string]$CoreVersion
    )
    $listener = 'Clipboard listener'
    if ($ListenerMode -eq 'Poll') { $listener = "Polling every $PollIntervalMs ms" }
    $action = 'not installed'
    if (-not [string]::IsNullOrWhiteSpace($TaskAction)) { $action = $TaskAction }
    $resultText = 'none'
    if ($null -ne $LastOutcome -and -not [string]::IsNullOrWhiteSpace([string]$LastOutcome)) {
        $resultText = ('{0} {1}' -f $LastOutcome, $LastReason).Trim()
    }
    $countText = 'n/a'
    if ($null -ne $LastCharCount -and -not [string]::IsNullOrWhiteSpace([string]$LastCharCount)) {
        $countText = [string]$LastCharCount
    }
    $ownerText = 'n/a'
    if ($null -ne $LastOwnerName -and -not [string]::IsNullOrWhiteSpace([string]$LastOwnerName)) {
        $ownerText = [string]$LastOwnerName
    }
    [ordered]@{
        Status                 = $(if ($Paused) { 'Paused' } else { 'Running' })
        Listener               = $listener
        'Start with Windows'   = $(if ($StartWithWindows) { 'Yes' } else { 'No' })
        Task                   = '\ClipboardDiagnosticsMvp\PlainTextTray'
        'Task action'          = $action
        'Session rewrites'     = [string]$SessionRewrites
        'Total rewrites'       = [string]$TotalRewrites
        'Last activity'        = (Format-ClipboardHealthInstant -Value $LastActivityUtc)
        'Last rewrite'         = (Format-ClipboardHealthInstant -Value $LastRewriteUtc)
        'Last result'          = $resultText
        'Last character count' = $countText
        'Last source process'  = $ownerText
        'Event Log'            = $(if ($EventLogReady) { 'registered' } else { 'not registered' })
        Policy                 = $(if ($PolicyPresent) { 'present (not applied)' } else { 'none' })
        'Log folder'           = '%LOCALAPPDATA%\clipboard_diagnostics_mvp\logs'
        Versions               = "clipboard-test.ps1 $ToolVersion; ClipboardCoreVersion $CoreVersion"
    }
}

function Sync-StartWithWindowsSetting {
    param($SettingsResult, [bool]$TaskInstalled)
    $settings = $SettingsResult.Settings
    if ($SettingsResult.Unsupported) {
        return [pscustomobject]@{ Changed = $false; Settings = $settings }
    }
    $current = $false
    if ($null -ne $settings -and $null -ne $settings.startWithWindows) {
        $current = [bool]$settings.startWithWindows
    }
    if ($current -eq $TaskInstalled) {
        return [pscustomobject]@{ Changed = $false; Settings = $settings }
    }
    $settings.startWithWindows = [bool]$TaskInstalled
    return [pscustomobject]@{ Changed = $true; Settings = $settings }
}

function ConvertFrom-StartupMethodResult {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) { return $null }
        return $Value[0]
    }
    return $Value
}

function Invoke-StartupToggle {
    param($Provider, $SettingsResult, [bool]$Enable, [string]$Root)
    $method = if ($Enable) { $Provider.Install } else { $Provider.Uninstall }
    $raw = $method.Invoke()
    $result = ConvertFrom-StartupMethodResult -Value $raw
    $ok = $false
    if ($null -ne $result -and $null -ne $result.PSObject.Properties['Ok']) {
        $ok = [bool]$result.Ok
    }
    if (-not $ok) {
        return [pscustomobject]@{ ExitCode = 2; TaskResult = 'error'; Saved = $false }
    }
    $taskResult = if ($Enable) { 'installed' } else { 'removed' }
    if ($SettingsResult.Unsupported) {
        return [pscustomobject]@{ ExitCode = 2; TaskResult = $taskResult; Saved = $false }
    }
    $SettingsResult.Settings.startWithWindows = [bool]$Enable
    $saved = Save-ClipboardDiagnosticsSettings -Settings $SettingsResult.Settings -Root $Root
    if ($saved) {
        $logDirectory = Join-Path $Root 'logs'
        $logger = New-LoggingProvider -LogDirectory $logDirectory -FileEnabled $true -EventLogEnabled $true
        $eventId = if ($Enable) { 1104 } else { 1105 }
        $reason = if ($Enable) { 'StartupInstalled' } else { 'StartupRemoved' }
        $logger.Write(@{
                Level   = 'INFO'
                EventId = $eventId
                Mode    = 'Tray'
                Reason  = $reason
            })
    }
    return [pscustomobject]@{ ExitCode = 0; TaskResult = $taskResult; Saved = [bool]$saved }
}
