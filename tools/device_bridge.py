"""Maintain the USB route to the local test backend across device reconnects."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.request import ProxyHandler, build_opener


class DeviceBridge:
    def __init__(self, hdc, port=5000, device=None, run=subprocess.run):
        self.hdc, self.port, self.device, self.run = str(hdc), port, device, run

    def command(self, *arguments):
        result = self.run([self.hdc, *arguments], capture_output=True, text=True,
                          encoding='utf-8', errors='replace', timeout=5,
                          creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if result.returncode:
            raise RuntimeError('hdc_command_failed')
        return result.stdout

    def has_route(self, device):
        output = self.command('-t', device, 'fport', 'ls')
        pattern = rf'^\s*{re.escape(device)}\s+tcp:{self.port}\s+tcp:{self.port}\s+\[Reverse\]\s*$'
        return re.search(pattern, output, re.M) is not None

    def step(self):
        try:
            output = self.command('list', 'targets')
            devices = [line.strip() for line in output.splitlines()
                       if re.fullmatch(r'[A-Za-z0-9_-]+', line.strip())]
            if self.device:
                devices = [device for device in devices if device == self.device]
            if not devices:
                return dict(status='disconnected', message='等待 USB 测试设备连接')
            if len(devices) != 1:
                return dict(status='selection_required', message='连接了多台 USB 设备，请指定 DeviceId')
            device = devices[0]
            if self.has_route(device):
                return dict(status='connected', deviceId=device, port=self.port)
            output = self.command('-t', device, 'rport', f'tcp:{self.port}', f'tcp:{self.port}')
            if 'Forwardport result:OK' not in output or not self.has_route(device):
                return dict(status='retrying', deviceId=device, message='正在恢复 USB 后端连接')
            return dict(status='connected', deviceId=device, port=self.port, repaired=True)
        except (OSError, RuntimeError, subprocess.TimeoutExpired):
            return dict(status='retrying', message='USB 调试暂不可用，自动重试中')


def backend_ready(port):
    try:
        with build_opener(ProxyHandler({})).open(f'http://127.0.0.1:{port}/ready', timeout=3) as response:
            payload = json.load(response)
            return response.status == 200 and isinstance(payload, dict) and payload.get('status') == 'ready'
    except (OSError, ValueError):
        return False


def write_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def acquire_lease(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    stream = path.open('a+b')
    if stream.tell() == 0:
        stream.write(b'0')
        stream.flush()
    stream.seek(0)
    try:
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        stream.close()
        return None
    return stream


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hdc', required=True)
    parser.add_argument('--port', type=int, default=5000)
    parser.add_argument('--device')
    parser.add_argument('--state', type=Path, required=True)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('port must be between 1 and 65535')
    lease = acquire_lease(args.state.with_suffix('.lock'))
    if lease is None:
        print('USB bridge monitor is already running.', flush=True)
        return 0
    bridge = DeviceBridge(args.hdc, args.port, args.device)
    previous = None
    while True:
        state = bridge.step()
        state['backendReady'] = backend_ready(args.port)
        signature = dict(state)
        signature.pop('repaired', None)
        if signature != previous or state.get('repaired'):
            print(json.dumps(state, ensure_ascii=False), flush=True)
        previous = signature
        state['checkedAt'] = datetime.now(timezone.utc).isoformat()
        state['processId'] = os.getpid()
        try:
            write_state(args.state, state)
        except OSError:
            print('Unable to update USB bridge status; monitoring continues.', flush=True)
        if args.once:
            return 0 if state['status'] == 'connected' and state['backendReady'] else 1
        time.sleep(2)


if __name__ == '__main__':
    raise SystemExit(main())
