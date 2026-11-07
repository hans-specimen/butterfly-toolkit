#!/usr/bin/env python3
"""Explicit local version updates and checks. No network, commits, or tags."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
CONFIG = "Config/Version.xcconfig"
PROJECT = "Butterfly Toolkit.xcodeproj/project.pbxproj"
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
VERSION_KEY = "MARKETING_VERSION"
BUILD_KEY = "CURRENT_PROJECT_VERSION"


def run(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.strip() or f"命令失败：{' '.join(args)}")
    return result.stdout.strip()


def read_version(text):
    values = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        match = re.fullmatch(r"(MARKETING_VERSION|CURRENT_PROJECT_VERSION)\s*=\s*(\S+)", line)
        if not match or match[1] in values:
            raise ValueError(f"{CONFIG} 仅允许各一项版本设置及独立 // 注释：{line}")
        values[match[1]] = match[2]
    if not re.fullmatch(VERSION_PATTERN, values.get(VERSION_KEY, "")):
        raise ValueError("版本必须为不含前导零的三段数字，例如 1.2.3")
    if not re.fullmatch(r"[1-9][0-9]*", values.get(BUILD_KEY, "")):
        raise ValueError("Build 必须为不含前导零的正整数")
    return tuple(map(int, values[VERSION_KEY].split("."))), int(values[BUILD_KEY])


def version_text(version):
    return ".".join(map(str, version))


def check_project():
    project = json.loads(run("plutil", "-convert", "json", "-o", "-", PROJECT))
    objects = project["objects"]
    configuration_list = objects[objects[project["rootObject"]]["buildConfigurationList"]]
    project_configs = set(configuration_list["buildConfigurations"])
    protected = {VERSION_KEY, BUILD_KEY, "INFOPLIST_KEY_CFBundleShortVersionString",
                 "INFOPLIST_KEY_CFBundleVersion"}
    for key, obj in objects.items():
        if obj.get("isa") != "XCBuildConfiguration":
            continue
        if any(setting.split("[", 1)[0] in protected for setting in obj["buildSettings"]):
            raise ValueError("Xcode 项目包含重复版本设置；请只修改 Config/Version.xcconfig")
        reference = obj.get("baseConfigurationReference")
        if key in project_configs or reference:
            config = objects.get(reference, {})
            if config.get("path") != CONFIG or config.get("sourceTree") != "SOURCE_ROOT":
                raise ValueError(f"{obj['name']} 未使用统一版本配置；请检查 Xcode 配置引用")


def bump(part, version, build, text):
    parts = list(version)
    if part != "build":
        index = {"major": 0, "minor": 1, "patch": 2}[part]
        parts[index] += 1
        parts[index + 1:] = [0] * (2 - index)
    for key, value in [(VERSION_KEY, version_text(parts)), (BUILD_KEY, str(build + 1))]:
        text = re.sub(rf"(?m)^([ \t]*{key}[ \t]*=[ \t]*)\S+",
                      lambda match: match[1] + value, text)
    (ROOT / CONFIG).write_text(text, encoding="utf-8")
    return tuple(parts), build + 1


def check_notes(version, build):
    text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    sections = re.findall(r"^## \[([^\]]+)\](.*?)\n(.*?)(?=^## |\Z)", text,
                          flags=re.MULTILINE | re.DOTALL)
    releases = [section for section in sections if section[0] != "Unreleased"]
    if not releases or releases[0][0] != version_text(version):
        raise ValueError("CHANGELOG.md 最新留档章节必须对应当前版本")
    if len({section[0] for section in releases}) != len(releases):
        raise ValueError("CHANGELOG.md 含重复版本章节")
    _, heading, body = releases[0]
    date = re.fullmatch(r" - ([0-9]{4}-[0-9]{2}-[0-9]{2})", heading)
    if not date:
        raise ValueError("留档标题格式：## [1.2.3] - YYYY-MM-DD")
    datetime.date.fromisoformat(date[1])
    if re.findall(r"^Build: (.+)$", body, re.MULTILINE) != [str(build)]:
        raise ValueError("留档章节必须有一行与当前配置一致的 Build: N")
    if not re.search(r"^- \S.*", body, re.MULTILINE):
        raise ValueError("留档章节至少需要一条非空的 '- 变更说明'")


def check_milestone(version, build):
    if run("git", "rev-parse", "--is-shallow-repository") != "false":
        raise ValueError("留档检查需要完整 Git 历史，不能使用浅克隆")
    if run("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("留档前请先提交或妥善保存全部改动（包括未跟踪文件）")
    check_notes(version, build)
    head = run("git", "rev-parse", "HEAD")
    for tag in run("git", "tag", "--list", "v*").splitlines():
        if not re.fullmatch("v" + VERSION_PATTERN, tag):
            continue
        reference = f"refs/tags/{tag}"
        old_version, old_build = read_version(run("git", "show", f"{reference}:{CONFIG}"))
        if tag != "v" + version_text(old_version):
            raise ValueError(f"标签 {tag} 与该提交的版本配置不一致")
        if old_version == version:
            if run("git", "rev-parse", f"{reference}^{{commit}}") != head:
                raise ValueError(f"{tag} 已用于其他提交，请升级产品版本，不要移动旧标签")
            if run("git", "cat-file", "-t", reference) != "tag":
                raise ValueError(f"{tag} 必须是附注标签（git tag -a）")
        elif old_version > version or old_build >= build:
            raise ValueError(f"当前版本和 Build 必须都高于已有留档 {tag} ({old_build})")


def check_app(path, version, build):
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    expected = {"CFBundleShortVersionString": version_text(version),
                "CFBundleVersion": str(build),
                "CFBundleIdentifier": "com.hans.Butterfly-Toolkit"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f"产物 {key} 不一致：期望 {value}，实际 {info.get(key)!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("show", help="显示当前版本")
    update = commands.add_parser("bump", help="显式升级版本；所有方式均使 Build +1")
    update.add_argument("part", choices=["major", "minor", "patch", "build"])
    check = commands.add_parser("check", help="检查版本配置")
    check.add_argument("--milestone", action="store_true", help="检查本地稳定版本留档条件")
    check.add_argument("--app", type=Path, help="同时核对指定 .app 的版本字段")
    args = parser.parse_args()
    try:
        text = (ROOT / CONFIG).read_text(encoding="utf-8")
        version, build = read_version(text)
        if args.command != "show":
            check_project()
        if args.command == "bump":
            version, build = bump(args.part, version, build, text)
        elif args.command == "check":
            if args.milestone:
                check_milestone(version, build)
            if args.app:
                check_app(args.app.expanduser().resolve(), version, build)
            print("检查通过" + ("（仅检查本地 Git 标签）" if args.milestone else ""))
        print(f"{version_text(version)} ({build})")
        return 0
    except (ValueError, OSError, KeyError, plistlib.InvalidFileException) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
