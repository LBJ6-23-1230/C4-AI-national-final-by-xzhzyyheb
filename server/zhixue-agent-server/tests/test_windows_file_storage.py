import os
from pathlib import Path
import pytest
from app.services.file_storage import FileStorage


@pytest.mark.skipif(os.name != 'nt', reason='Windows long-path filesystem regression')
def test_upload_read_delete_in_deep_extracted_project_keeps_traversal_guard(tmp_path, monkeypatch):
    root = tmp_path.joinpath(*(['deep-extracted-project-' + 'x' * 35] * 4))
    monkeypatch.setenv('FILE_STORAGE', 'local')
    monkeypatch.setenv('FILE_STORAGE_DIR', str(root))
    store = FileStorage()
    raw = b'local original under a long extracted project path'
    record = store.put('test-owner', raw, 'example.txt')
    assert len(str(root / record['objectKey'])) > 260
    assert store.read(record) == raw
    with pytest.raises(ValueError, match='invalid object key'):
        store._path('../outside.txt')
    store.delete(record)
    assert not store._path(record['objectKey']).exists()
