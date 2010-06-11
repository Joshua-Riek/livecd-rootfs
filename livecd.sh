#!/bin/bash
set -eu

##########################################################################
####           (c) Copyright 2004-2007 Canonical Ltd.                #####
#                                                                        #
# This program is free software; you can redistribute it and/or modify   #
# it under the terms of the GNU General Public License as published by   #
# the Free Software Foundation; either version 2, or (at your option)    #
# any later version.                                                     #
#                                                                        #
# This program is distributed in the hope that it will be useful, but    #
# WITHOUT ANY WARRANTY; without even the implied warranty of             #
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU      #
# General Public License for more details.                               #
#                                                                        #
# You should have received a copy of the GNU General Public License with #
# your Ubuntu system, in /usr/share/common-licenses/GPL, or with the     #
# livecd-rootfs source package as the file COPYING.  If not, write to    #
# the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,   #
# Boston, MA 02110-1301 USA.                                             #
##########################################################################

# Depends: debootstrap, rsync, python-minimal|python, procps, squashfs-tools, ltsp-server [i386], genext2fs

cleanup() {
    for mnt in ${ROOT}dev/pts ${ROOT}dev/shm ${ROOT}.dev ${ROOT}dev \
	       ${ROOT}proc/sys/fs/binfmt_misc ${ROOT}proc ${ROOT}sys \
	       ${ROOT}lib/modules/*/volatile ${ROOT}var/{lock,run}; do
	umount $mnt || true
    done

    [ -n "$DEV" ] && losetup -d $DEV || true
    grep ${ROOT} /proc/mounts && return 1 || return 0
}

kill_users() {
    set +e
    PIDLIST="$(ls -l /proc/*/root 2>/dev/null | grep -- " -> ${ROOT%/}" | sed -n 's/^.*proc.\([0-9]*\).*$/\1/p')"
    while [ -n "${PIDLIST}" ]; do
	echo killing $PIDLIST
	ps -l $(for p in $PIDLIST; do echo ' '-p $p; done)
	kill -9 $PIDLIST
	sleep 2
	PIDLIST="$(ls -l /proc/*/root 2>/dev/null | grep -- " -> ${ROOT%/}" | sed -n 's/^.*proc.\([0-9]*\).*$/\1/p')"
    done
    set -e
}

without_package() {
    echo "$2" | tr ' ' '\n' | grep -v "^$1$" | tr '\n' ' '
}

subst_package() {
    echo "$3" | tr ' ' '\n' | sed "s/^$1$/$2/" | tr '\n' ' '
}


livefs_squash()
{
  squashsort="http://people.ubuntu.com/~tfheen/livesort/${FSS}.list.${TARGETARCH}"
  #if wget -O livecd.${FSS}.sort ${squashsort} > /dev/null 2>&1; then
  if false; then
    echo "Using the squashfs sort list from ${squashsort}."
  else
    echo "Unable to fetch squashfs sort list; using a blank list."
    : > livecd.${FSS}.sort
  fi

  # make sure there is no old squashfs idling around
  rm -f livecd.${FSS}.squashfs

  mksquashfs ${ROOT} livecd.${FSS}.squashfs -sort livecd.${FSS}.sort
  chmod 644 livecd.${FSS}.squashfs
}

livefs_ext2()
{
  # Add 10MiB extra free space for first boot + ext3 journal
  size=$(($(du -ks ${ROOT} | cut -f1) + (10240)))
  echo "Building ext2 filesystem."

  # remove any stale filesystem images
  rm -f livecd.${FSS}.ext?

  genext2fs -b $size -d ${ROOT} livecd.${FSS}.ext2
  chmod 644 livecd.${FSS}.ext2
}

if [ $(id -u) != 0 ];then
  echo "must be run as root"
  exit 2
fi

umask 022
export TTY=unknown
export TERM=vt100
export DEBIAN_FRONTEND=noninteractive
export LANG=C
export CASPER_GENERATE_UUID=1
SRCMIRROR=http://archive.ubuntu.com/ubuntu
PPAMIRROR=ppa.launchpad.net
ARCH=$(dpkg --print-architecture)
OPTMIRROR=
INITRD_COMPRESSOR=lzma
TMPFS=no

select_mirror () {
    case $ARCH in
	i386|amd64)
	    case $FS in
		ubuntu-lpia|ubuntu-mid)
		    USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
		    SECMIRROR=${USERMIRROR}
		    SECSRCMIRROR=${SRCMIRROR}
		    TARGETARCH=lpia
		    ;;
		*)
		    USERMIRROR=http://archive.ubuntu.com/ubuntu
		    SECMIRROR=http://security.ubuntu.com/ubuntu
		    SECSRCMIRROR=${SECMIRROR}
		    TARGETARCH=${ARCH}
		    ;;
	    esac
	    ;;
	*)
	    USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
	    SECMIRROR=${USERMIRROR}
	    SECSRCMIRROR=${SRCMIRROR}
	    TARGETARCH=${ARCH}
	    ;;
    esac
    case $(hostname --fqdn) in
	bld-*.mmjgroup.com)	MIRROR=${USERMIRROR};;
	*.mmjgroup.com)		MIRROR=http://archive.mmjgroup.com/${USERMIRROR##*/};;
	*.0c3.net)		MIRROR=http://ftp.iinet.net.au/linux/ubuntu;;
	*.ubuntu.com)		MIRROR=http://ftpmaster.internal/ubuntu;;
	*.warthogs.hbd.com)	MIRROR=http://ftpmaster.internal/ubuntu;;
	*.buildd)		MIRROR=http://ftpmaster.internal/ubuntu;;
	*)			MIRROR=${USERMIRROR};;
    esac

    if [ "$OPTMIRROR" ]; then
	MIRROR="$OPTMIRROR"
    fi
}

STE=$(lsb_release -cs)
EXCLUDE=""
LIST=""
SUBARCH=""
PROPOSED=""
IMAGEFORMAT="squashfs"
# must be in the "team / PPA name" form; e.g. "moblin/ppa"; the default PPA
# name is "ppa", don't omit it
PPA=""

while getopts :d:e:i:I:m:S:s:a:f:p name; do case $name in
    d)  STE=$OPTARG;;
    e)  EXCLUDE="$EXCLUDE $OPTARG";;
    i)  LIST="$LIST $OPTARG";;
    I)	UINUM="$OPTARG";;
    m)	OPTMIRROR="$OPTARG";;
    S)	USZ="$OPTARG";;
    s)	SUBARCH="$OPTARG";;
    a)	ARCH="$OPTARG";;
    f)	IMAGEFORMAT="$OPTARG";;
    p)  PROPOSED="yes";;
    \?) echo bad usage >&2; exit 2;;
    \:) echo missing argument >&2; exit 2;;
esac; done;
shift $((OPTIND-1))

if (( $# == 0 )) || [ "X$1" = "Xall" ]; then
    set -- ubuntu kubuntu kubuntu-netbook edubuntu xubuntu mythbuntu gobuntu base
    if [ "$ARCH" = "i386" ]; then
        set -- ubuntu ubuntu-dvd kubuntu kubuntu-dvd kubuntu-netbook edubuntu edubuntu-dvd mythbuntu xubuntu gobuntu base
    fi
fi

for arg in "$@"; do
    case "$arg" in
       ubuntu|ubuntu-dvd|ubuntu-lpia|edubuntu|edubuntu-dvd|kubuntu|kubuntu-dvd|kubuntu-netbook|xubuntu|mythbuntu|gobuntu|ubuntu-mid|ubuntu-netbook|ubuntu-moblin-remix|base|tocd)
	    ;;
	*)
	    echo bad name >&2;
	    exit 2
	    ;;
    esac
done

ROOT=$(pwd)/chroot-livecd/	# trailing / is CRITICAL
for FS in "$@"; do
    FSS="$FS${SUBARCH:+-$SUBARCH}"
    IMG=livecd.${FSS}.fsimg
    DEV=""
    COMP="main restricted"

    select_mirror

    # Just in case there's some leftover junk here:
    cleanup 2>/dev/null || true

    umount ${ROOT} || true
    rm -rf ${ROOT}
    mkdir ${ROOT}
    # maybe use a tmpfs
    if  test yes = "$TMPFS"; then
        mount -t tmpfs -o size=8192M tmpfs ${ROOT} && echo using tmpfs
    fi

    mkdir -p ${ROOT}var/cache/debconf
    cat << @@EOF > ${ROOT}var/cache/debconf/config.dat
Name: debconf/frontend
Template: debconf/frontend
Value: Noninteractive
Owners: debconf
Flags: seen

@@EOF

    case "$FS" in
	ubuntu|ubuntu-lpia|ubuntu-dvd)
	    LIST="$LIST minimal^ standard^ ubuntu-desktop^"
	    LIVELIST="ubuntu-live^ laptop-detect casper lupin-casper"
	    ;;
	kubuntu|kubuntu-dvd)
	    LIST="$LIST minimal^ standard^ kubuntu-desktop^"
	    LIVELIST="kubuntu-live^ laptop-detect casper lupin-casper"
	    ;;
	kubuntu-netbook)
	    LIST="$LIST minimal^ standard^ kubuntu-netbook^"
	    LIVELIST="language-support-en kubuntu-netbook-live^ laptop-detect casper lupin-casper"
	    ;;
	edubuntu|edubuntu-dvd)
	    LIST="$LIST minimal^ standard^ edubuntu-desktop-gnome^"
	    LIVELIST="edubuntu-live^ laptop-detect casper lupin-casper"
	    COMP="main restricted universe"
	    ;;
	xubuntu)
	    LIST="$LIST minimal^ standard^ xterm xubuntu-desktop^"
	    LIVELIST="xubuntu-live^ laptop-detect casper lupin-casper"
	    COMP="main restricted universe multiverse"
	    ;;
	gobuntu)
	    LIST="$LIST minimal^ standard^ gobuntu-desktop^"
	    LIVELIST="gobuntu-live^ laptop-detect casper lupin-casper"
	    COMP="main"
	    ;;
	ubuntu-mid)
	    LIST="$LIST minimal^ mobile-mid^"
	    LIVELIST="mobile-live^ casper ubiquity"
	    COMP="main restricted universe multiverse"
	    ;;
	ubuntu-netbook)
	    LIST="$LIST minimal^ standard^ ubuntu-netbook^"
	    LIVELIST="netbook-live^ laptop-detect casper lupin-casper"
	    ;;
	mythbuntu)
	    LIST="$LIST minimal^ standard^ mythbuntu-desktop^"
	    LIVELIST="mythbuntu-live^ laptop-detect casper lupin-casper"
	    COMP="main restricted universe multiverse"
	    ;;
	ubuntu-moblin-remix)
	    LIST="$LIST minimal^ ubuntu-moblin-remix"
	    LIVELIST="ubuntu-moblin-live"
	    COMP="main restricted universe"
	    PPA="moblin/ppa"
	    ;;
	base)
	    LIST="$LIST minimal^ standard^"
	    LIVELIST="casper lupin-casper"
	    ;;
	tocd)
	    LIST="$LIST minimal^ standard^"
	    tocdtmp=`mktemp -d` || exit 1
	    tocdgerminate='http://people.ubuntu.com/~cjwatson/germinate-output/tocd3.1-dapper/'
	    if wget -O "$tocdtmp"/desktop "$tocdgerminate"/desktop; then
	        tocddesktop=`awk '{print $1}' "$tocdtmp"/desktop | egrep -v '^-|^Package|^\|' | tr '\n' ' '`
	        echo "TheOpenCD desktop package list is: $tocddesktop"
	    else
	        echo "Unable to fetch tocd-desktop germinate output."
	        [ -d "$tocdtmp" ] && rm -rf "$tocdtmp"
		exit 1
	    fi
	    if wget -O "$tocdtmp"/live "$tocdgerminate"/live; then
	        tocdlive=`awk '{print $1}' "$tocdtmp"/live | egrep -v '^-|^Package|^\|' | tr '\n' ' '`
	        echo "TheOpenCD live package list is: $tocdlive"
	    else
	        echo "Unable to fetch tocd-live germinate output."
	        [ -d "$tocdtmp" ] && rm -rf "$tocdtmp"
		exit 1
	    fi
	    [ -d "$tocdtmp" ] && rm -rf "$tocdtmp"
	    LIST="$LIST $tocddesktop"
	    LIVELIST="$tocdlive casper"
    esac
    case "$FS" in
	*-dvd)
	    LIVELIST="$LIVELIST ${FS}-live^"
	    UNIVERSE=1
	    MULTIVERSE=1
	    ;;
	*)
	    UNIVERSE=
	    MULTIVERSE=
	    ;;
    esac

    dpkg -l livecd-rootfs || true	# get our version # in the log.
    debootstrap --components=$(echo $COMP | sed 's/ /,/g') --arch $TARGETARCH $STE $ROOT $MIRROR

    # Recent dpkg has started complaining pretty loudly if dev/pts isn't 
    # mounted, so let's get it mounted immediately after debootstrap:
    mount -t devpts devpts-${STE}-${FSS}-livefs ${ROOT}dev/pts

    # Just make a few things go away, which lets us skip a few other things.
    DIVERTS="usr/sbin/mkinitrd usr/sbin/invoke-rc.d"
    for file in $DIVERTS; do
	mkdir -p ${ROOT}${file%/*}
	chroot $ROOT dpkg-divert --add --local --divert /${file}.livecd --rename /${file}
	cp ${ROOT}/bin/true ${ROOT}$file
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

    case $TARGETARCH in
        alpha|amd64|i386|ia64|lpia|m68k|mips|mipsel)
            link_in_boot=no
            ;;
        *)
            link_in_boot=yes
            ;;
    esac

    # Make a good /etc/kernel-img.conf for the kernel packages
    cat << @@EOF >> ${ROOT}etc/kernel-img.conf
do_symlinks = yes
relative_links = yes
do_bootloader = no
do_bootfloppy = no
do_initrd = yes
link_in_boot = $link_in_boot
@@EOF

    mkdir -p ${ROOT}proc
    mount -tproc none ${ROOT}proc

    # this indicates whether or not to keep /boot/vmlinuz; the default is to
    # strip it from the livefs as ubiquity >= 1.9.4 copies the kernel from the
    # CD root (/casper/vmlinuz) to the target if it doesn't find one on the
    # livefs, allowing us to save space; however some subarches use the uImage
    # format in casper/ so we would end up with no vmlinuz file in /boot at the
    # end. Not stripping it in the first place from /boot saves us from that.
    STRIP_VMLINUZ=yes

    case $TARGETARCH+$SUBARCH in
	powerpc+ps3)
	    mkdir -p ${ROOT}spu;;
    esac

    case $TARGETARCH in
	amd64)		LIST="$LIST linux-generic";;
	i386)		LIST="$LIST linux-generic";;

	# and the bastard stepchildren
	lpia)		LIST="$LIST linux-lpia";;
	ia64)		LIST="$LIST linux-ia64";;
	hppa)		LIST="$LIST linux-hppa32 linux-hppa64";;
	powerpc)	LIST="$LIST linux-powerpc linux-powerpc64-smp";;
	sparc*)		LIST="$LIST linux-sparc64";;
	armel)
			case "$SUBARCH" in
				imx51)
					LIST="$LIST linux-imx51"
					;;
				dove)
					LIST="$LIST linux-dove"
					STRIP_VMLINUZ=no
					;;
				omap)
					LIST="$LIST linux-omap"
					STRIP_VMLINUZ=no
					;;
			esac;;
	*)		echo "Unknown architecture: no kernel."; exit 1;;
    esac

    for x in $EXCLUDE; do
	LIST="$(without_package "$x" "$LIST")"
    done

    if [ "$STE" = "hardy" ]; then
	# <hack, hack, hack> use the version of ssl-cert from the release
	# pocket, because the version in -updates pulls in the large
	# openssl-blacklist package which we should never need on the
	# live CD
	cat << @@EOF > ${ROOT}etc/apt/preferences
Package: ssl-cert
Pin: version 1.0.14-0ubuntu2
Pin-Priority: 900
@@EOF
    fi

    # Create a good sources.list, and finish the install
    echo deb $MIRROR $STE ${COMP} > ${ROOT}etc/apt/sources.list
    echo deb $MIRROR ${STE}-security ${COMP} >> ${ROOT}etc/apt/sources.list
    echo deb $MIRROR ${STE}-updates ${COMP} >> ${ROOT}etc/apt/sources.list
    if [ "$PROPOSED" = "yes" ]; then
        echo deb $MIRROR ${STE}-proposed ${COMP} >> ${ROOT}etc/apt/sources.list
    fi
    if [ -n "$PPA" ]; then
        echo deb http://$PPAMIRROR/$PPA/ubuntu ${STE} main >> ${ROOT}etc/apt/sources.list

        # handle PPAs named "ppa" specially; their Origin field in the Release
        # file does not end with "-ppa" for backwards compatibility
        origin="${PPA%/ppa}"
        origin="${origin/\//-}"
        touch ${ROOT}etc/apt/preferences
        cat << @@EOF >> ${ROOT}etc/apt/preferences
Package: *
Pin: release o=LP-PPA-$origin
Pin-Priority: 550
@@EOF
    fi

    if [ "$FS" = "ubuntu-moblin-remix" ]; then
	chroot $ROOT apt-get update
	chroot $ROOT apt-get -y --force-yes install ubuntu-moblin-ppa-keyring
	# promote Release.gpg from APT's lists/partial/ to lists/
	chroot $ROOT apt-get update
	# workaround LP #442082
	rm -f ${ROOT}var/cache/apt/{,src}pkgcache.bin
    fi

    # In addition to the ones we got from apt, trust whatever the local system
    # believes in, but put things back afterwards.
    cp ${ROOT}etc/apt/trusted.gpg ${ROOT}etc/apt/trusted.gpg.$$
    cat /etc/apt/trusted.gpg >> ${ROOT}etc/apt/trusted.gpg

    chroot $ROOT apt-get update
    chroot $ROOT apt-get -y --purge dist-upgrade </dev/null
    chroot $ROOT apt-get -y --purge install $LIST </dev/null

    # launchpad likes to put dependencies of seeded packages in tasks along with the
    # actual seeded packages.  In general, this isn't an issue.  With updated kernels
    # and point-releases, though, we end up with extra header packages:
    chroot ${ROOT} dpkg -l linux-headers-2\* | grep ^i | awk '{print $2}' \
        > livecd.${FSS}.manifest-headers
    chroot ${ROOT} dpkg -l linux-headers-\* | grep ^i | awk '{print $2}' \
        > livecd.${FSS}.manifest-headers-full
    HEADERPACKAGES=`cat livecd.${FSS}.manifest-headers-full`
    HEADERMETA=""
    for i in `comm -3 livecd.${FSS}.manifest-headers livecd.${FSS}.manifest-headers-full`; do
        HEADERMETA="$HEADERMETA $i"
    done
    rm -f livecd.${FSS}.manifest-headers livecd.${FSS}.manifest-headers-full
    chroot ${ROOT} apt-get -y --purge remove $HEADERPACKAGES </dev/null || true
    chroot ${ROOT} apt-get -y --purge install $HEADERMETA </dev/null || true
    # End horrible linux-header launchpad workaround.  Hopefully this is temporary.

    chroot ${ROOT} dpkg-query -W --showformat='${Package} ${Version}\n' \
	> livecd.${FSS}.manifest-desktop
    chroot $ROOT apt-get -y --purge install $LIVELIST </dev/null
    case $FS in
	edubuntu)
	    chroot $ROOT apt-cache dumpavail | \
		grep-dctrl -nsPackage -FTask edubuntu-ship-addon -a \
				      -FTask edubuntu-live | \
		sort -u | \
		xargs chroot $ROOT \
		    dpkg-query -W --showformat='${Package} ${Version}\n' \
		>> livecd.${FSS}.manifest-desktop
	    ;;
    esac
    chroot ${ROOT} dpkg-query -W --showformat='${Package} ${Version}\n' \
	> livecd.${FSS}.manifest
    kill_users

    chroot $ROOT /etc/cron.daily/mlocate || true
    chroot $ROOT /etc/cron.daily/man-db	|| true

    # remove our diversions
    for file in $DIVERTS; do
	ls -ld ${ROOT}${file} ${ROOT}${file}.livecd || true
	rm -f ${ROOT}${file}
	chroot $ROOT dpkg-divert --remove --rename /${file}
    done

    # remove the apt preferences hack if it was added
    rm -f ${ROOT}etc/apt/preferences

    # And make this look more pristine
    cat << @@EOF > ${ROOT}etc/apt/sources.list
deb ${USERMIRROR} $STE ${COMP}
deb-src ${SRCMIRROR} $STE ${COMP}

deb ${SECMIRROR} ${STE}-security ${COMP}
deb-src ${SECSRCMIRROR} ${STE}-security ${COMP}

## Major bug fix updates produced after the final release of the
## distribution.
deb ${USERMIRROR} ${STE}-updates ${COMP}
deb-src ${SRCMIRROR} ${STE}-updates ${COMP}

@@EOF
    if [ "$UNIVERSE" ]; then
	COMMENT=
    else
	cat << @@EOF >> ${ROOT}etc/apt/sources.list
## Uncomment the following two lines to add software from the 'universe'
## repository.
@@EOF
	COMMENT='# '
    fi
    cat << @@EOF >> ${ROOT}etc/apt/sources.list
## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team. Also, please note that software in universe WILL NOT receive any
## review or updates from the Ubuntu security team.
${COMMENT}deb ${USERMIRROR} $STE universe
${COMMENT}deb-src ${SRCMIRROR} $STE universe
${COMMENT}deb ${USERMIRROR} ${STE}-updates universe
${COMMENT}deb-src ${SRCMIRROR} ${STE}-updates universe
${COMMENT}deb ${SECMIRROR} ${STE}-security universe
${COMMENT}deb-src ${SECSRCMIRROR} ${STE}-security universe

@@EOF
    if [ "$MULTIVERSE" ]; then
	COMMENT=
    else
	COMMENT='# '
    fi
    cat << @@EOF >> ${ROOT}etc/apt/sources.list
## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team, and may not be under a free licence. Please satisfy yourself as to
## your rights to use the software. Also, please note that software in
## multiverse WILL NOT receive any review or updates from the Ubuntu
## security team.
${COMMENT}deb ${USERMIRROR} $STE multiverse
${COMMENT}deb-src ${SRCMIRROR} $STE multiverse
${COMMENT}deb ${USERMIRROR} ${STE}-updates multiverse
${COMMENT}deb-src ${SRCMIRROR} ${STE}-updates multiverse
${COMMENT}deb ${SECMIRROR} ${STE}-security multiverse
${COMMENT}deb-src ${SECSRCMIRROR} ${STE}-security multiverse
@@EOF
    if [ -n "$PPA" ]; then
    cat << @@EOF >> ${ROOT}etc/apt/sources.list

## The following unsupported and untrusted Personal Archives (PPAs) were used
## to create the base image of this system
deb http://$PPAMIRROR/$PPA/ubuntu ${STE} main
deb-src http://$PPAMIRROR/$PPA/ubuntu ${STE} main
@@EOF

        # handle PPAs named "ppa" specially; their Origin field in the Release
        # file does not end with "-ppa" for backwards compatibility
        origin="${PPA%/ppa}"
        origin="${origin/\//-}"
        touch ${ROOT}etc/apt/preferences
        cat << @@EOF >> ${ROOT}etc/apt/preferences
Explanation: This prefers the Personal Archive $PPA over the other sources
Package: *
Pin: release o=LP-PPA-$origin
Pin-Priority: 550
@@EOF
    fi
    mv ${ROOT}etc/apt/trusted.gpg.$$ ${ROOT}etc/apt/trusted.gpg

    # get rid of the .debs - we don't need them.
    chroot ${ROOT} apt-get clean
    rm -f ${ROOT}var/lib/apt/lists/*_*
    rm -f ${ROOT}var/spool/postfix/maildrop/*
    # Removing update-notifier notes is now considered harmful:
    #rm -f ${ROOT}var/lib/update-notifier/user.d/*
    # The D-Bus machine identifier needs to be unique, and is generated at
    # boot time if it's missing.
    rm -f ${ROOT}var/lib/dbus/machine-id
    chroot $ROOT apt-get update || true	# give them fresh lists, but don't fail
    rm -f ${ROOT}etc/resolv.conf ${ROOT}etc/mailname
    if [ -f ${ROOT}/etc/postfix/main.cf ]; then
	sed -i '/^myhostname/d; /^mydestination/d; /^myorigin/d' ${ROOT}etc/postfix/main.cf
	echo set postfix/destinations | chroot ${ROOT} /usr/bin/debconf-communicate postfix
	echo set postfix/mailname | chroot ${ROOT} /usr/bin/debconf-communicate postfix
    fi
    KVERS=`chroot ${ROOT} dpkg -l linux-image-2\*|grep ^i|awk '{print $2}'|sed 's/linux-image-//'`
    for KVER in ${KVERS}; do
	SUBARCH="${KVER#*-*-}"
	chroot ${ROOT} update-initramfs -k "${KVER}" -u
	# we mv the initramfs, so it's not wasting space on the livefs
	mv ${ROOT}/boot/initrd.img-"${KVER}" livecd.${FSS}.initrd-"${SUBARCH}"
	rm -f ${ROOT}/boot/initrd.img-"${KVER}".bak
	# whether to strip vmlinuz or not to save space thanks to ubiquity
	action="cp"
	if [ "$STRIP_VMLINUZ" = "yes" ]; then
	    action="mv"
	fi
	$action ${ROOT}/boot/vmlinu?-"${KVER}" livecd.${FSS}.kernel-"${SUBARCH}"
	if [ "$INITRD_COMPRESSOR" != gz ]; then
	    zcat "livecd.${FSS}.initrd-${SUBARCH}" | "$INITRD_COMPRESSOR" -9c \
		> "livecd.${FSS}.initrd-${SUBARCH}.new"
	    mv "livecd.${FSS}.initrd-${SUBARCH}.new" \
		"livecd.${FSS}.initrd-${SUBARCH}"
	fi
    done
    NUMKVERS="$(set -- $KVERS; echo $#)"
    if [ "$NUMKVERS" = 1 ]; then
	# only one kernel
	SUBARCH="${KVERS#*-*-}"
	ln -sf livecd.${FSS}.initrd-"${SUBARCH}" livecd.${FSS}.initrd
	ln -sf livecd.${FSS}.kernel-"${SUBARCH}" livecd.${FSS}.kernel
    fi
    case $TARGETARCH+$SUBARCH in
	powerpc+ps3)
	    chroot ${ROOT} addgroup --system spu;;
    esac

    # No point keeping Gnome icon cache around for Kubuntu
    if [ "$FS" = "kubuntu" ] || [ "$FS" = "kubuntu-netbook" ]; then
        rm -f ${ROOT}/usr/share/icons/*/icon-theme.cache
    fi

    # all done with the chroot; reset the debconf frontend, so Colin doesn't cry
    echo RESET debconf/frontend | chroot $ROOT debconf-communicate
    echo FSET debconf/frontend seen true | chroot $ROOT debconf-communicate

    # And now that we're done messing with debconf, destroy the backup files:
    rm -f ${ROOT}/var/cache/debconf/*-old

    # show the size of directories in /usr/share/doc
    echo BEGIN docdirs
    (cd $ROOT && find usr/share/doc -maxdepth 1 -type d | xargs du -s | sort -nr)
    echo END docdirs

    # search for duplicate files, write the summary to stdout, 
    if which fdupes >/dev/null 2>&1; then
	echo "first line: <total size for dupes> <different dupes> <all dupes>"
	echo "data lines: <size for dupes> <number of dupes> <file size> <filename> [<filename> ...]"
	echo BEGIN fdupes
	(cd $ROOT \
	   && fdupes --recurse --noempty --sameline --size --quiet usr \
	   | awk '/bytes each/ {s=$1} /^usr/ { n+=1; n2+=NF-1; sum+=s*(NF-1); print s*(NF-1), NF-1, s, $0 } END {print sum, n, n2}' \
	   | sort -nr
	)
	echo END fdupes
    fi

    # Dirty hack to mark langpack stuff as manually installed
    perl -i -nle 'print unless /^Package: language-(pack|support)/ .. /^$/;' \
        ${ROOT}/var/lib/apt/extended_states

    # And run the cleanup function dead last, to umount /proc after nothing
    # else needs to be run in the chroot (umounting it earlier breaks rm):
    cleanup

    # Squashfs does not report unpacked disk space usage, which is explained at
    # <http://lkml.org/lkml/2006/6/16/163>.  However, we would like to cache this
    # number for partman's sufficient free space check and ubiquity's
    # installation progress calculation.
    printf $(du -sx --block-size=1 ${ROOT} | cut -f1) > livecd.${FSS}.size || true


    # Build our images
    if [ "$IMAGEFORMAT" = "ext2" ] || [ "$IMAGEFORMAT" = "ext3" ]; then
        livefs_ext2
    else
        livefs_squash
    fi

    # Upgrade ext2->ext3 if that's what is requested
    if [ "$IMAGEFORMAT" = "ext3" ]; then
        tune2fs -j livecd.${FSS}.ext2
        mv livecd.${FSS}.ext2 livecd.${FSS}.ext3
        # temporary workaround for LP: #583317 with ext3 images
        e2fsck -fy livecd.${FSS}.ext3 > /dev/null 2>&1
    fi

    # LTSP chroot building (only in 32bit and for Edubuntu (DVD))
    case $FS in
        edubuntu-dvd)
            if [ "$TARGETARCH" = "i386" ]; then
                ltsp-build-client --base $(pwd) --mirror $MIRROR --arch $TARGETARCH --dist $STE --chroot ltsp-live --purge-chroot --skipimage
                mkdir -p $(pwd)/images
                mksquashfs $(pwd)/ltsp-live $(pwd)/images/ltsp-live.img -noF -noD -noI -no-exports -e cdrom
                rm -Rf $(pwd)/ltsp-live
                if [ -f $(pwd)/images/ltsp-live.img ]; then
                    mv $(pwd)/images/ltsp-live.img livecd.$FS-ltsp.squashfs
                    chmod 0644 livecd.$FS-ltsp.squashfs
                    rmdir --ignore-fail-on-non-empty $(pwd)/images/
                else
                    echo "LTSP: Unable to build the chroot, see above for details."
                fi
            fi
        ;;
    esac
done
