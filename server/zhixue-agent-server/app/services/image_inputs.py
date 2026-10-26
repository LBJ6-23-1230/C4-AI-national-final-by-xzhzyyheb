"""Validate current-message image bytes before routing them to vision."""
import base64
import hashlib


def inspect_image(value):
    if not value:
        return {"status": "missing", "message": "本次消息未附图片"}
    try:
        raw = base64.b64decode(value, validate=True)
        if not raw or len(raw) > 5 * 1024 * 1024:
            raise ValueError()
        import pymupdf
        with pymupdf.open(stream=raw) as image:
            if image.is_pdf or len(image) != 1:
                raise ValueError()
            rect = image[0].rect
            if rect.width <= 0 or rect.height <= 0 or rect.width * rect.height > 36_000_000:
                raise ValueError()
        return {"status": "received", "message": "图片已接收", "sizeBytes": len(raw),
                "attachmentId": hashlib.sha256(raw).hexdigest()[:24]}
    except Exception:
        return {"status": "invalid", "message": "图片内容无效或格式无法解码，请重新选择图片后发送"}
