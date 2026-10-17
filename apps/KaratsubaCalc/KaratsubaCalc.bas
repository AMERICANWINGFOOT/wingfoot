_Title "Karatsuba Big-Integer Calculator"

' Add an Include metacommand for ButtonUI.bi HERE at the top (done below),
' and one for ButtonUI.bm at the very bottom of this file.
'$Include:'ButtonUI.bi'

Const SCRW = 860
Const SCRH = 640
Const MAXDIG = 96 '   per-field digit cap (keeps a field on one line)

' --- Big-integer engine (unchanged string routines) ---
Declare Function Karatsuba$ (X$, Y$)
Declare Function PadLeft$ (S$, L%)
Declare Function AddStrings$ (A$, B$)
Declare Function SubStrings$ (A$, B$)
Declare Function ShiftLeft$ (S$, N%)
Declare Function StripZeros$ (S$)
Declare Function CompareBig% (A$, B$)
Declare Sub DivideBig (numer As String, denom As String, quotient As String, remainder As String)

' --- Shared UI state (so the little helper Subs can see it) ---
Dim Shared fldA As String, fldB As String
Dim Shared activeField As Integer '   0 = Operand A, 1 = Operand B

' --- Screen & theme ---
Screen _NewImage(SCRW, SCRH, 32)
_ScreenMove _Middle
_PrintMode _KeepBackground '   transparent captions, no black boxes over panels
MouseInit '                    ButtonUI default slate-blue theme

' --- Palette ---
Dim colBg As _Unsigned Long, colText As _Unsigned Long, colDim As _Unsigned Long
Dim colResult As _Unsigned Long, colWarn As _Unsigned Long
colBg = _RGB32(22, 24, 30)
colText = _RGB32(226, 230, 238)
colDim = _RGB32(150, 156, 168)
colResult = _RGB32(150, 230, 170)
colWarn = _RGB32(240, 170, 90)

' --- Loop-scope locals (declared up front) ---
Dim resStr As String, remStr As String, elapsedMS As Double
Dim oper As Integer, lastOp As Integer, divErr As Integer
Dim caretOn As Integer, quitFlag As Integer
Dim aStr As String, bStr As String, t0 As Double
Dim qStr As String, rStr As String, cmp As Integer, rlen As Integer
Dim opName As String
Dim savF As _Unsigned Long, savH As _Unsigned Long, savD As _Unsigned Long
Dim af As String, tms As String, kk As String

resStr = ""
remStr = ""
opName = ""
elapsedMS = -1
activeField = 0
lastOp = 0

Do
    _Limit 60
    PollMouse

    ' The operation flag is rebuilt from scratch every frame, BEFORE we read
    ' the keyboard or draw the buttons, so both input paths feed the same
    ' flag and neither gets clobbered later in the frame.
    oper = 0

    ' ---- keyboard: digits, backspace, tab, operators, enter, esc ----
    kk = InKey$
    Do While kk <> ""
        Select Case kk
            Case "0" To "9": AppendDigit kk
            Case Chr$(8): BackspaceField '           Backspace
            Case Chr$(9): activeField = 1 - activeField ' Tab
            Case "+": oper = 1 '                     Add
            Case "-": oper = 2 '                     Subtract
            Case "*", "x", "X": oper = 3 '           Multiply
            Case "/", "\": oper = 4 '                Divide
            Case Chr$(13) '                          Enter = repeat last op
                If lastOp = 0 Then oper = 3 Else oper = lastOp
            Case Chr$(27): quitFlag = -1 '           Esc
        End Select
        kk = InKey$
    Loop

    caretOn = (Int(Timer * 2) Mod 2 = 0)

    Cls , colBg

    ' ---- header ----
    TextAt 30, 14, "Karatsuba Big-Integer Calculator", colText
    TextAt 30, 36, "Add, subtract, multiply (Karatsuba) and divide - on-screen keypad or type.", colDim

    ' ---- input fields (click to select which one you're typing into) ----
    TextAt 30, 60, "Operand A", colDim
    DrawField 30, 80, 800, 36, fldA, (activeField = 0), caretOn
    TextAt 30, 128, "Operand B", colDim
    DrawField 30, 148, 800, 36, fldB, (activeField = 1), caretOn

    If gMouse.clicked Then
        If PtInRect%(gMouse.mx, gMouse.my, 30, 80, 800, 36) Then activeField = 0
        If PtInRect%(gMouse.mx, gMouse.my, 30, 148, 800, 36) Then activeField = 1
    End If

    ' ---- numeric keypad ----
    If Button%(30, 210, 62, 46, "7") Then AppendDigit "7"
    If Button%(102, 210, 62, 46, "8") Then AppendDigit "8"
    If Button%(174, 210, 62, 46, "9") Then AppendDigit "9"
    If Button%(30, 266, 62, 46, "4") Then AppendDigit "4"
    If Button%(102, 266, 62, 46, "5") Then AppendDigit "5"
    If Button%(174, 266, 62, 46, "6") Then AppendDigit "6"
    If Button%(30, 322, 62, 46, "1") Then AppendDigit "1"
    If Button%(102, 322, 62, 46, "2") Then AppendDigit "2"
    If Button%(174, 322, 62, 46, "3") Then AppendDigit "3"
    If Button%(30, 378, 62, 46, "0") Then AppendDigit "0"
    If Button%(102, 378, 62, 46, "<-") Then BackspaceField
    If Button%(174, 378, 62, 46, "Clr") Then ClearActive

    ' ---- operation buttons (green action accent, 2x2 grid) ----
    savF = uiFace: savH = uiFaceHover: savD = uiFaceDown
    uiFace = _RGB32(46, 110, 64): uiFaceHover = _RGB32(60, 140, 82): uiFaceDown = _RGB32(34, 84, 50)
    If Button%(270, 210, 76, 46, "Add") Then oper = 1
    If Button%(354, 210, 76, 46, "Subtract") Then oper = 2
    If Button%(270, 266, 76, 46, "Multiply") Then oper = 3
    If Button%(354, 266, 76, 46, "Divide") Then oper = 4
    uiFace = savF: uiFaceHover = savH: uiFaceDown = savD

    ' ---- utility buttons ----
    If Button%(270, 322, 76, 46, "Swap") Then Swap fldA, fldB
    If Button%(354, 322, 76, 46, "Reset") Then
        fldA = "": fldB = "": resStr = "": remStr = ""
        lastOp = 0: divErr = 0: elapsedMS = -1
    End If
    If Button%(270, 378, 160, 46, "Load Sample") Then
        fldA = "12345678901234567890": fldB = "98765432109876543210"
        resStr = "": remStr = "": lastOp = 0: divErr = 0: elapsedMS = -1
    End If

    ' ---- run the requested operation (from a button OR the keyboard) ----
    divErr = 0
    If oper Then
        aStr = fldA: If aStr = "" Then aStr = "0"
        bStr = fldB: If bStr = "" Then bStr = "0"
        t0 = Timer(0.001)
        Select Case oper
            Case 1 ' add
                resStr = StripZeros$(AddStrings$(aStr, bStr))
                remStr = "": opName = "A + B"
            Case 2 ' subtract (sign-aware: fields hold no minus, so we add one)
                cmp = CompareBig%(aStr, bStr)
                If cmp >= 0 Then
                    resStr = SubStrings$(aStr, bStr)
                Else
                    resStr = "-" + SubStrings$(bStr, aStr)
                End If
                remStr = "": opName = "A - B"
            Case 3 ' multiply
                resStr = Karatsuba$(aStr, bStr)
                remStr = "": opName = "A x B"
            Case 4 ' integer divide -> quotient + remainder
                opName = "A \ B"
                If StripZeros$(bStr) = "0" Then
                    divErr = -1: resStr = "": remStr = ""
                Else
                    DivideBig aStr, bStr, qStr, rStr
                    resStr = qStr: remStr = rStr
                End If
        End Select
        elapsedMS = (Timer(0.001) - t0) * 1000
        If elapsedMS < 0 Then elapsedMS = 0 '  guard midnight wrap
        lastOp = oper
    End If

    ' ---- status panel ----
    Panel 450, 210, 380, 214
    TextAt 464, 222, "STATUS", colDim
    If activeField = 0 Then af = "Operand A" Else af = "Operand B"
    TextAt 464, 248, "Active field : " + af, colText
    TextAt 464, 272, "Operand A : " + _Trim$(Str$(Len(fldA))) + " digits", colText
    TextAt 464, 296, "Operand B : " + _Trim$(Str$(Len(fldB))) + " digits", colText

    If divErr Then
        TextAt 464, 320, "Result    : (undefined)", colText
    ElseIf Len(resStr) = 0 Then
        TextAt 464, 320, "Result    : -", colText
    Else
        rlen = Len(resStr)
        If Left$(resStr, 1) = "-" Then rlen = rlen - 1
        TextAt 464, 320, "Result    : " + _Trim$(Str$(rlen)) + " digits", colText
    End If

    If lastOp = 4 And Not divErr And Len(remStr) Then
        TextAt 464, 344, "Remainder : " + _Trim$(Str$(Len(remStr))) + " digits", colText
    Else
        TextAt 464, 344, "Remainder : -", colDim
    End If

    If lastOp = 0 Then
        TextAt 464, 368, "Last op   : -", colText
    Else
        TextAt 464, 368, "Last op   : " + opName, colText
    End If

    If elapsedMS < 0 Then
        tms = "-"
    Else
        tms = _Trim$(Str$(Int(elapsedMS * 1000 + 0.5) / 1000)) + " ms"
    End If
    TextAt 464, 388, "Elapsed   : " + tms, colText
    TextAt 464, 408, "Keys: 0-9  + - x /  Bksp Tab Enter Esc", colDim

    ' ---- result panel (wrapped) ----
    Panel 30, 438, 800, 190
    If divErr Then
        TextAt 44, 450, "RESULT  (A \ B)", colDim
        TextAt 44, 480, "Cannot divide by zero - Operand B is 0.", colWarn
    ElseIf lastOp = 4 And Len(resStr) Then
        TextAt 44, 450, "QUOTIENT  (A \ B)", colDim
        WrapText resStr, 44, 474, 96, 20, colResult
        TextAt 44, 536, "REMAINDER", colDim
        WrapText remStr, 44, 560, 96, 20, colResult
    ElseIf Len(resStr) Then
        TextAt 44, 450, "RESULT  (" + opName + ")", colDim
        WrapText resStr, 44, 476, 96, 20, colResult
    Else
        TextAt 44, 450, "RESULT", colDim
        TextAt 44, 476, "Type two numbers, then press  + - x /  (or a button).", colDim
    End If

    _Display
Loop Until quitFlag

System

' =========================================================================
' UI HELPERS
' =========================================================================
Sub TextAt (x As Integer, y As Integer, s As String, c As _Unsigned Long)
    Color c
    _PrintMode _KeepBackground
    _PrintString (x, y), s
End Sub

Sub Panel (x As Integer, y As Integer, w As Integer, h As Integer)
    Line (x, y)-(x + w, y + h), _RGB32(32, 35, 44), BF
    Line (x, y)-(x + w, y + h), _RGB32(60, 66, 82), B
End Sub

Sub DrawField (x As Integer, y As Integer, w As Integer, h As Integer, value As String, isActive As Integer, caretOn As Integer)
    Dim bord As _Unsigned Long, cx As Integer
    If isActive Then bord = _RGB32(120, 180, 250) Else bord = _RGB32(60, 66, 82)
    Line (x, y)-(x + w, y + h), _RGB32(16, 18, 24), BF
    Line (x, y)-(x + w, y + h), bord, B
    Color _RGB32(226, 230, 238)
    _PrintString (x + 8, y + (h - 16) \ 2), value
    If isActive And caretOn Then
        cx = x + 8 + Len(value) * 8
        Line (cx, y + 7)-(cx, y + h - 7), _RGB32(226, 230, 238)
    End If
End Sub

Sub WrapText (txt As String, x As Integer, y As Integer, maxCh As Integer, lineH As Integer, c As _Unsigned Long)
    Dim i As Long, ln As Integer
    Color c
    ln = 0
    i = 1
    Do While i <= Len(txt)
        _PrintString (x, y + ln * lineH), Mid$(txt, i, maxCh)
        i = i + maxCh
        ln = ln + 1
    Loop
End Sub

Sub AppendDigit (d As String)
    If activeField = 0 Then
        If Len(fldA) < MAXDIG Then fldA = fldA + d
    Else
        If Len(fldB) < MAXDIG Then fldB = fldB + d
    End If
End Sub

Sub BackspaceField
    If activeField = 0 Then
        If Len(fldA) > 0 Then fldA = Left$(fldA, Len(fldA) - 1)
    Else
        If Len(fldB) > 0 Then fldB = Left$(fldB, Len(fldB) - 1)
    End If
End Sub

Sub ClearActive
    If activeField = 0 Then fldA = "" Else fldB = ""
End Sub

' =========================================================================
' KARATSUBA MULTIPLICATION ALGORITHM
' =========================================================================
Function Karatsuba$ (X$, Y$)
    Dim xClean As String, yClean As String
    xClean = StripZeros$(X$)
    yClean = StripZeros$(Y$)

    ' Base cases
    If xClean = "0" Or yClean = "0" Then
        Karatsuba$ = "0"
        Exit Function
    End If
    ' Single-limb base case: up to 8 digits each collapses to ONE native
    ' 64-bit multiply. 8x8 digits gives at most 16 digits, which fits an
    ' _Integer64 exactly (max ~9.2e18). This is where the 8-at-a-time win
    ' really lands -- the recursion bottoms out three levels sooner.
    If Len(xClean) <= 8 And Len(yClean) <= 8 Then
        Dim xLimb As _Integer64, yLimb As _Integer64
        xLimb = Val(xClean)
        yLimb = Val(yClean)
        Karatsuba$ = LTrim$(Str$(xLimb * yLimb))
        Exit Function
    End If

    ' Equalize lengths by padding with leading zeros
    Dim maxLen As Integer
    maxLen = Len(xClean)
    If Len(yClean) > maxLen Then maxLen = Len(yClean)

    ' Round up to a multiple of 16 so that each half is a whole number of
    ' 8-digit limbs. The split point is still a plain power of ten, so the
    ' z2/z1/z0 recombination below is unchanged -- only the primitives
    ' (add, subtract, base multiply) work a limb at a time.
    If (maxLen Mod 16) <> 0 Then maxLen = maxLen + (16 - (maxLen Mod 16))

    Dim xPad As String, yPad As String
    xPad = PadLeft$(xClean, maxLen)
    yPad = PadLeft$(yClean, maxLen)

    ' Midpoint for split (a multiple of 8 -> limb-aligned)
    Dim m As Integer, m2 As Integer
    m = maxLen \ 2
    m2 = maxLen - m

    ' Split strings into high and low parts
    Dim xH As String, xL As String, yH As String, yL As String
    xH = Left$(xPad, m)
    xL = Right$(xPad, m2)
    yH = Left$(yPad, m)
    yL = Right$(yPad, m2)

    ' Recursive steps
    Dim z2 As String, z0 As String, z1 As String
    z2 = Karatsuba$(xH, yH)
    z0 = Karatsuba$(xL, yL)

    ' z1 components: (xH + xL) * (yH + yL) - z2 - z0
    Dim sumX As String, sumY As String, p3 As String
    sumX = AddStrings$(xH, xL)
    sumY = AddStrings$(yH, yL)
    p3 = Karatsuba$(sumX, sumY)

    z1 = SubStrings$(p3, z2)
    z1 = SubStrings$(z1, z0)

    ' Shift results (multiply by base powers)
    Dim term1 As String, term2 As String
    term1 = ShiftLeft$(z2, m2 * 2)
    term2 = ShiftLeft$(z1, m2)

    ' Combine final terms
    Dim finalResult As String
    finalResult = AddStrings$(term1, term2)
    finalResult = AddStrings$(finalResult, z0)

    Karatsuba$ = StripZeros$(finalResult)
End Function

' =========================================================================
' BIG INTEGER HELPER FUNCTIONS
' =========================================================================
Function AddStrings$ (A$, B$)
    Dim maxLen As Integer
    maxLen = Len(A$)
    If Len(B$) > maxLen Then maxLen = Len(B$)
    ' Align to whole 8-digit limbs so every window is exactly 8 chars.
    If (maxLen Mod 8) <> 0 Then maxLen = maxLen + (8 - (maxLen Mod 8))

    Dim aPad As String, bPad As String
    aPad = PadLeft$(A$, maxLen)
    bPad = PadLeft$(B$, maxLen)

    Dim res As String, carry As _Integer64
    res = Space$(maxLen)
    carry = 0

    Dim p As Integer, limA As _Integer64, limB As _Integer64, acc As _Integer64
    For p = maxLen To 1 Step -8
        limA = Val(Mid$(aPad, p - 7, 8))
        limB = Val(Mid$(bPad, p - 7, 8))
        acc = limA + limB + carry '            <= 199999999, comfortably 64-bit
        carry = acc \ 100000000
        Mid$(res, p - 7, 8) = Right$("00000000" + LTrim$(Str$(acc Mod 100000000)), 8)
    Next p

    ' Final carry out of the top limb can only ever be 0 or 1.
    If carry > 0 Then
        res = "1" + res
    End If
    AddStrings$ = res
End Function

Function SubStrings$ (A$, B$)
    ' Assumes A$ >= B$
    Dim maxLen As Integer
    maxLen = Len(A$)
    ' Align to whole 8-digit limbs (pads both operands the same way).
    If (maxLen Mod 8) <> 0 Then maxLen = maxLen + (8 - (maxLen Mod 8))

    Dim aPad As String, bPad As String
    aPad = PadLeft$(A$, maxLen)
    bPad = PadLeft$(B$, maxLen)

    Dim res As String, borrow As _Integer64
    res = Space$(maxLen)
    borrow = 0

    Dim p As Integer, limA As _Integer64, limB As _Integer64, diff As _Integer64
    For p = maxLen To 1 Step -8
        limA = Val(Mid$(aPad, p - 7, 8))
        limB = Val(Mid$(bPad, p - 7, 8))
        diff = limA - limB - borrow
        If diff < 0 Then
            diff = diff + 100000000
            borrow = 1
        Else
            borrow = 0
        End If
        Mid$(res, p - 7, 8) = Right$("00000000" + LTrim$(Str$(diff)), 8)
    Next p

    SubStrings$ = StripZeros$(res)
End Function

Function ShiftLeft$ (S$, N%)
    If S$ = "0" Or N% <= 0 Then
        ShiftLeft$ = S$
    Else
        ShiftLeft$ = S$ + String$(N%, "0")
    End If
End Function

Function PadLeft$ (S$, L%)
    Dim diff As Integer
    diff = L% - Len(S$)
    If diff > 0 Then
        PadLeft$ = String$(diff, "0") + S$
    Else
        PadLeft$ = S$
    End If
End Function

Function StripZeros$ (S$)
    Dim i As Integer
    For i = 1 To Len(S$)
        If Mid$(S$, i, 1) <> "0" Then
            StripZeros$ = Mid$(S$, i)
            Exit Function
        End If
    Next i
    StripZeros$ = "0"
End Function

' -------------------------------------------------------------------------
' CompareBig% -- magnitude compare of two non-negative digit strings.
'   returns -1 if A < B, 0 if A = B, +1 if A > B
' Leading zeros are stripped first, then equal-length strings compare
' lexicographically (ASCII '0'..'9' order matches numeric order).
' -------------------------------------------------------------------------
Function CompareBig% (A$, B$)
    Dim sa As String, sb As String
    sa = StripZeros$(A$)
    sb = StripZeros$(B$)
    If Len(sa) < Len(sb) Then
        CompareBig% = -1
    ElseIf Len(sa) > Len(sb) Then
        CompareBig% = 1
    ElseIf sa < sb Then
        CompareBig% = -1
    ElseIf sa > sb Then
        CompareBig% = 1
    Else
        CompareBig% = 0
    End If
End Function

' -------------------------------------------------------------------------
' DivideBig -- schoolbook long division of two non-negative digit strings.
' Produces quotient and remainder by reference. Caller must ensure the
' divisor is non-zero (the UI catches divide-by-zero before calling).
' One digit of the dividend is brought down per step; the quotient digit
' is found by repeated subtraction (at most 9 subtractions per digit), so
' the whole thing rides on the existing SubStrings$ / CompareBig% limbs.
' -------------------------------------------------------------------------
Sub DivideBig (numer As String, denom As String, quotient As String, remainder As String)
    Dim n As String, d As String, q As String, rrun As String
    Dim i As Long, digit As Integer

    n = StripZeros$(numer)
    d = StripZeros$(denom)
    q = ""
    rrun = "0" '  running remainder as we sweep left to right

    For i = 1 To Len(n)
        ' bring down the next dividend digit: run = run*10 + digit
        rrun = StripZeros$(rrun + Mid$(n, i, 1))
        digit = 0
        Do While CompareBig%(rrun, d) >= 0
            rrun = SubStrings$(rrun, d)
            digit = digit + 1
        Loop
        q = q + Chr$(48 + digit)
    Next i

    quotient = StripZeros$(q)
    remainder = rrun
End Sub

' Add an Include metacommand for ButtonUI.bm HERE at the bottom.
'$Include:'ButtonUI.bm'
