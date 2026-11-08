function Find-ObsExecutable {
    param([string]$ConfiguredPath)
    $installDir = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\OBS Studio' -ErrorAction SilentlyContinue).'(default)'
    $candidates = @($ConfiguredPath, (Join-Path $env:ProgramFiles 'obs-studio\bin\64bit\obs64.exe'))
    if ($installDir) { $candidates += Join-Path $installDir 'bin\64bit\obs64.exe' }
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    throw 'Install the Windows x64 desktop edition of OBS Studio, or set obsExecutable in config/local.json.'
}

function Read-ObsMessage {
    param($Socket)
    $buffer = New-Object byte[] 65536
    $stream = New-Object System.IO.MemoryStream
    $timeout = New-Object System.Threading.CancellationTokenSource 10000
    try {
        do {
            $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
            $result = $Socket.ReceiveAsync($segment, $timeout.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'OBS closed its control connection.'
            }
            $stream.Write($buffer, 0, $result.Count)
            if ($stream.Length -gt 1048576) { throw 'OBS control response exceeds 1 MiB.' }
        } until ($result.EndOfMessage)
        [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
    } finally {
        $timeout.Dispose()
        $stream.Dispose()
    }
}

function Send-ObsMessage {
    param($Socket, $Message)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Depth 15 -Compress))
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
    $timeout = New-Object System.Threading.CancellationTokenSource 10000
    try {
        $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $timeout.Token).GetAwaiter().GetResult() | Out-Null
    } finally { $timeout.Dispose() }
}

function Get-ObsHash {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))) }
    finally { $sha.Dispose() }
}

function Open-ObsSocket {
    $settings = Get-Content -Raw -LiteralPath (Join-Path $env:APPDATA 'obs-studio\plugin_config\obs-websocket\config.json') | ConvertFrom-Json
    if (-not $settings.server_enabled) { throw 'Enable the OBS WebSocket server in Tools > WebSocket Server Settings first.' }
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $timeout = New-Object System.Threading.CancellationTokenSource 3000
    try {
        $socket.ConnectAsync([uri]"ws://127.0.0.1:$($settings.server_port)", $timeout.Token).GetAwaiter().GetResult() | Out-Null
        $hello = Read-ObsMessage $socket
        if ($hello.op -ne 0) { throw 'Unexpected OBS handshake.' }
        $identify = @{rpcVersion = 1; eventSubscriptions = 0}
        if ($hello.d.authentication) {
            $secret = Get-ObsHash ($settings.server_password + $hello.d.authentication.salt)
            $identify.authentication = Get-ObsHash ($secret + $hello.d.authentication.challenge)
        }
        Send-ObsMessage $socket @{op = 1; d = $identify}
        $reply = Read-ObsMessage $socket
        if ($reply.op -ne 2) { throw 'OBS control authentication failed.' }
        return $socket
    } catch {
        $socket.Dispose()
        throw
    } finally { $timeout.Dispose() }
}

function Invoke-ObsRequest {
    param($Socket, [string]$Type, [hashtable]$Data = @{})
    $requestId = [guid]::NewGuid().ToString()
    Send-ObsMessage $Socket @{op = 6; d = @{requestType = $Type; requestId = $requestId; requestData = $Data}}
    do { $reply = Read-ObsMessage $Socket } until ($reply.op -eq 7 -and $reply.d.requestId -eq $requestId)
    if (-not $reply.d.requestStatus.result) {
        $error = New-Object System.InvalidOperationException("OBS $Type failed ($($reply.d.requestStatus.code)): $($reply.d.requestStatus.comment)")
        $error.Data['ObsCode'] = [int]$reply.d.requestStatus.code
        throw $error
    }
    return $reply.d.responseData
}

function Assert-ObsWhipAudioConfiguration {
    param($Socket)
    $mode = Invoke-ObsRequest $Socket 'GetProfileParameter' @{parameterCategory='Output';parameterName='Mode'}
    $outputMode = $mode.parameterValue
    if (-not $outputMode) { $outputMode = $mode.defaultParameterValue }
    if ($outputMode -eq 'Simple') {
        $category = 'SimpleOutput'
        $name = 'StreamAudioEncoder'
        $expected = 'opus'
    } else {
        $category = 'AdvOut'
        $name = 'AudioEncoder'
        $expected = 'ffmpeg_opus'
    }
    $audio = Invoke-ObsRequest $Socket 'GetProfileParameter' @{parameterCategory=$category;parameterName=$name}
    $encoder = $audio.parameterValue
    if (-not $encoder) { $encoder = $audio.defaultParameterValue }
    if ($encoder -ne $expected) {
        throw "LAN WHIP audio requires Opus; current encoder is '$encoder'. Stop streaming, select FFmpeg Opus in OBS Settings > Output > Streaming > Audio Encoder, apply, then start again."
    }
}

function Close-ObsSocket {
    param($Socket)
    if ($null -eq $Socket) { return }
    try {
        $timeout = New-Object System.Threading.CancellationTokenSource 1000
        $Socket.CloseOutputAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done', $timeout.Token).GetAwaiter().GetResult() | Out-Null
    } catch {
        # Disposal closes the transport if the peer has already gone away.
    } finally {
        if ($timeout) { $timeout.Dispose() }
        $Socket.Dispose()
    }
}
