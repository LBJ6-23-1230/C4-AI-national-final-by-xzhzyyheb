"""Package the current source, signed HAP and judge deployment guides."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import uuid
import zipfile
from pathlib import Path

from packaging_policy import assert_safe_content, iter_source_files, sanitized_bytes

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "ZhixueMate"
ZIP_NAME = "知学Mate+暗影骑士王们.zip"
ROOT_DIRS = (
    "app", "contracts", "server", "tools", "integration", "评委部署指导",
    "演示测试数据/大纲推荐验收",
    "演示测试数据/学习搭子双账号-20261025",
    "演示测试数据/指导老师预演-20261028/01-图片",
    "演示测试数据/指导老师预演-20261028/02-课程与DDL",
    "演示测试数据/指导老师预演-20261028/03-上传讲义",
)
ROOT_FILES = ("README.md", "LICENSE", ".gitignore", "start-backend.ps1", "start-all.ps1")
HAP_VERSION_KEYS = ("bundleName", "versionName", "versionCode")


def inspect_hap(hap: Path) -> tuple[bytes, dict]:
    payload = hap.read_bytes()
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        installed = json.loads(archive.read("module.json"))["app"]
    source = json.loads((ROOT / "app/AppScope/app.json5").read_text(encoding="utf-8-sig"))["app"]
    if any(installed.get(key) != source[key] for key in HAP_VERSION_KEYS):
        raise ValueError("HAP 包名或版本与 app/AppScope/app.json5 不一致，请重新构建、验签后再打包。")
    return payload, {key: installed[key] for key in HAP_VERSION_KEYS}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="检查 HAP 版本和源文件清单，不写文件")
    parser.add_argument("--hap", type=Path, default=ROOT / "hap/知学Mate-signed.hap",
                        help="明确指定本次已构建并验签的 HAP")
    parser.add_argument("--output", type=Path, default=ROOT / ZIP_NAME, help="输出 ZIP 的路径")
    args = parser.parse_args()

    try:
        hap_bytes, version = inspect_hap(args.hap)
    except (OSError, zipfile.BadZipFile, KeyError, ValueError) as error:
        parser.exit(1, f"[FAIL] 安装包检查失败：{error}\n")

    sources = [ROOT / name for name in ROOT_FILES]
    for name in ROOT_DIRS:
        base = ROOT / name
        if not base.is_dir():
            parser.exit(1, f"[FAIL] 交付目录缺失：{name}\n")
        sources.extend(path for path in iter_source_files(base)
                       if "evidence" not in path.relative_to(ROOT).parts)
    wheelhouse = ROOT / "offline-wheels/windows-py312"
    if wheelhouse.is_dir():
        sources.extend(path for path in iter_source_files(wheelhouse) if path.suffix in {".whl", ".txt"})
    sources.sort()

    if args.check:
        print(f"[CHECK] HAP {version['versionName']}，源文件 {len(sources)} 个")
        return 0

    zip_path = args.output
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = zip_path.with_name(zip_path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
            archive.writestr(f"{PRODUCT}/hap/知学Mate-signed.hap", hap_bytes)
            archive.writestr(f"{PRODUCT}/hap/manifest.json", json.dumps({
                "file": "知学Mate-signed.hap",
                **version,
                "size": len(hap_bytes),
                "sha256": hashlib.sha256(hap_bytes).hexdigest(),
            }, ensure_ascii=False, indent=2) + "\n")
            archive.writestr(f"{PRODUCT}/hap/README.md", "# 演示安装包\n\n"
                             "- [知学Mate-signed.hap](知学Mate-signed.hap)\n"
                             "- [版本与 SHA-256](manifest.json)\n"
                             "- [评委快速开始](../评委部署指导/00-现场快速部署与体验.md)\n"
                             "- [安装、启动与 DevEco 工程](../评委部署指导/01-安装HAP与打开工程.md)\n")
            for path in sources:
                relative = path.relative_to(ROOT).as_posix()
                data = sanitized_bytes(path)
                assert_safe_content(data, relative)
                archive.writestr(f"{PRODUCT}/{relative}", data)

        with zipfile.ZipFile(temporary) as archive:
            invalid = archive.testzip()
            if invalid:
                raise ValueError(f"ZIP 完整性检查失败：{invalid}")
            count = len(archive.infolist())
        os.replace(temporary, zip_path)
    finally:
        temporary.unlink(missing_ok=True)

    print(f"[OK] 已生成 {zip_path.name}")
    print(f"     条目数 {count}，大小 {zip_path.stat().st_size:,} B")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
