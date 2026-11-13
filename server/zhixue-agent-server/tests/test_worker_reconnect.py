import sys
from types import SimpleNamespace
from unittest.mock import Mock, call

from psycopg.errors import ConnectionTimeout, InvalidPassword, OperationalError, UndefinedTable
import pytest
from sqlalchemy.exc import DBAPIError

import worker


def connection_lost():
    return DBAPIError("SELECT 1", None, OperationalError("connection lost"), connection_invalidated=True)


@pytest.fixture
def polling(monkeypatch):
    repository = SimpleNamespace(durable_jobs=True, close=Mock())
    stop = Mock()
    monkeypatch.setattr(worker, "threading", SimpleNamespace(Event=lambda: stop))
    monkeypatch.setattr(worker.signal, "signal", Mock())
    monkeypatch.setattr(worker, "create_app", lambda: SimpleNamespace(extensions={"repository": repository}))
    monkeypatch.setattr(sys, "argv", ["worker.py"])
    return repository, stop


def test_worker_recovers_with_capped_backoff_and_resets_after_success(polling, monkeypatch):
    repository, stop = polling
    attempts = [connection_lost()] * 6 + [False, DBAPIError(None, None, ConnectionTimeout("timed out"))]
    stop.is_set.side_effect = [False] * len(attempts) + [True]
    run_once = Mock(side_effect=attempts)
    monkeypatch.setattr(worker, "run_once", run_once)

    worker.main()

    assert run_once.call_args_list == [call(repository)] * len(attempts)
    assert stop.wait.call_args_list == [call(delay) for delay in (2, 4, 8, 16, 30, 30, 1, 2)]
    repository.close.assert_called_once_with()


@pytest.mark.parametrize("args,error", [
    (["--once"], connection_lost()),
    ([], DBAPIError(None, None, InvalidPassword("authentication failed"))),
    ([], DBAPIError("SELECT 1", None, UndefinedTable("missing table"))),
])
def test_worker_fails_fast_for_one_shot_or_non_connection_error(polling, monkeypatch, args, error):
    repository, stop = polling
    stop.is_set.return_value = False
    monkeypatch.setattr(sys, "argv", ["worker.py", *args])
    run_once = Mock(side_effect=error)
    monkeypatch.setattr(worker, "run_once", run_once)

    with pytest.raises(DBAPIError) as raised:
        worker.main()

    assert raised.value is error
    run_once.assert_called_once_with(repository)
    stop.wait.assert_not_called()
    repository.close.assert_called_once_with()
