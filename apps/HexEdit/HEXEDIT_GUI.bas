'==========================================================
' HEXEDIT_GUI.BAS
' QB64PE Binary Hex Editor -- Graphical (mouse) edition
' Version 4.1
'
' Movable cursor, HEX/ASCII panes, live change highlighting,
' go-to-offset, hex/text search, in-memory edit list, plus:
'
'   * DATA INSPECTOR  - bytes at the cursor decoded live as
'     int8/uint8, int16/uint16 and int32/uint32 (LE + BE),
'     and uint64 LE.
'   * FOLLOW POINTER  - F7 / F8 read a 32/64-bit LE value at
'     the cursor and jump there. Backspace retraces jumps.
'   * FIND NEXT (F9)  - repeats the last search forward from
'     the cursor.
'   * CDIM INSPECTOR (F11) - checks the "CDIM" magic, reads
'     the member count at +4 and lists the pointer table at
'     +72; Enter or double-click jumps to an entry.
'   * Graphical file browser (Open / F6) with a Windows drive
'     bar and a "type path" (T) fallback.
'
' 4.1 cleanup:
'   - Inspector, pointer follow, CDIM and search all see
'     pending (unsaved) edits, same as the grid does.
'   - Hex and text search share one chunked search routine
'     (text search was reading the file one byte at a time),
'     and it no longer reads past EOF.
'   - Goto, searches and CDIM jumps push the jump stack, so
'     Backspace returns from them too.
'   - Typing a byte back to its original value un-marks it.
'   - Mouse wheel scrolls the grid, file list and CDIM list
'     (the browser wheel was being swallowed before).
'   - File browser no longer caps at 2048 entries.
'   - Open-file logic merged (browser + command line).
'   - Key handling, editing and button strip split into
'     their own subs; the main loop is now a plain frame loop.
'   - TextHelpers.bm dropped from the includes: nothing in
'     here used it (the file itself is untouched).
'
' Key map: F2 Save  F3 Goto  F4 Find Text  F5 Find Hex
'          F6 Open  F7 Follow32  F8 Follow64  F9 Find Next
'          F11 CDIM inspector  Backspace Jump back
'          Tab Switch pane  Esc/F10 Quit
'
' Requires (same folder): ButtonUI.bi  ButtonUI.bm
'
' *** Work on a COPY of important files. This tool cannot
'     grow or shrink a file (overwrite only), and there is
'     no undo once you save. ***
'==========================================================

Option _Explicit

'$Include:'ButtonUI.bi'

'--- file / view state -----------------------------------
Dim Shared fnum As Integer
Dim Shared filename As String
Dim Shared filesize As _Integer64

Dim Shared pageOffset As _Integer64 ' first byte of the visible page
Dim Shared pageLen As Integer '       valid bytes on this page (1..256)
Dim Shared pageBuf As String '        256 bytes: disk + pending edits
Dim Shared diskBuf As String '        256 bytes: pristine disk (for diff)

Dim Shared cur As Integer '           cursor index within page
Dim Shared pane As Integer '          0 = HEX pane, 1 = ASCII pane
Dim Shared nib As Integer '           0 = high nibble next, 1 = low
Dim Shared quitFlag As Integer

'--- sparse edit list (address -> new byte) --------------
Dim Shared editCount As Long
ReDim Shared editAddr(0 To 1023) As _Integer64
ReDim Shared editVal(0 To 1023) As Integer

'--- jump stack (Backspace retraces) ---------------------
Dim Shared jumpCount As Long
ReDim Shared jumpAddr(0 To 255) As _Integer64

'--- last search, as raw bytes (hex and text alike) ------
Dim Shared lastPattern As String

'--- file browser ----------------------------------------
Dim Shared PSEP As String
Dim Shared browseCount As Long
ReDim Shared browseEntries(0 To 255) As String
ReDim Shared browseIsDir(0 To 255) As Integer

'--- theme colors (set in SetupColors) -------------------
Dim Shared cBG As _Unsigned Long
Dim Shared cFG As _Unsigned Long
Dim Shared cHdr As _Unsigned Long
Dim Shared cDim As _Unsigned Long
Dim Shared cAddr As _Unsigned Long
Dim Shared cCol As _Unsigned Long
Dim Shared cWarn As _Unsigned Long
Dim Shared cErr As _Unsigned Long
Dim Shared cCurBg As _Unsigned Long
Dim Shared cMirror As _Unsigned Long
Dim Shared cBlack As _Unsigned Long
Dim Shared cBarBg As _Unsigned Long
Dim Shared cSelBg As _Unsigned Long

'--- layout: text rows/cols mapped to pixels (8x16 font) -
Const MARGINX = 8
Const MARGINY = 6
Const DATAROW0 = 7 '  text row of first data line
Const HEXCOL0 = 11 '  text col of first hex digit
Const ASCCOL0 = 61 '  text col of first ascii char
Const STATUSROW = 24

'--- button strips (pixels) ------------------------------
Const BTN_Y = 410
Const BTN2_Y = 454
Const BTN_H = 34
Const BTN_W = 120
Const BTN_STEP = 130 ' BTN_W + 10px gap

'--- sidebar (inspector + page buttons) ------------------
Const SIDE_X = 636
Const PG_W = 130
Const PG_H = 30

'--- misc ------------------------------------------------
Const SEARCH_CHUNK = 65536
Const DBLCLICK = 0.4 ' seconds

'==========================================================
' Startup
'==========================================================
$If WINDOWS Then
    PSEP = "\"
$Else
    PSEP = "/"
$End If

Screen _NewImage(786, 508, 32)
_Title "QB64PE HEXEDIT 4.1"
_ScreenMove _Middle
SetupColors
MouseInit

' A filename on the command line opens immediately.
If _CommandCount > 0 Then OpenPath Command$(1)

'==========================================================
' Frame loop (immediate-mode UI)
'==========================================================
Dim k As String, wheel As Integer
Do
    _Limit 120
    wheel = PollInput%
    k = InKey$
    If Len(k) > 0 Then HandleKey k

    If fnum <> 0 Then
        HandleGridClick
        If wheel <> 0 Then MoveCursor wheel * 48 ' 3 rows per notch
    End If

    Cls , cBG
    _PrintMode _KeepBackground
    DrawGrid
    DrawInspector
    DrawButtons
    _Display
Loop Until quitFlag

If fnum <> 0 Then Close #fnum
System


'==========================================================
' Theme (CONST cannot hold _RGB32, so shared vars).
'==========================================================
Sub SetupColors
    cBG = _RGB32(18, 20, 26)
    cFG = _RGB32(200, 204, 210)
    cHdr = _RGB32(255, 255, 255)
    cDim = _RGB32(110, 116, 126)
    cAddr = _RGB32(120, 210, 140)
    cCol = _RGB32(90, 200, 210)
    cWarn = _RGB32(240, 220, 70)
    cErr = _RGB32(240, 90, 90)
    cCurBg = _RGB32(220, 226, 235)
    cMirror = _RGB32(60, 150, 160)
    cBlack = _RGB32(0, 0, 0)
    cBarBg = _RGB32(40, 44, 54)
    cSelBg = _RGB32(58, 78, 112)
End Sub


'==========================================================
' Drain the mouse queue, totalling wheel notches on the
' way (PollMouse alone would drop them), then refresh
' gMouse. Returns the wheel total: +down, -up.
'==========================================================
Function PollInput% ()
    Dim w As Integer
    Do While _MouseInput
        w = w + _MouseWheel
    Loop
    PollMouse
    PollInput% = w
End Function


'==========================================================
' Keyboard dispatch.
'==========================================================
Sub HandleKey (k As String)
    ' Always available, file or not.
    Select Case k
        Case Chr$(0) + Chr$(64): OpenFile: Exit Sub '           F6
        Case Chr$(27), Chr$(0) + Chr$(68): RequestQuit: Exit Sub ' Esc / F10
    End Select

    If fnum = 0 Then Exit Sub

    Select Case k
        Case Chr$(0) + Chr$(60): SaveAll '          F2
        Case Chr$(0) + Chr$(61): GotoOffset '       F3
        Case Chr$(0) + Chr$(62): SearchText '       F4
        Case Chr$(0) + Chr$(63): SearchHex '        F5
        Case Chr$(0) + Chr$(65): FollowPointer 4 '  F7
        Case Chr$(0) + Chr$(66): FollowPointer 8 '  F8
        Case Chr$(0) + Chr$(67): FindNext '         F9
        Case Chr$(0) + Chr$(133): CDIMInspector '   F11
        Case Chr$(8): JumpBack '                    Backspace
        Case Chr$(9): pane = 1 - pane: nib = 0 '    Tab
        Case Chr$(0) + Chr$(72): MoveCursor -16 '   Up
        Case Chr$(0) + Chr$(80): MoveCursor 16 '    Down
        Case Chr$(0) + Chr$(75): MoveCursor -1 '    Left
        Case Chr$(0) + Chr$(77): MoveCursor 1 '     Right
        Case Chr$(0) + Chr$(73): MoveCursor -256 '  PgUp
        Case Chr$(0) + Chr$(81): MoveCursor 256 '   PgDn
        Case Chr$(0) + Chr$(71): JumpTo 0 '         Home
        Case Chr$(0) + Chr$(79): JumpTo filesize - 1 ' End
        Case Else: EditKey k
    End Select
End Sub


'==========================================================
' Typing into the active pane.
'==========================================================
Sub EditKey (k As String)
    Dim hv As Integer, b As Integer

    If pane = 0 Then
        hv = HexNibble%(k)
        If hv < 0 Then Exit Sub
        b = Asc(pageBuf, cur + 1)
        If nib = 0 Then
            PutByte hv * 16 + (b And 15)
            nib = 1
        Else
            PutByte hv + (b And 240)
            MoveCursor 1 ' also resets nib
        End If
    Else
        If Len(k) <> 1 Then Exit Sub
        b = Asc(k)
        If b < 32 Or b > 126 Then Exit Sub
        PutByte b
        MoveCursor 1
    End If
End Sub


'==========================================================
' Write one byte at the cursor into the page and edit list.
'==========================================================
Sub PutByte (v As Integer)
    Mid$(pageBuf, cur + 1, 1) = Chr$(v)
    SetEdit pageOffset + cur, v, Asc(diskBuf, cur + 1)
End Sub


'==========================================================
' Button strips + page buttons. Drawn every frame; each
' call reports its own click.
'==========================================================
Sub DrawButtons
    Dim bx As Integer, hasFile As Integer
    hasFile = (fnum <> 0)

    bx = MARGINX
    If Button%(bx, BTN_Y, BTN_W, BTN_H, "Open (F6)") Then OpenFile
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN_Y, BTN_W, BTN_H, "Save (F2)", (editCount > 0)) Then SaveAll
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN_Y, BTN_W, BTN_H, "Goto (F3)", hasFile) Then GotoOffset
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN_Y, BTN_W, BTN_H, "Find Hex (F5)", hasFile) Then SearchHex
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN_Y, BTN_W, BTN_H, "Find Text (F4)", hasFile) Then SearchText
    bx = bx + BTN_STEP
    If Button%(bx, BTN_Y, BTN_W, BTN_H, "Quit (Esc)") Then RequestQuit

    bx = MARGINX
    If ButtonEx%(bx, BTN2_Y, BTN_W, BTN_H, "Follow32 (F7)", hasFile) Then FollowPointer 4
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN2_Y, BTN_W, BTN_H, "Follow64 (F8)", hasFile) Then FollowPointer 8
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN2_Y, BTN_W, BTN_H, "Find Next (F9)", hasFile And (Len(lastPattern) > 0)) Then FindNext
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN2_Y, BTN_W, BTN_H, "CDIM (F11)", hasFile) Then CDIMInspector
    bx = bx + BTN_STEP
    If ButtonEx%(bx, BTN2_Y, BTN_W, BTN_H, "Back (Bksp)", (jumpCount > 0)) Then JumpBack

    If ButtonEx%(SIDE_X, 40, PG_W, PG_H, "Page Up", hasFile) Then MoveCursor -256
    If ButtonEx%(SIDE_X, 40 + PG_H + 6, PG_W, PG_H, "Page Down", hasFile) Then MoveCursor 256
End Sub


'==========================================================
' Text-cell -> pixel helpers.
'==========================================================
Function PX% (col As Integer)
    PX% = MARGINX + (col - 1) * 8
End Function

Function PY% (row As Integer)
    PY% = MARGINY + (row - 1) * 16
End Function

Sub TextAt (col As Integer, row As Integer, s As String, clr As _Unsigned Long)
    Color clr
    _PrintString (PX%(col), PY%(row)), s
End Sub


'==========================================================
' Page buffer + edit list
'==========================================================

' Lay pending edits over a buffer that starts at file
' offset bufStart. Used by the page, reads and search, so
' everything sees the same bytes the grid shows.
Sub OverlayEdits (buf As String, bufStart As _Integer64)
    Dim i As Long, rel As _Integer64, n As Long
    n = Len(buf)
    For i = 0 To editCount - 1
        rel = editAddr(i) - bufStart
        If rel >= 0 And rel < n Then Mid$(buf, rel + 1, 1) = Chr$(editVal(i))
    Next
End Sub

Sub LoadPage
    Dim n As _Integer64
    n = filesize - pageOffset
    If n > 256 Then n = 256
    pageLen = n

    diskBuf = Space$(pageLen)
    Get #fnum, pageOffset + 1, diskBuf
    diskBuf = diskBuf + String$(256 - pageLen, 0)
    pageBuf = diskBuf
    OverlayEdits pageBuf, pageOffset
End Sub

' Record, update or drop one edit. orig is the on-disk byte:
' typing a byte back to it removes the edit entirely.
Sub SetEdit (addr As _Integer64, v As Integer, orig As Integer)
    Dim i As Long

    For i = 0 To editCount - 1
        If editAddr(i) = addr Then
            If v = orig Then
                editCount = editCount - 1
                editAddr(i) = editAddr(editCount)
                editVal(i) = editVal(editCount)
            Else
                editVal(i) = v
            End If
            Exit Sub
        End If
    Next

    If v = orig Then Exit Sub

    If editCount > UBound(editAddr) Then
        ReDim _Preserve editAddr(0 To editCount * 2 - 1) As _Integer64
        ReDim _Preserve editVal(0 To editCount * 2 - 1) As Integer
    End If
    editAddr(editCount) = addr
    editVal(editCount) = v
    editCount = editCount + 1
End Sub

Sub SaveAll
    Dim i As Long, one As String
    If fnum = 0 Then Exit Sub
    For i = 0 To editCount - 1
        one = Chr$(editVal(i))
        Put #fnum, editAddr(i) + 1, one
    Next
    editCount = 0
    LoadPage
End Sub


'==========================================================
' Cursor movement
'==========================================================
Sub MoveCursor (delta As _Integer64)
    Dim gAddr As _Integer64, newPage As _Integer64
    If filesize = 0 Then Exit Sub

    gAddr = pageOffset + cur + delta
    If gAddr < 0 Then gAddr = 0
    If gAddr > filesize - 1 Then gAddr = filesize - 1

    newPage = (gAddr \ 256) * 256
    If newPage <> pageOffset Then
        pageOffset = newPage
        LoadPage
    End If

    cur = gAddr - pageOffset
    nib = 0
End Sub

Sub JumpTo (addr As _Integer64)
    MoveCursor addr - (pageOffset + cur)
End Sub

' Click in the grid: pick the byte and the pane clicked.
Sub HandleGridClick
    Dim r As Integer, rel As Integer, idx As Integer, p As Integer

    If Not gMouse.clicked Then Exit Sub

    rel = gMouse.my - PY%(DATAROW0)
    If rel < 0 Then Exit Sub
    r = rel \ 16
    If r > 15 Then Exit Sub

    idx = -1
    rel = gMouse.mx - PX%(HEXCOL0)
    If rel >= 0 And rel < 16 * 24 Then
        ' each hex cell is 3 chars; only the 2 digits count
        If (rel Mod 24) < 16 Then idx = r * 16 + rel \ 24: p = 0
    Else
        rel = gMouse.mx - PX%(ASCCOL0)
        If rel >= 0 And rel < 16 * 8 Then idx = r * 16 + rel \ 8: p = 1
    End If

    If idx >= 0 And idx < pageLen Then
        cur = idx: pane = p: nib = 0
    End If
End Sub


'==========================================================
' Modal prompts (status line)
'==========================================================

' Y = save, N = discard, Esc = cancel -> returns 1 / 2 / 3
Function ConfirmUnsaved% ()
    Dim a As String, y As Integer
    y = PY%(STATUSROW)
    Do
        _Limit 120
        Do While _MouseInput: Loop
        a = UCase$(InKey$)
        If a = "Y" Then ConfirmUnsaved% = 1: Exit Function
        If a = "N" Then ConfirmUnsaved% = 2: Exit Function
        If a = Chr$(27) Then ConfirmUnsaved% = 3: Exit Function

        Line (0, y)-(_Width, y + 20), cBarBg, BF
        Color cWarn
        _PrintString (PX%(1), y + 2), "Unsaved edits! Save first?  (Y = save   N = discard   Esc = cancel)"
        _Display
    Loop
End Function

' One-line text entry. cancelled = -1 on Esc.
Function GetText$ (prompt As String, cancelled As Integer)
    Dim s As String, k As String, done As Integer, y As Integer
    cancelled = 0
    y = PY%(STATUSROW)

    Do
        _Limit 120
        Do While _MouseInput: Loop
        k = InKey$
        If k = Chr$(13) Then
            done = -1
        ElseIf k = Chr$(27) Then
            cancelled = -1: done = -1
        ElseIf k = Chr$(8) Then
            If Len(s) > 0 Then s = Left$(s, Len(s) - 1)
        ElseIf Len(k) = 1 Then
            If Asc(k) >= 32 And Asc(k) <= 126 Then s = s + k
        End If

        Line (0, y)-(_Width, y + 20), cBarBg, BF
        Color cHdr
        _PrintString (PX%(1), y + 2), prompt + s + "_"
        _Display
    Loop Until done

    GetText$ = s
End Function

' Message on the status line; waits for a key.
Sub Flash (msg As String, clr As _Unsigned Long)
    Dim y As Integer
    y = PY%(STATUSROW)
    Line (0, y)-(_Width, y + 20), cBarBg, BF
    Color clr
    _PrintString (PX%(1), y + 2), msg + "   (press any key)"
    _Display
    Do
        _Limit 60
        Do While _MouseInput: Loop
    Loop Until Len(InKey$)
End Sub

Sub RequestQuit
    If editCount > 0 Then
        Select Case ConfirmUnsaved%
            Case 1: SaveAll: quitFlag = -1
            Case 2: quitFlag = -1
        End Select
    Else
        quitFlag = -1
    End If
End Sub


'==========================================================
' Goto: hex by default (&H / 0x prefix optional),
' #prefix for decimal (e.g. #1024).
'==========================================================
Sub GotoOffset
    Dim s As String, cancelled As Integer, useDec As Integer
    Dim i As Integer, d As Integer, v As _Integer64

    s = _Trim$(GetText$("Goto offset (hex, or #decimal): ", cancelled))
    If cancelled Or Len(s) = 0 Then Exit Sub

    If Left$(s, 1) = "#" Then
        useDec = -1
        s = Mid$(s, 2)
    ElseIf UCase$(Left$(s, 2)) = "&H" Or LCase$(Left$(s, 2)) = "0x" Then
        s = Mid$(s, 3)
    End If
    If Len(s) = 0 Then Exit Sub

    For i = 1 To Len(s)
        d = HexNibble%(Mid$(s, i, 1))
        If useDec And d > 9 Then d = -1
        If d < 0 Then Flash "Invalid offset: " + s, cErr: Exit Sub
        If useDec Then v = v * 10 + d Else v = v * 16 + d
    Next

    If v >= filesize Then Flash "Offset past end of file", cErr: Exit Sub
    PushJump pageOffset + cur
    JumpTo v
End Sub


'==========================================================
' Formatting helpers
'==========================================================
Function HexByte$ (b As Integer)
    HexByte$ = Right$("0" + Hex$(b), 2)
End Function

' At least 8 hex digits; grows past 4 GB instead of wrapping.
Function HexAddr$ (n As _Integer64)
    Dim h As String
    h = Hex$(n)
    If Len(h) < 8 Then h = String$(8 - Len(h), "0") + h
    HexAddr$ = h
End Function

' 0..15 for one hex-digit character, else -1.
Function HexNibble% (k As String)
    If Len(k) <> 1 Then HexNibble% = -1: Exit Function
    HexNibble% = InStr("0123456789ABCDEF", UCase$(k)) - 1
End Function


'==========================================================
' Search. Hex and text both become a raw byte pattern and
' go through FindPattern&&, which scans in 64 KB chunks
' (overlapping so boundary matches aren't missed) and sees
' pending edits.
'==========================================================
Function FindPattern&& (pattern As String, startPos As _Integer64)
    Dim chunk As String, filePos As _Integer64, chunkLen As _Integer64, hit As Long

    FindPattern&& = -1
    If Len(pattern) = 0 Or Len(pattern) > SEARCH_CHUNK Then Exit Function

    filePos = startPos
    If filePos < 0 Then filePos = 0

    Do While filePos + Len(pattern) <= filesize
        chunkLen = filesize - filePos
        If chunkLen > SEARCH_CHUNK Then chunkLen = SEARCH_CHUNK
        chunk = Space$(chunkLen)
        Get #fnum, filePos + 1, chunk
        OverlayEdits chunk, filePos

        hit = InStr(chunk, pattern)
        If hit > 0 Then
            FindPattern&& = filePos + hit - 1
            Exit Function
        End If

        If filePos + chunkLen >= filesize Then Exit Do
        filePos = filePos + chunkLen - Len(pattern) + 1
    Loop
End Function

Sub RunSearch (pattern As String, startPos As _Integer64)
    Dim hit As _Integer64
    lastPattern = pattern
    hit = FindPattern&&(pattern, startPos)
    If hit < 0 Then Flash "Not found", cErr: Exit Sub
    PushJump pageOffset + cur
    JumpTo hit
End Sub

Sub SearchText
    Dim s As String, cancelled As Integer
    s = GetText$("Find text: ", cancelled)
    If cancelled Or Len(s) = 0 Then Exit Sub
    RunSearch s, 0
End Sub

Sub SearchHex
    Dim s As String, cancelled As Integer, clean As String, pat As String
    Dim i As Integer, ch As String, hi As Integer, lo As Integer

    s = GetText$("Find hex bytes (e.g. 43 44 49 4D): ", cancelled)
    If cancelled Then Exit Sub

    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch <> " " Then clean = clean + ch
    Next
    If Len(clean) = 0 Then Exit Sub
    If Len(clean) Mod 2 = 1 Then Flash "Invalid hex string (need byte pairs)", cErr: Exit Sub

    For i = 1 To Len(clean) Step 2
        hi = HexNibble%(Mid$(clean, i, 1))
        lo = HexNibble%(Mid$(clean, i + 1, 1))
        If hi < 0 Or lo < 0 Then Flash "Invalid hex digit", cErr: Exit Sub
        pat = pat + Chr$(hi * 16 + lo)
    Next

    RunSearch pat, 0
End Sub

Sub FindNext
    If Len(lastPattern) = 0 Then Flash "No previous search", cDim: Exit Sub
    RunSearch lastPattern, pageOffset + cur + 1
End Sub


'==========================================================
' Byte readers. ReadFileBytes$ returns n bytes from a file
' offset with pending edits applied; past-EOF bytes are 0.
'==========================================================
Function ReadFileBytes$ (addr As _Integer64, n As Long)
    Dim avail As _Integer64, s As String

    If n <= 0 Then Exit Function
    If fnum = 0 Or addr < 0 Or addr >= filesize Then
        ReadFileBytes$ = String$(n, 0)
        Exit Function
    End If

    avail = filesize - addr
    If avail > n Then avail = n
    s = Space$(avail)
    Get #fnum, addr + 1, s
    OverlayEdits s, addr
    ReadFileBytes$ = s + String$(n - avail, 0)
End Function

' Unsigned readers; p is the 1-based position in s, nBytes
' is 1, 2, 4 or 8. A 64-bit value with the top bit set comes
' back negative (no unsigned 64-bit type to hold it).
Function ReadUIntLE&& (s As String, p As Long, nBytes As Integer)
    Dim i As Integer, v As _Integer64
    For i = nBytes - 1 To 0 Step -1
        v = v * 256 + Asc(s, p + i)
    Next
    ReadUIntLE&& = v
End Function

Function ReadUIntBE&& (s As String, p As Long, nBytes As Integer)
    Dim i As Integer, v As _Integer64
    For i = 0 To nBytes - 1
        v = v * 256 + Asc(s, p + i)
    Next
    ReadUIntBE&& = v
End Function

' Two's-complement reinterpretation for 1..7 byte values.
Function ToSigned&& (v As _Integer64, nBytes As Integer)
    Dim fullRange As _Integer64
    If nBytes >= 8 Then ToSigned&& = v: Exit Function
    fullRange = 2 ^ (nBytes * 8)
    If v >= fullRange \ 2 Then ToSigned&& = v - fullRange Else ToSigned&& = v
End Function


'==========================================================
' Data inspector sidebar.
'==========================================================
Sub InspRow (y As Integer, label As String, v As _Integer64)
    _PrintString (SIDE_X + 4, y), Left$(label + Space$(6), 6) + LTrim$(Str$(v))
    y = y + 18
End Sub

Sub DrawInspector
    Dim b As String, y As Integer, u64 As _Integer64, s64 As String

    Line (628, 0)-(628, 400), cDim
    If fnum = 0 Then Exit Sub

    b = ReadFileBytes$(pageOffset + cur, 8)

    y = 120
    Color cHdr
    _PrintString (SIDE_X + 4, y), "INSPECTOR"
    y = y + 22

    Color cFG
    InspRow y, "i8", ToSigned&&(ReadUIntLE&&(b, 1, 1), 1)
    InspRow y, "u8", ReadUIntLE&&(b, 1, 1)
    InspRow y, "i16LE", ToSigned&&(ReadUIntLE&&(b, 1, 2), 2)
    InspRow y, "u16LE", ReadUIntLE&&(b, 1, 2)
    InspRow y, "i16BE", ToSigned&&(ReadUIntBE&&(b, 1, 2), 2)
    InspRow y, "u16BE", ReadUIntBE&&(b, 1, 2)
    InspRow y, "i32LE", ToSigned&&(ReadUIntLE&&(b, 1, 4), 4)
    InspRow y, "u32LE", ReadUIntLE&&(b, 1, 4)
    InspRow y, "i32BE", ToSigned&&(ReadUIntBE&&(b, 1, 4), 4)
    InspRow y, "u32BE", ReadUIntBE&&(b, 1, 4)

    ' u64 on its own line. The sidebar fits 17 chars, so big
    ' values (and >= 2^63, which read back negative) show as
    ' hex -- Hex$ of a negative _Integer64 gives the true bits.
    u64 = ReadUIntLE&&(b, 1, 8)
    s64 = LTrim$(Str$(u64))
    If u64 < 0 Or Len(s64) > 17 Then s64 = "0x" + Hex$(u64)
    _PrintString (SIDE_X + 4, y), "u64LE"
    y = y + 16
    _PrintString (SIDE_X + 4, y), s64
    y = y + 24

    Color cDim
    _PrintString (SIDE_X + 4, y), "F7->0x" + HexAddr$(ReadUIntLE&&(b, 1, 4))
End Sub


'==========================================================
' Main view.
'==========================================================
Sub DrawGrid
    Dim r As Integer, c As Integer, idx As Integer, b As Integer
    Dim scrRow As Integer, ppx As Integer, ppy As Integer
    Dim ach As String, clr As _Unsigned Long, st As String

    TextAt 1, 1, "QB64PE HEXEDIT 4.1", cHdr

    If fnum = 0 Then
        TextAt 1, 3, "No file open.", cFG
        TextAt 1, 5, "Click  Open (F6)  to browse for a file to edit.", cDim
        Exit Sub
    End If

    TextAt 1, 2, "File: " + Right$(filename, 70), cFG
    TextAt 1, 3, "Size: " + LTrim$(Str$(filesize)) + " bytes", cFG
    TextAt 40, 3, "Cursor: " + HexAddr$(pageOffset + cur), cFG

    ' Column header
    TextAt 1, 5, " OFFSET", cCol
    For c = 0 To 15
        TextAt HEXCOL0 + c * 3, 5, HexByte$(c), cCol
    Next
    TextAt ASCCOL0, 5, "ASCII", cCol
    TextAt 1, 6, String$(78, "-"), cDim

    ' Data rows (changed bytes highlighted)
    For r = 0 To 15
        If r * 16 >= pageLen Then Exit For
        scrRow = DATAROW0 + r
        TextAt 1, scrRow, HexAddr$(pageOffset + r * 16), cAddr
        TextAt ASCCOL0 - 1, scrRow, "|", cFG
        TextAt ASCCOL0 + 16, scrRow, "|", cFG
        For c = 0 To 15
            idx = r * 16 + c
            If idx >= pageLen Then Exit For
            b = Asc(pageBuf, idx + 1)
            If b >= 32 And b <= 126 Then ach = Chr$(b) Else ach = "."
            If b <> Asc(diskBuf, idx + 1) Then clr = cWarn Else clr = cFG
            TextAt HEXCOL0 + c * 3, scrRow, HexByte$(b), clr
            TextAt ASCCOL0 + c, scrRow, ach, clr
        Next
    Next

    ' Cursor: solid in the active pane, tinted in the mirror pane
    scrRow = DATAROW0 + cur \ 16
    b = Asc(pageBuf, cur + 1)
    If b >= 32 And b <= 126 Then ach = Chr$(b) Else ach = "."

    ppx = PX%(HEXCOL0 + (cur Mod 16) * 3): ppy = PY%(scrRow)
    If pane = 0 Then clr = cCurBg Else clr = cMirror
    Line (ppx, ppy)-(ppx + 15, ppy + 15), clr, BF
    Color cBlack
    _PrintString (ppx, ppy), HexByte$(b)

    ppx = PX%(ASCCOL0 + (cur Mod 16))
    If pane = 1 Then clr = cCurBg Else clr = cMirror
    Line (ppx, ppy)-(ppx + 7, ppy + 15), clr, BF
    Color cBlack
    _PrintString (ppx, ppy), ach

    ' Status line
    st = "Byte " + HexByte$(b) + " (" + LTrim$(Str$(b)) + ")  ["
    If pane = 0 Then
        st = st + "HEX] nibble:"
        If nib = 0 Then st = st + "hi" Else st = st + "lo"
    Else
        st = st + "ASCII]"
    End If
    If editCount > 0 Then
        TextAt 1, STATUSROW, st + "   *UNSAVED " + LTrim$(Str$(editCount)) + "*", cWarn
    Else
        TextAt 1, STATUSROW, st, cFG
    End If

    TextAt 1, STATUSROW + 1, "Arrows/Wheel Move  Tab Pane  Type Edit  F7/F8 Follow  F9 Next  F11 CDIM  Bksp Back", cDim
End Sub


'==========================================================
' Pointer following + jump stack
'==========================================================
Sub FollowPointer (nBytes As Integer)
    Dim here As _Integer64, target As _Integer64
    here = pageOffset + cur
    target = ReadUIntLE&&(ReadFileBytes$(here, (nBytes)), 1, nBytes)
    If target < 0 Or target >= filesize Then
        Flash "Pointer target 0x" + HexAddr$(target) + " is outside the file", cErr
        Exit Sub
    End If
    PushJump here
    JumpTo target
End Sub

Sub PushJump (addr As _Integer64)
    If jumpCount > UBound(jumpAddr) Then
        ReDim _Preserve jumpAddr(0 To jumpCount * 2 - 1) As _Integer64
    End If
    jumpAddr(jumpCount) = addr
    jumpCount = jumpCount + 1
End Sub

Sub JumpBack
    If jumpCount = 0 Then Flash "Jump stack empty", cDim: Exit Sub
    jumpCount = jumpCount - 1
    JumpTo jumpAddr(jumpCount)
End Sub


'==========================================================
' CDIM structure inspector (modal). The pointer table is
' read once on entry instead of from disk every frame.
'==========================================================
Sub CDIMInspector
    Dim memberCount As _Integer64, tbl As String, addr As _Integer64
    Dim selIdx As Long, topIdx As Long, i As Long, idx As Long
    Dim doneFlag As Integer, jumpIt As Integer, wheel As Integer
    Dim k As String, rowY As Integer, lastIdx As Long, lastT As Double
    Dim panelX As Integer, panelY As Integer, panelW As Integer, panelH As Integer
    Dim listX As Integer, listY0 As Integer, listW As Integer, rowH As Integer, visRows As Integer

    If ReadFileBytes$(0, 4) <> "CDIM" Then
        Flash "Not a CDIM file (magic bytes mismatch at offset 0)", cErr
        Exit Sub
    End If

    memberCount = ReadUIntLE&&(ReadFileBytes$(4, 4), 1, 4)
    If memberCount > 1000000 Or 72 + memberCount * 8 > filesize Then
        Flash "Member count " + LTrim$(Str$(memberCount)) + " doesn't fit the file - aborting", cErr
        Exit Sub
    End If
    tbl = ReadFileBytes$(72, memberCount * 8)

    panelX = 60: panelY = 40: panelW = 666: panelH = 400
    listX = panelX + 12: listY0 = panelY + 70: listW = panelW - 24
    rowH = 18: visRows = 16
    lastIdx = -1

    Do
        _Limit 120
        wheel = PollInput%
        k = InKey$
        jumpIt = 0

        Select Case k
            Case Chr$(27): doneFlag = -1
            Case Chr$(13): jumpIt = -1
            Case Chr$(0) + Chr$(72): selIdx = selIdx - 1
            Case Chr$(0) + Chr$(80): selIdx = selIdx + 1
            Case Chr$(0) + Chr$(73): selIdx = selIdx - visRows
            Case Chr$(0) + Chr$(81): selIdx = selIdx + visRows
            Case Chr$(0) + Chr$(71): selIdx = 0
            Case Chr$(0) + Chr$(79): selIdx = memberCount - 1
        End Select
        selIdx = selIdx + wheel * 3

        ' click selects, double-click jumps
        If gMouse.clicked Then
            If PtInRect%(gMouse.mx, gMouse.my, listX, listY0, listW, visRows * rowH - 1) Then
                idx = topIdx + (gMouse.my - listY0) \ rowH
                If idx < memberCount Then
                    If idx = lastIdx And Timer - lastT < DBLCLICK Then jumpIt = -1
                    selIdx = idx: lastIdx = idx: lastT = Timer
                End If
            End If
        End If

        If selIdx > memberCount - 1 Then selIdx = memberCount - 1
        If selIdx < 0 Then selIdx = 0
        If selIdx < topIdx Then topIdx = selIdx
        If selIdx > topIdx + visRows - 1 Then topIdx = selIdx - visRows + 1

        If jumpIt And memberCount > 0 Then
            addr = ReadUIntLE&&(tbl, selIdx * 8 + 1, 8)
            If addr >= 0 And addr < filesize Then
                PushJump pageOffset + cur
                JumpTo addr
                doneFlag = -1
            Else
                Flash "Entry points outside the file", cErr
            End If
        End If

        ' --- render ---
        Line (panelX, panelY)-(panelX + panelW, panelY + panelH), cBarBg, BF
        Line (panelX, panelY)-(panelX + panelW, panelY + panelH), cDim, B
        Color cHdr
        _PrintString (panelX + 12, panelY + 8), "CDIM Structure Inspector"
        Color cFG
        _PrintString (panelX + 12, panelY + 30), "Magic: CDIM   Members: " + LTrim$(Str$(memberCount)) + "   Pointer table @ +72"

        For i = 0 To visRows - 1
            idx = topIdx + i
            If idx >= memberCount Then Exit For
            rowY = listY0 + i * rowH
            If idx = selIdx Then Line (listX, rowY)-(listX + listW, rowY + rowH - 1), cSelBg, BF
            addr = ReadUIntLE&&(tbl, idx * 8 + 1, 8)
            Color cFG
            _PrintString (listX + 4, rowY), "[" + Right$("   " + LTrim$(Str$(idx)), 4) + "]  offset +" + LTrim$(Str$(72 + idx * 8)) + "  -> 0x" + HexAddr$(addr)
        Next

        Color cDim
        _PrintString (panelX + 12, panelY + panelH - 20), "Enter/double-click=jump  arrows/PgUp/PgDn/wheel=move  Esc=close"
        _Display
    Loop Until doneFlag
End Sub


'==========================================================
' Directory helpers
'==========================================================
Function NormDir$ (d As String)
    Dim s As String
    s = d
    If Len(s) = 0 Then s = PSEP
    If Right$(s, 1) <> PSEP Then s = s + PSEP
    NormDir$ = s
End Function

Function ParentDir$ (d As String)
    Dim s As String, i As Integer
    s = d
    If Right$(s, 1) = PSEP Then s = Left$(s, Len(s) - 1)
    For i = Len(s) To 1 Step -1
        If Mid$(s, i, 1) = PSEP Then ParentDir$ = NormDir$(Left$(s, i - 1)): Exit Function
    Next
    ParentDir$ = NormDir$(s)
End Function

' Rebuild the browser list for curDir: folders first, then
' files, each case-insensitive alphabetical. "." dropped,
' ".." kept. Grows as needed (no entry cap).
Sub RefreshEntries (curDir As String)
    Dim e As String, nm As String, isDir As Integer
    Dim i As Long, j As Long, tName As String, tDir As Integer, tKey As String
    ReDim sortKey(0 To UBound(browseEntries)) As String

    browseCount = 0
    e = _Files$(curDir + "*")
    Do While Len(e) > 0
        isDir = (Right$(e, 1) = PSEP)
        If isDir Then nm = Left$(e, Len(e) - 1) Else nm = e
        If nm <> "." Then
            If browseCount > UBound(browseEntries) Then
                ReDim _Preserve browseEntries(0 To browseCount * 2 - 1) As String
                ReDim _Preserve browseIsDir(0 To browseCount * 2 - 1) As Integer
                ReDim _Preserve sortKey(0 To browseCount * 2 - 1) As String
            End If
            browseEntries(browseCount) = nm
            browseIsDir(browseCount) = isDir
            If isDir Then sortKey(browseCount) = "0" + UCase$(nm) Else sortKey(browseCount) = "1" + UCase$(nm)
            browseCount = browseCount + 1
        End If
        e = _Files$
    Loop

    ' insertion sort on the key
    For i = 1 To browseCount - 1
        tName = browseEntries(i): tDir = browseIsDir(i): tKey = sortKey(i)
        j = i - 1
        Do While j >= 0
            If sortKey(j) <= tKey Then Exit Do
            browseEntries(j + 1) = browseEntries(j)
            browseIsDir(j + 1) = browseIsDir(j)
            sortKey(j + 1) = sortKey(j)
            j = j - 1
        Loop
        browseEntries(j + 1) = tName: browseIsDir(j + 1) = tDir: sortKey(j + 1) = tKey
    Next
End Sub


'==========================================================
' Modal file browser. Returns the chosen path, or "" with
' cancelled = -1.
'   Mouse: click selects, double-click opens; wheel scrolls;
'          Windows drive bar across the top.
'   Keys:  arrows/PgUp/PgDn/Home/End move, Enter opens,
'          Backspace = up, T = type a path, Esc = cancel,
'          any other letter jumps to the next match.
'==========================================================
Function BrowseForFile$ (startDir As String, cancelled As Integer)
    Dim curDir As String, result As String, doneFlag As Integer
    Dim selIdx As Long, topIdx As Long, activate As Long, idx As Long
    Dim i As Integer, j As Long, rowY As Integer, wheel As Integer
    Dim k As String, ch As String, maxChars As Integer
    Dim lastClickIdx As Long, lastClickT As Double
    Dim driveLetters As String, dnum As Integer, boxX As Integer
    Dim typedName As String, typedCancel As Integer
    Dim panelX As Integer, panelY As Integer, panelW As Integer, panelH As Integer
    Dim listX As Integer, listY0 As Integer, listW As Integer, rowH As Integer, visRows As Integer
    Dim driveY As Integer, dbw As Integer, dbGap As Integer

    cancelled = 0
    lastClickIdx = -1

    curDir = _Trim$(startDir)
    If Len(curDir) = 0 Then curDir = _CWD$
    If Not _DirExists(curDir) Then curDir = _CWD$
    curDir = NormDir$(curDir)

    $If WINDOWS Then
        For dnum = 67 To 90 ' C..Z
            If _DirExists(Chr$(dnum) + ":\") Then driveLetters = driveLetters + Chr$(dnum)
        Next
    $End If

    panelX = 60: panelY = 40: panelW = 666: panelH = 400
    listX = panelX + 12: listY0 = panelY + 90: listW = panelW - 24
    rowH = 18: visRows = 15
    driveY = panelY + 52: dbw = 22: dbGap = 4
    maxChars = listW \ 8 - 1

    RefreshEntries curDir

    Do
        _Limit 120
        wheel = PollInput%
        k = InKey$
        activate = -1

        Select Case k
            Case Chr$(27): cancelled = -1: doneFlag = -1
            Case Chr$(13): If browseCount > 0 Then activate = selIdx
            Case Chr$(8)
                curDir = ParentDir$(curDir)
                RefreshEntries curDir
                selIdx = 0: topIdx = 0
            Case Chr$(0) + Chr$(72): selIdx = selIdx - 1
            Case Chr$(0) + Chr$(80): selIdx = selIdx + 1
            Case Chr$(0) + Chr$(73): selIdx = selIdx - visRows
            Case Chr$(0) + Chr$(81): selIdx = selIdx + visRows
            Case Chr$(0) + Chr$(71): selIdx = 0
            Case Chr$(0) + Chr$(79): selIdx = browseCount - 1
            Case "t", "T"
                typedName = _Trim$(GetText$("Open file (full path): ", typedCancel))
                If Not typedCancel And Len(typedName) > 0 Then result = typedName: doneFlag = -1
            Case Else
                If Len(k) = 1 And browseCount > 0 Then
                    ch = UCase$(k)
                    For j = 1 To browseCount
                        idx = (selIdx + j) Mod browseCount
                        If UCase$(Left$(browseEntries(idx), 1)) = ch Then selIdx = idx: Exit For
                    Next
                End If
        End Select
        selIdx = selIdx + wheel * 3

        If gMouse.clicked Then
            ' drive bar
            If Len(driveLetters) > 0 And gMouse.my >= driveY And gMouse.my < driveY + 18 Then
                For i = 1 To Len(driveLetters)
                    boxX = listX + (i - 1) * (dbw + dbGap)
                    If gMouse.mx >= boxX And gMouse.mx < boxX + dbw Then
                        curDir = Mid$(driveLetters, i, 1) + ":\"
                        RefreshEntries curDir
                        selIdx = 0: topIdx = 0
                    End If
                Next
            End If
            ' list: click selects, double-click opens
            If PtInRect%(gMouse.mx, gMouse.my, listX, listY0, listW, visRows * rowH - 1) Then
                idx = topIdx + (gMouse.my - listY0) \ rowH
                If idx < browseCount Then
                    If idx = lastClickIdx And Timer - lastClickT < DBLCLICK Then activate = idx
                    selIdx = idx: lastClickIdx = idx: lastClickT = Timer
                End If
            End If
        End If

        If activate >= 0 Then
            If browseIsDir(activate) Then
                If browseEntries(activate) = ".." Then
                    curDir = ParentDir$(curDir)
                Else
                    curDir = NormDir$(curDir + browseEntries(activate))
                End If
                RefreshEntries curDir
                selIdx = 0: topIdx = 0: lastClickIdx = -1
            Else
                result = curDir + browseEntries(activate)
                doneFlag = -1
            End If
        End If

        If selIdx > browseCount - 1 Then selIdx = browseCount - 1
        If selIdx < 0 Then selIdx = 0
        If selIdx < topIdx Then topIdx = selIdx
        If selIdx > topIdx + visRows - 1 Then topIdx = selIdx - visRows + 1

        ' --- render ---
        Line (panelX, panelY)-(panelX + panelW, panelY + panelH), cBarBg, BF
        Line (panelX, panelY)-(panelX + panelW, panelY + panelH), cDim, B
        Color cHdr
        _PrintString (panelX + 12, panelY + 8), "Open File"
        Color cFG
        _PrintString (panelX + 12, panelY + 30), Right$(curDir, maxChars)

        Color cAddr
        For i = 1 To Len(driveLetters)
            _PrintString (listX + (i - 1) * (dbw + dbGap), driveY), Mid$(driveLetters, i, 1) + ":"
        Next

        For i = 0 To visRows - 1
            idx = topIdx + i
            If idx >= browseCount Then Exit For
            rowY = listY0 + i * rowH
            If idx = selIdx Then Line (listX, rowY)-(listX + listW, rowY + rowH - 1), cSelBg, BF
            If browseIsDir(idx) Then
                Color cAddr
                _PrintString (listX + 4, rowY), Left$("[" + browseEntries(idx) + "]", maxChars)
            Else
                Color cFG
                _PrintString (listX + 4, rowY), Left$(browseEntries(idx), maxChars)
            End If
        Next

        Color cDim
        _PrintString (panelX + 12, panelY + panelH - 20), "Enter=open  Bksp=up  T=type path  Esc=cancel  wheel/PgUp/PgDn=scroll"
        _Display
    Loop Until doneFlag

    BrowseForFile$ = result
End Function


'==========================================================
' Opening files
'==========================================================

' Open (F6 / button): settle unsaved edits, then browse.
Sub OpenFile
    Dim cancelled As Integer, startDir As String, nm As String

    If editCount > 0 Then
        Select Case ConfirmUnsaved%
            Case 1: SaveAll
            Case 3: Exit Sub
        End Select
    End If

    If InStr(filename, PSEP) > 0 Then startDir = ParentDir$(filename) Else startDir = _CWD$
    nm = BrowseForFile$(startDir, cancelled)
    If Not cancelled Then OpenPath nm
End Sub

' Validate a path into a temporary handle BEFORE closing the
' current file, so a bad or empty choice changes nothing.
Sub OpenPath (nm As String)
    Dim newName As String, tnum As Integer, tsize As _Integer64

    newName = _Trim$(nm)
    If Len(newName) = 0 Then Exit Sub
    If Not _FileExists(newName) Then Flash "No such file: " + newName, cErr: Exit Sub

    tnum = FreeFile
    Open newName For Binary As #tnum
    tsize = LOF(tnum)
    If tsize = 0 Then
        Close #tnum
        Flash "Empty file - not opened", cErr
        Exit Sub
    End If

    If fnum <> 0 Then Close #fnum
    fnum = tnum
    filename = newName
    filesize = tsize

    editCount = 0
    jumpCount = 0
    lastPattern = ""
    pageOffset = 0
    cur = 0: pane = 0: nib = 0
    LoadPage
End Sub

'$Include:'ButtonUI.bm'
