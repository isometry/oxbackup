#!/bin/ksh
# RB 2007/02/16
# $Id$
#
# Backup local filesystems to local or remote device.
#

PATH=/usr/sbin:/usr/xpg4/bin:/usr/bin:$PATH

BASE=$(cd $(dirname $0)/..; pwd)
LOG_FILE=$BASE/log/backup.log
TOC_FILE=$BASE/log/toc
EXCLUDE_FILE=$BASE/etc/exclude
MAIL_USERS=
SCRIPT_BASE=$BASE/scripts
HOSTNAME=$(hostname)

function usage
{
	echo "USAGE: $0 [-d device]  # backup to device"
	echo "       $0 -c           # display current log file"
}

while getopts cd:mr:svh c
do
	case $c in
	c)	ACTION=log_view
		;;
	d)	DUMP_DEVICE=$OPTARG
		;;
	m)	MAIL_LOG=1
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
: ${MAIL_LOG:=0}
: ${MAIL_USERS:=p0073773@brookes.ac.uk}

# Set remote command defaults
GREP=/usr/xpg4/bin/grep
AWK=/usr/xpg4/bin/awk
MT=/usr/bin/mt
DD=/usr/bin/dd
PAX=/usr/bin/pax
UFSDUMP=/usr/sbin/ufsdump

# Calculate additional settings
REMOTE=$(echo $DUMP_DEVICE | $GREP :)
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
	NO_TAPE=$?
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
	if (( NO_TAPE > 0 )); then
		echo "--> NO TAPE: piping to /dev/null"
		cat >/dev/null
	else
		${REMOTE:+$RSH $DUMP_HOST} $DD of=$DUMP_DEVICE
	fi
}

# Generate a ToC for the pending backup
function toc_create
{
	echo "--> generating table of contents:"
	if [[ -f $EXCLUDE_FILE ]]; then
		EXCLUDE=$($AWK 'BEGIN {printf "^(";} $0 !~ /#/ && $0 != "" {printf "%s%s", (i++>0)?"|":"", $0;} END {printf ")$";}' $EXCLUDE_FILE)
	else
		echo "--> exclude file not found"
		EXCLUDE='^$'
	fi
	for t in $FS_TYPES; do
		$AWK -v fstype=$t -v exclude=$EXCLUDE \
			'$3 == fstype && $2 !~ exclude {print $3, $1, $2}' \
		< /etc/mnttab
	done | pr -tn > $TOC_FILE
	STATUS=$?
	cat $TOC_FILE
}

# Write backup ToC to dump device
function toc_write
{
	echo "--> writing table of contents"
	echo Backup of $HOSTNAME: $(date +'%Y-%m-%d %H:%M') | cat - $TOC_FILE | tape_write
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
			echo "--> no snapshot to destroy"
			STATUS=0
		fi
		;;
	esac
}

# Clean up snapshots on error trap
function snap_trap
{
	echo "==> TRAPPED ERROR"
	snap_destroy $1 $2
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DESTROY SNAPSHOT of $2"
	fi
}

# Dump the directory passed as argument via pax
# $1 = SNAPSHOT
# $2 = MOUNTPOINT
function dump_zfs
{
	echo "==> dumping $2 via pax"
	cd $1
	$PAX -w -pe -x $PAX_FORMAT -X . | tape_write
	STATUS=$?
	cd -
}

# Dump the directory passed as argument via ufsdump
# $1 = DEVICE or SNAPSHOT
# $2 = MOUNTPOINT
function dump_ufs
{
	echo "==> dumping $2 via ufsdump"
	$UFSDUMP 0uf - $1 | tape_write
	STATUS=$?
}

# Dump a filesystem
function dump_fs
{
	SNAPSHOT=$(snap_create $1 $2)
	if (( STATUS > 0 )); then
		echo "--> FAILED TO CREATE SNAPSHOT of $2"
		case $TYPE in
		zfs)	echo "--> skipping dump of $2"
				return $STATUS
				;;
		ufs)	echo "--> proceeding with live backup of $2"
				SNAPSHOT=$1
				;;
		esac
	fi
	trap "snap_trap $1 $2" 1 2 3 6 9 15
	dump_$TYPE $SNAPSHOT $2
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DUMP $2"
	fi
	RETVAL=$STATUS
	snap_destroy $1 $2
	if (( STATUS > 0 )); then
		echo "--> FAILED TO DESTROY SNAPSHOT of $2"
	fi
	return $RETVAL
}

# Mail interested parties
function mail_users
{
	mailx -s "Message from $HOSTNAME: backup failed" $MAIL_USERS
}

# Backup all local filesystems
function backup_all
{
	echo "===> Backup commenced: $(date +'%Y-%m-%d %H:%M')"
	tape_status
	tape_rewind
	toc_create
	toc_write
	while read NUM TYPE DEVICE MOUNTPOINT; do
		dump_fs $DEVICE $MOUNTPOINT
		(( STATUS > 0 )) && MAIL_LOG=1
	done < $TOC_FILE
	tape_eject
	echo "===> Backup completed: $(date +'%Y-%m-%d %H:%M')"
}

case $# in
0)	backup_all 2>&1 | tee -a $LOG_FILE >$OUTPUT
	;;
*)	echo "NOT IMPLEMENTED"
	usage 1
	;;
esac

if (( MAIL_LOG > 0 )); then
	mail_users < $LOG_FILE
fi

