# The oxbackup script

Tape backup for UFS and ZFS filesystems under Solaris 10

## UFS snapshots

If you want UFS filesystems to be snapshot, then you must create a backing store
to house them.

With ZFS available, just create a filesystem at `/snap`.

```
# zfs create pool/snap
# zfs set mountpoint=/snap pool/snap
# chmod 700 /snap
```

Lacking ZFS, a symlink from `/snap` to `/var/tmp` will suffice (but see the note below):

```
# ln -s /var/tmp /snap
```

To disable UFS snapshots altogether, you could simply set the `SNAPSHOT_UFS`
environment variable to 0:

```
# env SNAPSHOT_UFS=0 ...
```

If no `/snap` is found, then the script will print a warning but continue without UFS snapshots.

## Exclusions

You can configure exclusions and filesystems which you want backed up "live"
(without being snapshot).
The fileformat for both these configuration files is one filesystem mointpoint
per-line.
If you create a `/snap` zfs, then it should be excluded; if you backed `/snap` in
`/var`, then `/var` should not be snapshot.

```
# vi etc/exclude
  /snap
# vi etc/nosnap
  /var
```

## Scripts

The backup scripts supports configuration of arbitrary pre- and post-backup
scripts via `etc/scripts`.

If `ntpd` runs on the system, then it must be stopped in order to snapshot the
root filesystem. Examples for Solaris 9/10 are included.

## Scheduling

Finally, add an appropriate entry to the `crontab`:

```
# crontab -e
  30 2 * * 2-6 /sysadmin/backup/bin/oxbackup backup
```

Were you backing up to a remote tape, pass the appropriate arguments:

```
  30 2 * * 2-6 /sysadmin/backup/bin/oxbackup -f csdns:/dev/rmt/1cn backup
```

## Checking

In order to expose standard `checkback` functionality, add an alias to `~root/.cshrc`:

```
# vi ~root/.cshrc
  alias checkback '/sysadmin/backup/bin/oxbackup check'
```

## Errors

Sometimes, the script will falsely report a failure on a zfs mountpoint when it encounters a filename containing UTF-8 characters, for example:

```
==> BEGIN: dump of /crm1 via pax: 2007-07-19 01:57:51
--> running pax...
pax: invalid character in UTF-8 conversion of 'oracle_uat/tstcrmdb/9.2.0/network/admin/dg_prim_diag_lcrm_&×tamp.out'
pax: file (oracle_uat/tstcrmdb/9.2.0/network/admin/dg_prim_diag_lcrm_&×tamp.out): UTF-8 conversion failed.
==> ERROR: dump of /crm1 failed: 2007-07-19 03:32:57
234612447+0 records in
1862003+1 records out
```

These can generally be safely ignored, though it may be wise to notify the owner of the offending file that it's not being backed up. If unsure, you can verify the amount of data written to tape by multiplying the `records out` by output blocksize, `obs=63k`. For example 1,862,003 * 63KB = 117,306,189 KB = 111.9 GB. Check the size of the filesystem by multiplying the zfs `used` by `compressratio`, in this case giving us ~108.1 GB:

```
# zfs get used,compressratio st1/crm1
NAME             PROPERTY       VALUE                      SOURCE
st1/crm1         used           41.4G                      -
st1/crm1         compressratio  2.61x                      -
```

## Restores

The oxbackup script contains a wrapper around basic restore functionality, accessed via `bin/oxbackup restore [mountpoint]`.

If `mountpoint` is a UFS partition this will position the tape correctly before launching `ufsrestore`.
For a zfs `mountpoint` it will position the tape then prompt for a space-separated list of `fnmatch(3C)` patterns to restore (relative to `mountpoint`, no leading `./`).

A typical restore from a zfs might look something like this:

```
# ./oxbackup toc
--> rewinding tape
Backup of tcisdb1: 2007-07-19 01:10:02
    1   ufs /dev/dsk/c0t0d0s0 /
    2   ufs /dev/dsk/c0t0d0s3 /var
    3   zfs pool/app /app
    4   zfs st1/auth1 /auth1
    5   zfs pool/brookes /brookes
    6   zfs st1/cis /cis
    7   zfs st1/cmis /cmis
    8   zfs st1/crm1 /crm1
    9   zfs pool/data /data
   10   zfs st1/ecsis1 /ecsis1
   11   zfs st1/edm1 /edm1
   12   zfs st1/eis1 /eis1
   13   zfs st1/fin1 /fin1
   14   zfs pool/logs /logs
   15   zfs st1/oxshare1 /oxshare1
   16   zfs pool/sysadmin /sysadmin
   17   zfs pool/sysadmin/home /sysadmin/home
   18   zfs pool/users /users
1+1 records in
1+1 records out
# cd /tmp/foo
# ./oxbackup restore /crm1
==> initiating restore from /crm1
--> WARNING: restore will be to the current directory (/tmp/foo)!
--> rewinding tape
1+1 records in
1+1 records out
--> matched entry in table of contents: 8 zfs st1/crm1 /crm1
--> pax does not support interaction
Enter file patterns to restore: oracle/lcrmdb
USTAR format archive extended
oracle/lcrmdb/9.2.0/inventory/Components21/oracle.swd.oui/2.2.0.19.0/installlog.xml
oracle/lcrmdb/9.2.0/inventory/ContentsXML/comps.xml
oracle/lcrmdb/9.2.0/inventory/ContentsXML/libs.xml
1862003+1 records in
234612447+0 records out
483.47u 2004.12s 1:25:54.58 48.2%
```

When prompted with 'Enter file patterns to restore:', it is requesting the subfolders of the folder (so in the example it's crm1/oracle/lcrmdb that's being restored). 

## UFS Restores

```
[csdns:~]> mkdir trestore
[csdns:~]> cd trestore
[csdns:~/trestore]> /sysadmin/backup/bin/oxbackup toc
--> [13:34:43] rewinding tape
/dev/rmt/0cn: write protected or reserved.
++> [13:34:43] ERROR: accessing tape
Exit 1
[csdns:~/trestore]> pfexec tcsh
info: TCSHRC: sourced from CSDNS
[csdns:~/trestore]# /sysadmin/backup/bin/oxbackup toc
--> [13:35:17] rewinding tape
Backup of dcisapp1 [2014-10-23 03:10:02]
    1   ufs /dev/md/dsk/d10 /
    2   ufs /dev/md/dsk/d30 /var
    3   ufs /dev/md/dsk/d70 /cis
    4   ufs /dev/md/dsk/d40 /brookes
    5   ufs /dev/md/dsk/d50 /app
    6   ufs /dev/md/dsk/d60 /users
0+1 records in
0+1 records out
[csdns:~/trestore]# /sysadmin/backup/bin/oxbackup position 6
[csdns:~/trestore]# ufsrestore iv
Verify volume and initialize maps
Media block size is 126
Dump   date: 23 October 2014 05:10:03 BST
Dumped from: the epoch
Level 0 dump of an unlisted file system on dcisapp1:/dev/fssnap/0
Label: none
Extract directories from tape
Initialize symbol table.
ufsrestore > pwd
/
ufsrestore > ls
.:
      2 *./                10  oraform/       19043  p0074784/
      2 *../               13  oraoemag/     150714  p0074807/
 175029  brookes/       72916  orassom/       30326  p0074855/
 116209  dcrmapp/       19002  p0023009/     169003  p0075330/
      3  lost+found/    25600  p0054111/      43064  p0075347/
  86778  misbuild/      25601  p0054131/      80344  p0075634/
  44817  miscron/       42185  p0054270/     338874  p0075715/
  86779  misdploy/     152536  p0071665/      85246  p0076594/
 128086  ora10clt/      19044  p0072338/     175980  p0076801/
     14  ora92clt/          6  p0073279/     175037  p0076923/
     15  oracrma3/      25605  p0073604/      72606  p0077178/
 150402  oracron/           7  p0073611/     121305  p0077268/
      8  oraecsm/       25602  p0073923/        755  quotas
 102409  oraecsws/      25603  p0074093/         11  webecs1/
      9  oraedmm/      152560  p0074397/         12  webedm1/
ufsrestore > cd p0074093/
ufsrestore > pwd
/p0074093
ufsrestore > ls
./p0074093:
  27155  #afiedt.buf#
  25603  ./
      2 *../
  34380  .Xauthority
  ...
  42747  zztemp
ufsrestore > add *
Make node ./p0074093
...
Make node ./p0074093/xfer
ufsrestore > marked
./p0074093:
  27155 *#afiedt.buf#
  ...
  42747 *zztemp
ufsrestore > extract
Extract requested files
You have not read any volumes yet.
Unless you know which volume your file(s) are on you should start
with the last volume and work towards the first.
Specify next volume #:
Specify next volume #: 1
extract file ./p0074093/news/xx.
...
extract file ./p0074093/srec.logx
write error extracting inode 35142, name ./p0074093/srec.logx
write: No space left on device
5.81u 6.42s 14:02.19 1.4%
Exit 1
[csdns:~/trestore]#
```

## Manual Restores - Single Tape Drive

The following outlines a manual restore, for example from a Solaris boot CD.

1. Read the table of contents:
```
# mt rewind
# dd if=/dev/rmt/0c
Backup of tcisdb1: 2007-07-19 01:10:02
    1   ufs /dev/dsk/c0t0d0s0 /
    2   ufs /dev/dsk/c0t0d0s3 /var
    3   zfs pool/app /app
    4   zfs st1/auth1 /auth1
    5   zfs pool/brookes /brookes
    6   zfs st1/cis /cis
    7   zfs st1/cmis /cmis
    8   zfs st1/crm1 /crm1
    9   zfs pool/data /data
   10   zfs st1/ecsis1 /ecsis1
   11   zfs st1/edm1 /edm1
   12   zfs st1/eis1 /eis1
   13   zfs st1/fin1 /fin1
   14   zfs pool/logs /logs
   15   zfs st1/oxshare1 /oxshare1
   16   zfs pool/sysadmin /sysadmin
   17   zfs pool/sysadmin/home /sysadmin/home
   18   zfs pool/users /users
```

 2. Restore:
Below, the mt command is used to "Rewind, fast forward to beginning of file X". This operation has been seen to fail silently on csvleadm1's second tape drive. After running 
```
# mt asf 1
```
It is worth running the following to check that the drive has actually positioned the tape to the file number you have specified:
```
# mt status
HP DAT-72 tape drive:
   sense key(0x12)= EOF   residual= 0   retries= 0
   file no= 1   block no= 0
```
If you still get a zero ( 0 ) on the file no= entry then try a different tape drive

 2a. UFS restore:

The first thing you will need to know is which file number on the tape holds the directories and files you want to restore. This is available from the output of the table of contents acquired using the command: 
```
#dd if=/dev/rmt/0c
```

Restores can be started interactively, wich drops you to a ufsrestore> shell. The function letter 'i' achieves this (see commands below). Note the 'mt asf 1' command moves the tape to file number 1 on the tape, having first rewound it. If you find you are in the wrong location on the tape, you can use 'mt fsf 1' to move forwards 1 EOF marker, without rewinding to the start first.
```
# mt asf 1
# cd /restore_path
# ufsrestore ivf /dev/rmt/0cn
```

Note that user directories can be in a variety of locations.
eg. For systems Administration:
```
/brookes/sysadmin
/home/sysadmin
```

For standard users:
```
/users
```

Make sure you know where the files should be located on the server before trying to locate them on the tape, it will save you time.

Files to be restored need to be marked using the 'add' command. They can be located on the tape using the 'ls' command. (Top level directories on the tape do not require a leading '/').
```
ufsrestore > ls
.:
      2 *./                13  oraoemag/      19043  p0074784/
      2 *../            72916  orassom/      150714  p0074807/
 116209  dcrmapp/       19002  p0023009/      30326  p0074855/
      3  lost+found/    25600  p0054111/     144765  p0074930/
  86778  misbuild/      25601  p0054131/     169003  p0075330/
  44817  miscron/       25604  p0054270/      43064  p0075347/
```

Mark a directory and all of its files for restore using 'add'. The output will display all the files marked for restore.
```
ufsrestore> add p0054270
Make node ./p0054270/.subversion
Make node ./p0054270/.subversion/auth
Make node ./p0054270/.subversion/auth/svn.simple
```

To initiate the restore of files use the 'extract' command. You will be prompted for the volume to read. The volume refers to the tape used to backup the filesystem, if the particular filesystem backup ran over more than one tape you may need to specify something other than 1 here.
```
ufsrestore> extract
Extract requested files
You have not read any volumes yet.
Unless you know which volume your file(s) are on you should start
with the last volume and work towards the first.
Specify next volume #: 1
```

At the end of the restore you will be prompted wether or not to reset permissions on the restored directory. Generally you will not want to do this, so can respond 'N'.

 2b. ZFS restore, files matching fnmatch `PATTERN` (nothing if you want to restore everything):
```
# mt asf 3
# cd /restore_path
# dd bs=1024k if=/dev/rmt/0cn | pax -r -pe PATTERN
```

## Manual Restores - Multiple Tape Drives
As an example, csvleadm1 is attached to two tape drives. One is for backups of itself, the other for csvledr1 which a physical server in Wheatly H127.

 1. Identify the correct drive, by sticking a tape in, then ejecting it by specifying the path to the device
```
# mt -f /dev/rmt/0cn offline
```
 Take a look to see if the drive you expected to eject has done so. If it has, record the device path used. If not, try:
```
# mt -f /dev/rmt/1cn offline
```
 Keep going up the numbers until the the tape is eject from the drive you want to use.

 2. Read the table of contents:
```
# mt -f /dev/rmt/1cn rewind
# dd if=/dev/rmt/1c
Backup of csvledr1 [2012-08-23 01:10:06]
    1   zfs rpool/ROOT/S10u6-20090629 /
    2   zfs rpool/ROOT/S10u6-20090629/var /var
    3   zfs rpool/ROOT/S10u6-20090629/opt /opt
    4   zfs rpool/COMMON/brookes /brookes
    5   zfs rpool/COMMON/logs /logs
    6   zfs rpool /rpool
    7   zfs rpool/ROOT /rpool/ROOT
    8   zfs st1/sync-csvledb1 /sync-csvledb1
    9   zfs st1/sync-tvle-db1 /sync-tvle-db1
   10   zfs rpool/COMMON/sysadmin /sysadmin
   11   zfs rpool/COMMON/sysadmin/home /sysadmin/home
   12   zfs rpool/COMMON/users /users
1+1 records in
1+1 records out
```

 3. Restore
Below, the mt command is used to "Rewind, fast forward to beginning of file X". This operation has been seen to fail silently on csvleadm1's second tape drive. After running 
```
# mt -f /dev/rmt/1cn asf 1
```
It is worth running the following to check that the drive has actually positioned the tape to the file number you have specified:
```
# mt -f /dev/rmt/1cn status
HP DAT-72 tape drive:
   sense key(0x12)= EOF   residual= 0   retries= 0
   file no= 1   block no= 0
```
If you still get a zero ( 0 ) on the file no= entry then try a different tape drive

 3a. UFS restore:
```
# mt -f /dev/rmt/1c asf 1
# cd /restore_path
# ufsrestore ivf /dev/rmt/1cn
}}}

 3b. ZFS restore
```
# mt -f /dev/rmt/1c asf 5
# cd /restore_path
# dd bs=1024k if=/dev/rmt/1cn | pax -r -pe PATTERN
```