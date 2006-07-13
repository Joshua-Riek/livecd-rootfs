#!/bin/bash -eu

######################################################################
#### (c) Copyright 2004,2005 Canonical Ltd.  All rights reserved. ####
######################################################################

# Depends: debootstrap, rsync, cloop-utils, python-minimal|python, procps, squashfs-tools

SQUASH_ARCHES="i386 amd64 powerpc"
CLOOP_ARCHES="ia64 sparc hppa"

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
SRCMIRROR=http://archive.ubuntu.com/ubuntu
COMP="main restricted"
ARCH=$(dpkg --print-installation-architecture)
case $ARCH in
    i386|powerpc|amd64|sparc)
	USERMIRROR=http://archive.ubuntu.com/ubuntu
	SECMIRROR=http://security.ubuntu.com/ubuntu
	SECSRCMIRROR=${SECMIRROR}
	;;
    hppa)
    	USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
    	SECMIRROR=${USERMIRROR}
	SECSRCMIRROR=${SRCMIRROR}
	#COMP="main restricted universe"
	;;
    *)
    	USERMIRROR=http://ports.ubuntu.com/ubuntu-ports
    	SECMIRROR=${USERMIRROR}
	SECSRCMIRROR=${SRCMIRROR}
	;;
esac
case $(hostname --fqdn) in
    bld-*.mmjgroup.com)	MIRROR=${USERMIRROR};;
    *.mmjgroup.com)	MIRROR=http://archive.mmjgroup.com/${USERMIRROR##*/};;
    *.ubuntu.com)	MIRROR=http://ftpmaster.internal/ubuntu;;
    *.warthogs.hbd.com)	MIRROR=http://ftpmaster.internal/ubuntu;;
    *.buildd)		MIRROR=http://ftpmaster.internal/ubuntu;;
    *)			MIRROR=${USERMIRROR};;
esac

# How much space do we leave on the filesystem for the user?
USZ="400*1024"		# 400MB for the user
# And how many inodes?  Default currently gives them > 100000
UINUM=""		# blank (default), or number of inodes desired.
STE=edgy
EXCLUDE=""
LIST=""

while getopts :d:e:i:I:mS:: name; do case $name in
    d)  STE=$OPTARG;;
    e)  EXCLUDE="$EXCLUDE $OPTARG";;
    i)  LIST="$LIST $OPTARG";;
    I)	UINUM=$(sanitize int "$OPTARG");;
    m)	MIRROR=$(sanitize url "$OPTARG");;
    S)	USZ=$(sanitize int "$OPTARG");;
    \?) echo bad usage >&2; exit 2;;
    \:) echo missing argument >&2; exit 2;;
esac; done;
shift $((OPTIND-1))

if (( $# == 0 )) || [ "X$1" = "Xall" ]; then
    set -- ubuntu kubuntu edubuntu xubuntu base
fi

for arg in "$@"; do
    case "$arg" in
	ubuntu|edubuntu|kubuntu|xubuntu|base|tocd)
	    ;;
	*)
	    echo bad name >&2;
	    exit 2
	    ;;
    esac
done

ROOT=$(pwd)/chroot-livecd/	# trailing / is CRITICAL
for FS in "$@"; do
    IMG=livecd.${FS}.fsimg
    MOUNTS="${ROOT}dev/pts ${ROOT}dev/shm ${ROOT}.dev ${ROOT}dev ${ROOT}proc"
    DEV=""

    rm -rf ${ROOT}

    export DEBIAN_FRONTEND=noninteractive	# HACK for update-inetd
    mkdir -p ${ROOT}var/cache/debconf
    cat << @@EOF > ${ROOT}var/cache/debconf/config.dat
Name: debconf/frontend
Template: debconf/frontend
Value: Noninteractive
Owners: debconf
Flags: seen

@@EOF

    case "$FS" in
	ubuntu)
	    LIST="$LIST ubuntu-base ubuntu-desktop"
	    LIVELIST="ubuntu-live xresprobe laptop-detect casper"
	    ;;
	kubuntu)
	    LIST="$LIST ubuntu-base kubuntu-desktop"
	    LIVELIST="kubuntu-live xresprobe laptop-detect casper"
	    ;;
	edubuntu)
	    LIST="$LIST ubuntu-base edubuntu-desktop"
	    LIVELIST="edubuntu-live xresprobe laptop-detect casper"
	    ;;
	xubuntu)
	    LIST="$LIST ubuntu-base xterm libgoffice-gtk-1-2 xubuntu-desktop"
	    LIVELIST="xubuntu-live xresprobe laptop-detect casper"
	    ;;
	base)
	    LIST="$LIST ubuntu-base"
	    LIVELIST="casper"
	    ;;
	tocd)
	    LIST="$LIST ubuntu-base"
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

    dpkg -l livecd-rootfs	# get our version # in the log.
    debootstrap --components=$(echo $COMP | sed 's/ /,/g') $STE $ROOT $MIRROR

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

    case $ARCH in
	amd64)		LIST="$LIST linux-amd64-generic";;
	i386)		LIST="$LIST linux-686";;
	powerpc)	LIST="$LIST linux-powerpc linux-powerpc64-smp";;

	# and the bastard stepchildren
	ia64)		LIST="$LIST linux-itanium-smp linux-mckinley-smp";;
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
	> livecd.${FS}.manifest-desktop
    chroot $ROOT apt-get -y install $LIVELIST </dev/null
    chroot ${ROOT} dpkg-query -W --showformat='${Package} ${Version}\n' \
	> livecd.${FS}.manifest
    kill_users

    chroot $ROOT /etc/cron.daily/slocate || true
    chroot $ROOT /etc/cron.daily/man-db	|| true

    # remove our diversions
    for file in $DIVERTS; do
	ls -ld ${ROOT}${file} ${ROOT}${file}.livecd || true
	rm -f ${ROOT}${file}
	chroot $ROOT dpkg-divert --remove --rename /${file}
    done

    # And make this look more pristene
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
    rm -f ${ROOT}var/lib/apt/lists/*_*
    rm -f ${ROOT}var/spool/postfix/maildrop/*
    rm -f ${ROOT}var/lib/update-notifier/user.d/*
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
	cp ${ROOT}/boot/initrd.img-"${KVER}" livecd.${FS}.initrd-"${SUBARCH}"
	cp ${ROOT}/boot/vmlinu?-"${KVER}" livecd.${FS}.kernel-"${SUBARCH}"
    done
    NUMKVERS="$(set -- $KVERS; echo $#)"
    if [ "$NUMKVERS" = 1 ]; then
	# only one kernel
	SUBARCH="${KVERS#*-*-}"
	ln -s livecd.${FS}.initrd-"${SUBARCH}" livecd.${FS}.initrd
	ln -s livecd.${FS}.kernel-"${SUBARCH}" livecd.${FS}.kernel
    fi
    # all done with the chroot; reset the deconf frontend, so Colin doesn't cry
    echo RESET debconf/frontend | chroot $ROOT debconf-communicate
    echo FSET debconf/frontend seen true | chroot $ROOT debconf-communicate

  livefs_cloop()
  {
    mkdir -p livecd.mnt
    MOUNTS="$MOUNTS $(pwd)/livecd.mnt"
    DEV=$(losetup -f);

    # Make the filesystem, with some room for meta data and such
    SZ=$(python -c "print int(($(du -sk $ROOT|sed 's/[^0-9].*$//')*1.1+$USZ)/1024)")
    (( SZ > 2047 )) && SZ=2047
    SZ=2047				# XXX fix size for now
    if [ "$FS" = "kubuntu" ]; then
      SZ=2559
    fi

    for fsbs in 1024:65536; do 
      FSBLOCK=${fsbs%:*}
      COMP=${fsbs#*:}
      IMGNAME=${IMG}-${FSBLOCK}
      if [ ! -f ${IMGNAME} ]; then
	if [ -f old-${IMGNAME} ]; then
	  cp old-${IMGNAME} new-${IMGNAME}
	else
	  dd if=/dev/zero of=new-${IMGNAME} count=$SZ bs=1M
	  INUM=""
	  [ -n "$UINUM" ] && INUM="-N "$(python -c "print $(find ${ROOT}|wc -l)+$UINUM") || INUM=""
	  mke2fs -b $FSBLOCK $INUM -Osparse_super -F new-${IMGNAME}
	fi
	losetup $DEV new-${IMGNAME}
	mount $DEV livecd.mnt
	rsync -a --delete --inplace --no-whole-file ${ROOT} livecd.mnt
	umount $DEV
	rm -rf partimg-${IMGNAME}.*
	#if [ -x /usr/sbin/partimage ]; then
	#  partimage -b -z0 --nodesc -f3 -c -o -y save $DEV partimg-${IMGNAME}
	#  cat partimg-${IMGNAME}.*|partimage -b -z0 --nodesc -e -f3 -c -o -y restore $DEV stdin
	#else
	  /usr/sbin/e2fs-zero.py -w new-${IMGNAME}
	#fi
	losetup -d $DEV
	mv new-${IMGNAME} ${IMGNAME}
	cp ${IMGNAME} old-${IMGNAME}
      fi
      create_compressed_fs $IMGNAME $COMP > livecd.${FS}.cloop-${fsbs}
    done
  }

  livefs_squash()
  {
    mksquashfs ${ROOT} livecd.${FS}.squashfs
    chmod 644 livecd.${FS}.squashfs
  }

  for i in $SQUASH_ARCHES; do
    if [ "$ARCH" = "$i" ]; then livefs_squash; fi
  done

  for i in $CLOOP_ARCHES; do
    if [ "$ARCH" = "$i" ]; then livefs_cloop; fi
  done

done
