"""Owner scoped practice rounds and content identity, independent of model IDs."""
import hashlib
import json
import re
import unicodedata


def fingerprint(question):
    # A fresh UUID or shuffled answer options does not make a new question.
    stem = unicodedata.normalize('NFKC', str(question.get('stem', ''))).casefold()
    return hashlib.sha256(re.sub(r'\W+', '', stem).encode()).hexdigest()


def identity(owner, round_id):
    return hashlib.sha256((owner + '\0' + round_id).encode()).hexdigest()


def signature(course, point, difficulty, count, excluded, fresh):
    return json.dumps([course, point, difficulty, count, sorted(set(excluded)), fresh], ensure_ascii=False)


def previous_questions(repository, owner, candidates, include_issued):
    bank = {q['exerciseId']: q for q in candidates}
    used = {r['exerciseId'] for r in repository.list('exercise_usage') if r.get('userId') == owner}
    questions = [bank.get(qid) or repository.get('exercises', qid) for qid in used]
    if include_issued:
        questions.extend(q for r in repository.list('practice_rounds') if r.get('userId') == owner
                         for q in r.get('response', {}).get('exercises', []))
    return [q for q in questions if q]
