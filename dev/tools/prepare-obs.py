"""One-time OBS setup. Run with OBS closed; --windows only inspects native window state."""
import argparse
import configparser
import copy
import ctypes
from ctypes import wintypes as W
from datetime import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
OBS = Path(os.environ['APPDATA']) / 'obs-studio'


def windows(pid):
    user = ctypes.WinDLL('user32', use_last_error=True)
    user.GetWindowTextW.argtypes = [W.HWND, W.LPWSTR, ctypes.c_int]
    user.GetWindowRect.argtypes = [W.HWND, ctypes.POINTER(W.RECT)]
    user.IsWindowVisible.argtypes = user.IsZoomed.argtypes = user.IsIconic.argtypes = [W.HWND]
    rows = []
    callback_type = ctypes.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)

    def visit(handle, _):
        owner = W.DWORD()
        user.GetWindowThreadProcessId(handle, ctypes.byref(owner))
        if owner.value == pid and user.IsWindowVisible(handle):
            title = ctypes.create_unicode_buffer(512)
            user.GetWindowTextW(handle, title, len(title))
            rect = W.RECT()
            user.GetWindowRect(handle, ctypes.byref(rect))
            rows.append(dict(handle=handle, title=title.value,
                             rect=[rect.left, rect.top, rect.right, rect.bottom],
                             maximized=bool(user.IsZoomed(handle)), minimized=bool(user.IsIconic(handle))))
        return True

    user.EnumWindows(callback_type(visit), 0)
    print(json.dumps(rows, ensure_ascii=False))
    if rows:
        path = ROOT / 'dev/artifacts/obs-backup-20261101/windows.json'
        if not path.exists():
            path.write_text(json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')


def prepare():
    processes = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq obs64.exe', '/FO', 'CSV', '/NH'],
                               capture_output=True, text=True, check=True)
    if 'obs64.exe' in processes.stdout.lower():
        raise RuntimeError('Exit OBS normally before changing its files.')
    profile = OBS / 'basic/profiles/LAN_Stream'
    collection = OBS / 'basic/scenes/LAN_Stream.json'
    if profile.exists() or collection.exists():
        raise RuntimeError('LAN Stream already exists; do not overwrite a configured profile.')
    backup = ROOT / 'dev/artifacts' / ('obs-backup-' + datetime.now().strftime('%Y%m%d-%H%M%S'))
    backup.mkdir(parents=True)
    for source, name in [(OBS / 'user.ini', 'user.ini'),
                         (OBS / 'plugin_config/obs-websocket/config.json', 'obs-websocket.json'),
                         (OBS / 'basic/scenes/未命名.json', 'original-scenes.json')]:
        shutil.copy2(source, backup / name)
    shutil.copytree(OBS / 'basic/profiles/未命名', backup / 'original-profile')
    test_video = ROOT / 'dev/artifacts/link-test.mp4'
    if not test_video.exists():
        test_video.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i',
                        'testsrc2=size=1280x720:rate=30', '-f', 'lavfi', '-i',
                        'sine=frequency=440:sample_rate=48000', '-t', '10', '-c:v', 'libx264',
                        '-preset', 'veryfast', '-crf', '23', '-pix_fmt', 'yuv420p',
                        '-c:a', 'aac', '-b:a', '96k', str(test_video)], check=True)
    profile.mkdir()
    ini = configparser.ConfigParser(interpolation=None)
    ini.optionxform = str
    ini.read(OBS / 'basic/profiles/未命名/basic.ini', encoding='utf-8-sig')
    updates = {
        'General': {'Name': 'LAN Stream'},
        'Output': {'Mode': 'Advanced', 'DelayEnable': 'false', 'Reconnect': 'false'},
        'SimpleOutput': {'VBitrate': '6000', 'ABitrate': '128', 'StreamEncoder': 'nvenc',
                         'StreamAudioEncoder': 'opus', 'UseAdvanced': 'true', 'NVENCPreset2': 'p4'},
        'Stream1': {'EnableMultitrackVideo': 'false'},
        'AdvOut': {'Encoder': 'obs_nvenc_h264_tex', 'AudioEncoder': 'ffmpeg_opus',
                   'TrackIndex': '1', 'Track1Bitrate': '128'},
        'Video': {'BaseCX': '1920', 'BaseCY': '1080', 'OutputCX': '1920', 'OutputCY': '1080',
                  'FPSType': '0', 'FPSCommon': '30'},
    }
    for section, values in updates.items():
        if section not in ini:
            ini.add_section(section)
        ini[section].update(values)
    with (profile / 'basic.ini').open('w', encoding='utf-8') as file:
        ini.write(file, space_around_delimiters=False)
    (profile / 'service.json').write_text(json.dumps({
        'type': 'whip_custom', 'settings': {'server': 'http://127.0.0.1:8889/live/whip', 'bearer_token': ''}
    }, indent=2), encoding='utf-8')
    (profile / 'streamEncoder.json').write_text(json.dumps({
        'rate_control': 'CBR', 'bitrate': 6000, 'keyint_sec': 1, 'preset': 'p4',
        'tune': 'll', 'multipass': 'disabled', 'profile': 'high', 'bf': 0,
        'lookahead': False, 'adaptive_quantization': True,
    }, indent=2), encoding='utf-8')

    scene = json.loads((OBS / 'basic/scenes/未命名.json').read_text(encoding='utf-8-sig'))
    scene['name'] = 'LAN Stream'
    for key in ('DesktopAudioDevice1', 'AuxAudioDevice1'):
        if key in scene:
            scene[key]['muted'] = True
    template = next(source for source in scene['sources'] if source['id'] == 'scene')
    test_scene = copy.deepcopy(template)
    test_scene.update(name='链路测试', uuid=str(uuid.uuid4()), hotkeys={})
    media_uuid = str(uuid.uuid4())
    item = copy.deepcopy(template['settings']['items'][0])
    item.update(name='测试视频', source_uuid=media_uuid, visible=True, id=1,
                scale={'x': 1.5, 'y': 1.5}, scale_rel={'x': 1.5, 'y': 1.5})
    test_scene['settings'] = {'id_counter': 1, 'custom_size': False, 'items': [item]}
    media = {
        'name': '测试视频', 'uuid': media_uuid, 'id': 'ffmpeg_source', 'versioned_id': 'ffmpeg_source',
        'settings': {'local_file': (ROOT / 'dev/artifacts/link-test.mp4').as_posix(), 'is_local_file': True,
                     'looping': True, 'restart_on_activate': True, 'close_when_inactive': True},
        'mixers': 1, 'sync': 0, 'flags': 0, 'volume': 0.08, 'balance': 0.5,
        'enabled': True, 'muted': False, 'monitoring_type': 0,
        'canvas_uuid': template.get('canvas_uuid'), 'private_settings': {},
    }
    scene['sources'].extend([test_scene, media])
    scene['scene_order'].append({'name': '链路测试'})
    scene['current_scene'] = scene['current_program_scene'] = '链路测试'
    collection.write_text(json.dumps(scene, ensure_ascii=False, indent=2), encoding='utf-8')
    ws_path = OBS / 'plugin_config/obs-websocket/config.json'
    websocket = json.loads(ws_path.read_text(encoding='utf-8-sig'))
    websocket['server_enabled'] = True
    websocket['auth_required'] = True
    websocket['alerts_enabled'] = False
    if not websocket.get('server_password'):
        import secrets
        websocket['server_password'] = secrets.token_urlsafe(24)
    ws_path.write_text(json.dumps(websocket, indent=2), encoding='utf-8')
    print('Created LAN Stream profile/collection; original configuration preserved.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--windows', type=int)
    args = parser.parse_args()
    if args.windows:
        windows(args.windows)
    else:
        prepare()
