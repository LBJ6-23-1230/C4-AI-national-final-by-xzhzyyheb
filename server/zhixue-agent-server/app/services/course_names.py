"""Canonical course lists for matching; conjunctions in course names remain intact."""
import re

KNOWN_COURSES = ("数据结构", "计算机网络", "操作系统", "计算机组成原理", "数据库原理", "高等数学",
                 "线性代数", "概率论与数理统计", "编译原理", "软件工程", "人工智能")
ALIASES = {"概率统计": "概率论与数理统计", "计算机组成": "计算机组成原理", "数据库": "数据库原理"}


def course_names(value):
    values = value if isinstance(value, list) else [value]
    result = []
    for raw in values:
        if not isinstance(raw, str):
            continue
        for part in re.split(r"[、,，;；\n]+", raw):
            part = part.strip()
            parts = re.split(r"\s*(?:与|和|及|&)\s*", part)
            if len(parts) < 2 or not all(p in KNOWN_COURSES or p in ALIASES for p in parts):
                parts = [part]
            for name in parts:
                name = ALIASES.get(name, name)
                if name and name not in result:
                    result.append(name)
    return result


def profile_courses(profile):
    return course_names(profile.get("targetCourses") or profile.get("targetCourse", ""))
