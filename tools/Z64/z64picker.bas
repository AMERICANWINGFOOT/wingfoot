' z64picker.bas -- graphical standalone file picker for QB64-PE 4.5.0
'
' 1024x768 windowed picker with dual-pane layout, drive strip,
' path bar, and full mouse + keyboard control.  Uses z64fs
' (compiled from z64fs.c) for directory enumeration so hidden
' folders like Downloads / Documents / AppData are visible.
'
' CLI contract (unchanged from the text-mode version):
'
'   z64picker.exe <output-file> [start-path]
'
'   output-file   Where to write picked paths (one per line).
'                 Overwritten if it exists.  Empty on cancel/none.
'   start-path    Optional.  Absolute path to start browsing.
'                 If omitted, opens on the process CWD.
'
' Exit codes:
'   0  Picked one or more files, output-file populated
'   1  User cancelled (ESC / Cancel button)
'   2  Picked zero files (OK button with nothing checked)
'   3  Internal error (no output-file given, etc.)
'
' Output format: one absolute path per line, Windows line endings.
_Title ("Z64 File Picker")
Option _Explicit
'$Dynamic

Declare Library "z64fs"
    Function z64fs_open& (path As String, ByVal flags As Long)
    Function z64fs_next& (ByVal handle As Long, nname As String, ByVal nmax As Long, attrs As Long)
    Sub z64fs_close (ByVal handle As Long)
    Function z64fs_stat& (path As String, attrs As Long)
End Declare

Const Z64FS_ATTR_DIR = 1

'--- Screen ---
Const SCR_W = 1024
Const SCR_H = 768

'--- Layout constants ---
Const DRIVE_STRIP_Y = 12
Const DRIVE_BTN_W = 42
Const DRIVE_BTN_H = 24
Const DRIVE_BTN_GAP = 6

Const PATH_Y = 48
Const PATH_X1 = 20
Const PATH_X2 = SCR_W - 130
Const PATH_H = 24

Const UP_BTN_X1 = SCR_W - 120
Const UP_BTN_X2 = SCR_W - 20
Const UP_BTN_Y1 = 48
Const UP_BTN_Y2 = 72

Const HDR_Y = 88
Const PANE_Y = 112
Const PANE_H = 560
Const ROW_H = 24
Const LEFT_PANE_X1 = 20
Const LEFT_PANE_X2 = 504
Const RIGHT_PANE_X1 = 520
Const RIGHT_PANE_X2 = SCR_W - 20
Const CHECKBOX_W = 14

Const STATUS_Y = 684
Const OK_BTN_X1 = SCR_W - 220
Const OK_BTN_X2 = SCR_W - 130
Const OK_BTN_Y1 = STATUS_Y
Const OK_BTN_Y2 = STATUS_Y + 40
Const CANCEL_BTN_X1 = SCR_W - 120
Const CANCEL_BTN_X2 = SCR_W - 20
Const CANCEL_BTN_Y1 = STATUS_Y
Const CANCEL_BTN_Y2 = STATUS_Y + 40

Const NAME_BUF = 260

'--- Exit codes ---
Const EXIT_OK = 0
Const EXIT_CANCEL = 1
Const EXIT_EMPTY = 2
Const EXIT_ERROR = 3

'--- Focus enum ---
Const FOCUS_LEFT = 0
Const FOCUS_RIGHT = 1


'=======================================================================
'   Startup
'=======================================================================

Dim outputFile$
Dim startPath$

If _CommandCount < 1 Then
    Print "z64picker -- graphical file picker"
    Print "Usage: z64picker <output-file> [start-path]"
    System EXIT_ERROR
End If

outputFile$ = Command$(1)
If _CommandCount >= 2 Then
    startPath$ = Command$(2)
    If Right$(startPath$, 1) <> "\" And Right$(startPath$, 1) <> "/" Then
        startPath$ = startPath$ + "\"
    End If
Else
    startPath$ = _CWD$
    If Right$(startPath$, 1) <> "\" Then startPath$ = startPath$ + "\"
End If

Screen _NewImage(SCR_W, SCR_H, 32)
_Title "z64picker"
_PrintMode _KeepBackground


'=======================================================================
'   Main state
'=======================================================================

Dim curPath$: curPath$ = startPath$
Dim curNames$(0)
Dim curIsDir(0) As Integer
Dim curSelected(0) As Integer
Dim curCount As Long: curCount = -1

Dim pickedList$(0)
Dim pickedCount As Long: pickedCount = -1

Dim drives$(25)
Dim driveCount As Long: driveCount = -1

Dim focus As Integer: focus = FOCUS_LEFT
Dim curL As Long: curL = 0
Dim topL As Long: topL = 0
Dim curR As Long: curR = 0
Dim topR As Long: topR = 0
Dim pageRows As Long: pageRows = PANE_H \ ROW_H
Dim dx As Long: dx = 20
Dim done As Integer: done = 0
Dim cancelled As Integer: cancelled = 0
Dim needReload As Integer: needReload = -1

Dim mx As Long, my As Long
Dim mb As Integer, lastMB As Integer
Dim wheelDelta As Long
Dim kkey$
Dim i As Long
Dim rowIdx As Long
Dim rowY As Long
Dim fullPath$
Dim clickHandled As Integer
_FullScreen
'--- Enumerate present drives once at startup ---
Dim d As Long
For d = Asc("A") To Asc("Z")
    If _DirExists(Chr$(d) + ":\") Then
        driveCount = driveCount + 1
        drives$(driveCount) = Chr$(d) + ":"
    End If
Next d


'=======================================================================
'   Main event loop
'=======================================================================

Do
    '--- Redraw ---
    Cls
    _Display


    If needReload Then
        LoadDir curPath$, curNames$(), curIsDir(), curCount
        ReDim curSelected(curCount + 1) As Integer
        For i = 0 To curCount
            fullPath$ = JoinPath$(curPath$, curNames$(i))
            If InPicked%(fullPath$, pickedList$(), pickedCount) Then
                curSelected(i) = -1
            End If
        Next i
        curL = 0: topL = 0
        needReload = 0
    End If


    '--- Drive strip ---
    dx = 20
    For i = 0 To driveCount
        If UCase$(Left$(curPath$, 2)) = drives$(i) Then
            Line (dx, DRIVE_STRIP_Y)-(dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H), _RGB32(70, 130, 90), BF
        ElseIf PtInRect(mx, my, dx, DRIVE_STRIP_Y, dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H) Then
            Line (dx, DRIVE_STRIP_Y)-(dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H), _RGB32(70, 90, 130), BF
        Else
            Line (dx, DRIVE_STRIP_Y)-(dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H), _RGB32(60, 65, 78), BF
        End If
        Line (dx, DRIVE_STRIP_Y)-(dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H), _RGB32(140, 160, 200), B
        Color _RGB32(255, 255, 255)
        _PrintString (dx + 12, DRIVE_STRIP_Y + 5), drives$(i)
        dx = dx + DRIVE_BTN_W + DRIVE_BTN_GAP
    Next i

    '--- Path bar ---
    Line (PATH_X1, PATH_Y)-(PATH_X2, PATH_Y + PATH_H), _RGB32(30, 33, 40), BF
    Line (PATH_X1, PATH_Y)-(PATH_X2, PATH_Y + PATH_H), _RGB32(120, 140, 180), B
    Color _RGB32(220, 230, 255)
    _PrintString (PATH_X1 + 8, PATH_Y + 5), TruncateLeft$(curPath$, 62)

    '--- Up button ---
    If PtInRect(mx, my, UP_BTN_X1, UP_BTN_Y1, UP_BTN_X2, UP_BTN_Y2) Then
        Line (UP_BTN_X1, UP_BTN_Y1)-(UP_BTN_X2, UP_BTN_Y2), _RGB32(80, 100, 140), BF
    Else
        Line (UP_BTN_X1, UP_BTN_Y1)-(UP_BTN_X2, UP_BTN_Y2), _RGB32(50, 70, 100), BF
    End If
    Line (UP_BTN_X1, UP_BTN_Y1)-(UP_BTN_X2, UP_BTN_Y2), _RGB32(180, 200, 240), B
    Color _RGB32(255, 255, 255)
    _PrintString (UP_BTN_X1 + 28, UP_BTN_Y1 + 6), Chr$(24) + " Up"

    '--- Pane headers ---
    Color _RGB32(180, 220, 255)
    _PrintString (LEFT_PANE_X1, HDR_Y), "Folder  (" + LTrim$(Str$(curCount + 1)) + " items)"
    _PrintString (RIGHT_PANE_X1, HDR_Y), "Picked files  (" + LTrim$(Str$(pickedCount + 1)) + " total)"

    '--- Left pane background ---
    Line (LEFT_PANE_X1 - 4, PANE_Y - 4)-(LEFT_PANE_X2, PANE_Y + PANE_H), _RGB32(28, 30, 36), BF

    '--- Left pane rows ---
    For i = 0 To pageRows - 1
        rowIdx = topL + i
        If rowIdx > curCount Then Exit For
        rowY = PANE_Y + i * ROW_H

        If focus = FOCUS_LEFT And rowIdx = curL Then
            Line (LEFT_PANE_X1 - 4, rowY)-(LEFT_PANE_X2, rowY + ROW_H - 2), _RGB32(70, 80, 110), BF
        ElseIf PtInRect(mx, my, LEFT_PANE_X1 - 4, rowY, LEFT_PANE_X2, rowY + ROW_H - 2) Then
            Line (LEFT_PANE_X1 - 4, rowY)-(LEFT_PANE_X2, rowY + ROW_H - 2), _RGB32(45, 50, 65), BF
        End If

        If curIsDir(rowIdx) Then
            Color _RGB32(180, 200, 230)
            _PrintString (LEFT_PANE_X1 + 4, rowY + 6), "[DIR]  " + TruncateRight$(curNames$(rowIdx), 52)
        Else
            DrawCheckbox LEFT_PANE_X1 + 4, rowY + 5, LEFT_PANE_X1 + 4 + CHECKBOX_W, rowY + 5 + CHECKBOX_W, curSelected(rowIdx)
            Color _RGB32(230, 230, 240)
            _PrintString (LEFT_PANE_X1 + 4 + CHECKBOX_W + 10, rowY + 6), TruncateRight$(curNames$(rowIdx), 50)
        End If
    Next i

    '--- Right pane background ---
    Line (RIGHT_PANE_X1 - 4, PANE_Y - 4)-(RIGHT_PANE_X2, PANE_Y + PANE_H), _RGB32(28, 30, 36), BF

    '--- Right pane rows ---
    If pickedCount < 0 Then
        Color _RGB32(140, 140, 160)
        _PrintString (RIGHT_PANE_X1 + 4, PANE_Y + 8), "(nothing picked yet)"
        _PrintString (RIGHT_PANE_X1 + 4, PANE_Y + 32), "Check boxes in the left pane."
    Else
        For i = 0 To pageRows - 1
            rowIdx = topR + i
            If rowIdx > pickedCount Then Exit For
            rowY = PANE_Y + i * ROW_H

            If focus = FOCUS_RIGHT And rowIdx = curR Then
                Line (RIGHT_PANE_X1 - 4, rowY)-(RIGHT_PANE_X2, rowY + ROW_H - 2), _RGB32(110, 70, 80), BF
            ElseIf PtInRect(mx, my, RIGHT_PANE_X1 - 4, rowY, RIGHT_PANE_X2, rowY + ROW_H - 2) Then
                Line (RIGHT_PANE_X1 - 4, rowY)-(RIGHT_PANE_X2, rowY + ROW_H - 2), _RGB32(60, 45, 50), BF
            End If

            Color _RGB32(230, 220, 220)
            _PrintString (RIGHT_PANE_X1 + 4, rowY + 6), TruncateLeft$(pickedList$(rowIdx), 58)
        Next i
    End If

    '--- Status line ---
    Color _RGB32(160, 180, 200)
    _PrintString (20, STATUS_Y + 12), "Picked: " + LTrim$(Str$(pickedCount + 1)) + " file(s)"
    _PrintString (20, STATUS_Y + 28), "SPC toggle   ENTER open dir   BKSP up   TAB switch pane   A/N all/none in folder"

    '--- OK button ---
    If PtInRect(mx, my, OK_BTN_X1, OK_BTN_Y1, OK_BTN_X2, OK_BTN_Y2) Then
        Line (OK_BTN_X1, OK_BTN_Y1)-(OK_BTN_X2, OK_BTN_Y2), _RGB32(90, 170, 90), BF
    Else
        Line (OK_BTN_X1, OK_BTN_Y1)-(OK_BTN_X2, OK_BTN_Y2), _RGB32(50, 110, 50), BF
    End If
    Line (OK_BTN_X1, OK_BTN_Y1)-(OK_BTN_X2, OK_BTN_Y2), _RGB32(180, 220, 180), B
    Color _RGB32(255, 255, 255)
    _PrintString (OK_BTN_X1 + 34, OK_BTN_Y1 + 16), "OK"

    '--- Cancel button ---
    If PtInRect(mx, my, CANCEL_BTN_X1, CANCEL_BTN_Y1, CANCEL_BTN_X2, CANCEL_BTN_Y2) Then
        Line (CANCEL_BTN_X1, CANCEL_BTN_Y1)-(CANCEL_BTN_X2, CANCEL_BTN_Y2), _RGB32(170, 90, 90), BF
    Else
        Line (CANCEL_BTN_X1, CANCEL_BTN_Y1)-(CANCEL_BTN_X2, CANCEL_BTN_Y2), _RGB32(110, 50, 50), BF
    End If
    Line (CANCEL_BTN_X1, CANCEL_BTN_Y1)-(CANCEL_BTN_X2, CANCEL_BTN_Y2), _RGB32(220, 180, 180), B
    Color _RGB32(255, 255, 255)
    _PrintString (CANCEL_BTN_X1 + 24, CANCEL_BTN_Y1 + 16), "Cancel"

    _Display

    '--- Input ---
    kkey$ = InKey$
    While _MouseInput
        wheelDelta = wheelDelta + _MouseWheel
    Wend
    mx = _MouseX
    my = _MouseY
    mb = _MouseButton(1)

    '--- Mouse click handling ---
    If mb And Not lastMB Then
        clickHandled = 0

        If PtInRect(mx, my, OK_BTN_X1, OK_BTN_Y1, OK_BTN_X2, OK_BTN_Y2) Then
            done = -1
            clickHandled = -1
        End If

        If Not clickHandled And PtInRect(mx, my, CANCEL_BTN_X1, CANCEL_BTN_Y1, CANCEL_BTN_X2, CANCEL_BTN_Y2) Then
            cancelled = -1
            done = -1
            clickHandled = -1
        End If

        If Not clickHandled And PtInRect(mx, my, UP_BTN_X1, UP_BTN_Y1, UP_BTN_X2, UP_BTN_Y2) Then
            curPath$ = ParentPath$(curPath$)
            needReload = -1
            clickHandled = -1
        End If

        If Not clickHandled Then
            dx = 20
            For i = 0 To driveCount
                If PtInRect(mx, my, dx, DRIVE_STRIP_Y, dx + DRIVE_BTN_W, DRIVE_STRIP_Y + DRIVE_BTN_H) Then
                    curPath$ = drives$(i) + "\"
                    needReload = -1
                    clickHandled = -1
                    Exit For
                End If
                dx = dx + DRIVE_BTN_W + DRIVE_BTN_GAP
            Next i
        End If

        If Not clickHandled Then
            For i = 0 To pageRows - 1
                rowIdx = topL + i
                If rowIdx > curCount Then Exit For
                rowY = PANE_Y + i * ROW_H
                If PtInRect(mx, my, LEFT_PANE_X1 - 4, rowY, LEFT_PANE_X2, rowY + ROW_H - 2) Then
                    focus = FOCUS_LEFT
                    curL = rowIdx
                    If curIsDir(rowIdx) Then
                        If curNames$(rowIdx) = ".." Then
                            curPath$ = ParentPath$(curPath$)
                        Else
                            curPath$ = JoinPath$(curPath$, curNames$(rowIdx))
                            If Right$(curPath$, 1) <> "\" Then curPath$ = curPath$ + "\"
                        End If
                        needReload = -1
                    Else
                        ToggleFilePick curPath$, curNames$(rowIdx), _
                            pickedList$(), pickedCount, curSelected(), rowIdx
                    End If
                    clickHandled = -1
                    Exit For
                End If
            Next i
        End If

        If Not clickHandled Then
            For i = 0 To pageRows - 1
                rowIdx = topR + i
                If rowIdx > pickedCount Then Exit For
                rowY = PANE_Y + i * ROW_H
                If PtInRect(mx, my, RIGHT_PANE_X1 - 4, rowY, RIGHT_PANE_X2, rowY + ROW_H - 2) Then
                    focus = FOCUS_RIGHT
                    curR = rowIdx
                    clickHandled = -1
                    Exit For
                End If
            Next i
        End If
    End If
    lastMB = mb

    '--- Mouse wheel scroll ---
    If wheelDelta <> 0 Then
        If focus = FOCUS_LEFT Then
            topL = topL + wheelDelta
            If topL < 0 Then topL = 0
            If topL > curCount - pageRows + 1 Then topL = curCount - pageRows + 1
            If topL < 0 Then topL = 0
        Else
            topR = topR + wheelDelta
            If topR < 0 Then topR = 0
            If topR > pickedCount - pageRows + 1 Then topR = pickedCount - pageRows + 1
            If topR < 0 Then topR = 0
        End If
        wheelDelta = 0
    End If

    '--- Keyboard ---
    If kkey$ <> "" Then
        Select Case kkey$
            Case Chr$(9)
                If focus = FOCUS_LEFT Then focus = FOCUS_RIGHT Else focus = FOCUS_LEFT

            Case Chr$(13)
                If focus = FOCUS_LEFT And curL <= curCount Then
                    If curIsDir(curL) Then
                        If curNames$(curL) = ".." Then
                            curPath$ = ParentPath$(curPath$)
                        Else
                            curPath$ = JoinPath$(curPath$, curNames$(curL))
                            If Right$(curPath$, 1) <> "\" Then curPath$ = curPath$ + "\"
                        End If
                        needReload = -1
                    Else
                        ToggleFilePick curPath$, curNames$(curL), _
                            pickedList$(), pickedCount, curSelected(), curL
                    End If
                End If

            Case Chr$(27)
                cancelled = -1
                done = -1

            Case " "
                If focus = FOCUS_LEFT And curL <= curCount Then
                    If Not curIsDir(curL) Then
                        ToggleFilePick curPath$, curNames$(curL), _
                            pickedList$(), pickedCount, curSelected(), curL
                    End If
                ElseIf focus = FOCUS_RIGHT And curR <= pickedCount Then
                    fullPath$ = pickedList$(curR)
                    RemoveFromPicked fullPath$, pickedList$(), pickedCount
                    For i = 0 To curCount
                        If JoinPath$(curPath$, curNames$(i)) = fullPath$ Then
                            curSelected(i) = 0
                            Exit For
                        End If
                    Next i
                End If

            Case Chr$(8)
                curPath$ = ParentPath$(curPath$)
                needReload = -1

            Case Chr$(0) + Chr$(72)
                If focus = FOCUS_LEFT Then
                    If curL > 0 Then curL = curL - 1
                    If curL < topL Then topL = curL
                Else
                    If curR > 0 Then curR = curR - 1
                    If curR < topR Then topR = curR
                End If

            Case Chr$(0) + Chr$(80)
                If focus = FOCUS_LEFT Then
                    If curL < curCount Then curL = curL + 1
                    If curL >= topL + pageRows Then topL = curL - pageRows + 1
                Else
                    If curR < pickedCount Then curR = curR + 1
                    If curR >= topR + pageRows Then topR = curR - pageRows + 1
                End If

            Case Chr$(0) + Chr$(73)
                If focus = FOCUS_LEFT Then
                    curL = curL - pageRows
                    If curL < 0 Then curL = 0
                    topL = curL
                Else
                    curR = curR - pageRows
                    If curR < 0 Then curR = 0
                    topR = curR
                End If

            Case Chr$(0) + Chr$(81)
                If focus = FOCUS_LEFT Then
                    curL = curL + pageRows
                    If curL > curCount Then curL = curCount
                    topL = curL - pageRows + 1
                    If topL < 0 Then topL = 0
                Else
                    curR = curR + pageRows
                    If curR > pickedCount Then curR = pickedCount
                    topR = curR - pageRows + 1
                    If topR < 0 Then topR = 0
                End If

            Case "a", "A"
                For i = 0 To curCount
                    If Not curIsDir(i) Then
                        If Not curSelected(i) Then
                            fullPath$ = JoinPath$(curPath$, curNames$(i))
                            AddToPicked fullPath$, pickedList$(), pickedCount
                            curSelected(i) = -1
                        End If
                    End If
                Next i

            Case "n", "N"
                For i = 0 To curCount
                    If curSelected(i) Then
                        fullPath$ = JoinPath$(curPath$, curNames$(i))
                        RemoveFromPicked fullPath$, pickedList$(), pickedCount
                        curSelected(i) = 0
                    End If
                Next i
        End Select
    End If

    _Limit 60
Loop Until done


'=======================================================================
'   Write output file
'=======================================================================

Dim fh As Long

If cancelled Then
    fh = FreeFile
    Open outputFile$ For Output As #fh
    Close #fh
    System EXIT_CANCEL
End If

If pickedCount < 0 Then
    fh = FreeFile
    Open outputFile$ For Output As #fh
    Close #fh
    System EXIT_EMPTY
End If

fh = FreeFile
Open outputFile$ For Output As #fh
For i = 0 To pickedCount
    Print #fh, pickedList$(i)
Next i
Close #fh
System EXIT_OK


'=======================================================================
'   Directory loading via z64fs
'=======================================================================

Sub LoadDir (absPath$, names$(), isDir() As Integer, count As Long)
    Dim handle As Long
    Dim nname As String
    Dim attrs As Long
    Dim result As Long
    Dim nulPos As Long
    Dim entry$
    Dim itemIsDir As Integer

    count = -1
    ReDim names$(0)
    ReDim isDir(0) As Integer

    If Len(absPath$) > 3 Then
        count = count + 1
        ReDim _Preserve names$(count), isDir(count) As Integer
        names$(count) = ".."
        isDir(count) = -1
    End If

    handle = z64fs_open(absPath$ + Chr$(0), 0)
    If handle < 0 Then Exit Sub

    nname = Space$(NAME_BUF)
    Do
        result = z64fs_next(handle, nname, Len(nname), attrs)
        If result <> 1 Then Exit Do

        nulPos = InStr(nname, Chr$(0))
        If nulPos > 0 Then
            entry$ = Left$(nname, nulPos - 1)
        Else
            entry$ = RTrim$(nname)
        End If

        itemIsDir = 0
        If attrs And Z64FS_ATTR_DIR Then itemIsDir = -1

        If Not (itemIsDir And IsBlockedDir%(entry$)) Then
            count = count + 1
            ReDim _Preserve names$(count), isDir(count) As Integer
            names$(count) = entry$
            isDir(count) = itemIsDir
        End If

        nname = Space$(NAME_BUF)
    Loop

    z64fs_close handle
End Sub


'=======================================================================
'   Picked list management
'=======================================================================

Sub ToggleFilePick (basePath$, entryName$, picked$(), pickedCount As Long, _
                    curSelected() As Integer, idx As Long)
    Dim fullPath$: fullPath$ = JoinPath$(basePath$, entryName$)
    If curSelected(idx) Then
        RemoveFromPicked fullPath$, picked$(), pickedCount
        curSelected(idx) = 0
    Else
        AddToPicked fullPath$, picked$(), pickedCount
        curSelected(idx) = -1
    End If
End Sub


Function InPicked% (fullPath$, picked$(), pickedCount As Long)
    Dim i As Long
    Dim target$: target$ = LCase$(fullPath$)
    For i = 0 To pickedCount
        If LCase$(picked$(i)) = target$ Then
            InPicked% = -1
            Exit Function
        End If
    Next i
End Function


Sub AddToPicked (fullPath$, picked$(), pickedCount As Long)
    pickedCount = pickedCount + 1
    ReDim _Preserve picked$(pickedCount)
    picked$(pickedCount) = fullPath$
End Sub


Sub RemoveFromPicked (fullPath$, picked$(), pickedCount As Long)
    Dim i As Long, j As Long
    Dim target$: target$ = LCase$(fullPath$)
    For i = 0 To pickedCount
        If LCase$(picked$(i)) = target$ Then
            For j = i To pickedCount - 1
                picked$(j) = picked$(j + 1)
            Next j
            pickedCount = pickedCount - 1
            If pickedCount >= 0 Then
                ReDim _Preserve picked$(pickedCount)
            Else
                ReDim picked$(0)
            End If
            Exit Sub
        End If
    Next i
End Sub


'=======================================================================
'   Drawing helpers
'=======================================================================

Sub DrawCheckbox (x1 As Long, y1 As Long, x2 As Long, y2 As Long, checked As Integer)
    Line (x1, y1)-(x2, y2), _RGB32(220, 220, 220), B
    If checked Then
        Line (x1 + 2, y1 + 2)-(x2 - 2, y2 - 2), _RGB32(80, 220, 80), BF
        Line (x1 + 2, y1 + 2)-(x2 - 2, y2 - 2), _RGB32(20, 60, 20)
        Line (x1 + 2, y2 - 2)-(x2 - 2, y1 + 2), _RGB32(20, 60, 20)
    End If
End Sub


Function PtInRect (px As Long, py As Long, x1 As Long, y1 As Long, x2 As Long, y2 As Long)
    If px >= x1 And px <= x2 And py >= y1 And py <= y2 Then PtInRect = -1 Else PtInRect = 0
End Function


Function TruncateLeft$ (s$, maxLen As Long)
    If Len(s$) <= maxLen Then
        TruncateLeft$ = s$
    Else
        TruncateLeft$ = "..." + Right$(s$, maxLen - 3)
    End If
End Function


Function TruncateRight$ (s$, maxLen As Long)
    If Len(s$) <= maxLen Then
        TruncateRight$ = s$
    Else
        TruncateRight$ = Left$(s$, maxLen - 3) + "..."
    End If
End Function


'=======================================================================
'   Path helpers
'=======================================================================

Function JoinPath$ (baseDir$, nname$)
    If Len(baseDir$) = 0 Then JoinPath$ = nname$: Exit Function
    If Right$(baseDir$, 1) = "\" Or Right$(baseDir$, 1) = "/" Then
        JoinPath$ = baseDir$ + nname$
    Else
        JoinPath$ = baseDir$ + "\" + nname$
    End If
End Function


Function ParentPath$ (path$)
    Dim p$: p$ = path$
    Dim i As Long, ch$
    If Right$(p$, 1) = "\" Or Right$(p$, 1) = "/" Then p$ = Left$(p$, Len(p$) - 1)
    For i = Len(p$) To 1 Step -1
        ch$ = Mid$(p$, i, 1)
        If ch$ = "\" Or ch$ = "/" Then
            If i = 3 And Mid$(p$, 2, 1) = ":" Then
                ParentPath$ = Left$(p$, 3): Exit Function
            End If
            ParentPath$ = Left$(p$, i - 1) + "\": Exit Function
        End If
        If ch$ = ":" And i = 2 Then
            ParentPath$ = Left$(p$, 2) + "\": Exit Function
        End If
    Next i
    If Right$(p$, 1) = "\" Then ParentPath$ = p$ Else ParentPath$ = p$ + "\"
End Function


Function IsBlockedDir% (nname$)
    Dim ln$: ln$ = LCase$(nname$)
    If ln$ = "$recycle.bin" Then IsBlockedDir% = -1: Exit Function
    If ln$ = "recycler" Then IsBlockedDir% = -1: Exit Function
    If ln$ = "system volume information" Then IsBlockedDir% = -1: Exit Function
End Function
