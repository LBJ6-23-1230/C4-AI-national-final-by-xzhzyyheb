"""Export reviewed source into a clean clone; never commit, push or alter Git metadata."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess

from packaging_policy import iter_source_files, sanitized_bytes, assert_safe_content

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "LBJ6-23-1230/C4-AI-national-final-by-xzhzyyheb"
LIMIT = 100 * 1024 * 1024


def git(target, *arguments):
    result = subprocess.run(["git", "-C", str(target), *arguments],
                            capture_output=True, text=True, encoding="utf-8", errors="replace")
    if result.returncode:
        raise ValueError("Git check failed: " + result.stderr.strip())
    return result.stdout.strip()


def validate_clone(target):
    if target == ROOT or target.is_relative_to(ROOT) or ROOT.is_relative_to(target):
        raise ValueError("Use a separate sibling clone, outside the source directory")
    if Path(git(target, "rev-parse", "--show-toplevel")).resolve() != target:
        raise ValueError("Target must be the root of the cloned repository")
    allowed = {f"https://github.com/{REPOSITORY}.git", f"https://github.com/{REPOSITORY}",
               f"git@github.com:{REPOSITORY}.git"}
    if git(target, "remote", "get-url", "origin") not in allowed:
        raise ValueError("Target origin is not the requested GitHub repository")
    if git(target, "branch", "--show-current") != "main":
        raise ValueError("Use a clean clone on main")
    if git(target, "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("Target has local changes; review them before exporting again")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path, help="root of a fresh clone on main")
    parser.add_argument("--check-source", action="store_true", help="validate source without copying")
    args = parser.parse_args()
    if not args.check_source and args.target is None:
        parser.error("--target is required unless using --check-source")
    target = args.target.resolve() if args.target else None
    if target:
        validate_clone(target)
    # Preflight ALL files before changing anything in the clone.
    files = list(iter_source_files(ROOT))
    total = 0
    for source in files:
        relative = source.relative_to(ROOT)
        data = sanitized_bytes(source)
        if len(data) >= LIMIT:
            raise ValueError(f"File reaches GitHub's 100 MiB limit: {relative}")
        assert_safe_content(data, relative)
        total += len(data)
        if target:
            destination = target / relative
            if destination.is_symlink() or not destination.resolve().is_relative_to(target):
                raise ValueError(f"Unsafe target path: {relative}")
            if destination.exists() and not destination.is_file():
                raise ValueError(f"Target path is not a regular file: {relative}")
    copied = 0
    if target and not args.check_source:
        for source in files:
            destination = target / source.relative_to(ROOT)
            data = sanitized_bytes(source)
            if destination.exists() and destination.read_bytes() == data:
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
            copied += 1
    print(f"Validated {len(files)} files ({total} bytes); copied {copied} changed/new files.")
    print("Excluded local databases, uploaded originals, dependencies, private keys and real .env files.")
    print("Git history is preserved. Review git status/diff, then commit and push yourself.")
    print("Remote-only files are retained; review any obsolete files separately.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError) as error:
        raise SystemExit(str(error)) from None
