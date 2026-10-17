Option _Explicit
'$Include:'ButtonUI.bi'
'=======================================================================
' Calculator.bas - QB64Starter Simple Calculator
'
' A mouse-driven four-function calculator built on the ButtonUI helper.
' Digits, decimal point, sign toggle, backspace and clear, with a live
' display showing both the pending operation and the current entry.
'
' Keyboard works too: 0-9 . + - * / Enter (=) Backspace  C (clear)
' ESC or the Quit button exits.
'=======================================================================

Const SCRW = 320, SCRH = 480

' keypad geometry
Const BX = 12, BY = 126 '        top-left of the key grid
Const BW = 68, BH = 48 '         key size
Const BGAP = 8 '                 gap between keys

' display panel
Const DPX = 12, DPY = 44, DPW = 296, DPH = 68

Const MAXLEN = 16 '              longest entry we accept

' --- calculator state ---
Dim Shared curEntry As String '     the number currently being typed
Dim Shared acc As Double '       running accumulator
Dim Shared pendOp As String '    pending operator, "" when none
Dim Shared newInput As Integer ' -1 when the next digit starts fresh
Dim Shared errMsg As String '    non-empty locks the keypad until Clear

' --- palette ---
Dim Shared cBg As _Unsigned Long, cTitle As _Unsigned Long
Dim Shared cPanel As _Unsigned Long, cPanelEdge As _Unsigned Long
Dim Shared cEntry As _Unsigned Long, cPending As _Unsigned Long
Dim Shared cWarn As _Unsigned Long, cHint As _Unsigned Long
Dim Shared cOpFace As _Unsigned Long, cActOp As _Unsigned Long


'=======================================================================
' STARTUP
'=======================================================================
Screen _NewImage(SCRW, SCRH, 32)
_Title "Calculator"
_PrintMode _KeepBackground

MouseInit
InitColors
DoClear


'=======================================================================
' MAIN LOOP
'=======================================================================
Dim k As String

Do
    _Limit 60
    k = InKey$
    If k = Chr$(27) Then Exit Do
    HandleKey k
    PollMouse

    Cls , cBg
    _PrintMode _KeepBackground

    Color cTitle
    _PrintString (12, 14), "CALCULATOR"

    DrawDisplay
    DrawKeypad

    Color cHint
    _PrintString (12, SCRH - 24), "Keyboard works too"
    If Button%(SCRW - 92, SCRH - 64, 80, 30, "Quit") Then Exit Do

    _Display
Loop

System


'=======================================================================
' DISPLAY
'=======================================================================
Sub DrawDisplay
    Dim topLine As String, mainLine As String

    Line (DPX, DPY)-(DPX + DPW, DPY + DPH), cPanel, BF
    Line (DPX, DPY)-(DPX + DPW, DPY + DPH), cPanelEdge, B

    ' Upper line: what we're carrying, plus the pending operator.
    If Len(pendOp) > 0 Then topLine = FormatNum$(acc) + " " + pendOp
    Color cPending
    _PrintString (RightX%(topLine), DPY + 12), topLine

    ' Lower line: the entry, or the error if one is latched.
    If Len(errMsg) > 0 Then
        mainLine = errMsg
        Color cWarn
    Else
        mainLine = curEntry
        Color cEntry
    End If
    _PrintString (RightX%(mainLine), DPY + 40), mainLine
End Sub


Function RightX% (s As String)
    ' Right-align an 8px-per-char string inside the display panel.
    RightX% = DPX + DPW - 10 - 8 * Len(s)
End Function


'=======================================================================
' KEYPAD
'=======================================================================
Sub DrawKeypad
    ' Row 0: clear, backspace, sign, divide
    If Button%(ColX%(0), RowY%(0), BW, BH, "C") Then DoClear
    If Button%(ColX%(1), RowY%(0), BW, BH, "<-") Then DoBack
    If Button%(ColX%(2), RowY%(0), BW, BH, "+/-") Then DoSign
    If OpKey%(ColX%(3), RowY%(0), "/") Then DoOperator "/"

    ' Rows 1-3: digits and the remaining operators
    If Button%(ColX%(0), RowY%(1), BW, BH, "7") Then DoDigit "7"
    If Button%(ColX%(1), RowY%(1), BW, BH, "8") Then DoDigit "8"
    If Button%(ColX%(2), RowY%(1), BW, BH, "9") Then DoDigit "9"
    If OpKey%(ColX%(3), RowY%(1), "*") Then DoOperator "*"

    If Button%(ColX%(0), RowY%(2), BW, BH, "4") Then DoDigit "4"
    If Button%(ColX%(1), RowY%(2), BW, BH, "5") Then DoDigit "5"
    If Button%(ColX%(2), RowY%(2), BW, BH, "6") Then DoDigit "6"
    If OpKey%(ColX%(3), RowY%(2), "-") Then DoOperator "-"

    If Button%(ColX%(0), RowY%(3), BW, BH, "1") Then DoDigit "1"
    If Button%(ColX%(1), RowY%(3), BW, BH, "2") Then DoDigit "2"
    If Button%(ColX%(2), RowY%(3), BW, BH, "3") Then DoDigit "3"
    If OpKey%(ColX%(3), RowY%(3), "+") Then DoOperator "+"

    ' Row 4: zero spans two columns, then decimal point and equals
    If Button%(ColX%(0), RowY%(4), BW * 2 + BGAP, BH, "0") Then DoDigit "0"
    If Button%(ColX%(2), RowY%(4), BW, BH, ".") Then DoDecimal
    If Button%(ColX%(3), RowY%(4), BW, BH, "=") Then DoEquals
End Sub


Function ColX% (col As Integer)
    ColX% = BX + col * (BW + BGAP)
End Function


Function RowY% (row As Integer)
    RowY% = BY + row * (BH + BGAP)
End Function


Function OpKey% (x As Integer, y As Integer, symbol As String)
    ' An operator key that reads green while it is the pending operation.
    Dim savedFace As _Unsigned Long
    savedFace = uiFace
    If pendOp = symbol Then uiFace = cActOp Else uiFace = cOpFace
    OpKey% = Button%(x, y, BW, BH, symbol)
    uiFace = savedFace
End Function


'=======================================================================
' KEYBOARD
'=======================================================================
Sub HandleKey (k As String)
    If Len(k) <> 1 Then Exit Sub

    If k >= "0" And k <= "9" Then DoDigit k: Exit Sub

    Select Case k
        Case ".": DoDecimal
        Case "+", "-", "*", "/": DoOperator k
        Case "=", Chr$(13): DoEquals
        Case Chr$(8): DoBack
        Case "c", "C": DoClear
    End Select
End Sub


'=======================================================================
' CALCULATOR LOGIC
'=======================================================================
Sub DoDigit (d As String)
    If Len(errMsg) > 0 Then Exit Sub
    If newInput Then curEntry = "0": newInput = 0

    If curEntry = "0" Then
        curEntry = d
    ElseIf curEntry = "-0" Then
        curEntry = "-" + d
    ElseIf Len(curEntry) < MAXLEN Then
        curEntry = curEntry + d
    End If
End Sub


Sub DoDecimal
    If Len(errMsg) > 0 Then Exit Sub
    If newInput Then curEntry = "0": newInput = 0
    If InStr(curEntry, ".") = 0 And Len(curEntry) < MAXLEN Then curEntry = curEntry + "."
End Sub


Sub DoSign
    If Len(errMsg) > 0 Then Exit Sub
    If Left$(curEntry, 1) = "-" Then
        curEntry = Mid$(curEntry, 2)
    ElseIf curEntry <> "0" Then
        curEntry = "-" + curEntry
    End If
End Sub


Sub DoBack
    If Len(errMsg) > 0 Then Exit Sub
    If newInput Then Exit Sub ' nothing being typed yet
    curEntry = Left$(curEntry, Len(curEntry) - 1)
    If curEntry = "" Or curEntry = "-" Then curEntry = "0"
End Sub


Sub DoOperator (o As String)
    If Len(errMsg) > 0 Then Exit Sub
    If newInput And Len(pendOp) > 0 Then pendOp = o: Exit Sub
    ApplyPending
    If Len(errMsg) > 0 Then Exit Sub
    pendOp = o
    newInput = -1
End Sub


Sub DoEquals
    If Len(errMsg) > 0 Then Exit Sub
    ApplyPending
    pendOp = ""
    newInput = -1
End Sub


Sub DoClear
    curEntry = "0"
    acc = 0
    pendOp = ""
    newInput = -1
    errMsg = ""
End Sub


Sub ApplyPending
    ' Fold the current entry into the accumulator using the pending
    ' operator, then show the running total in the entry field.
    Dim v As Double
    v = Val(curEntry)

    If pendOp = "" Then
        acc = v
    Else
        Select Case pendOp
            Case "+": acc = acc + v
            Case "-": acc = acc - v
            Case "*": acc = acc * v
            Case "/"
                If v = 0 Then
                    errMsg = "Cannot divide by zero"
                    Exit Sub
                End If
                acc = acc / v
        End Select
    End If

    curEntry = FormatNum$(acc)
End Sub


'=======================================================================
' HELPERS
'=======================================================================
Function FormatNum$ (v As Double)
    Dim s As String
    s = _Trim$(Str$(v))
    ' QB64 drops the leading zero on fractions; put it back.
    If Left$(s, 1) = "." Then s = "0" + s
    If Left$(s, 2) = "-." Then s = "-0" + Mid$(s, 2)
    FormatNum$ = s
End Function


Sub InitColors
    cBg = _RGB32(24, 26, 32)
    cTitle = _RGB32(240, 244, 252)
    cPanel = _RGB32(38, 42, 52)
    cPanelEdge = _RGB32(70, 78, 96)
    cEntry = _RGB32(236, 240, 248)
    cPending = _RGB32(140, 152, 172)
    cWarn = _RGB32(226, 150, 120)
    cHint = _RGB32(120, 130, 148)
    cOpFace = _RGB32(58, 78, 104)
    cActOp = _RGB32(40, 110, 92)
End Sub

'$Include:'ButtonUI.bm'
