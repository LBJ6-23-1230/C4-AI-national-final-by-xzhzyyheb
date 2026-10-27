from pathlib import Path
import importlib.util

import pytest
from app.settings import validate_config
from tools.migrate_postgresql import prepare


def test_production_rejects_file_backend_and_demo(monkeypatch):
    monkeypatch.setenv("APP_ENV", "production")
    monkeypatch.setenv("ZHIXUE_DB", "json")
    with pytest.raises(RuntimeError, match="postgresql"):
        validate_config()


def test_import_detects_cross_owner_references_and_duplicate_normalized_phone():
    source = {"users": {"one": {"userId": "one", "phone": "13900000001"},
                        "two": {"userId": "two", "phone": "+86 13900000001"}},
              "knowledge_bases": {"kb": {"userId": "one", "kbId": "kb"}},
              "documents": {"doc": {"userId": "two", "documentId": "doc", "kbId": "kb"}}}
    _, errors = prepare(source)
    assert any("duplicate phone" in error for error in errors)
    assert any("mismatch" in error for error in errors)


def test_app_release_generator_requires_public_https_domain():
    path = Path(__file__).resolve().parents[3] / "tools/prepare_app_environment.py"
    spec = importlib.util.spec_from_file_location("app_build_environment", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    for address in ("http://api.school.cn", "https://127.0.0.1", "https://api.example.com", "https://localhost", "https://host.cn/path", "https://host.cn/'bad"):
        with pytest.raises(ValueError):
            module.render("production", address)
    output = module.render("production", "https://api.school.cn")
    assert "ALLOW_DEBUG: boolean = false" in output
    assert "ALLOW_DEMO: boolean = false" in output
