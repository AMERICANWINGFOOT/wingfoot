Option _Explicit
'$Include:'ButtonUI.bi'
'=======================================================================
' Calendar.bas - QB64Starter Month Calendar
'
' A mouse-driven month view built on the same two helper modules as the
' Date & Time Calculator:
'     ButtonUI        - immediate-mode buttons + mouse
'     DateTimeHelpers - weekday, days-in-month, formatting
'
' Navigate with the arrows (month and year), jump back with Today, and
' click any day to select it and see its full details at the bottom.
'=======================================================================


Const SCRW = 700, SCRH = 580
Const GRIDX = 24, GRIDY = 124
Const CELLW = 93, CELLH = 62

' --- shared calendar state ---
Dim Shared calMonth As Integer, calYear As Integer
Dim Shared selDay As Integer '                 0 = nothing selected
Dim Shared todMonth As Integer, todDay As Integer, todYear As Integer

' --- palette ---
Dim Shared kBg As _Unsigned Long, kTitle As _Unsigned Long
Dim Shared kHeader As _Unsigned Long, kWeekend As _Unsigned Long
Dim Shared kGridLine As _Unsigned Long, kCellBg As _Unsigned Long
Dim Shared kCellHover As _Unsigned Long, kCellDim As _Unsigned Long
Dim Shared kDayText As _Unsigned Long, kTodayRing As _Unsigned Long
Dim Shared kSelFill As _Unsigned Long, kSelText As _Unsigned Long
Dim Shared kInfo As _Unsigned Long


'=======================================================================
' STARTUP
'=======================================================================
Screen _NewImage(SCRW, SCRH, 32)
_Title "Month Calendar"


_PrintMode _KeepBackground

MouseInit
InitCalColors

' Remember today, and open on the current month with today selected.
SplitDate Date$, todMonth, todDay, todYear
calMonth = todMonth: calYear = todYear
selDay = todDay


'=======================================================================
' MAIN LOOP
'=======================================================================
Do
    _Limit 60
    If InKey$ = Chr$(27) Then Exit Do
    PollMouse

    Cls , kBg
    _PrintMode _KeepBackground ' one known text state per frame

    DrawHeader
    DrawNavBar
    DrawWeekdayHeader
    DrawGrid
    DrawInfoBar

    If Button%(SCRW - 128, SCRH - 42, 104, 30, "Quit") Then Exit Do

    _Display
Loop

System


'=======================================================================
' HEADER + NAV
'=======================================================================
Sub DrawHeader
    Dim t As String
    _PrintMode _KeepBackground
    t = MonthName$(calMonth) + " " + _Trim$(Str$(calYear))
    Color kTitle
    _PrintString ((SCRW - 8 * Len(t)) \ 2, 18), t
End Sub


Sub DrawNavBar
    If Button%(24, 52, 96, 34, "<< Year") Then calYear = calYear - 1: selDay = 0
    If Button%(124, 52, 96, 34, "< Month") Then PrevMonth
    If Button%(302, 52, 96, 34, "Today") Then GoToToday
    If Button%(480, 52, 96, 34, "Month >") Then NextMonth
    If Button%(580, 52, 96, 34, "Year >>") Then calYear = calYear + 1: selDay = 0
End Sub


Sub DrawWeekdayHeader
    Dim col As Integer, wd As String, tx As Integer
    For col = 0 To 6
        wd = Mid$("SunMonTueWedThuFriSat", col * 3 + 1, 3)
        tx = GRIDX + col * CELLW + (CELLW - 24) \ 2
        If col = 0 Or col = 6 Then Color kWeekend Else Color kHeader
        _PrintString (tx, 100), wd
    Next col
    Line (GRIDX, 120)-(GRIDX + 7 * CELLW, 120), kGridLine
End Sub


'=======================================================================
' GRID
'=======================================================================
Sub DrawGrid
    Dim firstDow As Integer, dmax As Integer
    Dim row As Integer, col As Integer, cellIndex As Integer, dayNum As Integer
    Dim cx As Integer, cy As Integer
    Dim isToday As Integer, isSel As Integer, wkend As Integer

    firstDow = DayOfWeekNum%(Pad2$(calMonth) + "-01-" + Pad4$(calYear))
    dmax = DaysInMonth%(calMonth, calYear)

    dayNum = 1
    For row = 0 To 5
        For col = 0 To 6
            cellIndex = row * 7 + col
            cx = GRIDX + col * CELLW
            cy = GRIDY + row * CELLH
            If cellIndex >= firstDow And dayNum <= dmax Then
                isToday = (calMonth = todMonth And calYear = todYear And dayNum = todDay)
                isSel = (dayNum = selDay)
                wkend = (col = 0 Or col = 6)
                DrawDayCell cx, cy, dayNum, isToday, isSel, wkend
                If gMouse.clicked And PtInRect%(gMouse.mx, gMouse.my, cx, cy, CELLW, CELLH) Then selDay = dayNum
                dayNum = dayNum + 1
            Else
                ' Empty leading/trailing cell
                Line (cx, cy)-(cx + CELLW, cy + CELLH), kCellDim, BF
                Line (cx, cy)-(cx + CELLW, cy + CELLH), kGridLine, B
            End If
        Next col
    Next row
End Sub


Sub DrawDayCell (cx As Integer, cy As Integer, dnum As Integer, isToday As Integer, isSel As Integer, wkend As Integer)
    Dim over As Integer, cellFill As _Unsigned Long, tcol As _Unsigned Long, s As String
    _PrintMode _KeepBackground
    over = PtInRect%(gMouse.mx, gMouse.my, cx, cy, CELLW, CELLH)
    If isSel Then
        cellFill = kSelFill
    ElseIf over Then
        cellFill = kCellHover
    Else
        cellFill = kCellBg
    End If

    Line (cx, cy)-(cx + CELLW, cy + CELLH), cellFill, BF
    Line (cx, cy)-(cx + CELLW, cy + CELLH), kGridLine, B

    If isToday Then
        Line (cx + 2, cy + 2)-(cx + CELLW - 2, cy + CELLH - 2), kTodayRing, B
        Line (cx + 3, cy + 3)-(cx + CELLW - 3, cy + CELLH - 3), kTodayRing, B
    End If

    If isSel Then
        tcol = kSelText
    ElseIf wkend Then
        tcol = kWeekend
    Else
        tcol = kDayText
    End If

    s = _Trim$(Str$(dnum))
    Color tcol
    _PrintString (cx + (CELLW - 8 * Len(s)) \ 2, cy + (CELLH - 16) \ 2), s
End Sub


Sub DrawInfoBar
    _PrintMode _KeepBackground
    Dim sd As String, info As String
    If selDay > 0 Then
        sd = Pad2$(calMonth) + "-" + Pad2$(selDay) + "-" + Pad4$(calYear)
        info = "Selected: " + WeekdayName$(sd) + ", " + DateLong$(sd)
        info = info + "   (day " + _Trim$(Str$(DayOfYear%(sd)))
        info = info + " of " + _Trim$(Str$(365 - IsLeapYear%(calYear))) + ")"
    Else
        info = "Click a day to select it."
    End If
    Color kInfo
    _PrintString (24, SCRH - 36), info
End Sub


'=======================================================================
' NAVIGATION
'=======================================================================
Sub PrevMonth
    calMonth = calMonth - 1
    If calMonth < 1 Then calMonth = 12: calYear = calYear - 1
    selDay = 0
End Sub


Sub NextMonth
    calMonth = calMonth + 1
    If calMonth > 12 Then calMonth = 1: calYear = calYear + 1
    selDay = 0
End Sub


Sub GoToToday
    calMonth = todMonth
    calYear = todYear
    selDay = todDay
End Sub


'=======================================================================
' PALETTE
'=======================================================================
Sub InitCalColors
    kBg = _RGB32(24, 26, 32)
    kTitle = _RGB32(240, 244, 252)
    kHeader = _RGB32(150, 160, 180)
    kWeekend = _RGB32(210, 140, 140)
    kGridLine = _RGB32(56, 62, 76)
    kCellBg = _RGB32(38, 42, 52)
    kCellHover = _RGB32(54, 60, 74)
    kCellDim = _RGB32(30, 33, 40)
    kDayText = _RGB32(228, 232, 240)
    kTodayRing = _RGB32(90, 200, 150)
    kSelFill = _RGB32(46, 108, 150)
    kSelText = _RGB32(245, 248, 252)
    kInfo = _RGB32(190, 210, 224)
End Sub

'$Include:'ButtonUI.bm'
'$Include:'DateTimeHelpers.bm'
