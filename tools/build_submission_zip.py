# -*- coding: utf-8 -*-
"""重建提交压缩包 `知学Mate+暗影骑士王们.zip`（在**本仓库根目录**上跑）。

## 为什么需要它

仓库里原有的 `tools/build_v2.py` 把源/目标写死成
`SRC = E:\\C4-liantiao\\liantiao5` / `DST = E:\\C4-liantiao\\V2`，**不能作用于本仓库**。
而本仓库里的 zip 是当时从 V2 拷过来的，源码一改它就过期了 ——
交付物与源码不一致是提交里最危险的一类问题（评审拿到的是旧代码）。

本脚本按**本仓库的现有布局**重建 zip，排除规则与 `build_v2.py` 完全一致：
`.git` / `.hvigor` / `.idea` / `build` / `oh_modules` / `node_modules` / `__pycache__` /
`.pytest-tmp` / `.pytest_cache` / `*.pyc` / `.env` / `data/repository.json` /
`chat/history.json` / 本地签名备份。

用法::

    python tools/build_submission_zip.py [--check] [--hap path] [--output path]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "知学Mate"
ZIP_NAME = "知学Mate+暗影骑士王们.zip"

ROOT_DIRS = ["app", "contracts", "server", "tools", "integration", "演示测试数据"]
EXTRA_DIRS = [("03-演示文件与源代码/联调与验证", "联调与验证")]
DEMO_GUIDE = "02-演示视频/README-待录制.md"

from packaging_policy import should_skip, iter_source_files, sanitized_bytes, assert_safe_content
import os
import uuid


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="只统计，不写文件")
    parser.add_argument("--hap", type=Path, help="明确指定本次已构建签名 HAP")
    parser.add_argument("--output", type=Path, default=ROOT / ZIP_NAME, help="输出 ZIP 的路径")
    args = parser.parse_args()

    hap = args.hap or ROOT / "hap/知学Mate-signed.hap"
    if not hap.is_file():
        print("[FAIL] 找不到 %s —— 先构建签名 HAP 再打包" % hap.name)
        return 1

    zip_path = args.output
    written: set[str] = set()
    dup: list[str] = []

    def add(archive: zipfile.ZipFile, src: Path, arcname: str) -> bool:
        if arcname in written:
            dup.append(arcname)
            return False
        data = sanitized_bytes(src)
        assert_safe_content(data, arcname)
        archive.writestr(arcname, data)
        written.add(arcname)
        return True

    if args.check:
        count = 0
        for name in ROOT_DIRS:
            base = ROOT / name
            if base.exists():
                count += sum(1 for p in iter_source_files(base) if p.is_file() and not should_skip(p))
        print("[CHECK] 预计条目数（不含文档/HAP）：%d" % count)
        return 0

    zip_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = zip_path.with_name(zip_path.name + "." + uuid.uuid4().hex + ".tmp")
    with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        hap_entry = f"{PRODUCT}/hap/知学Mate-signed.hap"
        hap_bytes = hap.read_bytes()
        z.writestr(hap_entry, hap_bytes)
        written.add(hap_entry)
        manifest_entry = f"{PRODUCT}/hap/manifest.json"
        z.writestr(manifest_entry, json.dumps({
            "file": "知学Mate-signed.hap",
            "size": len(hap_bytes),
            "sha256": hashlib.sha256(hap_bytes).hexdigest(),
        }, ensure_ascii=False, indent=2) + "\n")
        written.add(manifest_entry)
        hap_readme = f"{PRODUCT}/hap/README.md"
        z.writestr(hap_readme, "# 演示安装包\n\n"
                   "- [知学Mate-signed.hap](知学Mate-signed.hap)\n"
                   "- [文件大小与 SHA-256](manifest.json)\n"
                   f"- [开录自检](../{DEMO_GUIDE})\n")
        written.add(hap_readme)

        for name in ROOT_DIRS:
            base = ROOT / name
            if not base.is_dir():
                print("  !! 缺少目录 %s" % name)
                continue
            for path in sorted(iter_source_files(base)):
                if not path.is_file() or should_skip(path):
                    continue
                add(z, path, f"{PRODUCT}/{path.relative_to(ROOT).as_posix()}")

        for src_rel, arc_prefix in EXTRA_DIRS:
            base = ROOT / src_rel
            if not base.is_dir():
                continue
            for path in sorted(iter_source_files(base)):
                if not path.is_file() or should_skip(path):
                    continue
                add(z, path, f"{PRODUCT}/{arc_prefix}/{path.relative_to(base).as_posix()}")

        for path in sorted(ROOT.iterdir()):
            if not path.is_file() or should_skip(path):
                continue
            if path.name == ZIP_NAME:
                continue
            if path.suffix.lower() in (".md", ".ps1", ".gitattributes", "") or path.name == "LICENSE":
                add(z, path, f"{PRODUCT}/{path.name}")

        for relative in [DEMO_GUIDE] + [f"D{number:02}.svg" for number in range(1, 8)]:
            path = ROOT / relative
            if path.is_file():
                add(z, path, f"{PRODUCT}/{relative}")

        docdir = ROOT / "01-作品说明文档"
        for p in sorted(docdir.glob("*.pdf")) if docdir.is_dir() else []:
            add(z, p, f"{PRODUCT}/作品说明文档/{p.name}")

    os.replace(temporary, zip_path)
    size = zip_path.stat().st_size
    print("[OK] 已生成 %s" % zip_path.name)
    print("     条目数 : %d" % len(written))
    print("     大小   : %d B (%.2f MB)" % (size, size / 1024 / 1024))
    if dup:
        print("     !! 重复路径被跳过 %d 个（前几个：%s）" % (len(dup), dup[:3]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
