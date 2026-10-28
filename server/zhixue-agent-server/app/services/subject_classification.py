"""Conservative subject inference for legacy topic-as-course records.

Read projections only: never rewrite users' answers or practice counters.
"""
import re
from app.services.course_names import KNOWN_COURSES, ALIASES

TOPICS = {
    '数据结构': ('栈', '队列', '链表', '二叉树', '哈希', '散列', '排序', '图算法', '线性表', '最短路径', 'push', 'pop', 'lifo'),
    '计算机网络': ('tcp', 'udp', 'http', 'ip协议', '路由', '网络协议', '三次握手', '四次挥手', '拥塞控制'),
    '操作系统': ('进程', '线程', '死锁', '虚拟内存', '页面置换', '文件系统', '信号量'),
    '数据库原理': ('sql', '数据库', '事务隔离', '关系代数'),
    '高等数学': ('微积分', '导数', '极限', '积分'),
    '线性代数': ('矩阵', '特征值', '行列式'),
}


def subject(course='', point='', stem='', profile=None):
    course = str(course or '').strip()
    course = ALIASES.get(course, course)
    if course in KNOWN_COURSES or course == '大学英语':
        return course
    text = (str(point or '') + ' ' + str(stem or '') + ' ' + course).casefold()
    scores = {name: sum(term in text for term in terms) for name, terms in TOPICS.items()}
    ranked = sorted(scores, key=scores.get, reverse=True)
    if scores[ranked[0]] and scores[ranked[0]] > scores[ranked[1]]:
        return ranked[0]
    if profile:
        for row in profile.get('mastery') or []:
            if isinstance(row, dict) and row.get('knowledgePointName') == point and row.get('sourceCourse') in KNOWN_COURSES:
                return row['sourceCourse']
    # Preserve legitimate custom courses, but do not promote topic text to a course.
    looks_like_topic = course == point or any(term in course.casefold() for terms in TOPICS.values() for term in terms)
    if course and course not in ('待分类', '其他', '待确认科目') and not looks_like_topic and len(course) <= 30:
        return course
    return '待确认科目'


def topic_group(point):
    point = str(point or '').strip()
    if '栈' in point or re.search(r'\b(push|pop|lifo)\b', point, re.I):
        return '栈'
    if '队列' in point:
        return '队列'
    if '链表' in point:
        return '链表'
    return point or '待确认知识点'


def normalized_mastery(profile):
    rows = []
    for row in profile.get('mastery') or []:
        if not isinstance(row, dict):
            continue
        item = dict(row)
        item['sourceCourse'] = subject(item.get('sourceCourse'), item.get('knowledgePointName'), profile=profile)
        rows.append(item)
    return rows
