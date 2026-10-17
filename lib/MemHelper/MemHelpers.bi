'=============================================================
'  MemHelpers.bi  --  Growable _MEM byte buffers for QB64-PE
'  Part of the QB64Starter toolkit.
'
'  Buffers are referenced by a Long handle (0 .. MEMBUF_MAX-1).
'  A handle stays valid across every grow/shrink, so nothing
'  outside this module ever holds a raw _OFFSET.
'=============================================================

Const MEMBUF_MAX = 128
Const MEMBUF_MINCAP = 64

Dim Shared mbMem(0 To MEMBUF_MAX - 1) As _MEM
Dim Shared mbLngth(0 To MEMBUF_MAX - 1) As Long
Dim Shared mbCap(0 To MEMBUF_MAX - 1) As Long
Dim Shared mbUsed(0 To MEMBUF_MAX - 1) As Integer

Declare Function MemBufNew& (initialCap As Long)
Declare Function MemBufValid% (h As Long)
Declare Function MemBufLength& (h As Long)
Declare Function MemBufCapacity& (h As Long)
Declare Function MemBufSlice$ (h As Long, bpos As Long, count As Long)
Declare Function MemBufLoadFile% (h As Long, filePath As String)
Declare Function MemBufSaveFile% (h As Long, filePath As String)

Declare Sub MemBufFree (h As Long)
Declare Sub MemBufClear (h As Long)
Declare Sub MemBufReserve (h As Long, needed As Long)
Declare Sub MemBufAppend (h As Long, s As String)
Declare Sub MemBufReplace (h As Long, bpos As Long, oldLen As Long, s As String)
Declare Sub MemBufReadLine (h As Long, cursor As Long, lineTxt As String, lineStart As Long, lineLen As Long, advance As Long)
Declare Sub MemBufFreeAll ()
