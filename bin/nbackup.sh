#!/bin/ksh
# RB 2007/02/16
# $Id$
#
# Backup local filesystems to local or remote device.
#

PATH=/usr/sbin:/usr/xpg4/bin:/usr/bin:$PATH

BASE=$(cd $(dirname $0)/..; pwd)
LOG_FILE=$BASE/log/daily
TOC_FILE=$BASE/log/toc
EXCLUDE_FILE=$BASE/etc/exclude
SCRIPT_BASE=$BASE/scripts
HOSTNAME=$(hostname)

function usage
{
	echo "USAGE: $0 [-d device]  # backup to device"
	echo "       $0 -c           # display current log file"
}

while getopts cd:r:s:vh c
do
	case $c in
	c)	ACTION=log_view
		;;
	d)	DUMP_DEVICE=$OPTARG
		;;
	r)	RSH=$OPTARG
		;;
	s)	RSH="ssh -o BatchMode=yes"
		;;
	v)	OUTPUT=/dev/stdout
		;;
	h)	usage 0
		;;
	*)	usage 1
		;;
	esac
done
shift $((OPTIND - 1))

# Set defaults
: ${ACTION:=backup_all}
: ${DUMP_DEVICE:=/dev/rmt/0cbn}
: ${RSH:=rsh}
: ${OUTPUT:=/dev/null}
: ${NO_TAPE:=0}
: ${NO_REWIND:=0}
: ${NO_EJECT:=0}
: ${FS_TYPES:=ufs zfs}
: ${PAX_FORMAT:=xustar}
: ${SNAPSHOT_UFS:=0}

# Set remote command defaults
GREP=/usr/xpg4/bin/grep
AWK=/usr/xpg4/bin/awk
MT=/usr/bin/mt
DD=/usr/bin/dd
PAX=/usr/bin/pax
UFSDUMP=/usr/sbin/ufsdump

# Calculate additional settings
REMOTE=$(echo $DUMP_DEVICE | grep :)
if [[ -n "$REMOTE" ]]; then
	echo $DUMP_DEVICE | sed 's/:/ /' | read DUMP_HOST DUMP_DEVICE
fi

# Check tape status
function tape_status
{
	if (( NO_TAPE > 0 )); then
		echo "--> running without tape"
	else
		echo "--> checking tape status"
		${REMOTE:+$RSH $DUMP_HOST} $MT status
	fi
	STATUS=$?
}

# Rewind tape
function tape_rewind
{
	if (( NO_TAPE > 0 || NO_REWIND > 0 )); then
		echo "--> skipped tape rewind"
	else
		echo "--> rewinding tape"
		${REMOTE:+$RSH $DUMP_HOST} $MT rewind
	fi
	STATUS=$?
}

# Eject tape
function tape_eject
{
	if (( NO_TAPE > 0 || NO_EJECT > 0 )); then
		echo "--> skipped tape eject"
	else
		echo "--> ejecting tape"
		${REMOTE:+$RSH $DUMP_HOST} $MT offline
	fi
	STATUS=$?
}

# Write data to tape
function tape_write
{
	$DD if=$1 | ${REMOTE:+$RSH $DUMP_HOST} $DD of=$DUMP_DEVICE
}

# Generate a ToC for the pending backup
function toc_create
{
	if [[ -f $EXCLUDE_FILE ]]; then
		EXCLUDE=$(grep -v # | rs -C# 1 < $EXCLUDE_FILE)
	fi
	for t in $FS_TYPES; do
		$AWK -v fstype="$t" -v exclude="$EXCLUDE" '
		BEGIN {split(exclude, excludes, /#/)}
		$3 = fstype && ! $2 in excludes {print $3, $1, $2}
		' < /etc/mnttab
	done | pr -tn > $TOC_FILE
	STATUS=$?
}

# Write backup ToC to dump device
function toc_write
{
	tape_write $TOC_FILE
	STATUS=$?
}

# Create a snapshot of a zfs/ufs filesystem
# $1 = FILESYSTEM/DEVICE
# $2 = MOUNTPOINT
function snap_create
{
	case $TYPE in
	zfs)
		echo "--> creating zfs snapshot of $2" 1>&2
		zfs destroy -f $1@backup >/dev/null 2>&1
		zfs snapshot $1@backup
		STATUS=$?
		echo $2/.zfs/snapshot/backup
		;;
	ufs)
		if (( SNAPSHOT_UFS > 0 )); then
			echo "--> creating ufs snapshot of $2" 1>&2
			BACKING_STORE=$(mktemp); rm $BACKING_STORE
			fssnap -F ufs -o raw,bs=$BACKING_STORE,unlink $1
			STATUS=$?
		else
			echo "--> not creating ufs snapshot of $2" 1>&2
			echo $1
			STATUS=0
		fi
		;;
	esac
}

# Destroy the snapshot of a zfs/ufs filesystem
# $1 = FILESYSTEM/DEVICE
# $2 = MOUNTPOINT
function snap_destroy
{
	case $TYPE in
	zfs)
		echo "--> destroying zfs snapshot of $2"
		zfs destroy -f $1@backup >/dev/null 2>&1
		STATUS=$?
		;;
	ufs)
		if (( SNAPSHOT_UFS > 0 )); then
			echo "--> destroying ufs snapshot of $2"
			fssnap -d $2
			STATUS=$?
		else
			STATUS=0
		fi
		;;
	esac

}

# Clean up snapshots on error trap
function snap_trap
{
	echo "--> TRAPPED ERROR: destroying snapshot of $MOUNTPOINT"
	snap_destroy $DEVICE $MOUNTPOINT
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DESTROY SNAPSHOT of $MOUNTPOINT"
	fi
}

# Dump the directory passed as argument via pax
# $1 = SNAPSHOT
# $2 = MOUNTPOINT
function dump_zfs
{
	echo "--> dumping $2 (pax)"
	cd $1
	tape_write <($PAX -w -pe -x $PAX_FORMAT -X .)
	STATUS=$?
	cd -
}

# Dump the directory passed as argument via ufsdump
# $1 = DEVICE or SNAPSHOT
# $2 = MOUNTPOINT
function dump_ufs
{
	echo "--> dumping $2 (ufsdump)"
	tape_write <($UFSDUMP 0uf - $1)
	STATUS=$?
}

# Dump a filesystem
function dump_fs
{
	DEVICE=$1	# FILESYSTEM in the case of zfs
	MOUNTPOINT=$2
	SNAPSHOT=$(snap_create $DEVICE $MOUNTPOINT)
	if (( STATUS > 0 )); then
		echo "--> FAILED TO CREATE SNAPSHOT of $MOUNTPOINT"
		case $TYPE in
			zfs)	echo "--> skipping dump of $MOUNTPOINT"
					return $STATUS
					;;
			ufs)	echo "--> proceeding with live backup of $MOUNTPOINT"
					SNAPSHOT=$DEVICE
					;;
		esac
	fi
	trap snap_trap 1 2 3 6 9 15
	dump_$TYPE $SNAPSHOT $MOINTPOINT
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DUMP $MOINTPOINT"
	fi
	snap_destroy $DEVICE $MOINTPOINT
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DESTROY SNAPSHOT of $MOINTPOINT"
	fi
	return $STATUS
}

# Backup all local filesystems
function backup_all
{
	echo "===> STARTED: $(date +'%Y%m%d @%H:%M')"
	toc_create
	toc_write
	while read NUM TYPE DEVICE MOUNTPOINT; do
		dump_fs $DEVICE $MOUNTPOINT
	done < $TOC_FILE
	echo "===> COMPLETED: $(date +'%Y%m%d @%H:%M')"
}

case $# in
0)	backup_all
	;;
*)	echo "NOT IMPLEMENTED"
	usage 1
	;;
esac
