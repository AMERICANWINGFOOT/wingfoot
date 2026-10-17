'=======================================================================
' CPULoad.bas  -  CPU load / thermal test for Linux
' QB64-PE 4.5.0  -  uses ButtonUI, GaugeUI, loadtest.h, sysmon.h (same folder)
'
' loadtest.h runs one pthread worker per selected CPU thread doing
' floating-point math - QB64 itself only handles the UI.
'
' sysmon.h reads, once per second, straight from /proc and /sys
' (no shell calls, no temp files):
'   /proc/stat                   total CPU load
'   hwmon coretemp / k10temp     CPU package temperature
'   /proc/cpuinfo "cpu MHz"      average clock (shows throttling)
'   hwmon fanN_input             fan speeds (rpm), peak during test
'
' SAFETY: the test stops itself if the temperature reaches the limit.
'
' KEYS   Space = start / stop    Esc = quit
'=======================================================================
'$Include:'ButtonUI.bi'
'$Include:'GaugeUI.bi'

Declare Library "loadtest"
    Function LT_CPUCount& ()
    Function LT_Start& (ByVal n As Long)
    Sub LT_Stop ()
    Function LT_Running& ()
End Declare

Declare Library "sysmon"
    Sub SM_Update ()
    Function SM_Load# ()
    Function SM_Temp# ()
    Function SM_MHz# ()
    Function SM_FanCount& ()
    Function SM_FanChip& (ByVal i As Long)
    Function SM_FanNum& (ByVal i As Long)
    Function SM_FanRPM& (ByVal i As Long)
    Function SM_ModelLen& ()
    Function SM_ModelChar& (ByVal i As Long)
End Declare

Const HISTLEN = 120
Const MAXFAN = 8

Dim Shared nCpu As Long, nThreads As Long
Dim Shared durSel As Integer, tLimitC As Integer, useF As Integer
Dim Shared durSecs(0 To 3) As Long, durLbl$(0 To 3)
Dim Shared running As Integer, lastMsg$, cpuModel$
Dim Shared testElapsed As Double, runThreads As Long

Dim Shared tempNow As Single, tempStart As Single, tempPeak As Single
Dim Shared loadNow As Single, loadSum As Double, loadCnt As Long
Dim Shared mhzNow As Single, mhzMin As Single, mhzMax As Single

Dim Shared tempHist(0 To HISTLEN - 1) As Single, loadHist(0 To HISTLEN - 1) As Single
Dim Shared histPos As Integer, histFill As Integer
Dim Shared sparkT(0 To HISTLEN - 1) As Single, sparkL(0 To HISTLEN - 1) As Single

' --- fans (hwmon fanN_input), keyed by sysfs path ---
Dim Shared fanCount As Integer
Dim Shared fanKey$(1 To MAXFAN), fanName$(1 To MAXFAN)
Dim Shared fanRpm(1 To MAXFAN) As Long, fanPeak(1 To MAXFAN) As Long
Dim Shared fanSeen(1 To MAXFAN) As Integer

Dim Shared cBg As _Unsigned Long, cLbl As _Unsigned Long, cVal As _Unsigned Long
Dim Shared cHead As _Unsigned Long, cGood As _Unsigned Long, cBad As _Unsigned Long, cWarn As _Unsigned Long

Dim i As Integer, bx As Integer
Dim k$, s$
Dim tnow As Double, tSample As Double, dt As Double

Screen _NewImage(900, 640, 32)
_Title "CPU Load Test"
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

durSecs(0) = 60: durLbl$(0) = "1 min"
durSecs(1) = 300: durLbl$(1) = "5 min"
durSecs(2) = 600: durLbl$(2) = "10 min"
durSecs(3) = 0: durLbl$(3) = "No limit"

nCpu = LT_CPUCount&
nThreads = nCpu
durSel = 2
tLimitC = 90
tempNow = -999
lastMsg$ = "Ready"
SampleSystem
ReadModel
tSample = Timer

Do
    _Limit 30
    PollMouse
    If _Exit Then Exit Do
    k$ = InKey$
    If k$ = Chr$(27) Then Exit Do
    If k$ = " " Then
        If running Then EndTest "Stopped by user" Else BeginTest
    End If

    ' ---- once-per-second sampling ----
    tnow = Timer
    If tnow < tSample Then tSample = tnow
    If tnow - tSample >= 1 Then
        dt = tnow - tSample
        tSample = tnow
        SampleSystem
        If running Then
            testElapsed = testElapsed + dt
            loadSum = loadSum + loadNow: loadCnt = loadCnt + 1
            If tempNow > tempPeak Then tempPeak = tempNow
            If testElapsed >= 2 And mhzNow > 0 And mhzNow < mhzMin Then mhzMin = mhzNow
            If mhzNow > mhzMax Then mhzMax = mhzNow
            If tempNow > -999 And tempNow >= tLimitC Then
                EndTest "SAFETY STOP - temperature limit reached"
            ElseIf durSecs(durSel) > 0 And testElapsed >= durSecs(durSel) Then
                EndTest "Test complete"
            End If
        End If
    End If

    ' ---- draw ----
    Cls , cBg
    Txt 20, 10, cHead, "CPU LOAD TEST"
    Txt 140, 10, cLbl, Left$(cpuModel$, 60)

    ' threads
    Txt 20, 48, cLbl, "Threads"
    If ButtonEx%(90, 40, 32, 28, "-", (running = 0 And nThreads > 1)) Then nThreads = nThreads - 1
    Txt 130, 48, cVal, LTrim$(Str$(nThreads)) + "/" + LTrim$(Str$(nCpu))
    If ButtonEx%(190, 40, 32, 28, "+", (running = 0 And nThreads < nCpu)) Then nThreads = nThreads + 1
    If ButtonEx%(228, 40, 48, 28, "All", (running = 0 And nThreads <> nCpu)) Then nThreads = nCpu

    ' duration
    Txt 300, 48, cLbl, "Duration"
    For i = 0 To 3
        bx = 374 + i * 74
        If ButtonEx%(bx, 40, 70, 28, durLbl$(i), (running = 0 And i <> durSel)) Then durSel = i
    Next

    ' temperature limit
    Txt 20, 88, cLbl, "Temp limit"
    If ButtonEx%(110, 80, 32, 28, "-", (running = 0 And tLimitC > 70)) Then tLimitC = tLimitC - 5
    Txt 150, 88, cVal, FmtTemp$((tLimitC))
    If ButtonEx%(210, 80, 32, 28, "+", (running = 0 And tLimitC < 100)) Then tLimitC = tLimitC + 5
    Txt 300, 88, cLbl, "test stops automatically at this temperature"

    ' start / stop
    If running Then s$ = "STOP TEST" Else s$ = "START TEST"
    If Button%(700, 40, 180, 68, s$) Then
        If running Then EndTest "Stopped by user" Else BeginTest
    End If

    DrawStats

    If useF Then s$ = "Temp: " + Chr$(248) + "F" Else s$ = "Temp: " + Chr$(248) + "C"
    If Button%(20, 596, 110, 32, s$) Then useF = Not useF
    Txt 150, 604, cLbl, "Space: start / stop    Esc: quit"
    If Button%(780, 596, 100, 32, "Quit") Then Exit Do

    _Display
Loop

LT_Stop
System


'=======================================================================
' TEST CONTROL
'=======================================================================

Sub BeginTest
    Dim i As Integer
    If running Then Exit Sub
    runThreads = LT_Start&(nThreads)
    If runThreads < 1 Then
        lastMsg$ = "Could not start worker threads"
        Exit Sub
    End If
    running = -1
    testElapsed = 0
    tempStart = tempNow: tempPeak = tempNow
    mhzMin = 999999: mhzMax = 0
    For i = 1 To MAXFAN: fanPeak(i) = 0: Next
    loadSum = 0: loadCnt = 0
    lastMsg$ = "Running"
End Sub


Sub EndTest (why$)
    LT_Stop
    running = 0
    lastMsg$ = why$
End Sub


'=======================================================================
' DRAWING
'=======================================================================

Sub DrawStats
    Dim y As Integer, s$, hc As _Unsigned Long
    Dim tv As Single, mnT As Single, mxT As Single, u$

    y = 130
    If running Then
        hc = cGood
    ElseIf Left$(lastMsg$, 6) = "SAFETY" Then
        hc = cBad
    Else
        hc = cVal
    End If
    KV y, "Status", lastMsg$, hc
    If running Then s$ = LTrim$(Str$(runThreads)) + " worker threads" Else s$ = "idle"
    KV y, "Load gen", s$, cVal
    KV y, "Elapsed", FmtTime$(testElapsed), cVal
    If durSecs(durSel) = 0 Then
        s$ = "no limit"
    ElseIf running Then
        s$ = FmtTime$(durSecs(durSel) - testElapsed)
    Else
        s$ = FmtTime$((durSecs(durSel)))
    End If
    KV y, "Remaining", s$, cVal
    KV y, "CPU load", Fix1$((loadNow)) + "%", cVal
    If loadCnt > 0 Then s$ = Fix1$(loadSum / loadCnt) + "%" Else s$ = "--"
    KV y, "Avg load", s$, cVal
    KV y, "Temp now", FmtTemp$(tempNow), TempColor~&(tempNow)
    KV y, "Temp start", FmtTemp$(tempStart), cVal
    KV y, "Temp peak", FmtTemp$(tempPeak), TempColor~&(tempPeak)
    If tempStart > -999 And tempPeak > -999 Then
        If useF Then s$ = "+" + Fix1$((tempPeak - tempStart) * 9 / 5) Else s$ = "+" + Fix1$((tempPeak - tempStart))
    Else
        s$ = "--"
    End If
    KV y, "Temp rise", s$, cVal
    KV y, "Clock now", FmtMHz$(mhzNow), cVal
    If mhzMax > 0 Then s$ = FmtMHz$(mhzMin) + "  to  " + FmtMHz$(mhzMax) Else s$ = "--"
    KV y, "Clock range", s$, cVal

    ' gauges
    RingGauge 560, 245, 88, 60, (loadNow), "CPU load"
    If tempNow > -999 Then
        If useF Then
            tv = tempNow * 9 / 5 + 32: mnT = 68: mxT = 212: u$ = Chr$(248) + "F"
        Else
            tv = tempNow: mnT = 20: mxT = 100: u$ = Chr$(248) + "C"
        End If
        DialGauge 790, 245, 88, (tv), (mnT), (mxT), u$, "CPU temp"
    Else
        Circle (790, 245), 88, cLbl
        Txt 778, 237, cLbl, "N/A"
    End If

    ' history sparklines (last 2 minutes)
    BuildSpark
    If useF Then
        mnT = 68: mxT = 212
    Else
        mnT = 20: mxT = 100
    End If
    Sparkline 20, 400, 410, 120, sparkT(), histFill, (mnT), (mxT), "Temperature - last 2 min   (" + FmtTemp$(tempNow) + ")"
    Sparkline 470, 400, 410, 120, sparkL(), histFill, 0, 100, "CPU load - last 2 min   (" + Fix1$((loadNow)) + "%)"

    DrawFans
End Sub


Sub DrawFans
    ' up to 6 fans, 3 per row; only headers that have ever spun
    Dim i As Integer, shown As Integer, x As Integer, y As Integer, s$
    Dim fc As _Unsigned Long
    Txt 20, 538, cHead, "FANS"
    For i = 1 To fanCount
        If fanSeen(i) And shown < 6 Then
            x = 80 + (shown Mod 3) * 270
            y = 538 + (shown \ 3) * 20
            s$ = fanName$(i) + "  " + LTrim$(Str$(fanRpm(i))) + " rpm"
            If fanPeak(i) > 0 Then s$ = s$ + "   peak " + LTrim$(Str$(fanPeak(i)))
            If fanRpm(i) = 0 Then fc = cBad Else fc = cVal
            Txt x, y, fc, s$
            shown = shown + 1
        End If
    Next
    If shown = 0 Then Txt 80, 538, cLbl, "no fan sensors found"
End Sub


Sub BuildSpark
    Dim i As Integer, src As Integer, startIx As Integer
    startIx = (histPos - histFill + HISTLEN) Mod HISTLEN
    For i = 0 To histFill - 1
        src = (startIx + i) Mod HISTLEN
        If useF Then sparkT(i) = tempHist(src) * 9 / 5 + 32 Else sparkT(i) = tempHist(src)
        sparkL(i) = loadHist(src)
    Next
End Sub


Sub KV (y As Integer, lbl$, v$, vc As _Unsigned Long)
    Txt 20, y, cLbl, lbl$
    Txt 150, y, vc, v$
    y = y + 18
End Sub


Sub Txt (x As Integer, y As Integer, c As _Unsigned Long, s$)
    Color c
    _PrintString (x, y), s$
End Sub


Function TempColor~& (c As Single)
    If c <= -999 Then
        TempColor~& = cVal
    ElseIf c >= tLimitC - 10 Then
        TempColor~& = cBad
    ElseIf c >= 70 Then
        TempColor~& = cWarn
    Else
        TempColor~& = cGood
    End If
End Function


'=======================================================================
' DATA
'=======================================================================

Sub ReadModel
    ' model string comes from sysmon.h (filled by the first SM_Update)
    Dim i As Long, n As Long
    cpuModel$ = ""
    n = SM_ModelLen&
    For i = 1 To n
        cpuModel$ = cpuModel$ + Chr$(SM_ModelChar&(i))
    Next
End Sub


Sub SampleSystem
    Dim i As Long, n As Long
    SM_Update
    loadNow = SM_Load#
    tempNow = SM_Temp#
    mhzNow = SM_MHz#

    n = SM_FanCount&
    For i = 1 To n
        UpdateFan SM_FanChip&(i), SM_FanNum&(i), SM_FanRPM&(i)
    Next

    tempHist(histPos) = tempNow
    If tempNow <= -999 Then tempHist(histPos) = 0
    loadHist(histPos) = loadNow
    histPos = (histPos + 1) Mod HISTLEN
    If histFill < HISTLEN Then histFill = histFill + 1
End Sub


Sub UpdateFan (chip As Long, num As Long, rpm As Long)
    ' fans are keyed by hwmon chip + fan number so each keeps its peak
    Dim i As Integer, f As Integer, key$
    key$ = LTrim$(Str$(chip)) + "/" + LTrim$(Str$(num))
    f = 0
    For i = 1 To fanCount
        If fanKey$(i) = key$ Then
            f = i
            Exit For
        End If
    Next
    If f = 0 Then
        If fanCount >= MAXFAN Then Exit Sub
        fanCount = fanCount + 1
        f = fanCount
        fanKey$(f) = key$
        fanName$(f) = "fan" + LTrim$(Str$(num))
    End If
    fanRpm(f) = rpm
    If rpm > 0 Then fanSeen(f) = -1
    If running And rpm > fanPeak(f) Then fanPeak(f) = rpm
End Sub


'=======================================================================
' STRING HELPERS
'=======================================================================

Function Fix1$ (v As Double)
    ' one decimal place, built from whole tenths so no float noise
    Dim t As _Integer64, sgn$
    t = Int(v * 10 + 0.5)
    If t < 0 Then sgn$ = "-": t = -t
    Fix1$ = sgn$ + LTrim$(Str$(t \ 10)) + "." + LTrim$(Str$(t Mod 10))
End Function


Function FmtTime$ (secs As Double)
    Dim t As Long, m$, sc$
    t = Int(secs)
    If t < 0 Then t = 0
    m$ = LTrim$(Str$(t \ 60))
    sc$ = Right$("0" + LTrim$(Str$(t Mod 60)), 2)
    FmtTime$ = m$ + ":" + sc$
End Function


Function FmtTemp$ (c As Single)
    If c <= -999 Then
        FmtTemp$ = "N/A"
    ElseIf useF Then
        FmtTemp$ = LTrim$(Str$(Int(c * 9 / 5 + 32 + 0.5))) + " " + Chr$(248) + "F"
    Else
        FmtTemp$ = LTrim$(Str$(Int(c + 0.5))) + " " + Chr$(248) + "C"
    End If
End Function


Function FmtMHz$ (mhz As Single)
    If mhz <= 0 Then
        FmtMHz$ = "--"
    Else
        FmtMHz$ = LTrim$(Str$(Int(mhz + 0.5))) + " MHz"
    End If
End Function

'$Include:'ButtonUI.bm'
'$Include:'GaugeUI.bm'
