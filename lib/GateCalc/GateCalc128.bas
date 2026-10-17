_Title "Gate Calculator 128"

' 128-bit signed calculator. Every add, subtract, multiply,
' divide and decimal conversion is done by the logic gate library
' (Gate, Alu128). Buttons come from ButtonUI.
'
' Keep Gate, Alu128 and ButtonUI (.bi and .bm) in this folder.
' Each .bi is included below at the top; each .bm at the very
' bottom.
'$Include:'Gate.bi'
'$Include:'Alu128.bi'
'$Include:'ButtonUI.bi'

Const CALCW = 620
Const CALCH = 626

' --- calculator state ---
' cAcc     accumulator (128-bit two's complement)
' cMag     magnitude of the number being typed, cNeg its sign
' cPend    pending operator: 0 none, 1 +, 2 -, 3 x, 4 /
' cEnter   -1 while a number is being typed
' cErr     -1 after a divide by zero (press C)
' cRemStr  remainder of the last divide, already in decimal
Dim Shared cAcc As Word128, cMag As Word128
Dim Shared cGateOps As _Integer64, cRemStr As String
Dim Shared cPend As Integer, cEnter As Integer, cNeg As Integer
Dim Shared cErr As Integer, cHasRem As Integer
Dim Shared cC As Integer, cV As Integer, cN As Integer, cZ As Integer

' --- readout cache: a 128-bit double dabble takes thousands of
' gate evaluations, so the string is rebuilt only when the value
' on the display changes ---
Dim Shared dispLo As _Integer64, dispHi As _Integer64
Dim Shared dispStr As String, dispHave As Integer

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

Dim kk As String, shown As Word128, quitFlag As Integer
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

    CurVal shown

    Cls , colBg
    DrawHeader
    DrawDisplay shown
    DrawStatus
    DrawBits shown
    DrawFlags

    ' ---- keypad ----
    If Btn%(20, 266, 139, 54, "C", 3) Then KeyClear
    If Btn%(167, 266, 139, 54, "CE", 3) Then KeyCE
    If Btn%(314, 266, 139, 54, "<-", 0) Then KeyBack
    If Btn%(461, 266, 139, 54, "/", 1) Then KeyOp 4

    If Btn%(20, 330, 139, 54, "7", 0) Then KeyDigit 7
    If Btn%(167, 330, 139, 54, "8", 0) Then KeyDigit 8
    If Btn%(314, 330, 139, 54, "9", 0) Then KeyDigit 9
    If Btn%(461, 330, 139, 54, "x", 1) Then KeyOp 3

    If Btn%(20, 394, 139, 54, "4", 0) Then KeyDigit 4
    If Btn%(167, 394, 139, 54, "5", 0) Then KeyDigit 5
    If Btn%(314, 394, 139, 54, "6", 0) Then KeyDigit 6
    If Btn%(461, 394, 139, 54, "-", 1) Then KeyOp 2

    If Btn%(20, 458, 139, 54, "1", 0) Then KeyDigit 1
    If Btn%(167, 458, 139, 54, "2", 0) Then KeyDigit 2
    If Btn%(314, 458, 139, 54, "3", 0) Then KeyDigit 3
    If Btn%(461, 458, 139, 54, "+", 1) Then KeyOp 1

    If Btn%(20, 522, 139, 54, "+/-", 0) Then KeyNeg
    If Btn%(167, 522, 139, 54, "0", 0) Then KeyDigit 0
    If Btn%(314, 522, 139, 54, "Quit", 0) Then quitFlag = -1
    If Btn%(461, 522, 139, 54, "=", 2) Then KeyEq

    _Display
Loop Until quitFlag

System

'-------------------------------------------------------------------
' Calculator engine. Arithmetic is all gate-level (Alu128).
'-------------------------------------------------------------------

' The value on the display: the number being typed, else the accumulator.
Sub CurVal (rOut As Word128)
    If cEnter Then
        If cNeg Then
            Alu128Negate cMag, rOut
        Else
            rOut = cMag
        End If
    Else
        rOut = cAcc
    End If
End Sub

Sub SetFlags (r As Word128, cy As Integer, ov As Integer)
    cZ = Alu128IsZero%(r)
    cN = Alu128Bit%(r, 127)
    cC = cy
    cV = ov
End Sub

' Apply the pending operator: cAcc (pending op) operand.
Sub ApplyPending (operand As Word128)
    Dim r As Word128, q As Word128, rm As Word128
    Dim cy As Integer, ov As Integer, bo As Integer, dz As Integer
    cy = 0
    ov = 0
    cHasRem = 0
    GateEvalCount = 0
    Select Case cPend
        Case 1
            Alu128Add cAcc, operand, 0, 128, r, cy, ov
        Case 2
            Alu128Sub cAcc, operand, 128, r, bo, ov
            cy = GateEval%(GATE_NOT, bo, 0)
        Case 3
            Alu128MulS cAcc, operand, r, ov
        Case 4
            Alu128DivS cAcc, operand, q, rm, dz, ov
            If dz Then
                cErr = -1
                cGateOps = GateEvalCount
                Exit Sub
            End If
            r = q
            cHasRem = -1
        Case Else
            r = operand
    End Select
    cAcc = r
    SetFlags r, cy, ov
    cGateOps = GateEvalCount
    ' format the remainder after the count is taken, so the
    ' count covers the arithmetic only
    If cHasRem Then cRemStr = Alu128Fmt$(rm)
End Sub

Sub KeyDigit (dg As Integer)
    Dim nv As Word128, ok As Integer
    If cErr Then Exit Sub
    If cEnter = 0 Then
        cEnter = -1
        Alu128Load cMag, 0
        cNeg = 0
    End If
    ' accept only while the typed magnitude still fits in 127 bits
    Alu128DigitAppend cMag, dg, nv, ok
    If ok Then cMag = nv
End Sub

Sub KeyOp (opk As Integer)
    Dim cur As Word128
    If cErr Then Exit Sub
    CurVal cur
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
    Dim cur As Word128
    If cErr Then Exit Sub
    CurVal cur
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
    Dim zero As Word128, r As Word128
    Dim bo As Integer, ov As Integer, cy As Integer
    If cErr Then Exit Sub
    If cEnter Then
        cNeg = GateEval%(GATE_NOT, cNeg, 0)
    Else
        Alu128Load zero, 0
        Alu128Sub zero, cAcc, 128, r, bo, ov
        cy = GateEval%(GATE_NOT, bo, 0)
        cAcc = r
        SetFlags r, cy, ov
    End If
End Sub

' Backspace divides the typed magnitude by 10 with the gate divider.
Sub KeyBack
    Dim q As Word128, rm As Word128, ten As Word128
    If cErr Then Exit Sub
    If cEnter Then
        Alu128Load ten, 10
        Alu128DivU cMag, ten, q, rm
        cMag = q
    End If
End Sub

Sub KeyCE
    Alu128Load cMag, 0
    cNeg = 0
    cEnter = -1
    cErr = 0
End Sub

Sub KeyClear
    Alu128Load cAcc, 0
    Alu128Load cMag, 0
    cRemStr = ""
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

' Try a few common monospace fonts for the readout; without one
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
            f = _LoadFont(p, 22, "MONOSPACE")
            If f > 0 Then Exit For
        End If
    Next
    bigFont = f
End Sub

Sub DrawHeader
    Color colText
    _PrintString (20, 12), "128-bit Gate Calculator"
    Color colDim
    _PrintString (20, 30), "every result is computed by logic gates"
End Sub

Sub DrawDisplay (v As Word128)
    Dim s As String, w As Long, tx As Long, ty As Long
    If cErr Then
        s = "ERROR"
    Else
        If dispHave = 0 Or v.lo <> dispLo Or v.hi <> dispHi Then
            dispStr = Alu128Fmt$(v)
            dispLo = v.lo
            dispHi = v.hi
            dispHave = -1
        End If
        s = dispStr
    End If
    Line (20, 48)-(600, 118), colPanel, BF
    Line (20, 48)-(600, 118), colEdge, B
    If cErr Then Color colErr Else Color colText
    If bigFont > 0 Then
        _Font bigFont
        w = _PrintWidth(s)
        tx = 592 - w
        ty = 83 - _FontHeight \ 2
        _PrintString (tx, ty), s
        _Font 16
    Else
        w = _PrintWidth(s)
        tx = 592 - w
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
        If cHasRem Then s = s + "    Remainder: " + cRemStr
        Color colDim
        _PrintString (20, 124), s
    End If
    If cGateOps > 0 Then
        Color colDim
        _PrintString (20, 586), "Last operation: " + _Trim$(Str$(cGateOps)) + " gate evaluations"
    End If
    Color colDim
    _PrintString (20, 604), "Keys: 0-9 + - * / = Enter  Bksp  C clear  N sign  Esc"
End Sub

' 128 lamps in four rows of 32, bit 127 at the top left. Each row
' is labelled with the number of its leftmost (highest) bit.
Sub DrawBits (v As Word128)
    Dim i As Integer, rw As Integer, x As Integer, y As Integer
    Color colDim
    For rw = 0 To 3
        _PrintString (20, 146 + rw * 20), _Trim$(Str$(127 - rw * 32))
    Next
    For i = 127 To 0 Step -1
        rw = (127 - i) \ 32
        x = 56 + ((127 - i) Mod 32) * 17
        y = 146 + rw * 20
        If Alu128Bit%(v, i) Then
            Line (x, y)-(x + 13, y + 15), colLedOn, BF
        Else
            Line (x, y)-(x + 13, y + 15), colLedOff, BF
        End If
    Next
End Sub

Sub DrawFlags
    Call FlagLamp(20, "N neg", cN)
    Call FlagLamp(167, "Z zero", cZ)
    Call FlagLamp(314, "C carry", cC)
    Call FlagLamp(461, "V ovf", cV)
End Sub

Sub FlagLamp (x As Integer, lbl As String, lit As Integer)
    If lit Then
        Line (x, 232)-(x + 138, 253), colLedOn, BF
        Color colBg
    Else
        Line (x, 232)-(x + 138, 253), colLedOff, BF
        Color colDim
    End If
    _PrintString (x + 8, 235), lbl
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
'$Include:'Alu128.bm'
'$Include:'ButtonUI.bm'
