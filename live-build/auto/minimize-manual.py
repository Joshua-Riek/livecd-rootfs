#!/usr/bin/python3
"""Minimize the number of manually installed packages in the image.

Finds all manually meta packages and marks their dependencies as
automatically installed.
"""
import apt
import sys


def is_root(pkg):
    return (pkg.is_installed and
            not pkg.is_auto_installed and
            (pkg.section == "metapackages" or
             pkg.section.endswith("/metapackages")))


c = apt.Cache(rootdir=sys.argv[1] if len(sys.argv) > 1 else None)

roots = set(pkg for pkg in c if is_root(pkg))
workset = set(roots)
seen = set()

with c.actiongroup():
    while True:

        print("Iteration", file=sys.stderr)
        to_proc = workset - seen
        if not to_proc:
            break
        for pkg in sorted(to_proc):
            print("    Visiting", pkg, file=sys.stderr)

            # Mark every
            if pkg not in roots:
                pkg.mark_auto()

            for dep in pkg.installed.dependencies + pkg.installed.recommends:
                if dep.rawtype not in ('Depends', 'PreDepends', 'Recommends'):
                    continue
                for bdep in dep.or_dependencies:
                    for v in bdep.target_versions:
                        if v.package.is_installed:
                            workset.add(v.package)

            seen.add(pkg)

    c.commit()
