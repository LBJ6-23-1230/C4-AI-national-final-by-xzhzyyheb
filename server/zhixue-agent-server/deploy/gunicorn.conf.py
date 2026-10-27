import os

bind = "0.0.0.0:8000"
workers = int(os.getenv("WEB_CONCURRENCY", "2"))
threads = int(os.getenv("WEB_THREADS", "4"))
worker_class = "gthread"
timeout = 70
graceful_timeout = 60
keepalive = 5
# Construct connection pools after fork.
preload_app = False
accesslog = "-"
# Never log query strings, auth headers or request bodies.
access_log_format = '%(t)s %(m)s %(U)s %(s)s %(L)s'
errorlog = "-"
max_requests = 1000
max_requests_jitter = 100
