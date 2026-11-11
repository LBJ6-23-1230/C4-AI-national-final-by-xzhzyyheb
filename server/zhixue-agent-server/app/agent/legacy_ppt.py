"""Slide text extraction for the PowerPoint 97–2003 binary format (MS-PPT)."""

import io
import struct

import olefile


DOCUMENT = 0x03E8
SLIDE = 0x03EE
SLIDE_PERSIST = 0x03F3
DRAWING = 0x040C
TEXT_CHARS = 0x0FA0
TEXT_BYTES = 0x0FA8
SLIDE_LIST = 0x0FF0
USER_EDIT = 0x0FF5
CURRENT_USER = 0x0FF6
PERSIST_DIRECTORY = 0x1772
CLIENT_TEXTBOX = 0xF00D
DRAWING_CONTAINERS = {DRAWING, 0xF002, 0xF003, 0xF004}
RECORD_HEADER = struct.Struct('<HHI')


class LegacyPptError(ValueError):
    """A binary deck that needs a specific explanation."""


def _record_at(data, offset):
    flags, kind, length = RECORD_HEADER.unpack_from(data, offset)
    start = offset + RECORD_HEADER.size
    end = start + length
    if end > len(data):
        raise ValueError('record exceeds stream boundary')
    return flags, kind, data[start:end], end


def _records(data):
    offset = 0
    while offset < len(data):
        flags, kind, body, offset = _record_at(data, offset)
        yield flags, kind, body


def _persist_offsets(data, edit_offset):
    offsets = {}
    document_id = None
    while edit_offset:
        _, kind, edit, _ = _record_at(data, edit_offset)
        if kind != USER_EDIT or len(edit) not in (28, 32):
            raise ValueError('invalid edit record')
        if len(edit) == 32 and struct.unpack_from('<I', edit, 28)[0]:
            raise LegacyPptError('PPT 已加密，请上传解锁后的文件。')
        previous, directory_offset, current_document_id = struct.unpack_from('<III', edit, 8)
        if not previous < directory_offset < edit_offset:
            raise ValueError('invalid edit chain')
        if document_id is None:
            document_id = current_document_id
        _, kind, directory, end = _record_at(data, directory_offset)
        if kind != PERSIST_DIRECTORY or end > edit_offset:
            raise ValueError('invalid persist directory')
        cursor = 0
        while cursor < len(directory):
            entry, = struct.unpack_from('<I', directory, cursor)
            first_id, count = entry & 0xFFFFF, entry >> 20
            cursor += 4
            if not count or cursor + count * 4 > len(directory):
                raise ValueError('invalid persist entry')
            for index in range(count):
                offset, = struct.unpack_from('<I', directory, cursor + index * 4)
                if not previous <= offset < directory_offset:
                    raise ValueError('invalid persist offset')
                offsets.setdefault(first_id + index, offset)
            cursor += count * 4
        edit_offset = previous
    return offsets, offsets[document_id]


def _text(kind, body):
    encoding = 'utf-16le' if kind == TEXT_CHARS else 'latin-1'
    text = bytes(body).decode(encoding).replace('\r', '\n').replace('\v', '\n')
    return ''.join(char for char in text if char in '\n\t' or ord(char) >= 32).strip()


def _shape_text(records, depth=0):
    if depth > 64:
        raise ValueError('drawing nesting exceeds limit')
    for flags, kind, body in _records(records):
        if kind == CLIENT_TEXTBOX:
            for _, text_kind, text_body in _records(body):
                if text_kind in (TEXT_CHARS, TEXT_BYTES):
                    yield _text(text_kind, text_body)
        elif kind in DRAWING_CONTAINERS and flags & 0xF == 0xF:
            yield from _shape_text(body, depth + 1)


def extract_slides(raw, max_slides):
    with olefile.OleFileIO(io.BytesIO(raw)) as compound:
        if any(compound.get_size(name) > len(raw) for name in ('Current User', 'PowerPoint Document')):
            raise ValueError('invalid stream size')
        current_user = compound.openstream('Current User').read(20)
        _, kind, _, _, token, edit_offset = struct.unpack('<HHIIII', current_user)
        if kind != CURRENT_USER:
            raise ValueError('invalid current user record')
        if token == 0xF3D1C4DF:
            raise LegacyPptError('PPT 已加密，请上传解锁后的文件。')
        data = memoryview(compound.openstream('PowerPoint Document').read())

    offsets, document_offset = _persist_offsets(data, edit_offset)
    _, kind, document, _ = _record_at(data, document_offset)
    if kind != DOCUMENT:
        raise ValueError('invalid document record')
    slide_list = next((body for flags, kind, body in _records(document)
                       if kind == SLIDE_LIST and flags == 0xF), b'')
    slides = []
    visited = set()
    for _, kind, body in _records(slide_list):
        if kind == SLIDE_PERSIST:
            if len(slides) >= max_slides:
                raise LegacyPptError(f'PPT 超过 {max_slides} 页解析上限，请拆分后上传。')
            slide_id, = struct.unpack_from('<I', body)
            offset = offsets[slide_id]
            if offset in visited:
                raise ValueError('duplicate slide offset')
            visited.add(offset)
            _, slide_kind, slide, _ = _record_at(data, offset)
            if slide_kind != SLIDE:
                raise ValueError('invalid slide record')
            slides.append(([], slide))
        elif kind in (TEXT_CHARS, TEXT_BYTES) and slides:
            slides[-1][0].append(_text(kind, body))
    return ['\n'.join(filter(None, (*outline, *_shape_text(slide)))) for outline, slide in slides]
