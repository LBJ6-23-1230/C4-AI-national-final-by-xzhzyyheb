# -*- coding: utf-8 -*-
"""把 liantiao5 拆成「前端包 / 后端包」两个独立压缩包。

设计原则
--------
1. **各自自包含**：每人拿到手就能开工，不需要另一个包
2. **不含产物与依赖**：`entry/build`、`oh_modules`、`.hvigor`、`__pycache__`
   都是可再生的，打进去只会让包大 20 倍
3. **不含敏感信息**：`.env`、token、密钥一律排除，并在打包前**断言**
4. **契约双方都有**：前端只有镜像（`app/contracts/`），后端只有真源
   （`contracts/`），两侧的 `check_contract_sync()` 都已容错
5. **任务书按角色分发**：前端只拿前端相关的文档，避免信息过载

用法::

    python tools/package_handoff.py            # 生成两个 zip
    python tools/package_handoff.py --keep     # 保留中间 staging 目录（便于检查）
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "deliverables"
STAGE = ROOT / ".packaging"

VERSION = "liantiao5"

from packaging_policy import iter_source_files, sanitized_bytes, assert_safe_content, should_skip
import os
import uuid


def _iter_files(base):
    return (path for path in iter_source_files(base) if path.suffix.lower() != '.hap')


def copy_tree(src: Path, dst: Path, *, skip_top: set[str] | None = None) -> int:
    """把 src 复制到 dst，按排除规则过滤。返回复制文件数。"""
    skip_top = skip_top or set()
    count = 0
    for path in _iter_files(src):
        rel = path.relative_to(src)
        if rel.parts and rel.parts[0] in skip_top:
            continue
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(sanitized_bytes(path))
        count += 1
    return count


def copy_docs(dst: Path, names: list[str]) -> int:
    """只复制指定文档（按角色分发，避免信息过载）。"""
    dst.mkdir(parents=True, exist_ok=True)
    count = 0
    for name in names:
        src = ROOT / "项目文档" / name
        if src.exists():
            shutil.copy2(src, dst / name)
            count += 1
        else:
            print(f"  [WARN] 文档缺失：{name}")
    return count


def assert_no_secrets(stage):
    for path in stage.rglob('*'):
        if path.is_file():
            if should_skip(path.relative_to(stage)):
                raise ValueError(f'Forbidden package entry: {path.relative_to(stage)}')
            assert_safe_content(path.read_bytes(), path.relative_to(stage))
    print('  [OK] source-package content checks passed')


FRONTEND_README = """# 知学 Mate 前端工作包（{version}）

在 DevEco Studio 打开 app/，安装依赖并配置本机签名后构建。
contracts/openapi.json 为接口契约，app/contracts/openapi.json 为镜像。
本包不包含本地签名、依赖缓存、后端运行数据或 API 密钥。
测试与设备验收状态以仓库 README 和 evidence/ 的对应时间记录为准。
"""

BACKEND_README = """# 知学 Mate 后端工作包（{version}）

Windows 执行根目录 start-backend.ps1；先执行 start-backend.ps1 -Check 可检查环境。
跨平台可进入 server/zhixue-agent-server 创建 Python 3.12 虚拟环境，
安装 requirements.txt，将 .env.example 复制为 .env 后运行 python run.py。
数据文件首次启动创建，默认 JSON 仅支持单写进程；多进程使用 SQLite。
迁移前停止服务并备份，迁移工具默认拒绝覆盖已有目标。
本包不包含运行账号、会话、聊天历史或密钥。验证记录见 evidence/。
"""


def build_frontend() -> Path:
    stage = STAGE / f"{VERSION}-frontend"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    print("[前端包] 复制 app/ ...")
    count = copy_tree(ROOT / "app", stage / "app")
    print(f"  app/ → {count} 个文件")
    print("[前端包] 复制契约 ...")
    (stage / "contracts").mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "contracts" / "openapi.json", stage / "contracts" / "openapi.json")
    print("[前端包] 复制文档 ...")
    docs = [
        "17-前端同学任务书.md",
        "01-联调分析报告.md",
        "02-下一步工作清单.md",
        "18-技术改进实施报告.md",
        "19-未完成事项清单.md",
        "20-token加密API核验报告.md",
        "13-全场景与华为账号登录方案.md",
        "12-知识库设计方案.md",
        "11-用户登录体系方案.md",
        "07-鸿蒙特性审计报告.md",
        "08-前端静态Bug排查报告.md",
        "10-全项目审计与Bug修复总结.md",
    ]
    n = copy_docs(stage / "docs", docs)
    print(f"  {n} 份文档")
    (stage / "README.md").write_text(FRONTEND_README.format(version=VERSION), encoding="utf-8")
    return stage


def build_backend() -> Path:
    stage = STAGE / f"{VERSION}-backend"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)
    shutil.copy2(ROOT / "start-backend.ps1", stage / "start-backend.ps1")
    print("[后端包] 复制 server/ ...")
    count = copy_tree(ROOT / "server", stage / "server")
    print(f"  server/ → {count} 个文件")
    for name in ("contracts", "integration", "tools", "evidence"):
        src = ROOT / name
        if src.exists():
            c = copy_tree(src, stage / name)
            print(f"  {name}/ → {c} 个文件")
    print("[后端包] 复制文档 ...")
    docs = [
        "16-后端同学任务书.md",
        "01-联调分析报告.md",
        "02-下一步工作清单.md",
        "21-后端同学完成报告_2026-09-21.md",
        "18-技术改进实施报告.md",
        "19-未完成事项清单.md",
        "20-token加密API核验报告.md",
        "11-用户登录体系方案.md",
        "12-知识库设计方案.md",
        "13-全场景与华为账号登录方案.md",
        "05-大模型接入检查报告.md",
        "06-后端配置LLM任务单.md",
        "09-后端Bug排查报告.md",
        "10-全项目审计与Bug修复总结.md",
    ]
    n = copy_docs(stage / "docs", docs)
    print(f"  {n} 份文档")
    (stage / "README.md").write_text(BACKEND_README.format(version=VERSION), encoding="utf-8")
    return stage


def zip_stage(stage: Path) -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    archive = OUT / f"{stage.name}.zip"
    temporary = archive.with_name(archive.name + "." + uuid.uuid4().hex + ".tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in sorted(stage.rglob("*")):
            if path.is_file():
                bundle.write(path, path.relative_to(stage.parent))
    os.replace(temporary, archive)
    return archive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--keep", action="store_true", help="保留 staging 目录")
    args = parser.parse_args()

    if STAGE.resolve().parent != ROOT.resolve() or STAGE.name != '.packaging':
        raise ValueError('Unsafe staging path')
    if STAGE.exists():
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)

    print("=" * 72)
    frontend = build_frontend()
    assert_no_secrets(frontend)
    print()
    backend = build_backend()
    assert_no_secrets(backend)

    print("=" * 72)
    frontend_zip = zip_stage(frontend)
    backend_zip = zip_stage(backend)

    print("\n生成结果：")
    for archive in (frontend_zip, backend_zip):
        size = archive.stat().st_size / 1024 / 1024
        with zipfile.ZipFile(archive) as bundle:
            files = len(bundle.namelist())
        print(f"  {archive.name}")
        print(f"      {files} 个条目 / {size:.2f} MB")
        print(f"      {archive}")

    if not args.keep:
        shutil.rmtree(STAGE)
        print("\n（staging 目录已清理；加 --keep 可保留以便检查）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
