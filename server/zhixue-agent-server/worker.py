"""Recover queued/expired work; SIGTERM stops claiming and completes the current job."""
import argparse
import logging
import signal
import threading

from app.settings import load_environment

load_environment()
from app import create_app
from app.services.job_queue import run_once


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
    try:
        while not stop.is_set():
            worked = run_once(repository)
            if args.once:
                break
            if not worked:
                stop.wait(2)
    finally:
        repository.close()


if __name__ == "__main__":
    main()
