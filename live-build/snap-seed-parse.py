#!/usr/bin/python3

"""
Usage: snap-seed-parse [${chroot_dir}] <output file>

This script looks for a seed.yaml path in the given root directory, parsing
it and appending the parsed lines to the given output file.

The $chroot_dir argument is optional and will default to the empty string.
"""

import argparse
import glob
import os.path
import re
import yaml


def log(msg):
    print("snap-seed-parse: {}".format(msg))


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
CHROOT_ROOT = CHROOT_ROOT.rstrip('/')
log("CHROOT_ROOT: {}".format(CHROOT_ROOT))

# Snaps are prepended with this string in the manifest
LINE_PREFIX = 'snap:'

# This is where we expect to find the seed.yaml file
YAML_PATH = CHROOT_ROOT + '/var/lib/snapd/seed/seed.yaml'

log("yaml path: {}".format(YAML_PATH))


def make_manifest_from_seed_yaml(path):
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


def look_for_uc20_model(chroot):
    modeenv = f"{chroot}/var/lib/snapd/modeenv"
    system_name = None
    if os.path.isfile(modeenv):
        log(f"found modeenv file at {modeenv}")
        with open(modeenv) as fh:
            for line in fh:
                if line.startswith("recovery_system="):
                    system_name = line.split('=', 1)[1].strip()
                    log(f"read system name {system_name!r} from modeenv")
                    break
    if system_name is None:
        system_names = os.listdir(f"{chroot}/var/lib/snapd/seed/systems")
        if len(system_names) == 0:
            log("no systems found")
            return None
        elif len(system_names) > 1:
            log("multiple systems found, refusing to guess which to parse")
            return None
        else:
            system_name = system_names[0]
            log(f"parsing only system found {system_name}")
    system_dir = f"{chroot}/var/lib/snapd/seed/systems/{system_name}"
    if not os.path.isdir(system_dir):
        log(f"could not find system called {system_name}")
        return None
    return system_dir


def parse_assertion_file(asserts, filename):
    # Parse the snapd assertions file 'filename' and store the
    # assertions found in 'asserts'.
    with open(filename) as fp:
        text = fp.read()

    k = ''

    for block in text.split('\n\n'):
        if block.startswith('type:'):
            this_assert = {}
            for line in block.split('\n'):
                if line.startswith(' '):
                    this_assert[k.strip()] += '\n' + line
                    continue
                k, v = line.split(':', 1)
                this_assert[k.strip()] = v.strip()
            asserts.setdefault(this_assert['type'], []).append(this_assert)


def make_manifest_from_system(system_dir):
    files = [f"{system_dir}/model"] + glob.glob(f"{system_dir}/assertions/*")

    asserts = {}
    for filename in files:
        parse_assertion_file(asserts, filename)

    [model] = asserts['model']
    snaps = yaml.safe_load(model['snaps'])

    snap_names = []
    for snap in snaps:
        snap_names.append(snap['name'])
    snap_names.sort()

    snap_name_to_id = {}
    snap_id_to_rev = {}
    for decl in asserts['snap-declaration']:
        snap_name_to_id[decl['snap-name']] = decl['snap-id']
    for rev in asserts['snap-revision']:
        snap_id_to_rev[rev['snap-id']] = rev['snap-revision']

    log('Writing manifest to {}'.format(FNAME))

    with open(FNAME, 'a+') as fh:
        for snap_name in snap_names:
            channel = snap['default-channel']
            rev = snap_id_to_rev[snap_name_to_id[snap_name]]
            fh.write(f"{LINE_PREFIX}{snap_name}\t{channel}\t{rev}\n")


if os.path.isfile(YAML_PATH):
    log(f"seed.yaml found at {YAML_PATH}")
    make_manifest_from_seed_yaml(YAML_PATH)
else:
    system_dir = look_for_uc20_model(CHROOT_ROOT)
    if system_dir is None:
        log("WARNING: could not find seed.yaml or uc20-style seed")
        exit(0)
    make_manifest_from_system(system_dir)

log('Manifest output finished.')
