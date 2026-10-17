'==========================================================
' RFSGui.bas  -  graphical front end for RFS volumes  (V1.4)
'
' V1.2: New Volume accepts ALL as the size - the cap is set to
'       the free space on that disk (FAT32: held under 4 GB).
' V1.3: Add Folder (button, F6, or drop a folder). Files are
'       stored as "folder/sub/file"; extracting several files
'       into a folder recreates the subfolders. One commit per
'       folder, so big folders add much faster.
' V1.4: Get Folder (button or F7) - pick a stored folder from a
'       list, then a place to put it; the whole tree comes out.
'
' Mouse:  click selects, Ctrl+click adds/removes, Shift+click
'         selects a range, double-click extracts, wheel
'         scrolls, click a column header to sort.
' Keys:   arrows/PgUp/PgDn/Home/End move, Enter extract,
'         Del delete, Ins add files, Ctrl+A select all,
'         F5 check, F6 add folder, F7 extract folder,
'         Esc clear selection,
'         + / - compression level.
' Drop files or folders onto the window to add them (drop a .rfs file
' when nothing is mounted to open it).
'
' The last volume used is remembered in ~/.rfsgui and
' reopened at start. A volume path on the command line
' opens that one instead.
'
' Requires (same folder): RFS.bi RFS.bm ButtonUI.bi ButtonUI.bm
'==========================================================
Option _Explicit
'$Include:'ButtonUI.bi'
'$Include:'RFS.bi'

'--- screen + layout (pixels, 8x16 font) -----------------
Const SW = 920
Const SH = 640
Const TB_Y = 40
Const BW = 86
Const BH = 30
Const BSTEP = 90
Const LIST_X = 12
Const LIST_W = 896
Const HDR_Y = 84
Const ROW_Y0 = 104
Const ROW_H = 18
Const VIS_ROWS = 22
Const SPACE_Y = 514
Const STATUS_Y = 560
Const BAR_Y = 584
Const HINT_Y = 614
Const LVL_X = 620

'--- column positions, relative to LIST_X ----------------
Const COL_NAME = 10
Const COL_SIZE_R = 520
Const COL_STORED_R = 620
Const COL_RATIO_R = 690
Const COL_ADDED = 720
Const NAME_CHARS = 50

'--- deferred actions (run after the frame is on screen,
'    so modals snapshot a complete picture) ---------------
Const ACT_NEW = 1
Const ACT_MOUNT = 2
Const ACT_ADD = 3
Const ACT_EXTRACT = 4
Const ACT_DELETE = 5
Const ACT_VERIFY = 6
Const ACT_CHECK = 7
Const ACT_COMPACT = 8
Const ACT_ADDDIR = 9
Const ACT_GETDIR = 10

Const DBLCLICK = 0.4

'--- "ALL" volume size --------------------------------------
Const ALL_MARGIN = 16777216 '       leave 16 MiB free on the disk
Const FAT32_MAXCAP = 4293918720&& '   4095 MiB, under FAT32's 4 GiB file limit

Dim Shared As _Unsigned Long cBG, cPanel, cFG, cDim, cHdr, cSel, cGood, cWarn, cErr, cLive, cDead, cField

' view: viewIdx(row) -> catalog index, sorted
ReDim Shared viewIdx(0 To 0) As Long
ReDim Shared selFlag(0 To 0) As Integer
ReDim Shared badFlag(0 To 0) As Integer
Dim Shared viewCount As Long
Dim Shared curRow As Long
Dim Shared topRow As Long
Dim Shared anchorRow As Long
Dim Shared sortCol As Integer
Dim Shared sortDesc As Integer
Dim Shared lastClickRow As Long
Dim Shared lastClickT As Double

Dim Shared statusMsg As String
Dim Shared statusClr As _Unsigned Long
Dim Shared pendingAct As Integer
Dim Shared addedCount As Long
Dim Shared addedBytes As _Integer64
Dim Shared quitFlag As Integer
Dim Shared cfgPath As String
Dim Shared lastVolDir As String
Dim Shared lastHostDir As String
Dim Shared PSEP As String

' folder add: files found under the folder (path inside it, size)
ReDim Shared fldName(0 To 0) As String
ReDim Shared fldSize(0 To 0) As _Integer64

' folder picker: every folder on the volume, sorted, with the
' number of files and bytes under it (subfolders included).
' pfKey() is the name with "/" swapped for Chr$(1) so a folder
' sorts right before its own subfolders.
ReDim Shared pfName(0 To 0) As String
ReDim Shared pfKey(0 To 0) As String
ReDim Shared pfFiles(0 To 0) As Long
ReDim Shared pfBytes(0 To 0) As _Integer64
Dim Shared pfN As Long

Dim k As String, wheel As Integer, act As Integer

$If WINDOWS Then
    PSEP = "\"
$Else
    PSEP = "/"
$End If

ChDir _StartDir$
Screen _NewImage(SW, SH, 32)
_Title "RFS - Russell File System"
_ScreenMove _Middle
SetupColors
MouseInit
RFSInit
rfsVerbose = 2
rfsBarX = LIST_X
rfsBarY = BAR_Y
rfsBarW = LIST_W
_AcceptFileDrop

If Len(Environ$("HOME")) Then cfgPath = Environ$("HOME") + PSEP + ".rfsgui" Else cfgPath = "rfsgui.cfg"
lastLoad

lastClickRow = -1
SetStatus "Ready.", cDim
If _CommandCount > 0 Then
    MountVol Command$(1)
ElseIf Len(rfsVolPath) Then
    MountVol rfsVolPath
End If

'==========================================================
' Frame loop
'==========================================================
Do
    _Limit 60
    wheel = PollInput%
    HandleDrops
    k = InKey$
    If Len(k) Then HandleKey k
    If wheel <> 0 Then ScrollBy wheel * 3
    HandleListMouse

    Cls , cBG
    _PrintMode _KeepBackground
    DrawHeader
    DrawToolbar
    DrawList
    DrawSpace
    DrawStatus
    _Display

    If pendingAct Then
        act = pendingAct
        pendingAct = 0
        RunAction act
    End If
Loop Until quitFlag

RFSUnmount
System


'==========================================================
' Setup
'==========================================================
Sub SetupColors
    cBG = _RGB32(18, 20, 26)
    cPanel = _RGB32(28, 31, 40)
    cField = _RGB32(12, 14, 18)
    cFG = _RGB32(200, 204, 210)
    cDim = _RGB32(110, 116, 126)
    cHdr = _RGB32(255, 255, 255)
    cSel = _RGB32(58, 78, 112)
    cGood = _RGB32(120, 210, 140)
    cWarn = _RGB32(240, 220, 70)
    cErr = _RGB32(240, 90, 90)
    cLive = _RGB32(70, 150, 100)
    cDead = _RGB32(150, 120, 60)
End Sub

' Wheel notches are totalled while draining the queue
' (PollMouse alone would drop them). +down, -up.
Function PollInput% ()
    Dim w As Integer
    Do While _MouseInput
        w = w + _MouseWheel
    Loop
    PollMouse
    PollInput% = w
End Function

Sub SetStatus (msg As String, clr As _Unsigned Long)
    statusMsg = msg
    statusClr = clr
End Sub


'==========================================================
' Remembered paths (~/.rfsgui: volume, host folder)
'==========================================================
Sub lastLoad
    Dim fh As Integer, a As String
    If Not _FileExists(cfgPath) Then Exit Sub
    fh = FreeFile
    Open cfgPath For Input As #fh
    If Not EOF(fh) Then Line Input #fh, a: rfsVolPath = a
    If Not EOF(fh) Then Line Input #fh, a: lastHostDir = a
    If Not EOF(fh) Then
        Line Input #fh, a
        If Len(a) Then rfsLevel = _Clamp(Val(a), 0, 10)
    End If
    Close #fh
    lastVolDir = DirOf$(rfsVolPath)
End Sub

Sub lastSave
    Dim fh As Integer
    fh = FreeFile
    Open cfgPath For Output As #fh
    Print #fh, rfsVolPath
    Print #fh, lastHostDir
    Print #fh, LTrim$(Str$(rfsLevel))
    Close #fh
End Sub


'==========================================================
' Input
'==========================================================
Sub HandleKey (k As String)
    Dim i As Long
    Select Case k
        Case Chr$(0) + Chr$(72): MoveCur curRow - 1
        Case Chr$(0) + Chr$(80): MoveCur curRow + 1
        Case Chr$(0) + Chr$(73): MoveCur curRow - VIS_ROWS
        Case Chr$(0) + Chr$(81): MoveCur curRow + VIS_ROWS
        Case Chr$(0) + Chr$(71): MoveCur 0
        Case Chr$(0) + Chr$(79): MoveCur viewCount - 1
        Case Chr$(13): pendingAct = ACT_EXTRACT
        Case Chr$(0) + Chr$(83): pendingAct = ACT_DELETE
        Case Chr$(0) + Chr$(82): pendingAct = ACT_ADD
        Case Chr$(0) + Chr$(63): pendingAct = ACT_CHECK
        Case Chr$(0) + Chr$(64): pendingAct = ACT_ADDDIR
        Case Chr$(0) + Chr$(65): pendingAct = ACT_GETDIR
        Case Chr$(1)
            For i = 0 To rfsCount - 1: selFlag(i) = -1: Next
        Case Chr$(27)
            ClearSel
        Case "+", "="
            SetLevel rfsLevel + 1
        Case "-"
            SetLevel rfsLevel - 1
    End Select
End Sub

' Keyboard move: selects just the row under the cursor.
Sub MoveCur (r As Long)
    If viewCount = 0 Then Exit Sub
    curRow = r
    If curRow < 0 Then curRow = 0
    If curRow > viewCount - 1 Then curRow = viewCount - 1
    ClearSel
    selFlag(viewIdx(curRow)) = -1
    anchorRow = curRow
    If curRow < topRow Then topRow = curRow
    If curRow > topRow + VIS_ROWS - 1 Then topRow = curRow - VIS_ROWS + 1
End Sub

Sub ScrollBy (n As Integer)
    topRow = topRow + n
    If topRow > viewCount - VIS_ROWS Then topRow = viewCount - VIS_ROWS
    If topRow < 0 Then topRow = 0
End Sub

Sub HandleListMouse
    Dim mx As Integer, my As Integer, r As Long, i As Long, lo As Long, hi As Long
    Dim ctrl As Integer, shift As Integer, col As Integer

    If Not gMouse.clicked Or Not rfsMounted Then Exit Sub
    mx = gMouse.mx: my = gMouse.my
    If mx < LIST_X Or mx > LIST_X + LIST_W Then Exit Sub

    ' header: sort
    If my >= HDR_Y And my < HDR_Y + ROW_H Then
        mx = mx - LIST_X
        If mx < COL_SIZE_R - 80 Then
            col = 0
        ElseIf mx < COL_SIZE_R + 10 Then
            col = 1
        ElseIf mx < COL_STORED_R + 10 Then
            col = 2
        ElseIf mx < COL_RATIO_R + 10 Then
            col = 3
        Else
            col = 4
        End If
        If col = sortCol Then sortDesc = Not sortDesc Else sortCol = col: sortDesc = 0
        RebuildView
        Exit Sub
    End If

    ' rows
    If my < ROW_Y0 Or my >= ROW_Y0 + VIS_ROWS * ROW_H Then Exit Sub
    r = topRow + (my - ROW_Y0) \ ROW_H
    If r >= viewCount Then ClearSel: Exit Sub

    ctrl = _KeyDown(100305) Or _KeyDown(100306)
    shift = _KeyDown(100303) Or _KeyDown(100304)

    If shift Then
        If Not ctrl Then ClearSel
        lo = anchorRow: hi = r
        If lo > hi Then Swap lo, hi
        For i = lo To hi
            selFlag(viewIdx(i)) = -1
        Next
    ElseIf ctrl Then
        selFlag(viewIdx(r)) = Not selFlag(viewIdx(r))
        anchorRow = r
    Else
        If r = lastClickRow And Timer - lastClickT < DBLCLICK Then pendingAct = ACT_EXTRACT
        ClearSel
        selFlag(viewIdx(r)) = -1
        anchorRow = r
    End If
    curRow = r
    lastClickRow = r
    lastClickT = Timer
End Sub

Sub HandleDrops
    Dim n As Long, i As Long, anyDir As Integer
    n = _TotalDroppedFiles
    If n = 0 Then Exit Sub
    ReDim dropped(1 To n) As String
    For i = 1 To n
        dropped(i) = _DroppedFile$(i)
    Next
    _FinishDrop

    If Not rfsMounted Then
        If n = 1 And LCase$(Right$(dropped(1), 4)) = ".rfs" Then
            MountVol dropped(1)
        Else
            SetStatus "Mount or create a volume first, then drop files onto it.", cWarn
        End If
        Exit Sub
    End If

    addedCount = 0: addedBytes = 0
    For i = 1 To n
        If _DirExists(dropped(i)) Then
            anyDir = -1
            If Not AddFolder%(dropped(i)) Then Exit For
        ElseIf Not AddOne%(dropped(i)) Then
            Exit For
        End If
    Next
    AfterChange
    lastSave
    ' a folder add sets its own, more detailed status
    If addedCount And Not anyDir Then AddedStatus
End Sub


'==========================================================
' View / selection
'==========================================================
Sub ClearSel
    Dim i As Long
    For i = 0 To UBound(selFlag)
        selFlag(i) = 0
    Next
End Sub

Function SelCount& ()
    Dim i As Long, n As Long
    For i = 0 To rfsCount - 1
        If selFlag(i) Then n = n + 1
    Next
    SelCount& = n
End Function

' Selection, or the cursor row if nothing is selected.
Function EnsureSel& ()
    If SelCount& = 0 And curRow >= 0 And curRow < viewCount Then selFlag(viewIdx(curRow)) = -1
    EnsureSel& = SelCount&
End Function

Function FirstSel& ()
    Dim i As Long
    FirstSel& = -1
    For i = 0 To rfsCount - 1
        If selFlag(i) Then FirstSel& = i: Exit Function
    Next
End Function

' After the catalog changed: fresh flags, re-sort.
Sub AfterChange
    ReDim selFlag(0 To rfsCount) As Integer
    ReDim badFlag(0 To rfsCount) As Integer
    RebuildView
End Sub

Function StampKey$ (s As String)
    ' "mm-dd-yyyy hh:mm:ss" -> "yyyymmdd hh:mm:ss"
    StampKey$ = Mid$(s, 7, 4) + Left$(s, 2) + Mid$(s, 4, 2) + Mid$(s, 11)
End Function

Function RatioOf# (i As Long)
    If rfsSize(i) = 0 Then RatioOf# = 0 Else RatioOf# = rfsStored(i) / rfsSize(i)
End Function

Function ViewLess% (a As Long, b As Long)
    Dim res As Integer
    Select Case sortCol
        Case 1
            If rfsSize(a) <> rfsSize(b) Then res = (rfsSize(a) < rfsSize(b)): GoTo decided
        Case 2
            If rfsStored(a) <> rfsStored(b) Then res = (rfsStored(a) < rfsStored(b)): GoTo decided
        Case 3
            If RatioOf#(a) <> RatioOf#(b) Then res = (RatioOf#(a) < RatioOf#(b)): GoTo decided
        Case 4
            If rfsStamp(a) <> rfsStamp(b) Then res = (StampKey$(rfsStamp(a)) < StampKey$(rfsStamp(b))): GoTo decided
    End Select
    res = (UCase$(rfsName(a)) < UCase$(rfsName(b)))
    decided:
    If sortDesc Then res = Not res
    ViewLess% = res
End Function

Sub RebuildView
    Dim i As Long, j As Long, t As Long
    viewCount = rfsCount
    ReDim viewIdx(0 To viewCount) As Long
    For i = 0 To viewCount - 1
        viewIdx(i) = i
    Next
    For i = 1 To viewCount - 1
        t = viewIdx(i)
        j = i - 1
        Do While j >= 0
            If Not ViewLess%(t, viewIdx(j)) Then Exit Do
            viewIdx(j + 1) = viewIdx(j)
            j = j - 1
        Loop
        viewIdx(j + 1) = t
    Next
    If curRow > viewCount - 1 Then curRow = viewCount - 1
    If curRow < 0 Then curRow = 0
    ScrollBy 0
End Sub


'==========================================================
' Drawing
'==========================================================
Sub TextAt (x As Integer, y As Integer, s As String, clr As _Unsigned Long)
    Color clr
    _PrintString (x, y), s
End Sub

Sub TextRight (xr As Integer, y As Integer, s As String, clr As _Unsigned Long)
    Color clr
    _PrintString (xr - 8 * Len(s), y), s
End Sub

Sub DrawHeader
    Dim px As Integer, room As Integer
    TextAt 12, 12, "RFS", cGood
    If rfsMounted Then
        TextAt 52, 12, rfsLabel, cHdr
        px = 52 + 8 * (Len(rfsLabel) + 2)
        room = (LVL_X - 16 - px) \ 8
        If room > 0 Then TextAt px, 12, Right$(rfsVolPath, room), cDim
    Else
        TextAt 52, 12, "no volume mounted", cDim
    End If

    ' compression level: label + [-] [+]
    TextAt LVL_X, 12, "Compression " + LTrim$(Str$(rfsLevel)) + " " + LevelName$(rfsLevel), cFG
    If ButtonEx%(LIST_X + LIST_W - 70, 6, 32, 24, "-", (rfsLevel > 0)) Then SetLevel rfsLevel - 1
    If ButtonEx%(LIST_X + LIST_W - 32, 6, 32, 24, "+", (rfsLevel < 10)) Then SetLevel rfsLevel + 1
End Sub

Function LevelName$ (lv As Integer)
    Select Case lv
        Case 0: LevelName$ = "off (store only)"
        Case 1 To 3: LevelName$ = "fast"
        Case 4 To 6: LevelName$ = "normal"
        Case 7 To 8: LevelName$ = "high"
        Case Else: LevelName$ = "max"
    End Select
End Function

Sub SetLevel (lv As Integer)
    If lv < 0 Or lv > 10 Or lv = rfsLevel Then Exit Sub
    rfsLevel = lv
    lastSave
    SetStatus "Compression " + LTrim$(Str$(rfsLevel)) + " (" + LevelName$(rfsLevel) + ") - used for files added from now on.", cDim
End Sub

Sub DrawToolbar
    Dim bx As Integer, m As Integer, s As Integer
    m = rfsMounted
    s = m And (SelCount& > 0 Or viewCount > 0)
    bx = LIST_X
    If Button%(bx, TB_Y, BW, BH, "New Volume") Then pendingAct = ACT_NEW
    bx = bx + BSTEP
    If Button%(bx, TB_Y, BW, BH, "Mount") Then pendingAct = ACT_MOUNT
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Add Files", m) Then pendingAct = ACT_ADD
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Add Folder", m) Then pendingAct = ACT_ADDDIR
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Extract", s) Then pendingAct = ACT_EXTRACT
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Get Folder", s) Then pendingAct = ACT_GETDIR
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Delete", s) Then pendingAct = ACT_DELETE
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Verify", s) Then pendingAct = ACT_VERIFY
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Check", m) Then pendingAct = ACT_CHECK
    bx = bx + BSTEP
    If ButtonEx%(bx, TB_Y, BW, BH, "Compact", m) Then pendingAct = ACT_COMPACT
End Sub

Function SortTag$ (col As Integer)
    If col <> sortCol Then Exit Function
    If sortDesc Then SortTag$ = " v" Else SortTag$ = " ^"
End Function

Sub DrawList
    Dim i As Long, r As Long, idx As Long, y As Integer, clr As _Unsigned Long
    Dim trackH As Integer, thumbH As Integer, thumbY As Integer, nm As String

    Line (LIST_X, HDR_Y)-(LIST_X + LIST_W, ROW_Y0 + VIS_ROWS * ROW_H + 2), cPanel, BF

    If Not rfsMounted Then
        TextAt LIST_X + 24, ROW_Y0 + 40, "No volume mounted.", cFG
        TextAt LIST_X + 24, ROW_Y0 + 64, "New Volume creates one, Mount opens one.", cDim
        TextAt LIST_X + 24, ROW_Y0 + 84, "You can also drop a .rfs file onto this window.", cDim
        Exit Sub
    End If

    ' header
    Line (LIST_X, HDR_Y)-(LIST_X + LIST_W, HDR_Y + ROW_H - 1), _RGB32(38, 42, 54), BF
    TextAt LIST_X + COL_NAME, HDR_Y + 1, "Name" + SortTag$(0), cHdr
    TextRight LIST_X + COL_SIZE_R, HDR_Y + 1, "Size" + SortTag$(1), cHdr
    TextRight LIST_X + COL_STORED_R, HDR_Y + 1, "Stored" + SortTag$(2), cHdr
    TextRight LIST_X + COL_RATIO_R, HDR_Y + 1, "Ratio" + SortTag$(3), cHdr
    TextAt LIST_X + COL_ADDED, HDR_Y + 1, "Added" + SortTag$(4), cHdr

    If viewCount = 0 Then
        TextAt LIST_X + 24, ROW_Y0 + 40, "Empty volume.", cFG
        TextAt LIST_X + 24, ROW_Y0 + 64, "Add Files / Add Folder, or drop them onto this window.", cDim
        Exit Sub
    End If

    For i = 0 To VIS_ROWS - 1
        r = topRow + i
        If r >= viewCount Then Exit For
        idx = viewIdx(r)
        y = ROW_Y0 + i * ROW_H
        If selFlag(idx) Then Line (LIST_X, y)-(LIST_X + LIST_W - 10, y + ROW_H - 1), cSel, BF
        If r = curRow Then Line (LIST_X, y)-(LIST_X + LIST_W - 10, y + ROW_H - 1), cDim, B
        If badFlag(idx) Then clr = cErr Else clr = cFG

        nm = rfsName(idx)
        ' keep the end of long paths - the file name matters most
        If Len(nm) > NAME_CHARS Then nm = "..." + Right$(nm, NAME_CHARS - 3)
        TextAt LIST_X + COL_NAME, y + 1, nm, clr
        TextRight LIST_X + COL_SIZE_R, y + 1, FmtSize$(rfsSize(idx)), clr
        TextRight LIST_X + COL_STORED_R, y + 1, FmtSize$(rfsStored(idx)), clr
        TextRight LIST_X + COL_RATIO_R, y + 1, Ratio$(idx), clr
        TextAt LIST_X + COL_ADDED, y + 1, rfsStamp(idx), cDim
    Next

    ' scroll thumb
    If viewCount > VIS_ROWS Then
        trackH = VIS_ROWS * ROW_H
        thumbH = trackH * VIS_ROWS \ viewCount
        If thumbH < 16 Then thumbH = 16
        thumbY = ROW_Y0 + (trackH - thumbH) * topRow \ (viewCount - VIS_ROWS)
        Line (LIST_X + LIST_W - 6, ROW_Y0)-(LIST_X + LIST_W - 2, ROW_Y0 + trackH), cField, BF
        Line (LIST_X + LIST_W - 6, thumbY)-(LIST_X + LIST_W - 2, thumbY + thumbH), cDim, BF
    End If
End Sub

Sub DrawSpace
    Dim cap As _Integer64, used As _Integer64, live As _Integer64, dead As _Integer64
    Dim wLive As Long, wUsed As Long, s As String

    If Not rfsMounted Then Exit Sub
    cap = rfsVolSize
    used = rfsTail
    live = RFSLiveBytes&&
    dead = used - RFS_DATA_START - live - rfsCatLen
    If dead < 0 Then dead = 0

    Line (LIST_X, SPACE_Y)-(LIST_X + LIST_W, SPACE_Y + 12), cPanel, BF
    wUsed = LIST_W * used \ cap
    wLive = LIST_W * (live + RFS_DATA_START) \ cap
    If wLive < 1 Then wLive = 1
    If wUsed > wLive Then Line (LIST_X + wLive, SPACE_Y)-(LIST_X + wUsed, SPACE_Y + 12), cDead, BF
    Line (LIST_X, SPACE_Y)-(LIST_X + wLive, SPACE_Y + 12), cLive, BF

    s = LTrim$(Str$(rfsCount)) + " files   Used " + FmtSize$(used) + " of " + FmtSize$(cap)
    s = s + "   Live " + FmtSize$(live) + "   Reclaimable " + FmtSize$(dead)
    TextAt LIST_X, SPACE_Y + 20, s, cFG
    If dead > 1048576 And dead * 4 > used - RFS_DATA_START Then TextAt LIST_X + 8 * Len(s) + 16, SPACE_Y + 20, "Compact would free this", cWarn
End Sub

Sub DrawStatus
    TextAt LIST_X, STATUS_Y, Left$(statusMsg, LIST_W \ 8), statusClr
    TextAt LIST_X, HINT_Y, "Ctrl/Shift+click multi-select   Double-click extract   Del delete   Ctrl+A all   Drop files/folders to add", cDim
End Sub

' Busy bar for work the library doesn't report itself.
Sub Busy (txt As String, frac As Double)
    Dim fw As Long
    Line (LIST_X, BAR_Y)-(LIST_X + LIST_W, BAR_Y + 18), cPanel, BF
    fw = LIST_W * frac
    If fw > 0 Then Line (LIST_X, BAR_Y)-(LIST_X + fw, BAR_Y + 18), cLive, BF
    TextAt LIST_X + 8, BAR_Y + 2, txt, cHdr
    _Display
    Do While _MouseInput: Loop
End Sub


'==========================================================
' Modal dialogs. They draw over a snapshot of the last
' frame, dimmed. prompt lines are separated with "|".
'==========================================================
Sub DrawPanel (bg As Long, title As String, prompt As String, px As Integer, py As Integer, pw As Integer, ph As Integer)
    Dim ln As String, rest As String, p As Long, y As Integer
    _PutImage , bg
    Line (0, 0)-(SW, SH), _RGBA32(0, 0, 0, 150), BF
    Line (px, py)-(px + pw, py + ph), cPanel, BF
    Line (px, py)-(px + pw, py + ph), cDim, B
    TextAt px + 16, py + 12, title, cHdr
    rest = prompt
    y = py + 38
    Do While Len(rest)
        p = InStr(rest, "|")
        If p Then ln = Left$(rest, p - 1): rest = Mid$(rest, p + 1) Else ln = rest: rest = ""
        TextAt px + 16, y, ln, cFG
        y = y + 18
    Loop
End Sub

Function InputBox$ (title As String, prompt As String, dflt As String, cancelled As Integer)
    Dim bg As Long, s As String, k As String, done As Integer, w As Integer
    Dim px As Integer, py As Integer, pw As Integer, ph As Integer, fy As Integer

    bg = _CopyImage(0)
    s = dflt
    cancelled = 0
    pw = 600: ph = 170
    px = (SW - pw) \ 2: py = (SH - ph) \ 2
    fy = py + ph - 88
    Do
        _Limit 60
        w = PollInput%
        k = InKey$
        If k = Chr$(13) Then
            done = -1
        ElseIf k = Chr$(27) Then
            cancelled = -1: done = -1
        ElseIf k = Chr$(8) Then
            If Len(s) Then s = Left$(s, Len(s) - 1)
        ElseIf Len(k) = 1 Then
            If Asc(k) >= 32 And Asc(k) <= 126 Then s = s + k
        End If

        DrawPanel bg, title, prompt, px, py, pw, ph
        Line (px + 16, fy)-(px + pw - 16, fy + 24), cField, BF
        Line (px + 16, fy)-(px + pw - 16, fy + 24), cDim, B
        TextAt px + 22, fy + 4, Right$(s, (pw - 48) \ 8) + "_", cHdr
        If Button%(px + pw - 240, py + ph - 46, 104, BH, "OK") Then done = -1
        If Button%(px + pw - 124, py + ph - 46, 104, BH, "Cancel") Then cancelled = -1: done = -1
        _Display
    Loop Until done
    _FreeImage bg
    InputBox$ = s
End Function

Function Confirm% (title As String, prompt As String)
    Dim bg As Long, k As String, res As Integer, w As Integer
    Dim px As Integer, py As Integer, pw As Integer, ph As Integer

    bg = _CopyImage(0)
    pw = 600: ph = 150
    px = (SW - pw) \ 2: py = (SH - ph) \ 2
    Do
        _Limit 60
        w = PollInput%
        k = UCase$(InKey$)
        If k = "Y" Or k = Chr$(13) Then res = 1
        If k = "N" Or k = Chr$(27) Then res = 2
        DrawPanel bg, title, prompt, px, py, pw, ph
        If Button%(px + pw - 240, py + ph - 46, 104, BH, "Yes") Then res = 1
        If Button%(px + pw - 124, py + ph - 46, 104, BH, "No") Then res = 2
        _Display
    Loop Until res
    _FreeImage bg
    If res = 1 Then Confirm% = -1
End Function


'==========================================================
' Actions
'==========================================================
Sub RunAction (act As Integer)
    Select Case act
        Case ACT_NEW: ActNew
        Case ACT_MOUNT: ActMount
        Case ACT_ADD: ActAdd
        Case ACT_EXTRACT: ActExtract
        Case ACT_DELETE: ActDelete
        Case ACT_VERIFY: ActVerify
        Case ACT_CHECK: ActCheck
        Case ACT_COMPACT: ActCompact
        Case ACT_ADDDIR: ActAddDir
        Case ACT_GETDIR: ActGetDir
    End Select
End Sub

Sub MountVol (f As String)
    If Not _FileExists(f) Then
        SetStatus "Volume not found: " + f + "  (stick not plugged in?)", cWarn
        Exit Sub
    End If
    If RFSMount%(f) Then
        AfterMount
        If Len(rfsError) Then
            SetStatus rfsError, cWarn
        Else
            SetStatus "Mounted " + rfsLabel + " - " + LTrim$(Str$(rfsCount)) + " files.", cGood
        End If
    Else
        AfterChange
        SetStatus rfsError, cErr
    End If
End Sub

Sub AfterMount
    curRow = 0: topRow = 0: anchorRow = 0
    AfterChange
    lastVolDir = DirOf$(rfsVolPath)
    lastSave
End Sub

Sub ActNew
    Dim f As String, lbl As String, sz As String, c As Integer, mb As _Integer64
    Dim d As String, fsType As String, allBytes As _Integer64, capBytes As _Integer64
    Dim fh As Integer, note As String, prompt As String, dflt As String

    f = _SaveFileDialog$("Create a new RFS volume", lastVolDir + "volume.rfs", "*.rfs", "RFS volume files")
    If Len(f) = 0 Then Exit Sub
    If LCase$(Right$(f, 4)) <> ".rfs" Then f = f + ".rfs"
    If _FileExists(f) Then
        If Not Confirm%("Replace volume?", BaseName$(f) + " already exists.|Everything stored in it will be lost.") Then Exit Sub
    End If
    lbl = InputBox$("New volume", "Volume label (up to 32 characters):", "STICK64", c)
    If c Then Exit Sub

    ' --- how much room is there for "ALL"? ---
    d = DirOf$(f)
    If Len(d) = 0 Then d = "."
    Busy "Checking free space...", 0
    allBytes = DiskFree&&(d, fsType)
    If allBytes >= 0 Then
        ' the old volume being replaced gives its space back
        If _FileExists(f) Then
            fh = FreeFile
            If RFSOpen%(fh, f, -1) Then allBytes = allBytes + LOF(fh): Close #fh
        End If
        allBytes = allBytes - ALL_MARGIN
        If fsType = "vfat" Or fsType = "msdos" Then
            If allBytes > FAT32_MAXCAP Then allBytes = FAT32_MAXCAP: note = ", FAT32 limit"
        End If
        allBytes = (allBytes \ 1048576) * 1048576
        If allBytes < 4 * 1048576 Then allBytes = -1
    End If

    If allBytes > 0 Then
        prompt = "Size cap in MB, or ALL = use all free space (" + FmtSize$(allBytes) + note + ")."
        prompt = prompt + "|Using ALL leaves no room on this disk for Compact's copy."
        dflt = "ALL"
    Else
        prompt = "Size cap in MB. (Couldn't read free space, so ALL is off.)"
        prompt = prompt + "|FAT32 sticks: 3900 at most. Compact needs room for a second copy."
        dflt = "3900"
    End If
    sz = InputBox$("New volume", prompt, dflt, c)
    If c Then Exit Sub
    sz = UCase$(LTrim$(RTrim$(sz)))

    If sz = "ALL" Or sz = "A" Then
        If allBytes <= 0 Then SetStatus "Free space unknown - enter a size in MB instead.", cErr: Exit Sub
        capBytes = allBytes
    Else
        mb = Val(sz)
        If mb < 4 Then SetStatus "Size must be at least 4 MB (or ALL).", cErr: Exit Sub
        capBytes = mb * 1048576
        If allBytes > 0 And capBytes > allBytes Then
            If Not Confirm%("Bigger than the disk", FmtSize$(capBytes) + " is more than the " + FmtSize$(allBytes) + " free.|Adds will fail when the disk fills. Use it anyway?") Then Exit Sub
        End If
    End If

    Busy "Formatting " + BaseName$(f) + "...", 0
    If RFSFormat%(f, lbl, capBytes) Then
        AfterMount
        SetStatus "Created " + rfsLabel + " (" + FmtSize$(rfsVolSize) + " cap) - ready for files.", cGood
    Else
        SetStatus rfsError, cErr
    End If
End Sub

Sub ActMount
    Dim f As String
    f = _OpenFileDialog$("Mount an RFS volume", lastVolDir, "*.rfs", "RFS volume files")
    If Len(f) Then MountVol f
End Sub

' Store one host file under its base name. Returns -1 on success.
Function AddOne% (hostPath As String)
    Dim nm As String
    nm = BaseName$(hostPath)
    If RFSFind&(nm) >= 0 Then
        If Not Confirm%("Replace file?", nm + " is already on the volume.|Replace it with the new copy?") Then AddOne% = -1: Exit Function
    End If
    rfsBarText = "Adding " + nm
    RFSProgress 0, 1
    If RFSPutFile%(hostPath, nm) Then
        lastHostDir = DirOf$(hostPath)
        addedCount = addedCount + 1
        addedBytes = addedBytes + rfsSize(RFSFind&(nm))
        AddOne% = -1
    Else
        SetStatus nm + ": " + rfsError, cErr
    End If
End Function

Sub ActAdd
    Dim picked As String, one As String, p As Long
    picked = _OpenFileDialog$("Add files to " + rfsLabel, lastHostDir, "*", "All files", -1)
    If Len(picked) = 0 Then Exit Sub
    addedCount = 0: addedBytes = 0
    Do While Len(picked)
        p = InStr(picked, "|")
        If p Then one = Left$(picked, p - 1): picked = Mid$(picked, p + 1) Else one = picked: picked = ""
        If Len(one) Then
            If Not AddOne%(one) Then AfterChange: Exit Sub
        End If
    Loop
    AfterChange
    lastSave
    AddedStatus
End Sub

Sub ActAddDir
    Dim folder As String, ok As Integer
    folder = _SelectFolderDialog$("Add which folder to " + rfsLabel + "?", lastHostDir)
    If Len(folder) = 0 Then Exit Sub
    addedCount = 0: addedBytes = 0
    ok = AddFolder%(folder)
    AfterChange
    lastSave
End Sub

' Extract a whole stored folder. Picking "a/b" into <dest> gives
' <dest>/b/... - the folder itself comes along, like a copy.
Sub ActGetDir
    Dim f As Long, pre As Long, nm As String, j As Long, cut As Long
    Dim pfx As String, folder As String, target As String
    Dim i As Long, n As Long, exists As Long, ok As Long

    If Not rfsMounted Then Exit Sub
    BuildFolderList
    If pfN = 0 Then SetStatus "No folders on this volume - files added one by one aren't in a folder.", cWarn: Exit Sub

    ' start the picker on the cursor file's folder
    pre = -1
    If curRow >= 0 And curRow < viewCount Then
        nm = rfsName(viewIdx(curRow))
        j = _InStrRev(nm, "/")
        If j > 1 Then pre = FolderIdx&(Left$(nm, j - 1))
    End If
    f = PickFolder&("Extract which folder?", pre)
    If f < 0 Then Exit Sub

    pfx = pfName(f) + "/"
    cut = _InStrRev(pfName(f), "/") ' leading chars to drop (0 = top level)
    folder = _SelectFolderDialog$("Extract " + pfx + " into which folder?", lastHostDir)
    If Len(folder) = 0 Then Exit Sub
    If Right$(folder, 1) <> PSEP Then folder = folder + PSEP

    For i = 0 To rfsCount - 1
        If Left$(rfsName(i), Len(pfx)) = pfx Then
            n = n + 1
            If _FileExists(folder + LocalPath$(Mid$(rfsName(i), cut + 1))) Then exists = exists + 1
        End If
    Next
    If exists Then
        If Not Confirm%("Overwrite?", LTrim$(Str$(exists)) + " of the" + Str$(n) + " files already exist there.|Overwrite them?") Then Exit Sub
    End If

    For i = 0 To rfsCount - 1
        If Left$(rfsName(i), Len(pfx)) = pfx Then
            target = folder + LocalPath$(Mid$(rfsName(i), cut + 1))
            rfsBarText = LTrim$(Str$(ok + 1)) + "/" + LTrim$(Str$(n)) + " " + Right$(Mid$(rfsName(i), cut + 1), 60)
            MakeParentDirs target
            If Not RFSGetFile%(rfsName(i), target) Then
                SetStatus rfsName(i) + ": " + rfsError + "  (" + LTrim$(Str$(ok)) + " files done before this)", cErr
                Exit Sub
            End If
            ok = ok + 1
        End If
    Next
    lastHostDir = folder
    lastSave
    SetStatus "Extracted " + pfx + " -" + Str$(ok) + " files into " + folder + "  (CRC verified)", cGood
End Sub

' Fill pfName/pfKey/pfFiles/pfBytes from the catalog names.
Sub BuildFolderList
    Dim i As Long, j As Long, n As Long, k As Long, nm As String, t As String, gap As Long
    ReDim tmpK(0 To 63) As String

    ' every folder prefix of every name (duplicates for now)
    For i = 0 To rfsCount - 1
        nm = rfsName(i)
        For j = 2 To Len(nm)
            If Mid$(nm, j, 1) = "/" Then
                If n > UBound(tmpK) Then ReDim _Preserve tmpK(0 To n * 2) As String
                tmpK(n) = SortKey$(Left$(nm, j - 1))
                n = n + 1
            End If
        Next
    Next

    ' shell sort
    gap = n \ 2
    Do While gap > 0
        For i = gap To n - 1
            t = tmpK(i)
            j = i
            Do While j >= gap
                If tmpK(j - gap) <= t Then Exit Do
                tmpK(j) = tmpK(j - gap)
                j = j - gap
            Loop
            tmpK(j) = t
        Next
        gap = gap \ 2
    Loop

    ' drop duplicates
    ReDim pfKey(0 To n) As String
    ReDim pfName(0 To n) As String
    ReDim pfFiles(0 To n) As Long
    ReDim pfBytes(0 To n) As _Integer64
    pfN = 0
    For i = 0 To n - 1
        If pfN = 0 Then
            pfKey(0) = tmpK(i): pfN = 1
        ElseIf tmpK(i) <> pfKey(pfN - 1) Then
            pfKey(pfN) = tmpK(i): pfN = pfN + 1
        End If
    Next
    For i = 0 To pfN - 1
        pfName(i) = pfKey(i)
        For j = 1 To Len(pfName(i))
            If Asc(pfName(i), j) = 1 Then Mid$(pfName(i), j, 1) = "/"
        Next
    Next

    ' each file counts toward every folder above it
    For i = 0 To rfsCount - 1
        nm = rfsName(i)
        For j = 2 To Len(nm)
            If Mid$(nm, j, 1) = "/" Then
                k = FolderIdx&(Left$(nm, j - 1))
                If k >= 0 Then pfFiles(k) = pfFiles(k) + 1: pfBytes(k) = pfBytes(k) + rfsSize(i)
            End If
        Next
    Next
End Sub

Function SortKey$ (nm As String)
    Dim s As String, i As Long
    s = nm
    For i = 1 To Len(s)
        If Mid$(s, i, 1) = "/" Then Mid$(s, i, 1) = Chr$(1)
    Next
    SortKey$ = s
End Function

' Binary search of the folder list; -1 if not there.
Function FolderIdx& (nm As String)
    Dim lo As Long, hi As Long, md As Long, k As String
    k = SortKey$(nm)
    lo = 0: hi = pfN - 1
    FolderIdx& = -1
    Do While lo <= hi
        md = (lo + hi) \ 2
        If pfKey(md) = k Then FolderIdx& = md: Exit Function
        If pfKey(md) < k Then lo = md + 1 Else hi = md - 1
    Loop
End Function

' Modal folder list. Returns the pfName index, or -1 if cancelled.
Function PickFolder& (title As String, pre As Long)
    Dim bg As Long, k As String, w As Integer, res As Integer, sel As Long, topR As Long
    Dim px As Integer, py As Integer, pw As Integer, ph As Integer
    Dim lx As Integer, ly As Integer, lw As Integer, rows As Integer
    Dim i As Long, j As Long, r As Long, y As Integer, depth As Integer
    Dim lastR As Long, lastT As Double, s As String, nm As String

    bg = _CopyImage(0)
    pw = 640: ph = 470
    px = (SW - pw) \ 2: py = (SH - ph) \ 2
    lx = px + 16: ly = py + 60: lw = pw - 32: rows = 18
    sel = pre
    If sel < 0 Then sel = 0
    topR = sel - rows \ 2
    lastR = -1

    Do
        _Limit 60
        w = PollInput%
        k = InKey$
        Select Case k
            Case Chr$(13): res = 1
            Case Chr$(27): res = 2
            Case Chr$(0) + Chr$(72): sel = sel - 1
            Case Chr$(0) + Chr$(80): sel = sel + 1
            Case Chr$(0) + Chr$(73): sel = sel - rows
            Case Chr$(0) + Chr$(81): sel = sel + rows
            Case Chr$(0) + Chr$(71): sel = 0
            Case Chr$(0) + Chr$(79): sel = pfN - 1
        End Select
        If w <> 0 Then topR = topR + w * 3

        If gMouse.clicked Then
            If gMouse.mx >= lx And gMouse.mx <= lx + lw And gMouse.my >= ly And gMouse.my < ly + rows * ROW_H Then
                r = topR + (gMouse.my - ly) \ ROW_H
                If r < pfN Then
                    If r = lastR And Timer - lastT < DBLCLICK Then res = 1
                    sel = r
                    lastR = r
                    lastT = Timer
                End If
            End If
        End If

        If sel < 0 Then sel = 0
        If sel > pfN - 1 Then sel = pfN - 1
        If Len(k) Then
            If sel < topR Then topR = sel
            If sel > topR + rows - 1 Then topR = sel - rows + 1
        End If
        If topR > pfN - rows Then topR = pfN - rows
        If topR < 0 Then topR = 0

        DrawPanel bg, title, "Double-click a folder, or pick one and press OK.", px, py, pw, ph
        Line (lx, ly)-(lx + lw, ly + rows * ROW_H), cField, BF
        For i = 0 To rows - 1
            r = topR + i
            If r >= pfN Then Exit For
            y = ly + i * ROW_H
            If r = sel Then Line (lx, y)-(lx + lw, y + ROW_H - 1), cSel, BF
            nm = pfName(r)
            depth = 0
            For j = 1 To Len(nm)
                If Mid$(nm, j, 1) = "/" Then depth = depth + 1
            Next
            s = String$(depth * 2, 32) + BaseName$(nm) + "/"
            If Len(s) > 48 Then s = Left$(s, 45) + "..."
            TextAt lx + 6, y + 1, s, cFG
            TextRight lx + lw - 110, y + 1, LTrim$(Str$(pfFiles(r))) + " files", cDim
            TextRight lx + lw - 8, y + 1, FmtSize$(pfBytes(r)), cDim
        Next
        TextAt lx, ly + rows * ROW_H + 10, Right$(pfName(sel) + "/", lw \ 8), cHdr
        If Button%(px + pw - 240, py + ph - 46, 104, BH, "OK") Then res = 1
        If Button%(px + pw - 124, py + ph - 46, 104, BH, "Cancel") Then res = 2
        _Display
    Loop Until res
    _FreeImage bg
    If res = 1 Then PickFolder& = sel Else PickFolder& = -1
End Function

' Add every file under dirPath, stored as "<folder name>/<path
' inside it>". Commits once at the end. Returns -1 to carry on
' (even if some files were skipped), 0 if it stopped.
Function AddFolder% (dirPath As String)
    Dim d As String, top As String, n As Long, i As Long, total As _Integer64
    Dim dup As Long, replaceDup As Integer, nm As String, shown As String
    Dim added As Long, addBytes As _Integer64, kept As Long, skipped As Long
    Dim firstErr As String, stopped As Integer, roomLeft As _Integer64
    Dim msg As String, clr As _Unsigned Long

    d = dirPath
    Do While Len(d) > 1 And (Right$(d, 1) = "/" Or Right$(d, 1) = "\")
        d = Left$(d, Len(d) - 1)
    Loop
    top = BaseName$(d)
    If Len(top) = 0 Then top = "root"

    Busy "Scanning " + top + "...", 0
    n = ListFolder&(d)
    If n < 0 Then SetStatus "Couldn't list folder " + d + " (adding folders needs Linux).", cErr: Exit Function
    If n = 0 Then SetStatus "No files in " + top + ".", cWarn: AddFolder% = -1: Exit Function

    For i = 0 To n - 1
        total = total + fldSize(i)
        If RFSFind&(top + "/" + fldName(i)) >= 0 Then dup = dup + 1
    Next
    If dup Then
        replaceDup = Confirm%("Already stored", LTrim$(Str$(dup)) + " of the" + Str$(n) + " files in " + top + " are already on the volume.|Yes = replace them,  No = keep the stored copies.")
    End If
    roomLeft = rfsVolSize - rfsTail
    If total > roomLeft Then
        If Not Confirm%("May not fit", top + " holds " + FmtSize$(total) + ", the volume has " + FmtSize$(roomLeft) + " left.|It only fits if it compresses enough. Try anyway?") Then
            SetStatus "Folder add cancelled.", cDim
            Exit Function
        End If
    End If

    rfsDeferCommit = -1
    For i = 0 To n - 1
        nm = top + "/" + fldName(i)
        If RFSFind&(nm) >= 0 And Not replaceDup Then
            kept = kept + 1
        Else
            shown = fldName(i)
            If Len(shown) > 60 Then shown = "..." + Right$(shown, 57)
            rfsBarText = LTrim$(Str$(i + 1)) + "/" + LTrim$(Str$(n)) + " " + shown
            If RFSPutFile%(d + "/" + fldName(i), nm) Then
                added = added + 1
                addBytes = addBytes + fldSize(i)
            ElseIf Left$(rfsError, 15) = "Not enough room" Then
                firstErr = nm + ": " + rfsError
                stopped = -1
                Exit For
            Else
                skipped = skipped + 1
                If Len(firstErr) = 0 Then firstErr = nm + ": " + rfsError
            End If
        End If
    Next
    rfsDeferCommit = 0

    If added Then
        Busy "Saving catalog for " + top + "...", 1
        If Not RFSCommit% Then
            msg = rfsError
            MountVol rfsVolPath ' reload what's really on the stick
            SetStatus "Folder add failed at the catalog save: " + msg, cErr
            Exit Function
        End If
    End If
    addedCount = addedCount + added
    addedBytes = addedBytes + addBytes
    lastHostDir = DirOf$(d)

    msg = top + ": added" + Str$(added) + " file(s), " + FmtSize$(addBytes)
    clr = cGood
    If kept Then msg = msg + ", kept" + Str$(kept) + " already stored"
    If skipped Then msg = msg + "," + Str$(skipped) + " skipped - " + firstErr: clr = cWarn
    If stopped Then msg = msg + ". STOPPED - " + firstErr: clr = cErr
    SetStatus msg, clr
    AddFolder% = Not stopped
End Function

' Fill fldName()/fldSize() with every regular file under folder d
' (paths relative to d). Returns the count, or -1 if it can't list.
Function ListFolder& (d As String)
    Dim tmp As String, fh As Integer, ln As String, p As Long, n As Long
    ListFolder& = -1
    $If WINDOWS Then
        Exit Function
    $Else
        tmp = "/tmp/rfs_find.txt"
        If _FileExists(tmp) Then RFSTryKill tmp
        Shell _Hide "find -H " + ShQuote$(d) + " -type f -printf '%s %P\n' > " + tmp + " 2>/dev/null"
        If Not _FileExists(tmp) Then Exit Function
        ReDim fldName(0 To 255) As String
        ReDim fldSize(0 To 255) As _Integer64
        fh = FreeFile
        Open tmp For Input As #fh
        Do While Not EOF(fh)
            Line Input #fh, ln
            p = InStr(ln, " ")
            If p > 1 And p < Len(ln) Then
                If n > UBound(fldName) Then
                    ReDim _Preserve fldName(0 To n * 2) As String
                    ReDim _Preserve fldSize(0 To n * 2) As _Integer64
                End If
                fldSize(n) = Val(Left$(ln, p - 1))
                fldName(n) = Mid$(ln, p + 1)
                n = n + 1
            End If
        Loop
        Close #fh
        RFSTryKill tmp
        ListFolder& = n
    $End If
End Function

Sub AddedStatus
    If addedCount = 0 Then SetStatus "Nothing added.", cDim: Exit Sub
    SetStatus "Added" + Str$(addedCount) + " file(s), " + FmtSize$(addedBytes) + ".", cGood
End Sub

Sub ActExtract
    Dim n As Long, i As Long, idx As Long, f As String, folder As String, ok As Long, exists As Integer
    n = EnsureSel&
    If n = 0 Then Exit Sub

    If n = 1 Then
        idx = FirstSel&
        f = _SaveFileDialog$("Extract " + rfsName(idx), lastHostDir + BaseName$(rfsName(idx)), "*", "All files")
        If Len(f) = 0 Then Exit Sub
        rfsBarText = "Extracting " + rfsName(idx)
        If RFSGetFile%(rfsName(idx), f) Then
            lastHostDir = DirOf$(f)
            SetStatus "Extracted " + rfsName(idx) + " to " + f + "  (CRC verified)", cGood
        Else
            SetStatus rfsError, cErr
        End If
        Exit Sub
    End If

    folder = _SelectFolderDialog$("Extract" + Str$(n) + " files into which folder?", lastHostDir)
    If Len(folder) = 0 Then Exit Sub
    If Right$(folder, 1) <> PSEP Then folder = folder + PSEP
    For i = 0 To rfsCount - 1
        If selFlag(i) Then
            If _FileExists(folder + LocalPath$(rfsName(i))) Then exists = exists + 1
        End If
    Next
    If exists Then
        If Not Confirm%("Overwrite?", LTrim$(Str$(exists)) + " of these files already exist in that folder.|Overwrite them?") Then Exit Sub
    End If
    For i = 0 To rfsCount - 1
        If selFlag(i) Then
            rfsBarText = "Extracting " + rfsName(i)
            MakeParentDirs folder + LocalPath$(rfsName(i))
            If Not RFSGetFile%(rfsName(i), folder + LocalPath$(rfsName(i))) Then
                SetStatus rfsName(i) + ": " + rfsError, cErr
                Exit Sub
            End If
            ok = ok + 1
        End If
    Next
    lastHostDir = folder
    SetStatus "Extracted" + Str$(ok) + " files to " + folder + "  (CRC verified)", cGood
End Sub

Sub ActDelete
    Dim n As Long, i As Long, msg As String
    n = EnsureSel&
    If n = 0 Then Exit Sub
    If n = 1 Then msg = "Delete " + rfsName(FirstSel&) + "?" Else msg = "Delete" + Str$(n) + " files?"
    If Not Confirm%("Delete", msg + "|Space is given back by Compact.") Then Exit Sub

    ' drop from the end so indices stay valid, then one commit
    For i = rfsCount - 1 To 0 Step -1
        If selFlag(i) Then RFSDropEntry i
    Next
    Busy "Saving catalog...", 1
    If RFSCommit% Then
        SetStatus "Deleted" + Str$(n) + " file(s).", cGood
    Else
        SetStatus rfsError, cErr
    End If
    AfterChange
End Sub

Sub ActVerify
    Dim n As Long, i As Long, idx As Long, f As String, folder As String
    Dim same As Long, diff As Long, missing As Long, firstBad As String
    n = EnsureSel&
    If n = 0 Then Exit Sub

    If n = 1 Then
        idx = FirstSel&
        f = _OpenFileDialog$("Compare " + rfsName(idx) + " with which file?", lastHostDir + BaseName$(rfsName(idx)), "*", "All files")
        If Len(f) = 0 Then Exit Sub
        Busy "Comparing " + rfsName(idx) + "...", 0
        If RFSCompareFile%(rfsName(idx), f) Then
            SetStatus "Identical: " + rfsName(idx) + " = " + f, cGood
        Else
            SetStatus "DIFFERENT: " + rfsError, cErr
        End If
        Exit Sub
    End If

    folder = _SelectFolderDialog$("Compare" + Str$(n) + " files with the ones in which folder?", lastHostDir)
    If Len(folder) = 0 Then Exit Sub
    If Right$(folder, 1) <> PSEP Then folder = folder + PSEP
    ReDim badFlag(0 To rfsCount) As Integer
    For i = 0 To rfsCount - 1
        If selFlag(i) Then
            Busy "Comparing " + rfsName(i) + "...", (same + diff + missing) / n
            If Not _FileExists(folder + LocalPath$(rfsName(i))) Then
                missing = missing + 1
            ElseIf RFSCompareFile%(rfsName(i), folder + LocalPath$(rfsName(i))) Then
                same = same + 1
            Else
                diff = diff + 1
                badFlag(i) = -1
                If Len(firstBad) = 0 Then firstBad = rfsName(i) + ": " + rfsError
            End If
        End If
    Next
    If diff Then
        SetStatus LTrim$(Str$(diff)) + " differ (red)," + Str$(same) + " identical," + Str$(missing) + " not in folder. " + firstBad, cErr
    Else
        SetStatus LTrim$(Str$(same)) + " identical," + Str$(missing) + " not in that folder.", cGood
    End If
End Sub

Sub ActCheck
    Dim i As Long, bad As Long, firstBad As String
    ReDim badFlag(0 To rfsCount) As Integer
    For i = 0 To rfsCount - 1
        Busy "Checking " + rfsName(i) + "...", i / rfsCount
        If Not RFSCheckFile%(i) Then
            bad = bad + 1
            badFlag(i) = -1
            If Len(firstBad) = 0 Then firstBad = rfsName(i) + ": " + rfsError
        End If
    Next
    If bad Then
        SetStatus LTrim$(Str$(bad)) + " damaged file(s), shown in red. " + firstBad, cErr
    Else
        SetStatus "All" + Str$(rfsCount) + " files verified - every CRC good.", cGood
    End If
End Sub

Sub ActCompact
    Dim f As String, oldPath As String
    f = _SaveFileDialog$("Compact into a NEW volume file", lastVolDir + "compacted.rfs", "*.rfs", "RFS volume files")
    If Len(f) = 0 Then Exit Sub
    If LCase$(Right$(f, 4)) <> ".rfs" Then f = f + ".rfs"
    If f = rfsVolPath Then SetStatus "Pick a different file - compact writes a fresh copy.", cErr: Exit Sub
    If _FileExists(f) Then
        If Not Confirm%("Replace?", BaseName$(f) + " already exists. Replace it?") Then Exit Sub
    End If
    oldPath = rfsVolPath
    Busy "Compacting into " + BaseName$(f) + "...", 0
    If RFSCompact%(f) Then
        AfterMount
        SetStatus "Compacted into " + BaseName$(f) + ". Old volume left untouched: " + oldPath, cGood
    Else
        SetStatus rfsError, cErr
    End If
End Sub


'==========================================================
' Helpers
'==========================================================
Function BaseName$ (p As String)
    Dim i As Long
    For i = Len(p) To 1 Step -1
        If Mid$(p, i, 1) = "/" Or Mid$(p, i, 1) = "\" Then BaseName$ = Mid$(p, i + 1): Exit Function
    Next
    BaseName$ = p
End Function

' Folder part of a path, with trailing separator ("" if none).
Function DirOf$ (p As String)
    Dim i As Long
    For i = Len(p) To 1 Step -1
        If Mid$(p, i, 1) = "/" Or Mid$(p, i, 1) = "\" Then DirOf$ = Left$(p, i): Exit Function
    Next
End Function

' Stored name -> relative path on this OS. A name that could climb
' out of the target folder (absolute, or with a .. part) is cut
' back to its base name.
Function LocalPath$ (nm As String)
    Dim s As String, i As Long
    s = nm
    If Left$(s, 1) = "/" Or InStr("/" + s + "/", "/../") > 0 Then s = BaseName$(s)
    $If WINDOWS Then
        For i = 1 To Len(s)
            If Mid$(s, i, 1) = "/" Then Mid$(s, i, 1) = "\"
        Next
    $End If
    LocalPath$ = s
End Function

' Create every missing folder on the way to file path p.
Sub MakeParentDirs (p As String)
    Dim i As Long, part As String
    For i = 2 To Len(p)
        If Mid$(p, i, 1) = PSEP Then
            part = Left$(p, i - 1)
            If Not _DirExists(part) Then
                rfsIOErr = 0
                On Error GoTo RFSIOFail
                MkDir part
                On Error GoTo 0
            End If
        End If
    Next
End Sub

' Quote a path for sh: 'it'\''s' style.
Function ShQuote$ (s As String)
    Dim i As Long, r As String, ch As String
    r = "'"
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch = "'" Then r = r + "'\''" Else r = r + ch
    Next
    ShQuote$ = r + "'"
End Function

' Free bytes on the disk holding folder d, and its filesystem
' type (vfat, exfat, ext4...). Returns -1 if it can't tell.
Function DiskFree&& (d As String, fsType As String)
    Dim tmp As String, fh As Integer, a As String, b As String, p As Long
    DiskFree&& = -1
    fsType = ""
    $If WINDOWS Then
        Exit Function
    $Else
        tmp = "/tmp/rfs_df.txt"
        If _FileExists(tmp) Then RFSTryKill tmp
        Shell _Hide "df -B1 --output=avail,fstype " + ShQuote$(d) + " > " + tmp + " 2>/dev/null"
        If Not _FileExists(tmp) Then Exit Function
        fh = FreeFile
        Open tmp For Input As #fh
        If Not EOF(fh) Then Line Input #fh, a ' header: Avail Type
        If Not EOF(fh) Then Line Input #fh, b
        Close #fh
        RFSTryKill tmp
        b = LTrim$(RTrim$(b))
        p = InStr(b, " ")
        If p = 0 Then Exit Function
        fsType = LCase$(LTrim$(Mid$(b, p + 1)))
        If Val(Left$(b, p - 1)) <= 0 Then Exit Function
        DiskFree&& = Val(Left$(b, p - 1))
    $End If
End Function

Function FmtSize$ (n As _Integer64)
    Dim d As Double, u As Integer, units As String, t As _Integer64
    units = "B  KB MB GB TB"
    If n < 1024 Then FmtSize$ = LTrim$(Str$(n)) + " B": Exit Function
    d = n
    Do While d >= 1024 And u < 4
        d = d / 1024: u = u + 1
    Loop
    t = Int(d * 10 + 0.5)
    FmtSize$ = LTrim$(Str$(t \ 10)) + "." + LTrim$(Str$(t Mod 10)) + " " + RTrim$(Mid$(units, u * 3 + 1, 3))
End Function

Function Ratio$ (idx As Long)
    Dim pct As _Integer64
    If rfsSize(idx) = 0 Then Ratio$ = "-": Exit Function
    pct = Int(rfsStored(idx) * 100 / rfsSize(idx) + 0.5)
    If pct = 0 Then Ratio$ = "<1%" Else Ratio$ = LTrim$(Str$(pct)) + "%"
End Function

'$Include:'RFS.bm'
'$Include:'ButtonUI.bm'
