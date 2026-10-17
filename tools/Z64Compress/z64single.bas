'=======================================================================
' z64single.bas  -  Single-file one-chunk deflate packer (QB64-PE)
' Built on QB64Starter ButtonUI + native file dialogs.
'
' Container format "Z64F" v1:
'    0    4   magic "Z64F"
'    4    1   format version (1)
'    5    1   name length (1-255)
'    6    n   original filename INCLUDING its extension
'    6+n  8   original uncompressed size (_Integer64)
'   14+n  ..  raw _Deflate$ payload
'
' Keep ButtonUI.bi and ButtonUI.bm in the same folder as this source.
'=======================================================================

Option _Explicit

'$Include: 'ButtonUI.bi'

Const Z64VER = 1
Const APPW = 760
Const APPH = 460

Dim Shared statusMsg As String
Dim Shared repName As String
Dim Shared repAction As String
Dim Shared As _Integer64 repOrig, repPacked

Dim As Integer running, hasReport
Dim kk As String

Screen _NewImage(APPW, APPH, 32)
_Title "Z64 Single-File Packer"
MouseInit
statusMsg = "Ready. Pick a file to pack, or a .z64 to restore."
repAction = ""
running = -1

Do
    _Limit 60
    PollMouse
    Cls , _RGB32(26, 30, 38)

    DrawHeader
    DrawPanel

    If Button%(40, 118, 210, 46, "Pack File...") Then DoPack
    If Button%(275, 118, 210, 46, "Unpack .z64...") Then DoUnpack

    If repAction = "" Then hasReport = 0 Else hasReport = -1
    If ButtonEx%(510, 118, 210, 46, "Clear", hasReport) Then ClearReport

    DrawReport
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
    _PrintString (40, 34), "Z64 SINGLE-FILE PACKER"
    Color _RGB32(150, 160, 178)
    _PrintString (40, 58), "One-chunk deflate. Original filename is stored inside the archive."
    Line (40, 90)-(APPW - 40, 91), _RGB32(60, 68, 84), BF
End Sub


Sub DrawPanel
    Line (40, 190)-(APPW - 40, 372), _RGB32(20, 24, 30), BF
    Line (40, 190)-(APPW - 40, 372), _RGB32(60, 68, 84), B
End Sub


Sub DrawReport
    Dim pct As Double
    Dim yy As Integer
    Dim saved As _Integer64

    If repAction = "" Then
        Color _RGB32(110, 118, 134)
        _PrintString (62, 268), "No archive processed yet."
        Exit Sub
    End If

    yy = 212
    Color _RGB32(150, 200, 160)
    _PrintString (62, yy), repAction
    yy = yy + 30

    Color _RGB32(150, 160, 178)
    _PrintString (62, yy), "File"
    Color _RGB32(226, 232, 244)
    _PrintString (200, yy), repName
    yy = yy + 24

    Color _RGB32(150, 160, 178)
    _PrintString (62, yy), "Original"
    Color _RGB32(226, 232, 244)
    _PrintString (200, yy), Commafy$(repOrig) + " bytes"
    yy = yy + 24

    Color _RGB32(150, 160, 178)
    _PrintString (62, yy), "Compressed"
    Color _RGB32(226, 232, 244)
    _PrintString (200, yy), Commafy$(repPacked) + " bytes"
    yy = yy + 24

    If repOrig > 0 Then
        pct = (repPacked / repOrig) * 100
        saved = repOrig - repPacked
        Color _RGB32(150, 160, 178)
        _PrintString (62, yy), "Ratio"
        Color _RGB32(226, 232, 244)
        _PrintString (200, yy), Left$(_Trim$(Str$(pct)) + "      ", 5) + " %  of original    (saved " + Commafy$(saved) + ")"
    End If
End Sub


Sub DrawStatus
    Line (0, APPH - 30)-(APPW, APPH), _RGB32(18, 21, 27), BF
    Color _RGB32(170, 180, 196)
    _PrintString (14, APPH - 23), Left$(statusMsg, 90)
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
    repName = ""
    repOrig = 0
    repPacked = 0
    statusMsg = "Cleared."
End Sub


'----------------------------------------------------------- engine

' Returns "" on success, otherwise an error message.
Function PackFile$ (srcPath As String, dstPath As String)
    Dim As Long fin, fout
    Dim origSize As _Integer64
    Dim As _Unsigned _Byte ver, nlen
    Dim magic As String * 4
    Dim raw As String, packed As String, bname As String

    PackFile$ = ""

    If _FileExists(srcPath) = 0 Then
        PackFile$ = "Source file not found."
        Exit Function
    End If

    fin = FreeFile
    Open srcPath For Binary As #fin
    origSize = LOF(fin)

    If origSize > 1500000000 Then
        Close #fin
        PackFile$ = "File too large for one-chunk mode (limit ~1.5 GB)."
        Exit Function
    End If

    raw = Space$(origSize)
    If origSize > 0 Then Get #fin, 1, raw
    Close #fin

    packed = _Deflate$(raw)
    raw = ""

    bname = BaseName$(srcPath)
    If Len(bname) > 255 Then bname = Right$(bname, 255)
    nlen = Len(bname)
    magic = "Z64F"
    ver = Z64VER

    If _FileExists(dstPath) Then Kill dstPath
    fout = FreeFile
    Open dstPath For Binary As #fout
    Put #fout, 1, magic
    Put #fout, , ver
    Put #fout, , nlen
    Put #fout, , bname
    Put #fout, , origSize
    If Len(packed) > 0 Then Put #fout, , packed
    Close #fout

    repAction = "PACKED"
    repName = bname
    repOrig = origSize
    repPacked = Len(packed)
End Function


' emsg comes back "" on success; writtenPath holds the restored file path.
Sub UnpackFile (srcPath As String, outDir As String, writtenPath As String, emsg As String)
    Dim As Long fin, fout
    Dim As _Integer64 origSize, payloadLen
    Dim As _Unsigned _Byte ver, nlen
    Dim magic As String * 4
    Dim raw As String, packed As String, bname As String, dst As String

    emsg = ""
    writtenPath = ""

    If _FileExists(srcPath) = 0 Then emsg = "Archive not found.": Exit Sub

    fin = FreeFile
    Open srcPath For Binary As #fin

    If LOF(fin) < 15 Then Close #fin: emsg = "File is too small to be a Z64F container.": Exit Sub

    Get #fin, 1, magic
    If magic <> "Z64F" Then Close #fin: emsg = "Not a Z64F container (bad magic).": Exit Sub

    Get #fin, , ver
    If ver <> Z64VER Then Close #fin: emsg = "Unsupported format version.": Exit Sub

    Get #fin, , nlen
    If nlen = 0 Then Close #fin: emsg = "Bad header (empty name).": Exit Sub

    bname = Space$(nlen)
    Get #fin, , bname
    Get #fin, , origSize

    payloadLen = LOF(fin) - (14 + nlen)
    If payloadLen < 0 Then Close #fin: emsg = "Truncated archive.": Exit Sub

    packed = Space$(payloadLen)
    If payloadLen > 0 Then Get #fin, , packed
    Close #fin

    raw = _Inflate$(packed, origSize)

    If Len(raw) <> origSize Then
        emsg = "Size mismatch after inflate - archive may be corrupt."
        Exit Sub
    End If

    dst = outDir + bname
    If _FileExists(dst) Then
        dst = outDir + StripExt$(bname) + "_restored" + Mid$(bname, Len(StripExt$(bname)) + 1)
    End If

    If _FileExists(dst) Then Kill dst
    fout = FreeFile
    Open dst For Binary As #fout
    If Len(raw) > 0 Then Put #fout, 1, raw
    Close #fout

    writtenPath = dst
    repAction = "RESTORED"
    repName = BaseName$(dst)
    repOrig = origSize
    repPacked = payloadLen
End Sub


'----------------------------------------------------------- actions

Sub DoPack
    Dim src As String, dst As String, r As String

    src = _OpenFileDialog$("Select a file to pack", "", "*.*", "All files")
    ResyncMouse
    If src = "" Then statusMsg = "Pack cancelled.": Exit Sub

    dst = _SaveFileDialog$("Save archive as", DirOf$(src) + StripExt$(BaseName$(src)) + ".z64", "*.z64", "Z64 archive")
    ResyncMouse
    If dst = "" Then statusMsg = "Pack cancelled.": Exit Sub
    If LCase$(Right$(dst, 4)) <> ".z64" Then dst = dst + ".z64"

    statusMsg = "Packing..."
    r = PackFile$(src, dst)
    If r <> "" Then
        statusMsg = r
    Else
        statusMsg = "Wrote " + BaseName$(dst)
    End If
End Sub


Sub DoUnpack
    Dim src As String, outp As String, emsg As String

    src = _OpenFileDialog$("Select a .z64 archive", "", "*.z64", "Z64 archive")
    ResyncMouse
    If src = "" Then statusMsg = "Unpack cancelled.": Exit Sub

    statusMsg = "Inflating..."
    UnpackFile src, DirOf$(src), outp, emsg
    If emsg <> "" Then
        statusMsg = emsg
    Else
        statusMsg = "Restored to " + BaseName$(outp)
    End If
End Sub


'$Include: 'ButtonUI.bm'
