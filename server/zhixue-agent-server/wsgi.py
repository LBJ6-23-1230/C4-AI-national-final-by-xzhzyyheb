"""gunicorn --config deploy/gunicorn.conf.py wsgi:application"""
from app.settings import load_environment

load_environment()
from app import create_app

application = create_app()
