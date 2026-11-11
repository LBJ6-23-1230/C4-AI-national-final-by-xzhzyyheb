"""Disposable HTTP server for the production-client integration check."""
from pathlib import Path
import json
import os
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'server' / 'zhixue-agent-server'))
from app import create_app
from werkzeug.serving import make_server

with tempfile.TemporaryDirectory(prefix='device-http-', dir=root / '.local-work') as folder:
    app = create_app(Path(folder) / 'repository.json')
    auth = app.test_client().post('/api/v1/auth/register', json=dict(
        nickname='设备协同集成检查', phone='13900008992', password='test-pw-123456')).get_json()
    server = make_server('127.0.0.1', 0, app, threaded=True)
    print('DEVICE_TEST_READY ' + json.dumps(dict(url=f'http://127.0.0.1:{server.server_port}',
        userId=auth['user']['userId'], token=auth['token'])), flush=True)
    server.serve_forever()
