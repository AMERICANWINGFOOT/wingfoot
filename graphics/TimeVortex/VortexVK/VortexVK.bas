'=======================================================================
'  VortexVK.bas  --  GPU time-vortex: Vulkan ray-marched tunnel
'  QB64-PE 4.6 on Linux, with libvortexvk.so (run build.sh first)
'
'  The music analysis is the same as TimeVortex.bas (_MemSound window,
'  16 Goertzel bands, beat detector); every pixel of the tunnel is
'  ray-marched on the GPU by vortex.comp and copied into a QB64 image.
'
'  Run:    ./VortexVK                      plays "Doctor Who - 1980.mp3"
'          ./VortexVK "song.mp3"           any other song
'          ./VortexVK --gpu=1              pick a GPU by index (the list
'                                          is printed to the terminal)
'
'  Keys:   SPACE pause   LEFT/RIGHT seek 5s   F fullscreen   H hud   ESC quit
'=======================================================================
Option _Explicit

Const SW = 1024, SH = 576
Const NWIN = 1024, NBAND = 16
Const PI2 = 6.2831853

Declare Library "./libvortexvk"
    Function vvk_init& (ByVal w As Long, ByVal h As Long, ByVal devIndex As Long)
    Sub vvk_set_band (ByVal i As Long, ByVal v As Single)
    Function vvk_render& (ByVal dst As _Offset, ByVal t As Single, ByVal zpos As Single, ByVal bass As Single, ByVal mids As Single, ByVal treb As Single, ByVal flash As Single, ByVal twist As Single, ByVal level As Single)
    Function vvk_ms!
    Sub vvk_devname (outName As String, ByVal maxlen As Long)
    Sub vvk_shutdown
End Declare

'--- audio state ---------------------------------------------------------
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
Dim Shared defaultSong As String

Dim fileName As String, arg As String, devStr As String
Dim ai As Long, gpuIdx As Long, rc As Long, i As Long, kh As Long, bx As Long, bh As Long
Dim vimg As Long
Dim vm As _MEM
Dim zpos As Single, spd As Single, twist As Single
Dim bassAvg As Single, flash As Single, flashCool As Long
Dim paused As Long, showHud As Long, frameCount As Long
Dim fr As _Integer64
Dim np As Double, songLen As Double
Dim fpsT As Double, fpsN As Long, fps As Long
Dim tstr As String

'--- command line --------------------------------------------------------
' (a plain variable, not a Const: the Const parser chokes on this text)
defaultSong = "Doctor Who - 1980.mp3"
gpuIdx = -1
For ai = 1 To _CommandCount
    arg = Command$(ai)
    If LCase$(Left$(arg, 6)) = "--gpu=" Then
        gpuIdx = Val(Mid$(arg, 7))
    Else
        fileName = arg
    End If
Next
If fileName = "" Then
    If _FileExists(defaultSong) Then fileName = defaultSong
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

'--- GPU -----------------------------------------------------------------
rc = vvk_init(SW, SH, gpuIdx)
If rc < 1 Then
    Print "Vulkan init failed, code"; rc
    Select Case rc
        Case -1: Print "  vkCreateInstance failed - is a Vulkan driver installed? (vulkaninfo)"
        Case -2: Print "  no Vulkan GPU found"
        Case -3: Print "  GPU has no compute queue"
        Case -4: Print "  vkCreateDevice failed"
        Case -5, -6, -7: Print "  couldn't create the host-visible output buffer"
        Case -8: Print "  shader/pipeline failed - rebuild with build.sh"
        Case Else: Print "  descriptor/command setup failed"
    End Select
    Sleep
    System
End If
devStr = Space$(256)
vvk_devname devStr, 256
If InStr(devStr, Chr$(0)) > 0 Then devStr = Left$(devStr, InStr(devStr, Chr$(0)) - 1)
devStr = _Trim$(devStr)

'--- audio ---------------------------------------------------------------
snd = _SndOpen(fileName)
If snd < 1 Then
    Print "Couldn't open audio: "; fileName
    vvk_shutdown
    Sleep
    System
End If
srate = _SndRate
songLen = _SndLen(snd)

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

'--- screen --------------------------------------------------------------
Screen _NewImage(SW, SH, 32)
_Title "VortexVK - " + devStr
_ScreenMove _Middle
_PrintMode _KeepBackground
vimg = _NewImage(SW, SH, 32)
vm = _MemImage(vimg)

showHud = -1
fpsT = Timer(0.001)
_SndPlay snd

'=======================================================================
Do
    _Limit 60
    frameCount = frameCount + 1
    tt = tt + 1 / 60

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

    bassAvg = bassAvg * 0.97 + bass * 0.03
    If flashCool > 0 Then flashCool = flashCool - 1
    If bass - bassAvg > 0.07 And flashCool = 0 Then
        flash = 1
        flashCool = 12
    End If
    flash = flash * 0.86

    spd = 0.05 + level * 0.4 + bass * 0.1 + flash * 0.08
    If paused Then spd = spd * 0.1
    zpos = zpos + spd
    twist = twist + 0.004 + treb * 0.025

    '--- GPU frame -----------------------------------------------------
    For i = 0 To NBAND - 1
        vvk_set_band i, bandV(i)
    Next
    rc = vvk_render(vm.OFFSET, tt, zpos, bass, mids, treb, flash, twist, level)
    _PutImage (0, 0), vimg

    '--- HUD -----------------------------------------------------------
    fpsN = fpsN + 1
    If Timer(0.001) - fpsT >= 1 Then
        fps = fpsN
        fpsN = 0
        fpsT = Timer(0.001)
    End If

    If showHud Then
        For i = 0 To NBAND - 1
            bx = SW - NBAND * 14 - 20 + i * 14
            bh = bandV(i) * 70
            Line (bx, SH - 24 - bh)-(bx + 10, SH - 24), _RGBA32(90, 150, 255, 170), BF
            bh = bandP(i) * 70
            Line (bx, SH - 25 - bh)-(bx + 10, SH - 25 - bh), _RGB32(255, 200, 110)
        Next

        tstr = MinSec$(_SndGetPos(snd)) + " / " + MinSec$(songLen)
        If paused Then tstr = tstr + "   [paused]"
        Color _RGB32(170, 185, 220)
        _PrintString (16, 16), tstr
        _PrintString (16, 34), devStr + "   " + LTrim$(Str$(fps)) + " fps   GPU+copy" + Str$(Int(vvk_ms * 10) / 10) + " ms"
        _PrintString (16, SH - 24), "SPACE pause   LEFT/RIGHT seek   F fullscreen   H hud   ESC quit"
    End If

    _Display
Loop

_MemFree vm
_FreeImage vimg
vvk_shutdown
If haveMem Then _MemFree mm
_SndStop snd
_SndClose snd
System

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
