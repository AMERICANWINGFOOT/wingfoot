$Title "Text Reader"
$If WIN Then
    '$ExeIcon:'Reader.ico'
$End If
$Resize:Smooth

'$Include:'BookReader.bi'
'$Include:'GlyphFont.bi'

handle& = _NewImage(800, 550, 32)
Screen handle&

Dim Shared printx As Integer
printx = Int(_Width / 2 - (71 * GFLW) / 2)

Dim Shared curBook As Integer
Dim Shared chapter As Integer, verse As Integer
Dim Shared buttons As Integer, up As Integer, GoUp As Long
Dim Shared chapterchanged As Integer, stopdown As Long
Dim Shared ButX(1 To 400) As Integer, ButY(1 To 400) As Integer
Dim Shared bok1(1 To 400) As Integer

GFLoadFont
BRLoadManifest "books.ini"

curBook = SelectBook%
BRLoadBook BRBook(curBook).FileName
buttons = BRBook(curBook).UnitCount
BuildChapterGrid buttons

Line (0, 20)-(_Width, 25), _RGB(10, 10, 180), BF
Line (0, 31)-(_Width, _Height), _RGB(0, 0, 50), BF
_PrintString (1, 1), "[WEB] " + _Trim$(BRBook(curBook).Title) + " - press B for book list, Esc to quit"
_PrintString (494, 1), "PageUp PageDn Spacebar " + Chr$(24) + " " + Chr$(25)
speedmeter

chapter = 1: verse = 1
printchapter 0
up = 0: GoUp = 0

Do
    Do While _MouseInput
    Loop
    For i = 1 To buttons
        multibutton LTrim$(Str$(i)), i
    Next i
    If chapterchanged = 1 Then up = 0: GoUp = 1: chapterchanged = 0: up4 = up: up1 = 0
    in$ = "": in$ = InKey$
    up3 = up
    If GoUp > 0 And Mid$(in$, 2, 1) = "H" Then ' arrow up
        If up > -5 Then up = up - 1: up4 = up: up1 = 0
    End If
    If GoUp < stopdown And Mid$(in$, 2, 1) = "P" Then ' arrow down
        If up < 5 Then up = up + 1: up4 = up: up1 = 0
    End If
    If GoUp > 0 And Mid$(in$, 2, 1) = "I" Then ' page up
        If GoUp > 300 Then GoUp = GoUp - 300 Else GoUp = 1
        If up <> 0 Then Swap up1, up4: up = up4
    End If
    If GoUp < stopdown And Mid$(in$, 2, 1) = "Q" Then ' page down
        If GoUp < stopdown - 300 Then GoUp = GoUp + 300 Else GoUp = stopdown
        If up <> 0 Then Swap up1, up4: up = up4
    End If
    If in$ = Chr$(32) Then Swap up1, up4: up = up4 ' spacebar
    If UCase$(in$) = "B" Then
        curBook = SelectBook%
        BRLoadBook BRBook(curBook).FileName
        buttons = BRBook(curBook).UnitCount
        BuildChapterGrid buttons
        chapter = 1: verse = 1
        Line (0, 31)-(_Width, _Height), _RGB(0, 0, 50), BF
        _PrintString (1, 1), "[WEB] " + _Trim$(BRBook(curBook).Title) + " - press B for book list, Esc to quit                                        "
        printchapter 0
        up = 0: GoUp = 0
    End If
    If up3 <> up Then
        speedmeter
        c0& = _RGB(0, 0, 0)
        If up < 0 Then
            Color _RGB(255, 0, 0), c0&
            For i = 1 To Abs(up)
                _PrintString (752 - i * 8, 1), Chr$(221)
            Next i
        End If
        If up > 0 Then
            Color _RGB(0, 255, 0), c0&
            For i = 1 To Abs(up)
                _PrintString (744 + i * 8, 1), Chr$(221)
            Next i
        End If
    End If
    If up > 0 Then up2 = 1 Else up2 = -1
    If up = 0 Then up2 = 0
    GoUp = GoUp + up2
    If GoUp < 0 Then GoUp = 0: up = 0: up4 = up: up1 = 0: speedmeter
    If GoUp > stopdown Then up = 0: up4 = up: up1 = 0: up2 = 0: speedmeter
    If GoUp <> 0 Then printchapter GoUp
    Select Case Abs(up)
        Case 0
            _Delay .01
        Case 1
            _Delay .06
        Case 2
            _Delay .04
        Case 3
            _Delay .02
        Case 4
            _Delay .009
        Case 5
            _Delay .007
    End Select
    _Display
    If in$ = Chr$(27) Then Exit Do
Loop

System: End

' ------------------------------------------------------------
' Book selection screen. Returns the chosen index into BRBook().
' ------------------------------------------------------------
Function SelectBook% ()
    Dim pick As Integer, i As Integer, rowY As Integer
    Line (0, 0)-(_Width, _Height), _RGB(0, 0, 30), BF
    Color _RGB(255, 255, 255), _RGB(0, 0, 30)
    _PrintString (Int(_Width / 2 - 40), 20), "SELECT A BOOK"
    pick = 0
    Do
        Do While _MouseInput
        Loop
        For i = 1 To BRBookCount
            rowY = 60 + (i - 1) * 30
            If _MouseX > 100 And _MouseX < _Width - 100 And _MouseY > rowY And _MouseY < rowY + 26 Then
                Line (100, rowY)-(_Width - 100, rowY + 26), _RGB(0, 90, 0), BF
                Color _RGB(255, 255, 255), _RGB(0, 90, 0)
                If _MouseButton(1) Then pick = i
            Else
                Line (100, rowY)-(_Width - 100, rowY + 26), _RGB(20, 20, 60), BF
                Color _RGB(200, 200, 200), _RGB(20, 20, 60)
            End If
            _PrintString (110, rowY + 6), _Trim$(BRBook(i).Title) + "   (" + _Trim$(BRBook(i).Author) + ")"
        Next i
        _Display
        _Limit 60
    Loop Until pick > 0
    SelectBook% = pick
End Function

' ------------------------------------------------------------
' Precomputes screen coordinates for each chapter/act/etc. button
' in a wrapping grid, so multibutton doesn't have to recompute
' layout math every frame.
' ------------------------------------------------------------
Sub BuildChapterGrid (unitCount As Integer)
    Dim perRow As Integer, rows As Integer, i As Integer
    Dim col As Integer, rowNum As Integer, rowStart As Integer
    Dim lastRowCount As Integer
    perRow = 25
    rows = _Ceil(unitCount / perRow)
    For i = 1 To unitCount
        rowNum = Int((i - 1) / perRow)
        col = (i - 1) Mod perRow
        rowStart = Int(_Width / 2 - (perRow * 28) / 2)
        If rowNum = rows - 1 Then
            lastRowCount = unitCount - rowNum * perRow
            rowStart = Int(_Width / 2 - (lastRowCount * 28) / 2)
        End If
        ButX(i) = rowStart + col * 28
        ButY(i) = 30 + rowNum * 27
    Next i
End Sub

Sub speedmeter
    c0& = _RGB(0, 0, 0)
    For i = 1 To 10
        If i < 6 Then Color _RGB(110, 0, 0), c0& Else Color _RGB(0, 110, 0), c0&
        _PrintString (704 + i * 8, 1), Chr$(221)
    Next i
End Sub

Sub printchapter (top As Long)
    If GoUp < 0 Or GoUp > stopdown + 1 Then Exit Sub
    Static StartLine As Long, EndLine As Long
    Dim ln As Long, k As Integer, k2 As Integer
    Dim vers$, a$, b$, i5 As Integer, i4 As Integer

    If top = 0 Then
        stopdown = 0
        speedmeter
        BRGetBounds chapter, StartLine, EndLine
    End If

    k = 0: Line (0, 60)-(_Width, _Height), _RGB(255, 255, 255), BF

    For ln = StartLine To EndLine
        k = k + 1
        k2 = 50 + k * 27 - top
        If BRSubSect(ln) > 0 Then
            vers$ = LTrim$(Str$(BRSubSect(ln)))
        Else
            vers$ = ""
        End If
        If Len(vers$) > 0 Then GFPrintText vers$, printx, k2, 1

        a$ = BRLineText(ln) + " "
        i5 = 1: i4 = 0
        Do
            i4 = i4 + i5
            b$ = Mid$(a$, i4, 65)
            i5 = _InStrRev(Len(b$), b$, Space$(1))
            b$ = Mid$(b$, 1, i5)
            k2 = 50 + k * 27 - top
            If ln = EndLine And stopdown = 0 Then stopdown = k2 - 300
            If i5 > 0 Then GFPrintText b$, printx + 70, k2, 0: k = k + 1
        Loop Until i5 = 0
    Next ln
End Sub

Sub multibutton (labelText As String, unitID As Integer)
    Dim bx As Integer, by As Integer, bw As Integer, bh As Integer
    bx = ButX(unitID): by = ButY(unitID): bw = 27: bh = 25

    Dim c0 As _Unsigned Long, c1 As _Unsigned Long, c2 As _Unsigned Long, c4 As _Unsigned Long
    c0 = _RGB(0, 0, 0): c1 = _RGB(0, 0, 50): c2 = _RGB(100, 180, 100): c4 = _RGB(0, 120, 0)

    If _MouseX > bx And _MouseX < bx + bw And _MouseY > by And _MouseY < by + bh Then
        Line (bx + 1, by + 1)-(bx + bw - 1, by + bh - 1), c2, B
        Line (bx, by)-(bx + bw, by + bh), c2, B
        chapterchanged = 0
        If _MouseButton(1) = 0 Then bok1(unitID) = 1
        If _MouseButton(1) = -1 And bok1(unitID) = 1 Then
            Line (ButX(chapter) + 1, ButY(chapter) + 1)-(ButX(chapter) + bw - 1, ButY(chapter) + bh - 1), c0, BF
            chapter = unitID
            verse = 1
            chapterchanged = 1
            printchapter 0
        End If
    Else
        Line (bx + 1, by + 1)-(bx + bw - 1, by + bh - 1), c1, B
        Line (bx, by)-(bx + bw, by + bh), c1, B
        bok1(unitID) = 0
    End If

    If unitID = chapter Then
        Line (bx + 2, by + 2)-(bx + bw - 2, by + bh - 2), c4, BF
        Color _RGB(250, 250, 250), c4
    Else
        Line (bx + 2, by + 2)-(bx + bw - 2, by + bh - 2), c0, BF
        Color _RGB(250, 250, 250), c0
    End If
    _PrintString (bx + bw / 2 - Len(labelText) * 4 + 1, by + 6), labelText
End Sub

'$Include:'BookReader.bm'
'$Include:'GlyphFont.bm'
