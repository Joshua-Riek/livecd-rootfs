#!/usr/bin/python3
"""Minimize the number of manually installed packages in the image.

Finds all manually installed meta packages, and marks their dependencies
as automatically installed.
"""
import sys

import apt


def is_root(pkg):
    """Check if the package is a root package (manually inst. meta)"""
    return (pkg.is_installed and
            not pkg.is_auto_installed and
            (pkg.section == "metapackages" or
             pkg.section.endswith("/metapackages")))


def main():
    """Main function"""
    cache = apt.Cache(rootdir=sys.argv[1] if len(sys.argv) > 1 else None)
    roots = set(pkg for pkg in cache if is_root(pkg))
    workset = set(roots)
    seen = set()

    with cache.actiongroup():
        while True:
            print("Iteration", file=sys.stderr)
            to_proc = workset - seen
            if not to_proc:
                break
            for pkg in sorted(to_proc):
                print("    Visiting", pkg, file=sys.stderr)

                if pkg not in roots:
                    pkg.mark_auto()

                for dep in (pkg.installed.dependencies +
                            pkg.installed.recommends):
                    for bdep in dep.or_dependencies:
                        for ver in bdep.target_versions:
                            if ver.package.is_installed:
                                workset.add(ver.package)

                seen.add(pkg)

        cache.commit()


if __name__ == '__main__':
    main()
