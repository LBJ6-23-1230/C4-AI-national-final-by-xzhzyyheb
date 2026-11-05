# -*- coding: utf-8 -*-
"""Inspect a HarmonyOS .p7b Profile.

Important:
    `app-privilege-capabilities` is about *application privileges* (for example
    AllowAppDataNotCleared / AllowAppDesktopIconHide), NOT about Push Kit.
    An empty list is normal for most apps and does NOT mean Push Kit is missing.

    Push Kit is controlled by AGC:
      - 推送服务 console (enable push service)
      - 开放能力管理 -> 推送服务 (open capability switch)
      - 自分类权益 (message category approval)
      - service-account JWT on the server

Usage:
    python tools/check_p7b_capabilities.py <profile.p7b>
"""
from __future__ import annotations

import datetime as _dt
import json
import sys
from pathlib import Path


def _extract_profile_json(path: Path) -> dict:
    data = path.read_bytes()
    starts: list[int] = []
    idx = data.find(b'{"')
    while idx != -1:
        starts.append(idx)
        idx = data.find(b'{"', idx + 1)
    for start in starts:
        text = data[start:].decode("utf-8", "ignore")
        try:
            obj, _ = json.JSONDecoder().raw_decode(text)
        except Exception:
            continue
        if isinstance(obj, dict) and "type" in obj and "bundle-info" in obj:
            return obj
    return {}


def _fmt_time(value) -> str:
    try:
        return _dt.datetime.fromtimestamp(int(value), _dt.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except Exception:
        return str(value)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python tools/check_p7b_capabilities.py <profile.p7b>")
        return 1

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"[X] File not found: {path}")
        return 1

    prof = _extract_profile_json(path)
    if not prof:
        print("[X] Cannot extract Profile JSON from the p7b file")
        return 1

    bundle = prof.get("bundle-info", {})
    debug = prof.get("debug-info", {}) or {}
    caps = prof.get("app-privilege-capabilities") or []
    acls = prof.get("acls") or {}

    print(f"File              : {path}")
    print(f"Type              : {prof.get('type')}")
    print(f"Issuer            : {prof.get('issuer')}")
    print(f"Bundle name       : {bundle.get('bundle-name')}")
    print(f"App identifier    : {bundle.get('app-identifier')}")
    print(f"Device ID type    : {debug.get('device-id-type')}")
    print(f"Device IDs        : {debug.get('device-ids') or []}")
    print(f"App privileges    : {caps}")
    print(f"ACL               : {acls}")
    print(f"Validity          : {_fmt_time(prof.get('validity', {}).get('not-before'))} -> "
          f"{_fmt_time(prof.get('validity', {}).get('not-after'))}")

    print()
    if caps:
        print("[OK] The Profile declares application privileges. This is normal.")
    else:
        print("[OK] app-privilege-capabilities is empty.")
        print("     This is NORMAL for apps that do not need special application privileges.")
        print("     It does NOT mean Push Kit is unavailable.")
    print("     Push Kit is controlled by AGC Push Service / Open Capability, not by this field.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
