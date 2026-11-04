"""Treat extracted files as reference data and retain them within one account/session."""
import hashlib
import re


MENU_PROMPTS = {
    '今天我应该先学什么？', '帮我诊断这道错题', '帮我看看我的薄弱知识点',
    '帮我匹配一个学习搭子', '今天有哪些任务要交？', '我要更新学习画像：我的学习目标或掌握情况有变化',
}


def resolve(repository, owner, session, message, document=None, has_image=False):
    explicit = document is not None
    # Compatibility with the previous client which embedded extracted text in
    # its message. Never send this text through the action/intent classifier.
    if document is None and '<uploaded_document>\n' in message:
        match = re.fullmatch(r'(.*?)\n以下是上传文件中的引用资料，.*?\n<uploaded_document>\n(.*?)\n</uploaded_document>', message, re.S)
        if match:
            heading = match.group(1)
            name = re.search(r'\n附件：([^\n]+)$', heading)
            document = dict(fileName=name.group(1) if name else '上传文件', text=match.group(2), truncated=False)
            message = re.sub(r'\n附件：[^\n]+$', '', heading)
            explicit = True
    key = hashlib.sha256((owner + '\0' + (session or '')).encode()).hexdigest()
    if document is not None:
        if not session or not isinstance(document, dict):
            raise ValueError('文件问答需要有效的聊天会话与附件内容')
        name, text = document.get('fileName'), document.get('text')
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 200 or not isinstance(text, str) or not 1 <= len(text.strip()) <= 12000:
            raise ValueError('附件名称或正文不完整，请重新添加文件')
        if type(document.get('truncated', False)) is not bool:
            raise ValueError('附件截断标识无效')
        record = dict(userId=owner, chatSessionId=session, fileName=name.strip(), text=text,
                      truncated=document.get('truncated', False))
        repository.save('chat_documents', key, record)
    else:
        record = repository.get('chat_documents', key) if session else None
    switch = message.strip() in MENU_PROMPTS or bool(re.search(
        r'换个话题|不聊.{0,4}(?:文件|附件)|(?:帮我|我要)(?:匹配|寻找).{0,8}搭子|(?:帮我|我要)(?:更新|修改).{0,6}画像', message))
    if not explicit and (has_image or switch):
        if record:
            repository.delete('chat_documents', key)
        return message, None
    return message, record


def clear(repository, owner):
    deletes = [('chat_documents', key) for key in repository.ids('chat_documents')
               if (repository.get('chat_documents', key) or {}).get('userId') == owner]
    if deletes:
        repository.apply_batch(deletes, [])
