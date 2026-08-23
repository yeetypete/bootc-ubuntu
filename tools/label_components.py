#!/usr/bin/env python3
"""Label every package-owned regular file with the source package that owns it."""

import argparse
import os
import stat
import subprocess
import sys
from pathlib import Path

XATTR_NAME = "user.component"

# dpkg-query interprets the backslash escapes itself.
QUERY_FORMAT = r"${binary:Package}\t${source:Package}\t${db:Status-Status}\n"


def source_packages(admindir: Path) -> dict[str, str]:
    """Map each installed binary package to the source package it was built from.

    The source package is the grouping chunkah's rpm backend uses via the SRPM,
    and it keeps subpackages built from one source in a single component.
    """
    completed = subprocess.run(
        ["dpkg-query", f"--admindir={admindir}", "-f", QUERY_FORMAT, "-W"],
        capture_output=True,
        check=True,
        text=True,
    )
    packages: dict[str, str] = {}
    for line in completed.stdout.splitlines():
        binary, source, status = line.split("\t")
        if status == "installed":
            packages[binary] = source
    return packages


def label_package(list_file: Path, source: str) -> None:
    """Set the component xattr on every regular file a package owns.

    Regular files only. Directories are shared between packages, and the kernel
    rejects user.* xattrs on symlinks. Many listed paths are absent because
    Ubuntu's dpkg excludes drop man pages, locales and documentation.
    """
    value = source.encode()
    for path in list_file.read_bytes().split(b"\n"):
        if not path:
            continue
        try:
            info = os.lstat(path)
        except OSError:
            continue
        if stat.S_ISREG(info.st_mode):
            os.setxattr(path, XATTR_NAME, value)


def parse_args() -> argparse.Namespace:
    """Parse the command line."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("admindir", type=Path, help="the dpkg admin directory")
    return parser.parse_args()


def main() -> int:
    """Label every package listed in the dpkg database given on the command line."""
    admindir: Path = parse_args().admindir
    source_of = source_packages(admindir)

    labelled = 0
    skipped = 0
    for list_file in sorted(admindir.glob("info/*.list")):
        source = source_of.get(list_file.stem)
        if source is None:
            print(
                f"No source package for {list_file.stem}, leaving its files unclaimed.",
                file=sys.stderr,
            )
            skipped += 1
            continue
        label_package(list_file, source)
        labelled += 1

    print(f"Labelled {labelled} packages, skipped {skipped}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
