#!/usr/bin/env python3

import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable


GENERAL_PR_PATTERN = re.compile(
    r"https://github\.com/JuliaRegistries/General/pull/(?P<number>[0-9]+)"
)
VERSION_TITLE_PATTERN = re.compile(
    r"^New version: (?P<package>[^ ]+) v(?P<version>[^ ]+)$"
)
PROJECT_NAME_PATTERN = re.compile(
    r"^\s*name\s*=\s*(?P<quote>['\"])(?P<name>[A-Za-z][A-Za-z0-9_]*)"
    r"(?P=quote)\s*(?:#.*)?$"
)


class ResolutionError(RuntimeError):
    pass


@dataclass(frozen=True)
class Resolution:
    subdirs: list[str]
    mode: str
    package: str = ""
    version: str = ""


def discover_packages(workspace: Path) -> dict[str, str]:
    projects = [workspace / "Project.toml"]
    lib = workspace / "lib"
    if lib.is_dir():
        projects.extend(sorted(lib.glob("*/Project.toml")))

    packages: dict[str, str] = {}
    for project in projects:
        if not project.is_file():
            continue
        name = None
        for line in project.read_text(encoding="utf-8").splitlines():
            if line.lstrip().startswith("["):
                break
            match = PROJECT_NAME_PATTERN.fullmatch(line)
            if match is not None:
                name = match.group("name")
                break
        if name is None:
            continue
        subdir = (
            ""
            if project.parent == workspace
            else project.parent.relative_to(workspace).as_posix()
        )
        if name in packages:
            raise ResolutionError(f"duplicate package name {name!r} in the monorepo")
        packages[name] = subdir

    if not packages:
        raise ResolutionError(
            "no Julia packages were found at the repository root or under lib/*"
        )
    return packages


def general_pr_number(comment_body: str) -> int | None:
    matches = {
        int(match.group("number"))
        for match in GENERAL_PR_PATTERN.finditer(comment_body)
    }
    if not matches:
        return None
    if len(matches) != 1:
        raise ResolutionError(
            "the JuliaTagBot comment references multiple General pull requests"
        )
    return matches.pop()


def package_version(title: str) -> tuple[str, str]:
    match = VERSION_TITLE_PATTERN.fullmatch(title)
    if match is None:
        raise ResolutionError(f"unexpected General pull request title: {title!r}")
    return match.group("package"), match.group("version")


def fetch_general_pr(number: int, token: str) -> dict[str, object]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "SciML-monorepo-TagBot",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"https://api.github.com/repos/JuliaRegistries/General/pulls/{number}",
        headers=headers,
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise ResolutionError(
            f"General pull request {number} lookup failed with HTTP {error.code}"
        ) from error
    except urllib.error.URLError as error:
        raise ResolutionError(
            f"General pull request {number} lookup failed: {error.reason}"
        ) from error


def resolve(
    workspace: Path,
    comment_body: str,
    manual_package: str,
    token: str,
    fetch_pr: Callable[[int, str], dict[str, object]] = fetch_general_pr,
) -> Resolution:
    packages = discover_packages(workspace)

    if manual_package:
        if manual_package not in packages:
            raise ResolutionError(
                f"manual package {manual_package!r} was not found in the monorepo"
            )
        return Resolution([packages[manual_package]], "manual", manual_package)

    pr_number = general_pr_number(comment_body)
    if pr_number is None:
        ordered = sorted(packages.items(), key=lambda item: (item[1] != "", item[1]))
        return Resolution([subdir for _, subdir in ordered], "full-audit")

    pull_request = fetch_pr(pr_number, token)
    title = pull_request.get("title")
    if not isinstance(title, str):
        raise ResolutionError(f"General pull request {pr_number} has no title")
    package, version = package_version(title)
    if package not in packages:
        raise ResolutionError(
            f"registered package {package!r} from General pull request {pr_number} "
            "was not found in the monorepo"
        )
    return Resolution([packages[package]], "registry-pr", package, version)


def write_output(name: str, value: str) -> None:
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as stream:
        stream.write(f"{name}={value}\n")


def write_summary(result: Resolution) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary:
        return
    if result.mode == "full-audit":
        detail = f"full audit of {len(result.subdirs)} packages"
    elif result.version:
        detail = f"{result.package} v{result.version}"
    else:
        detail = result.package
    with Path(summary).open("a", encoding="utf-8") as stream:
        stream.write(f"Resolved monorepo TagBot target: {detail} ({result.mode}).\n")


def main() -> int:
    try:
        result = resolve(
            Path(os.environ.get("GITHUB_WORKSPACE", ".")).resolve(),
            os.environ.get("TAGBOT_COMMENT_BODY", ""),
            os.environ.get("TAGBOT_MANUAL_PACKAGE", "").strip(),
            os.environ.get("TAGBOT_GITHUB_TOKEN", ""),
        )
        write_output("subdirs", json.dumps(result.subdirs, separators=(",", ":")))
        write_output("mode", result.mode)
        write_output("package", result.package)
        write_output("version", result.version)
        write_summary(result)
        return 0
    except (OSError, ResolutionError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
