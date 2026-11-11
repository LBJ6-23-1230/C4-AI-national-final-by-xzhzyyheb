"""Extract and draw self-contained objective questions from uploaded files."""

import hashlib
import io
import re
import zipfile
from functools import lru_cache
from xml.etree import ElementTree

from app.agent import knowledge
from app.services.exercise_quality import is_subject_question
from app.services.file_storage import storage

MODE = 'document_bank'
MAX_ROUND = 20
_NAME = re.compile(r'题库|试题|客观题|练习题|习题|真题|模拟卷|题目|试卷')
_BOUNDARY = re.compile(r'(?m)^[ \t]*(?:\d{1,4}[.．、](?!\d)[ \t]*|(?=第[^\n]{1,18}[章节]|[一二三四五六七八九十]+、))')
_NUMBER = re.compile(r'\d{1,4}[.．、]')
_OPTION = re.compile(r'(?:^|\s)([A-HＡ-Ｈ])[.．、:：)）][ \t]*')
_ANSWER = r'[A-HＡ-Ｈ√×✓✗对错]|正确|错误'
_INLINE_KEY = re.compile(r'[（(]\s*(' + _ANSWER + r')\s*[）)]\s*$')
_LABELED_KEY = re.compile(r'(?:^|\n)[ \t]*(?:参考答案|正确答案|答案)[ \t]*[:：][ \t]*(' + _ANSWER + r')\s*$')
_UNVERIFIED = re.compile(r'(?m)^.*(?:答案还没出|答案未核实|答案未经核实|答案是\s*AI\s*给的).*$')
_OBJECT = '\ufffc'
_WORD = '{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'


def _docx_text(raw):
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        info = archive.getinfo('word/document.xml')
        if info.file_size > 32 * 1024 * 1024:
            return ''
        root = ElementTree.fromstring(archive.read(info))
    parts = []
    for paragraph in root.iter(_WORD + 'p'):
        line = []
        for node in paragraph.iter():
            if node.tag == _WORD + 't':
                line.append(node.text or '')
            elif node.tag in (_WORD + 'br', _WORD + 'tab'):
                line.append(' ')
            elif node.tag.rsplit('}', 1)[-1] in ('oMath', 'drawing', 'pict', 'object', 'sym'):
                line.append(_OBJECT)
        parts.append(''.join(line))
    return '\n'.join(parts)


def parse_questions(text):
    unverified = _UNVERIFIED.search(text)
    if unverified:
        text = text[:unverified.start()]
    boundaries = list(_BOUNDARY.finditer(text))
    by_stem = {}
    conflicts = set()
    for index, start in enumerate(boundaries):
        if not _NUMBER.search(start.group()):
            continue
        block = text[start.end():boundaries[index + 1].start() if index + 1 < len(boundaries) else len(text)].strip()
        if _OBJECT in block or '\ufffd' in block:
            continue
        trailing = _LABELED_KEY.search(block)
        if trailing:
            block = block[:trailing.start()].rstrip()
        markers = list(_OPTION.finditer(block))
        stem = block[:markers[0].start()].strip() if markers else block
        inline = _INLINE_KEY.search(stem)
        if inline:
            stem = stem[:inline.start()].rstrip()
        if not (inline or trailing) or (inline and trailing and inline[1] != trailing[1]):
            continue
        answer = (inline or trailing)[1].translate(str.maketrans('ＡＢＣＤＥＦＧＨ', 'ABCDEFGH'))
        stem = ' '.join(stem.split())
        if not 4 <= len(stem) <= 1200:
            continue
        if markers:
            labels = [m[1].translate(str.maketrans('ＡＢＣＤＥＦＧＨ', 'ABCDEFGH')) for m in markers]
            bodies = [' '.join(block[m.end():markers[i + 1].start() if i + 1 < len(markers) else len(block)].split())
                      for i, m in enumerate(markers)]
            if (not 2 <= len(labels) <= 8 or labels != list('ABCDEFGH'[:len(labels)]) or answer not in labels
                    or not all(0 < len(body) <= 400 for body in bodies) or len(set(bodies)) != len(bodies)):
                continue
            options = [f'{label}. {body}' for label, body in zip(labels, bodies)]
        elif answer in ('√', '✓', '对', '正确', '×', '✗', '错', '错误'):
            options = ['A. 正确', 'B. 错误']
            answer = 'A' if answer in ('√', '✓', '对', '正确') else 'B'
        else:
            continue
        key = re.sub(r'\s+', '', stem).casefold()
        item = (stem, tuple(options), answer)
        if key in by_stem and by_stem[key] != item:
            conflicts.add(key)
        by_stem.setdefault(key, item)
    return tuple(item for key, item in by_stem.items() if key not in conflicts)


@lru_cache(maxsize=64)
def _original_questions(file_id, owner, object_key, size, digest, bucket, name):
    raw = storage().read(dict(fileId=file_id, userId=owner, objectKey=object_key,
                              sizeBytes=size, sha256=digest, bucket=bucket, fileName=name))
    if len(raw) > knowledge.MAX_FILE_BYTES:
        return ()
    if knowledge.extension_of(name) == '.docx':
        return parse_questions(_docx_text(raw))
    for encoding in ('utf-8-sig', 'gb18030'):
        try:
            return parse_questions(raw.decode(encoding))
        except UnicodeDecodeError:
            pass
    return ()


def candidates(repository, owner, document):
    if document.get('status') != 'ready':
        return []
    name = document['fileName']
    extension = knowledge.extension_of(name)
    original = repository.get('file_objects', document.get('fileId', ''))
    try:
        if extension in ('.docx', '.txt', '.md', '.markdown') and original:
            if original.get('userId') != owner or original.get('documentId') != document['documentId']:
                return []
            rows = _original_questions(original['fileId'], owner, original['objectKey'],
                                       original['sizeBytes'], original['sha256'], original.get('bucket', ''), name)
        elif extension in ('.txt', '.md', '.markdown'):
            scope = {k: document[k] for k in ('documentId', 'kbId', 'userId')}
            chunks = sorted(repository.query('chunks', scope), key=lambda row: row.get('index', 0))
            rows = parse_questions('\n'.join(row['text'] for row in chunks))
        else:
            return []
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, ElementTree.ParseError):
        return []
    result = []
    for stem, options, answer in rows:
        digest = hashlib.sha256('\0'.join((owner, document['documentId'], stem, *options, answer)).encode()).hexdigest()
        question = dict(exerciseId=f'original-{digest[:36]}', stem=stem, options=list(options), answerKey=answer,
                        knowledgePointId='unknown', knowledgePointName='题库原题', source=MODE, difficulty='unknown',
                        explanation='按上传文件中标注的答案判分。', sourceFileName=name)
        if is_subject_question(question):
            result.append(question)
    return result


def for_course(repository, owner, course):
    from app.services.grounded_exercises import course_bases
    bases = course_bases(repository, owner, course) if course else repository.query('knowledge_bases', {'userId': owner})
    return [document for base in bases
            for document in repository.query('documents', {'userId': owner, 'kbId': base['kbId']})
            if document.get('status') == 'ready' and _NAME.search(document['fileName'])]


def used_ids(repository, owner):
    return {row['exerciseId'] for row in repository.query('exercise_usage', {'userId': owner})}
