#!/usr/bin/python3

"""
Usage: snap-seed-parse ${chroot_dir} > somefile.manifest

This script looks for a seed.yaml path in the given root directory, parsing
it and printing generated manifest lines to stdout for easy redirection.
"""

import re
import sys
import yaml
import os.path


def log(msg):
    sys.stderr.write("snap-seed-parse: {}\n".format(msg))


log("Parsing seed.yaml")

CHROOT_ROOT = sys.argv[1] if len(sys.argv) > 1 and len(sys.argv[1]) > 0 \
                          else ''

# Trim any trailing slashes for correct appending
log("CHROOT_ROOT: {}".format(CHROOT_ROOT))
if len(CHROOT_ROOT) > 0 and CHROOT_ROOT[-1] == '/':
    CHROOT_ROOT = CHROOT_ROOT[:-1]

# This is where we expect to find the seed.yaml file
YAML_PATH = CHROOT_ROOT + '/var/lib/snapd/seed/seed.yaml'

# Snaps are prepended with this string in the manifest
LINE_PREFIX = 'snap:'

log("yaml path: {}".format(YAML_PATH))
if not os.path.isfile(YAML_PATH):
    log("WARNING: yaml path not found; no seeded snaps found.")
    exit(0)
else:
    log("yaml path found.")

with open(YAML_PATH, 'r') as fh:
    yaml_lines = yaml.safe_load(fh)['snaps']

# Loop over dict items, outputting one manifest line from each triplet
for item in yaml_lines:
    filestring = item['file']
    # Pull the revision number off the file name
    revision = filestring[filestring.rindex('_')+1:]
    revision = re.sub(r'[^0-9]', '', revision)
    print("{}{}\t{}\t{}".format(LINE_PREFIX,
                                        item['name'],
                                        item['channel'],
                                        revision,
                                        ))
