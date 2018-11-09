#!/usr/bin/python3

"""
Usage: snap-seed-parse [${chroot_dir}] <output file>

This script looks for a seed.yaml path in the given root directory, parsing
it and appending the parsed lines to the given output file.

The $chroot_dir argument is optional and will default to the empty string.
"""

import argparse
import os.path
import re
import yaml


def log(msg):
    print("snap-seed-parse: {}\n".format(msg))


log("Parsing seed.yaml")

parser = argparse.ArgumentParser()
parser.add_argument('chroot', nargs='?', default='',
                    help='root dir for the chroot from which to generate the '
                         'manifest')
parser.add_argument('file', help='Output manifest to this file')

ARGS = parser.parse_args()
CHROOT_ROOT = ARGS.chroot
FNAME = ARGS.file

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

log('Writing manifest to {}'.format(FNAME))

with open(FNAME, 'a+') as fh:
    for item in yaml_lines:
        filestring = item['file']
        # Pull the revision number off the file name
        revision = filestring[filestring.rindex('_')+1:]
        revision = re.sub(r'[^0-9]', '', revision)
        fh.write("{}{}\t{}\t{}\n".format(LINE_PREFIX,
                                         item['name'],
                                         item['channel'],
                                         revision,
                                         ))
log('Manifest output finished.')
