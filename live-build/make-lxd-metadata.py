#! /usr/bin/python3

"""Make a metadata.yaml file for a LXD image."""

import argparse
import json
import sys
import time


# Map dpkg architecture names to LXD architecture names.
lxd_arches = {
    "amd64": "x86_64",
    "arm64": "aarch64",
    "armhf": "armv7l",
    "i386": "i686",
    "powerpc": "ppc",
    "ppc64el": "ppc64le",
    "s390x": "s390x",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("series", help="Ubuntu series name")
    parser.add_argument("architecture", help="Ubuntu architecture name")
    args = parser.parse_args()

    metadata = {
        "architecture": lxd_arches[args.architecture],
        "creation_date": int(time.time()),
        "properties": {
            "os": "Ubuntu",
            "series": args.series,
            "architecture": args.architecture,
            "description": "Ubuntu buildd %s %s" % (
                args.series, args.architecture),
            },
        }

    # Encoding this as JSON is good enough, and saves pulling in a YAML
    # library dependency.
    json.dump(
        metadata, sys.stdout, sort_keys=True, indent=4, separators=(",", ": "),
        ensure_ascii=False)


if __name__ == "__main__":
    main()
