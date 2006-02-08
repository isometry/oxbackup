#!/bin/ksh
#
# System backup script
# $Id$

PATH=/usr/sbin:/usr/xpg4/bin:/usr/bin:${PATH}

BASE=/brookes/backup
LOGFILE=${BASE}/log/daily
SCRIPT_BASE=${BASE}/scripts
HOSTNAME=$(hostname)

function usage
{
	echo "USAGE: $0 [-ehqrt] [-f file] [-c dumpcmd] [-u dumparg] [-d dumpdev]"
	echo "       $0 -l  # display current log file"
	echo "       $0 -R  # register with logadm"
	exit $1
}

function process_scripts
{
	SCRIPT_TYPE=$1
	SCRIPT_PATH=${SCRIPT_BASE}/${SCRIPT_TYPE}

	if [[ ${NO_SCRIPT} -eq 1 ]]
	then
		echo "--> ${SCRIPT_TYPE} scripts skipped"
	else
		if [[ -d ${SCRIPT_PATH} ]]
		then
			echo "--> ${SCRIPT_TYPE} scripts"
			ls ${SCRIPT_PATH} | while read i
			do
				j=${SCRIPT_PATH}/$i
				if [[ -x $j ]]
				then
					echo "--> executing $j"
					(	# execute in a subshell; prefix each output line with #
						$j
					) 2>&1 | sed 's/^/# /'
				else
					echo "--> skipping $j"
				fi
			done
		else
			echo "--> ${SCRIPT_TYPE} scripts missing"
		fi
	fi
}

function tape_status
{
	if [[ ${NO_TAPE} -eq 1 ]]
	then
		echo "--> running without tape"
	else
		echo "--> checking tape status"
		mt status
		if [[ $? -ne 0 ]]
		then
			echo "--> error accessing tape device"
			NO_TAPE=1
		fi
	fi
}

function tape_rewind
{
	if [[ ${NO_TAPE} -eq 1 || ${NO_REWIND} -eq 1 ]]
	then
		echo "--> skipped tape rewind"
	else
		echo "--> rewinding tape"
		mt rewind
		if [[ $? -ne 0 ]]
		then
			# if rewind failed, don't dump nor eject
			NO_DUMP=1
		fi
	fi
}

function tape_eject
{
	if [[ ${NO_TAPE} -eq 1 || ${NO_EJECT} -eq 1 ]]
	then
		echo "--> skipped tape eject"
	else
		echo "--> ejecting tape"
		mt offline
	fi
}

function fs_dump
{
	if [[ ${NO_TAPE} -eq 1 || ${NO_DUMP} -eq 1 ]]
	then
		echo "--> skipped dump of ${HOSTNAME}:$1"
	else
		echo "--> dumping ${HOSTNAME}:$1"
		${DUMP_CMD} ${DUMP_ARG} ${DUMP_DEV} $1
	fi
}

function fs_loop
{
	echo "--> looping over ${FILESYSTEMS}"
	grep -Ev -e '^\s*(#.*)?$' ${FILESYSTEMS} | while read i
	do
		fs_dump $i
	done
}

function do_backup
{
	echo "===> STARTED: $(date +'%Y%m%d @%H:%M')"
	tape_status
	process_scripts pre
	tape_rewind
	fs_loop
	tape_eject
	process_scripts post
	echo "===> COMPLETED: $(date +'%Y%m%d @%H:%M')"
}

function hilite
{
	sed -e "s/${1}/[${2}m&[0m/"
}

function colourize
{
	if [[ $NO_COLOUR -eq 1 ]]
	then
		cat
	else
		{ hilite 'DUMP IS DONE' '1;32' \
		| hilite '.*failed.*' '1;31' \
		| hilite '^-->.*' '1;37' }
	fi

}

function show_log
{
	# dump the log, without script output and with highlighting
	cat ${LOGFILE} \
	| grep -v '^#' \
	| colourize \
	| ${PAGER:-/usr/bin/more}
}

# process command line arguments
while getopts c:d:ef:hlnqrRtu:v c
do
	case $c in
	# set dump command (default: ufsdump(1M))
	c)	DUMP_CMD=${OPTARG}
		;;
	# set ufsdump arguments
	u)	DUMP_ARG=${OPTARG}
		;;
	# set ufsdump device
	d)	DUMP_DEV=${OPTARG}
		;;
	# print progress on console
	v)	OUTPUT=/dev/stdout
		;;
	# don't eject the tape
	e)	NO_EJECT=1
		;;
	# don't colourize log
	n)	NO_COLOUR=1
		;;
	# don't run pre/post scripts
	q)	NO_SCRIPT=1
		;;
	# don't rewind the tape
	r)	NO_REWIND=1
		;;
	# assume no tape is present
	t)	NO_TAPE=1
		;;
	f)	FILESYSTEMS=${OPTARG}
		;;
	# show help
	h)	usage 0
		;;
	l)	show_log
		exit 0
		;;
	# register with logadm
	R)	logadm -w backup -C 14 -p never -z 1 /brookes/backup/log/daily
		exit 0
		;;
	# default: exit with error
	*)	usage 1
		;;
	esac
done
shift $((OPTIND - 1))

# Set defaults
: ${DUMP_CMD:=/usr/sbin/ufsdump}
: ${DUMP_ARG:=0uf}
: ${DUMP_DEV:=/dev/rmt/0cbn}
: ${OUTPUT:=/dev/null}
: ${NO_EJECT:=0}
: ${NO_COLOUR:=0}
: ${NO_SCRIPT:=0}
: ${NO_REWIND:=0}
: ${NO_TAPE:=0}
: ${FILESYSTEMS:=${BASE}/FILESYSTEMS}

[[ -f $FILESYSTEMS ]] || { echo "$FILESYSTEMS not found"; usage 1 }

# do it
do_backup 2>&1 | tee -a ${LOGFILE} >${OUTPUT}
