FROM python:3.12.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv/zhixue
COPY requirements.txt requirements-lock-py312.txt ./
RUN pip install -r requirements.txt && useradd --uid 10001 --create-home app
COPY --chown=app:app . .
RUN mkdir -p data && chown app:app data
USER app
EXPOSE 8000
CMD ["gunicorn", "--config", "deploy/gunicorn.conf.py", "wsgi:application"]
