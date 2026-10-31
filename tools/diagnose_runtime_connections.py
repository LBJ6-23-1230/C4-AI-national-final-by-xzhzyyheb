"""Read-only network, PostgreSQL protocol, and local API probes.

Credentials are read from the project's existing environment; never emitted.
No database writes, account login, or service restarts are performed.
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from time import perf_counter
from urllib.error import HTTPError
from urllib.request import ProxyHandler, Request, build_opener
from zoneinfo import ZoneInfo
import json
import os
import socket
import struct
import sys

from dotenv import dotenv_values
from sqlalchemy.engine import make_url

ROOT = Path(__file__).resolve().parents[1]
ENV = ROOT / 'server/zhixue-agent-server/.env'
VALUES = dotenv_values(ENV, encoding='utf-8-sig')
URL = make_url(os.environ.get('DATABASE_URL') or VALUES['DATABASE_URL'])
HOST, PORT = URL.host, URL.port or 5432


def protocol_probe(mode):
    started = perf_counter()
    result = {'probe': mode, 'target': f'{HOST}:{PORT}'}
    stage = 'tcp_connect'
    try:
        with socket.create_connection((HOST, PORT), timeout=4) as connection:
            result.update(tcpConnected=True, localAddress=connection.getsockname()[0])
            connection.settimeout(5)
            if mode == 'ssl_request':
                packet = struct.pack('!II', 8, 80877103)
            else:
                fields = ('user\0' + URL.username + '\0database\0' + URL.database +
                          '\0application_name\0zhixue_readonly_diagnosis\0\0').encode()
                packet = struct.pack('!II', 8 + len(fields), 196608) + fields
            stage = 'postgresql_reply'
            connection.sendall(packet)
            reply = connection.recv(1)
            result['reply'] = reply.decode('ascii', errors='replace') or 'connection_closed'
            result['postgresqlResponded'] = reply in (b'S', b'N') if mode == 'ssl_request' else reply in (b'R', b'E')
    except OSError as error:
        result.update(failedStage=stage, error=type(error).__name__, osError=getattr(error, 'winerror', None))
    result['seconds'] = round(perf_counter() - started, 3)
    return result


def login_probe(sslmode):
    import psycopg
    started = perf_counter()
    result = {'probe': 'postgresql_login', 'sslmode': sslmode, 'gssencmode': 'disable'}
    try:
        with psycopg.connect(host=HOST, port=PORT, dbname=URL.database,
                             user=URL.username, password=URL.password, connect_timeout=5,
                             sslmode=sslmode, gssencmode='disable',
                             application_name='zhixue_readonly_diagnosis',
                             options='-c statement_timeout=5000') as connection:
            connection.read_only = True
            row = connection.execute('SELECT current_database(), current_user, inet_server_addr()::text, inet_server_port()').fetchone()
            result.update(ok=True, database=row[0], user=row[1], serverAddress=row[2], serverPort=row[3])
    except psycopg.Error as error:
        # SQLSTATE identifies authentication/schema errors without exposing a DSN.
        result.update(ok=False, error=type(error).__name__, sqlstate=error.sqlstate,
                      timeout='timeout' in str(error).lower())
    result['seconds'] = round(perf_counter() - started, 3)
    return result


def http_probe(path):
    started = perf_counter()
    result = {'probe': 'backend_http', 'path': path, 'url': 'http://127.0.0.1:5000' + path}
    try:
        # Loopback must bypass system HTTP proxies.
        opener = build_opener(ProxyHandler({}))
        request = Request(result['url'], headers={'X-API-Contract-Version': 'api-contract-v0.3'})
        try:
            response = opener.open(request, timeout=18 if path == '/ready' else 8)
        except HTTPError as error:
            response = error
        with response:
            data = json.loads(response.read())
            allowed = ('status', 'service', 'contractVersion', 'errorCode', 'message', 'llm', 'model', 'llmReady')
            result.update(status=response.status, body={key: data[key] for key in allowed if key in data})
    except Exception as error:
        result.update(error=type(error).__name__)
    result['seconds'] = round(perf_counter() - started, 3)
    return result


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    jobs = [(protocol_probe, 'ssl_request'), (protocol_probe, 'plain_startup'),
            (login_probe, 'prefer'), (login_probe, 'disable'), (login_probe, 'require')]
    jobs += [(http_probe, path) for path in ('/', '/health', '/ready', '/api/agent/health', '/api/v1/auth/me')]
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        futures = [pool.submit(fn, arg) for fn, arg in jobs]
        results = [future.result() for future in futures]
    report = {
        'checkedAt': datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(),
        'configuration': {'host': HOST, 'port': PORT, 'database': URL.database, 'username': URL.username,
                          'driver': URL.drivername, 'passwordConfigured': bool(URL.password),
                          'source': 'process environment' if os.environ.get('DATABASE_URL') else 'server .env',
                          'matchesProvidedEndpoint': (HOST, PORT, URL.database, URL.username) ==
                              ('10.77.203.46', 5432, 'zhixue_dev', 'zhixue_dev_app')},
        'results': results,
    }
    output = ROOT / 'evidence/runtime-connection-diagnosis-20261031.json'
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
