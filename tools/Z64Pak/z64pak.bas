'=======================================================================
' z64pak2.bas  -  Multi-file uncompressed .pak archiver (QB64-PE)
' Built on QB64Starter ButtonUI + native file dialogs.
'
' Store format "Z64K" v1 - front-loaded table of contents, so listing
' and single-file extraction are seeks, not scans:
'
'   0   4   magic "Z64K"
'   4   1   format version (1)
'   5   4   entry count (Long)
'   9   ..  TOC, one record per entry:
'             1  name length (1-255)
'             n  file name, no path
'             8  size   (_Integer64, little endian)
'             8  offset (_Integer64, absolute from start of file)
'   ..  ..  payload blobs, in TOC order
'
' Payloads are copied through a 1 MB buffer, so peak RAM stays flat no
' matter how large the archive gets. There is no size limit here.
'
' Keep ButtonUI.bi and ButtonUI.bm in the same folder as this source.
'=======================================================================

Option _Explicit

'$Include: 'ButtonUI.bi'

Const Z64KVER = 1
Const APPW = 820
Const APPH = 620
Const MAXFILES = 4096
Const CHUNK = 1048576 '  1 MB streaming buffer
Const LISTROWS = 12

Dim Shared statusMsg As String
Dim Shared gCount As Long
Dim Shared gPaths(1 To MAXFILES) As String
Dim Shared gNames(1 To MAXFILES) As String
Dim Shared gSizes(1 To MAXFILES) As _Integer64
Dim Shared gTop As Long '  first visible row in the list
Dim Shared gTotal As _Integer64

Dim As Integer running, canPack, canScroll
Dim kk As String

Screen _NewImage(APPW, APPH, 32)
_Title "Z64 PAK Builder"
MouseInit
statusMsg = "Ready. Add files, then create a .pak."
gCount = 0
gTop = 1
gTotal = 0
running = -1

Do
    _Limit 60
    PollMouse
    Cls , _RGB32(26, 30, 38)

    DrawHeader

    If gCount > 0 Then canPack = -1 Else canPack = 0

    If Button%(30, 112, 180, 44, "Add Files...") Then AddFiles
    If ButtonEx%(220, 112, 180, 44, "Create PAK...", canPack) Then DoPack
    If Button%(410, 112, 180, 44, "Extract PAK...") Then DoExtract
    If ButtonEx%(600, 112, 180, 44, "Clear List", canPack) Then ClearList

    DrawList

    If gCount > LISTROWS Then canScroll = -1 Else canScroll = 0
    If ButtonEx%(APPW - 78, 190, 48, 34, "Up", canScroll) Then ScrollList -LISTROWS
    If ButtonEx%(APPW - 78, 232, 48, 34, "Dn", canScroll) Then ScrollList LISTROWS

    DrawTotals
    DrawStatus

    If Button%(APPW - 130, APPH - 62, 100, 34, "Quit") Then running = 0

    _Display

    kk = InKey$
    If kk = Chr$(27) Then running = 0
Loop While running

System


'----------------------------------------------------------- drawing

Sub DrawHeader
    Color _RGB32(236, 240, 248)
    _PrintString (30, 32), "Z64 PAK BUILDER"
    Color _RGB32(150, 160, 178)
    _PrintString (30, 56), "Flat multi-file container. Stored, never compressed."
    Line (30, 88)-(APPW - 30, 89), _RGB32(60, 68, 84), BF
End Sub


Sub DrawList
    Dim As Long i, row, shown
    Dim yy As Integer
    Dim nm As String

    Line (30, 180)-(APPW - 90, 180 + LISTROWS * 22 + 12), _RGB32(20, 24, 30), BF
    Line (30, 180)-(APPW - 90, 180 + LISTROWS * 22 + 12), _RGB32(60, 68, 84), B

    If gCount = 0 Then
        Color _RGB32(110, 118, 134)
        _PrintString (48, 180 + (LISTROWS * 22) \ 2), "No files queued. Use Add Files."
        Exit Sub
    End If

    shown = 0
    For row = 0 To LISTROWS - 1
        i = gTop + row
        If i > gCount Then Exit For
        yy = 192 + row * 22

        Color _RGB32(110, 118, 134)
        _PrintString (44, yy), Right$("    " + _Trim$(Str$(i)), 4)

        nm = gNames(i)
        If Len(nm) > 46 Then nm = Left$(nm, 43) + "..."
        Color _RGB32(226, 232, 244)
        _PrintString (92, yy), nm

        Color _RGB32(150, 160, 178)
        _PrintString (APPW - 90 - 8 - 8 * Len(Commafy$(gSizes(i))), yy), Commafy$(gSizes(i))
        shown = shown + 1
    Next row
End Sub


Sub DrawTotals
    Dim yy As Integer
    yy = 180 + LISTROWS * 22 + 34

    Color _RGB32(150, 160, 178)
    _PrintString (30, yy), "Files"
    Color _RGB32(226, 232, 244)
    _PrintString (140, yy), _Trim$(Str$(gCount))

    Color _RGB32(150, 160, 178)
    _PrintString (280, yy), "Total"
    Color _RGB32(226, 232, 244)
    _PrintString (390, yy), Commafy$(gTotal) + " bytes"
End Sub


Sub DrawStatus
    Line (0, APPH - 30)-(APPW, APPH), _RGB32(18, 21, 27), BF
    Color _RGB32(170, 180, 196)
    _PrintString (14, APPH - 23), Left$(statusMsg, 98)
End Sub


Sub Progress (caption As String, pct As Integer)
    Dim fillw As Long
    Dim yy As Integer
    yy = APPH - 110
    fillw = ((APPW - 60) * pct) \ 100
    Line (30, yy)-(APPW - 30, yy + 28), _RGB32(20, 24, 30), BF
    If fillw > 0 Then Line (30, yy)-(30 + fillw, yy + 28), _RGB32(64, 120, 88), BF
    Line (30, yy)-(APPW - 30, yy + 28), _RGB32(60, 68, 84), B
    Color _RGB32(226, 232, 244)
    _PrintString (40, yy + 7), Left$(caption + "  " + _Trim$(Str$(pct)) + "%", 90)
    _Display
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


Sub ScrollList (delta As Long)
    gTop = gTop + delta
    If gTop > gCount - LISTROWS + 1 Then gTop = gCount - LISTROWS + 1
    If gTop < 1 Then gTop = 1
End Sub


Sub ClearList
    gCount = 0
    gTop = 1
    gTotal = 0
    statusMsg = "List cleared."
End Sub


' Copy nbytes from the current position of fin to the current position
' of fout, through a fixed buffer. Peak RAM stays at CHUNK.
Sub CopyStream (fin As Long, fout As Long, nbytes As _Integer64)
    Dim bufr As String
    Dim As _Integer64 left2go, take
    left2go = nbytes
    Do While left2go > 0
        If left2go > CHUNK Then take = CHUNK Else take = left2go
        bufr = Space$(take)
        Get #fin, , bufr
        Put #fout, , bufr
        left2go = left2go - take
    Loop
End Sub


'----------------------------------------------------------- list building

Sub AddOne (ppath As String)
    Dim fh As Long
    Dim ssize As _Integer64
    Dim i As Long

    If gCount >= MAXFILES Then statusMsg = "List is full (" + _Trim$(Str$(MAXFILES)) + " files).": Exit Sub
    If _FileExists(ppath) = 0 Then Exit Sub

    For i = 1 To gCount
        If gPaths(i) = ppath Then Exit Sub '  already queued
    Next i

    fh = FreeFile
    Open ppath For Binary As #fh
    ssize = LOF(fh)
    Close #fh

    gCount = gCount + 1
    gPaths(gCount) = ppath
    gNames(gCount) = BaseName$(ppath)
    gSizes(gCount) = ssize
    gTotal = gTotal + ssize
End Sub


Sub AddFiles
    Dim sel As String, one As String
    Dim p As Long
    Dim before As Long

    before = gCount
    sel = _OpenFileDialog$("Add files to the archive", "", "*.*", "All files", -1)
    ResyncMouse
    If sel = "" Then statusMsg = "Nothing added.": Exit Sub

    Do
        p = InStr(sel, "|")
        If p = 0 Then
            one = sel
            sel = ""
        Else
            one = Left$(sel, p - 1)
            sel = Mid$(sel, p + 1)
        End If
        If one <> "" Then AddOne one
    Loop While sel <> ""

    statusMsg = "Added " + _Trim$(Str$(gCount - before)) + " file(s). " + _Trim$(Str$(gCount)) + " queued."
End Sub


'----------------------------------------------------------- engine

' Returns "" on success, otherwise an error message.
Function PackPak$ (dstPath As String)
    Dim As Long i, fin, fout
    Dim As _Integer64 tocLen, dataStart, ofs, donebytes
    Dim cnt As Long
    Dim toc As String, magic As String * 4
    Dim ver As _Unsigned _Byte
    Dim pct As Integer

    PackPak$ = ""
    If gCount = 0 Then PackPak$ = "Nothing to pack.": Exit Function

    ' TOC length is known from the names alone, so offsets can be final
    ' on the first pass. No back-patching needed.
    tocLen = 0
    For i = 1 To gCount
        tocLen = tocLen + 1 + Len(gNames(i)) + 16
    Next i
    dataStart = 9 + tocLen

    toc = ""
    ofs = dataStart
    For i = 1 To gCount
        toc = toc + Chr$(Len(gNames(i))) + gNames(i) + I64ToStr$(gSizes(i)) + I64ToStr$(ofs)
        ofs = ofs + gSizes(i)
    Next i

    magic = "Z64K"
    ver = Z64KVER
    cnt = gCount

    If _FileExists(dstPath) Then Kill dstPath
    fout = FreeFile
    Open dstPath For Binary As #fout
    Put #fout, 1, magic
    Put #fout, , ver
    Put #fout, , cnt
    Put #fout, , toc

    donebytes = 0
    For i = 1 To gCount
        If _FileExists(gPaths(i)) = 0 Then
            Close #fout
            PackPak$ = "File vanished during pack: " + gNames(i)
            Exit Function
        End If

        fin = FreeFile
        Open gPaths(i) For Binary As #fin
        If gSizes(i) > 0 Then CopyStream fin, fout, gSizes(i)
        Close #fin

        donebytes = donebytes + gSizes(i)
        If gTotal > 0 Then pct = Int((donebytes * 100) / gTotal) Else pct = 100
        Progress "Packing " + gNames(i), pct
    Next i

    Close #fout
End Function


' Extracts every entry into outDir. emsg comes back "" on success.
Sub ExtractPak (srcPath As String, outDir As String, ccount As Long, emsg As String)
    Dim As Long fin, fout, i
    Dim As _Integer64 ssize, ofs, archLen, donebytes, grand
    Dim cnt As Long
    Dim magic As String * 4
    Dim ver As _Unsigned _Byte
    Dim nlen As _Unsigned _Byte
    Dim nm As String, dst As String
    Dim entName(1 To MAXFILES) As String
    Dim entSize(1 To MAXFILES) As _Integer64
    Dim entOfs(1 To MAXFILES) As _Integer64
    Dim pct As Integer

    emsg = ""
    ccount = 0

    If _FileExists(srcPath) = 0 Then emsg = "Archive not found.": Exit Sub

    fin = FreeFile
    Open srcPath For Binary As #fin
    archLen = LOF(fin)
    If archLen < 9 Then Close #fin: emsg = "File is too small to be a Z64K archive.": Exit Sub

    Get #fin, 1, magic
    If magic <> "Z64K" Then Close #fin: emsg = "Not a Z64K archive (bad magic).": Exit Sub

    Get #fin, , ver
    If ver <> Z64KVER Then Close #fin: emsg = "Unsupported archive version.": Exit Sub

    Get #fin, , cnt
    If cnt < 1 Or cnt > MAXFILES Then Close #fin: emsg = "Entry count out of range.": Exit Sub

    ' Read the TOC.
    grand = 0
    For i = 1 To cnt
        Get #fin, , nlen
        If nlen = 0 Then Close #fin: emsg = "Bad TOC entry (empty name).": Exit Sub
        nm = Space$(nlen)
        Get #fin, , nm
        entName(i) = nm

        nm = Space$(8): Get #fin, , nm: ssize = StrToI64&&(nm)
        entSize(i) = ssize
        nm = Space$(8): Get #fin, , nm: ofs = StrToI64&&(nm)
        entOfs(i) = ofs

        If ssize < 0 Or ofs < 9 Or ofs + ssize > archLen Then
            Close #fin
            emsg = "TOC entry " + _Trim$(Str$(i)) + " points outside the archive."
            Exit Sub
        End If
        grand = grand + ssize
    Next i

    If _DirExists(outDir) = 0 Then MkDir outDir

    donebytes = 0
    For i = 1 To cnt
        dst = outDir + entName(i)
        If _FileExists(dst) Then
            dst = outDir + StripExt$(entName(i)) + "_x" + _Trim$(Str$(i)) + Mid$(entName(i), Len(StripExt$(entName(i))) + 1)
        End If
        If _FileExists(dst) Then Kill dst

        Seek #fin, entOfs(i) + 1
        fout = FreeFile
        Open dst For Binary As #fout
        If entSize(i) > 0 Then CopyStream fin, fout, entSize(i)
        Close #fout

        donebytes = donebytes + entSize(i)
        If grand > 0 Then pct = Int((donebytes * 100) / grand) Else pct = 100
        Progress "Extracting " + entName(i), pct
        ccount = ccount + 1
    Next i

    Close #fin
End Sub


'----------------------------------------------------------- actions

Sub DoPack
    Dim dst As String, r As String
    Dim startDir As String

    If gCount > 0 Then startDir = DirOf$(gPaths(1)) Else startDir = ""

    dst = _SaveFileDialog$("Save archive as", startDir + "archive.pak", "*.pak", "Z64 PAK archive")
    ResyncMouse
    If dst = "" Then statusMsg = "Pack cancelled.": Exit Sub
    If LCase$(Right$(dst, 4)) <> ".pak" Then dst = dst + ".pak"

    statusMsg = "Packing..."
    r = PackPak$(dst)
    If r <> "" Then
        statusMsg = r
    Else
        statusMsg = "Wrote " + BaseName$(dst) + " - " + _Trim$(Str$(gCount)) + " files, " + Commafy$(gTotal) + " bytes"
    End If
End Sub


Sub DoExtract
    Dim src As String, outDir As String, emsg As String
    Dim ccount As Long

    src = _OpenFileDialog$("Select a .pak archive", "", "*.pak", "Z64 PAK archive")
    ResyncMouse
    If src = "" Then statusMsg = "Extract cancelled.": Exit Sub

    ' Extract beside the archive, into a folder named after it.
    outDir = DirOf$(src) + StripExt$(BaseName$(src)) + "_files\"

    statusMsg = "Extracting..."
    ExtractPak src, outDir, ccount, emsg
    If emsg <> "" Then
        statusMsg = emsg
    Else
        statusMsg = "Extracted " + _Trim$(Str$(ccount)) + " file(s) to " + StripExt$(BaseName$(src)) + "_files"
    End If
End Sub


'$Include: 'ButtonUI.bm'
