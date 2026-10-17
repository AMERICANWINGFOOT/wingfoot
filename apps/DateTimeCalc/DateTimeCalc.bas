Option _Explicit
'$Include:'ButtonUI.bi'
'=======================================================================
' DateTimeCalc.bas - QB64Starter Date & Time Calculator
'
' A mouse-driven GUI calculator built on two helper modules:
'     ButtonUI        - immediate-mode buttons + mouse
'     DateTimeHelpers - all date/time math and formatting
'
' Four modes: Days Between, Add/Subtract Days, Date Info, Duration.
' Click a field to focus it, type with the keyboard (digits and the
' separators shown in each label). Results update live as you type.
' ESC clears the focused field, or quits when nothing is focused.
'=======================================================================

Const SCRW = 760, SCRH = 600
Const PANX = 24, PANY = 314, PANW = 712, PANH = 232

' Field focus IDs
Const FLD_A = 1, FLD_B = 2, FLD_ADDDATE = 3, FLD_ADDN = 4
Const FLD_INFO = 5, FLD_TS = 6, FLD_TE = 7

' --- shared UI state ---
Dim Shared gFocus As Integer '   which field currently has keyboard focus
Dim Shared gKeyCh As String '    this frame's InKey$, read once in the main loop

' --- shared field contents ---
Dim Shared gDateA As String, gDateB As String
Dim Shared gAddDate As String, gAddN As String
Dim Shared gInfoDate As String
Dim Shared gTimeStart As String, gTimeEnd As String

' --- date entry order ---
'   0 = MM-DD-YYYY (US, matches QB64's Date$)
'  -1 = DD-MM-YYYY (rest of the world)
' Field contents are always stored in DISPLAY order; ToCanon$ turns
' them into the MM-DD-YYYY the helper library expects.
Dim Shared gDMY As Integer

' --- palette ---
Dim Shared cBg As _Unsigned Long, cTitle As _Unsigned Long
Dim Shared cLabel As _Unsigned Long, cResult As _Unsigned Long
Dim Shared cFieldBg As _Unsigned Long, cFieldBorder As _Unsigned Long
Dim Shared cFieldFocus As _Unsigned Long, cText As _Unsigned Long


'=======================================================================
' STARTUP
'=======================================================================
Screen _NewImage(SCRW, SCRH, 32)
_Title "Date & Time Calculator"
_ScreenMove _Middle
_PrintMode _KeepBackground ' transparent text everywhere

MouseInit
InitColors

gDMY = 0 ' start in MM-DD-YYYY; the header button toggles it

' Sensible starting values so every mode shows a result immediately.
gDateA = ToUser$(Date$): gDateB = ToUser$(Date$)
gAddDate = ToUser$(Date$): gAddN = "30"
gInfoDate = ToUser$(Date$)
gTimeStart = "09:00:00": gTimeEnd = "17:30:00"

Dim mode As Integer
mode = 1
gFocus = FLD_A

'=======================================================================
' MAIN LOOP
'=======================================================================
Do
    _Limit 60
    gKeyCh = InKey$
    If gKeyCh = Chr$(27) Then
        If gFocus <> 0 Then gFocus = 0 Else Exit Do
    End If
    PollMouse

    Cls , cBg
    _PrintMode _KeepBackground ' one known state per frame; every mode/helper inherits it

    ' --- header ---
    Color cTitle
    _PrintString (24, 16), "DATE & TIME CALCULATOR"
    Color cLabel
    _PrintString (SCRW - 250, 16), "Now: " + Time12$(Time$)
    Line (24, 40)-(SCRW - 24, 40), cFieldBorder

    ' --- mode tabs ---
    If ModeTab%(24, 52, 170, 34, "Days Between", (mode = 1)) Then mode = 1: gFocus = FLD_A
    If ModeTab%(202, 52, 170, 34, "Add / Sub Days", (mode = 2)) Then mode = 2: gFocus = FLD_ADDDATE
    If ModeTab%(380, 52, 170, 34, "Date Info", (mode = 3)) Then mode = 3: gFocus = FLD_INFO
    If ModeTab%(558, 52, 178, 34, "Duration", (mode = 4)) Then mode = 4: gFocus = FLD_TS

    ' --- active mode body ---
    Select Case mode
        Case 1: ModeDaysBetween
        Case 2: ModeAddDays
        Case 3: ModeDateInfo
        Case 4: ModeDuration
    End Select

    ' --- footer ---
    Color cLabel
    _PrintString (24, SCRH - 30), "Click a field, type to edit. ESC clears / quits."
    If Button%(420, SCRH - 40, 186, 30, "Order: " + DateOrder$) Then ToggleDateOrder
    If Button%(SCRW - 134, SCRH - 40, 110, 30, "Quit") Then Exit Do

    _Display
Loop

System


'=======================================================================
' MODE BODIES
'=======================================================================
Sub ModeDaysBetween
    EditableField FLD_A, 40, 140, 210, "Date A  (" + DateOrder$ + ", BC ok)", gDateA, "0123456789-/ BbCcAaDd"
    EditableField FLD_B, 40, 210, 210, "Date B  (" + DateOrder$ + ", BC ok)", gDateB, "0123456789-/ BbCcAaDd"
    If Button%(266, 140, 96, 34, "Today") Then gDateA = ToUser$(Date$)
    If Button%(266, 210, 96, 34, "Today") Then gDateB = ToUser$(Date$)
    If Button%(266, 262, 96, 34, "Swap") Then SwapStr gDateA, gDateB

    Dim cA As String, cB As String
    cA = ToCanon$(gDateA): cB = ToCanon$(gDateB)

    If ValidDate%(cA) And ValidDate%(cB) Then
        Dim d As Long, ad As Long, wk As Long, rd As Long
        d = DaysBetween&(cA, cB)
        ad = Abs(d): wk = ad \ 7: rd = ad Mod 7
        ResultLine 0, "From " + DateLongC$(cA) + "  (" + WeekdayName$(cA) + ")"
        ResultLine 1, "  to " + DateLongC$(cB) + "  (" + WeekdayName$(cB) + ")"
        ResultLine 3, "Difference: " + _Trim$(Str$(ad)) + " days"
        ResultLine 4, "          = " + _Trim$(Str$(wk)) + " weeks, " + _Trim$(Str$(rd)) + " days"
        If d > 0 Then
            ResultLine 6, "Date B falls after Date A."
        ElseIf d < 0 Then
            ResultLine 6, "Date B falls before Date A."
        Else
            ResultLine 6, "Both dates are the same day."
        End If
    Else
        ResultLine 0, "Enter two valid dates above to compare them."
    End If
End Sub


Sub ModeAddDays
    EditableField FLD_ADDDATE, 40, 140, 210, "Start date  (" + DateOrder$ + ", BC ok)", gAddDate, "0123456789-/ BbCcAaDd"
    EditableField FLD_ADDN, 40, 210, 130, "Days to add (+/-)", gAddN, "0123456789-"
    If Button%(266, 140, 96, 34, "Today") Then gAddDate = ToUser$(Date$)

    ' Quick nudges for the day count
    If Button%(184, 210, 40, 34, "-1") Then BumpN -1
    If Button%(228, 210, 40, 34, "+1") Then BumpN 1
    If Button%(272, 210, 40, 34, "-7") Then BumpN -7
    If Button%(316, 210, 40, 34, "+7") Then BumpN 7
    If Button%(184, 250, 40, 34, "-30") Then BumpN -30
    If Button%(228, 250, 40, 34, "+30") Then BumpN 30
    If Button%(272, 250, 84, 34, "Reset 0") Then gAddN = "0"

    Dim cStart As String
    cStart = ToCanon$(gAddDate)

    If ValidDate%(cStart) Then
        Dim n As Long, res As String
        n = Val(gAddN)
        res = AddDays$(cStart, n)
        ResultLine 0, DateLongC$(cStart) + "  (" + WeekdayName$(cStart) + ")"
        If n >= 0 Then
            ResultLine 1, "  plus " + _Trim$(Str$(n)) + " days ="
        Else
            ResultLine 1, "  minus " + _Trim$(Str$(-n)) + " days ="
        End If
        ResultLine 3, DateLongC$(res) + "  (" + WeekdayName$(res) + ")"
        ResultLine 4, ToUser$(res) + "   ISO: " + DateISO$(res)
    Else
        ResultLine 0, "Enter a valid start date above."
    End If
End Sub


Sub ModeDateInfo
    EditableField FLD_INFO, 40, 140, 210, "Date  (" + DateOrder$ + ", BC ok)", gInfoDate, "0123456789-/ BbCcAaDd"
    If Button%(266, 140, 96, 34, "Today") Then gInfoDate = ToUser$(Date$)

    Dim cInfo As String
    cInfo = ToCanon$(gInfoDate)

    If ValidDate%(cInfo) Then
        Dim mm As Integer, dd As Integer, yy As Integer
        SplitDate cInfo, mm, dd, yy
        ResultLine 0, DateLongC$(cInfo)
        ResultLine 1, "Weekday:        " + WeekdayName$(cInfo)
        ResultLine 2, "Day of year:    " + _Trim$(Str$(DayOfYear%(cInfo))) + " of " + _Trim$(Str$(365 - IsLeapYear%(yy)))
        ResultLine 3, "Days in month:  " + _Trim$(Str$(DaysInMonth%(mm, yy)))
        ResultLine 4, "Leap year:      " + YesNoStr$(IsLeapYear%(yy))
        ResultLine 6, "ISO:   " + DateISO$(cInfo)
        ResultLine 7, "Short: " + DateShortC$(cInfo)
    Else
        ResultLine 0, "Enter a valid date above."
    End If
End Sub


Sub ModeDuration
    EditableField FLD_TS, 40, 140, 190, "Start time  (HH:MM:SS)", gTimeStart, "0123456789:"
    EditableField FLD_TE, 40, 210, 190, "End time  (HH:MM:SS)", gTimeEnd, "0123456789:"
    If Button%(246, 140, 96, 34, "Now") Then gTimeStart = Time$
    If Button%(246, 210, 96, 34, "Now") Then gTimeEnd = Time$

    Dim s1 As Long, s2 As Long
    s1 = ClockToSecs&(gTimeStart)
    s2 = ClockToSecs&(gTimeEnd)
    If s1 >= 0 And s2 >= 0 Then
        Dim e As Long, crossed As Integer
        e = s2 - s1
        crossed = 0
        If e < 0 Then e = e + 86400: crossed = -1
        ResultLine 0, "Elapsed: " + FormatClock$(e)
        ResultLine 1, "       = " + FormatDuration$(e)
        ResultLine 2, "       = " + _Trim$(Str$(e)) + " seconds"
        If crossed Then ResultLine 4, "(end time is on the following day)"
    Else
        ResultLine 0, "Enter two valid times above (HH:MM:SS)."
    End If
End Sub


'=======================================================================
' UI HELPERS
'=======================================================================
Sub InitColors
    cBg = _RGB32(24, 26, 32)
    cTitle = _RGB32(240, 244, 252)
    cLabel = _RGB32(150, 160, 180)
    cResult = _RGB32(206, 228, 216)
    cFieldBg = _RGB32(38, 42, 52)
    cFieldBorder = _RGB32(70, 78, 96)
    cFieldFocus = _RGB32(120, 190, 156)
    cText = _RGB32(236, 239, 246)
End Sub


Function ModeTab% (x As Integer, y As Integer, w As Integer, h As Integer, caption As String, isActive As Integer)
    Dim savedFace As _Unsigned Long
    savedFace = uiFace
    If isActive Then uiFace = _RGB32(40, 110, 92) ' selected tab reads green
    ModeTab% = Button%(x, y, w, h, caption)
    uiFace = savedFace
End Function


Sub EditableField (fid As Integer, x As Integer, y As Integer, w As Integer, labelText As String, value As String, allowed As String)
    Const FH = 34
    Dim focused As Integer, bcol As _Unsigned Long, shown As String

    _PrintMode _KeepBackground
    Color cLabel
    _PrintString (x, y - 18), labelText

    focused = (gFocus = fid)
    If gMouse.clicked And PtInRect%(gMouse.mx, gMouse.my, x, y, w, FH) Then
        gFocus = fid
        focused = -1
    End If

    Line (x, y)-(x + w, y + FH), cFieldBg, BF
    If focused Then bcol = cFieldFocus Else bcol = cFieldBorder
    Line (x, y)-(x + w, y + FH), bcol, B
    If focused Then Line (x + 1, y + 1)-(x + w - 1, y + FH - 1), bcol, B

    If focused Then
        If gKeyCh = Chr$(8) Then
            If Len(value) > 0 Then value = Left$(value, Len(value) - 1)
        ElseIf Len(gKeyCh) = 1 Then
            If InStr(allowed, gKeyCh) > 0 Then value = value + gKeyCh
        End If
    End If

    shown = value
    If focused And (Int(Timer * 2) Mod 2 = 0) Then shown = shown + "|"
    Color cText
    _PrintString (x + 8, y + (FH - 16) \ 2), shown
End Sub


Sub ResultLine (row As Integer, s As String)

    _PrintMode _KeepBackground
    ' Draw the panel background once per pass, on the first line printed.
    If row = 0 Then
        Line (PANX, PANY)-(PANX + PANW, PANY + PANH), cFieldBg, BF
        Line (PANX, PANY)-(PANX + PANW, PANY + PANH), cFieldBorder, B
    End If
    Color cResult
    _PrintString (PANX + 18, PANY + 18 + row * 22), s
End Sub


'=======================================================================
' LOGIC HELPERS
'=======================================================================
Sub SwapStr (a As String, b As String)
    Dim t As String
    t = a: a = b: b = t
End Sub


Sub BumpN (delta As Integer)
    gAddN = _Trim$(Str$(Val(gAddN) + delta))
End Sub


Function YesNoStr$ (flag As Integer)
    If flag Then YesNoStr$ = "Yes" Else YesNoStr$ = "No"
End Function


'=======================================================================
' DATE ORDER (display order <-> the library's canonical MM-DD-YYYY)
'=======================================================================
Function DateOrder$
    If gDMY Then DateOrder$ = "DD-MM-YYYY" Else DateOrder$ = "MM-DD-YYYY"
End Function


Sub ToggleDateOrder
    ' Flip the flag, then re-order what is already in the fields so the
    ' dates on screen keep meaning the same day.
    gDMY = Not gDMY
    gDateA = SwapMD$(gDateA)
    gDateB = SwapMD$(gDateB)
    gAddDate = SwapMD$(gAddDate)
    gInfoDate = SwapMD$(gInfoDate)
End Sub


Function SwapMD$ (d As String)
    ' Exchange the first two fields of a 3-part date. Its own inverse,
    ' so one routine covers both directions.
    Dim s As String, i As Integer, ch As String
    Dim p1 As Integer, p2 As Integer

    s = _Trim$(d)
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch = "/" Then Mid$(s, i, 1) = "-"
    Next i

    p1 = InStr(s, "-")
    p2 = 0
    If p1 > 0 Then p2 = InStr(p1 + 1, s, "-")
    If p1 = 0 Or p2 = 0 Then SwapMD$ = s: Exit Function

    SwapMD$ = Mid$(s, p1 + 1, p2 - p1 - 1) + "-" + Left$(s, p1 - 1) + "-" + Mid$(s, p2 + 1)
End Function


Function StripEra$ (d As String, bcFlag As Integer)
    ' Splits a trailing era token (BC or AD, any case, optional leading
    ' space) off a date string. bcFlag returns -1 for BC, 0 otherwise.
    ' The returned string is the trimmed date portion.
    Dim s As String, u As String
    s = _Trim$(d)
    bcFlag = 0
    u = UCase$(s)
    If Right$(u, 2) = "BC" Then
        bcFlag = -1
        s = _Trim$(Left$(s, Len(s) - 2))
    ElseIf Right$(u, 2) = "AD" Then
        s = _Trim$(Left$(s, Len(s) - 2))
    End If
    StripEra$ = s
End Function


Function ToCanon$ (d As String)
    ' Field text (display order, optional trailing BC/AD) -> canonical
    ' MM-DD-YYYY with an ASTRONOMICAL year for the helper library:
    ' 1 BC -> 0, 44 BC -> -43. AD passes straight through unchanged, so
    ' malformed input reaches ValidDate% exactly as it did before.
    Dim s As String, bc As Integer
    Dim p1 As Integer, p2 As Integer, histYear As Long

    s = StripEra$(d, bc)
    If gDMY Then s = SwapMD$(s)
    If Not bc Then ToCanon$ = s: Exit Function

    ' BC: rewrite the trailing year as its astronomical equivalent.
    p1 = InStr(s, "-")
    If p1 = 0 Then ToCanon$ = s: Exit Function
    p2 = InStr(p1 + 1, s, "-")
    If p2 = 0 Then ToCanon$ = s: Exit Function
    histYear = Val(Mid$(s, p2 + 1))
    ToCanon$ = Left$(s, p2) + _Trim$(Str$(1 - histYear))
End Function


Function ToUser$ (d As String)
    ' Canonical MM-DD-YYYY (astronomical year) -> field display order,
    ' with a trailing " BC" whenever the astronomical year is <= 0.
    Dim mm As Integer, dd As Integer, yy As Integer
    Dim suffix As String, body As String
    SplitDate d, mm, dd, yy
    suffix = ""
    If yy <= 0 Then yy = 1 - yy: suffix = " BC"
    body = Pad2$(mm) + "-" + Pad2$(dd) + "-" + Pad4$(yy)
    If gDMY Then body = SwapMD$(body)
    ToUser$ = body + suffix
End Function


Function DateLongC$ (dc As String)
    ' Long form of a CANONICAL date, worded to match the entry order:
    '   MM-DD-YYYY -> July 17, 2026        DD-MM-YYYY -> 17 July 2026
    Dim mm As Integer, dd As Integer, yy As Integer
    If gDMY Then
        SplitDate dc, mm, dd, yy
        DateLongC$ = _Trim$(Str$(dd)) + " " + MonthName$(mm) + " " + YearLabel$(yy)
    Else
        DateLongC$ = DateLong$(dc)
    End If
End Function


Function DateShortC$ (dc As String)
    Dim mm As Integer, dd As Integer, yy As Integer
    If gDMY Then
        SplitDate dc, mm, dd, yy
        DateShortC$ = _Trim$(Str$(dd)) + " " + MonthShort$(mm) + " " + YearLabel$(yy)
    Else
        DateShortC$ = DateShort$(dc)
    End If
End Function

Function ValidDate% (d As String)
    Dim s As String, i As Integer, ch As String
    Dim p1 As Integer, p2 As Integer
    Dim mm As Integer, dd As Integer, yy As Integer

    s = _Trim$(d)
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch = "/" Then Mid$(s, i, 1) = "-"
    Next i

    p1 = InStr(s, "-")
    If p1 = 0 Then ValidDate% = 0: Exit Function
    p2 = InStr(p1 + 1, s, "-")
    If p2 = 0 Then ValidDate% = 0: Exit Function

    mm = Val(Left$(s, p1 - 1))
    dd = Val(Mid$(s, p1 + 1, p2 - p1 - 1))
    yy = Val(Mid$(s, p2 + 1))

    If yy < -9999 Or yy > 9999 Then ValidDate% = 0: Exit Function
    If mm < 1 Or mm > 12 Then ValidDate% = 0: Exit Function
    If dd < 1 Or dd > DaysInMonth%(mm, yy) Then ValidDate% = 0: Exit Function
    ValidDate% = -1
End Function


Function ClockToSecs& (t As String)
    Dim s As String, c1 As Integer, c2 As Integer
    Dim hh As Integer, mm As Integer, ss As Integer

    s = _Trim$(t)
    c1 = InStr(s, ":")
    If c1 = 0 Then ClockToSecs& = -1: Exit Function
    c2 = InStr(c1 + 1, s, ":")
    If c2 = 0 Then ClockToSecs& = -1: Exit Function

    hh = Val(Left$(s, c1 - 1))
    mm = Val(Mid$(s, c1 + 1, c2 - c1 - 1))
    ss = Val(Mid$(s, c2 + 1))

    If hh < 0 Or hh > 23 Then ClockToSecs& = -1: Exit Function
    If mm < 0 Or mm > 59 Then ClockToSecs& = -1: Exit Function
    If ss < 0 Or ss > 59 Then ClockToSecs& = -1: Exit Function
    ClockToSecs& = hh * 3600& + mm * 60& + ss
End Function

'$Include:'ButtonUI.bm'
'$Include:'DateTimeHelpers.bm'
