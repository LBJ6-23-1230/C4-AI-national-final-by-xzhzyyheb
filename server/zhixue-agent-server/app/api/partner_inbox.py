"""Private conversation summaries and monotonic, per-account read watermarks."""
import hashlib
from datetime import datetime, timezone

from flask import Blueprint, abort, jsonify, request

from app.api.learning_upgrade import authenticated, body, repo, relationship, string
from app.services.course_names import profile_courses
from app.services.subject_classification import normalized_mastery, topic_group

partner_inbox_api = Blueprint('partner_inbox', __name__)


def room_id(owner, partner):
    return hashlib.sha256('\0'.join(sorted([owner, partner])).encode()).hexdigest()


def summary(owner, partner, contact, messages=None):
    repository = repo()
    room = room_id(owner, partner)
    rows = [x for x in (messages if messages is not None else repository.list('partner_messages'))
            if x.get('roomId') == room]
    rows.sort(key=lambda x: x['messageId'])
    read = repository.get('partner_reads', owner + ':' + room) or {}
    unread = sum(x.get('senderId') != owner and x['messageId'] > read.get('lastReadMessageId', '') for x in rows)
    account = repository.get('users', partner) or {}
    left = repository.get('profiles', owner) or {}
    right = repository.get('profiles', partner) or {}
    shared = sorted(set(profile_courses(left)) & set(profile_courses(right)))
    agreed = contact.get('courseName')
    if agreed and agreed not in shared:
        shared.append(agreed)
    def topics(profile):
        return {topic_group(x.get('knowledgePointName')) for x in normalized_mastery(profile)
                if x.get('sourceCourse') in shared}
    points = sorted(topics(left) & topics(right))
    latest = rows[-1] if rows else {}
    paired = contact.get('pairedAt', '')
    try:
        parsed = datetime.fromisoformat(paired.replace('Z', '+00:00'))
        paired_days = max(0, (datetime.now(timezone.utc) - parsed.astimezone(timezone.utc)).days)
    except (ValueError, TypeError):
        paired_days = 0
    return dict(partnerUserId=partner, partnerName=account.get('nickname') or contact.get('partnerName') or '学习搭子',
        avatar=account.get('avatar') or '', pairedAt=paired, pairedDays=paired_days,
        sharedCourses=shared, sharedKnowledgePoints=points, sharedStudyMinutes=None,
        lastMessage=latest.get('text') or ('[图片]' if latest.get('image') else ''),
        lastMessageId=latest.get('messageId', ''), lastMessageAt=latest.get('createdAt', ''), unreadCount=unread)


@partner_inbox_api.get('/api/v1/partner-conversations')
def conversations():
    owner = authenticated()
    try:
        offset = int(request.args.get('offset', 0))
        if offset < 0 or offset > 100000:
            abort(400)
    except ValueError:
        abort(400)
    contacts = [x for x in repo().list('contacts') if x.get('userId') == owner and x.get('status') != 'ended']
    all_messages = repo().list('partner_messages')
    items = []
    seen = set()
    for contact in contacts:
        partner = contact.get('partnerUserId')
        if not partner or partner in seen:
            continue
        # A stale one-sided or deactivated contact must not expose messages.
        reverse = [x for x in repo().list('contacts') if x.get('userId') == partner
                   and x.get('partnerUserId') == owner and x.get('status') != 'ended']
        account = repo().get('users', partner)
        if not reverse or not account or account.get('status') != 'active':
            continue
        seen.add(partner)
        items.append(summary(owner, partner, contact, all_messages))
    items.sort(key=lambda x: x['lastMessageAt'] or x['pairedAt'], reverse=True)
    page = items[offset:offset + 30]
    return jsonify(conversations=page, totalUnread=sum(x['unreadCount'] for x in items),
                   nextOffset=offset + len(page), hasMore=offset + len(page) < len(items))


@partner_inbox_api.get('/api/v1/partners/<partner>/summary')
def partner_summary(partner):
    owner = authenticated()
    contact = relationship(owner, partner)
    return jsonify(conversation=summary(owner, partner, contact))


@partner_inbox_api.post('/api/v1/partners/<partner>/read')
def mark_read(partner):
    owner = authenticated()
    relationship(owner, partner)
    cursor = string(body(), 'lastReadMessageId', 160, True)
    room = room_id(owner, partner)
    with repo().transaction():
        message = repo().get('partner_messages', cursor)
        if not message or message.get('roomId') != room:
            abort(404)
        key = owner + ':' + room
        previous = repo().get('partner_reads', key) or {}
        watermark = max(cursor, previous.get('lastReadMessageId', ''))
        repo().save('partner_reads', key, dict(userId=owner, partnerUserId=partner, lastReadMessageId=watermark))
    return jsonify(status='ok', lastReadMessageId=watermark)
