import os
import logging
from pathlib import Path

from dotenv import load_dotenv
load_dotenv(Path(__file__).resolve().parents[1] / ".env", override=False, encoding="utf-8-sig")

from flask import Flask, g, request
from flask_cors import CORS

from app.api.auth import auth_api, configure_auth_repository
from app.api.demo import configure_demo_repository, demo_api, ensure_demo_data
from app.api.chat import chat_api, configure_chat_repository
from app.api.exercises import exercises_api
from app.api.experiments import experiments_api
from app.api.knowledge import configure_knowledge_repository, knowledge_api
from app.api.plans import plans_api
from app.api.partner_match import (
    configure_partner_match_repository,
    partner_match_api,
)
from app.api.partner_invite import (
    configure_partner_invite_repository,
    partner_invite_api,
)
from app.api.profile import profile_api
from app.api.proactive import proactive_api
from app.api.schedule_import import schedule_import_api
from app.api.traces import traces_api
from app.api.workflows import configure_workflows_repository, workflows_api
from app.api.wrong_book import configure_wrong_book_repository, wrong_book_api
from app.api.focus import configure_focus_repository, focus_api
from app.auth import service as auth_service
from app.repositories.json_repository import JsonRepository

CONTRACT_VERSION = "api-contract-v0.3"

_DEFAULT_CORS_ORIGINS = (
    r"http://localhost(:\d+)?",
    r"http://127\.0\.0\.1(:\d+)?",
    r"http://\[::1\](:\d+)?",
    r"http://10\.\d{1,3}\.\d{1,3}\.\d{1,3}(:\d+)?",
    r"http://192\.168\.\d{1,3}\.\d{1,3}(:\d+)?",
    r"http://172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}(:\d+)?",
)


def _cors_origins() -> list[str]:
    """解析允许的跨域来源；环境变量优先。"""
    raw = (os.getenv("ZHIXUE_CORS_ORIGINS") or "").strip()
    if not raw:
        return list(_DEFAULT_CORS_ORIGINS)
    if raw == "*":
        return ["*"]
    return [item.strip() for item in raw.split(",") if item.strip()]


VALID_DB_BACKENDS = ("json", "sqlite", "postgresql")


def _build_repository(path: Path):
    """按 `ZHIXUE_DB` 选择仓储实现。返回的对象满足 `Repository` 抽象。"""
    spec = (os.getenv("ZHIXUE_DB") or "json").strip()
    backend, _, explicit = spec.partition(":")
    backend = backend.strip().lower() or "json"

    if backend not in VALID_DB_BACKENDS:
        raise ValueError(
            f"ZHIXUE_DB 取值非法: {spec!r}；可选 {VALID_DB_BACKENDS}（可写成 sqlite:<path>）")

    if backend == "postgresql":
        from app.repositories.postgresql_repository import PostgreSQLRepository
        if not os.getenv("DATABASE_URL"):
            raise RuntimeError("DATABASE_URL is required for PostgreSQL")
        return PostgreSQLRepository(os.environ["DATABASE_URL"])
    if backend == "sqlite":
        from app.repositories.sqlite_repository import SQLiteRepository

        target = Path(explicit.strip()) if explicit.strip() else path.with_suffix(".sqlite")
        target.parent.mkdir(parents=True, exist_ok=True)
        return SQLiteRepository(target)
    return JsonRepository(path)


def _report_repository_state(path: Path, repository) -> None:
    """启动时把「账号库在哪个文件、里面有多少账号」打到控制台。

    为什么需要：`data/repository.json` 是**运行期状态** —— 它既在 `.gitignore` 里
    （第 23 行），也在交付打包的排除表里（`tools/build_submission_zip.py` 的
    `EXCLUDE_NAMES`）。也就是说：**换一份新检出的工程、或重新解压一次交付包，
    之前注册的账号就是不在的**，只能重新注册。

    这本身是有意为之（免得几十个联调测试账号被打进交付物），但现场完全看不出线索 ——
    实测反馈「把 DevEco Studio 和模拟器全部关掉再打开项目就要重新注册了」，
    排查时只能靠猜。把路径与账号数直接打在启动输出里，这种情况一眼可判：
    账号数是 0 就说明换库了；账号数不为 0 而 App 仍要重新登录，那就是
    模拟器侧的 preferences 被冷启动清掉了，方向完全不同。
    """
    try:
        users = repository.ids("users")
        sessions = repository.ids("sessions")
    except Exception as error:  # noqa: BLE001 - 诊断信息绝不影响启动
        print(f"  [数据] 无法读取账号库统计: {error}")
        return
    print(f"  [数据] 账号库   : {getattr(repository, 'path', path)}")
    print(f"  [数据] 已存账号 : {len(users)} 个 · 会话 {len(sessions)} 个"
          + ("   ← 空库：之前注册的账号不在这个文件里" if not users else ""))


def create_app(repository_path: str | Path | None = None) -> Flask:
    from app.settings import load_environment, validate_config, demo_enabled, production
    load_environment()
    validate_config()
    event_logger = logging.getLogger("zhixue")
    event_logger.setLevel(logging.INFO)
    if not event_logger.handlers:
        event_logger.addHandler(logging.StreamHandler())
    app = Flask(__name__)
    app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024
    _origins = _cors_origins()
    CORS(app, resources={r"/*": {"origins": _origins if _origins != ["*"] else "*"}})
    if repository_path is None:
        repository_path = os.getenv("ZHIXUE_REPOSITORY") or None
    path = Path(repository_path) if repository_path else Path(__file__).resolve().parents[1] / "data" / "repository.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    repository = _build_repository(path)
    app.extensions["repository"] = repository
    app.config["DEMO_ENABLED"] = demo_enabled()
    if getattr(repository, "durable_jobs", False):
        from sqlalchemy.exc import DBAPIError, TimeoutError as DatabaseTimeout
        def database_unavailable(error):
            event_logger.warning("database_request_failed request_id=%s", getattr(g, "request_id", ""))
            return {"errorCode": "SERVICE_UNAVAILABLE", "message": "服务暂时不可用，请稍后重试", "details": None}, 503
        app.register_error_handler(DBAPIError, database_unavailable)
        app.register_error_handler(DatabaseTimeout, database_unavailable)
    if not os.getenv("ZHIXUE_QUIET"):
        _report_repository_state(path, repository)
    configure_demo_repository(repository)
    if demo_enabled():
        ensure_demo_data()
    configure_workflows_repository(repository)
    configure_auth_repository(repository)
    configure_knowledge_repository(repository)
    configure_chat_repository(repository)
    configure_wrong_book_repository(repository)
    configure_focus_repository(repository)
    configure_partner_invite_repository(repository)
    configure_partner_match_repository(repository)
    app.register_blueprint(demo_api)
    app.register_blueprint(auth_api)
    app.register_blueprint(chat_api)
    app.register_blueprint(profile_api)
    app.register_blueprint(plans_api)
    app.register_blueprint(partner_match_api)
    app.register_blueprint(partner_invite_api)
    app.register_blueprint(exercises_api)
    app.register_blueprint(experiments_api)
    app.register_blueprint(traces_api)
    app.register_blueprint(workflows_api)
    app.register_blueprint(proactive_api)
    app.register_blueprint(knowledge_api)
    app.register_blueprint(schedule_import_api)
    app.register_blueprint(wrong_book_api)
    from app.api.learning_upgrade import learning_upgrade_api
    app.register_blueprint(learning_upgrade_api)
    from app.api.learning_records import learning_records_api
    app.register_blueprint(learning_records_api)
    from app.api.partner_inbox import partner_inbox_api
    app.register_blueprint(partner_inbox_api)
    app.register_blueprint(focus_api)
    from app.api.reminders import reminders_api
    app.register_blueprint(reminders_api)
    from app.api.learning_data import learning_data_api
    app.register_blueprint(learning_data_api)
    from app.api.device_collaboration import device_collaboration_api
    app.register_blueprint(device_collaboration_api)
    from app.api.shared_focus import shared_focus_api
    app.register_blueprint(shared_focus_api)
    from app.api.study_tasks import study_tasks_api
    app.register_blueprint(study_tasks_api)

    @app.before_request
    def resolve_optional_identity():
        """无凭据可使用演示身份；无效或过期凭据不得降级为游客。"""
        g.current_user = None
        g.auth_token = ""
        token = auth_service.parse_bearer(request.headers.get("Authorization"))
        if request.method == "OPTIONS":
            return None
        if request.headers.get("Authorization") is not None and not token:
            return {"errorCode": "UNAUTHORIZED", "message": "invalid authorization", "details": None}, 401
        if token:
            user = auth_service.resolve_session(repository, token)
            if user is None:
                return {"errorCode": "UNAUTHORIZED", "message": "invalid or expired session", "details": None}, 401
            if user is not None:
                g.current_user = user
                g.auth_token = token
                if (auth_service.needs_password_setup(user) and request.path.startswith("/api/")
                        and request.path not in {"/api/v1/auth/me", "/api/v1/auth/logout",
                            "/api/v1/auth/change-password", "/api/v1/auth/account", "/api/v1/auth/status"}):
                    return {"errorCode": "PASSWORD_SETUP_REQUIRED", "message": "请先设置登录密码", "details": None}, 403
        if not demo_enabled() and request.path.startswith("/api/"):
            public = {"/api/agent/health", "/api/v1/auth/status", "/api/v1/auth/register",
                      "/api/v1/auth/login", "/api/v1/auth/phone/login", "/api/v1/auth/login-or-register",
                      "/api/v1/auth/send-code", "/api/v1/auth/verify-code", "/api/v1/auth/login-with-huawei"}
            if "/demo/" in request.path or request.path.startswith("/api/v1/experiments"):
                return {"errorCode": "NOT_FOUND", "message": "resource not found", "details": None}, 404
            if not g.current_user and request.path not in public:
                return {"errorCode": "UNAUTHORIZED", "message": "请先登录", "details": None}, 401

    @app.before_request
    def require_contract_version():
        """契约版本校验（api-contract-v0.3）。

        规则：`/api/v1/**` 只要带了 `X-API-Contract-Version` 头，就必须等于当前冻结版本；
        不带头则放行，便于用浏览器 / curl 手工抽查接口做答辩演示。

        `/api/agent/*`（聊天层与连通性探针）不做版本校验——否则前端在版本不匹配时
        会把「契约不一致」误读成「后端不可用」，把可诊断的问题变成不可诊断的问题。
        """
        if request.path.startswith("/api/v1"):
            supplied = request.headers.get("X-API-Contract-Version", "")
            if supplied and supplied != CONTRACT_VERSION:
                return {
                    "errorCode": "CONTRACT_VERSION_MISMATCH",
                    "message": f"请使用 X-API-Contract-Version: {CONTRACT_VERSION}",
                    "details": None,
                }, 409

    @app.get("/health")
    def health_check():
        return {"status": "ok"}

    @app.get("/ready")
    def readiness_check():
        try:
            if hasattr(repository, "check_ready"):
                repository.check_ready()
            else:
                repository.ids("users")
            return {"status": "ready"}
        except Exception:
            return {"status": "unavailable"}, 503

    @app.before_request
    def start_request_trace():
        import uuid
        g.request_id = uuid.uuid4().hex

    @app.after_request
    def attach_request_trace(response):
        response.headers["X-Request-ID"] = getattr(g, "request_id", "")
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Cache-Control"] = "no-store"
        return response

    @app.get("/")
    def service_index():
        """根路径自描述，方便评委直接打开浏览器确认服务确实在跑。"""
        from app.agent import chat_llm
        return {
            "service": "知学 Mate · 统一后端",
            "contractVersion": CONTRACT_VERSION,
            "layers": {
                "naturalLanguage": "/api/agent/chat",
                "workflow": "/api/v1/*",
                "auth": "/api/v1/auth/*",
            },
            "llm": {
                "ready": chat_llm.llm_ready(),
                "model": chat_llm.llm_model(),
            },
            "auth": {
                "mode": "bearer-or-demo" if demo_enabled() else "bearer",
                "guestUserId": auth_service.DEMO_USER_ID if demo_enabled() else None,
                "note": "游客仅访问 demo-user；真实用户数据需要有效会话",
            },
        }

    @app.errorhandler(404)
    def handle_not_found(error):
        return {"errorCode": "NOT_FOUND", "message": "resource not found", "details": None}, 404

    @app.errorhandler(400)
    def handle_bad_request(error):
        return {"errorCode": "BAD_REQUEST", "message": "invalid request", "details": None}, 400

    @app.errorhandler(500)
    def handle_internal_error(error):
        return {"errorCode": "INTERNAL_ERROR", "message": "internal server error", "details": None}, 500

    @app.errorhandler(405)
    def handle_method_not_allowed(error):
        return {
            "errorCode": "BAD_REQUEST",
            "message": "method not allowed for this endpoint",
            "details": {"method": request.method, "path": request.path},
        }, 405

    @app.errorhandler(414)
    def handle_uri_too_long(error):
        return {
            "errorCode": "BAD_REQUEST",
            "message": "request URI too long",
            "details": {"pathLength": len(request.full_path or "")},
        }, 414

    @app.errorhandler(415)
    def handle_unsupported_media_type(error):
        return {
            "errorCode": "BAD_REQUEST",
            "message": "unsupported media type; use application/json",
            "details": {"contentType": request.content_type},
        }, 415

    @app.errorhandler(413)
    def handle_payload_too_large(error):
        return {
            "errorCode": "BAD_REQUEST",
            "message": "request payload too large",
            "details": None,
        }, 413

    return app
