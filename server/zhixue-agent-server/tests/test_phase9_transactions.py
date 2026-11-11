from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time
from urllib.request import Request, build_opener, ProxyHandler
from urllib.error import HTTPError

import pytest

from app import create_app
from app.api import exercises
from app.repositories.json_repository import JsonRepository
from app.repositories.sqlite_repository import SQLiteRepository
from app.services import retention

SERVER = Path(__file__).resolve().parents[1]


def test_two_http_workers_ten_submissions_score_once(tmp_path):
    database = tmp_path / "shared.sqlite"
    processes, bases = [], []
    opener = build_opener(ProxyHandler({}))
    def call(base, method, path, payload=None):
        data = json.dumps(payload).encode() if payload is not None else None
        req = Request(base + path, data=data, method=method, headers={"Content-Type": "application/json"})
        try:
            with opener.open(req, timeout=10) as result:
                return result.status, json.loads(result.read())
        except HTTPError as error:
            return error.code, json.loads(error.read())
    try:
        for _ in range(2):
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            env = dict(os.environ, ZHIXUE_DB=f"sqlite:{database}", DASHSCOPE_API_KEY="", ZHIXUE_QUIET="1",
                       ZHIXUE_REPOSITORY=str(tmp_path / "unused.json"))
            script = f"from app import create_app; create_app().run(host='127.0.0.1',port={port},use_reloader=False)"
            process = subprocess.Popen([sys.executable, "-c", script], cwd=SERVER, env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            processes.append(process)
            base = f"http://127.0.0.1:{port}"
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                assert process.poll() is None, "worker exited before health became available"
                try:
                    if call(base, "GET", "/health")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.05)
            else:
                pytest.fail("worker startup timed out")
            bases.append(base)
        payload = {"idempotencyKey": "two-process", "answers": [
            {"exerciseId": "exercise-preorder-001", "answer": "A"},
            {"exerciseId": "exercise-inorder-001", "answer": "B"},
            {"exerciseId": "exercise-postorder-001", "answer": "A"}]}
        url = "/api/v1/exercises/set-demo-binary-tree-001/submit"
        with ThreadPoolExecutor(max_workers=10) as callers:
            results = list(callers.map(lambda n: call(bases[n % 2], "POST", url, payload), range(10)))
        assert all(code == 200 for code, _ in results)
        assert all(body == results[0][1] for _, body in results)
        assert results[0][1]["masteryUpdate"] == {"knowledgePointId": "binary-tree-postorder", "oldScore": 42, "newScore": 58}
        changed = dict(payload, answers=[{"exerciseId": "exercise-preorder-001", "answer": "B"}])
        assert call(bases[0], "POST", url, changed) == call(bases[1], "POST", url, changed)
        assert call(bases[0], "POST", url, changed)[0] == 409
        repo = SQLiteRepository(database)
        try:
            assert len(repo.list("submissions")) == 1
            assert repo.get("profiles", "demo-user")["profileVersion"] == 2
        finally:
            repo.close()
    finally:
        for process in processes:
            process.terminate()
        for process in processes:
            try:
                process.wait(5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(5)


def test_json_rejects_another_writer_process(tmp_path):
    path = tmp_path / "single.json"
    repo = JsonRepository(path)
    try:
        result = subprocess.run([sys.executable, "-c",
            "from app.repositories.json_repository import JsonRepository; import sys; JsonRepository(sys.argv[1])",
            str(path)], cwd=SERVER, capture_output=True, text=True, timeout=10)
        assert result.returncode != 0
        assert "one process only" in result.stderr
    finally:
        repo.close()
    result = subprocess.run([sys.executable, "-c",
        "from app.repositories.json_repository import JsonRepository; import sys; JsonRepository(sys.argv[1])",
        str(path)], cwd=SERVER, capture_output=True, timeout=10)
    assert result.returncode == 0


@pytest.mark.parametrize("backend", [JsonRepository, SQLiteRepository])
def test_retention_protects_references_unknown_dates_and_unresolved_mistakes(tmp_path, backend):
    repo = backend(tmp_path / "retention")
    try:
        for key, row in {"old": {"userId": "u", "createdAt": "2020-01-01"},
                         "bound": {"response": {"userId": "u", "traceId": "t"}, "createdAt": "2020-01-01"},
                         "unknown": {"userId": "u"}}.items():
            repo.save("submissions", key, row)
        repo.save("workflows", "w", {"state": {"boundSubmissionId": "bound"}})
        repo.save("traces", "t", {"userId": "u", "events": [{"timestamp": "2020-01-01"}]})
        repo.save("wrong_book", "wrong", {"userId": "u", "correctCount": 0, "addedAt": "2020-01-01"})
        assert retention.plan(repo, datetime(2026, 10, 22, tzinfo=timezone.utc)) == [("submissions", "old")]
        assert len(repo.list("submissions")) == 3
        with repo.transaction():
            repo.apply_batch(retention.plan(repo), [])
        assert repo.get("submissions", "old") is None
        assert repo.get("wrong_book", "wrong")
    finally:
        repo.close()


def test_history_retention_is_per_user_and_time_bounded():
    store = {"one": [{"timestamp": "2020-01-01"}] + [{"timestamp": "2026-10-22", "n": n} for n in range(60)],
             "two": [{"timestamp": "2026-10-22", "n": "other"}]}
    updated = retention.history_plan(store, datetime(2026, 10, 22, tzinfo=timezone.utc))
    assert len(updated["one"]) == 50 and updated["one"][0]["n"] == 10
    assert updated["two"] == store["two"]
