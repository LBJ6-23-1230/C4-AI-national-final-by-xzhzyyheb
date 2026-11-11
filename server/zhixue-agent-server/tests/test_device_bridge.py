from importlib.util import module_from_spec, spec_from_file_location
from io import StringIO
from pathlib import Path
import subprocess
from types import SimpleNamespace

import pytest


spec = spec_from_file_location('device_bridge', Path(__file__).resolve().parents[3] / 'tools/device_bridge.py')
bridge = module_from_spec(spec)
spec.loader.exec_module(bridge)


class FakeHdc:
    def __init__(self, devices='tablet\n127.0.0.1:5555\n', route=False):
        self.devices, self.route, self.calls = devices, route, []

    def __call__(self, command, **options):
        assert options['timeout'] == 5
        self.calls.append(command[1:])
        if command[1:] == ['list', 'targets']:
            output = self.devices
        elif command[-2:] == ['fport', 'ls']:
            output = 'tablet tcp:5000 tcp:5000 [Reverse]\n' if self.route else '[Empty]\n'
        else:
            assert command[1:] == ['-t', 'tablet', 'rport', 'tcp:5000', 'tcp:5000']
            self.route = True
            output = 'Forwardport result:OK\n'
        return SimpleNamespace(returncode=0, stdout=output)


def test_missing_usb_route_is_repaired_once_then_reused():
    fake = FakeHdc()
    monitor = bridge.DeviceBridge('hdc', device='tablet', run=fake)
    assert monitor.step()['repaired']
    assert monitor.step() == dict(status='connected', deviceId='tablet', port=5000)
    assert sum('rport' in command for command in fake.calls) == 1
    assert all('kill' not in command and 'rm' not in command for command in fake.calls)


def test_route_loss_after_reconnection_is_repaired_again():
    fake = FakeHdc(route=True)
    monitor = bridge.DeviceBridge('hdc', device='tablet', run=fake)
    assert monitor.step()['status'] == 'connected'
    fake.devices, fake.route = '127.0.0.1:5555\n', False
    assert monitor.step()['status'] == 'disconnected'
    fake.devices = 'tablet\n127.0.0.1:5555\n'
    assert monitor.step()['repaired']


def test_multiple_usb_devices_require_selection_without_mutation():
    fake = FakeHdc(devices='tablet\nother\n127.0.0.1:5555\n')
    assert bridge.DeviceBridge('hdc', run=fake).step()['status'] == 'selection_required'
    assert fake.calls == [['list', 'targets']]
    assert bridge.DeviceBridge('hdc', device='tablet', run=fake).step()['status'] == 'connected'


def test_emulator_alone_does_not_get_a_usb_route():
    fake = FakeHdc(devices='127.0.0.1:5555\n')
    assert bridge.DeviceBridge('hdc', run=fake).step()['status'] == 'disconnected'
    assert fake.calls == [['list', 'targets']]


@pytest.mark.parametrize('error', [OSError('unavailable'), subprocess.TimeoutExpired('hdc', 5), RuntimeError('failure')])
def test_hdc_errors_can_recover_on_a_later_tick(error):
    def unavailable(*args, **kwargs):
        raise error
    monitor = bridge.DeviceBridge('hdc', device='tablet', run=unavailable)
    assert monitor.step()['status'] == 'retrying'
    monitor.run = FakeHdc()
    assert monitor.step()['status'] == 'connected'


def test_failed_creation_does_not_claim_connected():
    fake = FakeHdc()
    def failure(command, **options):
        if 'rport' in command:
            return SimpleNamespace(returncode=0, stdout='[Fail] route unavailable')
        return fake(command, **options)
    assert bridge.DeviceBridge('hdc', device='tablet', run=failure).step()['status'] == 'retrying'


def test_only_exact_device_port_and_reverse_direction_count_as_ready():
    for output in ('other tcp:5000 tcp:5000 [Reverse]', 'tablet tcp:5000 tcp:5001 [Reverse]',
                   'tablet tcp:5000 tcp:5000 [Forward]', 'tablet tcp:55000 tcp:5000 [Reverse]'):
        fake = lambda *args, **kwargs: SimpleNamespace(returncode=0, stdout=output)
        assert not bridge.DeviceBridge('hdc', device='tablet', run=fake).has_route('tablet')


def test_single_instance_lease_is_released_when_process_handle_closes(tmp_path):
    path = tmp_path / 'bridge.lock'
    first = bridge.acquire_lease(path)
    assert first is not None
    try:
        assert bridge.acquire_lease(path) is None
    finally:
        first.close()
    reopened = bridge.acquire_lease(path)
    assert reopened is not None
    reopened.close()


@pytest.mark.parametrize('status,payload,ready', [
    (200, '{"status":"ready"}', True),
    (503, '{"status":"unavailable"}', False),
    (200, '[]', False),
    (200, 'not-json', False),
])
def test_backend_readiness_rejects_unavailable_or_malformed_payloads(monkeypatch, status, payload, ready):
    response = StringIO(payload)
    response.status = status
    def open_health(url, timeout):
        assert url == 'http://127.0.0.1:5000/ready'
        assert timeout == 3
        return response
    monkeypatch.setattr(bridge, 'build_opener', lambda *args: SimpleNamespace(open=open_health))
    assert bridge.backend_ready(5000) is ready
