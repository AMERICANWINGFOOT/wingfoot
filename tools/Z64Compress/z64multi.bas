'=======================================================================
' z64multi.bas  -  Multi-file deflate archiver (QB64-PE)
' Built on QB64Starter ButtonUI + native file dialogs.
' Derived from z64single.bas; same deflate engine, front TOC.
'
' Container format "Z64M" v1:
'    0    4   magic "Z64M"
'    4    1   format version (1)
'    5    4   entry count (Long)
'    9    ..  TOC, one variable-length record per entry:
'                1   name length (1-255)
'                n   filename INCLUDING extension, NO path
'                8   original uncompressed size (_Integer64)
'                8   stored/compressed size    (_Integer64)
'                8   absolute payload offset, 1-based (_Integer64)
'                4   CRC32 of the ORIGINAL bytes (_Unsigned Long)
'    ..   ..  payloads, each an independent _Deflate$ blob
'
' Each entry is deflated separately rather than solid. That costs
' some ratio on many small files but keeps peak RAM at the size of
' the LARGEST member, not the sum, and lets one file be extracted
' without touching the others.
'
' Keep ButtonUI.bi and ButtonUI.bm in the same folder as this source.
'=======================================================================

Option _Explicit

'$Include: 'ButtonUI.bi'

Const Z64VER = 1
Const APPW = 860
Const APPH = 640
Const MAXENT = 512
Const VISROWS = 10
Const MAXMEMBER = 536870912 ' 512 MB per-member ceiling for one-chunk mode

' ---- staging list (mode 0) ----
Dim Shared srcPaths(MAXENT) As String
Dim Shared srcSizes(MAXENT) As _Integer64
Dim Shared entCount As Integer

' ---- opened archive (mode 1) ----
Dim Shared arcNames(MAXENT) As String
Dim Shared arcOrig(MAXENT) As _Integer64
Dim Shared arcPacked(MAXENT) As _Integer64
Dim Shared arcOff(MAXENT) As _Integer64
Dim Shared arcCrc(MAXENT) As _Unsigned Long
Dim Shared arcCount As Integer
Dim Shared arcPath As String

Dim Shared selFlag(MAXENT) As Integer
Dim Shared listMode As Integer ' 0 = staging, 1 = archive
Dim Shared topRow As Integer

Dim Shared statusMsg As String
Dim Shared repAction As String
Dim Shared repFiles As Long
Dim Shared As _Integer64 repOrig, repPacked

Dim Shared crcTab(255) As _Unsigned Long

Dim As Integer running, hasReport, hasList, hasSel, hasArc
Dim kk As String
Dim rr As Integer
Dim idx As Integer
Dim yy As Integer

BuildCrcTable

Screen _NewImage(APPW, APPH, 32)
_Title "Z64 Multi-File Packer"
MouseInit
statusMsg = "Ready. Add files to build an archive, or open an existing .z64m."
repAction = ""
listMode = 0
entCount = 0
arcCount = 0
topRow = 0
running = -1

Do
    _Limit 60
    PollMouse
    Cls , _RGB32(26, 30, 38)

    DrawHeader
    DrawListPanel

    ' ---- list management row ----
    If Button%(30, 92, 150, 36, "Add Files...") Then AddFiles
    hasSel = 0: If AnySelected% Then hasSel = -1
    If ButtonEx%(190, 92, 130, 36, "Remove Sel", hasSel) Then RemoveSelected
    hasList = 0: If ListCount% > 0 Then hasList = -1
    If ButtonEx%(330, 92, 120, 36, "Clear List", hasList) Then ClearList
    If Button%(460, 92, 180, 36, "Open Archive...") Then OpenArchive

    Color _RGB32(150, 160, 178)
    If listMode = 0 Then
        _PrintString (656, 104), "mode: BUILD"
    Else
        _PrintString (656, 104), "mode: BROWSE"
    End If

    ' ---- list rows (plain buttons - no manual hit testing) ----
    For rr = 0 To VISROWS - 1
        idx = topRow + rr
        If idx < ListCount% Then
            yy = 150 + rr * 25
            If Button%(40, yy, 700, 22, RowLabel$(idx)) Then
                selFlag(idx) = Not selFlag(idx)
            End If
        End If
    Next rr

    If ButtonEx%(752, 150, 66, 26, "Up", -1) Then
        topRow = topRow - VISROWS
        If topRow < 0 Then topRow = 0
    End If
    If ButtonEx%(752, 182, 66, 26, "Down", -1) Then
        If topRow + VISROWS < ListCount% Then topRow = topRow + VISROWS
    End If
    If ButtonEx%(752, 214, 66, 26, "All", hasList) Then SelectAll
    If ButtonEx%(752, 246, 66, 26, "None", hasList) Then SelectNone

    Color _RGB32(120, 128, 144)
    _PrintString (752, 290), _Trim$(Str$(ListCount%))
    _PrintString (752, 306), "items"

    ' ---- action row ----
    If ButtonEx%(30, 432, 190, 40, "Create Archive", CanBuild%) Then DoCreate
    hasArc = 0: If listMode = 1 And arcCount > 0 Then hasArc = -1
    If ButtonEx%(230, 432, 190, 40, "Extract Selected", ExtractableSel%) Then DoExtract 0
    If ButtonEx%(430, 432, 160, 40, "Extract All", hasArc) Then DoExtract -1
    If repAction = "" Then hasReport = 0 Else hasReport = -1
    If ButtonEx%(600, 432, 140, 40, "Clear Report", hasReport) Then ClearReport
    If Button%(APPW - 110, 432, 80, 40, "Quit") Then running = 0

    DrawReport
    DrawStatus

    _Display

    kk = InKey$
    If kk = Chr$(27) Then running = 0
Loop While running

System


'----------------------------------------------------------- drawing

Sub DrawHeader
    Color _RGB32(236, 240, 248)
    _PrintString (30, 26), "Z64 MULTI-FILE PACKER"
    Color _RGB32(150, 160, 178)
    _PrintString (30, 50), "Per-member deflate. Names stored without paths, CRC32 verified on extract."
    Line (30, 78)-(APPW - 30, 79), _RGB32(60, 68, 84), BF
End Sub


Sub DrawListPanel
    Line (30, 140)-(APPW - 30, 420), _RGB32(20, 24, 30), BF
    Line (30, 140)-(APPW - 30, 420), _RGB32(60, 68, 84), B

    If ListCount% = 0 Then
        Color _RGB32(110, 118, 134)
        If listMode = 0 Then
            _PrintString (52, 274), "No files staged. Press Add Files... to begin."
        Else
            _PrintString (52, 274), "Archive is empty."
        End If
    End If
End Sub


Sub DrawReport
    Dim pct As Double
    Dim saved As _Integer64
    Dim yy As Integer

    Line (30, 486)-(APPW - 30, 596), _RGB32(20, 24, 30), BF
    Line (30, 486)-(APPW - 30, 596), _RGB32(60, 68, 84), B

    If repAction = "" Then
        Color _RGB32(110, 118, 134)
        _PrintString (52, 536), "No archive processed yet."
        Exit Sub
    End If

    yy = 502
    Color _RGB32(150, 200, 160)
    _PrintString (52, yy), repAction
    yy = yy + 26

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Members"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), _Trim$(Str$(repFiles))
    yy = yy + 22

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Original"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), Commafy$(repOrig) + " bytes"
    yy = yy + 22

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Stored"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), Commafy$(repPacked) + " bytes"

    If repOrig > 0 Then
        pct = (repPacked / repOrig) * 100
        saved = repOrig - repPacked
        Color _RGB32(150, 160, 178)
        _PrintString (470, yy), "Ratio"
        Color _RGB32(226, 232, 244)
        _PrintString (540, yy), Left$(_Trim$(Str$(pct)) + "      ", 5) + " %   (saved " + Commafy$(saved) + ")"
    End If
End Sub


Sub DrawStatus
    Line (0, APPH - 30)-(APPW, APPH), _RGB32(18, 21, 27), BF
    Color _RGB32(170, 180, 196)
    _PrintString (14, APPH - 23), Left$(statusMsg, 104)
End Sub


'----------------------------------------------------------- list helpers

Function ListCount%
    If listMode = 0 Then ListCount% = entCount Else ListCount% = arcCount
End Function


Function RowLabel$ (idx As Integer)
    Dim mark As String
    Dim bname As String
    Dim szs As String
    Dim room As Integer

    If selFlag(idx) Then mark = "[x] " Else mark = "[ ] "

    If listMode = 0 Then
        bname = BaseName$(srcPaths(idx))
        szs = Commafy$(srcSizes(idx))
    Else
        bname = arcNames(idx)
        szs = Commafy$(arcOrig(idx)) + " -> " + Commafy$(arcPacked(idx))
    End If

    room = 84 - Len(mark) - Len(szs) - 2
    If Len(bname) > room Then bname = Left$(bname, room - 3) + "..."
    RowLabel$ = mark + bname + Space$(room - Len(bname) + 2) + szs
End Function


Function AnySelected%
    Dim i As Integer
    AnySelected% = 0
    For i = 0 To ListCount% - 1
        If selFlag(i) Then AnySelected% = -1: Exit Function
    Next i
End Function


Function CanBuild%
    CanBuild% = 0
    If listMode = 0 And entCount > 0 Then CanBuild% = -1
End Function


Function ExtractableSel%
    ExtractableSel% = 0
    If listMode = 1 And arcCount > 0 And AnySelected% Then ExtractableSel% = -1
End Function


Sub SelectAll
    Dim i As Integer
    For i = 0 To ListCount% - 1
        selFlag(i) = -1
    Next i
End Sub


Sub SelectNone
    Dim i As Integer
    For i = 0 To MAXENT
        selFlag(i) = 0
    Next i
End Sub


Sub ClearList
    Dim i As Integer
    For i = 0 To MAXENT
        srcPaths(i) = ""
        srcSizes(i) = 0
        arcNames(i) = ""
        selFlag(i) = 0
    Next i
    entCount = 0
    arcCount = 0
    arcPath = ""
    topRow = 0
    listMode = 0
    statusMsg = "List cleared."
End Sub


Sub RemoveSelected
    Dim As Integer i, keep

    If listMode <> 0 Then
        statusMsg = "Remove only applies to the staging list."
        Exit Sub
    End If

    keep = 0
    For i = 0 To entCount - 1
        If selFlag(i) = 0 Then
            srcPaths(keep) = srcPaths(i)
            srcSizes(keep) = srcSizes(i)
            keep = keep + 1
        End If
    Next i

    For i = keep To entCount - 1
        srcPaths(i) = ""
        srcSizes(i) = 0
    Next i

    entCount = keep
    SelectNone
    If topRow >= entCount Then topRow = 0
    statusMsg = "Removed. " + _Trim$(Str$(entCount)) + " file(s) staged."
End Sub


'----------------------------------------------------------- helpers

Function BaseName$ (ppath As String)
    Dim i As Long
    Dim c As String
    For i = Len(ppath) To 1 Step -1
        c = Mid$(ppath, i, 1)
        If c = "\" Or c = "/" Then
            BaseName$ = Mid$(ppath, i + 1)
            Exit Function
        End If
    Next i
    BaseName$ = ppath
End Function


Function DirOf$ (ppath As String)
    Dim i As Long
    Dim c As String
    For i = Len(ppath) To 1 Step -1
        c = Mid$(ppath, i, 1)
        If c = "\" Or c = "/" Then
            DirOf$ = Left$(ppath, i)
            Exit Function
        End If
    Next i
    DirOf$ = ""
End Function


Function StripExt$ (fname As String)
    Dim i As Long
    For i = Len(fname) To 1 Step -1
        If Mid$(fname, i, 1) = "." Then
            StripExt$ = Left$(fname, i - 1)
            Exit Function
        End If
    Next i
    StripExt$ = fname
End Function


Function Commafy$ (n As _Integer64)
    Dim s As String, r As String
    Dim As Long i, c
    s = _Trim$(Str$(n))
    r = ""
    c = 0
    For i = Len(s) To 1 Step -1
        r = Mid$(s, i, 1) + r
        c = c + 1
        If c Mod 3 = 0 And i > 1 Then r = "," + r
    Next i
    Commafy$ = r
End Function


' File dialogs block the event queue; drop any stale press so the
' click that opened the dialog cannot fire a second time on return.
Sub ResyncMouse
    Do While _MouseInput
    Loop
    gMouse.held = 0
    gMouse.prevHeld = 0
    gMouse.clicked = 0
End Sub


Sub ClearReport
    repAction = ""
    repFiles = 0
    repOrig = 0
    repPacked = 0
    statusMsg = "Report cleared."
End Sub


'----------------------------------------------------------- CRC32

Sub BuildCrcTable
    Dim As Long n, k
    Dim c As _Unsigned Long

    For n = 0 To 255
        c = n
        For k = 0 To 7
            If c And 1 Then
                c = &HEDB88320 Xor _ShR(c, 1)
            Else
                c = _ShR(c, 1)
            End If
        Next k
        crcTab(n) = c
    Next n
End Sub


Function Crc32~& (s As String)
    Dim c As _Unsigned Long
    Dim i As Long

    c = &HFFFFFFFF
    For i = 1 To Len(s)
        c = crcTab((c Xor Asc(s, i)) And 255) Xor _ShR(c, 8)
    Next i
    Crc32~& = c Xor &HFFFFFFFF
End Function


'----------------------------------------------------------- engine

Sub AddFiles
    Dim picked As String
    Dim one As String
    Dim p As Long
    Dim fh As Long
    Dim added As Integer

    picked = _OpenFileDialog$("Select files to pack", "", "*.*", "All files", -1)
    ResyncMouse
    If picked = "" Then statusMsg = "Nothing added.": Exit Sub

    If listMode = 1 Then
        arcCount = 0
        arcPath = ""
        SelectNone
        listMode = 0
        topRow = 0
    End If

    added = 0
    Do
        p = InStr(picked, "|")
        If p = 0 Then
            one = picked
            picked = ""
        Else
            one = Left$(picked, p - 1)
            picked = Mid$(picked, p + 1)
        End If

        If one <> "" And entCount <= MAXENT Then
            If _FileExists(one) Then
                fh = FreeFile
                Open one For Binary As #fh
                srcSizes(entCount) = LOF(fh)
                Close #fh
                srcPaths(entCount) = one
                selFlag(entCount) = 0
                entCount = entCount + 1
                added = added + 1
            End If
        End If
    Loop While picked <> ""

    statusMsg = "Added " + _Trim$(Str$(added)) + " file(s). " + _Trim$(Str$(entCount)) + " staged."
End Sub


' Returns "" on success, otherwise an error message.
Function BuildArchive$ (dstPath As String)
    Dim As Long fout, fin
    Dim As Integer i, nlen
    Dim As _Integer64 tocSize, filePos, totOrig, totPacked, origSize
    Dim As _Integer64 packedSize
    Dim As _Unsigned _Byte ver, nb
    Dim magic As String * 4
    Dim cnt As Long
    Dim raw As String, packed As String, bname As String
    Dim offs(MAXENT) As _Integer64
    Dim plens(MAXENT) As _Integer64
    Dim olens(MAXENT) As _Integer64
    Dim crcs(MAXENT) As _Unsigned Long
    Dim names(MAXENT) As String

    BuildArchive$ = ""

    ' --- size the TOC up front so payloads can start at a known offset ---
    tocSize = 0
    For i = 0 To entCount - 1
        bname = BaseName$(srcPaths(i))
        If Len(bname) > 255 Then bname = Right$(bname, 255)
        names(i) = bname
        tocSize = tocSize + 29 + Len(bname)
    Next i

    If _FileExists(dstPath) Then Kill dstPath
    fout = FreeFile
    Open dstPath For Binary As #fout

    magic = "Z64M"
    ver = Z64VER
    cnt = entCount
    Put #fout, 1, magic
    Put #fout, , ver
    Put #fout, , cnt

    filePos = 10 + tocSize ' 1-based offset of the first payload byte
    totOrig = 0
    totPacked = 0

    For i = 0 To entCount - 1
        If _FileExists(srcPaths(i)) = 0 Then
            Close #fout
            BuildArchive$ = "Missing file: " + names(i)
            Exit Function
        End If

        fin = FreeFile
        Open srcPaths(i) For Binary As #fin
        origSize = LOF(fin)

        If origSize > MAXMEMBER Then
            Close #fin
            Close #fout
            BuildArchive$ = "Too large for one-chunk mode: " + names(i)
            Exit Function
        End If

        If origSize > 0 Then
            raw = Space$(origSize)
            Get #fin, 1, raw
        Else
            raw = ""
        End If
        Close #fin

        If origSize > 0 Then
            crcs(i) = Crc32~&(raw)
            packed = _Deflate$(raw)
        Else
            crcs(i) = 0
            packed = ""
        End If
        raw = ""

        packedSize = Len(packed)
        offs(i) = filePos
        plens(i) = packedSize
        olens(i) = origSize

        If packedSize > 0 Then Put #fout, filePos, packed
        packed = ""

        filePos = filePos + packedSize
        totOrig = totOrig + origSize
        totPacked = totPacked + packedSize
    Next i

    ' --- backfill the TOC now that every offset is known ---
    For i = 0 To entCount - 1
        nlen = Len(names(i))
        nb = nlen
        If i = 0 Then
            Put #fout, 10, nb
        Else
            Put #fout, , nb
        End If
        Put #fout, , names(i)
        Put #fout, , olens(i)
        Put #fout, , plens(i)
        Put #fout, , offs(i)
        Put #fout, , crcs(i)
    Next i

    Close #fout

    repAction = "PACKED"
    repFiles = entCount
    repOrig = totOrig
    repPacked = totPacked
End Function


' emsg comes back "" on success.
Sub ReadArchive (srcPath As String, emsg As String)
    Dim As Long fin
    Dim As Integer i, nlen
    Dim As _Unsigned _Byte ver, nb
    Dim magic As String * 4
    Dim cnt As Long
    Dim bname As String
    Dim As _Integer64 totOrig, totPacked

    emsg = ""

    If _FileExists(srcPath) = 0 Then emsg = "Archive not found.": Exit Sub

    fin = FreeFile
    Open srcPath For Binary As #fin

    If LOF(fin) < 9 Then Close #fin: emsg = "File is too small to be a Z64M container.": Exit Sub

    Get #fin, 1, magic
    If magic <> "Z64M" Then Close #fin: emsg = "Not a Z64M container (bad magic).": Exit Sub

    Get #fin, , ver
    If ver <> Z64VER Then Close #fin: emsg = "Unsupported format version.": Exit Sub

    Get #fin, , cnt
    If cnt < 0 Or cnt > MAXENT Then Close #fin: emsg = "Entry count out of range.": Exit Sub

    totOrig = 0
    totPacked = 0

    For i = 0 To cnt - 1
        Get #fin, , nb
        nlen = nb
        If nlen = 0 Then Close #fin: emsg = "Bad TOC (empty name).": Exit Sub

        bname = Space$(nlen)
        Get #fin, , bname

        ' Defensive: the writer stores basenames, but never trust a
        ' file on disk to contain a path-free name.
        arcNames(i) = BaseName$(bname)

        Get #fin, , arcOrig(i)
        Get #fin, , arcPacked(i)
        Get #fin, , arcOff(i)
        Get #fin, , arcCrc(i)

        If arcOff(i) + arcPacked(i) - 1 > LOF(fin) Then
            Close #fin
            emsg = "Truncated archive (entry " + _Trim$(Str$(i + 1)) + ")."
            Exit Sub
        End If

        totOrig = totOrig + arcOrig(i)
        totPacked = totPacked + arcPacked(i)
    Next i

    Close #fin

    arcCount = cnt
    arcPath = srcPath
    listMode = 1
    topRow = 0
    SelectNone

    repAction = "OPENED"
    repFiles = cnt
    repOrig = totOrig
    repPacked = totPacked
End Sub


' Extract one member. Returns "" on success.
Function ExtractOne$ (idx As Integer, outDir As String)
    Dim As Long fin, fout
    Dim packed As String, raw As String, dst As String
    Dim gotCrc As _Unsigned Long

    ExtractOne$ = ""

    fin = FreeFile
    Open arcPath For Binary As #fin

    If arcPacked(idx) > 0 Then
        packed = Space$(arcPacked(idx))
        Get #fin, arcOff(idx), packed
    Else
        packed = ""
    End If
    Close #fin

    If arcOrig(idx) > 0 Then
        raw = _Inflate$(packed, arcOrig(idx))
        If Len(raw) <> arcOrig(idx) Then
            ExtractOne$ = "Size mismatch: " + arcNames(idx)
            Exit Function
        End If
        gotCrc = Crc32~&(raw)
        If gotCrc <> arcCrc(idx) Then
            ExtractOne$ = "CRC mismatch: " + arcNames(idx)
            Exit Function
        End If
    Else
        raw = ""
    End If

    dst = outDir + arcNames(idx)
    If _FileExists(dst) Then Kill dst
    fout = FreeFile
    Open dst For Binary As #fout
    If Len(raw) > 0 Then Put #fout, 1, raw
    Close #fout
End Function


'----------------------------------------------------------- actions

Sub DoCreate
    Dim dst As String, r As String

    If entCount = 0 Then statusMsg = "Nothing staged.": Exit Sub

    dst = _SaveFileDialog$("Save archive as", DirOf$(srcPaths(0)) + "archive.z64m", "*.z64m", "Z64 multi archive")
    ResyncMouse
    If dst = "" Then statusMsg = "Create cancelled.": Exit Sub
    If LCase$(Right$(dst, 5)) <> ".z64m" Then dst = dst + ".z64m"

    statusMsg = "Packing " + _Trim$(Str$(entCount)) + " file(s)..."
    r = BuildArchive$(dst)
    If r <> "" Then
        statusMsg = r
    Else
        statusMsg = "Wrote " + BaseName$(dst)
    End If
End Sub


Sub OpenArchive
    Dim src As String, emsg As String

    src = _OpenFileDialog$("Select a .z64m archive", "", "*.z64m", "Z64 multi archive")
    ResyncMouse
    If src = "" Then statusMsg = "Open cancelled.": Exit Sub

    ReadArchive src, emsg
    If emsg <> "" Then
        statusMsg = emsg
        arcCount = 0
    Else
        statusMsg = "Opened " + BaseName$(src) + " - " + _Trim$(Str$(arcCount)) + " member(s)."
    End If
End Sub


Sub DoExtract (allOfThem As Integer)
    Dim As Integer i, done, failed
    Dim outDir As String, r As String, stem As String

    If listMode <> 1 Or arcCount = 0 Then statusMsg = "Open an archive first.": Exit Sub

    stem = StripExt$(BaseName$(arcPath))
    outDir = DirOf$(arcPath) + stem + "_out\"
    If _DirExists(outDir) = 0 Then MkDir outDir
    If _DirExists(outDir) = 0 Then statusMsg = "Could not create " + stem + "_out": Exit Sub

    done = 0
    failed = 0
    For i = 0 To arcCount - 1
        If allOfThem Or selFlag(i) Then
            r = ExtractOne$(i, outDir)
            If r <> "" Then
                failed = failed + 1
                statusMsg = r
            Else
                done = done + 1
            End If
        End If
    Next i

    repAction = "EXTRACTED"
    repFiles = done

    If failed = 0 Then
        statusMsg = "Extracted " + _Trim$(Str$(done)) + " file(s) to " + stem + "_out"
    Else
        statusMsg = statusMsg + "  (" + _Trim$(Str$(done)) + " ok, " + _Trim$(Str$(failed)) + " failed)"
    End If
End Sub


'$Include: 'ButtonUI.bm'
