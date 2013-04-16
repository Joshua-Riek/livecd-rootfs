#!/bin/sh

set -e

codename=$1
builddir=$codename-build
release=raring

[ "$(dpkg --print-architecture)" = "amd64" ] || exit 1

# set up a build chroot
case $(hostname --fqdn) in
	*.buildd)
		MIRROR=http://ftpmaster.internal/ubuntu
		;;
	*)
		MIRROR=http://archive.ubuntu.com/ubuntu
		;;
esac
debootstrap --components=main,universe $release $builddir $MIRROR

mount -t devpts devpts-$builddir $builddir/dev/pts
chroot mount -t proc proc-$builddir /proc
chroot mount -t sysfs sys-$builddir /sys

# set up multiarch inside the chroot
chroot $builddir dpkg --add-architecture i386
chroot $builddir apt-get update

# add cross build env including the needed i386 packages
chroot $builddir apt-get -y install git gnupg flex bison gperf build-essential \
    zip bzr curl libc6-dev libncurses5-dev:i386 x11proto-core-dev \
    libx11-dev:i386 libreadline6-dev:i386 libgl1-mesa-glx:i386 \
    libgl1-mesa-dev g++-multilib mingw32 tofrodos phablet-tools \
    python-markdown libxml2-utils xsltproc zlib1g-dev:i386 schedtool \
	openjdk-6-jdk

# create an in chroot script to get the git tree and build it
cat << 'EOF' > $builddir/build-android.sh
#!/bin/bash

phablet-dev-bootstrap -v $codename $builddir
cd $builddir
repo sync
. build/envsetup.sh
brunch $codename
EOF

chmod +x $builddir/build-android.sh

chroot $builddir /build-android.sh

cp $builddir/$builddir/out/target/product/$codename/*-$codename.zip ./livecd.ubuntu-touch-$codename.zip
for image in system recovery boot; do
	cp $builddir/$builddir/out/target/product/$codename/$image.img ./livecd.ubuntu-touch-$codename.$image.img
done

umount $builddir/sys
umount $builddir/proc
umount $builddir/dev/pts

rm -rf $builddir
