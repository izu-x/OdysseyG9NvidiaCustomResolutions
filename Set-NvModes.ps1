<#
.SYNOPSIS
  Persists custom resolutions in NVIDIA's NV_Modes registry value.

.DESCRIPTION
  Reads the live NV_Modes value, strips entries previously added by this
  tool, re-appends the customs listed in custom-resolutions.txt, and writes
  back to whichever class subkey is currently active. Auto-backs up before
  any change. Idempotent: re-running with no changes is a no-op (safe under
  Task Scheduler).

.EXAMPLE
  .\Set-NvModes.ps1                  # interactive menu
  .\Set-NvModes.ps1 -Add 2304x1440
  .\Set-NvModes.ps1 -Remove 2304x1440
  .\Set-NvModes.ps1 -List
  .\Set-NvModes.ps1 -Apply           # what the scheduled task runs
  .\Set-NvModes.ps1 -Install         # register scheduled task
  .\Set-NvModes.ps1 -Uninstall       # remove scheduled task
  .\Set-NvModes.ps1 -Restore .\backups\NV_Modes_20260428-150000.reg
#>

[CmdletBinding(DefaultParameterSetName='Menu')]
param(
    [Parameter(ParameterSetName='Apply')]              [switch]$Apply,
    [Parameter(ParameterSetName='List')]               [switch]$List,
    [Parameter(ParameterSetName='Add', Mandatory)]     [string]$Add,
    [Parameter(ParameterSetName='Remove', Mandatory)]  [string]$Remove,
    [Parameter(ParameterSetName='Backup')]             [switch]$Backup,
    [Parameter(ParameterSetName='Restore', Mandatory)] [string]$Restore,
    [Parameter(ParameterSetName='Install')]            [switch]$Install,
    [Parameter(ParameterSetName='Uninstall')]          [switch]$Uninstall,

    [string]$GpuMatch    = '*NVIDIA*',
    [string]$ConfigPath,
    [string]$BackupDir,
    [int]   $KeepBackups = 20,
    [string]$TaskName    = 'NV_Modes Persistence'
)

$ErrorActionPreference = 'Stop'

$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot }
              elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
              else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptRoot 'custom-resolutions.txt' }
if (-not $BackupDir)  { $BackupDir  = Join-Path $ScriptRoot 'backups' }
$ClassPath   = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$DefaultMask = '1FFF'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (([Security.Principal.WindowsPrincipal] $id).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) { return $true }
    # SYSTEM (S-1-5-18) also has full registry access - task runs as SYSTEM
    if ($id.User.Value -eq 'S-1-5-18') { return $true }
    $false
}

function Get-NvAdapter {
    $found = Get-ChildItem $ClassPath -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.DriverDesc -like $GpuMatch) {
                [pscustomobject]@{
                    Path       = $_.PSPath
                    DriverDesc = $p.DriverDesc
                    RegPath    = $_.Name   # HKEY_LOCAL_MACHINE\... form for reg.exe
                }
            }
        }
    if (-not $found) {
        throw "No NVIDIA adapter subkey under $ClassPath (run as Administrator? GpuMatch='$GpuMatch')"
    }
    $found
}

function Get-NvModesValue($adapter) {
    (Get-ItemProperty -Path $adapter.Path -Name NV_Modes -ErrorAction SilentlyContinue).NV_Modes
}

function Read-CustomEntries {
    if (-not (Test-Path $ConfigPath)) { return @() }
    ,@(Get-Content $ConfigPath |
        ForEach-Object { $_.Trim() } |
        Where-Object   { $_ -and -not $_.StartsWith('#') })
}

function Format-CustomEntry([string]$entry) {
    $e = $entry.Trim()
    if ($e -match '^(\d+)x(\d+)$') {
        return "$($Matches[1])x$($Matches[2])x8,16,32,64=$DefaultMask"
    }
    if ($e -match '^\d+x\d+x8,16,32,64=[0-9A-Fa-f]+$') { return $e }
    throw "Invalid resolution: '$entry'. Use 'WxH' or 'WxHx8,16,32,64=MASK'."
}

function Remove-CustomFromString([string]$nvModes, [string[]]$customs) {
    foreach ($c in $customs) {
        $token = Format-CustomEntry $c
        $pat   = '\s*' + [regex]::Escape($token) + ';?'
        $nvModes = [regex]::Replace($nvModes, $pat, '')
    }
    $nvModes.Trim()
}

function Add-CustomToString([string]$nvModes, [string[]]$customs) {
    $tail = ($customs | ForEach-Object { Format-CustomEntry $_ }) -join '; '
    if (-not $tail) { return $nvModes }
    if ($nvModes -and -not $nvModes.TrimEnd().EndsWith(';')) { $nvModes = "$nvModes;" }
    "$nvModes $tail;".Trim()
}

function New-NvModesBackup($adapter) {
    if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $file  = Join-Path $BackupDir "NV_Modes_$stamp.reg"
    & reg.exe export $adapter.RegPath $file /y | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "reg.exe export failed for $($adapter.RegPath)" }

    Get-ChildItem $BackupDir -Filter 'NV_Modes_*.reg' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip $KeepBackups |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $file
}

function Invoke-Apply {
    if (-not (Test-Admin)) { throw 'Run PowerShell as Administrator.' }
    $adapters = Get-NvAdapter
    $customs  = Read-CustomEntries
    $changed  = $false

    foreach ($a in $adapters) {
        $current = Get-NvModesValue $a
        if (-not $current) {
            Write-Warning "$($a.DriverDesc): NV_Modes not set yet - open NVCP once, then re-run."
            continue
        }
        $stripped = Remove-CustomFromString $current $customs
        $final    = Add-CustomToString $stripped $customs

        if ($final -eq $current) {
            Write-Host "$($a.DriverDesc): already current - skipped."
            continue
        }
        $bk = New-NvModesBackup $a
        Set-ItemProperty -Path $a.Path -Name 'NV_Modes' -Value $final -Type String
        Write-Host "$($a.DriverDesc): updated. Backup: $bk"
        $changed = $true
    }
    if ($changed) {
        Write-Host "`nRestart display driver: Win+Ctrl+Shift+B (or reboot)."
    }
}

function Invoke-List {
    $adapters = Get-NvAdapter
    foreach ($a in $adapters) {
        Write-Host "`n=== $($a.DriverDesc) ==="
        $v = Get-NvModesValue $a
        if ($v) {
            $v -split ';' | Where-Object { $_.Trim() } |
                ForEach-Object { '  ' + $_.Trim() }
        } else {
            Write-Host '  (NV_Modes not set)'
        }
    }
    Write-Host "`n=== Configured customs ($ConfigPath) ==="
    $cs = Read-CustomEntries
    if ($cs) { $cs | ForEach-Object { "  $_" } } else { Write-Host '  (empty)' }
}

function Invoke-Add([string]$entry) {
    $token   = Format-CustomEntry $entry
    $existing = Read-CustomEntries
    $already = $existing | ForEach-Object {
        try { Format-CustomEntry $_ } catch { $null }
    }
    if ($already -contains $token) {
        Write-Host "Already in config: $token"
    } else {
        if (-not (Test-Path $ConfigPath)) { New-Item -ItemType File -Path $ConfigPath | Out-Null }
        Add-Content -Path $ConfigPath -Value $token
        Write-Host "Added: $token"
    }
    Invoke-Apply
}

function Invoke-Remove([string]$entry) {
    if (-not (Test-Path $ConfigPath)) { Write-Host 'No config file.'; return }
    $key = if ($entry -match '^(\d+x\d+)') { $Matches[1] } else { $entry.Trim() }
    $kept = Get-Content $ConfigPath | Where-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return $true }
        return ($line -notmatch ('^' + [regex]::Escape($key) + '(x|=|$)'))
    }
    Set-Content -Path $ConfigPath -Value $kept
    Write-Host "Removed entries matching: $key"
    Invoke-Apply
}

function Invoke-Restore([string]$file) {
    if (-not (Test-Admin))      { throw 'Run as Administrator.' }
    if (-not (Test-Path $file)) { throw "Backup not found: $file" }
    & reg.exe import $file
    if ($LASTEXITCODE -ne 0) { throw 'reg.exe import failed.' }
    Write-Host 'Restored. Restart driver: Win+Ctrl+Shift+B'
}

function Invoke-Install {
    if (-not (Test-Admin)) { throw 'Run as Administrator.' }
    $scriptPath = (Resolve-Path $PSCommandPath).Path
    if ($scriptPath -like '*Downloads*') {
        Write-Warning "Script is under Downloads - Task Scheduler stores absolute paths. Move to a stable location (e.g. C:\Tools\NvModes\) before installing."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$scriptPath`" -Apply"

    $atStartup = New-ScheduledTaskTrigger -AtStartup

    $sessionClass = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler
    $atUnlock = New-CimInstance -CimClass $sessionClass -ClientOnly `
        -Property @{ StateChange = 8 }   # 8 = SessionUnlock

    $eventClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler
    $displayQuery = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Display''] and (EventID=1)]]</Select></Query></QueryList>'
    $atDisplayEvent = New-CimInstance -CimClass $eventClass -ClientOnly `
        -Property @{ Enabled = $true; Subscription = $displayQuery }

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
        -LogonType ServiceAccount -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName $TaskName `
        -Action $action `
        -Trigger @($atStartup, $atUnlock, $atDisplayEvent) `
        -Principal $principal `
        -Settings $settings `
        -Description "Re-applies NV_Modes after boot, unlock, and Display driver re-init. Auto-generated by Set-NvModes.ps1." `
        -Force | Out-Null

    Write-Host "Scheduled task '$TaskName' installed."
    Write-Host "Triggers: at startup, on unlock, on Display event ID 1."
    Write-Host "Action:   powershell -File `"$scriptPath`" -Apply"
    Write-Host "Verify:   Get-ScheduledTask -TaskName '$TaskName' | Get-ScheduledTaskInfo"
}

function Invoke-Uninstall {
    if (-not (Test-Admin)) { throw 'Run as Administrator.' }
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $existing) {
        Write-Host "No scheduled task named '$TaskName'."
        return
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed."
}

function Show-Menu {
    while ($true) {
        Write-Host "`n=== NV_Modes Persistence ==="
        Write-Host ' 1) List current resolutions + config'
        Write-Host ' 2) Add custom resolution'
        Write-Host ' 3) Remove custom resolution'
        Write-Host ' 4) Apply (re-write NV_Modes from config)'
        Write-Host ' 5) Backup current NV_Modes'
        Write-Host ' 6) Restore from backup'
        Write-Host ' 7) Install scheduled task (auto-apply after driver updates)'
        Write-Host ' 8) Uninstall scheduled task'
        Write-Host ' 0) Exit'
        $c = Read-Host 'Choice'
        try {
            switch ($c) {
                '1' { Invoke-List }
                '2' {
                    $r = Read-Host 'Resolution (e.g. 2304x1440 or 2304x1440x8,16,32,64=1FFF)'
                    if ($r) { Invoke-Add $r }
                }
                '3' {
                    $cs = Read-CustomEntries
                    if (-not $cs) { Write-Host 'No customs configured.'; break }
                    Write-Host "`nConfigured customs:"
                    for ($i = 0; $i -lt $cs.Count; $i++) {
                        Write-Host (' {0}) {1}' -f ($i + 1), $cs[$i])
                    }
                    Write-Host ' m) Enter manually'
                    Write-Host ' 0) Cancel'
                    $r = Read-Host 'Choice'
                    if ($r -eq '0' -or -not $r) { break }
                    elseif ($r -eq 'm' -or $r -eq 'M') {
                        $manual = Read-Host 'Resolution to remove (WxH)'
                        if ($manual) { Invoke-Remove $manual }
                    }
                    elseif ($r -match '^\d+$' -and [int]$r -ge 1 -and [int]$r -le $cs.Count) {
                        Invoke-Remove $cs[[int]$r - 1]
                    }
                    else { Write-Host 'Invalid choice.' }
                }
                '4' { Invoke-Apply }
                '5' {
                    if (-not (Test-Admin)) { Write-Warning 'Need Administrator.'; continue }
                    Get-NvAdapter | ForEach-Object {
                        Write-Host "Backup: $(New-NvModesBackup $_)"
                    }
                }
                '6' {
                    $f = Read-Host 'Path to .reg backup'
                    if ($f) { Invoke-Restore $f }
                }
                '7' { Invoke-Install }
                '8' { Invoke-Uninstall }
                '0' { return }
                default { Write-Host 'Invalid.' }
            }
        } catch {
            Write-Warning $_.Exception.Message
        }
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Apply'   { Invoke-Apply }
    'List'    { Invoke-List }
    'Add'     { Invoke-Add    $Add }
    'Remove'  { Invoke-Remove $Remove }
    'Backup'  {
        if (-not (Test-Admin)) { throw 'Run as Administrator.' }
        Get-NvAdapter | ForEach-Object {
            Write-Host "Backup: $(New-NvModesBackup $_)"
        }
    }
    'Restore'   { Invoke-Restore $Restore }
    'Install'   { Invoke-Install }
    'Uninstall' { Invoke-Uninstall }
    'Menu'      { Show-Menu }
}
