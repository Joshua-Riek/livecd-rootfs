#!/bin/sh

# policy-rc.d script for chroots.
# Copyright (c) 2007 Peter Palfrader <peter@palfrader.org>
# License: <weasel> MIT, if you want one.

while true; do
  case "$1" in
    -*)         shift ;;
    makedev)    exit 0;;
    *) echo "Not running services in chroot."; exit 101 ;;
  esac
done
