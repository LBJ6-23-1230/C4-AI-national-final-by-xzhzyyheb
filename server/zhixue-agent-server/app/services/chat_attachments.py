"""Private chat originals and bounded previews; originals never enter history payloads."""
import base64

from app.services.file_storage import storage, schedule_delete


def prepare(repository, owner, encoded):
    import pymupdf
    raw = base64.b64decode(encoded, validate=True)
    with pymupdf.open(stream=raw) as document:
        page = document[0]
        scale = min(1, 720 / max(page.rect.width, page.rect.height))
        for _ in range(6):
            preview = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False).tobytes("jpeg", jpg_quality=70)
            if len(preview) <= 80_000:
                break
            scale *= 0.7
    record = storage().put(owner, raw, "chat-image")
    record["purpose"] = "chat_image"
    return record, "data:image/jpeg;base64," + base64.b64encode(preview).decode("ascii")


def release(repository, entries):
    if repository is None:
        return
    for entry in entries:
        file_id = entry.get("image_file_id")
        original = repository.get("file_objects", file_id) if file_id else None
        if not original or original.get("purpose") != "chat_image":
            continue
        if getattr(repository, "durable_jobs", False):
            schedule_delete(repository, original)
            repository.save("file_objects", file_id, dict(original, status="delete_pending"))
        else:
            storage().delete(original)
            repository.delete("file_objects", file_id)
