"""Reject questions about syllabus labels instead of subject knowledge."""
import re


def is_subject_question(item):
    stem = str(item.get("stem") or "")
    if re.search(r"(?:掌握|熟悉|了解).{0,8}(?:程度|要求)|(?:程度|要求).{0,8}(?:掌握|熟悉|了解)|是否必考|考纲.{0,8}要求", stem):
        return False
    levels = 0
    for option in item.get("options", []):
        body = re.sub(r"^[A-D]\s*[.、．:：]\s*", "", str(option)).strip()
        if re.fullmatch(r"(?:重点|基本|熟练)?掌握(?:[，,、 ]*必考)?|熟悉|了解|基础|不要求|一般了解", body):
            levels += 1
    return levels < 3


def has_subject_content(text):
    """Syllabus tables alone cannot substantiate a subject exercise."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    useful = [line for line in lines if not re.search(r"掌握|熟悉|了解|必考|考试要求", line)
              or re.search(r"是指|定义|称为|因此|因为|满足|复杂度为|O\(|结点|节点|指针|遍历顺序|当.+时|若.+则", line)]
    return len("".join(useful)) >= 20
