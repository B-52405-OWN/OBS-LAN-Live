[CmdletBinding()]
param([ValidateRange(5, 600)][int]$DurationSeconds = 60)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $projectRoot 'src\Obs.ps1')

function Get-SessionCounterDelta {
    param($Current, $Previous, [string]$Counter)
    if ($Current.id -and $Current.id -eq $Previous.id -and
        $null -ne $Current.$Counter -and $null -ne $Previous.$Counter) {
        $delta = $Current.$Counter - $Previous.$Counter
        if ($delta -ge 0) { return $delta }
    }
}

$socket = $null
$previousStats = $null
$previousStream = $null
$previousPublisher = $null
$previousReader = $null
$previousSeconds = 0.0
try {
    $socket = Open-ObsSocket
    $video = Invoke-ObsRequest $socket 'GetVideoSettings'
    $targetFps = [math]::Round($video.fpsNumerator / $video.fpsDenominator, 3)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $stream = Invoke-ObsRequest $socket 'GetStreamStatus'
        $sampleTime = $timer.Elapsed
        $elapsed = $sampleTime.TotalSeconds
        if (-not $stream.outputActive -or $stream.outputReconnecting) {
            if (-not $previousStream) { throw 'Start a live stream in OBS before collecting frame rate samples.' }
            Write-Warning 'The stream stopped or reconnected. Samples collected so far are saved.'
            break
        }
        $stats = Invoke-ObsRequest $socket 'GetStats'

        $renderMissed = $null
        $encodingSkipped = $null
        $outputFps = $null
        $publishKbps = $null
        if ($previousStream) {
            $renderMissed = $stats.renderSkippedFrames - $previousStats.renderSkippedFrames
            $encodingSkipped = $stats.outputSkippedFrames - $previousStats.outputSkippedFrames
            $frames = $stream.outputTotalFrames - $previousStream.outputTotalFrames
            $bytes = $stream.outputBytes - $previousStream.outputBytes
            if ($renderMissed -lt 0 -or $encodingSkipped -lt 0 -or $frames -lt 0 -or $bytes -lt 0 -or
                $stream.outputDuration -lt $previousStream.outputDuration) {
                Write-Warning 'OBS counters reset. Samples collected before the reset are saved.'
                break
            }
            $interval = $elapsed - $previousSeconds
            $outputFps = [math]::Round($frames / $interval, 2)
            $publishKbps = [math]::Round(8 * $bytes / $interval / 1000)
        } else {
            $artifacts = Join-Path $projectRoot 'dev\artifacts'
            New-Item -ItemType Directory -Path $artifacts -Force | Out-Null
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
            $report = Join-Path $artifacts "frame-rate-$stamp-$PID.csv"
            Write-Host "Collecting OBS and MediaMTX statistics for $DurationSeconds seconds. Report: $report"
        }

        $timestamp = [DateTime]::UtcNow.ToString('o')
        $mediaStatus = 'ok'
        $publisher = $null
        $reader = $null
        $readerCount = $null
        try {
            $response = Invoke-RestMethod -Uri 'http://127.0.0.1:9997/v3/webrtc/sessions/list' -UseBasicParsing -TimeoutSec 1
            if ($response.pageCount -gt 1) {
                $mediaStatus = 'multiplePages'
            } else {
                $live = @($response.items | Where-Object { $_.path -eq 'live' -and $_.peerConnectionEstablished })
                $publishers = @($live | Where-Object { $_.state -eq 'publish' })
                $readers = @($live | Where-Object { $_.state -eq 'read' })
                $readerCount = $readers.Count
                if ($publishers.Count -eq 1) { $publisher = $publishers[0] }
                if ($readerCount -eq 1) { $reader = $readers[0] }
            }
        } catch {
            $mediaStatus = 'unavailable'
        }

        [pscustomobject]@{
            timestampUtc = $timestamp
            elapsedSeconds = [math]::Round($elapsed, 3)
            targetFps = $targetFps
            obsRenderFps = [math]::Round($stats.activeFps, 2)
            averageRenderMs = [math]::Round($stats.averageFrameRenderTime, 2)
            renderMissedFrames = $renderMissed
            encodingSkippedFrames = $encodingSkipped
            obsOutputFps = $outputFps
            obsPublishKbps = $publishKbps
            mediaApiStatus = $mediaStatus
            mediaReaderCount = $readerCount
            mediaPublisherPacketsLost = Get-SessionCounterDelta $publisher $previousPublisher 'inboundRTPPacketsLost'
            mediaReaderPacketsSent = Get-SessionCounterDelta $reader $previousReader 'outboundRTPPackets'
            mediaReaderFramesDiscarded = Get-SessionCounterDelta $reader $previousReader 'outboundFramesDiscarded'
        } | Export-Csv -LiteralPath $report -Append -NoTypeInformation -Encoding UTF8

        $previousStats = $stats
        $previousStream = $stream
        $previousPublisher = $publisher
        $previousReader = $reader
        $previousSeconds = $elapsed
        if ($elapsed -ge $DurationSeconds) { break }
        $delay = [long]$sampleTime.TotalMilliseconds + 1000 - $timer.ElapsedMilliseconds
        if ($delay -gt 0) { Start-Sleep -Milliseconds $delay }
    } while ($true)

    Write-Output $report
} finally {
    Close-ObsSocket $socket
}
