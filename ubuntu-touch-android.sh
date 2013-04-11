!#/bin/bash

set -e

codename=$1
builddir=$codename-build

[ "$(dpkg --print-architecture)" = "amd64" ] || exit 1

# set up multiarch
dpkg --print-foreign-architectures | grep -q i386 || dpkg --add-architecture i386
apt-get update

# add cross build env including the needed i386 packages
apt-get -y install git gnupg flex bison gperf build-essential \
    zip bzr curl libc6-dev libncurses5-dev:i386 x11proto-core-dev \
    libx11-dev:i386 libreadline6-dev:i386 libgl1-mesa-glx:i386 \
    libgl1-mesa-dev g++-multilib mingw32 tofrodos phablet-tools \
    python-markdown libxml2-utils xsltproc zlib1g-dev:i386 schedtool \
	openjdk-6-jdk

# get the git tree
phablet-dev-bootstrap -v $codename $builddir

cd $builddir
repo sync

. build/envsetup.sh
brunch $codename

cd -
cp $builddir/out/target/product/$codename/*-$codename.zip ./livecd.ubuntu-touch-$codename.zip
for image in system recovery boot; do
	cp $builddir/out/target/product/$codename/$image.img ./livecd.ubuntu-touch-$codename.$image.img
done
rm -rf $buildir
