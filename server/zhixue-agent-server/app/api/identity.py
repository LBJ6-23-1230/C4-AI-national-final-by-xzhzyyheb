"""身份由有效会话确定；游客只可访问公开演示身份。"""
from typing import Any
from flask import abort, g

DEMO_USER_ID = "demo-user"
MAX_USER_ID_CHARS = 128


def current_user_id() -> str:
    current = getattr(g, "current_user", None)
    if isinstance(current, dict):
        value = current.get("userId")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def resolve_user_id(supplied: Any = None, default: str = DEMO_USER_ID) -> str:
    """登录后忽略遗留 userId 参数；匿名指定真实身份时拒绝。"""
    authed = current_user_id()
    if authed:
        return authed
    if supplied is not None:
        if not isinstance(supplied, str) or not supplied.strip() or len(supplied.strip()) > MAX_USER_ID_CHARS:
            abort(400)
        supplied = supplied.strip()
    if supplied is not None and supplied != DEMO_USER_ID:
        abort(404)
    return DEMO_USER_ID


def can_read_user(user_id: str) -> bool:
    return user_id == DEMO_USER_ID or user_id == current_user_id()


def is_impersonation_attempt(supplied: Any) -> bool:
    authed = current_user_id()
    return bool(authed and isinstance(supplied, str) and supplied.strip()
                and supplied.strip() != authed)
