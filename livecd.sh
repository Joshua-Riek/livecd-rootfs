#!/bin/sh -eu

#################################################################
#### (c) Copyright 2004 Canonical Ltd.  All rights reserved. ####
#################################################################

# Depends: debootstrap, rsync, cloop-utils, python

cleanup() {
    for mnt in $MOUNTS; do
	umount $mnt || true
    done

    [ -n "$DEV" ] && losetup -d $DEV || true
    grep ${ROOT} /proc/mounts && return 1 || return 0
}

if [ $(id -u) != 0 ];then
  echo "must be run as root"
  exit 2
fi

umask 022
export TTY=unknown
case $(hostname --fqdn) in
  *.mmjgroup.com)	MIRROR=http://ia/ubuntu;;
  *.warthogs.hbd.com)	MIRROR=http://jackass.warthogs.hbd.com;;
  *.ubuntu.com)		MIRROR=http://jackass.warthogs.hbd.com;;
  *)			MIRROR=http://archive.ubuntu.com/ubuntu;;
esac

# How much space do we leave on the filesystem for the user?
USZ="400*1024"		# 400MB for the user
# And how many inodes?  Default currently gives them > 100000
UINUM=""		# blank (default), or number of inodes desired.
STE=hoary

ROOT=$(pwd)/chroot-livecd/	# trailing / is CRITICAL
IMG=livecd.fsimg
MOUNTS="${ROOT}dev/pts ${ROOT}dev/shm ${ROOT}.dev ${ROOT}dev ${ROOT}proc"
DEV=""

rm -rf ${ROOT} $(pwd)/${IMG}-*

mkdir -p ${ROOT}var/cache/debconf
cat << @@EOF > ${ROOT}var/cache/debconf/config.dat
Name: debconf/frontend
Template: debconf/frontend
Value: Noninteractive
Owners: debconf
Flags: seen
@@EOF

# need to defer udev until the apt-get, since debootstrap doesn't believe
# in diversions
debootstrap --exclude=udev,ubuntu-base $STE $ROOT $MIRROR

# Just make a few things go away, which lets us skip a few other things.
# sadly, udev's postinst does some actual work, so we can't just make it
# go away completely.
DIVERTS="usr/sbin/mkinitrd usr/sbin/invoke-rc.d sbin/udevd"
for file in $DIVERTS; do
    mkdir -p ${ROOT}${file%/*}
    sudo chroot $ROOT dpkg-divert --add --local \
    				--divert /${file}.livecd --rename /${file}
    cp /bin/true ${ROOT}$file
done

# /bin/true won't cut it for mkinitrd, need to have -o support.
cat << @@EOF > ${ROOT}/usr/sbin/mkinitrd
#!/usr/bin/python
import sys

for i in range(len(sys.argv)):
    if sys.argv[i]=='-o':
	open(sys.argv[i+1],"w")
@@EOF
chmod 755 ${ROOT}usr/sbin/mkinitrd

trap "cleanup" 0 1 2 3 15

# Make a good /etc/kernel-img.conf for the kernel packages
cat << @@EOF >> ${ROOT}etc/kernel-img.conf
do_symlinks = yes
relative_links = yes
do_bootloader = no
do_bootfloppy = no
do_initrd = yes
link_in_boot = no
@@EOF

cat << @@EOF > ${ROOT}etc/locale.gen
en_US.UTF-8 UTF-8
en_GB.UTF-8 UTF-8
en_ZA.UTF-8 UTF-8
@@EOF

mkdir -p ${ROOT}proc
mount -tproc none ${ROOT}proc

# In addition to the ones we got from apt, trust whatever the local system
# believes in, but put things back afterwards.
cp ${ROOT}etc/apt/trusted.gpg ${ROOT}etc/apt/trusted.gpg.$$
cat /etc/apt/trusted.gpg >> ${ROOT}etc/apt/trusted.gpg

OTHER="xresprobe laptop-detect"
case $(dpkg --print-architecture) in
  amd64)	OTHER="$OTHER linux-amd64-generic";;
  i386)		OTHER="$OTHER linux-386";;
  ia64)		OTHER="$OTHER linux-itanium-smp linux-mckinley-smp";;
  powerpc)	OTHER="$OTHER linux-powerpc linux-power3 linux-power4";;

  # and the bastard stepchildren
  hppa)		OTHER="$OTHER linux-hppa32-smp linux-hppa64-smp";;
  sparc*)	OTHER="$OTHER linux-sparc64";;
  *)		echo "Unknown architecture: no kernel."; exit 1;;
esac

# Create a good sources.list, and finish the install
echo deb $MIRROR $STE main restricted > ${ROOT}etc/apt/sources.list
#echo deb http://rockhopper.warthogs.hbd.com/~lamont/lrm / >>  ${ROOT}etc/apt/sources.list
chroot $ROOT apt-get update
chroot $ROOT apt-get -y install ubuntu-base ubuntu-desktop $OTHER </dev/null
chroot $ROOT /etc/cron.daily/slocate
chroot $ROOT /etc/cron.daily/man-db
chroot $ROOT /usr/sbin/locale-gen

# remove our diversions
for file in $DIVERTS; do
    ls -ld ${ROOT}${file} ${ROOT}${file}.livecd || true
    rm -f ${ROOT}${file}
    chroot $ROOT dpkg-divert --remove --rename /${file}
done

# And make this look more pristene
cleanup
cat << @@EOF > ${ROOT}etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu $STE main restricted
deb-src http://archive.ubuntu.com/ubuntu $STE main restricted

## Uncomment the following two lines to add software from the 'universe'
## repository.
## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team, and may not be under a free licence. Please satisfy yourself as to
## your rights to use the software. Also, please note that software in
## universe WILL NOT receive any review or updates from the Ubuntu security
## team.
# deb http://archive.ubuntu.com/ubuntu $STE universe
# deb-src http://archive.ubuntu.com/ubuntu $STE universe

deb http://security.ubuntu.com/ubuntu ${STE}-security main restricted
deb-src http://security.ubuntu.com/ubuntu ${STE}-security main restricted
@@EOF
mv ${ROOT}etc/apt/trusted.gpg.$$ ${ROOT}etc/apt/trusted.gpg

# get rid of the .debs - we don't need them.
chroot ${ROOT} apt-get clean
rm -f ${ROOT}var/lib/apt/lists/*_*
rm -f ${ROOT}var/spool/postfix/maildrop/*

mkdir -p livecd.mnt
MOUNTS="$MOUNTS $(pwd)/livecd.mnt"
DEV=$(losetup -f);

# Make the filesystem, with some room for meta data and such
SZ=$(python -c "print int(($(du -sk $ROOT|sed 's/[^0-9].*$//')*1.1+$USZ)/1024)")
(( SZ > 2047 )) && SZ=2047
SZ=2047				# XXX fix size for now

for fsbs in 1024:65536; do 
  FSBLOCK=${fsbs%:*}
  COMP=${fsbs#*:}
  IMGNAME=${IMG}-${FSBLOCK}
  if [ ! -f ${IMGNAME} ]; then
    dd if=/dev/zero of=$IMGNAME count=$SZ bs=1M
    INUM=""
    [ -n "$UINUM" ] && INUM="-N "$(python -c "print $(find ${ROOT}|wc -l)+$UINUM") || INUM=""
    mke2fs -b $FSBLOCK $INUM -Osparse_super -F $IMGNAME
    losetup $DEV $IMGNAME
    mount $DEV livecd.mnt
    rsync -a ${ROOT} livecd.mnt
    umount $DEV
    losetup -d $DEV
  fi
  create_compressed_fs $IMGNAME $COMP > livecd.cloop-${fsbs}
done

chroot ${ROOT} dpkg-query -W --showformat='${Package} ${Version}\n' > livecd.manifest
