_Title "Gate Calculator 32"

' 32-bit signed calculator. Every add, subtract, multiply, divide
' and decimal conversion is done by the logic gate library
' (Gate, Adder, Alu32). Buttons come from ButtonUI.
'
' Keep Gate, Adder, Alu32 and ButtonUI (.bi and .bm) in this
' folder. Each .bi is included below at the top; each .bm at the
' very bottom.
'$Include:'Gate.bi'
'$Include:'Adder.bi'
'$Include:'Alu32.bi'
'$Include:'ButtonUI.bi'

Const CALCW = 450
Const CALCH = 622

' --- calculator state ---
' cAcc     accumulator (32-bit two's complement)
' cMag     magnitude of the number being typed, cNeg its sign
' cPend    pending operator: 0 none, 1 +, 2 -, 3 x, 4 /
' cEnter   -1 while a number is being typed
' cErr     -1 after a divide by zero (press C)
Dim Shared cAcc As Long, cMag As Long, cRem As Long, cGateOps As _Integer64
Dim Shared cPend As Integer, cEnter As Integer, cNeg As Integer
Dim Shared cErr As Integer, cHasRem As Integer
Dim Shared cC As Integer, cV As Integer, cN As Integer, cZ As Integer

' --- look ---
Dim Shared bigFont As Long
Dim Shared colBg As _Unsigned Long, colPanel As _Unsigned Long
Dim Shared colEdge As _Unsigned Long, colText As _Unsigned Long
Dim Shared colDim As _Unsigned Long, colLedOn As _Unsigned Long
Dim Shared colLedOff As _Unsigned Long, colErr As _Unsigned Long

Screen _NewImage(CALCW, CALCH, 32)
_ScreenMove _Middle
_PrintMode _KeepBackground
MouseInit

colBg = _RGB32(22, 24, 30)
colPanel = _RGB32(12, 14, 18)
colEdge = _RGB32(70, 76, 90)
colText = _RGB32(226, 230, 238)
colDim = _RGB32(150, 156, 168)
colLedOn = _RGB32(80, 220, 120)
colLedOff = _RGB32(38, 44, 56)
colErr = _RGB32(240, 110, 110)

LoadBigFont
KeyClear

Dim kk As String, shown As Long, quitFlag As Integer
quitFlag = 0

Do
    _Limit 60
    PollMouse

    ' ---- keyboard ----
    kk = InKey$
    Do While kk <> ""
        Select Case kk
            Case "0" To "9": KeyDigit Asc(kk) - 48
            Case "+": KeyOp 1
            Case "-": KeyOp 2
            Case "*", "x", "X": KeyOp 3
            Case "/": KeyOp 4
            Case "=", Chr$(13): KeyEq
            Case Chr$(8): KeyBack
            Case "c", "C": KeyClear
            Case "n", "N": KeyNeg
            Case Chr$(27): quitFlag = -1
        End Select
        kk = InKey$
    Loop

    shown = CurVal&

    Cls , colBg
    DrawHeader
    DrawDisplay shown
    DrawStatus
    DrawBits shown
    DrawFlags

    ' ---- keypad ----
    If Btn%(20, 262, 95, 54, "C", 3) Then KeyClear
    If Btn%(125, 262, 95, 54, "CE", 3) Then KeyCE
    If Btn%(230, 262, 95, 54, "<-", 0) Then KeyBack
    If Btn%(335, 262, 95, 54, "/", 1) Then KeyOp 4

    If Btn%(20, 326, 95, 54, "7", 0) Then KeyDigit 7
    If Btn%(125, 326, 95, 54, "8", 0) Then KeyDigit 8
    If Btn%(230, 326, 95, 54, "9", 0) Then KeyDigit 9
    If Btn%(335, 326, 95, 54, "x", 1) Then KeyOp 3

    If Btn%(20, 390, 95, 54, "4", 0) Then KeyDigit 4
    If Btn%(125, 390, 95, 54, "5", 0) Then KeyDigit 5
    If Btn%(230, 390, 95, 54, "6", 0) Then KeyDigit 6
    If Btn%(335, 390, 95, 54, "-", 1) Then KeyOp 2

    If Btn%(20, 454, 95, 54, "1", 0) Then KeyDigit 1
    If Btn%(125, 454, 95, 54, "2", 0) Then KeyDigit 2
    If Btn%(230, 454, 95, 54, "3", 0) Then KeyDigit 3
    If Btn%(335, 454, 95, 54, "+", 1) Then KeyOp 1

    If Btn%(20, 518, 95, 54, "+/-", 0) Then KeyNeg
    If Btn%(125, 518, 95, 54, "0", 0) Then KeyDigit 0
    If Btn%(230, 518, 95, 54, "Quit", 0) Then quitFlag = -1
    If Btn%(335, 518, 95, 54, "=", 2) Then KeyEq

    _Display
Loop Until quitFlag

System

'-------------------------------------------------------------------
' Calculator engine. Arithmetic is all gate-level (Adder / Alu32).
'-------------------------------------------------------------------

' The value on the display: the number being typed, else the accumulator.
Function CurVal&
    Dim r As Long
    If cEnter Then
        If cNeg Then
            r = AddNegate&(cMag, 32)
        Else
            r = cMag
        End If
    Else
        r = cAcc
    End If
    CurVal& = r
End Function

Sub SetFlags (r As Long, cy As Integer, ov As Integer)
    cZ = Alu32IsZero%(r)
    cN = AddBit%(r, 31)
    cC = cy
    cV = ov
End Sub

' Apply the pending operator: cAcc (pending op) operand.
Sub ApplyPending (operand As Long)
    Dim r As Long, q As Long, rm As Long
    Dim cy As Integer, ov As Integer, bo As Integer, dz As Integer
    cy = 0
    ov = 0
    cHasRem = 0
    GateEvalCount = 0
    Select Case cPend
        Case 1
            AddRipple cAcc, operand, 0, 32, r, cy, ov
        Case 2
            AddSubtract cAcc, operand, 32, r, bo, ov
            cy = GateEval%(GATE_NOT, bo, 0)
        Case 3
            Alu32MulS cAcc, operand, r, ov
        Case 4
            Alu32DivS cAcc, operand, q, rm, dz, ov
            If dz Then
                cErr = -1
                cGateOps = GateEvalCount
                Exit Sub
            End If
            r = q
            cRem = rm
            cHasRem = -1
        Case Else
            r = operand
    End Select
    cAcc = r
    SetFlags r, cy, ov
    cGateOps = GateEvalCount
End Sub

Sub KeyDigit (dg As Integer)
    Dim nv As Long, ok As Integer
    If cErr Then Exit Sub
    If cEnter = 0 Then
        cEnter = -1
        cMag = 0
        cNeg = 0
    End If
    ' accept only while the typed magnitude still fits in 31 bits
    nv = Alu32DigitAppend&(cMag, dg, ok)
    If ok Then cMag = nv
End Sub

Sub KeyOp (opk As Integer)
    Dim cur As Long
    If cErr Then Exit Sub
    cur = CurVal&
    If cPend <> 0 And cEnter <> 0 Then
        ApplyPending cur
        If cErr Then Exit Sub
    ElseIf cPend = 0 Then
        cAcc = cur
    End If
    cPend = opk
    cEnter = 0
End Sub

Sub KeyEq
    Dim cur As Long
    If cErr Then Exit Sub
    cur = CurVal&
    If cPend <> 0 And cEnter <> 0 Then
        ApplyPending cur
        If cErr Then Exit Sub
    ElseIf cPend = 0 Then
        cAcc = cur
    End If
    cPend = 0
    cEnter = 0
End Sub

Sub KeyNeg
    Dim zero As Long, r As Long
    Dim bo As Integer, ov As Integer, cy As Integer
    If cErr Then Exit Sub
    If cEnter Then
        cNeg = GateEval%(GATE_NOT, cNeg, 0)
    Else
        zero = 0
        AddSubtract zero, cAcc, 32, r, bo, ov
        cy = GateEval%(GATE_NOT, bo, 0)
        cAcc = r
        SetFlags r, cy, ov
    End If
End Sub

' Backspace divides the typed magnitude by 10 with the gate divider.
Sub KeyBack
    Dim q As Long, rm As Long, ten As Long
    If cErr Then Exit Sub
    If cEnter Then
        ten = 10
        Alu32DivU cMag, ten, q, rm
        cMag = q
    End If
End Sub

Sub KeyCE
    cMag = 0
    cNeg = 0
    cEnter = -1
    cErr = 0
End Sub

Sub KeyClear
    cAcc = 0
    cMag = 0
    cRem = 0
    cGateOps = 0
    cPend = 0
    cEnter = 0
    cNeg = 0
    cErr = 0
    cHasRem = 0
    cC = 0
    cV = 0
    cN = 0
    cZ = 0
End Sub

'-------------------------------------------------------------------
' Drawing
'-------------------------------------------------------------------

' Try a few common monospace fonts for the big readout; without one
' the display falls back to the built-in font.
Sub LoadBigFont
    Dim f As Long, i As Integer, p As String
    f = 0
    For i = 1 To 4
        Select Case i
            Case 1
                p = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
            Case 2
                p = "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf"
            Case 3
                p = "C:\Windows\Fonts\consola.ttf"
            Case Else
                p = "C:\Windows\Fonts\cour.ttf"
        End Select
        If _FileExists(p) Then
            f = _LoadFont(p, 40, "MONOSPACE")
            If f > 0 Then Exit For
        End If
    Next
    bigFont = f
End Sub

Sub DrawHeader
    Color colText
    _PrintString (20, 12), "32-bit Gate Calculator"
    Color colDim
    _PrintString (20, 30), "every result is computed by logic gates"
End Sub

Sub DrawDisplay (v As Long)
    Dim s As String, w As Long, tx As Long, ty As Long
    If cErr Then
        s = "ERROR"
    Else
        s = Alu32Fmt$(v)
    End If
    Line (20, 48)-(430, 118), colPanel, BF
    Line (20, 48)-(430, 118), colEdge, B
    If cErr Then Color colErr Else Color colText
    If bigFont > 0 Then
        _Font bigFont
        w = _PrintWidth(s)
        tx = 422 - w
        ty = 83 - _FontHeight \ 2
        _PrintString (tx, ty), s
        _Font 16
    Else
        w = _PrintWidth(s)
        tx = 422 - w
        _PrintString (tx, 75), s
    End If
End Sub

Sub DrawStatus
    Dim s As String
    If cErr Then
        Color colErr
        _PrintString (20, 124), "Divide by zero - press C"
    Else
        s = "Op: "
        Select Case cPend
            Case 1
                s = s + "+"
            Case 2
                s = s + "-"
            Case 3
                s = s + "x"
            Case 4
                s = s + "/"
            Case Else
                s = s + "none"
        End Select
        If cHasRem Then s = s + "    Remainder: " + Alu32Fmt$(cRem)
        Color colDim
        _PrintString (20, 124), s
    End If
    If cGateOps > 0 Then
        Color colDim
        _PrintString (20, 582), "Last operation: " + _Trim$(Str$(cGateOps)) + " gate evaluations"
    End If
    Color colDim
    _PrintString (20, 600), "Keys: 0-9 + - * / = Enter  Bksp  C clear  N sign  Esc"
End Sub

' 32 lamps in two rows of 16: bits 31-16 on top, 15-0 below.
Sub DrawBits (v As Long)
    Dim i As Integer, x As Integer, y As Integer
    Color colDim
    _PrintString (20, 144), "bit 31"
    _PrintString (382, 144), "bit 16"
    _PrintString (20, 184), "bit 15"
    _PrintString (390, 184), "bit 0"
    For i = 31 To 0 Step -1
        If i >= 16 Then
            x = 20 + (31 - i) * 26
            y = 162
        Else
            x = 20 + (15 - i) * 26
            y = 202
        End If
        If AddBit%(v, i) Then
            Line (x, y)-(x + 19, y + 17), colLedOn, BF
        Else
            Line (x, y)-(x + 19, y + 17), colLedOff, BF
        End If
    Next
End Sub

Sub DrawFlags
    Call FlagLamp(20, "N neg", cN)
    Call FlagLamp(126, "Z zero", cZ)
    Call FlagLamp(232, "C carry", cC)
    Call FlagLamp(338, "V ovf", cV)
End Sub

Sub FlagLamp (x As Integer, lbl As String, lit As Integer)
    If lit Then
        Line (x, 228)-(x + 91, 249), colLedOn, BF
        Color colBg
    Else
        Line (x, 228)-(x + 91, 249), colLedOff, BF
        Color colDim
    End If
    _PrintString (x + 8, 231), lbl
End Sub

' A ButtonUI button with an optional colour: 0 normal, 1 operator,
' 2 equals, 3 clear. Theme colours are restored after each button.
Function Btn% (x As Integer, y As Integer, w As Integer, h As Integer, lbl As String, kind As Integer)
    Dim sf As _Unsigned Long, sh As _Unsigned Long, sd As _Unsigned Long
    Dim r As Integer
    sf = uiFace
    sh = uiFaceHover
    sd = uiFaceDown
    Select Case kind
        Case 1
            uiFace = _RGB32(150, 92, 40)
            uiFaceHover = _RGB32(184, 114, 52)
            uiFaceDown = _RGB32(120, 72, 30)
        Case 2
            uiFace = _RGB32(46, 110, 64)
            uiFaceHover = _RGB32(60, 140, 82)
            uiFaceDown = _RGB32(34, 84, 50)
        Case 3
            uiFace = _RGB32(140, 52, 52)
            uiFaceHover = _RGB32(176, 66, 66)
            uiFaceDown = _RGB32(108, 40, 40)
    End Select
    r = Button%((x), (y), (w), (h), lbl)
    uiFace = sf
    uiFaceHover = sh
    uiFaceDown = sd
    Btn% = r
End Function

'$Include:'Gate.bm'
'$Include:'Adder.bm'
'$Include:'Alu32.bm'
'$Include:'ButtonUI.bm'
