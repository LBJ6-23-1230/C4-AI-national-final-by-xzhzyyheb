"""Stable, course-scoped topic membership; scores only come from observed answers."""
import hashlib


def membership(repo, owner, point):
    course = point.get('sourceCourse') or ''
    name = point.get('knowledgePointName') or point['knowledgePointId']
    existing = repo.get('topic_memberships', owner + ':' + point['knowledgePointId'])
    if existing and existing.get('confirmed') and existing.get('sourceCourse') == course:
        return {k: existing[k] for k in ('topicGroupId', 'topicGroupName', 'topicGroupConfidence')}
    rules = [('树的遍历', ('先序', '中序', '后序', '层序', '树遍历', '树的遍历')),
             ('排序算法', ('冒泡排序', '插入排序', '选择排序', '快速排序', '归并排序', '堆排序', '排序算法')),
             ('线性结构', ('栈', '队列')), ('链表操作', ('链表',)),
             ('图的遍历', ('广度优先', '深度优先', '图遍历')),
             ('应用层协议', ('HTTP', 'http', 'DNS', 'dns')),
             ('传输层协议', ('TCP', 'tcp', 'UDP', 'udp', '三次握手', '四次挥手')),
             ('操作系统内核', ('宏内核', '微内核', '内核结构')),
             ('进程管理', ('进程', '线程', '死锁')),
             ('内存管理', ('内存管理', '内存分页', '页面置换', '虚拟内存')),
             ('微积分', ('导数', '微分', '积分', '极限')),
             ('线性表', ('线性表',)), ('二叉树', ('二叉树', '二叉搜索树')), ('图算法', ('图算法', '最短路径'))]
    label = next((label for label, terms in rules if any(t in name for t in terms)), '')
    identity = hashlib.sha256((course + '\0' + label).encode()).hexdigest()[:20]
    key = owner + ':' + point['knowledgePointId']
    record = dict(userId=owner, knowledgePointId=point['knowledgePointId'], sourceCourse=course,
                  knowledgePointName=name, topicGroupId='topic-' + identity,
                  topicGroupName=label, topicGroupConfidence=0.95 if label != name else 0.5)
    if repo.get('topic_memberships', key) != record:
        repo.save('topic_memberships', key, record)
    return {k: record[k] for k in ('topicGroupId', 'topicGroupName', 'topicGroupConfidence')}


def aggregate(points):
    groups = {}
    for p in points:
        if not p.get('sourceCourse') or not p.get('topicGroupName'):
            continue
        group = groups.setdefault(p['topicGroupId'], dict(topicGroupId=p['topicGroupId'],
            topicGroupName=p['topicGroupName'], sourceCourse=p.get('sourceCourse') or '待分类',
            memberPoints=[], evidenceQuestionCount=0, weighted=0))
        count = p.get('effectiveQuestionCount', 0)
        score = p.get('recentAccuracy')
        count = count if type(count) is int and count > 0 and type(score) in (int, float) else 0
        group['weighted'] += (score or 0) * count
        group['evidenceQuestionCount'] += count
        group['memberPoints'].append(dict(knowledgePointId=p['knowledgePointId'],
            name=p['knowledgePointName'], masteryScore=score if count else None,
            evidenceQuestionCount=count))
    for group in groups.values():
        count = group['evidenceQuestionCount']
        group['masteryScore'] = round(group.pop('weighted') / count, 2) if count else None
        group['recentAccuracy'] = group['masteryScore']
        group['memberCount'] = len(group['memberPoints'])
        group['memberPointIds'] = [p['knowledgePointId'] for p in group['memberPoints']]
    return sorted(groups.values(), key=lambda g: (g['masteryScore'] if g['masteryScore'] is not None else 101,
                  -g['evidenceQuestionCount'], g['topicGroupName']))
