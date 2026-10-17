
Option _Explicit
'$Include:'ButtonUI.bi'
'=======================================================================
' PngToIco.bas - QB64Starter Image -> ICO Converter (multi-size)
'
' Loads an image and writes a Windows .ico containing several sizes in
' one file, so Windows can pick a crisp version for each context
' (16 px in lists, 32 on shortcuts, 256 for high-DPI) instead of
' scaling a single image down and blurring it.
'
' HOW IT WORKS
'   _SaveImage writes one image per file, so the multi-size container is
'   assembled by hand: each selected size is scaled into a square buffer
'   and saved to a temp PNG, those bytes are read back, then a 6-byte
'   ICONDIR + one 16-byte ICONDIRENTRY per size + the PNG payloads are
'   written out as the .ico.
'
' Note: 256 x 256 is the ICO format ceiling - the entry's width/height
' are single bytes (0 means 256), so larger sizes cannot be encoded.
' Feed it a big source image (512+) and let it downscale.
'
' Uses ButtonUI for the interface and the native file dialogs.
'=======================================================================



Const SCRW = 700, SCRH = 480
Const BOXX = 24, BOXY = 104, BOXW = 304, BOXH = 304 ' preview box (multiple of 16)
Const CTLX = 358 '                                    right-hand control column
Const NSIZES = 6 '                                    how many standard sizes we offer
Const TMPPNG = "_pngtoico_tmp.png"

' --- shared state ---
Dim Shared pngPath As String
Dim Shared pngW As Long, pngH As Long
Dim Shared previewImg As Long
Dim Shared sizeList(0 To NSIZES - 1) As Integer '     the offered icon sizes
Dim Shared sizeOn(0 To NSIZES - 1) As Integer '       -1 when that size is included
Dim Shared statusMsg As String, statusErr As Integer

' --- palette ---
Dim Shared cBg As _Unsigned Long, cTitle As _Unsigned Long
Dim Shared cLabel As _Unsigned Long, cText As _Unsigned Long
Dim Shared cGood As _Unsigned Long, cWarn As _Unsigned Long
Dim Shared cBoxBorder As _Unsigned Long, cCheckA As _Unsigned Long, cCheckB As _Unsigned Long
Dim Shared cOnFace As _Unsigned Long


'=======================================================================
' STARTUP
'=======================================================================
Screen _NewImage(SCRW, SCRH, 32)
_Title "Image to ICO Converter"
_PrintMode _KeepBackground

MouseInit
InitColors
InitSizes
previewImg = -1
statusMsg = "Load an image to begin."
statusErr = 0


'=======================================================================
' MAIN LOOP
'=======================================================================
Do
    _Limit 60
    If InKey$ = Chr$(27) Then Exit Do
    PollMouse

    Cls , cBg
    _PrintMode _KeepBackground

    Color cTitle
    _PrintString (24, 18), "IMAGE  ->  ICO  CONVERTER"

    If Button%(24, 52, 150, 36, "Load image...") Then LoadSource
    If ButtonEx%(190, 52, 170, 36, "Save as ICO...", CanSave%) Then SaveIco

    DrawPreview
    DrawInfo
    DrawSizePicker

    If statusErr Then Color cWarn Else Color cLabel
    _PrintString (24, SCRH - 34), statusMsg

    If Button%(SCRW - 128, SCRH - 42, 104, 30, "Quit") Then Exit Do

    _Display
Loop

If previewImg < -1 Then _FreeImage previewImg
System


'=======================================================================
' PREVIEW + INFO
'=======================================================================
Sub DrawPreview
    Dim xx As Integer, yy As Integer, tone As _Unsigned Long
    For yy = 0 To BOXH - 1 Step 16
        For xx = 0 To BOXW - 1 Step 16
            If ((xx \ 16 + yy \ 16) And 1) = 0 Then tone = cCheckA Else tone = cCheckB
            Line (BOXX + xx, BOXY + yy)-(BOXX + xx + 16, BOXY + yy + 16), tone, BF
        Next xx
    Next yy

    If previewImg < -1 Then
        Dim iw As Long, ih As Long, s As Single
        Dim dw As Long, dh As Long, dx As Long, dy As Long
        iw = _Width(previewImg): ih = _Height(previewImg)
        s = BOXW / iw
        If BOXH / ih < s Then s = BOXH / ih
        dw = iw * s: dh = ih * s
        dx = BOXX + (BOXW - dw) \ 2: dy = BOXY + (BOXH - dh) \ 2
        _PutImage (dx, dy)-(dx + dw, dy + dh), previewImg
    End If

    Line (BOXX, BOXY)-(BOXX + BOXW, BOXY + BOXH), cBoxBorder, B
End Sub


Sub DrawInfo
    If Len(pngPath) = 0 Then
        Color cLabel
        _PrintString (CTLX, 112), "No image loaded yet."
        _PrintString (CTLX, 136), "Click 'Load image...' to pick"
        _PrintString (CTLX, 154), "a source. 512 px or larger is"
        _PrintString (CTLX, 172), "ideal - it downscales cleanly."
        Exit Sub
    End If

    Color cLabel: _PrintString (CTLX, 112), "File:"
    Color cText: _PrintString (CTLX + 56, 112), BaseName$(pngPath)
    Color cLabel: _PrintString (CTLX, 134), "Source:"
    Color cText: _PrintString (CTLX + 70, 134), _Trim$(Str$(pngW)) + " x " + _Trim$(Str$(pngH))

    Color cLabel
    _PrintString (CTLX, 168), "Sizes to include:"

    ' summary + warnings under the picker
    Dim n As Integer
    n = CountSelected%
    If n = 0 Then
        Color cWarn
        _PrintString (CTLX, 306), "Pick at least one size."
    Else
        Color cText
        _PrintString (CTLX, 306), _Trim$(Str$(n)) + " size(s) in one .ico"
    End If

    If AnyUpscale% Then
        Color cWarn
        _PrintString (CTLX, 330), "Some sizes exceed the source"
        _PrintString (CTLX, 348), "and will look soft."
    ElseIf n > 0 Then
        Color cGood
        _PrintString (CTLX, 330), "All sizes downscale cleanly."
    End If
End Sub


Sub DrawSizePicker
    ' Two rows of three toggles; included sizes read green.
    If SizeToggle%(CTLX, 190, 0) Then sizeOn(0) = Not sizeOn(0)
    If SizeToggle%(CTLX + 66, 190, 1) Then sizeOn(1) = Not sizeOn(1)
    If SizeToggle%(CTLX + 132, 190, 2) Then sizeOn(2) = Not sizeOn(2)
    If SizeToggle%(CTLX, 226, 3) Then sizeOn(3) = Not sizeOn(3)
    If SizeToggle%(CTLX + 66, 226, 4) Then sizeOn(4) = Not sizeOn(4)
    If SizeToggle%(CTLX + 132, 226, 5) Then sizeOn(5) = Not sizeOn(5)

    ' quick presets
    If Button%(CTLX, 266, 84, 30, "Standard") Then SelectStandard
    If Button%(CTLX + 90, 266, 50, 30, "All") Then SelectAll
    If Button%(CTLX + 146, 266, 50, 30, "None") Then SelectNone
End Sub


Function SizeToggle% (x As Integer, y As Integer, idx As Integer)
    Dim savedFace As _Unsigned Long
    savedFace = uiFace
    If sizeOn(idx) Then uiFace = cOnFace
    SizeToggle% = Button%(x, y, 60, 30, _Trim$(Str$(sizeList(idx))))
    uiFace = savedFace
End Function


'=======================================================================
' LOAD / SAVE
'=======================================================================
Sub LoadSource
    Dim p As String
    p = _OpenFileDialog$("Select an image", "", "*.png|*.jpg|*.bmp|*.gif", "Image files", 0)
    If p = "" Then Exit Sub ' cancelled

    Dim h As Long
    h = _LoadImage(p, 32)
    If h < -1 Then
        If previewImg < -1 Then _FreeImage previewImg
        previewImg = h
        pngW = _Width(previewImg)
        pngH = _Height(previewImg)
        pngPath = p
        SelectStandard
        TrimUpscales
        SetStatus "Loaded " + BaseName$(p), 0
    Else
        SetStatus "Couldn't load that image.", -1
    End If
End Sub


Sub SaveIco
    If Len(pngPath) = 0 Then SetStatus "Load an image first.", -1: Exit Sub
    If CountSelected% = 0 Then SetStatus "Pick at least one size.", -1: Exit Sub

    Dim d As String
    d = _SaveFileDialog$("Save ICO as", "", "*.ico", "Icon files")
    If d = "" Then Exit Sub
    If LCase$(Right$(d, 4)) <> ".ico" Then d = d + ".ico"

    WriteMultiIco d
End Sub


Sub WriteMultiIco (destPath As String)
    Dim payload(0 To NSIZES - 1) As String
    Dim pxOf(0 To NSIZES - 1) As Integer
    Dim i As Integer, n As Integer

    ' --- render each selected size to PNG bytes ---
    n = 0
    For i = 0 To NSIZES - 1
        If sizeOn(i) Then
            payload(n) = PngBytesAt$(sizeList(i))
            If Len(payload(n)) = 0 Then
                SetStatus "Couldn't render the " + _Trim$(Str$(sizeList(i))) + " px image.", -1
                Exit Sub
            End If
            pxOf(n) = sizeList(i)
            n = n + 1
        End If
    Next i

    ' --- assemble the container ---
    Dim o As Integer
    Dim uReserved As _Unsigned Integer, uType As _Unsigned Integer, uCount As _Unsigned Integer
    Dim bW As _Unsigned _Byte, bH As _Unsigned _Byte, bCC As _Unsigned _Byte, bRes As _Unsigned _Byte
    Dim wPlanes As _Unsigned Integer, wBits As _Unsigned Integer
    Dim dwBytes As _Unsigned Long, dwOffset As _Unsigned Long
    Dim runningOffset As Long

    uReserved = 0: uType = 1: uCount = n
    bCC = 0: bRes = 0
    wPlanes = 1: wBits = 32

    ' First image starts after the directory: 6 + 16 bytes per entry.
    runningOffset = 6 + 16 * n

    o = FreeFile
    Open destPath For Output As #o: Close #o ' truncate any existing file
    Open destPath For Binary As #o

    Put #o, , uReserved '  ICONDIR
    Put #o, , uType
    Put #o, , uCount

    For i = 0 To n - 1 '   one ICONDIRENTRY per size
        If pxOf(i) >= 256 Then bW = 0 Else bW = pxOf(i)
        bH = bW
        dwBytes = Len(payload(i))
        dwOffset = runningOffset
        Put #o, , bW
        Put #o, , bH
        Put #o, , bCC
        Put #o, , bRes
        Put #o, , wPlanes
        Put #o, , wBits
        Put #o, , dwBytes
        Put #o, , dwOffset
        runningOffset = runningOffset + Len(payload(i))
    Next i

    For i = 0 To n - 1 '   then the PNG payloads, in the same order
        Put #o, , payload(i)
    Next i

    Close #o

    SetStatus "Saved " + BaseName$(destPath) + "  (" + _Trim$(Str$(n)) + " sizes)", 0
End Sub


Function PngBytesAt$ (px As Integer)
    ' Scale the source into a square px-by-px buffer (aspect preserved,
    ' transparent padding), save it as a temp PNG, and hand back its bytes.
    Dim scaled As Long, origDest As Long
    Dim iw As Long, ih As Long, sc As Single
    Dim dw As Long, dh As Long, dx As Long, dy As Long

    scaled = _NewImage(px, px, 32)
    If scaled >= -1 Then PngBytesAt$ = "": Exit Function

    origDest = _Dest
    _Dest scaled
    Cls , _RGBA32(0, 0, 0, 0) ' transparent background
    _Dest origDest

    iw = _Width(previewImg): ih = _Height(previewImg)
    sc = px / iw
    If px / ih < sc Then sc = px / ih ' contain: fit the longest side
    dw = iw * sc: dh = ih * sc
    If dw < 1 Then dw = 1
    If dh < 1 Then dh = 1
    dx = (px - dw) \ 2: dy = (px - dh) \ 2
    _PutImage (dx, dy)-(dx + dw, dy + dh), previewImg, scaled

    If _FileExists(TMPPNG) Then Kill TMPPNG
    _SaveImage TMPPNG, scaled
    _FreeImage scaled

    PngBytesAt$ = ReadFileBytes$(TMPPNG)
    If _FileExists(TMPPNG) Then Kill TMPPNG
End Function


Function ReadFileBytes$ (fpath As String)
    Dim f As Integer, sz As Long, buf As String
    If Not _FileExists(fpath) Then ReadFileBytes$ = "": Exit Function
    f = FreeFile
    Open fpath For Binary As #f
    sz = LOF(f)
    If sz > 0 Then
        buf = Space$(sz)
        Get #f, 1, buf
    Else
        buf = ""
    End If
    Close #f
    ReadFileBytes$ = buf
End Function


'=======================================================================
' SIZE SELECTION
'=======================================================================
Sub InitSizes
    sizeList(0) = 16
    sizeList(1) = 32
    sizeList(2) = 48
    sizeList(3) = 64
    sizeList(4) = 128
    sizeList(5) = 256
    SelectStandard
End Sub


Sub SelectStandard
    ' 16 / 32 / 48 / 256 covers lists, shortcuts and high-DPI.
    Dim i As Integer
    For i = 0 To NSIZES - 1
        sizeOn(i) = 0
    Next i
    sizeOn(0) = -1
    sizeOn(1) = -1
    sizeOn(2) = -1
    sizeOn(5) = -1
End Sub


Sub SelectAll
    Dim i As Integer
    For i = 0 To NSIZES - 1
        sizeOn(i) = -1
    Next i
End Sub


Sub SelectNone
    Dim i As Integer
    For i = 0 To NSIZES - 1
        sizeOn(i) = 0
    Next i
End Sub


Sub TrimUpscales
    ' Drop any selected size bigger than the source, so nothing is blown
    ' up; keep at least the smallest so there is always something to save.
    Dim i As Integer, srcMin As Long
    srcMin = pngW
    If pngH < srcMin Then srcMin = pngH
    For i = 0 To NSIZES - 1
        If sizeList(i) > srcMin Then sizeOn(i) = 0
    Next i
    If CountSelected% = 0 Then sizeOn(0) = -1
End Sub


Function CountSelected%
    Dim i As Integer, n As Integer
    n = 0
    For i = 0 To NSIZES - 1
        If sizeOn(i) Then n = n + 1
    Next i
    CountSelected% = n
End Function


Function AnyUpscale%
    Dim i As Integer, srcMin As Long
    If Len(pngPath) = 0 Then AnyUpscale% = 0: Exit Function
    srcMin = pngW
    If pngH < srcMin Then srcMin = pngH
    For i = 0 To NSIZES - 1
        If sizeOn(i) And sizeList(i) > srcMin Then AnyUpscale% = -1: Exit Function
    Next i
    AnyUpscale% = 0
End Function


Function CanSave%
    If Len(pngPath) = 0 Then CanSave% = 0: Exit Function
    If CountSelected% = 0 Then CanSave% = 0: Exit Function
    CanSave% = -1
End Function


'=======================================================================
' HELPERS
'=======================================================================
Sub SetStatus (msg As String, isErr As Integer)
    statusMsg = msg
    statusErr = isErr
End Sub


Function BaseName$ (p As String)
    Dim i As Integer, ch As String
    For i = Len(p) To 1 Step -1
        ch = Mid$(p, i, 1)
        If ch = "\" Or ch = "/" Then BaseName$ = Mid$(p, i + 1): Exit Function
    Next i
    BaseName$ = p
End Function


Sub InitColors
    cBg = _RGB32(24, 26, 32)
    cTitle = _RGB32(240, 244, 252)
    cLabel = _RGB32(150, 160, 180)
    cText = _RGB32(232, 236, 244)
    cGood = _RGB32(120, 200, 150)
    cWarn = _RGB32(226, 170, 110)
    cBoxBorder = _RGB32(70, 78, 96)
    cCheckA = _RGB32(52, 56, 66)
    cCheckB = _RGB32(40, 44, 54)
    cOnFace = _RGB32(40, 110, 92)
End Sub

'$Include:'ButtonUI.bm'
