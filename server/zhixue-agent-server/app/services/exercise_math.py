"""Recompute supported numerical questions independently of model answers."""
from fractions import Fraction
from decimal import Decimal, localcontext
import heapq
import re
import unicodedata


_NUMBER = r"[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:/\d+)?%?"
_VALUES = rf"{_NUMBER}(?:[\s,、;]+{_NUMBER})+"
_WEIGHTS = r"(?:权值|权重|频率|频数|weights?|frequencies)"
_WEIGHT_PREFIX = rf"{_WEIGHTS}\s*(?:集合|序列)?\s*(?:(?:分别|依次)\s*)?(?:(?:为|是|are|is)\s*)?[:=]?\s*"
_LABEL = re.compile(r"^\s*[A-D]\s*[.、:：]\s*", re.I)


def _number(text):
    text = text.strip()
    if not re.fullmatch(_NUMBER, text) or len(text) > 32:
        return None
    try:
        return Fraction(text.rstrip('%')) / (100 if text.endswith('%') else 1)
    except (ValueError, ZeroDivisionError):
        return None


def _option_number(option):
    text = unicodedata.normalize('NFKC', str(option))
    body = _LABEL.sub('', text).strip()
    match = re.fullmatch(rf"(?:WPL\s*[=:]\s*)?({_NUMBER})(?:\s*(?:位|比特|bits?))?", body, re.I)
    return _number(match[1]) if match else None


def _display(value):
    if value.denominator == 1:
        return str(value.numerator)
    denominator = value.denominator
    for factor in (2, 5):
        while denominator % factor == 0:
            denominator //= factor
    if denominator != 1:
        return str(value)
    with localcontext() as context:
        context.prec = 100
        return format(Decimal(value.numerator) / Decimal(value.denominator), 'f').rstrip('0').rstrip('.')


def _huffman_wpl(item):
    """Return an exact total and derivation; reject ambiguous numerical variants."""
    stem = unicodedata.normalize('NFKC', str(item.get('stem', '')))
    context = stem + ' ' + str(item.get('knowledgePointName', ''))
    if not re.search(r'哈夫曼|霍夫曼|huffman|最优二叉树', context, re.I) or not re.search(r'带权路径长度|(?<![a-z])WPL(?![a-z])', stem, re.I):
        return None
    values = [_option_number(option) for option in item.get('options', [])]
    if not any(value is not None for value in values):
        return None
    if len(values) != 4 or any(value is None for value in values):
        raise ValueError('Unsupported WPL options')
    if re.search(r'平均|子树|最大|增加|减少|变化|之差|归一|(?:[3-9]\d*|[12]\d+|[三四五六七八九十百多kdmn])-?\s*(?:叉|元)|ternary|非最优|不是.*哈夫曼|不采用.*哈夫曼', stem, re.I):
        raise ValueError('Unsupported WPL variant')
    continuation = rf'[\d./%eE]|\s*(?:[,、;]|和|及|与|以及)\s*{_NUMBER}'
    pattern = rf'{_WEIGHT_PREFIX}(?:[{{\[(]\s*({_VALUES})\s*[}}\])]|({_VALUES})(?!{continuation}))'
    lists = [bracketed or bare for bracketed, bare in re.findall(pattern, stem, re.I)]
    if len(lists) != 1:
        raise ValueError('Ambiguous WPL weights')
    weights = [_number(part) for part in re.split(r'[\s,、;]+', lists[0].strip())]
    if not 2 <= len(weights) <= 64 or any(value is None or value < 0 for value in weights):
        raise ValueError('Invalid WPL weights')
    heap = weights[:]
    heapq.heapify(heap)
    total, steps = Fraction(0), []
    while len(heap) > 1:
        left, right = heapq.heappop(heap), heapq.heappop(heap)
        merged = left + right
        total += merged
        steps.append(f'{_display(left)}+{_display(right)}={_display(merged)}')
        heapq.heappush(heap, merged)
    explanation = ('每次合并当前最小的两个权值：' + '；'.join(steps) +
                   '。带权路径长度等于各次合并权值之和，WPL=' +
                   '+'.join(step.split('=')[1] for step in steps) + '=' + _display(total) + '。')
    return total, values, explanation


def normalize_calculation(item):
    """Repair new, verifiable WPL results before they are ever issued or stored."""
    try:
        result = _huffman_wpl(item)
    except ValueError:
        return None
    if result is None:
        return item
    total, values, explanation = result
    if len(set(values)) != 4:
        return None
    corrected = dict(item, options=list(item['options']), explanation=explanation)
    if total in values:
        index = values.index(total)
    else:
        answer = item.get('answerKey')
        if answer not in ('A', 'B', 'C', 'D'):
            return None
        index = 'ABCD'.index(answer)
        corrected['options'][index] = f'{"ABCD"[index]}. {_display(total)}'
    corrected['answerKey'] = 'ABCD'[index]
    return corrected


def calculation_is_valid(item):
    """Check stored questions without changing anything already shown to a user."""
    try:
        result = _huffman_wpl(item)
    except ValueError:
        return False
    if result is None:
        return True
    total, values, _ = result
    answer = str(item.get('answerKey', ''))
    return (len(set(values)) == 4 and values.count(total) == 1 and answer in ('A', 'B', 'C', 'D')
            and values['ABCD'.index(answer)] == total)


def calculation_explanation(item):
    try:
        result = _huffman_wpl(item)
    except ValueError:
        return ''
    return result[2] if result is not None and calculation_is_valid(item) else ''
