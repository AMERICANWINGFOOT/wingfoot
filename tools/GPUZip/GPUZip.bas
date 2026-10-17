'=============================================================================
' GPUZip.bas - multi-GPU folder compressor (QB64-PE 4.6 front end)
'
' Needs libgpuzip.so and gpuzip.h in the same folder (run build.sh first).
' The folder path must not contain spaces.
'
' Archive format "GPZ1":
'   64-byte header (Type GPZHEAD)
'   compressed chunks back to back (each <= 64 KB raw, LZ4 block or stored)
'   chunk table: one Long per chunk (> 0 = LZ4 size, < 0 = stored raw size)
'   file table: per entry pathLen (2), path, size (8), stream offset (8),
'               crc32 (4), entry type (1: 0 = file, 1 = folder)
' All files are joined into one solid stream before chunking.
'
' Command line (also handy for scripts):
'   GPUZip c <folder> <archive.gpz> [mode]   compress
'   GPUZip x <archive.gpz> <dest folder>     extract
'   GPUZip l <archive.gpz>                   list
'   GPUZip b <folder>                        benchmark every mode
'   mode: -2 hybrid, -1 CPU, 0 all GPUs, 1..n one GPU
'=============================================================================
Option _Explicit
$Console

Const CS = 65536
Const BATCH_CHUNKS = 1024
Const BATCH_BYTES = 67108864
Const BENCH_CAP = 1073741824
Const READ_PIECE = 1048576
Const SW = 1000
Const SH = 660
Const ROWH = 16
Const PANEL_Y = 112

Declare Library "./gpuzip"
    Function gz_Init& ()
    Sub gz_Shutdown ()
    Function gz_DeviceCount& ()
    Function gz_DeviceName& (ByVal idx As Long, buf As String, ByVal cap As Long)
    Function gz_CpuThreads& ()
    Function gz_LastError& (buf As String, ByVal cap As Long)
    Function gz_CompressBatch&& (ByVal src As _Offset, ByVal srcLen As _Integer64, ByVal chunkSize As Long, ByVal dst As _Offset, ByVal sizes As _Offset, ByVal cmode As Long)
    Function gz_WorkerChunks&& (ByVal idx As Long)
    Function gz_ChunkCount&& (ByVal length As _Integer64, ByVal chunkSize As Long)
    Function gz_DecompressBatch& (ByVal src As _Offset, ByVal srcLen As _Integer64, ByVal sizes As _Offset, ByVal nChunks As Long, ByVal chunkSize As Long, ByVal rawLen As _Integer64, ByVal dst As _Offset)
    Function gz_Crc32~& (ByVal p As _Offset, ByVal length As _Integer64, ByVal crc As _Unsigned Long)
    Function gz_ScanFolder& (root As String)
    Function gz_ScanPath& (ByVal idx As Long, buf As String, ByVal cap As Long)
    Function gz_ScanSize&& (ByVal idx As Long)
    Function gz_ScanType& (ByVal idx As Long)
    Function gz_MkdirP& (folderPath As String)
    Function gz_FCreate& (filePath As String)
    Function gz_FOpenR& (filePath As String)
    Function gz_FWrite& (ByVal fd As Long, ByVal p As _Offset, ByVal length As _Integer64)
    Function gz_FWriteAt& (ByVal fd As Long, ByVal p As _Offset, ByVal length As _Integer64, ByVal fileOfs As _Integer64)
    Function gz_FRead&& (ByVal fd As Long, ByVal p As _Offset, ByVal length As _Integer64)
    Function gz_FClose& (ByVal fd As Long)
    Function gz_FSync& (ByVal fd As Long)
    Function gz_FDelete& (filePath As String)
    Function gz_ErrText& (ByVal code As Long, buf As String, ByVal cap As Long)
    Function gz_FreeSpace&& (folderPath As String)
End Declare

' magic "GPZ1", ver 1, codec 1 = LZ4 block. Offsets are 0-based file offsets.
Type GPZHEAD
    magic As String * 4
    ver As Long
    chunkSize As Long
    codec As Long
    fileCount As Long
    chunkCount As Long
    streamSize As _Integer64
    chunkTabOfs As _Integer64
    fileTabOfs As _Integer64
    reserved As String * 16
End Type

'--- shared state
Dim Shared nGpu As Long, cpuThreads As Long, gmode As Long
Dim Shared srcFolder As String, archivePath As String
Dim Shared cliMode As Long, cancelReq As Long, lastDraw As Double
Dim Shared mx As Long, my As Long, mDown As Long, mClick As Long, mWheel As Long
Dim Shared logL(0 To 299) As String, logN As Long
Dim Shared panelMode As Long, listTop As Long
Dim Shared busyTitle As String, busyDone As _Integer64, busyTotal As _Integer64

Dim Shared hdr As GPZHEAD
ReDim Shared entPath(0) As String
ReDim Shared entSize(0) As _Integer64
ReDim Shared entOfs(0) As _Integer64
ReDim Shared entCrc(0) As _Unsigned Long
ReDim Shared entType(0) As _Byte
Dim Shared entCount As Long
ReDim Shared chunkSz(0) As Long
Dim Shared bsz(0 To BATCH_CHUNKS) As Long
Dim Shared wStat(0 To 16) As _Integer64

Dim Shared inM As _MEM, outM As _MEM
' compressor state used by CompressFlush%
Dim Shared cFo As Long, cFill As _Integer64, cChunkBase As Long, cPacked As _Integer64, cTime As Double
Dim Shared cPos As _Integer64, cRawDone As _Integer64, tmpM As _MEM

Dim i As Long, buf As String, l As Long, k As Long, a1 As String

Screen _NewImage(SW, SH, 32)
_Title "GPUZip - multi-GPU folder compressor"
_PrintMode _KeepBackground

a1 = LCase$(Command$(1))
If Len(a1) Then cliMode = -1: _ScreenHide

inM = _MemNew(BATCH_BYTES)
outM = _MemNew(BATCH_BYTES)
tmpM = _MemNew(1048576)

nGpu = gz_Init
cpuThreads = gz_CpuThreads
If nGpu > 16 Then nGpu = 16
If nGpu = 0 Then gmode = -1 Else gmode = 0
LogMsg "GPUZip ready. CPU threads: " + _Trim$(Str$(cpuThreads)) + "   GPUs: " + _Trim$(Str$(nGpu))
For i = 0 To nGpu - 1
    buf = Space$(256)
    l = gz_DeviceName(i, buf, 256)
    LogMsg "  GPU " + _Trim$(Str$(i + 1)) + ": " + Left$(buf, l)
Next
If nGpu = 0 Then LogMsg "  No CUDA GPU found - CPU mode only."

'--------------------------------------------------------------- command line
If cliMode Then
    Select Case a1
        Case "c"
            srcFolder = StripSlash$(Command$(2))
            If Len(Command$(4)) Then gmode = Val(Command$(4))
            DoCompress Command$(3)
        Case "x"
            archivePath = Command$(2)
            DoExtract Command$(3)
        Case "l"
            archivePath = Command$(2)
            If ReadArchiveIndex%(archivePath) Then
                For i = 0 To entCount - 1
                    LogMsg EntryLine$(i)
                Next
            End If
        Case "b"
            srcFolder = StripSlash$(Command$(2))
            DoBenchmark
        Case Else
            LogMsg "usage: GPUZip c <folder> <archive> [mode] | x <archive> <dest> | l <archive> | b <folder>"
    End Select
    ShutdownAll
    System
End If

'--------------------------------------------------------------- GUI loop
Do
    _Limit 30
    PollInput
    k = _KeyHit
    If k = 27 Then Exit Do
    Cls , _RGB32(20, 24, 30)

    If Btn%(8, 8, 120, 28, "Source folder") Then PickSource: mDown = 0
    If Btn%(134, 8, 90, 28, "Compress") Then DoCompress "": mDown = 0
    If Btn%(230, 8, 110, 28, "Open archive") Then PickArchive: mDown = 0
    If Btn%(346, 8, 80, 28, "Extract") Then DoExtract "": mDown = 0
    If Btn%(432, 8, 96, 28, "Benchmark") Then DoBenchmark: mDown = 0
    If Btn%(534, 8, 220, 28, "Mode: " + ModeName$(gmode)) Then CycleMode
    If Btn%(760, 8, 100, 28, PanelName$) Then panelMode = 1 - panelMode: listTop = 0
    If Btn%(SW - 78, 8, 70, 28, "Quit") Then Exit Do

    DrawInfo
    DrawPanel
    _Display
Loop
ShutdownAll
System

'=============================================================================
' UI helpers
'=============================================================================
Sub PollInput
    Dim b As Long
    mWheel = 0
    Do While _MouseInput
        mWheel = mWheel + _MouseWheel
    Loop
    mx = _MouseX
    my = _MouseY
    b = _MouseButton(1)
    mClick = (b = 0 And mDown <> 0)
    mDown = b
End Sub

Function Btn% (x As Long, y As Long, w As Long, h As Long, label As String)
    Dim hot As Long
    hot = (mx >= x And mx < x + w And my >= y And my < y + h)
    If hot Then
        Line (x, y)-(x + w - 1, y + h - 1), _RGB32(70, 92, 125), BF
    Else
        Line (x, y)-(x + w - 1, y + h - 1), _RGB32(42, 52, 66), BF
    End If
    Line (x, y)-(x + w - 1, y + h - 1), _RGB32(110, 130, 160), B
    Color _RGB32(235, 235, 235)
    _PrintString (x + (w - Len(label) * 8) \ 2, y + (h - 16) \ 2), label
    Btn% = (hot And mClick)
End Function

Sub DrawInfo
    Color _RGB32(170, 200, 230)
    _PrintString (8, 46), "Source : " + ClipL$(srcFolder, 120)
    _PrintString (8, 64), "Archive: " + ClipL$(archivePath, 120)
    Color _RGB32(140, 150, 165)
    _PrintString (8, 84), "Esc cancels a running job. Mouse wheel scrolls the panel."
End Sub

Sub DrawPanel
    Dim rows As Long, r As Long, i As Long, y As Long, maxTop As Long
    rows = (SH - PANEL_Y - 40) \ ROWH
    Line (4, PANEL_Y - 4)-(SW - 5, PANEL_Y + rows * ROWH + 4), _RGB32(12, 14, 18), BF
    Line (4, PANEL_Y - 4)-(SW - 5, PANEL_Y + rows * ROWH + 4), _RGB32(60, 70, 85), B
    If panelMode = 1 And entCount > 0 Then
        listTop = listTop - mWheel * 3
        maxTop = entCount - rows
        If maxTop < 0 Then maxTop = 0
        If listTop > maxTop Then listTop = maxTop
        If listTop < 0 Then listTop = 0
        For r = 0 To rows - 1
            i = listTop + r
            If i >= entCount Then Exit For
            y = PANEL_Y + r * ROWH
            If entType(i) = 1 Then Color _RGB32(230, 200, 120) Else Color _RGB32(220, 220, 220)
            _PrintString (10, y), ClipR$(EntryLine$(i), 122)
        Next
        Color _RGB32(140, 150, 165)
        _PrintString (8, SH - 30), _Trim$(Str$(entCount)) + " entries, " + MB$(hdr.streamSize) + " raw  ->  showing " + _Trim$(Str$(listTop + 1)) + "-" + _Trim$(Str$(listTop + r))
    Else
        Color _RGB32(200, 215, 200)
        i = logN - rows
        If i < 0 Then i = 0
        For r = 0 To rows - 1
            If i + r >= logN Then Exit For
            _PrintString (10, PANEL_Y + r * ROWH), ClipR$(logL(i + r), 122)
        Next
    End If
End Sub

' Redraws a busy screen at most 10 times a second; Esc sets cancelReq.
Sub ShowBusy (title As String, done As _Integer64, total As _Integer64)
    Dim w As Long, k As Long, frac As Double
    busyTitle = title: busyDone = done: busyTotal = total
    Do While _MouseInput
    Loop
    k = _KeyHit
    If k = 27 Then cancelReq = -1
    If Abs(Timer(0.001) - lastDraw) < 0.1 Then Exit Sub
    lastDraw = Timer(0.001)
    If cliMode Then Exit Sub
    Cls , _RGB32(20, 24, 30)
    Color _RGB32(235, 235, 235)
    _PrintString (8, 14), title
    If total > 0 Then frac = done / total Else frac = 0
    w = Int((SW - 20) * frac)
    Line (8, 40)-(SW - 9, 64), _RGB32(42, 52, 66), BF
    If w > 0 Then Line (8, 40)-(8 + w, 64), _RGB32(70, 160, 90), BF
    Line (8, 40)-(SW - 9, 64), _RGB32(110, 130, 160), B
    _PrintString (16, 45), MB$(done) + " / " + MB$(total) + "   (" + _Trim$(Str$(Int(frac * 100))) + "%)   Esc = cancel"
    panelMode = 0
    DrawPanel
    _Display
End Sub

Sub LogMsg (s As String)
    Dim i As Long
    If logN > UBound(logL) Then
        For i = 1 To UBound(logL)
            logL(i - 1) = logL(i)
        Next
        logN = UBound(logL)
    End If
    logL(logN) = s
    logN = logN + 1
    If cliMode Then _Echo s
End Sub

Sub LogLibError (what As String)
    Dim buf As String, l As Long
    buf = Space$(512)
    l = gz_LastError(buf, 512)
    LogMsg "ERROR in " + what + ": " + Left$(buf, l)
End Sub

Sub CycleMode
    If nGpu = 0 Then gmode = -1: Exit Sub
    gmode = gmode + 1
    If gmode > nGpu Then gmode = -2
End Sub

Function ModeName$ (m As Long)
    Select Case m
        Case -2
            ModeName$ = "Hybrid GPUs+CPU"
        Case -1
            ModeName$ = "CPU x" + _Trim$(Str$(cpuThreads))
        Case 0
            ModeName$ = "All GPUs (" + _Trim$(Str$(nGpu)) + ")"
        Case Else
            ModeName$ = "GPU " + _Trim$(Str$(m)) + " only"
    End Select
End Function

Function PanelName$
    If panelMode = 1 Then PanelName$ = "Show log" Else PanelName$ = "Show list"
End Function

Sub PickSource
    Dim f As String
    f = _SelectFolderDialog$("Folder to compress", srcFolder)
    If Len(f) Then
        srcFolder = StripSlash$(f)
        LogMsg "Source: " + srcFolder
    End If
End Sub

Sub PickArchive
    Dim f As String
    f = _OpenFileDialog$("Open GPUZip archive", archivePath, "*.gpz", "GPUZip archive")
    If Len(f) = 0 Then Exit Sub
    If ReadArchiveIndex%(f) Then
        archivePath = f
        panelMode = 1: listTop = 0
    End If
End Sub

Sub ShutdownAll
    _MemFree inM
    _MemFree outM
    _MemFree tmpM
    gz_Shutdown
End Sub

'=============================================================================
' text helpers
'=============================================================================
Function StripSlash$ (p As String)
    Dim s As String
    s = p
    Do While Len(s) > 1 And Right$(s, 1) = "/"
        s = Left$(s, Len(s) - 1)
    Loop
    StripSlash$ = s
End Function

Function ClipR$ (s As String, n As Long)
    If Len(s) > n Then ClipR$ = Left$(s, n - 3) + "..." Else ClipR$ = s
End Function

Function ClipL$ (s As String, n As Long)
    If Len(s) > n Then ClipL$ = "..." + Right$(s, n - 3) Else ClipL$ = s
End Function

Function PadL$ (s As String, n As Long)
    If Len(s) >= n Then PadL$ = s Else PadL$ = Space$(n - Len(s)) + s
End Function

Function PadR$ (s As String, n As Long)
    If Len(s) >= n Then PadR$ = s Else PadR$ = s + Space$(n - Len(s))
End Function

Function Fmt2$ (v As Double)
    Dim a As Double, w As _Integer64, f As Long, sg As String
    a = v
    If a < 0 Then sg = "-": a = -a
    w = Int(a)
    f = Int((a - w) * 100 + 0.5)
    If f >= 100 Then w = w + 1: f = f - 100
    Fmt2$ = sg + _Trim$(Str$(w)) + "." + Right$("0" + _Trim$(Str$(f)), 2)
End Function

Function MB$ (b As _Integer64)
    MB$ = Fmt2$(b / 1048576#) + " MB"
End Function

Function Elapsed# (t0 As Double)
    Dim d As Double
    d = Timer(0.001) - t0
    If d < 0 Then d = d + 86400
    Elapsed# = d
End Function

Function Rate$ (bytes As _Integer64, secs As Double)
    If secs <= 0 Then Rate$ = "n/a" Else Rate$ = Fmt2$(bytes / 1048576# / secs) + " MB/s"
End Function

Function EntryLine$ (i As Long)
    If entType(i) = 1 Then
        EntryLine$ = PadL$("<DIR>", 14) + "  " + entPath(i) + "/"
    ElseIf entType(i) = 2 Then
        EntryLine$ = PadL$("<SKIPPED>", 14) + "  " + entPath(i)
    Else
        EntryLine$ = PadL$(_Trim$(Str$(entSize(i))), 14) + "  " + entPath(i)
    End If
End Function

Function WorkerSplit$
    Dim s As String, i As Long, tot As _Integer64
    For i = 0 To nGpu
        tot = tot + wStat(i)
    Next
    If tot = 0 Then WorkerSplit$ = "": Exit Function
    For i = 0 To nGpu - 1
        If wStat(i) > 0 Then s = s + "GPU" + _Trim$(Str$(i + 1)) + " " + _Trim$(Str$(Int(wStat(i) * 100 / tot + 0.5))) + "%  "
    Next
    If wStat(nGpu) > 0 Then s = s + "CPU " + _Trim$(Str$(Int(wStat(nGpu) * 100 / tot + 0.5))) + "%"
    WorkerSplit$ = s
End Function

Sub ClearStats
    Dim i As Long
    For i = 0 To 16
        wStat(i) = 0
    Next
End Sub

Sub AddStats
    Dim i As Long
    For i = 0 To nGpu
        wStat(i) = wStat(i) + gz_WorkerChunks(i)
    Next
End Sub

' Rejects absolute paths and any ".." component (archive path safety).
Function SafePath% (p As String)
    Dim s As String, i As Long, part As String
    If Len(p) = 0 Or Left$(p, 1) = "/" Then SafePath% = 0: Exit Function
    s = p + "/"
    part = ""
    For i = 1 To Len(s)
        If Mid$(s, i, 1) = "/" Then
            If part = ".." Then SafePath% = 0: Exit Function
            part = ""
        Else
            part = part + Mid$(s, i, 1)
        End If
    Next
    SafePath% = -1
End Function

Function ParentDir$ (p As String)
    Dim i As Long
    i = _InStrRev(p, "/")
    If i > 1 Then ParentDir$ = Left$(p, i - 1) Else ParentDir$ = ""
End Function

'=============================================================================
' folder scan -> entry arrays (sizes and stream offsets)
'=============================================================================
Function ScanSource&& ()
    Dim n As Long, i As Long, buf As String, l As Long, total As _Integer64
    n = gz_ScanFolder(srcFolder + Chr$(0))
    If n < 0 Then LogLibError "scan": ScanSource&& = -1: Exit Function
    entCount = n
    ReDim entPath(0 To n) As String
    ReDim entSize(0 To n) As _Integer64
    ReDim entOfs(0 To n) As _Integer64
    ReDim entCrc(0 To n) As _Unsigned Long
    ReDim entType(0 To n) As _Byte
    buf = Space$(4096)
    For i = 0 To n - 1
        l = gz_ScanPath(i, buf, 4096)
        entPath(i) = Left$(buf, l)
        entType(i) = gz_ScanType(i)
        entSize(i) = gz_ScanSize(i)
        entOfs(i) = total
        total = total + entSize(i)
    Next
    ScanSource&& = total
End Function

'=============================================================================
' compress
'=============================================================================
Sub DoCompress (target As String)
    Dim outFile As String, total As _Integer64, nChunks As _Integer64, streamPos As _Integer64
    Dim i As Long, fh As Long, remain As _Integer64, take As _Integer64, got As _Integer64
    Dim crc As _Unsigned Long, t0 As Double, e As Long, fileCnt As Long, skipCnt As Long
    Dim c As Long, cnt As Long, k As Long, s As String, ft As String
    Dim failed As Long, secs As Double, freeB As _Integer64, need As _Integer64, warned As Long

    If Len(srcFolder) = 0 Then LogMsg "Pick a source folder first.": Exit Sub
    If _DirExists(srcFolder) = 0 Then LogMsg "Folder not found: " + srcFolder: Exit Sub
    outFile = target
    If Len(outFile) = 0 Then outFile = _SaveFileDialog$("Save archive as", srcFolder + ".gpz", "*.gpz", "GPUZip archive")
    If Len(outFile) = 0 Then Exit Sub
    If LCase$(Right$(outFile, 4)) <> ".gpz" Then outFile = outFile + ".gpz"
    If Left$(outFile, Len(srcFolder) + 1) = srcFolder + "/" Then
        LogMsg "The archive can't be saved inside the folder being compressed."
        Exit Sub
    End If

    t0 = Timer(0.001)
    LogMsg "Scanning " + srcFolder + " ..."
    total = ScanSource&&
    If total < 0 Then Exit Sub
    nChunks = gz_ChunkCount(total, CS)
    LogMsg _Trim$(Str$(entCount)) + " entries, " + MB$(total) + ", " + _Trim$(Str$(nChunks)) + " chunks, mode " + ModeName$(gmode)
    ReDim chunkSz(0 To nChunks) As Long

    ' worst case: nothing compresses, so the archive is the data plus its tables
    need = total + nChunks * 4 + entCount * 64 + 1048576
    freeB = gz_FreeSpace(ParentDir$(outFile) + Chr$(0))
    If freeB >= 0 And freeB < need Then
        LogMsg "  Target drive has " + MB$(freeB) + " free. If the data doesn't compress, the archive needs up to " + MB$(need) + "."
        If cliMode = 0 Then
            If _MessageBox("GPUZip - low disk space", "The target drive has " + MB$(freeB) + " free." + Chr$(10) + "If this data doesn't compress, the archive could need " + MB$(need) + "." + Chr$(10) + Chr$(10) + "Start anyway?", "yesno", "warning", 0) <> 1 Then
                LogMsg "  Cancelled - pick a drive with more room."
                Exit Sub
            End If
        End If
    End If

    cFo = gz_FCreate(outFile + Chr$(0))
    If cFo < 0 Then LogMsg "Cannot create " + outFile + ": " + ErrText$(cFo): Exit Sub
    hdr.magic = "GPZ1"
    hdr.ver = 1
    hdr.chunkSize = CS
    hdr.codec = 1
    hdr.fileCount = 0
    hdr.chunkCount = 0
    hdr.streamSize = 0
    hdr.chunkTabOfs = 0
    hdr.fileTabOfs = 0
    e = WriteStr&(cFo, HeaderStr$)
    If e Then LogMsg "Write failed: " + ErrText$(e): AbortArchive outFile: Exit Sub
    cPos = 64

    cFill = 0: cChunkBase = 0: cPacked = 0: cRawDone = 0: cTime = 0: cancelReq = 0
    streamPos = 0
    ClearStats
    For i = 0 To entCount - 1
        If entType(i) = 0 Then
            entOfs(i) = streamPos
            fh = gz_FOpenR(srcFolder + "/" + entPath(i) + Chr$(0))
            If fh < 0 Then
                LogMsg "  skipped (" + ErrText$(fh) + "): " + entPath(i)
                entType(i) = 2
                skipCnt = skipCnt + 1
            Else
                remain = entSize(i)
                crc = 0
                got = 0
                Do While remain > 0
                    take = BATCH_BYTES - cFill
                    If take > remain Then take = remain
                    If take > READ_PIECE Then take = READ_PIECE
                    got = gz_FRead(fh, inM.OFFSET + cFill, take)
                    If got <= 0 Then Exit Do
                    crc = gz_Crc32(inM.OFFSET + cFill, got, crc)
                    cFill = cFill + got
                    remain = remain - got
                    streamPos = streamPos + got
                    If cFill = BATCH_BYTES Then
                        If CompressFlush% = 0 Then failed = -1: Exit Do
                    End If
                    ShowBusy "Compressing " + ClipL$(entPath(i), 80) + RatioNote$, streamPos, total
                    If cancelReq Then failed = -1: Exit Do
                Loop
                e = gz_FClose(fh)
                If got < 0 Then LogMsg "  read error (" + ErrText$(got) + "), kept the part before it: " + entPath(i)
                If remain > 0 And got >= 0 Then LogMsg "  file got shorter while reading: " + entPath(i)
                entSize(i) = entSize(i) - remain
                entCrc(i) = crc
                fileCnt = fileCnt + 1
                If warned = 0 And cRawDone >= 1073741824 Then
                    If cPacked * 100 > cRawDone * 95 Then
                        LogMsg "  note: this data is barely compressing (" + Fmt2$(Pct#(cPacked, cRawDone)) + "% after " + MB$(cRawDone) + ")"
                        warned = -1
                    End If
                End If
            End If
            If failed Then Exit For
        End If
    Next
    If failed = 0 And cFill > 0 Then
        If CompressFlush% = 0 Then failed = -1
    End If
    If failed Then
        AbortArchive outFile
        If cancelReq Then LogMsg "Cancelled - partial archive removed." Else LogMsg "Compression stopped - partial archive removed."
        cancelReq = 0
        Exit Sub
    End If

    ' chunk table
    hdr.chunkTabOfs = cPos
    c = 0
    Do While c < cChunkBase
        cnt = cChunkBase - c
        If cnt > 65536 Then cnt = 65536
        s = Space$(cnt * 4)
        For k = 0 To cnt - 1
            Mid$(s, k * 4 + 1, 4) = MKL$(chunkSz(c + k))
        Next
        e = WriteStr&(cFo, s)
        If e Then failed = e: Exit Do
        cPos = cPos + Len(s)
        c = c + cnt
    Loop

    ' file table (skipped entries left out)
    hdr.fileTabOfs = cPos
    hdr.fileCount = 0
    ft = ""
    For i = 0 To entCount - 1
        If failed Then Exit For
        If entType(i) <> 2 Then
            ft = ft + MKI$(Len(entPath(i))) + entPath(i) + _MK$(_Integer64, entSize(i)) + _MK$(_Integer64, entOfs(i)) + _MK$(_Unsigned Long, entCrc(i)) + Chr$(entType(i))
            hdr.fileCount = hdr.fileCount + 1
        End If
        If Len(ft) > 1048576 Or i = entCount - 1 Then
            e = WriteStr&(cFo, ft)
            If e Then failed = e: Exit For
            cPos = cPos + Len(ft)
            ft = ""
        End If
    Next

    ' real header, then flush everything to the drive
    If failed = 0 Then
        hdr.streamSize = streamPos
        hdr.chunkCount = cChunkBase
        s = HeaderStr$
        _MemPut tmpM, tmpM.OFFSET, s
        failed = gz_FWriteAt(cFo, tmpM.OFFSET, 64, 0)
    End If
    If failed = 0 Then failed = gz_FSync(cFo)
    If failed Then
        LogMsg "Write failed: " + ErrText$(failed)
        AbortArchive outFile
        LogMsg "Compression stopped - partial archive removed."
        Exit Sub
    End If
    e = gz_FClose(cFo)

    secs = Elapsed#(t0)
    archivePath = outFile
    LogMsg "Done: " + outFile
    LogMsg "  " + MB$(streamPos) + " -> " + MB$(cPos) + "  (" + Fmt2$(Pct#(cPos, streamPos)) + "% of original)   files: " + _Trim$(Str$(fileCnt)) + "   skipped: " + _Trim$(Str$(skipCnt))
    LogMsg "  compress stage " + Fmt2$(cTime) + " s = " + Rate$(streamPos, cTime) + "   whole job " + Fmt2$(secs) + " s = " + Rate$(streamPos, secs)
    LogMsg "  work split: " + WorkerSplit$
End Sub

Function Pct# (a As _Integer64, b As _Integer64)
    If b <= 0 Then Pct# = 0 Else Pct# = a * 100# / b
End Function

' closes and deletes a half-written archive
Sub AbortArchive (f As String)
    Dim e As Long
    e = gz_FClose(cFo)
    e = gz_FDelete(f + Chr$(0))
End Sub

Function ErrText$ (code As Long)
    Dim buf As String, l As Long
    buf = Space$(256)
    l = gz_ErrText(code, buf, 256)
    ErrText$ = Left$(buf, l)
End Function

' running compression ratio for the progress line
Function RatioNote$
    If cRawDone > 0 Then RatioNote$ = "   ratio " + Fmt2$(Pct#(cPacked, cRawDone)) + "%" Else RatioNote$ = ""
End Function

' 64-byte archive header built from hdr
Function HeaderStr$
    HeaderStr$ = hdr.magic + MKL$(hdr.ver) + MKL$(hdr.chunkSize) + MKL$(hdr.codec) + MKL$(hdr.fileCount) + MKL$(hdr.chunkCount) + _MK$(_Integer64, hdr.streamSize) + _MK$(_Integer64, hdr.chunkTabOfs) + _MK$(_Integer64, hdr.fileTabOfs) + String$(16, 0)
End Function

' writes a string through the scratch buffer; returns errno (0 = ok)
Function WriteStr& (fd As Long, s As String)
    If Len(s) = 0 Then WriteStr& = 0: Exit Function
    If Len(s) > tmpM.SIZE Then
        _MemFree tmpM
        tmpM = _MemNew(Len(s))
    End If
    _MemPut tmpM, tmpM.OFFSET, s
    WriteStr& = gz_FWrite(fd, tmpM.OFFSET, Len(s))
End Function

' Compresses the filled part of inM and appends the result to the archive.
Function CompressFlush%
    Dim nc As Long, i As Long, packed As _Integer64, t0 As Double, e As Long
    nc = gz_ChunkCount(cFill, CS)
    t0 = Timer(0.001)
    packed = gz_CompressBatch(inM.OFFSET, cFill, CS, outM.OFFSET, _Offset(bsz(0)), gmode)
    cTime = cTime + Elapsed#(t0)
    If packed < 0 Then LogLibError "compress": CompressFlush% = 0: Exit Function
    AddStats
    e = gz_FWrite(cFo, outM.OFFSET, packed)
    If e Then LogMsg "Write failed: " + ErrText$(e): CompressFlush% = 0: Exit Function
    cPos = cPos + packed
    For i = 0 To nc - 1
        chunkSz(cChunkBase + i) = bsz(i)
    Next
    cChunkBase = cChunkBase + nc
    cPacked = cPacked + packed
    cRawDone = cRawDone + cFill
    cFill = 0
    CompressFlush% = -1
End Function

'=============================================================================
' archive index
'=============================================================================
Function ReadArchiveIndex% (a As String)
    Dim fa As Long, c As Long, cnt As Long, k As Long, s As String, i As Long, pl As _Unsigned Integer
    ReadArchiveIndex% = 0
    If _FileExists(a) = 0 Then LogMsg "Archive not found: " + a: Exit Function
    fa = gz_FOpenR(a + Chr$(0))
    If fa < 0 Then LogMsg "Cannot open " + a + ": " + ErrText$(fa): Exit Function
    fa = gz_FClose(fa)
    fa = FreeFile
    Open a For Binary Access Read As #fa
    If LOF(fa) < 64 Then Close #fa: LogMsg "Not a GPUZip archive (too short).": Exit Function
    Get #fa, 1, hdr
    If hdr.magic <> "GPZ1" Or hdr.ver <> 1 Or hdr.codec <> 1 Or hdr.chunkSize <> CS Then
        Close #fa
        LogMsg "Not a GPZ1 archive (or unsupported version)."
        Exit Function
    End If
    If hdr.chunkCount <> gz_ChunkCount(hdr.streamSize, CS) Or hdr.fileTabOfs > LOF(fa) Or hdr.chunkTabOfs > hdr.fileTabOfs Then
        Close #fa
        LogMsg "Archive header is damaged."
        Exit Function
    End If
    ReDim chunkSz(0 To hdr.chunkCount) As Long
    Seek #fa, hdr.chunkTabOfs + 1
    c = 0
    Do While c < hdr.chunkCount
        cnt = hdr.chunkCount - c
        If cnt > 65536 Then cnt = 65536
        s = Space$(cnt * 4)
        Get #fa, , s
        For k = 0 To cnt - 1
            chunkSz(c + k) = CVL(Mid$(s, k * 4 + 1, 4))
        Next
        c = c + cnt
    Loop
    entCount = hdr.fileCount
    ReDim entPath(0 To entCount) As String
    ReDim entSize(0 To entCount) As _Integer64
    ReDim entOfs(0 To entCount) As _Integer64
    ReDim entCrc(0 To entCount) As _Unsigned Long
    ReDim entType(0 To entCount) As _Byte
    Seek #fa, hdr.fileTabOfs + 1
    For i = 0 To entCount - 1
        Get #fa, , pl
        s = Space$(pl)
        Get #fa, , s
        entPath(i) = s
        Get #fa, , entSize(i)
        Get #fa, , entOfs(i)
        Get #fa, , entCrc(i)
        Get #fa, , entType(i)
    Next
    Close #fa
    LogMsg "Opened " + a + ": " + _Trim$(Str$(entCount)) + " entries, " + MB$(hdr.streamSize) + " raw, " + _Trim$(Str$(hdr.chunkCount)) + " chunks"
    ReadArchiveIndex% = -1
End Function

'=============================================================================
' extract
'=============================================================================
Sub DoExtract (target As String)
    Dim dest As String, fa As Long, c0 As _Integer64, nc As Long, k As Long
    Dim comp As _Integer64, rawLen As _Integer64, s As String, rc As Long
    Dim cur As Long, fh As Long, remain As _Integer64, crc As _Unsigned Long
    Dim ppos As _Integer64, take As _Integer64, bad As Long, skipped As Long
    Dim t0 As Double, tDec As Double, t1 As Double, outPath As String, failed As Long
    Dim written As Long, e As Long, freeB As _Integer64

    If Len(archivePath) = 0 Then PickArchive
    If Len(archivePath) = 0 Then Exit Sub
    If ReadArchiveIndex%(archivePath) = 0 Then Exit Sub
    dest = target
    If Len(dest) = 0 Then dest = _SelectFolderDialog$("Extract into folder", "")
    If Len(dest) = 0 Then Exit Sub
    dest = StripSlash$(dest)
    If gz_MkdirP(dest + Chr$(0)) <> 0 Then LogMsg "Cannot create " + dest: Exit Sub
    freeB = gz_FreeSpace(dest + Chr$(0))
    If freeB >= 0 And freeB < hdr.streamSize + 1048576 Then
        LogMsg "  " + dest + " has " + MB$(freeB) + " free, the files need " + MB$(hdr.streamSize) + "."
        If cliMode Then Exit Sub
        If _MessageBox("GPUZip - low disk space", "That drive has " + MB$(freeB) + " free but the files need " + MB$(hdr.streamSize) + "." + Chr$(10) + Chr$(10) + "Extract anyway?", "yesno", "warning", 0) <> 1 Then Exit Sub
    End If

    t0 = Timer(0.001)
    cancelReq = 0
    fa = FreeFile
    Open archivePath For Binary Access Read As #fa
    Seek #fa, 65
    cur = 0: fh = 0

    c0 = 0
    Do While c0 < hdr.chunkCount
        nc = hdr.chunkCount - c0
        If nc > BATCH_CHUNKS Then nc = BATCH_CHUNKS
        comp = 0
        For k = 0 To nc - 1
            bsz(k) = chunkSz(c0 + k)
            comp = comp + Abs(bsz(k))
        Next
        rawLen = hdr.streamSize - c0 * CS
        If rawLen > nc * CS Then rawLen = nc * CS
        If comp > BATCH_BYTES Then LogMsg "Chunk table is damaged.": failed = -1: Exit Do
        s = Space$(comp)
        Get #fa, , s
        _MemPut inM, inM.OFFSET, s
        t1 = Timer(0.001)
        rc = gz_DecompressBatch(inM.OFFSET, comp, _Offset(bsz(0)), nc, CS, rawLen, outM.OFFSET)
        tDec = tDec + Elapsed#(t1)
        If rc <> 0 Then LogLibError "decompress": failed = -1: Exit Do

        ppos = 0
        Do While ppos < rawLen
            If fh = 0 Then
                cur = OpenNextFile&(cur, dest, fh, skipped, written)
                remain = entSize(cur)
                crc = 0
                If cur >= entCount Then LogMsg "Stream is longer than the file table.": failed = -1: Exit Do
            End If
            take = rawLen - ppos
            If take > remain Then take = remain
            If fh > 0 Then
                e = gz_FWrite(fh, outM.OFFSET + ppos, take)
                If e Then LogMsg "Write failed on " + entPath(cur) + ": " + ErrText$(e): failed = -1: Exit Do
            End If
            crc = gz_Crc32(outM.OFFSET + ppos, take, crc)
            ppos = ppos + take
            remain = remain - take
            If remain = 0 Then
                If fh > 0 Then e = gz_FClose(fh)
                If crc <> entCrc(cur) Then
                    bad = bad + 1
                    LogMsg "  CRC MISMATCH: " + entPath(cur)
                End If
                fh = 0
                cur = cur + 1
            End If
        Loop
        If failed Then Exit Do
        c0 = c0 + nc
        ShowBusy "Extracting " + ClipL$(archivePath, 100), c0 * CS, hdr.streamSize
        If cancelReq Then LogMsg "Cancelled.": failed = -1: Exit Do
    Loop
    Close #fa
    If fh > 0 Then e = gz_FClose(fh)

    ' folders and empty files that come after the last byte of data
    If failed = 0 Then
        Do While cur < entCount
            cur = OpenNextFile&(cur, dest, fh, skipped, written)
            If cur < entCount Then
                LogMsg "Archive ended before " + entPath(cur): failed = -1
                If fh > 0 Then e = gz_FClose(fh)
                Exit Do
            End If
        Loop
    End If
    cancelReq = 0

    If failed Then
        LogMsg "Extraction STOPPED early - files written so far are in " + dest
    Else
        LogMsg "Extracted to " + dest + " in " + Fmt2$(Elapsed#(t0)) + " s  (decompress stage " + Fmt2$(tDec) + " s = " + Rate$(hdr.streamSize, tDec) + ")"
    End If
    LogMsg "  files written: " + _Trim$(Str$(written)) + "   CRC errors: " + _Trim$(Str$(bad)) + "   skipped: " + _Trim$(Str$(skipped))
    If failed = 0 And bad = 0 Then LogMsg "  All files verified OK."
End Sub

' Starting at entry idx: makes folders and empty files, then opens the next file
' that has data. Returns its index (fh = handle, or -1 if its path is unsafe),
' or entCount when nothing with data is left.
Function OpenNextFile& (idx As Long, dest As String, fh As Long, skipped As Long, written As Long)
    Dim i As Long, full As String, h As Long, par As String, e As Long
    i = idx
    fh = 0
    Do While i < entCount
        If SafePath%(entPath(i)) = 0 Then
            skipped = skipped + 1
            LogMsg "  skipped unsafe path: " + entPath(i)
            If entType(i) = 0 And entSize(i) > 0 Then fh = -1: OpenNextFile& = i: Exit Function
        Else
            full = dest + "/" + entPath(i)
            If entType(i) = 1 Then
                If gz_MkdirP(full + Chr$(0)) <> 0 Then LogMsg "  cannot create folder " + full
            Else
                par = ParentDir$(full)
                If Len(par) Then
                    If gz_MkdirP(par + Chr$(0)) <> 0 Then LogMsg "  cannot create folder " + par
                End If
                h = gz_FCreate(full + Chr$(0))
                If h < 0 Then
                    LogMsg "  cannot create (" + ErrText$(h) + "): " + full
                    skipped = skipped + 1
                    If entSize(i) > 0 Then fh = -1: OpenNextFile& = i: Exit Function
                Else
                    written = written + 1
                    If entSize(i) > 0 Then fh = h: OpenNextFile& = i: Exit Function
                    e = gz_FClose(h)
                End If
            End If
        End If
        i = i + 1
    Loop
    OpenNextFile& = entCount
End Function

'=============================================================================
' benchmark: load up to 1 GB of the folder into RAM, then time each mode
'=============================================================================
Sub DoBenchmark
    Dim total As _Integer64, capB As _Integer64, loaded As _Integer64, bm As _MEM
    Dim i As Long, fh As Long, take As _Integer64, got As _Integer64, t0 As Double, tRead As Double, e As Long
    Dim modes(0 To 20) As Long, nm As Long, mi As Long, m As Long
    Dim ppos As _Integer64, sl As _Integer64, packed As _Integer64, packSum As _Integer64
    Dim tc As Double, td As Double, nc As Long, rc As Long, ok As Long
    Dim crcA As _Unsigned Long, crcB As _Unsigned Long, saveMode As Long

    If Len(srcFolder) = 0 Then LogMsg "Pick a source folder first.": Exit Sub
    LogMsg "Benchmark: scanning " + srcFolder
    total = ScanSource&&
    If total <= 0 Then LogMsg "Nothing to benchmark.": Exit Sub
    capB = total
    If capB > BENCH_CAP Then capB = BENCH_CAP
    bm = _MemNew(capB)
    cancelReq = 0

    ' read stage (disk speed)
    t0 = Timer(0.001)
    For i = 0 To entCount - 1
        If entType(i) = 0 And entSize(i) > 0 And loaded < capB Then
            fh = gz_FOpenR(srcFolder + "/" + entPath(i) + Chr$(0))
            If fh < 0 Then
                LogMsg "  skipped (" + ErrText$(fh) + "): " + entPath(i)
            Else
                Do While loaded < capB
                    take = READ_PIECE
                    If take > capB - loaded Then take = capB - loaded
                    got = gz_FRead(fh, bm.OFFSET + loaded, take)
                    If got <= 0 Then Exit Do
                    loaded = loaded + got
                    ShowBusy "Benchmark: reading files into RAM", loaded, capB
                    If cancelReq Then Exit Do
                Loop
                e = gz_FClose(fh)
            End If
            If cancelReq Then Exit For
        End If
    Next
    tRead = Elapsed#(t0)
    If cancelReq Then LogMsg "Cancelled.": _MemFree bm: cancelReq = 0: Exit Sub
    LogMsg "  loaded " + MB$(loaded) + " in " + Fmt2$(tRead) + " s  (disk/cache read " + Rate$(loaded, tRead) + ")"

    ' mode list
    nm = 0
    modes(nm) = -1: nm = nm + 1
    For i = 1 To nGpu
        modes(nm) = i: nm = nm + 1
    Next
    If nGpu >= 2 Then modes(nm) = 0: nm = nm + 1
    If nGpu >= 1 Then modes(nm) = -2: nm = nm + 1

    saveMode = gmode
    LogMsg "  " + PadR$("mode", 20) + PadL$("compress", 16) + PadL$("size", 10) + PadL$("decompress", 16) + "  check   split"
    For mi = 0 To nm - 1
        m = modes(mi)
        gmode = m
        ClearStats
        ppos = 0: packSum = 0: tc = 0: td = 0: ok = -1
        Do While ppos < loaded
            sl = loaded - ppos
            If sl > BATCH_BYTES Then sl = BATCH_BYTES
            nc = gz_ChunkCount(sl, CS)
            t0 = Timer(0.001)
            packed = gz_CompressBatch(bm.OFFSET + ppos, sl, CS, outM.OFFSET, _Offset(bsz(0)), m)
            tc = tc + Elapsed#(t0)
            If packed < 0 Then LogLibError "compress": ok = 0: Exit Do
            AddStats
            t0 = Timer(0.001)
            rc = gz_DecompressBatch(outM.OFFSET, packed, _Offset(bsz(0)), nc, CS, sl, inM.OFFSET)
            td = td + Elapsed#(t0)
            If rc <> 0 Then LogLibError "decompress": ok = 0: Exit Do
            crcA = gz_Crc32(bm.OFFSET + ppos, sl, 0)
            crcB = gz_Crc32(inM.OFFSET, sl, 0)
            If crcA <> crcB Then ok = 0
            packSum = packSum + packed
            ppos = ppos + sl
            ShowBusy "Benchmark: " + ModeName$(m), ppos, loaded
            If cancelReq Then Exit Do
        Loop
        If cancelReq Then Exit For
        If ok Then
            LogMsg "  " + PadR$(ModeName$(m), 20) + PadL$(Rate$(loaded, tc), 16) + PadL$(Fmt2$(Pct#(packSum, loaded)) + "%", 10) + PadL$(Rate$(loaded, td), 16) + "  OK      " + WorkerSplit$
        Else
            LogMsg "  " + PadR$(ModeName$(m), 20) + "  FAILED round-trip check"
        End If
    Next
    gmode = saveMode
    If cancelReq Then LogMsg "Cancelled."
    cancelReq = 0
    LogMsg "  (compress includes PCIe transfers; size = compressed % of original; decompress is CPU)"
    _MemFree bm
End Sub
