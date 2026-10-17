' ============================================================
'  Enigma-Like Cipher - QB64PE 256-Symbol Edition
'  GUI build: immediate-mode buttons via ButtonUI
'
'  Requires ButtonUI.bi (included at top) and ButtonUI.bm
'  (included at bottom) in the same folder as this .bas.
'
'  All 256 byte values are in the alphabet, so ANY file
'  round-trips byte-for-byte. No sanitizing, no text/binary
'  distinction.
' ============================================================
Option _Explicit

Const MAXMSG = 1048576 ' 1 MB cap on message length (typed or loaded)
Const NSYM = 256
Const HEXROWS = 7
Const HEXCOLS = 16

'$Include: 'ButtonUI.bi'

' ------------------------------------------------------------
'  Cipher globals - wheels are index tables, not strings
' ------------------------------------------------------------
Dim Shared r1(255) As Integer, r2(255) As Integer, r3(255) As Integer
Dim Shared i1(255) As Integer, i2(255) As Integer, i3(255) As Integer
Dim Shared rf(255) As Integer
Dim Shared prngState As _Integer64

Dim Shared rotorPos(2) As Integer
Dim Shared initPos(2) As Integer

' ------------------------------------------------------------
'  UI palette
' ------------------------------------------------------------
Dim Shared cBack As _Unsigned Long
Dim Shared cPanel As _Unsigned Long
Dim Shared cEdge As _Unsigned Long
Dim Shared cTitle As _Unsigned Long
Dim Shared cLabel As _Unsigned Long
Dim Shared cValue As _Unsigned Long
Dim Shared cField As _Unsigned Long
Dim Shared cCipher As _Unsigned Long
Dim Shared cDim As _Unsigned Long

cBack = _RGB32(24, 28, 38)
cPanel = _RGB32(38, 44, 58)
cEdge = _RGB32(90, 102, 126)
cTitle = _RGB32(255, 214, 102)
cLabel = _RGB32(176, 186, 204)
cValue = _RGB32(126, 230, 160)
cField = _RGB32(16, 20, 28)
cCipher = _RGB32(126, 230, 160)
cDim = _RGB32(112, 120, 136)

BuildWheels

' ------------------------------------------------------------
'  Program state
' ------------------------------------------------------------
Dim msgIn As String
Dim msgOut As String
Dim statusLine As String
Dim charCount As Long
Dim dumpTop As Long

Dim iLoop As Integer
Dim yy As Integer
Dim vs As String
Dim kk As String
Dim caret As Integer
Dim fieldCols As Integer
Dim shown As String
Dim hasIn As Integer
Dim hasOut As Integer
Dim pathName As String
Dim rawText As String
Dim truncated As Integer
Dim hexBlob As String

msgIn = ""
msgOut = ""
statusLine = "Ready. Type a message or load any file, then press Process."
charCount = 0
dumpTop = 0

Randomize Timer

_Title "Enigma Cipher 256 - QB64PE"
Screen _NewImage(900, 660, 32)
$ExeIcon:'./icon\icon.ico'
_PrintMode _KeepBackground
MouseInit

fieldCols = 828 \ 8

Do
    _Limit 60
    PollMouse

    ' ---- keyboard into the message field ----
    Do
        kk = InKey$
        If kk = "" Then Exit Do
        If kk = Chr$(27) Then System
        If kk = Chr$(8) Then
            If Len(msgIn) > 0 Then msgIn = Left$(msgIn, Len(msgIn) - 1)
        ElseIf kk = Chr$(13) Then
            If Len(msgIn) > 0 Then
                msgOut = RunCipher$(msgIn)
                charCount = Len(msgIn)
                dumpTop = 0
                statusLine = "Processed" + Str$(charCount) + " bytes."
            End If
        ElseIf Len(kk) = 1 Then
            If Asc(kk) >= 32 And Asc(kk) <= 126 And Len(msgIn) < MAXMSG Then
                msgIn = msgIn + kk
            End If
        End If
    Loop

    hasIn = 0: If Len(msgIn) > 0 Then hasIn = -1
    hasOut = 0: If Len(msgOut) > 0 Then hasOut = -1

    Cls , cBack

    ' ---- header ----
    Line (0, 0)-(899, 56), _RGB32(30, 36, 50), BF
    Line (0, 56)-(899, 57), cEdge, BF
    PText 292, 12, "E N I G M A   C I P H E R", cTitle
    PText 316, 32, "256-Symbol Byte-Exact Edition", cDim

    ' ---- rotor panel ----
    DrawPanel 20, 70, 420, 120, "ROTOR START POSITIONS  (0-255)"

    For iLoop = 0 To 2
        yy = 100 + iLoop * 30

        PText 36, yy + 4, "Rotor" + Str$(iLoop + 1) + ":", cLabel

        Line (140, yy)-(200, yy + 24), cField, BF
        Line (140, yy)-(200, yy + 24), cEdge, B
        vs = LTrim$(Str$(initPos(iLoop)))
        PText 170 - 4 * Len(vs), yy + 4, vs, cValue

        If Button%(210, yy, 40, 24, "-16") Then
            initPos(iLoop) = (initPos(iLoop) + 240) And 255
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If
        If Button%(254, yy, 32, 24, "-") Then
            initPos(iLoop) = (initPos(iLoop) + 255) And 255
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If
        If Button%(290, yy, 32, 24, "+") Then
            initPos(iLoop) = (initPos(iLoop) + 1) And 255
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If
        If Button%(326, yy, 40, 24, "+16") Then
            initPos(iLoop) = (initPos(iLoop) + 16) And 255
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If
    Next iLoop

    ' ---- session panel ----
    DrawPanel 460, 70, 420, 120, "SESSION"
    PText 476, 100, "Key   : [" + LTrim$(Str$(initPos(0))) + " | " + LTrim$(Str$(initPos(1))) + " | " + LTrim$(Str$(initPos(2))) + "]", cLabel
    PText 476, 120, "Live  : [" + LTrim$(Str$(rotorPos(0))) + " | " + LTrim$(Str$(rotorPos(1))) + " | " + LTrim$(Str$(rotorPos(2))) + "]", cLabel
    PText 476, 140, "Bytes :" + Str$(charCount), cLabel
    PText 476, 165, "Symmetric - same key decrypts. Any file type.", cDim

    ' ---- input panel ----
    DrawPanel 20, 205, 860, 95, "MESSAGE  (typing goes straight into this field)"
    Line (36, 240)-(864, 280), cField, BF
    Line (36, 240)-(864, 280), cEdge, B

    If Len(msgIn) > fieldCols - 1 Then
        shown = Right$(msgIn, fieldCols - 1)
    Else
        shown = msgIn
    End If
    shown = Printable$(shown)
    caret = 0
    If Int(Timer * 2) Mod 2 = 0 Then caret = -1
    PText 42, 252, shown, _RGB32(238, 240, 248)
    If caret Then PText 42 + 8 * Len(shown), 252, "_", cTitle

    ' ---- action buttons ----
    If ButtonEx%(20, 310, 150, 34, "Process", hasIn) Then
        msgOut = RunCipher$(msgIn)
        charCount = Len(msgIn)
        dumpTop = 0
        statusLine = "Processed" + Str$(charCount) + " bytes."
    End If

    If ButtonEx%(180, 310, 160, 34, "Out -> In", hasOut) Then
        msgIn = msgOut
        msgOut = ""
        dumpTop = 0
        statusLine = "Output moved to input - press Process to round-trip it."
    End If

    If ButtonEx%(350, 310, 140, 34, "Copy Hex", hasOut) Then
        hexBlob = ToHex$(msgOut, 32768)
        _Clipboard$ = hexBlob
        If Len(msgOut) > 32768 Then
            statusLine = "Copied first 32768 bytes as hex (output is binary)."
        Else
            statusLine = "Output copied to the clipboard as hex."
        End If
    End If

    If Button%(500, 310, 110, 34, "Clear") Then
        msgIn = ""
        msgOut = ""
        charCount = 0
        dumpTop = 0
        statusLine = "Cleared."
    End If

    If Button%(620, 310, 170, 34, "Reset Rotors") Then
        initPos(0) = 0: initPos(1) = 0: initPos(2) = 0
        rotorPos(0) = 0: rotorPos(1) = 0: rotorPos(2) = 0
        statusLine = "Rotor key reset to [0 | 0 | 0]."
    End If

    If Button%(800, 310, 80, 34, "Quit") Then System

    ' ---- file buttons ----
    If Button%(20, 352, 150, 34, "Load File") Then
        pathName = _OpenFileDialog$("Open any file", "", "*.*", "All files")
        If pathName <> "" Then
            rawText = LoadBinaryFile$(pathName)
            If Len(rawText) = 0 Then
                statusLine = "That file is empty or could not be read."
            Else
                msgIn = rawText
                truncated = 0
                If Len(msgIn) > MAXMSG Then
                    msgIn = Left$(msgIn, MAXMSG)
                    truncated = -1
                End If
                msgOut = ""
                charCount = 0
                dumpTop = 0
                If truncated Then
                    statusLine = "Loaded and truncated to" + Str$(MAXMSG) + " bytes."
                Else
                    statusLine = "Loaded" + Str$(Len(msgIn)) + " bytes."
                End If
            End If
        Else
            statusLine = "Load cancelled."
        End If
    End If

    If ButtonEx%(180, 352, 160, 34, "Save Input", hasIn) Then
        pathName = _SaveFileDialog$("Save the input bytes", "input.bin", "*.*", "All files")
        If pathName <> "" Then
            SaveBinaryFile pathName, msgIn
            statusLine = "Input saved -" + Str$(Len(msgIn)) + " bytes."
        Else
            statusLine = "Save cancelled."
        End If
    End If

    If ButtonEx%(350, 352, 170, 34, "Save Output", hasOut) Then
        pathName = _SaveFileDialog$("Save the cipher output", "output.bin", "*.*", "All files")
        If pathName <> "" Then
            SaveBinaryFile pathName, msgOut
            statusLine = "Output saved -" + Str$(Len(msgOut)) + " bytes."
        Else
            statusLine = "Save cancelled."
        End If
    End If

    If Button%(530, 352, 160, 34, "Random Key") Then
        initPos(0) = Int(Rnd * 256)
        initPos(1) = Int(Rnd * 256)
        initPos(2) = Int(Rnd * 256)
        statusLine = "Random key [" + LTrim$(Str$(initPos(0))) + " | " + LTrim$(Str$(initPos(1))) + " | " + LTrim$(Str$(initPos(2))) + "] - write it down."
    End If

    ' ---- output panel ----
    DrawPanel 20, 398, 860, 210, "OUTPUT  (hex dump)"
    Line (36, 430)-(864, 570), cField, BF
    Line (36, 430)-(864, 570), cEdge, B
    DrawHexDump 42, 438, HEXROWS, dumpTop, msgOut, cCipher

    If ButtonEx%(36, 576, 90, 26, "< Prev", hasOut) Then
        dumpTop = dumpTop - HEXROWS * HEXCOLS
        If dumpTop < 0 Then dumpTop = 0
    End If
    If ButtonEx%(132, 576, 90, 26, "Next >", hasOut) Then
        If dumpTop + HEXROWS * HEXCOLS < Len(msgOut) Then dumpTop = dumpTop + HEXROWS * HEXCOLS
    End If
    If ButtonEx%(228, 576, 70, 26, "Top", hasOut) Then dumpTop = 0

    If hasOut Then
        PText 312, 583, "showing" + Str$(dumpTop) + " -" + Str$(dumpTop + HEXROWS * HEXCOLS - 1) + " of" + Str$(Len(msgOut)) + " bytes", cDim
    End If

    ' ---- status bar ----
    Line (0, 628)-(899, 659), _RGB32(30, 36, 50), BF
    Line (0, 628)-(899, 628), cEdge, BF
    PText 12, 636, statusLine, cLabel
    PText 700, 636, "Esc = quit", cDim

    _Display
Loop

' ============================================================
'  UI HELPERS
' ============================================================
Sub PText (x As Integer, y As Integer, s As String, c As _Unsigned Long)
    Color c
    _PrintMode _KeepBackground
    _PrintString (x, y), s
End Sub

Sub DrawPanel (x As Integer, y As Integer, w As Integer, h As Integer, ttl As String)
    Line (x, y)-(x + w, y + h), cPanel, BF
    Line (x, y)-(x + w, y + h), cEdge, B
    Line (x + 1, y + 1)-(x + w - 1, y + 22), _RGB32(48, 56, 72), BF
    PText x + 10, y + 4, ttl, cTitle
End Sub

Sub DrawHexDump (x As Integer, y As Integer, rws As Integer, topOff As Long, s As String, c As _Unsigned Long)
    Dim rr As Integer
    Dim i As Integer
    Dim b As Integer
    Dim bbase As Long
    Dim ln As String
    Dim txt As String

    If Len(s) = 0 Then
        PText x, y, "(no output yet)", cDim
        Exit Sub
    End If

    For rr = 0 To rws - 1
        bbase = topOff + rr * 16
        If bbase >= Len(s) Then Exit For
        ln = Hex8$(bbase) + "  "
        txt = ""
        For i = 0 To 15
            If bbase + i < Len(s) Then
                b = Asc(s, bbase + i + 1)
                ln = ln + Hex2$(b) + " "
                If b >= 32 And b <= 126 Then
                    txt = txt + Chr$(b)
                Else
                    txt = txt + "."
                End If
            Else
                ln = ln + "   "
                txt = txt + " "
            End If
        Next i
        PText x, y + rr * 20, ln + " |" + txt + "|", c
    Next rr
End Sub

Function Hex2$ (b As Integer)
    Dim h As String
    h = Hex$(b)
    If Len(h) < 2 Then h = "0" + h
    Hex2$ = h
End Function

Function Hex8$ (v As Long)
    Dim h As String
    h = Hex$(v)
    Do While Len(h) < 8
        h = "0" + h
    Loop
    Hex8$ = h
End Function

Function ToHex$ (s As String, maxBytes As Long)
    Dim n As Long
    Dim i As Long
    Dim acc As String

    n = Len(s)
    If n > maxBytes Then n = maxBytes
    acc = Space$(n * 2)
    For i = 1 To n
        Mid$(acc, i * 2 - 1, 2) = Hex2$(Asc(s, i))
    Next i
    ToHex$ = acc
End Function

' Replace non-printable bytes with '.' so a binary buffer can be
' shown in the single-line input field without garbling the screen.
Function Printable$ (s As String)
    Dim i As Long
    Dim b As Integer
    Dim acc As String

    acc = Space$(Len(s))
    For i = 1 To Len(s)
        b = Asc(s, i)
        If b >= 32 And b <= 126 Then
            Mid$(acc, i, 1) = Chr$(b)
        Else
            Mid$(acc, i, 1) = "."
        End If
    Next i
    Printable$ = acc
End Function

' ============================================================
'  FILE I/O - binary, byte-exact, no translation
' ============================================================
Function LoadBinaryFile$ (pathName As String)
    Dim fh As Integer
    Dim buf As String
    Dim sz As Long

    LoadBinaryFile$ = ""
    If _FileExists(pathName) = 0 Then Exit Function

    fh = FreeFile
    Open pathName For Binary As #fh
    sz = LOF(fh)
    If sz > MAXMSG Then sz = MAXMSG
    If sz > 0 Then
        buf = Space$(sz)
        Get #fh, 1, buf
    End If
    Close #fh

    LoadBinaryFile$ = buf
End Function

Sub SaveBinaryFile (pathName As String, s As String)
    Dim fh As Integer

    ' Binary mode does not truncate, so remove any old file first.
    If _FileExists(pathName) Then Kill pathName

    fh = FreeFile
    Open pathName For Binary As #fh
    If Len(s) > 0 Then Put #fh, 1, s
    Close #fh
End Sub

' ============================================================
'  WHEEL CONSTRUCTION
'  Deterministic LCG so the wiring is identical on every run
'  and every machine - do NOT swap this for RND.
' ============================================================
Sub BuildWheels
    prngState = 1234567

    MakeRotor r1(), i1()
    MakeRotor r2(), i2()
    MakeRotor r3(), i3()
    MakeReflector rf()
End Sub

Function NextRand& (n As Long)
    prngState = (prngState * 1103515245 + 12345) Mod 2147483648
    NextRand& = (prngState \ 65536) Mod n
End Function

Sub MakeRotor (fwd() As Integer, inv() As Integer)
    Dim k As Integer
    Dim j As Integer
    Dim tmp As Integer

    For k = 0 To 255
        fwd(k) = k
    Next k

    ' Fisher-Yates
    For k = 255 To 1 Step -1
        j = NextRand&(k + 1)
        tmp = fwd(k): fwd(k) = fwd(j): fwd(j) = tmp
    Next k

    For k = 0 To 255
        inv(fwd(k)) = k
    Next k
End Sub

' 128 disjoint pairs - a true fixed-point-free involution, which
' the old 37-symbol alphabet could not express.
Sub MakeReflector (rfl() As Integer)
    Dim pool(255) As Integer
    Dim k As Integer
    Dim j As Integer
    Dim tmp As Integer

    For k = 0 To 255
        pool(k) = k
    Next k

    For k = 255 To 1 Step -1
        j = NextRand&(k + 1)
        tmp = pool(k): pool(k) = pool(j): pool(j) = tmp
    Next k

    For k = 0 To 254 Step 2
        rfl(pool(k)) = pool(k + 1)
        rfl(pool(k + 1)) = pool(k)
    Next k
End Sub

' ============================================================
'  CIPHER
' ============================================================
Function RunCipher$ (src As String)
    Dim i As Long
    Dim acc As String

    ' Enigma is symmetric: always start from the saved key.
    rotorPos(0) = initPos(0)
    rotorPos(1) = initPos(1)
    rotorPos(2) = initPos(2)

    acc = Space$(Len(src))
    For i = 1 To Len(src)
        Mid$(acc, i, 1) = Chr$(EncByte%(Asc(src, i)))
    Next i

    RunCipher$ = acc
End Function

Function EncByte% (b As Integer)
    Dim x As Integer

    ' Step rotors (rotor 0 always steps; carry to 1 and 2)
    rotorPos(0) = (rotorPos(0) + 1) And 255
    If rotorPos(0) = 0 Then
        rotorPos(1) = (rotorPos(1) + 1) And 255
        If rotorPos(1) = 0 Then
            rotorPos(2) = (rotorPos(2) + 1) And 255
        End If
    End If

    x = b

    ' Forward pass
    x = (r1((x + rotorPos(0)) And 255) - rotorPos(0)) And 255
    x = (r2((x + rotorPos(1)) And 255) - rotorPos(1)) And 255
    x = (r3((x + rotorPos(2)) And 255) - rotorPos(2)) And 255

    ' Reflector
    x = rf(x)

    ' Reverse pass through the inverse tables
    x = (i3((x + rotorPos(2)) And 255) - rotorPos(2)) And 255
    x = (i2((x + rotorPos(1)) And 255) - rotorPos(1)) And 255
    x = (i1((x + rotorPos(0)) And 255) - rotorPos(0)) And 255

    EncByte% = x
End Function

'$Include: 'ButtonUI.bm'
