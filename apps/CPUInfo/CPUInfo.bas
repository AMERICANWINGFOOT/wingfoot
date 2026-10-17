' ============================================================
' CPUInfo.bas - Linux CPU Information Display
' QB64-PE 4.5.0
'
' Reads CPU model, core count, clock speed, per-core and
' aggregate load, and temperature directly from /proc and
' /sys - no external C library or shell-out required.
'
' Data sources:
'   /proc/cpuinfo                       - model name, cores, MHz
'   /proc/stat                          - jiffies per core (load calc)
'   /sys/class/thermal/thermal_zoneN/*  - temperature (millidegrees C)
'
' ESC or Quit button to quit. A key or Mode button toggles live/30s avg.
' ============================================================

'$Include:'ButtonUI.bi'
'$Include:'GaugeUI.bi'

Type CpuStatType
    user As _Integer64
    nice As _Integer64
    sys As _Integer64
    idle As _Integer64
    iowait As _Integer64
    irq As _Integer64
    softirq As _Integer64
    steal As _Integer64
    total As _Integer64
End Type

Const MAX_CORES = 128
Const HISTORY_LEN = 30 ' seconds of load samples kept for the 30s-average mode

Dim Shared modelName As String
Dim Shared coreCount As Integer
Dim Shared mhzText As String
Dim Shared thermalZonePath As String
Dim Shared thermalZoneLabel As String

Dim Shared prevStat(MAX_CORES) As CpuStatType ' index 0 = aggregate, 1..N = per core
Dim Shared currStat(MAX_CORES) As CpuStatType
Dim Shared loadPct(MAX_CORES) As Single

Dim Shared loadHistory(MAX_CORES, HISTORY_LEN - 1) As Single ' circular buffer per core
Dim Shared tempHistory(HISTORY_LEN - 1) As Single ' circular buffer, same cadence as loadHistory
Dim Shared historyPos As Integer ' next write slot (0..HISTORY_LEN-1)
Dim Shared historyCount As Integer ' samples collected so far, caps at HISTORY_LEN
Dim Shared displayMode As Integer ' 0 = live (1s), 1 = 30s average
Dim Shared currentTempC As Single ' most recent temp reading, updated once/sec
Dim Shared tempUnitF As Integer ' 0 = Celsius, 1 = Fahrenheit

Dim Shared sparkVals(HISTORY_LEN - 1) As Single ' aggregate load, unwrapped chronological order
Dim Shared sparkCount As Integer

Screen _NewImage(900, 640, 32)
_Title "CPU Info"
Color _RGB32(200, 200, 200), _RGB32(0, 0, 0)
MouseInit
GaugeInit

ReadCpuInfo
FindThermalZone

Dim firstSample As Integer
firstSample = -1
historyPos = 0
historyCount = 0
displayMode = 0
tempUnitF = 0

Dim lastSampleTime As Double
lastSampleTime = -999 ' forces an immediate first sample below

Dim wantQuit As Integer
wantQuit = 0

Do
    _Limit 30
    PollMouse

    If Abs(Timer - lastSampleTime) >= 1 Or firstSample = -1 Then
        ReadCpuStat
        If firstSample = -1 Then
            ' need two samples to compute a delta, so just copy and wait
            CopyStats
            firstSample = 0
            _Delay 0.5
            ReadCpuStat
        End If
        ComputeLoad
        currentTempC = ReadTempC!
        RecordHistory
        BuildAggSparkline
        CopyStats
        lastSampleTime = Timer
    End If

    DrawScreen wantQuit

    Dim k$
    k$ = InKey$
    If k$ = Chr$(27) Then wantQuit = -1
    If UCase$(k$) = "A" Then displayMode = 1 - displayMode

    If wantQuit Then Exit Do
Loop

System

' ------------------------------------------------------------
Sub ReadCpuInfo
    Dim f As Integer, ln As String
    Dim gotModel As Integer, gotMhz As Integer
    coreCount = 0
    modelName = "unknown"
    mhzText = "unknown"
    gotModel = 0
    gotMhz = 0

    ' /proc/cpuinfo reports a file size of 0 to the OS, which breaks QB64's
    ' EOF() check (it relies on reported size, not an actual read attempt) -
    ' the Do-While-Not-EOF loop below would never run a single iteration.
    ' Route it through cat into a real temp file first, which has a normal
    ' reported size.
    Shell "cat /proc/cpuinfo > /tmp/qb64_cpuinfo.tmp 2>/dev/null"

    f = FreeFile
    Open "/tmp/qb64_cpuinfo.tmp" For Input As #f
    Do While Not EOF(f)
        Line Input #f, ln
        If Left$(ln, 9) = "processor" Then
            coreCount = coreCount + 1
        ElseIf gotModel = 0 And Left$(ln, 10) = "model name" Then
            modelName = ExtractValue$(ln)
            gotModel = -1
        ElseIf gotMhz = 0 And Left$(ln, 7) = "cpu MHz" Then
            mhzText = ExtractValue$(ln)
            gotMhz = -1
        End If
    Loop
    Close #f
End Sub

Function ExtractValue$ (ln As String)
    Dim p As Integer
    p = InStr(ln, ":")
    If p > 0 Then
        ExtractValue$ = LTrim$(Mid$(ln, p + 1))
    Else
        ExtractValue$ = ""
    End If
End Function

' ------------------------------------------------------------
Sub FindThermalZone
    Dim zoneIdx As Integer, f As Integer, path$, typeLine$
    thermalZonePath = ""
    thermalZoneLabel = ""

    For zoneIdx = 0 To 15
        path$ = "/sys/class/thermal/thermal_zone" + LTrim$(Str$(zoneIdx)) + "/type"
        If _FileExists(path$) Then
            f = FreeFile
            Open path$ For Input As #f
            Line Input #f, typeLine$
            Close #f

            ' Prefer a package/core sensor if we find one, otherwise take the first zone found
            If thermalZonePath = "" Then
                thermalZonePath = "/sys/class/thermal/thermal_zone" + LTrim$(Str$(zoneIdx)) + "/temp"
                thermalZoneLabel = typeLine$
            End If
            If InStr(LCase$(typeLine$), "pkg") > 0 Or InStr(LCase$(typeLine$), "cpu") > 0 Or InStr(LCase$(typeLine$), "core") > 0 Then
                thermalZonePath = "/sys/class/thermal/thermal_zone" + LTrim$(Str$(zoneIdx)) + "/temp"
                thermalZoneLabel = typeLine$
                Exit For
            End If
        End If
    Next zoneIdx
End Sub

Function ReadTempC! ()
    Dim f As Integer, raw As String, milli As Long
    If thermalZonePath = "" Then
        ReadTempC! = -999
        Exit Function
    End If
    If Not _FileExists(thermalZonePath) Then
        ReadTempC! = -999
        Exit Function
    End If
    f = FreeFile
    Open thermalZonePath For Input As #f
    Line Input #f, raw
    Close #f
    milli = Val(raw)
    ReadTempC! = milli / 1000.0
End Function

' ------------------------------------------------------------
Sub ReadCpuStat
    Dim f As Integer, ln As String, tag$, idx As Integer
    Dim u As _Integer64, n As _Integer64, s As _Integer64, i As _Integer64
    Dim iow As _Integer64, irqv As _Integer64, sirq As _Integer64, stl As _Integer64

    ' Same procfs size-0 / EOF() issue as /proc/cpuinfo - go through a temp file.
    Shell "cat /proc/stat > /tmp/qb64_stat.tmp 2>/dev/null"

    f = FreeFile
    Open "/tmp/qb64_stat.tmp" For Input As #f
    Do While Not EOF(f)
        Line Input #f, ln
        If Left$(ln, 3) = "cpu" Then
            tag$ = ""
            Dim sp As Integer
            sp = InStr(ln, " ")
            If sp > 0 Then tag$ = Left$(ln, sp - 1)

            If tag$ = "cpu" Then
                idx = 0
            ElseIf Left$(tag$, 3) = "cpu" And Len(tag$) > 3 Then
                idx = Val(Mid$(tag$, 4)) + 1
                If idx > MAX_CORES Then idx = -1
            Else
                idx = -1
            End If

            If idx >= 0 And idx <= MAX_CORES Then
                Dim rest$
                rest$ = Mid$(ln, sp + 1)
                u = ParseNextInt(rest$)
                n = ParseNextInt(rest$)
                s = ParseNextInt(rest$)
                i = ParseNextInt(rest$)
                iow = ParseNextInt(rest$)
                irqv = ParseNextInt(rest$)
                sirq = ParseNextInt(rest$)
                stl = ParseNextInt(rest$)

                currStat(idx).user = u
                currStat(idx).nice = n
                currStat(idx).sys = s
                currStat(idx).idle = i
                currStat(idx).iowait = iow
                currStat(idx).irq = irqv
                currStat(idx).softirq = sirq
                currStat(idx).steal = stl
                currStat(idx).total = u + n + s + i + iow + irqv + sirq + stl
            End If
        End If
    Loop
    Close #f
End Sub

' Pulls the next whitespace-delimited integer off the front of s$ and shrinks s$
Function ParseNextInt&& (s As String)
    Dim s2 As String
    s2 = LTrim$(s)
    Dim sp As Integer
    sp = InStr(s2, " ")
    If sp = 0 Then
        ParseNextInt&& = Val(s2)
        s = ""
    Else
        ParseNextInt&& = Val(Left$(s2, sp - 1))
        s = Mid$(s2, sp + 1)
    End If
End Function

Sub CopyStats
    Dim idx As Integer
    For idx = 0 To coreCount
        prevStat(idx) = currStat(idx)
    Next idx
End Sub

Sub ComputeLoad
    Dim idx As Integer
    Dim totalDelta As _Integer64, idleDelta As _Integer64
    For idx = 0 To coreCount
        totalDelta = currStat(idx).total - prevStat(idx).total
        idleDelta = (currStat(idx).idle + currStat(idx).iowait) - (prevStat(idx).idle + prevStat(idx).iowait)
        If totalDelta > 0 Then
            loadPct(idx) = (1.0 - (idleDelta / totalDelta)) * 100.0
            If loadPct(idx) < 0 Then loadPct(idx) = 0
            If loadPct(idx) > 100 Then loadPct(idx) = 100
        Else
            loadPct(idx) = 0
        End If
    Next idx
End Sub

Sub RecordHistory
    Dim idx As Integer
    For idx = 0 To coreCount
        loadHistory(idx, historyPos) = loadPct(idx)
    Next idx
    tempHistory(historyPos) = currentTempC
    historyPos = (historyPos + 1) Mod HISTORY_LEN
    If historyCount < HISTORY_LEN Then historyCount = historyCount + 1
End Sub

' Unwraps the aggregate (idx 0) load history circular buffer into
' chronological (oldest-first) order for Sparkline to draw left-to-right.
Sub BuildAggSparkline
    Dim i As Integer, oldestPos As Integer, srcPos As Integer
    If historyCount < HISTORY_LEN Then
        oldestPos = 0
    Else
        oldestPos = historyPos ' buffer full - the next write slot holds the oldest sample
    End If
    For i = 0 To historyCount - 1
        srcPos = (oldestPos + i) Mod HISTORY_LEN
        sparkVals(i) = loadHistory(0, srcPos)
    Next i
    sparkCount = historyCount
End Sub

Function AvgLoad! (idx As Integer)
    If historyCount = 0 Then
        AvgLoad! = 0
        Exit Function
    End If
    Dim total As Single, k As Integer
    total = 0
    For k = 0 To historyCount - 1
        total = total + loadHistory(idx, k)
    Next k
    AvgLoad! = total / historyCount
End Function

Function AvgTempC! ()
    If historyCount = 0 Then
        AvgTempC! = currentTempC
        Exit Function
    End If
    Dim total As Single, k As Integer
    total = 0
    For k = 0 To historyCount - 1
        total = total + tempHistory(k)
    Next k
    AvgTempC! = total / historyCount
End Function

' Returns the Celsius temp to display, per the same displayMode toggle
' used for load (0 = live instantaneous reading, 1 = 30s average)
Function DisplayTempC! ()
    If displayMode = 0 Then
        DisplayTempC! = currentTempC
    Else
        DisplayTempC! = AvgTempC!
    End If
End Function

Function CToF! (c As Single)
    CToF! = c * 9.0 / 5.0 + 32.0
End Function

' Returns the value to display for a given core/aggregate index, per the
' current displayMode (0 = live instantaneous reading, 1 = 30s average)
Function DisplayLoad! (idx As Integer)
    If displayMode = 0 Then
        DisplayLoad! = loadPct(idx)
    Else
        DisplayLoad! = AvgLoad!(idx)
    End If
End Function

' ------------------------------------------------------------
Sub DrawScreen (wantQuit As Integer)
    Cls
    Color _RGB32(255, 255, 255)
    _PrintString (16, 10), "CPU INFO"
    Color _RGB32(120, 120, 120)
    _PrintString (16, 26), String$(100, "-")

    If Button%(816, 8, 76, 26, "Quit") Then wantQuit = -1

    Color _RGB32(200, 200, 200)
    _PrintString (16, 46), "Model:      " + modelName
    _PrintString (16, 62), "Cores:      " + LTrim$(Str$(coreCount))
    _PrintString (16, 78), "Clock:      " + mhzText + " MHz"

    Dim modeLabel$, toggleCaption$, unitCaption$
    If displayMode = 0 Then
        modeLabel$ = "LIVE"
        toggleCaption$ = "Mode: Live"
    Else
        modeLabel$ = "AVG " + LTrim$(Str$(historyCount)) + "/" + LTrim$(Str$(HISTORY_LEN)) + "s"
        toggleCaption$ = "Mode: Avg30"
    End If

    Dim tempVal!, unitLabel$, dialMin!, dialMax!, tempOk As Integer
    tempOk = (thermalZonePath <> "")
    If tempOk Then
        If tempUnitF Then
            tempVal! = CToF!(DisplayTempC!)
            unitLabel$ = "F"
            unitCaption$ = "Unit: F"
            dialMin! = 32: dialMax! = 212
        Else
            tempVal! = DisplayTempC!
            unitLabel$ = "C"
            unitCaption$ = "Unit: C"
            dialMin! = 0: dialMax! = 100
        End If
        _PrintString (16, 94), "Temp (" + modeLabel$ + "): " + FormatNum$(tempVal!, 1) + " " + unitLabel$ + "   (" + thermalZoneLabel + ")"
        If Button%(700, 90, 130, 22, unitCaption$) Then tempUnitF = 1 - tempUnitF
    Else
        _PrintString (16, 94), "Temp:       not available"
    End If

    Color _RGB32(120, 120, 120)
    _PrintString (16, 118), String$(100, "-")

    ' --- Gauge row: ring (load), dial (temp), sparkline (load trend) ---
    RingGauge 130, 235, 85, 64, DisplayLoad!(0), "LOAD (" + modeLabel$ + ")"
    If tempOk Then
        DialGauge 350, 235, 85, tempVal!, dialMin!, dialMax!, unitLabel$, "TEMP (" + modeLabel$ + ")"
    End If
    Sparkline 560, 150, 300, 140, sparkVals(), sparkCount, 0, 100, "LOAD TREND (30s)"

    Color _RGB32(120, 120, 120)
    _PrintString (16, 360), String$(100, "-")

    Color _RGB32(200, 200, 200)
    _PrintString (16, 378), "PER-CORE LOAD:"
    If Button%(_Width / 2, 90, 192, 26, toggleCaption$) Then displayMode = 1 - displayMode

    Dim idx As Integer, col As Integer, row As Integer
    Dim baseX As Integer, baseY As Integer
    Dim barW As Integer
    barW = 260
    For idx = 1 To coreCount
        col = (idx - 1) Mod 2
        row = (idx - 1) \ 2
        baseX = 16 + col * 440
        baseY = 396 + row * 26

        If baseY < 630 Then
            Color _RGB32(180, 180, 180)
            _PrintString (baseX, baseY), "core" + Right$("  " + LTrim$(Str$(idx - 1)), 3) + ":"
            HBar baseX + 60, baseY + 2, barW, 12, DisplayLoad!(idx)
            Color _RGB32(200, 200, 200)
            _PrintString (baseX + 60 + barW + 10, baseY), FormatNum$(DisplayLoad!(idx), 0) + "%"
        End If
    Next idx

    Color _RGB32(90, 90, 90)
    _PrintString (16, 612), "ESC/Quit to quit  |  A key or Mode button: live/30s avg  |  Unit button: C/F"
    _Display
End Sub

Function FormatNum$ (v As Single, decimals As Integer)
    Dim s$
    s$ = Str$(Fix(v * (10 ^ decimals) + 0.5) / (10 ^ decimals))
    FormatNum$ = LTrim$(s$)
End Function

'$Include:'ButtonUI.bm'
'$Include:'GaugeUI.bm'
