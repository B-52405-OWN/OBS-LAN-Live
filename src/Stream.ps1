[CmdletBinding()]
param([ValidateSet('Start', 'Stop', 'Status', 'Firewall')][string]$Action = 'Status')

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$settings = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'config\local.json') | ConvertFrom-Json
$runtimeDir = Join-Path $projectRoot 'dev\artifacts\runtime'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
$pidPath = Join-Path $runtimeDir 'mediamtx.json'
$mediaExe = Join-Path $projectRoot 'vendor\mediamtx\mediamtx.exe'
$mediaConfig = Join-Path $projectRoot 'config\mediamtx.yml'
. (Join-Path $PSScriptRoot 'Obs.ps1')
$socket = $null
$startedMedia = $null
$previousProfile = $null
$previousCollection = $null
$didSwitch = $false
$lockKey = (Get-ObsHash $projectRoot).Replace('/', '_').Replace('+', '_')
$mutex = New-Object System.Threading.Mutex($false, "Local\Stream-$lockKey")
$locked = $false

function Get-ProjectMedia {
    if (-not (Test-Path -LiteralPath $pidPath)) { return $null }
    $state = Get-Content -Raw -LiteralPath $pidPath | ConvertFrom-Json
    $process = Get-Process -Id $state.processId -ErrorAction SilentlyContinue
    if ($process -and $process.Path -eq $mediaExe -and $process.StartTime.ToUniversalTime().ToString('o') -eq $state.startedUtc) { return $process }
    return $null
}

function Test-ProjectService {
    param($Service)
    return ($Service.streamServiceType -eq 'whip_custom' -and $Service.streamServiceSettings.server -eq $settings.whipUrl)
}

try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another Stream command is running. Retry after it finishes.' }
    if ($Action -eq 'Firewall') {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Windows administrator rights are required for firewall configuration.' }
        foreach ($entry in @(@{name='Stream-MediaMTX-Web';protocol='TCP';port=8889}, @{name='Stream-MediaMTX-Media';protocol='TCP';port=8189})) {
            $existing = Get-NetFirewallRule -Name $entry.name -ErrorAction SilentlyContinue
            if ($existing) { Remove-NetFirewallRule -Name $entry.name }
            New-NetFirewallRule -Name $entry.name -DisplayName $entry.name -Direction Inbound -Action Allow -Enabled True -Profile Any -Program $mediaExe -Protocol $entry.protocol -LocalPort $entry.port -LocalAddress $settings.lanAddress -RemoteAddress $settings.lanSubnet -InterfaceType Wired | Out-Null
        }
        @{time=(Get-Date).ToString('o');success=$true;localAddress=$settings.lanAddress;remoteSubnet=$settings.lanSubnet;ports=@('TCP/8889','TCP/8189')} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeDir 'firewall-result.json') -Encoding UTF8
        Write-Output 'LAN-only firewall rules installed.'
        return
    }

    $mediaProcess = Get-ProjectMedia
    if ($Action -eq 'Status') {
        $obsState = $null
        if (Get-Process obs64 -ErrorAction SilentlyContinue) {
            $socket = Open-ObsSocket
            $obsState = Invoke-ObsRequest $socket 'GetStreamStatus'
        }
        @{mediaProcessId= $(if ($mediaProcess) {$mediaProcess.Id} else {$null});obs=$obsState;watchUrl=$settings.watchUrl} | ConvertTo-Json -Depth 5
        return
    }

    if ($Action -eq 'Stop') {
        if (Get-Process obs64 -ErrorAction SilentlyContinue) {
            $socket = Open-ObsSocket
            $status = Invoke-ObsRequest $socket 'GetStreamStatus'
            $service = Invoke-ObsRequest $socket 'GetStreamServiceSettings'
            if ($status.outputActive -and (Test-ProjectService $service)) {
                Invoke-ObsRequest $socket 'StopStream' | Out-Null
                $deadline = (Get-Date).AddSeconds(15)
                do {
                    Start-Sleep -Milliseconds 250
                    $status = Invoke-ObsRequest $socket 'GetStreamStatus'
                } while ($status.outputActive -and (Get-Date) -lt $deadline)
                if ($status.outputActive) { throw 'OBS has not stopped streaming; the media server is left running.' }
            }
        }
        if ($mediaProcess) {
            Stop-Process -Id $mediaProcess.Id
            $mediaProcess.WaitForExit(5000) | Out-Null
            if (-not $mediaProcess.HasExited) { throw 'MediaMTX did not exit.' }
            Remove-Item -LiteralPath $pidPath -ErrorAction SilentlyContinue
        }
        Write-Output 'LAN stream stopped. OBS remains open.'
        return
    }

    if (-not (Test-Path -LiteralPath $mediaExe)) { throw 'MediaMTX executable is missing; see vendor/mediamtx/SOURCE.md.' }
    $lanIP = Get-NetIPAddress -AddressFamily IPv4 -IPAddress $settings.lanAddress -ErrorAction SilentlyContinue
    if (-not $lanIP) { throw "LAN address $($settings.lanAddress) is not present; update config before starting." }
    if (-not (Get-Process obs64 -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $settings.obsExecutable -WorkingDirectory (Split-Path -Parent $settings.obsExecutable) -ArgumentList '--profile "LAN Stream" --collection "LAN Stream"' | Out-Null
        $deadline = (Get-Date).AddSeconds(25)
        do {
            try { $socket = Open-ObsSocket } catch { if ((Get-Date) -ge $deadline) { throw }; Start-Sleep -Milliseconds 500 }
        } until ($socket)
    } else { $socket = Open-ObsSocket }

    $streamStatus = Invoke-ObsRequest $socket 'GetStreamStatus'
    $profiles = Invoke-ObsRequest $socket 'GetProfileList'
    $collections = Invoke-ObsRequest $socket 'GetSceneCollectionList'
    $service = Invoke-ObsRequest $socket 'GetStreamServiceSettings'
    if ($streamStatus.outputActive) {
        if ($profiles.currentProfileName -eq $settings.obsProfile -and (Test-ProjectService $service) -and $mediaProcess) {
            Assert-ObsWhipAudioConfiguration $socket
            Write-Output "Already streaming: $($settings.watchUrl)"
            return
        }
        throw 'OBS is already streaming. Stop its current stream before switching.'
    }
    $record = Invoke-ObsRequest $socket 'GetRecordStatus'
    try { $replay = Invoke-ObsRequest $socket 'GetReplayBufferStatus' }
    catch {
        if ($_.Exception.Data['ObsCode'] -eq 604) { $replay = @{outputActive=$false} }
        else { throw }
    }
    if ($record.outputActive -or $replay.outputActive) { throw 'OBS is recording or using replay buffer. Stop it before switching profiles.' }
    $previousProfile = $profiles.currentProfileName
    $previousCollection = $collections.currentSceneCollectionName
    if ($previousProfile -ne $settings.obsProfile) {
        Invoke-ObsRequest $socket 'SetCurrentProfile' @{profileName=$settings.obsProfile} | Out-Null
        $didSwitch = $true
    }
    if ($previousCollection -ne $settings.obsCollection) {
        Invoke-ObsRequest $socket 'SetCurrentSceneCollection' @{sceneCollectionName=$settings.obsCollection} | Out-Null
        $didSwitch = $true
    }
    $service = Invoke-ObsRequest $socket 'GetStreamServiceSettings'
    if (-not (Test-ProjectService $service)) { throw 'LAN Stream profile does not contain the expected WHIP endpoint.' }
    Assert-ObsWhipAudioConfiguration $socket

    if (-not $mediaProcess) {
        $conflicts = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object {$_.LocalPort -in 8189,8889,9997})
        $udpConflict = @(Get-NetUDPEndpoint -LocalPort 8189 -ErrorAction SilentlyContinue | Where-Object {$_.LocalAddress -in '127.0.0.1','0.0.0.0','::'})
        if ($conflicts.Count -or $udpConflict.Count) { throw 'A required TCP port (8189, 8889, 9997) or loopback UDP port 8189 is already in use.' }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
        $startedMedia = Start-Process -FilePath $mediaExe -ArgumentList ('"' + $mediaConfig + '"') -WorkingDirectory $runtimeDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $runtimeDir "mediamtx-$stamp.jsonl") -RedirectStandardError (Join-Path $runtimeDir "mediamtx-$stamp.stderr.log") -PassThru
        @{processId=$startedMedia.Id;startedUtc=$startedMedia.StartTime.ToUniversalTime().ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $pidPath -Encoding UTF8
        $deadline = (Get-Date).AddSeconds(10)
        do {
            if ($startedMedia.HasExited) { throw 'MediaMTX exited during startup; inspect dev/artifacts/runtime.' }
            try { $null = Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 1; break }
            catch { if ((Get-Date) -ge $deadline) { throw }; Start-Sleep -Milliseconds 250 }
        } while ($true)
    }
    Invoke-ObsRequest $socket 'StartStream' | Out-Null
    $deadline = (Get-Date).AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 500
        $status = Invoke-ObsRequest $socket 'GetStreamStatus'
        $paths = Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/paths/list' -TimeoutSec 2
        $live = $paths.items | Where-Object {$_.name -eq 'live' -and $_.ready}
    } until (($status.outputActive -and $live) -or (Get-Date) -ge $deadline)
    if (-not $status.outputActive -or -not $live) { throw 'OBS did not publish the live stream within 20 seconds.' }
    Write-Output "Streaming: $($settings.watchUrl)"
} catch {
    $failure = $_
    if ($Action -eq 'Start') {
        if ($socket) {
            try {
                $service = Invoke-ObsRequest $socket 'GetStreamServiceSettings'
                $active = Invoke-ObsRequest $socket 'GetStreamStatus'
                if ($active.outputActive -and (Test-ProjectService $service) -and $startedMedia) { Invoke-ObsRequest $socket 'StopStream' | Out-Null }
                if ($didSwitch) {
                    if ($previousProfile) { Invoke-ObsRequest $socket 'SetCurrentProfile' @{profileName=$previousProfile} | Out-Null }
                    if ($previousCollection) { Invoke-ObsRequest $socket 'SetCurrentSceneCollection' @{sceneCollectionName=$previousCollection} | Out-Null }
                }
            } catch { $_ | Out-String | Add-Content -LiteralPath (Join-Path $runtimeDir 'cleanup-errors.log') }
        }
        if ($startedMedia -and -not $startedMedia.HasExited) { Stop-Process -Id $startedMedia.Id -ErrorAction SilentlyContinue }
    }
    @{time=(Get-Date).ToString('o');operation=$Action;type=$failure.Exception.GetType().FullName;message=$failure.Exception.Message;stack=$failure.ScriptStackTrace;details=$failure.ToString()} | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $runtimeDir 'errors.jsonl') -Encoding UTF8
    if ($Action -eq 'Firewall') {
        @{time=(Get-Date).ToString('o');success=$false;message=$failure.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $runtimeDir 'firewall-result.json') -Encoding UTF8
    }
    Write-Error $failure.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    Close-ObsSocket $socket
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
