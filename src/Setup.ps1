[CmdletBinding()]
param([switch]$PrepareOnly)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$artifacts = Join-Path $projectRoot 'dev\artifacts'
$runtimeDir = Join-Path $artifacts 'runtime'
New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
. (Join-Path $PSScriptRoot 'Obs.ps1')
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Install-MediaMtx {
    $vendor = Join-Path $projectRoot 'vendor\mediamtx'
    $release = Get-Content -Raw -LiteralPath (Join-Path $vendor 'release.json') | ConvertFrom-Json
    $exe = Join-Path $vendor 'mediamtx.exe'
    if (Test-Path -LiteralPath $exe) {
        if ((Get-FileHash -LiteralPath $exe).Hash -ne $release.executableSha256) {
            throw 'Existing mediamtx.exe differs from the pinned release. Stop the live stream and move that binary aside before rerunning setup.'
        }
        Write-Output 'MediaMTX is ready.'
        return
    }
    $cache = Join-Path $projectRoot 'dev\cache'
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $archive = Join-Path $cache ([uri]$release.url).Segments[-1]
    $download = $archive + '.download'
    $staged = $exe + '.staged'
    try {
        if (-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive).Hash -ne $release.archiveSha256) {
            Write-Output 'Downloading the pinned MediaMTX release.'
            Invoke-WebRequest -UseBasicParsing -Uri $release.url -OutFile $download -TimeoutSec 120
            if ((Get-FileHash -LiteralPath $download).Hash -ne $release.archiveSha256) { throw 'MediaMTX archive checksum mismatch.' }
            Move-Item -LiteralPath $download -Destination $archive -Force
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $entry = $zip.GetEntry('mediamtx.exe')
            if (-not $entry) { throw 'The MediaMTX archive does not contain mediamtx.exe.' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $staged, $true)
        } finally { $zip.Dispose() }
        if ((Get-FileHash -LiteralPath $staged).Hash -ne $release.executableSha256) { throw 'MediaMTX executable checksum mismatch.' }
        Move-Item -LiteralPath $staged -Destination $exe
        Write-Output 'MediaMTX installed and verified.'
    } finally {
        Remove-Item -LiteralPath $download,$staged -ErrorAction SilentlyContinue
    }
}

function Write-NewObsFile {
    param([string]$Path, [string]$Content)
    if (Test-Path -LiteralPath $Path) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $staged = $Path + '.staged'
    try {
        [IO.File]::WriteAllText($staged, $Content, $utf8)
        Move-Item -LiteralPath $staged -Destination $Path
    } finally { Remove-Item -LiteralPath $staged -ErrorAction SilentlyContinue }
}

function Initialize-ObsProfile {
    param($Settings)
    $obsExe = Find-ObsExecutable $Settings.obsExecutable
    $obsVersion = (Get-Item -LiteralPath $obsExe).VersionInfo.FileMajorPart
    if ($obsVersion -lt 33) { throw 'This setup requires OBS Studio 33 or newer.' }
    $obsRoot = Join-Path $env:APPDATA 'obs-studio'
    $profile = Join-Path $obsRoot 'basic\profiles\LAN_Stream'
    $ini = Join-Path $profile 'basic.ini'
    $service = Join-Path $profile 'service.json'
    $encoder = Join-Path $profile 'streamEncoder.json'
    $collection = Join-Path $obsRoot 'basic\scenes\LAN_Stream.json'
    $controlPath = Join-Path $obsRoot 'plugin_config\obs-websocket\config.json'
    $control = if (Test-Path -LiteralPath $controlPath) { Get-Content -Raw -LiteralPath $controlPath | ConvertFrom-Json } else { [pscustomobject]@{} }
    $controlReady = $control.server_enabled -and $control.auth_required -and $control.server_password -and $control.server_port
    if (Test-Path -LiteralPath $service) {
        $currentService = Get-Content -Raw -LiteralPath $service | ConvertFrom-Json
        if ($currentService.type -ne 'whip_custom' -or $currentService.settings.server -ne $Settings.whipUrl) {
            throw 'The existing LAN Stream profile uses a different service. Select the documented WHIP endpoint in OBS before rerunning setup.'
        }
    }
    $missing = @($ini,$service,$collection | Where-Object { -not (Test-Path -LiteralPath $_) })
    if (-not $missing.Count -and $controlReady) {
        Write-Output 'Existing LAN Stream profile and scenes are ready.'
        return
    }
    if (Get-Process obs64 -ErrorAction SilentlyContinue) { throw 'Close OBS normally before setup creates or changes its configuration, then rerun Setup-Live.cmd.' }

    if (-not (Test-Path -LiteralPath $ini)) {
        Write-NewObsFile $encoder (@{rate_control='CBR';bitrate=6000;keyint_sec=1;preset='veryfast';tune='zerolatency';profile='baseline'} | ConvertTo-Json)
        Write-NewObsFile $ini @'
[General]
Name=LAN Stream
[Output]
Mode=Advanced
[AdvOut]
Encoder=obs_x264
AudioEncoder=ffmpeg_opus
TrackIndex=1
Track1Bitrate=128
[Video]
BaseCX=1920
BaseCY=1080
OutputCX=1920
OutputCY=1080
FPSType=0
FPSCommon=30
'@
    }
    Write-NewObsFile $service (@{type='whip_custom';settings=@{server=$Settings.whipUrl;bearer_token=''}} | ConvertTo-Json -Depth 4)
    $scene = @{name='Scene';id='scene';versioned_id='scene';uuid=[guid]::NewGuid().ToString();enabled=$true;volume=1.0;settings=@{items=@()}}
    $scenes = @{name='LAN Stream';current_scene='Scene';current_program_scene='Scene';scene_order=@(@{name='Scene'});sources=@($scene)}
    Write-NewObsFile $collection ($scenes | ConvertTo-Json -Depth 6)
    if (-not $controlReady) {
        if (Test-Path -LiteralPath $controlPath) {
            $backup = Join-Path $artifacts ('obs-setup-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            New-Item -ItemType Directory -Path $backup | Out-Null
            Copy-Item -LiteralPath $controlPath -Destination (Join-Path $backup 'obs-websocket.json')
        }
        if (-not $control.server_password) {
            $bytes = New-Object byte[] 24
            $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
            $control | Add-Member -NotePropertyName server_password -NotePropertyValue ([Convert]::ToBase64String($bytes)) -Force
        }
        if (-not $control.server_port) { $control | Add-Member -NotePropertyName server_port -NotePropertyValue 4455 -Force }
        $control | Add-Member -NotePropertyMembers @{server_enabled=$true;auth_required=$true;first_load=$false} -Force
        New-Item -ItemType Directory -Path (Split-Path -Parent $controlPath) -Force | Out-Null
        [IO.File]::WriteAllText($controlPath + '.staged', ($control | ConvertTo-Json -Depth 10), $utf8)
        Move-Item -LiteralPath ($controlPath + '.staged') -Destination $controlPath -Force
    }
    Write-Output 'LAN Stream profile and scene collection prepared.'
}

$lockKey = (Get-ObsHash $projectRoot).Replace('/', '_').Replace('+', '_')
$mutex = New-Object System.Threading.Mutex($false, "Local\Stream-$lockKey")
$locked = $false
$stage = 'Prepare'
try {
    $locked = $mutex.WaitOne(0)
    if (-not $locked) { throw 'Another Stream command is running. Rerun setup after it finishes.' }
    $settings = Get-Content -Raw -LiteralPath (Join-Path $projectRoot 'config\local.json') | ConvertFrom-Json
    Initialize-ObsProfile $settings
    Install-MediaMtx
    $mutex.ReleaseMutex()
    $locked = $false
    if ($PrepareOnly) { return }

    $stage = 'Firewall'
    $streamScript = Join-Path $PSScriptRoot 'Stream.ps1'
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $streamScript -Action Firewall
        $firewallExit = $LASTEXITCODE
    } else {
        Write-Output 'Approve the Windows administrator prompt to install the LAN firewall rules.'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $streamScript + '" -Action Firewall'
        $firewall = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -Wait
        $firewallExit = $firewall.ExitCode
    }
    if ($firewallExit -ne 0) { throw 'Firewall setup failed. See dev/artifacts/runtime/firewall-result.json and rerun setup.' }
    Write-Output 'Setup complete. Select a capture source in the LAN Stream scene collection, then run Start-Live.cmd.'
} catch {
    @{time=(Get-Date).ToString('o');operation='Setup';stage=$stage;type=$_.Exception.GetType().FullName;message=$_.Exception.Message;stack=$_.ScriptStackTrace} | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $runtimeDir 'errors.jsonl') -Encoding UTF8
    Write-Error $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
