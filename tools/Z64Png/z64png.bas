'=======================================================================
' z64pngbatch.bas  -  One PNG per file, batch write and batch read
' Built on QB64Starter ButtonUI + native file dialogs.
' Derived from z64png.bas; identical Z64P v1 container per image.
'
' Each staged file becomes its OWN .png. The container format is
' unchanged, so images written here are readable by the original
' single-file z64png.bas and vice versa.
'
' Byte stream laid across the pixels of each image, in order:
'    0    4   magic "Z64P"
'    4    1   format version (1)
'    5    1   name length (1-255)
'    6    n   original filename INCLUDING its extension
'    6+n  8   original size (_Integer64, little-endian)
'   14+n  ..  raw file bytes, then zero padding to fill the last pixel
'
' Capacity of a w x h image is w * h * 3 bytes.
'
' NOTE ON TYPES: every Dim here uses the "Dim As <type> a, b" form.
' The trailing form "Dim a, b As _Integer64" types only the LAST
' name and silently leaves the rest SINGLE, which loses integer
' precision above 16,777,216 and corrupts payloads over ~16 MB.
'
' Keep ButtonUI.bi and ButtonUI.bm in the same folder as this source.
'=======================================================================

Option _Explicit

'$Include: 'ButtonUI.bi'

Const Z64PVER = 1
Const APPW = 860
Const APPH = 660
Const MAXENT = 512
Const VISROWS = 10
Const MAXPAYLOAD = 67108864 ' 64 MB per file - peak RAM is roughly 3x this

' ---- staging list ----
Dim Shared srcPaths(MAXENT) As String
Dim Shared srcSizes(MAXENT) As _Integer64
Dim Shared resNote(MAXENT) As String
Dim Shared selFlag(MAXENT) As Integer
Dim Shared entCount As Integer
Dim Shared listMode As Integer ' 0 = files to pack, 1 = PNGs to read
Dim Shared topRow As Integer

Dim Shared statusMsg As String
Dim Shared repAction As String
Dim Shared outDirShown As String
Dim Shared As Long repOk, repFail
Dim Shared As _Integer64 repBytes, repPixels

Dim As Integer running, hasReport, hasList, hasSel
Dim As Integer rr, idx, yy
Dim kk As String

Screen _NewImage(APPW, APPH, 32)
_Title "Z64 PNG Disk - Batch"
MouseInit
statusMsg = "Ready. Add files to write PNGs, or add PNGs to read them back."
repAction = ""
outDirShown = ""
listMode = 0
entCount = 0
topRow = 0
running = -1

Do
    _Limit 60
    PollMouse
    Cls , _RGB32(26, 30, 38)

    DrawHeader
    DrawListPanel

    If Button%(30, 92, 160, 36, "Add Files...") Then AddItems 0
    If Button%(200, 92, 160, 36, "Add PNGs...") Then AddItems 1
    hasSel = 0: If AnySelected% Then hasSel = -1
    If ButtonEx%(370, 92, 130, 36, "Remove Sel", hasSel) Then RemoveSelected
    hasList = 0: If entCount > 0 Then hasList = -1
    If ButtonEx%(510, 92, 120, 36, "Clear List", hasList) Then ClearList

    Color _RGB32(150, 160, 178)
    If listMode = 0 Then
        _PrintString (648, 104), "mode: FILE -> PNG"
    Else
        _PrintString (648, 104), "mode: PNG -> FILE"
    End If

    ' ---- list rows (plain buttons - no manual hit testing) ----
    For rr = 0 To VISROWS - 1
        idx = topRow + rr
        If idx < entCount Then
            yy = 150 + rr * 25
            If Button%(40, yy, 700, 22, RowLabel$(idx)) Then
                selFlag(idx) = Not selFlag(idx)
            End If
        End If
    Next rr

    If Button%(752, 150, 66, 26, "Up") Then
        topRow = topRow - VISROWS
        If topRow < 0 Then topRow = 0
    End If
    If Button%(752, 182, 66, 26, "Down") Then
        If topRow + VISROWS < entCount Then topRow = topRow + VISROWS
    End If
    If ButtonEx%(752, 214, 66, 26, "All", hasList) Then SelectAll
    If ButtonEx%(752, 246, 66, 26, "None", hasList) Then SelectNone

    Color _RGB32(120, 128, 144)
    _PrintString (752, 290), _Trim$(Str$(entCount))
    _PrintString (752, 306), "items"

    ' ---- action row ----
    If ButtonEx%(30, 412, 200, 40, "Write PNGs", CanWrite%) Then DoBatchWrite
    If ButtonEx%(240, 412, 200, 40, "Extract PNGs", CanRead%) Then DoBatchRead
    If repAction = "" Then hasReport = 0 Else hasReport = -1
    If ButtonEx%(450, 412, 150, 40, "Clear Report", hasReport) Then ClearReport
    If Button%(APPW - 110, 412, 80, 40, "Quit") Then running = 0

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
    _PrintString (30, 26), "Z64 PNG DISK - BATCH"
    Color _RGB32(150, 160, 178)
    _PrintString (30, 50), "One PNG per file. Raw bytes in the RGB channels, no payload compression."
    Line (30, 78)-(APPW - 30, 79), _RGB32(60, 68, 84), BF
End Sub


Sub DrawListPanel
    Line (30, 140)-(APPW - 30, 400), _RGB32(20, 24, 30), BF
    Line (30, 140)-(APPW - 30, 400), _RGB32(60, 68, 84), B

    If entCount = 0 Then
        Color _RGB32(110, 118, 134)
        _PrintString (52, 264), "Nothing staged. Add Files... to write, or Add PNGs... to read."
    End If
End Sub


Sub DrawReport
    Dim yy As Integer

    Line (30, 506)-(APPW - 30, 616), _RGB32(20, 24, 30), BF
    Line (30, 506)-(APPW - 30, 616), _RGB32(60, 68, 84), B

    If repAction = "" Then
        Color _RGB32(110, 118, 134)
        _PrintString (52, 556), "Nothing written or read yet."
        Exit Sub
    End If

    yy = 520
    Color _RGB32(150, 200, 160)
    _PrintString (52, yy), repAction
    yy = yy + 26

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Succeeded"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), _Trim$(Str$(repOk))
    If repFail > 0 Then
        Color _RGB32(226, 150, 150)
        _PrintString (260, yy), _Trim$(Str$(repFail)) + " failed"
    End If
    yy = yy + 22

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Payload"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), Commafy$(repBytes) + " bytes"
    yy = yy + 22

    Color _RGB32(150, 160, 178)
    _PrintString (52, yy), "Pixels"
    Color _RGB32(226, 232, 244)
    _PrintString (190, yy), Commafy$(repPixels) + "   (capacity " + Commafy$(repPixels * 3) + " bytes)"

    If outDirShown <> "" Then
        Color _RGB32(120, 128, 144)
        _PrintString (470, 520), "out: " + Right$(outDirShown, 44)
    End If
End Sub


Sub DrawStatus
    Line (0, APPH - 30)-(APPW, APPH), _RGB32(18, 21, 27), BF
    Color _RGB32(170, 180, 196)
    _PrintString (14, APPH - 23), Left$(statusMsg, 104)
End Sub


' Called from inside the byte loops so a large file does not look frozen.
Sub Progress (caption As String, pct As Integer)
    Dim fillw As Long
    fillw = ((APPW - 60) * pct) \ 100
    Line (30, 464)-(APPW - 30, 494), _RGB32(20, 24, 30), BF
    If fillw > 0 Then Line (30, 464)-(30 + fillw, 494), _RGB32(64, 120, 88), BF
    Line (30, 464)-(APPW - 30, 494), _RGB32(60, 68, 84), B
    Color _RGB32(226, 232, 244)
    _PrintString (38, 472), caption + "  " + _Trim$(Str$(pct)) + "%"
    _Display
End Sub


'----------------------------------------------------------- list helpers

Function RowLabel$ (idx As Integer)
    Dim mark As String
    Dim bname As String
    Dim tail As String
    Dim room As Integer

    If selFlag(idx) Then mark = "[x] " Else mark = "[ ] "
    bname = BaseName$(srcPaths(idx))

    If resNote(idx) <> "" Then
        tail = resNote(idx)
    Else
        tail = Commafy$(srcSizes(idx))
    End If

    room = 84 - Len(mark) - Len(tail) - 2
    If room < 8 Then room = 8
    If Len(bname) > room Then bname = Left$(bname, room - 3) + "..."
    RowLabel$ = mark + bname + Space$(room - Len(bname) + 2) + tail
End Function


Function AnySelected%
    Dim i As Integer
    AnySelected% = 0
    For i = 0 To entCount - 1
        If selFlag(i) Then AnySelected% = -1: Exit Function
    Next i
End Function


Function CanWrite%
    CanWrite% = 0
    If listMode = 0 And entCount > 0 Then CanWrite% = -1
End Function


Function CanRead%
    CanRead% = 0
    If listMode = 1 And entCount > 0 Then CanRead% = -1
End Function


Sub SelectAll
    Dim i As Integer
    For i = 0 To entCount - 1
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
        resNote(i) = ""
        selFlag(i) = 0
    Next i
    entCount = 0
    topRow = 0
    statusMsg = "List cleared."
End Sub


Sub RemoveSelected
    Dim As Integer i, keep

    keep = 0
    For i = 0 To entCount - 1
        If selFlag(i) = 0 Then
            srcPaths(keep) = srcPaths(i)
            srcSizes(keep) = srcSizes(i)
            resNote(keep) = resNote(i)
            keep = keep + 1
        End If
    Next i

    For i = keep To entCount - 1
        srcPaths(i) = ""
        srcSizes(i) = 0
        resNote(i) = ""
    Next i

    entCount = keep
    SelectNone
    If topRow >= entCount Then topRow = 0
    statusMsg = "Removed. " + _Trim$(Str$(entCount)) + " item(s) staged."
End Sub


Sub AddItems (wantPng As Integer)
    Dim picked As String
    Dim one As String
    Dim p As Long
    Dim fh As Long
    Dim added As Integer

    If wantPng Then
        picked = _OpenFileDialog$("Select PNGs to read", "", "*.png", "PNG image", -1)
    Else
        picked = _OpenFileDialog$("Select files to store in PNGs", "", "*.*", "All files", -1)
    End If
    ResyncMouse
    If picked = "" Then statusMsg = "Nothing added.": Exit Sub

    ' Switching direction clears the list - the two modes are not mixable.
    If listMode <> wantPng Then
        ClearList
        listMode = wantPng
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
                resNote(entCount) = ""
                selFlag(entCount) = 0
                entCount = entCount + 1
                added = added + 1
            End If
        End If
    Loop While picked <> ""

    statusMsg = "Added " + _Trim$(Str$(added)) + " item(s). " + _Trim$(Str$(entCount)) + " staged."
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


' Never overwrite: append _2, _3 ... before the extension.
Function UniquePath$ (ddir As String, bname As String)
    Dim stem As String
    Dim ext As String
    Dim cand As String
    Dim k As Integer

    cand = ddir + bname
    If _FileExists(cand) = 0 Then UniquePath$ = cand: Exit Function

    stem = StripExt$(bname)
    ext = Mid$(bname, Len(stem) + 1)
    For k = 2 To 9999
        cand = ddir + stem + "_" + _Trim$(Str$(k)) + ext
        If _FileExists(cand) = 0 Then UniquePath$ = cand: Exit Function
    Next k

    UniquePath$ = ""
End Function


Function Commafy$ (n As _Integer64)
    Dim As String s, r
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


' Little-endian 8-byte encode / decode, so the header is portable.
Function I64ToStr$ (n As _Integer64)
    Dim s As String
    Dim i As Integer
    Dim v As _Integer64
    s = Space$(8)
    v = n
    For i = 1 To 8
        Mid$(s, i, 1) = Chr$(v And 255)
        v = v \ 256
    Next i
    I64ToStr$ = s
End Function


Function StrToI64&& (s As String)
    Dim As _Integer64 v, mul
    Dim i As Integer
    v = 0
    mul = 1
    For i = 1 To 8
        v = v + Asc(s, i) * mul
        mul = mul * 256
    Next i
    StrToI64&& = v
End Function


Sub ResyncMouse
    Do While _MouseInput
    Loop
    gMouse.held = 0
    gMouse.prevHeld = 0
    gMouse.clicked = 0
End Sub


Sub ClearReport
    Dim i As Integer
    repAction = ""
    repOk = 0
    repFail = 0
    repBytes = 0
    repPixels = 0
    outDirShown = ""
    For i = 0 To entCount - 1
        resNote(i) = ""
    Next i
    statusMsg = "Report cleared."
End Sub


'----------------------------------------------------------- engine

' Returns "" on success, otherwise an error message.
' pxOut comes back with the pixel count of the image written.
Function WritePngOne$ (srcPath As String, dstPath As String, caption As String, pxOut As _Integer64)
    Dim fin As Long
    Dim As _Integer64 origSize, total, pixels, p, sidx, bidx
    Dim As _Integer64 w, h
    Dim nlen As _Unsigned _Byte
    Dim As String raw, stream, bufr, bname
    Dim img As Long
    Dim mi As _MEM
    Dim As Integer lastPct, pct

    WritePngOne$ = ""
    pxOut = 0

    If _FileExists(srcPath) = 0 Then WritePngOne$ = "Source not found": Exit Function

    fin = FreeFile
    Open srcPath For Binary As #fin
    origSize = LOF(fin)
    If origSize > MAXPAYLOAD Then
        Close #fin
        WritePngOne$ = "Over 64 MB limit"
        Exit Function
    End If
    raw = Space$(origSize)
    If origSize > 0 Then Get #fin, 1, raw
    Close #fin

    bname = BaseName$(srcPath)
    If Len(bname) > 255 Then bname = Right$(bname, 255)
    nlen = Len(bname)

    stream = "Z64P" + Chr$(Z64PVER) + Chr$(nlen) + bname + I64ToStr$(origSize) + raw
    raw = ""

    total = Len(stream)
    pixels = (total + 2) \ 3
    w = Int(Sqr(pixels)) + 1
    h = (pixels + w - 1) \ w
    If h < 1 Then h = 1

    ' Alpha pre-filled to 255 across the whole buffer, so the loop below
    ' only has to touch the three colour channels.
    bufr = String$(w * h * 4, Chr$(255))

    lastPct = -1
    For p = 1 To pixels
        bidx = (p - 1) * 4 + 1
        sidx = (p - 1) * 3 + 1
        ' 32-bit surfaces are BGRA in memory: B at +0, G at +1, R at +2.
        If sidx + 2 <= total Then Mid$(bufr, bidx, 1) = Chr$(Asc(stream, sidx + 2)) Else Mid$(bufr, bidx, 1) = Chr$(0)
        If sidx + 1 <= total Then Mid$(bufr, bidx + 1, 1) = Chr$(Asc(stream, sidx + 1)) Else Mid$(bufr, bidx + 1, 1) = Chr$(0)
        If sidx <= total Then Mid$(bufr, bidx + 2, 1) = Chr$(Asc(stream, sidx)) Else Mid$(bufr, bidx + 2, 1) = Chr$(0)

        If (p And 262143) = 0 Then
            pct = Int((p * 100) / pixels)
            If pct <> lastPct Then Progress caption + " writing pixels", pct: lastPct = pct
        End If
    Next p
    stream = ""

    img = _NewImage(w, h, 32)
    If img >= -1 Then WritePngOne$ = "Image alloc failed": Exit Function

    mi = _MemImage(img)
    _MemPut mi, mi.OFFSET, bufr
    _MemFree mi
    bufr = ""

    Progress caption + " encoding PNG", 100
    If _FileExists(dstPath) Then Kill dstPath
    _SaveImage dstPath, img
    _FreeImage img

    pxOut = w * h
End Function


' Returns "" on success. writtenPath holds the extracted file path,
' bytesOut the payload size, pxOut the source image pixel count.
Function ReadPngOne$ (srcPath As String, outDir As String, caption As String, writtenPath As String, bytesOut As _Integer64, pxOut As _Integer64)
    Dim fout As Long
    Dim As _Integer64 origSize, capacity, pixels, p, sidx, bidx, hdrLen
    Dim As _Integer64 w, h
    Dim nlen As _Unsigned _Byte
    Dim As String stream, bufr, bname, dst
    Dim img As Long
    Dim mi As _MEM
    Dim As Integer lastPct, pct

    ReadPngOne$ = ""
    writtenPath = ""
    bytesOut = 0
    pxOut = 0

    If _FileExists(srcPath) = 0 Then ReadPngOne$ = "Image not found": Exit Function

    img = _LoadImage(srcPath, 32)
    If img >= -1 Then ReadPngOne$ = "Could not load image": Exit Function

    w = _Width(img)
    h = _Height(img)
    pixels = w * h
    capacity = pixels * 3
    pxOut = pixels

    If capacity < 15 Then _FreeImage img: ReadPngOne$ = "Too small for a container": Exit Function

    bufr = Space$(pixels * 4)
    mi = _MemImage(img)
    _MemGet mi, mi.OFFSET, bufr
    _MemFree mi
    _FreeImage img

    stream = Space$(capacity)
    lastPct = -1
    For p = 1 To pixels
        bidx = (p - 1) * 4 + 1
        sidx = (p - 1) * 3 + 1
        Mid$(stream, sidx, 1) = Chr$(Asc(bufr, bidx + 2)) '     R
        Mid$(stream, sidx + 1, 1) = Chr$(Asc(bufr, bidx + 1)) ' G
        Mid$(stream, sidx + 2, 1) = Chr$(Asc(bufr, bidx)) '     B

        If (p And 262143) = 0 Then
            pct = Int((p * 100) / pixels)
            If pct <> lastPct Then Progress caption + " reading pixels", pct: lastPct = pct
        End If
    Next p
    bufr = ""

    If Left$(stream, 4) <> "Z64P" Then ReadPngOne$ = "No Z64P container": Exit Function
    If Asc(stream, 5) <> Z64PVER Then ReadPngOne$ = "Bad version": Exit Function

    nlen = Asc(stream, 6)
    If nlen = 0 Then ReadPngOne$ = "Empty name in header": Exit Function

    ' Defensive: the writer stores a basename, but never trust an
    ' image on disk to contain a path-free name.
    bname = BaseName$(Mid$(stream, 7, nlen))
    If bname = "" Then ReadPngOne$ = "Bad name in header": Exit Function

    hdrLen = 14 + nlen
    origSize = StrToI64&&(Mid$(stream, 7 + nlen, 8))

    If origSize < 0 Or origSize > capacity - hdrLen Then
        ReadPngOne$ = "Size out of range"
        Exit Function
    End If

    dst = UniquePath$(outDir, bname)
    If dst = "" Then ReadPngOne$ = "Could not find a free name": Exit Function

    fout = FreeFile
    Open dst For Binary As #fout
    If origSize > 0 Then
        stream = Mid$(stream, hdrLen + 1, origSize)
        Put #fout, 1, stream
    End If
    Close #fout

    writtenPath = dst
    bytesOut = origSize
End Function


'----------------------------------------------------------- actions

Function EnsureOutDir$ (anchorPath As String)
    Dim d As String
    d = DirOf$(anchorPath) + "z64png_out\"
    If _DirExists(d) = 0 Then MkDir d
    If _DirExists(d) = 0 Then EnsureOutDir$ = "" Else EnsureOutDir$ = d
End Function


Sub DoBatchWrite
    Dim As Integer i
    Dim As Long okc, failc
    Dim As _Integer64 totBytes, totPix, px
    Dim As String outDir, dst, r, cap

    If entCount = 0 Then statusMsg = "Nothing staged.": Exit Sub

    outDir = EnsureOutDir$(srcPaths(0))
    If outDir = "" Then statusMsg = "Could not create z64png_out folder.": Exit Sub

    okc = 0: failc = 0: totBytes = 0: totPix = 0

    For i = 0 To entCount - 1
        cap = "File " + _Trim$(Str$(i + 1)) + "/" + _Trim$(Str$(entCount))
        dst = UniquePath$(outDir, StripExt$(BaseName$(srcPaths(i))) + ".png")
        If dst = "" Then
            resNote(i) = "FAIL name"
            failc = failc + 1
        Else
            r = WritePngOne$(srcPaths(i), dst, cap, px)
            If r <> "" Then
                resNote(i) = "FAIL " + r
                failc = failc + 1
            Else
                resNote(i) = "OK " + BaseName$(dst)
                okc = okc + 1
                totBytes = totBytes + srcSizes(i)
                totPix = totPix + px
            End If
        End If
    Next i

    repAction = "WRITTEN"
    repOk = okc
    repFail = failc
    repBytes = totBytes
    repPixels = totPix
    outDirShown = outDir

    If failc = 0 Then
        statusMsg = "Wrote " + _Trim$(Str$(okc)) + " PNG(s) to z64png_out"
    Else
        statusMsg = "Wrote " + _Trim$(Str$(okc)) + ", " + _Trim$(Str$(failc)) + " failed - see the list"
    End If
End Sub


Sub DoBatchRead
    Dim As Integer i
    Dim As Long okc, failc
    Dim As _Integer64 totBytes, totPix, bytesOut, px
    Dim As String outDir, outp, r, cap

    If entCount = 0 Then statusMsg = "Nothing staged.": Exit Sub

    outDir = EnsureOutDir$(srcPaths(0))
    If outDir = "" Then statusMsg = "Could not create z64png_out folder.": Exit Sub

    okc = 0: failc = 0: totBytes = 0: totPix = 0

    For i = 0 To entCount - 1
        cap = "PNG " + _Trim$(Str$(i + 1)) + "/" + _Trim$(Str$(entCount))
        r = ReadPngOne$(srcPaths(i), outDir, cap, outp, bytesOut, px)
        If r <> "" Then
            resNote(i) = "FAIL " + r
            failc = failc + 1
        Else
            resNote(i) = "OK " + BaseName$(outp)
            okc = okc + 1
            totBytes = totBytes + bytesOut
            totPix = totPix + px
        End If
    Next i

    repAction = "EXTRACTED"
    repOk = okc
    repFail = failc
    repBytes = totBytes
    repPixels = totPix
    outDirShown = outDir

    If failc = 0 Then
        statusMsg = "Extracted " + _Trim$(Str$(okc)) + " file(s) to z64png_out"
    Else
        statusMsg = "Extracted " + _Trim$(Str$(okc)) + ", " + _Trim$(Str$(failc)) + " failed - see the list"
    End If
End Sub


'$Include: 'ButtonUI.bm'
