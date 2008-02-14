#!/bin/bash -eu

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

# Depends: debootstrap, rsync, python-minimal|python, procps, squashfs-tools

cleanup() {
    for mnt in $MOUNTS ${ROOT}lib/modules/*/volatile ${ROOT}var/{lock,run}; do
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
ARCH=$(dpkg --print-installation-architecture)
OPTMIRROR=

select_mirror () {
    case $ARCH in
	i386|amd64|sparc)
	    case $FS in
		ubuntu-lpia)
		    USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
		    SECMIRROR=${USERMIRROR}
		    SECSRCMIRROR=${SRCMIRROR}
		    ;;
		*)
		    USERMIRROR=http://archive.ubuntu.com/ubuntu
		    SECMIRROR=http://security.ubuntu.com/ubuntu
		    SECSRCMIRROR=${SECMIRROR}
		    ;;
	    esac
	    ;;
	hppa)
	    USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
	    SECMIRROR=${USERMIRROR}
	    SECSRCMIRROR=${SRCMIRROR}
	    ;;
	*)
	    USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
	    SECMIRROR=${USERMIRROR}
	    SECSRCMIRROR=${SRCMIRROR}
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

STE=gutsy
EXCLUDE=""
LIST=""
SUBARCH=""

while getopts :d:e:i:I:m:S:s: name; do case $name in
    d)  STE=$OPTARG;;
    e)  EXCLUDE="$EXCLUDE $OPTARG";;
    i)  LIST="$LIST $OPTARG";;
    I)	UINUM="$OPTARG";;
    m)	OPTMIRROR="$OPTARG";;
    S)	USZ="$OPTARG";;
    s)	SUBARCH="$OPTARG";;
    \?) echo bad usage >&2; exit 2;;
    \:) echo missing argument >&2; exit 2;;
esac; done;
shift $((OPTIND-1))

if (( $# == 0 )) || [ "X$1" = "Xall" ]; then
    set -- ubuntu kubuntu kubuntu-kde4 edubuntu xubuntu gobuntu base
    if [ "$ARCH" = "i386" ]; then
        set -- ubuntu ubuntu-dvd ubuntu-lpia kubuntu kubuntu-dvd kubuntu-kde4 edubuntu edubuntu-dvd xubuntu gobuntu base
    fi
fi

for arg in "$@"; do
    case "$arg" in
	ubuntu|ubuntu-dvd|ubuntu-lpia|edubuntu|edubuntu-dvd|kubuntu|kubuntu-dvd|kubuntu-kde4|xubuntu|gobuntu|base|tocd)
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
    MOUNTS="${ROOT}dev/pts ${ROOT}dev/shm ${ROOT}.dev ${ROOT}dev ${ROOT}proc ${ROOT}sys"
    DEV=""
    COMP="main restricted"

    select_mirror

    rm -rf ${ROOT}

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
	    LIVELIST="ubuntu-live^ xresprobe laptop-detect casper lupin-casper"
	    ;;
	kubuntu|kubuntu-dvd)
	    LIST="$LIST minimal^ standard^ kubuntu-desktop^"
	    LIVELIST="kubuntu-live^ xresprobe laptop-detect casper lupin-casper"
	    ;;
	kubuntu-kde4)
	    LIST="$LIST minimal^ standard^ kubuntu-kde4-desktop^"
	    LIVELIST="kubuntu-kde4-live^ xresprobe laptop-detect casper lupin-casper"
	    ;;
	edubuntu|edubuntu-dvd)
	    LIST="$LIST minimal^ standard^ edubuntu-desktop^"
	    LIVELIST="edubuntu-live^ xresprobe laptop-detect casper lupin-casper"
	    ;;
	xubuntu)
	    LIST="$LIST minimal^ standard^ xterm libgoffice-gtk-0-6 xubuntu-desktop^"
	    LIVELIST="xubuntu-live^ xresprobe laptop-detect casper lupin-casper"
	    COMP="main restricted universe multiverse"
	    ;;
	gobuntu)
	    LIST="$LIST minimal^ standard^ gobuntu-desktop^"
	    LIVELIST="gobuntu-live^ xresprobe laptop-detect casper lupin-casper"
	    COMP="main"
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
	    ;;
    esac

    dpkg -l livecd-rootfs || true	# get our version # in the log.
    if [ "$FS" != "ubuntu-lpia" ]; then
        debootstrap --components=$(echo $COMP | sed 's/ /,/g') $STE $ROOT $MIRROR
    else
        debootstrap --components=$(echo $COMP | sed 's/ /,/g') --arch lpia $STE $ROOT $MIRROR
    fi

    # Just make a few things go away, which lets us skip a few other things.
    DIVERTS="usr/sbin/mkinitrd usr/sbin/invoke-rc.d"
    for file in $DIVERTS; do
	mkdir -p ${ROOT}${file%/*}
	chroot $ROOT dpkg-divert --add --local --divert /${file}.livecd --rename /${file}
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

    case $ARCH in
        alpha|amd64|i386|ia64|m68k|mips|mipsel)
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

    case $ARCH+$SUBARCH in
	powerpc+ps3)
	    mkdir -p ${ROOT}spu;;
    esac

    # In addition to the ones we got from apt, trust whatever the local system
    # believes in, but put things back afterwards.
    cp ${ROOT}etc/apt/trusted.gpg ${ROOT}etc/apt/trusted.gpg.$$
    cat /etc/apt/trusted.gpg >> ${ROOT}etc/apt/trusted.gpg

    case $ARCH in
	amd64)		LIST="$LIST linux-generic";;
	i386)
	    case $FS in
		ubuntu-lpia) LIST="$LIST linux-lpia";;
		*)	LIST="$LIST linux-generic";;
	    esac;;
	powerpc)
	    case $SUBARCH in
		ps3)	LIST="$LIST linux-cell";;
		*)	LIST="$LIST linux-powerpc linux-powerpc64-smp";;
	    esac;;

	# and the bastard stepchildren
	ia64)		LIST="$LIST linux-itanium linux-mckinley";;
	hppa)		LIST="$LIST linux-hppa32 linux-hppa64";;
	sparc*)		LIST="$LIST linux-sparc64";;
	*)		echo "Unknown architecture: no kernel."; exit 1;;
    esac

    for x in $EXCLUDE; do
	LIST="$(without_package "$x" "$LIST")"
    done

    # Create a good sources.list, and finish the install
    echo deb $MIRROR $STE ${COMP} > ${ROOT}etc/apt/sources.list
    chroot $ROOT apt-get update
    chroot $ROOT apt-get -y install $LIST </dev/null
    chroot ${ROOT} dpkg-query -W --showformat='${Package} ${Version}\n' \
	> livecd.${FSS}.manifest-desktop
    chroot $ROOT apt-get -y install $LIVELIST </dev/null
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

    chroot $ROOT /etc/cron.daily/slocate || true
    chroot $ROOT /etc/cron.daily/man-db	|| true

    # remove our diversions
    for file in $DIVERTS; do
	ls -ld ${ROOT}${file} ${ROOT}${file}.livecd || true
	rm -f ${ROOT}${file}
	chroot $ROOT dpkg-divert --remove --rename /${file}
    done

    # And make this look more pristine
    cleanup
    cat << @@EOF > ${ROOT}etc/apt/sources.list
deb ${USERMIRROR} $STE ${COMP}
deb-src ${SRCMIRROR} $STE ${COMP}

## Uncomment the following two lines to add software from the 'universe'
## repository.
## N.B. software from this repository is ENTIRELY UNSUPPORTED by the Ubuntu
## team, and may not be under a free licence. Please satisfy yourself as to
## your rights to use the software. Also, please note that software in
## universe WILL NOT receive any review or updates from the Ubuntu security
## team.
# deb ${USERMIRROR} $STE universe
# deb-src ${SRCMIRROR} $STE universe

deb ${SECMIRROR} ${STE}-security ${COMP}
deb-src ${SECSRCMIRROR} ${STE}-security ${COMP}
@@EOF
    mv ${ROOT}etc/apt/trusted.gpg.$$ ${ROOT}etc/apt/trusted.gpg

    # get rid of the .debs - we don't need them.
    chroot ${ROOT} apt-get clean
    rm -f ${ROOT}etc/X11/xorg.conf
    # Restore an empty xorg.conf, else xserver-xorg postinst will be confused
    touch ${ROOT}etc/X11/xorg.conf
    rm -f ${ROOT}var/lib/apt/lists/*_*
    rm -f ${ROOT}var/spool/postfix/maildrop/*
    # Removing update-notifier notes is now considered harmful:
    #rm -f ${ROOT}var/lib/update-notifier/user.d/*
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
	cp ${ROOT}/boot/vmlinu?-"${KVER}" livecd.${FSS}.kernel-"${SUBARCH}"
    done
    NUMKVERS="$(set -- $KVERS; echo $#)"
    if [ "$NUMKVERS" = 1 ]; then
	# only one kernel
	SUBARCH="${KVERS#*-*-}"
	ln -s livecd.${FSS}.initrd-"${SUBARCH}" livecd.${FSS}.initrd
	ln -s livecd.${FSS}.kernel-"${SUBARCH}" livecd.${FSS}.kernel
    fi
    case $ARCH+$SUBARCH in
	powerpc+ps3)
	    chroot ${ROOT} addgroup --system spu;;
    esac
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

  livefs_squash()
  {
    squashsort="http://people.ubuntu.com/~tfheen/livesort/${FSS}.list.${ARCH}"
    if wget -O livecd.${FSS}.sort ${squashsort} > /dev/null 2>&1; then
      echo "Using the squashfs sort list from ${squashsort}."
    else
      echo "Unable to fetch squashfs sort list; using a blank list."
      : > livecd.${FSS}.sort
    fi

    mksquashfs ${ROOT} livecd.${FSS}.squashfs -nolzma -sort livecd.${FSS}.sort
    chmod 644 livecd.${FSS}.squashfs
  }

  livefs_squash

done
