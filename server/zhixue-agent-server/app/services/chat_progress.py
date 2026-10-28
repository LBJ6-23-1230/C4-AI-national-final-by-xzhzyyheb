"""Optional SSE transport around the unchanged, authoritative chat operation.

Progress is advisory. Only the terminal result authorizes client-side updates.
A disconnected client does not replay or cancel an already accepted mutation.
"""
from concurrent.futures import ThreadPoolExecutor
from contextvars import ContextVar
import json
import logging
from queue import Queue, Empty, Full
import threading

from flask import Response, copy_current_request_context, current_app, g, request

_sink = ContextVar("chat_progress_sink", default=None)
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="chat-stream")
_slots = threading.BoundedSemaphore(8)


def emit(stage, message, reply=""):
    sink = _sink.get()
    if sink:
        sink("progress", {"stage": stage, "message": message, "reply": reply})


def stream_response(operation):
    # Parse/cache the body in the request thread before copying the context.
    request.get_data()
    slots = _slots
    if not slots.acquire(blocking=False):
        return {"errorCode": "BUSY", "message": "当前请求较多，请稍后重试", "details": None}, 503
    application = current_app._get_current_object()
    identity_context = dict(g.__dict__)
    events = Queue(maxsize=32)
    disconnected = threading.Event()

    def send(kind, data):
        if disconnected.is_set():
            return
        try:
            events.put_nowait((kind, data))
        except Full:
            # Retain terminal messages even if a client consumes progress slowly.
            if kind != "progress":
                try:
                    events.get_nowait()
                except Empty:
                    pass
                events.put_nowait((kind, data))

    @copy_current_request_context
    def run():
        g.__dict__.update(identity_context)
        token = _sink.set(send)
        try:
            try:
                response = application.make_response(operation())
            except Exception as error:
                response = application.make_response(application.handle_user_exception(error))
            data = response.get_json(silent=True)
            if response.status_code >= 400:
                send("error", {"status": response.status_code, "body": data})
            else:
                send("result", data)
        except Exception:
            logging.getLogger("zhixue.llm").warning("chat_stream_failed")
            send("error", {"status": 500, "body": {"message": "本次处理未完成，请稍后查看会话记录"}})
        finally:
            _sink.reset(token)

    try:
        future = _pool.submit(run)
    except BaseException:
        slots.release()
        raise
    future.add_done_callback(lambda _: slots.release())

    def frame(kind, data):
        # ASCII framing also makes arbitrary network packet splits harmless.
        return "event: " + kind + "\ndata: " + json.dumps(data, ensure_ascii=True) + "\n\n"

    def generate():
        try:
            yield frame("progress", {"stage": "accepted", "message": "请求已接收，等待处理", "reply": ""})
            while True:
                try:
                    kind, data = events.get(timeout=5)
                except Empty:
                    yield ": keep-alive\n\n"
                    continue
                yield frame(kind, data)
                if kind in ("result", "error"):
                    break
        finally:
            disconnected.set()

    return Response(generate(), mimetype="text/event-stream", headers={
        "Cache-Control": "no-store", "X-Accel-Buffering": "no"})
