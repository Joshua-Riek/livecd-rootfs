#!/bin/sh -xe

# Depends: debootstrap, rsync, cloop-utils, python

cleanup() {
    for mnt in $MOUNTS; do
	umount $mnt || true
    done

    [ -n "$DEV" ] && losetup -d $DEV
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

ROOT=$(pwd)/chroot-livecd/
IMG=livecd.fsimg
MOUNTS="${ROOT}dev/pts ${ROOT}dev/shm ${ROOT}.dev ${ROOT}dev ${ROOT}proc"

rm -rf ${ROOT}

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
debootstrap --exclude=udev,ubuntu-base hoary $ROOT $MIRROR

# Just make a few things go away, which lets us skip a few other things.
# sadly, udev's postinst does some actual work, so we can't just make it
# go away completely.
DIVERTS="usr/sbin/mkinitrd usr/sbin/invoke-rc.d etc/init.d/dbus-1 sbin/udevd"
for file in $DIVERTS; do
    mkdir -p ${ROOT}${file%/*}
    cp /bin/true ${ROOT}$file
    (echo /$file; echo /${file}.livecd; echo :) >> ${ROOT}var/lib/dpkg/diversions
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

mkdir -p ${ROOT}proc
mount -tproc none ${ROOT}proc

# In addition to the ones we got from apt, trust whatever the local system
# believes in, but put things back afterwards.
cp ${ROOT}etc/apt/trusted.gpg ${ROOT}etc/apt/trusted.gpg.$$
cat /etc/apt/trusted.gpg >> ${ROOT}etc/apt/trusted.gpg

# Create a good sources.list, and finish the install
echo deb $MIRROR hoary main restricted > ${ROOT}etc/apt/sources.list
chroot $ROOT apt-get update
chroot $ROOT apt-get -y install ubuntu-base ubuntu-desktop linux-386 </dev/null

# remove our diversions
for file in $DIVERTS; do
    ls -ld ${ROOT}$file ${ROOT}$file.livecd || true
    rm -f ${ROOT}$file
    chroot $ROOT dpkg-divert --remove --rename /$file
done

# And make this look more pristene
cleanup
cat << @@EOF > ${ROOT}etc/apt/sources.list
echo deb http://archive.ubuntu.com/ubuntu hoary main restricted
echo deb-src http://archive.ubuntu.com/ubuntu hoary main restricted
@@EOF
mv ${ROOT}etc/apt/trusted.gpg.$$ ${ROOT}etc/apt/trusted.gpg

# get rid of the .debs - we don't need them.
chroot ${ROOT} apt-get clean
rm ${ROOT}var/lib/apt/lists/*_*

# Make the filesystem, with some room for meta data and such
USZ="400*1024"		# 400MB for the user
UINUM=""		# blank (default), or number of inodes desired.
SZ=$(python -c "print int($(du -sk $ROOT|sed 's/[^0-9].*$//')*1.1+$USZ)")
dd if=/dev/zero of=$IMG seek=$SZ bs=1024 count=1
if [-n "$UINUM" ]; then
    INUM="-N "$(python -c "print $(find ${ROOT} | wc -l)+$UINUM")
fi
mke2fs $INUM -Osparse_super -F $IMG
DEV=$(losetup -f);
losetup $DEV $IMG
mkdir -p livecd.mnt
MOUNTS="$MOUNTS $(pwd)/livecd.mnt"
mount $DEV livecd.mnt
rsync -a ${ROOT}/ livecd.mnt

rm -rf ${ROOT} &

create_compressed_fs $IMG 65536 > livecd.cloop
