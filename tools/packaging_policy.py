"""Shared source-package policy; never export runtime data or local signing material."""
import os
import re
from pathlib import Path

EXCLUDE_DIRS = {'.git', '.hvigor', '.idea', '.vscode', 'build', 'oh_modules',
                'node_modules', '__pycache__', '.pytest-tmp', '.pytest_cache',
                '.cxx', '.local-work', '.packaging', 'deliverables', '.uv-cache'}
EXCLUDE_SUFFIXES = ('.pyc', '.pyo', '.bak', '.bak-round0', '.har', '.zip', '.tmp', '.log',
                    '.process.lock', '.sqlite', '.sqlite3', '.db', '-wal', '-shm', '-journal',
                    '.p12', '.pfx', '.pem', '.key', '.p7b', '.cer', '.jks', '.keystore')
EXCLUDE_NAMES = {'repository.json', 'history.json', 'local.properties', 'Thumbs.db', '.DS_Store'}


def should_skip(path):
    path = Path(path)
    return (path.name in EXCLUDE_NAMES or
            path.name.startswith(('repository.json.', 'repository.sqlite', 'history.json.')) or
            (path.name.startswith('.env') and path.name != '.env.example') or
            path.name.lower().endswith(EXCLUDE_SUFFIXES) or
            any(p in EXCLUDE_DIRS or p.startswith(('.venv', 'pytest-cache-files-', 'pytest-of-'))
                for p in path.parts))


def iter_source_files(base):
    for current, dirs, files in os.walk(base, onerror=lambda error: (_ for _ in ()).throw(error)):
        dirs[:] = sorted(d for d in dirs if not should_skip(Path(current) / d)
                         and not (Path(current) / d).is_symlink())
        for name in sorted(files):
            path = Path(current) / name
            if not path.is_symlink() and not should_skip(path):
                yield path


def sanitized_bytes(path):
    data = path.read_bytes()
    if path.name != 'build-profile.json5':
        return data
    text = data.decode('utf-8-sig')
    # Tokenize strings/comments as indivisible tokens, so brackets inside passwords
    # or comments cannot terminate the signing array early.
    token_re = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/|[A-Za-z_$][\w$]*|[^\s]')
    tokens = [t for t in token_re.finditer(text) if not t.group().startswith(('//', '/*'))]
    removals = []
    for i, token in enumerate(tokens):
        key = token.group().strip('\'"')
        if key not in ('signingConfigs', 'signingConfig') or i+2 >= len(tokens):
            continue
        if tokens[i+1].group() != ':':
            continue
        end = i+2
        if key == 'signingConfigs':
            if tokens[end].group() != '[':
                raise ValueError('Unexpected signing configuration syntax')
            depth = 0
            for end in range(end, len(tokens)):
                value = tokens[end].group()
                if value == '[': depth += 1
                elif value == ']': depth -= 1
                if depth == 0: break
            if depth:
                raise ValueError('Unclosed signing configuration')
        begin = token.start()
        finish = tokens[end].end()
        if end+1 < len(tokens) and tokens[end+1].group() == ',':
            finish = tokens[end+1].end()
        elif key == 'signingConfig' and i > 0 and tokens[i-1].group() == ',':
            begin = tokens[i-1].start()
        replacement = '"signingConfigs": [],' if key == 'signingConfigs' and text[finish-1:finish] == ',' else ('"signingConfigs": []' if key == 'signingConfigs' else '')
        removals.append((begin, finish, replacement))
    for begin, end, replacement in reversed(removals):
        text = text[:begin] + replacement + text[end:]
    return text.encode('utf-8')


def assert_safe_content(data, name):
    text = data.decode('utf-8', errors='ignore')
    for match in re.finditer(r'sk-[A-Za-z0-9]{16,}', text):
        if set(match.group()[3:].lower()) != {'x'}:
            raise ValueError(f'Possible API key in {name}; packaging stopped')
