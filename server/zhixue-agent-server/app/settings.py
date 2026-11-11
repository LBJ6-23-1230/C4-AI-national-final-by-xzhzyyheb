"""Shared configuration for development, WSGI, migrations and workers."""
import os
from pathlib import Path

from dotenv import load_dotenv


def load_environment():
    load_dotenv(Path(__file__).resolve().parents[1] / ".env", override=False, encoding="utf-8-sig")


def production():
    return os.getenv("APP_ENV", os.getenv("ZHIXUE_ENV", "development")).lower() == "production"


def demo_enabled():
    return os.getenv("DEMO_ENABLED", "false" if production() else "true").lower() in {"1", "true", "yes"}


def validate_config():
    if not production():
        return
    if os.getenv("ZHIXUE_DB", "").lower() != "postgresql":
        raise RuntimeError("production requires ZHIXUE_DB=postgresql")
    if not os.getenv("DATABASE_URL"):
        raise RuntimeError("DATABASE_URL is required")
    from sqlalchemy.engine import make_url
    url = make_url(os.environ["DATABASE_URL"])
    if url.query.get("sslmode") != "verify-full" or not url.query.get("sslrootcert"):
        raise RuntimeError("production DATABASE_URL requires sslmode=verify-full and sslrootcert")
    if demo_enabled() or os.getenv("ZHIXUE_ENABLE_DEV_TOOLS", "0").lower() not in {"0", "false"}:
        raise RuntimeError("disable DEMO_ENABLED and ZHIXUE_ENABLE_DEV_TOOLS in production")
    if os.getenv("ZHIXUE_ENV", "production").lower() in {"development", "dev", "test", "testing"}:
        raise RuntimeError("production must not enable development verification codes")
    if os.getenv("ZHIXUE_CORS_ORIGINS") == "*":
        raise RuntimeError("wildcard CORS is disabled in production")
    if os.getenv("FILE_STORAGE") not in {"s3", "obs"}:
        raise RuntimeError("production requires private object storage: FILE_STORAGE=obs or s3")
    for name in ("S3_ENDPOINT_URL", "S3_BUCKET", "S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY"):
        if not os.getenv(name):
            raise RuntimeError(f"{name} is required")
    if not os.environ["S3_ENDPOINT_URL"].startswith("https://"):
        raise RuntimeError("object storage endpoint must use HTTPS")
