# -*- coding: utf-8 -*-
"""数据库连接自检：确认 `.env` 里的仓储后端真的可用，而不是"配置了"。

退出码 0 = 连接、schema 版本、权限与 `/ready` 全部通过；非 0 = 有硬失败（详见输出）。

为什么单独做一个闸门
--------------------
`/health` 只证明 Flask 起来了，不碰数据库；`ZHIXUE_DB=postgresql` 配置写错、
库没迁移、账号没权限，都要等第一个真实请求才炸。这个脚本在启动前就把这四件事
一次查完，并把「连不上」和「连上了但 schema 不对」明确区分开 —— 两者排查方向完全不同。

支持三种后端，按 `.env` 的 `ZHIXUE_DB` 自动选择：
  * postgresql —— 连接、版本、alembic 版本、核心表、读写权限、`/ready`
  * sqlite     —— 库文件可读、records 表可用、`/ready`
  * json（默认）—— 文件可解析、集合数、`/ready`

用法（在任意目录均可）::

    python tools/check_database.py            # 按 .env 检查
    python tools/check_database.py --verbose  # 额外打印连接耗时与各表行数
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import time
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SERVER = ROOT / "server" / "zhixue-agent-server"
ENV_FILE = SERVER / ".env"

if not ENV_FILE.exists():
    print(f"  [X] 未找到 {ENV_FILE}")
    sys.exit(1)

from dotenv import load_dotenv  # noqa: E402

load_dotenv(ENV_FILE, override=False, encoding="utf-8-sig")
sys.path.insert(0, str(SERVER))

BACKEND = (os.getenv("ZHIXUE_DB") or "json").strip()
STATE = SERVER / "data"
FAILURES: list[str] = []


def ok(message: str) -> None:
    print(f"  [OK] {message}")


def warn(message: str) -> None:
    print(f"  [!]  {message}")


def fail(message: str, hint: str = "") -> None:
    FAILURES.append(message)
    print(f"  [X]  {message}")
    if hint:
        print(f"       → {hint}")


def _masked(url: str) -> str:
    try:
        from sqlalchemy.engine import make_url

        return make_url(url).render_as_string(hide_password=True)
    except Exception:
        return "(无法解析的 DATABASE_URL)"


def _tcp_reachable(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def check_postgresql(verbose: bool) -> None:
    from sqlalchemy import text
    from sqlalchemy.engine import make_url

    url = (os.getenv("DATABASE_URL") or "").strip()
    if not url:
        fail("ZHIXUE_DB=postgresql 但 DATABASE_URL 为空",
             "在 server/zhixue-agent-server/.env 填 DATABASE_URL=postgresql+psycopg://用户:密码@主机:5432/库名")
        return

    parsed = make_url(url)
    if parsed.drivername in {"postgres", "postgresql"}:
        warn(f"驱动 {parsed.drivername} 会被代码纠正为 postgresql+psycopg（建议直接写全）")
    elif parsed.drivername != "postgresql+psycopg":
        fail(f"驱动必须是 Psycopg 3，当前是 {parsed.drivername!r}",
             "把 URL 前缀改成 postgresql+psycopg://")

    host, port = parsed.host or "localhost", parsed.port or 5432
    print(f"  目标库   : {_masked(url)}")
    print(f"  连通性   : {host}:{port} ... ", end="", flush=True)
    if _tcp_reachable(host, port):
        print("TCP 可达")
    else:
        print("TCP 不可达")
        fail(f"无法建立到 {host}:{port} 的 TCP 连接",
             "检查网络/VPN/安全组；本机可用 Test-NetConnection -ComputerName {host} -Port {port} 复核".format(host=host, port=port))
        return

    from app.repositories.pg_schema import REVISION
    from app.repositories.postgresql_repository import make_engine

    started = time.perf_counter()
    try:
        engine = make_engine(url)
        with engine.connect() as connection:
            latency = (time.perf_counter() - started) * 1000
            print(f"  连接耗时 : {latency:.0f} ms")
            version = connection.execute(text("SELECT version()")).scalar_one()
            database, user = connection.execute(
                text("SELECT current_database(), current_user")).one()
            ok(f"登录成功：{user}@{database}")
            print(f"  PG 版本  : {version.split(' on ')[0]}")
            if verbose:
                timezone = connection.execute(text("SHOW TimeZone")).scalar_one()
                print(f"  会话时区 : {timezone}")

            try:
                actual = connection.execute(
                    text("SELECT version_num FROM alembic_version")).scalar_one()
            except Exception:
                actual = None
            if actual is None:
                fail("库里没有 alembic_version（未执行迁移）",
                     "在后端目录执行 alembic upgrade head 后再启动")
            elif actual != REVISION:
                fail(f"schema 版本不一致：库={actual} 代码={REVISION}",
                     "执行 alembic upgrade head 对齐；不要直接改代码里的 REVISION")
            else:
                ok(f"schema 版本一致：{actual}")

            tables = {row[0] for row in connection.execute(text(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema = current_schema()"))}
            expected = {"users", "jobs", "submissions", "plans", "learning_profiles",
                        "knowledge_bases", "exercises", "agent_traces"}
            missing = sorted(expected - tables)
            if missing:
                fail(f"缺少核心表：{', '.join(missing)}", "执行 alembic upgrade head")
            else:
                ok(f"核心表齐全（当前 schema 共 {len(tables)} 张表）")

            writable = connection.execute(text(
                "SELECT has_table_privilege(current_user, 'users', 'INSERT,UPDATE,DELETE')")).scalar_one()
            if writable:
                ok("写权限：users 表 INSERT/UPDATE/DELETE 可用")
            else:
                fail("当前账号对 users 表没有写权限", "找库管理员授予读写权限")

            if verbose:
                for name in ("users", "learning_profiles", "plans", "submissions",
                             "exercises", "knowledge_bases", "agent_traces"):
                    try:
                        count = connection.execute(
                            text(f"SELECT count(*) FROM {name}")).scalar_one()
                        print(f"  {name:<20s} {count} 行")
                    except Exception as error:  # noqa: BLE001 - 只影响统计展示
                        print(f"  {name:<20s} 统计失败: {error}")
        engine.dispose()
    except Exception as error:  # noqa: BLE001 - 连接错误必须分类后原样报出
        fail(f"数据库连接/查询失败：{type(error).__name__}: {error}",
             "密码错误、账号不存在、pg_hba 未放行、库不存在都会在这里暴露；"
             "先用 psql 'host=... user=... dbname=...' 复核")
        return

    from app.repositories.postgresql_repository import PostgreSQLRepository

    try:
        repository = PostgreSQLRepository(url)
        users = repository.ids("users")
        ok(f"仓储层可用（PostgreSQLRepository），现有账号 {len(users)} 个")
        repository.close()
    except Exception as error:  # noqa: BLE001
        fail(f"仓储层初始化失败：{type(error).__name__}: {error}",
             "确认 app/repositories/pg_schema.py 的 REVISION 与库一致")


def check_sqlite(verbose: bool) -> None:
    import sqlite3

    spec = BACKEND.partition(":")[2].strip()
    path = Path(spec) if spec else STATE / "repository.sqlite"
    print(f"  库文件   : {path}")
    if not path.exists():
        fail("SQLite 库文件不存在", "先运行 python tools/migrate_repository.py --verify 迁移")
        return
    try:
        with sqlite3.connect(path) as connection:
            total = connection.execute("SELECT count(*) FROM records").fetchone()[0]
            groups = connection.execute(
                "SELECT collection, count(*) FROM records GROUP BY collection").fetchall()
        ok(f"SQLite 可读：{total} 条记录")
        if verbose:
            for name, count in groups:
                print(f"  {name:<20s} {count} 行")
    except Exception as error:  # noqa: BLE001
        fail(f"SQLite 读取失败：{type(error).__name__}: {error}")


def check_json(verbose: bool) -> None:
    path = STATE / "repository.json"
    print(f"  库文件   : {path}")
    if not path.exists():
        warn("JSON 库文件尚不存在 —— 首次启动会新建空库（现有账号不会在库里）")
        return
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception as error:  # noqa: BLE001
        fail(f"JSON 解析失败：{type(error).__name__}: {error}")
        return
    if not isinstance(data, dict):
        fail("JSON 顶层不是对象，与 JsonRepository 约定不符")
        return
    total = sum(len(v) for v in data.values() if isinstance(v, list))
    ok(f"JSON 可读：{len(data)} 个集合 / {total} 条记录")
    if verbose:
        for name, value in sorted(data.items()):
            if isinstance(value, list):
                print(f"  {name:<20s} {len(value)} 行")


def check_ready() -> None:
    """最后一步用应用自己的 /ready 探针收口：仓储 + schema 版本都归一。"""
    try:
        from app import create_app

        application = create_app()
        client = application.test_client()
        response = client.get("/ready")
        payload = response.get_json(silent=True) or {}
    except Exception as error:  # noqa: BLE001
        fail(f"create_app() 失败：{type(error).__name__}: {error}")
        return
    if response.status_code == 200 and payload.get("status") == "ready":
        ok("GET /ready -> 200 ready")
    else:
        fail(f"GET /ready -> {response.status_code} {payload}", "看上面的仓储层报错")


def main() -> int:
    parser = argparse.ArgumentParser(description="数据库连接自检")
    parser.add_argument("--verbose", action="store_true", help="打印连接耗时与各表行数")
    args = parser.parse_args()

    backend = BACKEND.partition(":")[0].strip().lower() or "json"
    print("=" * 64)
    print("  知学 Mate · 数据库连接自检")
    print("=" * 64)
    print(f"  .env     : {ENV_FILE}")
    print(f"  后端     : {backend}")
    print("-" * 64)

    if backend == "postgresql":
        check_postgresql(args.verbose)
    elif backend == "sqlite":
        check_sqlite(args.verbose)
    elif backend == "json":
        check_json(args.verbose)
    else:
        fail(f"未知的 ZHIXUE_DB 取值：{BACKEND!r}", "可选 json / sqlite[:path] / postgresql")
        return 1

    print("-" * 64)
    check_ready()
    print("=" * 64)
    if FAILURES:
        print(f"  结论：{len(FAILURES)} 项失败")
        return 1
    print("  结论：全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
