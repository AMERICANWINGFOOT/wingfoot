'=======================================================================
' RFS.bi  -  Russell File System (declarations)
'
' Add an Include metacommand for RFS.bi at the TOP of your program and
' one for RFS.bm at the BOTTOM. (Written as words on purpose -- the
' real metacommand is comment-formatted, so QB64 would act on it even
' from inside these remarks.)
'
' RFS is an append-only, copy-on-write volume format for flash sticks.
' Nothing already on the volume is ever overwritten; every change is
' appended, then committed by writing a superblock. Pulling the stick
' mid-write loses only the unfinished operation.
'
' ON-DISK LAYOUT (all integers little-endian, offsets from 0)
'
'   0        Superblock A  (128 bytes, used when seq is even)
'   4096     Superblock B  (128 bytes, used when seq is odd)
'   1 MiB    Log start: records appended one after another
'
' SUPERBLOCK (128 bytes)
'   +0   "RFS1"            magic
'   +4   INTEGER           format version (1)
'   +6   INTEGER           flags (0)
'   +8   _INTEGER64        seq  (commit counter; newest valid wins)
'   +16  _INTEGER64        catalog record offset
'   +24  LONG              catalog record length (header + payload)
'   +28  4 bytes           reserved
'   +32  _INTEGER64        tail (end of committed log)
'   +40  _INTEGER64        volume size cap
'   +48  32 bytes          label, zero padded
'   +80  44 bytes          reserved
'   +124 _UNSIGNED LONG    CRC32 of bytes 0..123
'
' RECORD HEADER (32 bytes) followed by payload
'   +0   "RCHK" or "RCAT"  magic (file chunk / catalog)
'   +4   LONG              flags (bit 0 = payload is deflated)
'   +8   LONG              raw length (after inflating)
'   +12  LONG              stored payload length
'   +16  _UNSIGNED LONG    CRC32 of stored payload
'   +20  8 bytes           reserved
'   +28  _UNSIGNED LONG    CRC32 of header bytes 0..27
'
' CATALOG PAYLOAD (deflated): LONG count, then per file:
'   INTEGER nameLen, name bytes, _INTEGER64 size, _INTEGER64 stored,
'   _INTEGER64 first chunk offset, LONG chunk count, 19-byte timestamp
'
' A file's chunks sit back to back in the log, so the next chunk is
' at (this offset + 32 + stored length).
'=======================================================================

Const RFS_SUPER_A = 0
Const RFS_SUPER_B = 4096
Const RFS_SUPER_LEN = 128
Const RFS_DATA_START = 1048576
Const RFS_HDR_LEN = 32
Const RFS_CHUNK_RAW = 1048576
Const RFS_VERSION = 1

' --- mounted volume state ---
Dim Shared rfsMounted As Integer
Dim Shared rfsFh As Integer
Dim Shared rfsVolPath As String
Dim Shared rfsLabel As String
Dim Shared rfsSeq As _Integer64
Dim Shared rfsCatOfs As _Integer64
Dim Shared rfsCatLen As Long
Dim Shared rfsTail As _Integer64
Dim Shared rfsVolSize As _Integer64
Dim Shared rfsError As String
Dim Shared rfsVerbose As Integer
Dim Shared rfsIOErr As Long

' -1 = RFSPutFile% skips its commit (batch adds: call RFSCommit%
' yourself once at the end). 0 = commit after every file (default).
Dim Shared rfsDeferCommit As Integer

' --- compression level for files added from now on ---
' 0 = store only (no deflate), 1 = fastest ... 10 = smallest. Default 6.
Dim Shared rfsLevel As Integer

' --- progress display ---
' rfsVerbose: 0 = silent, -1 = text line (console tools),
'             2 = graphics bar at rfsBarX/Y/W with rfsBarText (GUI)
Dim Shared rfsBarX As Integer
Dim Shared rfsBarY As Integer
Dim Shared rfsBarW As Integer
Dim Shared rfsBarText As String

' --- in-memory catalog ---
Dim Shared rfsCount As Long
ReDim Shared rfsName(0 To 63) As String
ReDim Shared rfsSize(0 To 63) As _Integer64
ReDim Shared rfsStored(0 To 63) As _Integer64
ReDim Shared rfsFirst(0 To 63) As _Integer64
ReDim Shared rfsChunks(0 To 63) As Long
ReDim Shared rfsStamp(0 To 63) As String

' --- backup target (RFSBackupPlan% / RFSBackupRun%) ---
' A second catalog for the backup volume being written. The mounted
' volume is only ever read while a backup runs.
Dim Shared rfsBkPath As String
Dim Shared rfsBkFh As Integer
Dim Shared rfsBkIsOpen As Integer
Dim Shared rfsBkPlanned As Integer
Dim Shared rfsBkIsNew As Integer
Dim Shared rfsBkLabel As String
Dim Shared rfsBkSeq As _Integer64
Dim Shared rfsBkCatOfs As _Integer64
Dim Shared rfsBkTail As _Integer64
Dim Shared rfsBkCap As _Integer64
Dim Shared rfsBkCount As Long
ReDim Shared rfsBkName(0 To 63) As String
ReDim Shared rfsBkSize(0 To 63) As _Integer64
ReDim Shared rfsBkStored(0 To 63) As _Integer64
ReDim Shared rfsBkFirst(0 To 63) As _Integer64
ReDim Shared rfsBkChunks(0 To 63) As Long
ReDim Shared rfsBkStamp(0 To 63) As String
ReDim Shared rfsBkSeen(0 To 63) As Integer

' per mounted file: index in the backup catalog (-1 = not there),
' and -1 if it has to be copied (new or changed)
ReDim Shared rfsBkMatch(0 To 63) As Long
ReDim Shared rfsBkNeed(0 To 63) As Integer

' plan results (set by RFSBackupPlan%)
Dim Shared rfsBkToCopy As Long
Dim Shared rfsBkToCopyBytes As _Integer64
Dim Shared rfsBkUnchanged As Long
Dim Shared rfsBkOrphans As Long

' run results (set by RFSBackupRun%)
Dim Shared rfsBkCopied As Long
Dim Shared rfsBkBytes As _Integer64
Dim Shared rfsBkRemoved As Long
Dim Shared rfsBkBad As Long
Dim Shared rfsBkFirstBad As String

