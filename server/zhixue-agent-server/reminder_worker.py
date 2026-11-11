"""Independent reminder clock. Never start a scanner from a web worker."""
import argparse
import logging
import signal
import threading

from app import create_app
from app.services import reminders
from app.services.push_provider import send, configured


def tick(repo):
    owners = {u['userId'] for u in repo.list('users') if u.get('status') != 'deactivated'}
    for owner in sorted(owners):
        reminders.schedule(repo, owner)
    if configured():
        for _ in range(50):
            if not reminders.deliver_once(repo, send):
                break


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    repo = create_app().extensions['repository']
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    try:
        while not stop.is_set():
            try:
                tick(repo)
            except Exception:
                logging.exception('reminder_tick_failed')
            if args.once:
                break
            stop.wait(30)
    finally:
        repo.close()


if __name__ == '__main__':
    main()
