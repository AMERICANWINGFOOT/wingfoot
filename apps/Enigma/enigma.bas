' ============================================================
'  Enigma-Like Cipher - QB64PE Enhanced Edition
'  GUI build: immediate-mode buttons via ButtonUI
'
'  Requires ButtonUI.bi (top) and ButtonUI.bm (bottom) in the
'  same folder as this .bas.
' ============================================================
Option _Explicit

Const MAXMSG = 6553600 ' hard cap on message length (typed or loaded)

'$Include: 'ButtonUI.bi'

' ------------------------------------------------------------
'  Cipher globals
' ------------------------------------------------------------
Dim Shared alphabet$
Dim Shared r1$, r2$, r3$, rf$
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

alphabet$ = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 "
r1$ = "BDFHJLCPRTXVZNYEIWGAKMUSQO1234567890 "
r2$ = "AJDKSIRUXBLHWTMCQGZNPYFVOE9876543210 "
r3$ = "EKMFLGDQVZNTOWYHXUSPAIBRCJ5647382910 "
rf$ = "YRUHQSLDPXNGOKMIEBFZCWVJAT0123456789 "

cBack = _RGB32(24, 28, 38)
cPanel = _RGB32(38, 44, 58)
cEdge = _RGB32(90, 102, 126)
cTitle = _RGB32(255, 214, 102)
cLabel = _RGB32(176, 186, 204)
cValue = _RGB32(126, 230, 160)
cField = _RGB32(16, 20, 28)
cCipher = _RGB32(126, 230, 160)
cDim = _RGB32(112, 120, 136)

' ------------------------------------------------------------
'  Program state
' ------------------------------------------------------------
Dim msgIn As String
Dim msgOut As String
Dim statusLine As String
Dim charCount As Integer

Dim iLoop As Integer
Dim yy As Integer
Dim vs As String
Dim kk As String
Dim caret As Integer
Dim fieldCols As Integer
Dim outCols As Integer
Dim shown As String
Dim hasIn As Integer
Dim hasOut As Integer
Dim pathName As String
Dim rawText As String
Dim truncated As Integer

msgIn = ""
msgOut = ""
statusLine = "Ready. Type your message, then press Process (or Enter)."
charCount = 0

_Title "Enigma Cipher - QB64PE"
Screen _NewImage(900, 660, 32)
$ExeIcon:'./icon\icon.ico'
_PrintMode _KeepBackground
MouseInit

fieldCols = 828 \ 8
outCols = 828 \ 8

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
                statusLine = "Processed" + Str$(charCount) + " characters."
            End If
        ElseIf Len(kk) = 1 Then
            If Asc(kk) >= 32 And Asc(kk) <= 126 And Len(msgIn) < MAXMSG Then
                msgIn = msgIn + UCase$(kk)
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
    PText 330, 32, "QB64PE Enhanced Edition", cDim

    ' ---- rotor panel ----
    DrawPanel 20, 70, 420, 120, "ROTOR START POSITIONS"

    For iLoop = 0 To 2
        yy = 108 + iLoop * 30

        PText 36, yy + 4, "Rotor" + Str$(iLoop + 1) + ":", cLabel

        Line (140, yy)-(200, yy + 24), cField, BF
        Line (140, yy)-(200, yy + 24), cEdge, B
        vs = LTrim$(Str$(initPos(iLoop)))
        PText 170 - 4 * Len(vs), yy + 4, vs, cValue

        If Button%(212, yy, 30, 24, "-") Then
            initPos(iLoop) = (initPos(iLoop) + 36) Mod 37
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If
        If Button%(248, yy, 30, 24, "+") Then
            initPos(iLoop) = (initPos(iLoop) + 1) Mod 37
            statusLine = "Rotor" + Str$(iLoop + 1) + " start set to" + Str$(initPos(iLoop)) + "."
        End If

        PText 292, yy + 4, "now:" + Str$(rotorPos(iLoop)), cDim
    Next iLoop

    ' ---- session panel ----
    DrawPanel 460, 70, 420, 120, "SESSION"
    PText 476, 108, "Key    : [" + LTrim$(Str$(initPos(0))) + " | " + LTrim$(Str$(initPos(1))) + " | " + LTrim$(Str$(initPos(2))) + "]", cLabel
    PText 476, 128, "Live   : [" + LTrim$(Str$(rotorPos(0))) + " | " + LTrim$(Str$(rotorPos(1))) + " | " + LTrim$(Str$(rotorPos(2))) + "]", cLabel
    PText 476, 148, "Chars  :" + Str$(charCount), cLabel
    PText 476, 168, "Enigma is symmetric - same key decrypts.", cDim

    ' ---- input panel ----
    DrawPanel 20, 205, 860, 95, "MESSAGE  (typing goes straight into this field)"
    Line (36, 240)-(864, 280), cField, BF
    Line (36, 240)-(864, 280), cEdge, B

    If Len(msgIn) > fieldCols - 1 Then
        shown = Right$(msgIn, fieldCols - 1)
    Else
        shown = msgIn
    End If
    caret = 0
    If Int(Timer * 2) Mod 2 = 0 Then caret = -1
    PText 42, 252, shown, _RGB32(238, 240, 248)
    If caret Then PText 42 + 8 * Len(shown), 252, "_", cTitle

    ' ---- action buttons ----
    If ButtonEx%(20, 310, 150, 34, "Process", hasIn) Then
        msgOut = RunCipher$(msgIn)
        charCount = Len(msgIn)
        statusLine = "Processed" + Str$(charCount) + " characters."
    End If

    If ButtonEx%(180, 310, 160, 34, "Out -> In", hasOut) Then
        msgIn = msgOut
        msgOut = ""
        statusLine = "Output moved to input - press Process to round-trip it."
    End If

    If ButtonEx%(350, 310, 140, 34, "Copy Out", hasOut) Then
        _Clipboard$ = msgOut
        statusLine = "Output copied to the clipboard."
    End If

    If Button%(500, 310, 110, 34, "Clear") Then
        msgIn = ""
        msgOut = ""
        charCount = 0
        statusLine = "Cleared."
    End If

    If Button%(620, 310, 170, 34, "Reset Rotors") Then
        initPos(0) = 0: initPos(1) = 0: initPos(2) = 0
        rotorPos(0) = 0: rotorPos(1) = 0: rotorPos(2) = 0
        statusLine = "Rotor key reset to [0 | 0 | 0]."
    End If

    If Button%(800, 310, 80, 34, "Quit") Then System

    ' ---- file buttons ----
    If Button%(20, 352, 150, 34, "Load .txt") Then
        pathName = _OpenFileDialog$("Open a text file", "", "*.txt|*.bas|*.*", "Text files")
        If pathName <> "" Then
            rawText = LoadTextFile$(pathName)
            If Len(rawText) = 0 Then
                statusLine = "That file is empty or could not be read."
            Else
                msgIn = SanitizeText$(rawText)
                truncated = 0
                If Len(msgIn) > MAXMSG Then
                    msgIn = Left$(msgIn, MAXMSG)
                    truncated = -1
                End If
                msgOut = ""
                charCount = 0
                If truncated Then
                    statusLine = "Loaded and truncated to" + Str$(MAXMSG) + " characters."
                Else
                    statusLine = "Loaded" + Str$(Len(msgIn)) + " usable characters."
                End If
            End If
        Else
            statusLine = "Load cancelled."
        End If
    End If

    If ButtonEx%(180, 352, 160, 34, "Save Input", hasIn) Then
        pathName = _SaveFileDialog$("Save the input text", "input.txt", "*.txt|*.*", "Text files")
        If pathName <> "" Then
            SaveTextFile pathName, msgIn
            statusLine = "Input saved."
        Else
            statusLine = "Save cancelled."
        End If
    End If

    If ButtonEx%(350, 352, 170, 34, "Save Output", hasOut) Then
        pathName = _SaveFileDialog$("Save the cipher output", "output.txt", "*.txt|*.*", "Text files")
        If pathName <> "" Then
            SaveTextFile pathName, msgOut
            statusLine = "Output saved."
        Else
            statusLine = "Save cancelled."
        End If
    End If

    ' ---- output panel ----
    DrawPanel 20, 398, 860, 210, "OUTPUT"
    Line (36, 430)-(864, 594), cField, BF
    Line (36, 430)-(864, 594), cEdge, B
    DrawWrapped 42, 438, outCols, 7, msgOut, cCipher

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

Sub DrawWrapped (x As Integer, y As Integer, cols As Integer, maxLines As Integer, s As String, c As _Unsigned Long)
    Dim lineNo As Integer
    Dim p As Long

    lineNo = 0
    p = 1
    Do While p <= Len(s) And lineNo < maxLines
        PText x, y + lineNo * 20, Mid$(s, p, cols), c
        p = p + cols
        lineNo = lineNo + 1
    Loop

    If p <= Len(s) Then
        PText x, y + maxLines * 20, "... (" + LTrim$(Str$(Len(s) - p + 1)) + " more characters)", cDim
    End If
End Sub

' ============================================================
'  FILE I/O
' ============================================================
Function LoadTextFile$ (pathName As String)
    Dim fh As Integer
    Dim buf As String
    Dim sz As Long

    LoadTextFile$ = ""
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

    LoadTextFile$ = buf
End Function

Sub SaveTextFile (pathName As String, s As String)
    Dim fh As Integer

    fh = FreeFile
    Open pathName For Output As #fh
    Print #fh, s
    Close #fh
End Sub

' Fold a raw file down to what the 37-character rotor alphabet can
' actually carry: CRLF/LF/TAB become a single space, other control
' bytes are dropped, everything else is uppercased.
Function SanitizeText$ (s As String)
    Dim i As Long
    Dim c As Integer
    Dim acc As String

    acc = ""
    i = 1
    Do While i <= Len(s)
        c = Asc(Mid$(s, i, 1))
        If c = 13 Then
            acc = acc + " "
            If i < Len(s) Then
                If Asc(Mid$(s, i + 1, 1)) = 10 Then i = i + 1
            End If
        ElseIf c = 10 Or c = 9 Then
            acc = acc + " "
        ElseIf c >= 32 And c <= 126 Then
            acc = acc + Chr$(c)
        End If
        i = i + 1
    Loop

    SanitizeText$ = UCase$(acc)
End Function

' ============================================================
'  CIPHER
' ============================================================
Function RunCipher$ (src As String)
    Dim i As _Unsigned Integer
    Dim ch1 As String
    Dim acc As String

    ' Enigma is symmetric: always start from the saved key.
    rotorPos(0) = initPos(0)
    rotorPos(1) = initPos(1)
    rotorPos(2) = initPos(2)

    acc = ""
    For i = 1 To Len(src)
        ch1 = Mid$(src, i, 1)
        acc = acc + EncryptCharacter$(ch1)
    Next i

    RunCipher$ = acc
End Function

Function EncryptCharacter$ (ch As String)
    Dim idx As Integer

    idx = InStr(alphabet$, ch) - 1
    If idx < 0 Then EncryptCharacter$ = ch: Exit Function

    ' Step rotors (rotor 0 always steps; carry to 1 and 2)
    rotorPos(0) = (rotorPos(0) + 1) Mod 37
    If rotorPos(0) = 0 Then
        rotorPos(1) = (rotorPos(1) + 1) Mod 37
        If rotorPos(1) = 0 Then
            rotorPos(2) = (rotorPos(2) + 1) Mod 37
        End If
    End If

    ' Forward pass through rotors
    idx = (InStr(alphabet$, Mid$(r1$, (idx + rotorPos(0)) Mod 37 + 1, 1)) - 1 - rotorPos(0) + 37) Mod 37
    idx = (InStr(alphabet$, Mid$(r2$, (idx + rotorPos(1)) Mod 37 + 1, 1)) - 1 - rotorPos(1) + 37) Mod 37
    idx = (InStr(alphabet$, Mid$(r3$, (idx + rotorPos(2)) Mod 37 + 1, 1)) - 1 - rotorPos(2) + 37) Mod 37

    ' Reflector
    idx = InStr(alphabet$, Mid$(rf$, idx + 1, 1)) - 1

    ' Reverse pass through rotors
    idx = (InStr(r3$, Mid$(alphabet$, (idx + rotorPos(2)) Mod 37 + 1, 1)) - 1 - rotorPos(2) + 37) Mod 37
    idx = (InStr(r2$, Mid$(alphabet$, (idx + rotorPos(1)) Mod 37 + 1, 1)) - 1 - rotorPos(1) + 37) Mod 37
    idx = (InStr(r1$, Mid$(alphabet$, (idx + rotorPos(0)) Mod 37 + 1, 1)) - 1 - rotorPos(0) + 37) Mod 37

    EncryptCharacter$ = Mid$(alphabet$, idx + 1, 1)
End Function

'$Include: 'ButtonUI.bm'
