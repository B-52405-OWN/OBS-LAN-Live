"""Compare one OBS/MediaMTX capture with a Chromium RTCStats dump."""

import argparse
import csv
from datetime import datetime, timezone
import gzip
import json
from pathlib import Path
from statistics import median
from urllib.parse import urlsplit


def parse_time(value):
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if parsed.tzinfo is None:
        raise ValueError('请在时间末尾加时区，例如 +08:00。')
    return parsed.timestamp()


def counter_delta(before, after, key):
    first = before.get(key)
    last = after.get(key)
    if isinstance(first, (int, float)) and isinstance(last, (int, float)):
        # packetsLost is a signed estimate and can fall when late packets arrive.
        if last >= first or key == 'packetsLost':
            return max(0, last - first)
    return None


def read_browser(path):
    connections = set()
    previous = {}
    samples = []
    opened = gzip.open if path.suffix.lower() == '.gz' else open
    with opened(path, 'rt', encoding='utf-8-sig') as stream:
        if stream.readline().strip() != 'RTCStatsDump' or json.loads(stream.readline()).get('fileFormat') != 3:
            raise ValueError('请选择 Chrome 的「Download the rtcstats dump」。')
        timestamp_ms = 0
        for line in stream:
            if not line.strip():
                continue
            event, connection, report, *extra = json.loads(line)
            timestamp_ms += extra[-1]
            if event == 'create' and len(extra) > 1 and urlsplit(extra[0]).path.rstrip('/') == '/live':
                connections.add(connection)
            if event != 'getStats' or connection not in connections:
                continue

            for track_id, video in report.items():
                if video.get('type') != 'inbound-rtp' or video.get('kind', video.get('mediaType')) != 'video':
                    continue
                key = (connection, track_id)
                timestamp = timestamp_ms / 1000
                last_timestamp, last_video = previous.get(key, (timestamp, {}))
                previous[key] = (timestamp, video)
                interval = timestamp - last_timestamp
                if not 0 < interval <= 4:
                    continue

                sample = {field: counter_delta(last_video, video, field) for field in (
                    'packetsLost', 'packetsDiscarded', 'framesReceived', 'framesDecoded',
                    'framesRendered', 'framesDropped', 'freezeCount', 'totalFreezesDuration',
                    'totalDecodeTime', 'jitterBufferDelay', 'jitterBufferEmittedCount',
                )}
                decoded = sample['framesDecoded']
                received = sample['framesReceived']
                rendered = sample['framesRendered']
                decode_time = sample['totalDecodeTime']
                buffer_delay = sample['jitterBufferDelay']
                buffer_count = sample['jitterBufferEmittedCount']
                transport = report.get(video.get('transportId'), {})
                pair = report.get(transport.get('selectedCandidatePairId'), {})
                candidate = report.get(pair.get('remoteCandidateId'), {})
                sample.update(time=timestamp, connection=key,
                              receiveFps=None if received is None else received / interval,
                              decodeFps=None if decoded is None else decoded / interval,
                              renderFps=None if rendered is None else rendered / interval,
                              decodeMs=1000 * decode_time / decoded if decoded and decode_time is not None else None,
                              bufferMs=1000 * buffer_delay / buffer_count if buffer_count and buffer_delay is not None else None,
                              protocol=candidate.get('protocol'), decoder=video.get('decoderImplementation'))
                samples.append(sample)
    return sorted(samples, key=lambda sample: sample['time'])


def read_host(path):
    with path.open(encoding='utf-8-sig', newline='') as stream:
        capture = [{**row, 'time': parse_time(row['timestampUtc'])} for row in csv.DictReader(stream)]
    return sorted(capture, key=lambda sample: sample['time'])


def numbers(samples, key):
    return [float(sample[key]) for sample in samples if sample.get(key) not in (None, '')]


def describe(samples, key, summarize):
    values = numbers(samples, key)
    return f'{summarize(values):.2f}' if values else '缺数据'


def analyze(host, browser, at):
    if len(host) < 2 or not browser:
        raise ValueError('需要至少两行主播采样和直播页 /live/ 的浏览器视频统计。')
    overlap = [sample for sample in browser if host[0]['time'] <= sample['time'] <= host[-1]['time']]
    if not overlap:
        raise ValueError('两端采样时间没有重合。请检查两台电脑的系统时间与采样时段。')
    target = median(numbers(host, 'targetFps'))
    lookback = 3
    if at is None:
        freezes = [sample for sample in overlap if sample['freezeCount']]
        low_fps = [sample for sample in overlap if sample['decodeFps'] is not None and sample['decodeFps'] < 0.75 * target]
        if freezes:
            focus = max(freezes, key=lambda sample: sample['totalFreezesDuration'] or 0)
            lookback = max(lookback, (focus['totalFreezesDuration'] or 0) + 2)
        elif low_fps:
            focus = min(low_fps, key=lambda sample: sample['decodeFps'])
        else:
            print('重叠时段未检测到画面冻结或明显的解码帧率下降。请用 --at 指定肉眼看到卡顿的时刻。')
            return
        at = focus['time']

    if not host[0]['time'] <= at <= host[-1]['time'] or not any(abs(sample['time'] - at) <= 2 for sample in overlap):
        raise ValueError('指定时刻附近缺少双端样本。请检查时区、两端时钟和采样范围。')
    host_window = [sample for sample in host[1:] if at - lookback <= sample['time'] <= at + 2]
    viewer_window = [sample for sample in overlap if at - lookback <= sample['time'] <= at + 2]
    if not host_window:
        raise ValueError('卡顿时段缺少主播输出采样。')
    if len({sample['connection'] for sample in viewer_window}) != 1:
        raise ValueError('卡顿时段涉及多路观看流或重连。请在此次采样中指定一条连接稳定时的卡顿时刻。')

    stamp = datetime.fromtimestamp(at, timezone.utc).isoformat(timespec='seconds')
    print(f'卡顿时刻 {stamp}（UTC），检查之前 {lookback:.1f} 秒至之后 2 秒。')
    if at - lookback < host[0]['time'] or at + 2 > host[-1]['time']:
        print('主播采样只覆盖部分卡顿时段。')
    print(f'OBS 目标帧率 {target:.2f}，区间最低输出帧率 {describe(host_window, "obsOutputFps", min)}')
    for name, column, data in (
        ('OBS 渲染漏帧', 'renderMissedFrames', host_window),
        ('OBS 编码跳帧', 'encodingSkippedFrames', host_window),
        ('MediaMTX 发布端入站丢包', 'mediaPublisherPacketsLost', host_window),
        ('MediaMTX 观看会话出站弃帧', 'mediaReaderFramesDiscarded', host_window),
        ('浏览器接收端丢包', 'packetsLost', viewer_window),
        ('浏览器丢弃收到的包', 'packetsDiscarded', viewer_window),
        ('浏览器掉帧', 'framesDropped', viewer_window),
        ('浏览器画面冻结次数', 'freezeCount', viewer_window),
    ):
        print(f'{name}  {describe(data, column, sum)}')

    print(f'浏览器最低接收 / 解码 / 呈现帧率  {describe(viewer_window, "receiveFps", min)} / '
          f'{describe(viewer_window, "decodeFps", min)} / {describe(viewer_window, "renderFps", min)}')
    print(f'浏览器峰值区间平均解码耗时  {describe(viewer_window, "decodeMs", max)} ms/帧')
    print(f'浏览器峰值区间平均抖动缓冲耗时  {describe(viewer_window, "bufferMs", max)} ms/帧')
    for name, field in (('媒体传输', 'protocol'), ('视频解码器', 'decoder')):
        values = sorted({sample[field] for sample in viewer_window if sample[field]})
        if values:
            print(f'{name}  {", ".join(values)}')

    findings = []
    if sum(numbers(host_window, 'renderMissedFrames')) > 0:
        findings.append('OBS 渲染出现漏帧')
    if sum(numbers(host_window, 'encodingSkippedFrames')) > 0:
        findings.append('OBS 编码出现跳帧')
    output_rates = numbers(host_window, 'obsOutputFps')
    if output_rates and min(output_rates) < 0.75 * target:
        findings.append('OBS 流输出帧率已经下降')
    if sum(numbers(host_window, 'mediaPublisherPacketsLost')) > 0:
        findings.append('OBS 到 MediaMTX 的发布会话报告丢包')
    if sum(numbers(host_window, 'mediaReaderFramesDiscarded')) > 0:
        findings.append('MediaMTX 在转发时弃帧')
    if sum(numbers(viewer_window, 'packetsLost')) > 0 or sum(numbers(viewer_window, 'packetsDiscarded')) > 0:
        findings.append('浏览器报告网络丢包或接收缓冲丢包')
    if any(sample['receiveFps'] is not None and sample['receiveFps'] >= 0.9 * target
           and sample['decodeFps'] is not None and sample['decodeFps'] < 0.75 * target
           and sample['packetsLost'] == 0 and sample['packetsDiscarded'] == 0 for sample in viewer_window):
        findings.append('浏览器接收帧率稳定时解码帧率下降，优先查观看端')
    if any(sample['decodeFps'] is not None and sample['decodeFps'] >= 0.9 * target
           and sample['renderFps'] is not None and sample['renderFps'] < 0.75 * target
           and sample['framesDropped'] for sample in viewer_window):
        findings.append('浏览器解码帧率稳定时呈现帧率下降，优先查观看端播放')
    if findings:
        print('同一时段的异常')
        for finding in findings:
            print(f'- {finding}')
    else:
        print('现有计数无法锁定原因。对照主播游戏帧率和 OBS 预览，检查采集画面是否已经卡顿。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('host_csv', type=Path)
    parser.add_argument('rtcstats_dump', type=Path)
    parser.add_argument('--at', help='卡顿时刻，使用带时区的 ISO 8601，例如 2026-11-15T20:30:25+08:00')
    arguments = parser.parse_args()
    try:
        analyze(read_host(arguments.host_csv), read_browser(arguments.rtcstats_dump),
                parse_time(arguments.at) if arguments.at else None)
    except (OSError, ValueError, KeyError, IndexError) as error:
        parser.exit(1, f'{error}\n')


if __name__ == '__main__':
    main()
