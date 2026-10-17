'=======================================================================
' GPU_Info.bas  -  Linux NVIDIA GPU information / monitor
' QB64-PE 4.5.0  -  uses ButtonUI, GaugeUI and gpumon.h (keep all files together)
'
' DATA SOURCE
'   nvidia-smi --query-gpu   via gpumon.h - ONE call per second covers
'                            every GPU; results are cached in C.
'                            Fields a card doesn't report read N/A.
'
' Same look and layout as DiskInfo.bas.
'
' KEYS   Tab = next GPU   1-8 = pick GPU   F / C = temp units
'        P = pause        Esc = quit
'=======================================================================
'$Include:'ButtonUI.bi'
'$Include:'GaugeUI.bi'

Declare Library "gpumon"
    Function GPUMonRefresh& ()
    Function GPUMonValue# (ByVal idx As Long, ByVal fld As Long)
    Sub GPUMonText (ByVal idx As Long, ByVal which As Long, buf As String, ByVal buflen As Long)
End Declare

Const MAXG = 8
Const HISTLEN = 60

' --- gpumon field indexes (must match gpumon.h) ---
Const GF_UTIL = 0
Const GF_MEMUTIL = 1
Const GF_MEMUSED = 2
Const GF_MEMTOTAL = 3
Const GF_TEMP = 4
Const GF_POWER = 5
Const GF_PLIMIT = 6
Const GF_CLK = 7
Const GF_CLKMAX = 8
Const GF_MEMCLK = 9
Const GF_FAN = 10
Const GF_INDEX = 11
Const GT_NAME = 0
Const GT_PSTATE = 1
Const GT_DRIVER = 2

' --- GPUs are 1..gpuCount here; gpumon itself is 0-based ---
Dim Shared gpuCount As Integer

' --- load / VRAM history (percent), circular like DiskInfo ---
Dim Shared ldHist(1 To MAXG, 0 To HISTLEN - 1) As Single
Dim Shared vrHist(1 To MAXG, 0 To HISTLEN - 1) As Single
Dim Shared histPos As Integer, histFill As Integer
Dim Shared sparkL(0 To HISTLEN - 1) As Single
Dim Shared sparkV(0 To HISTLEN - 1) As Single
Dim Shared sparkPeakL As Single, sparkPeakV As Single

' --- settings / theme ---
Dim Shared useF As Integer, sel As Integer, paused As Integer
Dim Shared cBg As _Unsigned Long, cLbl As _Unsigned Long, cVal As _Unsigned Long
Dim Shared cHead As _Unsigned Long, cGood As _Unsigned Long, cBad As _Unsigned Long, cWarn As _Unsigned Long
Dim Shared cSel As _Unsigned Long

Dim i As Integer, bx As Integer
Dim k$, s$
Dim tnow As Double, tPoll As Double

Screen _NewImage(900, 640, 32)
_Title "GPU Info"
_PrintMode _KeepBackground
MouseInit
GaugeInit

cBg = _RGB32(18, 20, 26)
cLbl = _RGB32(140, 150, 170)
cVal = _RGB32(230, 235, 245)
cHead = _RGB32(120, 200, 255)
cGood = _RGB32(90, 220, 110)
cBad = _RGB32(255, 90, 80)
cWarn = _RGB32(240, 200, 80)
cSel = _RGB32(34, 40, 54)

sel = 1
PollGPUs
tPoll = Timer

Do
    _Limit 30
    PollMouse
    k$ = InKey$
    If k$ = Chr$(27) Then Exit Do
    If k$ = Chr$(9) And gpuCount > 0 Then sel = (sel Mod gpuCount) + 1
    If Len(k$) = 1 And k$ >= "1" And k$ <= "8" Then
        If Val(k$) <= gpuCount Then sel = Val(k$)
    End If
    If LCase$(k$) = "f" Then useF = -1
    If LCase$(k$) = "c" Then useF = 0
    If LCase$(k$) = "p" Then paused = Not paused

    ' ---- timed work: one nvidia-smi call per second ----
    tnow = Timer
    If tnow < tPoll Then tPoll = tnow
    If Not paused And tnow - tPoll >= 1 Then
        PollGPUs
        tPoll = tnow
    End If
    If sel > gpuCount Then sel = 1

    ' ---- draw ----
    Cls , cBg
    Txt 20, 10, cHead, "GPU INFO"
    Txt 110, 10, cLbl, "NVIDIA GPUs    Tab: next GPU    F/C: temp units    P: pause    Esc: quit"
    If paused Then Txt 836, 10, cWarn, "PAUSED"

    For i = 1 To gpuCount
        bx = 20 + (i - 1) * 108
        If ButtonEx%(bx, 32, 100, 28, "GPU " + LTrim$(Str$(GIdx%(i))), (i <> sel)) Then sel = i
    Next

    If gpuCount = 0 Then
        Txt 20, 90, cWarn, "No NVIDIA GPU found."
        Txt 20, 110, cLbl, "nvidia-smi is missing or returned no data - retrying every second."
    Else
        DrawDetails sel
    End If

    If useF Then s$ = "Temp: " + Chr$(248) + "F" Else s$ = "Temp: " + Chr$(248) + "C"
    If Button%(20, 596, 110, 32, s$) Then useF = Not useF
    If paused Then s$ = "Resume" Else s$ = "Pause"
    If Button%(140, 596, 110, 32, s$) Then paused = Not paused
    If Button%(780, 596, 100, 32, "Quit") Then Exit Do

    _Display
Loop
System


'=======================================================================
' DRAWING
'=======================================================================

Sub DrawDetails (d As Integer)
    Dim y As Integer, g As Integer
    Dim s$, u$, nm$, pct As Single, vp As Single
    Dim t As Double, tv As Single, mnT As Single, mxT As Single
    Dim pw As Double, pl As Double
    Dim hc As _Unsigned Long

    ' ---- info column ----
    y = 76
    KV y, "Name", Left$(GText$(d, GT_NAME), 40), cVal
    KV y, "Driver", GText$(d, GT_DRIVER), cVal
    KV y, "P-State", GText$(d, GT_PSTATE), cVal
    KV y, "Load", PctStr$(GV#(d, GF_UTIL)), cVal

    vp = VramPct#(d)
    If vp >= 0 Then
        s$ = FmtMiB$(GV#(d, GF_MEMUSED)) + " of " + FmtMiB$(GV#(d, GF_MEMTOTAL)) + "  (" + Fix1$((vp)) + "%)"
    Else
        s$ = "N/A"
    End If
    KV y, "VRAM", s$, cVal
    KV y, "Memory bus", PctStr$(GV#(d, GF_MEMUTIL)), cVal

    t = GV#(d, GF_TEMP)
    KV y, "Temperature", GTemp$(t), TempCol~&(t)

    pw = GV#(d, GF_POWER)
    pl = GV#(d, GF_PLIMIT)
    If pw >= 0 Then
        s$ = Fix1$((pw)) + " W"
        If pl > 0 Then s$ = s$ + " of " + Fix1$((pl)) + " W limit  (" + Fix1$((pw / pl * 100)) + "%)"
    Else
        s$ = "N/A (not reported by this card)"
    End If
    KV y, "Power", s$, cVal

    If GV#(d, GF_FAN) >= 0 Then s$ = PctStr$(GV#(d, GF_FAN)) Else s$ = "N/A (passive / not reported)"
    KV y, "Fan", s$, cVal
    KV y, "Core clock", MHz$(GV#(d, GF_CLK)) + " MHz  (max " + MHz$(GV#(d, GF_CLKMAX)) + ")", cVal
    KV y, "Memory clock", MHz$(GV#(d, GF_MEMCLK)) + " MHz", cVal

    ' ---- gauges ----
    pct = GV#(d, GF_UTIL)
    If pct >= 0 Then
        RingGauge 580, 170, 88, 60, (pct), "GPU load"
    Else
        Circle (580, 170), 88, cLbl
        Txt 568, 162, cLbl, "N/A"
    End If
    If t >= 0 Then
        If useF Then
            tv = t * 9 / 5 + 32: mnT = 32: mxT = 212: u$ = Chr$(248) + "F"
        Else
            tv = t: mnT = 0: mxT = 100: u$ = Chr$(248) + "C"
        End If
        DialGauge 790, 170, 88, (tv), (mnT), (mxT), u$, "GPU temp"
    Else
        Circle (790, 170), 88, cLbl
        Txt 778, 162, cLbl, "N/A"
    End If

    ' ---- all-GPU table (click a row to select) ----
    y = 296
    Txt 20, y, cHead, "GPU"
    Txt 64, y, cHead, "NAME"
    Txt 290, y, cHead, "LOAD"
    Txt 460, y, cHead, "VRAM"
    Txt 640, y, cHead, "TEMP"
    Txt 730, y, cHead, "POWER"
    y = y + 20
    For g = 1 To gpuCount
        If g = d Then Line (16, y - 2)-(884, y + 15), cSel, BF
        If gMouse.clicked Then
            If PtInRect%(gMouse.mx, gMouse.my, 16, y - 2, 868, 17) Then sel = g
        End If

        Txt 20, y, cVal, LTrim$(Str$(GIdx%(g)))
        nm$ = GText$(g, GT_NAME)
        If Left$(nm$, 7) = "NVIDIA " Then nm$ = Mid$(nm$, 8)
        Txt 64, y, cVal, Left$(nm$, 26)

        pct = GV#(g, GF_UTIL)
        If pct >= 0 Then
            HBar 290, y + 2, 100, 12, (pct)
            Txt 400, y, cVal, Fix1$((pct)) + "%"
        Else
            Txt 290, y, cLbl, "-"
        End If

        vp = VramPct#(g)
        If vp >= 0 Then
            HBar 460, y + 2, 100, 12, (vp)
            Txt 570, y, cVal, Fix1$((vp)) + "%"
        Else
            Txt 460, y, cLbl, "-"
        End If

        t = GV#(g, GF_TEMP)
        Txt 640, y, TempCol~&(t), GTemp$(t)

        pw = GV#(g, GF_POWER)
        If pw >= 0 Then Txt 730, y, cVal, Fix1$((pw)) + " W" Else Txt 730, y, cLbl, "N/A"
        y = y + 18
    Next

    ' ---- history sparklines (percent, fixed 0-100 scale) ----
    BuildSpark d
    Sparkline 20, 500, 410, 72, sparkL(), histFill, 0, 100, "Load " + PctStr$(GV#(d, GF_UTIL)) + "   peak " + Fix1$((sparkPeakL)) + "%"
    Sparkline 470, 500, 410, 72, sparkV(), histFill, 0, 100, "VRAM " + PctStr$(VramPct#(d)) + "   peak " + Fix1$((sparkPeakV)) + "%"
End Sub


Sub KV (y As Integer, lbl$, v$, vc As _Unsigned Long)
    ' label / value row; advances y to the next row
    Txt 20, y, cLbl, lbl$
    Txt 150, y, vc, v$
    y = y + 18
End Sub


Sub Txt (x As Integer, y As Integer, c As _Unsigned Long, s$)
    Color c
    _PrintMode _KeepBackground
    _PrintString (x, y), s$
End Sub


Sub BuildSpark (d As Integer)
    ' unwrap the circular history for GPU d into chronological sparkL/sparkV
    Dim i As Integer, src As Integer, startIx As Integer
    sparkPeakL = 0: sparkPeakV = 0
    startIx = (histPos - histFill + HISTLEN) Mod HISTLEN
    For i = 0 To histFill - 1
        src = (startIx + i) Mod HISTLEN
        sparkL(i) = ldHist(d, src)
        sparkV(i) = vrHist(d, src)
        If sparkL(i) > sparkPeakL Then sparkPeakL = sparkL(i)
        If sparkV(i) > sparkPeakV Then sparkPeakV = sparkV(i)
    Next
End Sub


'=======================================================================
' DATA: gpumon.h wrappers
'=======================================================================

Sub PollGPUs
    Dim d As Integer, u As Single, v As Single, n As Integer
    n = GPUMonRefresh&
    If n > MAXG Then n = MAXG
    ' GPU set changed (first run, or a card dropped off): start fresh
    If n <> gpuCount Then histPos = 0: histFill = 0
    gpuCount = n
    If gpuCount = 0 Then Exit Sub
    For d = 1 To gpuCount
        u = GV#(d, GF_UTIL)
        If u < 0 Then u = 0
        v = VramPct#(d)
        If v < 0 Then v = 0
        ldHist(d, histPos) = u
        vrHist(d, histPos) = v
    Next
    histPos = (histPos + 1) Mod HISTLEN
    If histFill < HISTLEN Then histFill = histFill + 1
End Sub


Function GV# (d As Integer, fld As Integer)
    ' value for GPU d (1-based); -1 = not reported
    GV# = GPUMonValue#(d - 1, fld)
End Function


Function GIdx% (d As Integer)
    ' nvidia-smi's own index for GPU d
    GIdx% = CInt(GPUMonValue#(d - 1, GF_INDEX))
End Function


Function GText$ (d As Integer, what As Integer)
    Dim buf As String, z As Long
    buf = Space$(128)
    GPUMonText d - 1, what, buf, 128
    z = InStr(buf, Chr$(0))
    If z > 0 Then buf = Left$(buf, z - 1)
    GText$ = _Trim$(buf)
End Function


Function VramPct# (d As Integer)
    Dim mu As Double, mt As Double
    mu = GV#(d, GF_MEMUSED)
    mt = GV#(d, GF_MEMTOTAL)
    If mu < 0 Or mt <= 0 Then
        VramPct# = -1
    Else
        VramPct# = mu / mt * 100
    End If
End Function


'=======================================================================
' STRING HELPERS
'=======================================================================
Function Fix1$ (v As Double)
    ' one decimal place, e.g. 3.0 / 12.5 / 0.4 - integer math, no float artifacts
    Dim t As Long
    t = Int(v * 10 + 0.5)
    Fix1$ = _Trim$(Str$(t \ 10)) + "." + _Trim$(Str$(t Mod 10))
End Function


Function PctStr$ (p As Double)
    If p < 0 Then PctStr$ = "N/A" Else PctStr$ = Fix1$((p)) + "%"
End Function


Function MHz$ (x As Double)
    If x < 0 Then MHz$ = "N/A" Else MHz$ = LTrim$(Str$(CLng(x)))
End Function


Function FmtMiB$ (mb As Double)
    ' nvidia-smi reports memory in MiB
    If mb < 0 Then
        FmtMiB$ = "N/A"
    ElseIf mb >= 1024 Then
        FmtMiB$ = Fix1$((mb / 1024)) + " GiB"
    Else
        FmtMiB$ = LTrim$(Str$(CLng(mb))) + " MiB"
    End If
End Function


Function GTemp$ (c As Double)
    If c < 0 Then
        GTemp$ = "N/A"
    ElseIf useF Then
        GTemp$ = LTrim$(Str$(Int(c * 9 / 5 + 32 + 0.5))) + " " + Chr$(248) + "F"
    Else
        GTemp$ = LTrim$(Str$(Int(c + 0.5))) + " " + Chr$(248) + "C"
    End If
End Function


Function TempCol~& (c As Double)
    ' thresholds in Celsius regardless of display units
    If c < 0 Then
        TempCol~& = cLbl
    ElseIf c >= 85 Then
        TempCol~& = cBad
    ElseIf c >= 75 Then
        TempCol~& = cWarn
    Else
        TempCol~& = cVal
    End If
End Function

'$Include:'ButtonUI.bm'
'$Include:'GaugeUI.bm'
