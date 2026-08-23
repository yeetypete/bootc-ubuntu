#!/usr/bin/env python3
"""Label package-owned paths with the source package that owns them for chunking
with chunkah."""

import argparse
import os
import stat
import subprocess
import sys
from collections import defaultdict
from pathlib import Path, PurePosixPath
from typing import NamedTuple

# Recorded path to source package.
type Owners = dict[str, str]
# Directory to the source package owning its whole subtree.
type Components = dict[PurePosixPath, str]


class LabelCounts(NamedTuple):
    """What one labelling pass touched."""

    files: int
    unclaimed_symlinks: int
    broken_hardlinks: int
    broken_hardlink_bytes: int


COMPONENT_XATTR = "user.component"

# dpkg-query interprets the backslash escapes itself.
QUERY_FORMAT = r"${binary:Package}\t${source:Package}\t${db:Status-Status}\n"

# States in which a package's files are on disk. A package awaiting a trigger is
# still installed.
INSTALLED_STATES = frozenset({"installed", "triggers-awaiting", "triggers-pending"})


def source_packages(admindir: Path) -> dict[str, str]:
    """Map each installed binary package to its source package.

    Args:
        admindir: The dpkg admin directory.

    Returns:
        Binary package name to source package name.
    """
    completed = subprocess.run(
        ["dpkg-query", f"--admindir={admindir}", "-f", QUERY_FORMAT, "-W"],
        stdout=subprocess.PIPE,
        check=True,
        text=True,
    )
    packages = {}
    for line in completed.stdout.splitlines():
        binary, source, status = line.split("\t")
        if status in INSTALLED_STATES:
            packages[binary] = source
    return packages


def owned_paths(admindir: Path, source_of: dict[str, str]) -> tuple[Owners, list[str]]:
    """Map every file and symlink dpkg records to its source package.

    Directories are skipped, because dpkg lists a shared directory under every
    package installing into it. Absent paths are skipped too, since the base
    image's dpkg excludes drop man pages, locales and documentation.

    Args:
        admindir: The dpkg admin directory.
        source_of: Binary package name to source package name.

    Returns:
        The owned paths, and the packages with no known source package.
    """
    owners: Owners = {}
    unknown = []
    for list_file in sorted(admindir.glob("info/*.list")):
        source = source_of.get(list_file.stem)
        if source is None:
            unknown.append(list_file.stem)
            continue
        # surrogateescape preserves paths that are not valid UTF-8.
        listed = list_file.read_text(encoding="utf-8", errors="surrogateescape")
        for path in listed.splitlines():
            try:
                mode = os.lstat(path).st_mode
            except OSError:
                continue
            if stat.S_ISREG(mode) or stat.S_ISLNK(mode):
                owners[path] = source
    return owners, unknown


def wholly_owned_dirs(owners: Owners) -> Components:
    """Find the topmost directories whose recorded contents come from one source.

    chunkah applies a directory's component to everything beneath it, so one
    xattr here stands in for thousands below.

    Args:
        owners: Recorded path to source package.

    Returns:
        Directory to the source package owning its whole subtree.
    """
    sources: dict[PurePosixPath, set[str]] = defaultdict(set)
    for path, source in owners.items():
        for directory in PurePosixPath(path).parents:
            sources[directory].add(source)

    owned = {d for d, s in sources.items() if len(s) == 1}
    return {d: next(iter(sources[d])) for d in owned if d.parent not in owned}


def apply_labels(owners: Owners, components: Components) -> LabelCounts:
    """Write the component xattr onto each directory and the paths it misses.

    Args:
        owners: Recorded path to source package.
        components: Directory to the source package owning its whole subtree.

    Returns:
        What the pass labelled, and what it could not.
    """
    for directory, source in components.items():
        os.setxattr(directory, COMPONENT_XATTR, source.encode())

    files = symlinks = hardlinks = unshared = 0
    for path, source in owners.items():
        if any(d in components for d in PurePosixPath(path).parents):
            continue
        info = os.lstat(path)
        if stat.S_ISLNK(info.st_mode):
            # The kernel rejects user.* xattrs on symlinks.
            symlinks += 1
            continue
        if info.st_nlink > 1:
            # Copying the file out of its layer breaks the link, which costs
            # a duplicate of its contents.
            hardlinks += 1
            unshared += info.st_size
        os.setxattr(path, COMPONENT_XATTR, source.encode())
        files += 1
    return LabelCounts(files, symlinks, hardlinks, unshared)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("admindir", type=Path, help="the dpkg admin directory")
    return parser.parse_args()


def main() -> int:
    """Label every path recorded in the dpkg database given on the command line.

    Returns:
        1 if nothing was labelled, 0 otherwise.
    """
    admindir: Path = parse_args().admindir
    owners, unknown = owned_paths(admindir, source_packages(admindir))
    for package in unknown:
        print(
            f"No source package for {package}, leaving its files unclaimed.",
            file=sys.stderr,
        )

    components = wholly_owned_dirs(owners)
    files, symlinks, hardlinks, unshared = apply_labels(owners, components)
    if not components and not files:
        print(f"Nothing to label under {admindir}.", file=sys.stderr)
        return 1

    print(
        f"Labelled {len(set(owners.values()))} components as "
        f"{len(components)} directories and {files} files."
    )
    if symlinks:
        print(f"{symlinks} unclaimed symlinks have no labelled directory above them.")
    if hardlinks:
        mib = unshared / 1024**2
        print(f"{hardlinks} hardlinked files ({mib:.0f} MiB) no longer share inodes.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
