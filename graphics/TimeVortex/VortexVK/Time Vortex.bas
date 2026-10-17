'=======================================================================
'  TimeVortex.bas  --  Audio-reactive time-vortex tunnel visualizer
'  QB64-PE 4.5 / 4.6 (Linux or Windows)
'
'  Plays an audio file (MP3/OGG/WAV/FLAC) and flies you down a twisting
'  tunnel that pulses with the music. The decoded samples are read with
'  _MemSound, a Hann-windowed 1024-sample slice is taken around the play
'  cursor every frame, and 16 log-spaced Goertzel filters (60 Hz-8 kHz)
'  give the band levels that drive the rings, arms, stars and glow.
'
'  Usage:  just run it -- "Doctor Who - 1980.mp3" in the same folder
'          starts playing immediately. Or: ./TimeVortex "other song.mp3"
'          If neither is found, a file picker opens.
'
'  Keys:   SPACE pause/resume   LEFT/RIGHT seek 5s   F fullscreen
'          H hide/show HUD      ESC quit
'=======================================================================
Option _Explicit

Const SW = 1024, SH = 768
Const NRING = 36, NSEG = 56, NARM = 6
Const NSTAR = 260
Const NWIN = 1024, NBAND = 16
Const DMAX = 24, DMIN = 0.6
Const FOCAL = 260
Const PI2 = 6.2831853
Const DEFAULT_SONG = "Doctor Who - 1980.mp3"

'--- audio state (shared with the analysis routines) -------------------
Dim Shared snd As Long
Dim Shared mm As _MEM
Dim Shared haveMem As Long, nch As Long, bps As Long, isFloat As Long
Dim Shared totalFrames As _Integer64
Dim Shared srate As Single
Dim Shared bandF(NBAND - 1) As Single
Dim Shared bandV(NBAND - 1) As Single
Dim Shared bandP(NBAND - 1) As Single
Dim Shared hann(NWIN - 1) As Single
Dim Shared xs(NWIN - 1) As Single
Dim Shared level As Single, bass As Single, mids As Single, treb As Single
Dim Shared tt As Single

'--- scene state ---------------------------------------------------------
Dim ringD(NRING - 1) As Single
Dim stX(NSTAR - 1) As Single, stY(NSTAR - 1) As Single, stZ(NSTAR - 1) As Single

Dim fileName As String
Dim i As Long, s As Long, k As Long, j As Long, kh As Long
Dim d As Single, r As Single, rr As Single, a As Single, f As Single
Dim cx As Single, cy As Single, px As Single, py As Single, lx As Single, ly As Single
Dim mix As Single, cr As Single, cg As Single, cb As Single, al As Single
Dim spd As Single, twist As Single
Dim bassAvg As Single, flash As Single, flashCool As Long
Dim paused As Long, showHud As Long, frameCount As Long
Dim fr As _Integer64
Dim np As Double, songLen As Double
Dim z0 As Single, x0 As Single, y0 As Single, x1 As Single, y1 As Single
Dim bx As Long, bh As Long, glowR As Long
Dim tstr As String

Randomize Timer

'--- pick the file -------------------------------------------------------
' 1) a file named on the command line
' 2) the default song sitting next to the program (auto-plays at start-up)
' 3) otherwise ask with a file picker
fileName = Command$(1)
If fileName = "" Then
    If _FileExists(DEFAULT_SONG) Then fileName = DEFAULT_SONG
End If
If fileName = "" Then
    fileName = _OpenFileDialog$("Pick a song for the vortex", "", "*.mp3|*.ogg|*.wav|*.flac", "Audio files")
End If
If fileName = "" Then System
If Not _FileExists(fileName) Then
    Print "Can't find: "; fileName
    Sleep
    System
End If

snd = _SndOpen(fileName)
If snd < 1 Then
    Print "Couldn't open audio: "; fileName
    Sleep
    System
End If

srate = _SndRate
songLen = _SndLen(snd)

'--- get at the decoded samples ------------------------------------------
mm = _MemSound(snd, 0)
If mm.SIZE > 0 Then
    haveMem = -1
    bps = mm.TYPE And 15
    isFloat = ((mm.TYPE And 256) <> 0)
    If bps < 1 Then bps = 2
    nch = mm.ELEMENTSIZE \ bps
    If nch < 1 Then nch = 1
    totalFrames = mm.SIZE \ mm.ELEMENTSIZE
End If

For i = 0 To NWIN - 1
    hann(i) = 0.5 - 0.5 * Cos(PI2 * i / (NWIN - 1))
Next
For i = 0 To NBAND - 1
    bandF(i) = 60 * (8000 / 60) ^ (i / (NBAND - 1))
Next

'--- scene init ----------------------------------------------------------
For i = 0 To NRING - 1
    ringD(i) = DMIN + i * (DMAX - DMIN) / NRING
Next
For i = 0 To NSTAR - 1
    stX(i) = (Rnd * 2 - 1) * 3
    stY(i) = (Rnd * 2 - 1) * 3
    stZ(i) = DMIN + Rnd * DMAX
Next

Screen _NewImage(SW, SH, 32)
_Title "Time Vortex"
_ScreenMove _Middle
Cls , _RGB32(0, 0, 8)
_PrintMode _KeepBackground

showHud = -1
_SndPlay snd

'=======================================================================
Do
    _Limit 60
    frameCount = frameCount + 1
    tt = tt + 1 / 60

    '--- input ---------------------------------------------------------
    kh = _KeyHit
    Select Case kh
        Case 27
            Exit Do
        Case 32
            If paused Then
                _SndPlay snd
                paused = 0
            Else
                _SndPause snd
                paused = -1
            End If
        Case 19200, 19712
            np = _SndGetPos(snd)
            If kh = 19200 Then np = np - 5 Else np = np + 5
            np = _Clamp(np, 0, songLen - 0.5)
            _SndSetPos snd, np
        Case 70, 102
            If _FullScreen = 0 Then
                _FullScreen _SquarePixels , _Smooth
            Else
                _FullScreen _Off
            End If
        Case 72, 104
            showHud = Not showHud
    End Select

    ' loop the song when it finishes
    If Not paused And frameCount > 30 Then
        If Not _SndPlaying(snd) Then _SndPlay snd
    End If

    '--- analysis ------------------------------------------------------
    If haveMem Then
        If paused Then
            For i = 0 To NBAND - 1: bandV(i) = bandV(i) * 0.95: Next
            level = level * 0.95
        Else
            fr = Int(_SndGetPos(snd) * srate)
            Analyze fr
        End If
    Else
        FakeBands
    End If

    bass = (bandV(0) + bandV(1) + bandV(2) + bandV(3)) / 4
    mids = 0
    For i = 4 To 9: mids = mids + bandV(i): Next
    mids = mids / 6
    treb = 0
    For i = 10 To NBAND - 1: treb = treb + bandV(i): Next
    treb = treb / (NBAND - 10)

    ' crude beat detector: bass jumps above its own slow average
    bassAvg = bassAvg * 0.97 + bass * 0.03
    If flashCool > 0 Then flashCool = flashCool - 1
    If bass - bassAvg > 0.07 And flashCool = 0 Then
        flash = 1
        flashCool = 12
    End If
    flash = flash * 0.86

    spd = 0.03 + level * 0.5 + bass * 0.12 + flash * 0.08
    If paused Then spd = spd * 0.1
    twist = twist + 0.004 + treb * 0.025

    '--- fade previous frame for motion trails -------------------------
    Line (0, 0)-(SW - 1, SH - 1), _RGBA32(0, 0, 8, 64), BF

    '--- glow at the throat of the tunnel ------------------------------
    cx = VX(DMAX): cy = VY(DMAX)
    glowR = 14 + bass * 70 + flash * 40
    For i = glowR To 2 Step -3
        al = (1 - i / glowR) * 22 + 4
        Circle (cx, cy), i, _RGBA32(150 + flash * 100, 170 + flash * 80, 255, al)
    Next

    '--- stars streaming past ------------------------------------------
    For i = 0 To NSTAR - 1
        z0 = stZ(i)
        stZ(i) = stZ(i) - spd * 1.6
        If stZ(i) < 0.25 Then
            stX(i) = (Rnd * 2 - 1) * 3
            stY(i) = (Rnd * 2 - 1) * 3
            stZ(i) = DMAX
        Else
            x0 = VX(z0) + stX(i) / z0 * FOCAL
            y0 = VY(z0) + stY(i) / z0 * FOCAL
            x1 = VX(stZ(i)) + stX(i) / stZ(i) * FOCAL
            y1 = VY(stZ(i)) + stY(i) / stZ(i) * FOCAL
            f = 1 - stZ(i) / DMAX
            Line (x0, y0)-(x1, y1), _RGBA32(200, 220, 255, f * 230)
        End If
    Next

    '--- rings ---------------------------------------------------------
    For i = 0 To NRING - 1
        ringD(i) = ringD(i) - spd
        If ringD(i) < DMIN Then ringD(i) = ringD(i) + (DMAX - DMIN)
        d = ringD(i)
        r = FOCAL / d
        cx = VX(d): cy = VY(d)
        f = 1 - (d - DMIN) / (DMAX - DMIN)

        mix = bandV(i Mod NBAND)
        mix = _Clamp(mix * mix * 1.6, 0, 1)
        ' deep blue -> amber with energy, washed toward white on a beat
        cr = 25 + (255 - 25) * mix
        cg = 70 + (165 - 70) * mix
        cb = 255 + (55 - 255) * mix
        cr = cr + (255 - cr) * flash * 0.6
        cg = cg + (255 - cg) * flash * 0.6
        cb = cb + (255 - cb) * flash * 0.6
        al = f * f * 230

        For s = 0 To NSEG
            a = s * PI2 / NSEG
            rr = r * (1 + 0.11 * Sin(5 * a + tt * 1.7 + d * 0.5) * (0.35 + bass * 1.6))
            px = cx + Cos(a + d * 0.22 + twist) * rr
            py = cy + Sin(a + d * 0.22 + twist) * rr * 0.92
            If s > 0 Then Line (lx, ly)-(px, py), _RGBA32(cr, cg, cb, al)
            lx = px: ly = py
        Next
    Next

    '--- spiral arms twisting down the tunnel --------------------------
    For k = 0 To NARM - 1
        For j = 0 To 30
            d = DMIN + j * 0.75
            r = FOCAL / d
            a = k * PI2 / NARM + d * 0.37 + twist * 1.3 - tt * 0.4
            px = VX(d) + Cos(a) * r
            py = VY(d) + Sin(a) * r * 0.92
            f = 1 - (d - DMIN) / (DMAX - DMIN)
            If j > 0 Then Line (lx, ly)-(px, py), _RGBA32(255, 190, 90, f * (40 + mids * 200))
            lx = px: ly = py
        Next
    Next

    '--- HUD -----------------------------------------------------------
    If showHud Then
        ' spectrum
        For i = 0 To NBAND - 1
            bx = SW - NBAND * 14 - 20 + i * 14
            bh = bandV(i) * 70
            Line (bx, SH - 24 - bh)-(bx + 10, SH - 24), _RGBA32(90, 150, 255, 170), BF
            bh = bandP(i) * 70
            Line (bx, SH - 25 - bh)-(bx + 10, SH - 25 - bh), _RGB32(255, 200, 110)
        Next

        tstr = MinSec$(_SndGetPos(snd)) + " / " + MinSec$(songLen)
        If paused Then tstr = tstr + "   [paused]"
        If Not haveMem Then tstr = tstr + "   (no sample access - demo motion)"
        Color _RGB32(170, 185, 220)
        _PrintString (16, 16), tstr
        _PrintString (16, SH - 24), "SPACE pause   LEFT/RIGHT seek   F fullscreen   H hud   ESC quit"
    End If

    _Display
Loop

If haveMem Then _MemFree mm
_SndStop snd
_SndClose snd
System

'=======================================================================
'  Tunnel centre line: the far end wanders more than the near end,
'  which is what makes the tube look like it's bending.
'=======================================================================
Function VX! (d As Single)
    VX! = SW / 2 + Sin(tt * 0.6 + d * 0.18) * d * 7
End Function

Function VY! (d As Single)
    VY! = SH / 2 + Cos(tt * 0.45 + d * 0.15) * d * 5
End Function

'=======================================================================
'  Mono sample at a frame index, normalised to -1..1
'=======================================================================
Function MonoAt! (fr As _Integer64)
    Dim o As _Offset, c As Long, acc As Single
    If fr < 0 Or fr >= totalFrames Then
        MonoAt! = 0
        Exit Function
    End If
    o = mm.OFFSET + fr * mm.ELEMENTSIZE
    For c = 0 To nch - 1
        If isFloat Then
            acc = acc + _MemGet(mm, o + c * 4, Single)
        ElseIf bps = 2 Then
            acc = acc + _MemGet(mm, o + c * 2, Integer) / 32768!
        ElseIf bps = 4 Then
            acc = acc + _MemGet(mm, o + c * 4, Long) / 2147483648#
        Else
            acc = acc + (_MemGet(mm, o + c, _Unsigned _Byte) - 128) / 128!
        End If
    Next
    MonoAt! = acc / nch
End Function

'=======================================================================
'  Window around the play cursor, RMS level + 16 Goertzel bands
'=======================================================================
Sub Analyze (fr As _Integer64)
    Dim i As Long, b As Long
    Dim s0 As Single, s1 As Single, s2 As Single, cf As Single
    Dim pw As Single, mag As Single, db As Single, v As Single
    Dim sumSq As Single, lv As Single

    For i = 0 To NWIN - 1
        xs(i) = MonoAt!(fr - NWIN \ 2 + i)
        sumSq = sumSq + xs(i) * xs(i)
        xs(i) = xs(i) * hann(i)
    Next

    lv = _Clamp(Sqr(sumSq / NWIN) * 3, 0, 1)
    If lv > level Then level = level + (lv - level) * 0.5 Else level = level * 0.92 + lv * 0.08

    For b = 0 To NBAND - 1
        cf = 2 * Cos(PI2 * bandF(b) / srate)
        s1 = 0: s2 = 0
        For i = 0 To NWIN - 1
            s0 = xs(i) + cf * s1 - s2
            s2 = s1
            s1 = s0
        Next
        pw = s1 * s1 + s2 * s2 - cf * s1 * s2
        If pw < 0 Then pw = 0
        ' full-scale sine through a Hann window peaks at N/4
        mag = Sqr(pw) / (NWIN / 4)
        db = 20 * Log(mag + 0.000001) / Log(10)
        v = _Clamp((db + 60) / 60, 0, 1)

        If v > bandV(b) Then
            bandV(b) = bandV(b) + (v - bandV(b)) * 0.6
        Else
            bandV(b) = bandV(b) * 0.88 + v * 0.12
        End If
        bandP(b) = bandP(b) - 0.006
        If bandV(b) > bandP(b) Then bandP(b) = bandV(b)
        If bandP(b) < 0 Then bandP(b) = 0
    Next
End Sub

'=======================================================================
'  Fallback motion if the sample memory isn't available
'=======================================================================
Sub FakeBands
    Dim b As Long
    For b = 0 To NBAND - 1
        bandV(b) = 0.35 + 0.3 * Sin(tt * (2 + b * 0.3) + b)
        If bandV(b) > bandP(b) Then bandP(b) = bandV(b)
        bandP(b) = bandP(b) - 0.006
    Next
    level = 0.3 + 0.15 * Sin(tt * 3)
End Sub

'=======================================================================
Function MinSec$ (secs As Double)
    Dim m As Long, sc As Long
    m = Int(secs / 60)
    sc = Int(secs) Mod 60
    MinSec$ = LTrim$(Str$(m)) + ":" + Right$("0" + LTrim$(Str$(sc)), 2)
End Function

