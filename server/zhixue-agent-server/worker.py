"""Recover queued/expired work; SIGTERM stops claiming and completes the current job."""
import argparse
import logging
import signal
import threading

from psycopg.errors import ConnectionTimeout
from sqlalchemy.exc import DBAPIError

from app.settings import load_environment

load_environment()
from app import create_app
from app.services.job_queue import run_once


_RECONNECT_SQLSTATES = {"08000", "08001", "08003", "08006", "08007", "57P01", "57P02", "57P03"}


def _can_reconnect(error):
    original = error.orig
    if error.connection_invalidated or isinstance(original, ConnectionTimeout):
        return True
    sqlstate = getattr(original, "sqlstate", None)
    if sqlstate is not None:
        return sqlstate in _RECONNECT_SQLSTATES
    # libpq can report socket failures during a new connection without SQLSTATE.
    return error.statement is None and any(
        reason in str(original).casefold()
        for reason in ("failed: connection refused", "failed: network is unreachable", "failed: no route to host")
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    app = create_app()
    repository = app.extensions["repository"]
    if not getattr(repository, "durable_jobs", False):
        raise RuntimeError("standalone worker requires ZHIXUE_DB=postgresql")
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    logging.basicConfig(level=logging.INFO)
    retry_delay = 2
    try:
        while not stop.is_set():
            try:
                worked = run_once(repository)
            except DBAPIError as error:
                if args.once or not _can_reconnect(error):
                    raise
                # The next poll can claim eligible jobs. An uncertain claim keeps its lease until expiry.
                logging.warning("worker_db_unavailable retry_in_seconds=%d", retry_delay)
                stop.wait(retry_delay)
                retry_delay = min(retry_delay * 2, 30)
                continue
            retry_delay = 2
            if args.once:
                break
            if not worked:
                stop.wait(1)
    finally:
        repository.close()


if __name__ == "__main__":
    main()
