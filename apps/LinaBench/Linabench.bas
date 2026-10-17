'==================================================================
' Linabench v1.4 - multi-threaded CPU render benchmark for Linux
' QB64-PE 4.5.0 front end + linabench.h (pthreads ray tracer)
' Keep linabench.h in the same folder as this file.
'
' Keys:  M = multi-core run     S = single-core run
'        L = 10-minute multi-core loop (thermal / sustained)
'        W = thread scaling sweep (1, 2, 4 ... all threads)
'        + / - = thread count for M and L
'        Esc = abort a run, or quit when idle
'
' The loop (L) draws score and temperature over the 10 minutes.
' For terminals / SSH use LinabenchCLI.bas (same kernel and scores).
' Only one Linabench (GUI or CLI) can benchmark at a time per machine.
' The MHz logged per run is the average of the N busiest cores for an
' N-thread run, so idle cores do not drag it down.
'
' Every finished run is appended to linabench_results.csv in the
' current folder, so one file can collect results from several boxes.
'
' Score = rays traced per second / 100000. Scores are only
' comparable between machines running the same Linabench version.
'==================================================================
Option _Explicit

Declare Library "./linabench"
    Function lb_start& (ByVal buf As _Offset, ByVal threads As Long)
    Function lb_finish# ()
    Function lb_is_done& ()
    Function lb_tiles_done& ()
    Function lb_tiles_total& ()
    Function lb_tiles_x& ()
    Function lb_tile_state& (ByVal i As Long)
    Function lb_elapsed# ()
    Function lb_rays# ()
    Function lb_cpu_count& ()
    Function lb_checksum~& ()
    Function lb_now# ()
    Function lb_width& ()
    Function lb_height& ()
    Function lb_cpu_model$ ()
    Function lb_cpu_temp# ()
    Function lb_cpu_mhz# ()
    Function lb_cpu_mhz_top# (ByVal top As Long)
    Function lb_lock& ()
    Sub lb_unlock ()
    Function lb_governor$ ()
    Function lb_freq_driver$ ()
    Function lb_hostname$ ()
End Declare

Const TILE = 32
Const RX = 10
Const RY = 10
Const PX = 985
Const LOOPSECS = 600
Const LBVER$ = "1.4"

Dim Shared scr&, rimg&, rw&, rh&
Dim Shared m As _MEM
Dim Shared runThr&
Dim Shared logs$(1 To 8)
Dim Shared cTxt~&, cHi~&, cDim~&, cBad~&
Dim Shared cpuName$, hostName$, gov$, drv$
Dim Shared runPeak#, mhzSum#, mhzN&

Dim nCpu&, nThr&, mode%, k$
Dim el#, rays#, score#, sum~&, avgMhz#
Dim multiScore#, singleScore#, multiSum~&, singleSum~&
Dim loopStart#, loopRuns&, loopMin#, loopMax#, remain#
Dim tempC#, tempMax#, curMhz#, runMhz#, sampleNext#
Dim status$, check$, govWarn%
Dim sweepThr&(1 To 12), sweepScore#(1 To 12), sweepN%, sweepIdx%, sweepMax#
Dim i&, j%, t&, tot&, ntx&, done&, x0&, y0&, x1&, y1&, bw&, yy&
Dim panelView%, loopT#(1 To 512), loopS#(1 To 512), tHist#(1 To 400), tHistN%, tHistNext#
Dim gx&, gy&, gw&, gh&, lo#, hi#, hN&

cTxt~& = _RGB32(215, 215, 220)
cHi~& = _RGB32(0, 190, 255)
cDim~& = _RGB32(120, 120, 130)
cBad~& = _RGB32(255, 90, 70)

rw& = lb_width&
rh& = lb_height&
scr& = _NewImage(1280, 720, 32)
Screen scr&
_FullScreen
_Title "Linabench v" + LBVER$
_PrintMode _KeepBackground
rimg& = _NewImage(rw&, rh&, 32)
m = _MemImage(rimg&)
_Dest rimg&: Cls , _RGB32(20, 20, 24): _Dest scr&

cpuName$ = lb_cpu_model$
hostName$ = lb_hostname$
nCpu& = lb_cpu_count&
nThr& = nCpu&
status$ = "Ready"
tempC# = lb_cpu_temp#
tempMax# = tempC#
curMhz# = lb_cpu_mhz#
gov$ = lb_governor$
drv$ = lb_freq_driver$

' intel_pstate / amd-pstate "powersave" is normal dynamic scaling.
' Under acpi-cpufreq or intel_cpufreq it really does pin clocks low.
govWarn% = (gov$ = "powersave" And drv$ <> "intel_pstate" And Left$(drv$, 9) <> "amd-pstat")
k$ = _CWD$
If Right$(k$, 1) <> "/" Then k$ = k$ + "/"
AddLog "Freq driver " + drv$ + ", governor " + gov$ + "   Results -> " + k$ + "linabench_results.csv"
If govWarn% Then AddLog "WARNING: this governor holds clocks low. Try: sudo cpupower frequency-set -g performance"

Do
    If mode% = 0 Then lb_unlock

    '---------------- input ----------------
    k$ = UCase$(InKey$)
    Select Case k$
        Case "M"
            If mode% = 0 Then StartRun nThr&: mode% = 1: status$ = "Multi-core run"
        Case "S"
            If mode% = 0 Then StartRun 1: mode% = 2: status$ = "Single-core run"
        Case "L"
            If mode% = 0 Then
                loopStart# = lb_now#
                loopRuns& = 0
                tHistN% = 0
                tHistNext# = loopStart#
                panelView% = 2
                StartRun nThr&
                mode% = 3
                status$ = "10-minute loop"
                AddLog "Loop started, " + LTrim$(Str$(nThr&)) + " threads"
            End If
        Case "W"
            If mode% = 0 Then
                sweepN% = 0
                t& = 1
                Do While t& < nCpu&
                    sweepN% = sweepN% + 1
                    sweepThr&(sweepN%) = t&
                    t& = t& * 2
                Loop
                sweepN% = sweepN% + 1
                sweepThr&(sweepN%) = nCpu&
                For j% = 1 To sweepN%
                    sweepScore#(j%) = 0
                Next
                sweepIdx% = 1
                panelView% = 1
                StartRun sweepThr&(1)
                mode% = 4
                status$ = "Scaling sweep"
                AddLog "Sweep started: " + LTrim$(Str$(sweepN%)) + " steps"
            End If
        Case "+", "="
            If mode% = 0 And nThr& < 256 Then nThr& = nThr& + 1
        Case "-", "_"
            If mode% = 0 And nThr& > 1 Then nThr& = nThr& - 1
        Case Chr$(27)
            If mode% <> 0 Then
                el# = lb_finish#
                mode% = 0
                status$ = "Aborted"
                AddLog "Run aborted at " + F2$(el#) + " s (not logged)"
            Else
                Exit Do
            End If
    End Select

    '---------------- run bookkeeping ----------------
    If mode% <> 0 And runThr& = 0 Then mode% = 0: status$ = "Not started"
    If mode% <> 0 Then
        If lb_is_done& Then
            el# = lb_finish#
            rays# = lb_rays#
            score# = rays# / el# / 100000
            sum~& = lb_checksum~&
            If mhzN& > 0 Then avgMhz# = mhzSum# / mhzN& Else avgMhz# = -1
            Select Case mode%
                Case 1
                    multiScore# = score#
                    multiSum~& = sum~&
                    AddLog "Multi  x" + LTrim$(Str$(runThr&)) + "  " + F2$(score#) + " pts  " + F2$(el#) + " s" + ClkTxt$(avgMhz#) + "  " + Hex$(sum~&)
                    LogCsv "multi", runThr&, score#, el#, avgMhz#, sum~&
                    mode% = 0
                    status$ = "Done"
                Case 2
                    singleScore# = score#
                    singleSum~& = sum~&
                    AddLog "Single x1  " + F2$(score#) + " pts  " + F2$(el#) + " s" + ClkTxt$(avgMhz#) + "  " + Hex$(sum~&)
                    LogCsv "single", 1, score#, el#, avgMhz#, sum~&
                    mode% = 0
                    status$ = "Done"
                Case 3
                    loopRuns& = loopRuns& + 1
                    If loopRuns& = 1 Or score# < loopMin# Then loopMin# = score#
                    If loopRuns& = 1 Or score# > loopMax# Then loopMax# = score#
                    If loopRuns& <= 512 Then
                        loopT#(loopRuns&) = lb_now# - loopStart#
                        loopS#(loopRuns&) = score#
                    End If
                    AddLog "Loop #" + LTrim$(Str$(loopRuns&)) + "  " + F2$(score#) + " pts  " + F2$(el#) + " s" + ClkTxt$(avgMhz#)
                    LogCsv "loop", runThr&, score#, el#, avgMhz#, sum~&
                    If lb_now# - loopStart# < LOOPSECS Then
                        StartRun nThr&
                    Else
                        multiScore# = score#
                        multiSum~& = sum~&
                        AddLog "Loop done: " + LTrim$(Str$(loopRuns&)) + " runs, min " + F2$(loopMin#) + " max " + F2$(loopMax#) + "  drop " + F1$((loopMax# - loopMin#) / loopMax# * 100) + "%"
                        mode% = 0
                        status$ = "Loop done"
                    End If
                Case 4
                    sweepScore#(sweepIdx%) = score#
                    If sweepThr&(sweepIdx%) = 1 Then singleScore# = score#: singleSum~& = sum~&
                    If sweepThr&(sweepIdx%) = nCpu& Then multiScore# = score#: multiSum~& = sum~&
                    AddLog "Sweep x" + LTrim$(Str$(runThr&)) + "  " + F2$(score#) + " pts  " + F2$(el#) + " s" + ClkTxt$(avgMhz#)
                    LogCsv "sweep", runThr&, score#, el#, avgMhz#, sum~&
                    If sweepIdx% < sweepN% Then
                        sweepIdx% = sweepIdx% + 1
                        StartRun sweepThr&(sweepIdx%)
                    Else
                        AddLog "Sweep done: " + LTrim$(Str$(nCpu&)) + " threads = " + F2$(score# / sweepScore#(1)) + "x one thread"
                        mode% = 0
                        status$ = "Sweep done"
                    End If
            End Select
        End If
    End If

    '---------------- sensors, twice a second ----------------
    If lb_now# >= sampleNext# Then
        sampleNext# = lb_now# + 0.5
        tempC# = lb_cpu_temp#
        If tempC# > tempMax# Then tempMax# = tempC#
        curMhz# = lb_cpu_mhz#
        If mode% <> 0 Then
            If tempC# > runPeak# Then runPeak# = tempC#
            runMhz# = lb_cpu_mhz_top#(runThr&)
            If runMhz# > 0 Then mhzSum# = mhzSum# + runMhz#: mhzN& = mhzN& + 1
        End If
    End If
    If mode% = 3 And lb_now# >= tHistNext# And tHistN% < 400 Then
        tHistNext# = tHistNext# + 2
        tHistN% = tHistN% + 1
        tHist#(tHistN%) = tempC#
    End If

    '---------------- draw ----------------
    Cls , _RGB32(12, 12, 14)
    _PutImage (RX, RY), rimg&, scr&
    Line (RX - 1, RY - 1)-(RX + rw&, RY + rh&), _RGB32(70, 70, 80), B

    tot& = lb_tiles_total&
    done& = 0
    If mode% <> 0 Then
        ntx& = lb_tiles_x&
        For i& = 0 To tot& - 1
            If lb_tile_state&(i&) = 1 Then
                x0& = (i& Mod ntx&) * TILE
                y0& = (i& \ ntx&) * TILE
                x1& = x0& + TILE - 1: If x1& > rw& - 1 Then x1& = rw& - 1
                y1& = y0& + TILE - 1: If y1& > rh& - 1 Then y1& = rh& - 1
                Line (RX + x0&, RY + y0&)-(RX + x1&, RY + y1&), _RGB32(255, 210, 0), B
            End If
        Next
        done& = lb_tiles_done&
    End If

    Line (RX, 560)-(RX + rw& - 1, 576), _RGB32(40, 40, 48), BF
    If done& > 0 Then Line (RX, 560)-(RX + (rw& - 1) * done& / tot&, 576), cHi~&, BF

    For i& = 1 To 8
        Color cTxt~&
        _PrintString (RX, 588 + (i& - 1) * 16), logs$(i&)
    Next

    PT 0, "LINABENCH v" + LBVER$, cHi~&
    PT 1, Left$(cpuName$, 36), cTxt~&
    PT 2, "Host         : " + Left$(hostName$, 21), cTxt~&
    PT 3, "Logical CPUs : " + LTrim$(Str$(nCpu&)), cTxt~&
    PT 4, "Threads (M/L): " + LTrim$(Str$(nThr&)) + "  [+/-]", cTxt~&
    If tempC# >= 0 Then PT 5, "CPU temp     : " + F1$(tempC#) + " C (max " + F1$(tempMax#) + ")", cTxt~& Else PT 5, "CPU temp     : n/a", cDim~&
    If curMhz# > 0 Then PT 6, "CPU clock    : " + LTrim$(Str$(Int(curMhz#))) + " MHz avg", cTxt~& Else PT 6, "CPU clock    : n/a", cDim~&
    If govWarn% Then PT 7, "Governor     : " + gov$ + " (!)", cBad~& Else PT 7, "Governor     : " + gov$, cTxt~&
    PT 8, "Status       : " + status$, cTxt~&
    If mode% <> 0 Then
        PT 9, "Elapsed      : " + F1$(lb_elapsed#) + " s", cTxt~&
        PT 10, "Tiles        : " + LTrim$(Str$(done&)) + " / " + LTrim$(Str$(tot&)), cTxt~&
        If mhzN& > 0 Then PT 11, "Run clock    : " + LTrim$(Str$(Int(mhzSum# / mhzN&))) + " MHz (top " + LTrim$(Str$(runThr&)) + ")", cTxt~&
    End If

    PT 13, "Multi-core   : " + ScoreTxt$(multiScore#), cTxt~&
    PT 14, "Single-core  : " + ScoreTxt$(singleScore#), cTxt~&
    If multiScore# > 0 And singleScore# > 0 Then
        PT 15, "MP ratio     : " + F2$(multiScore# / singleScore#) + "x", cTxt~&
    Else
        PT 15, "MP ratio     : --", cDim~&
    End If

    check$ = "--"
    If multiSum~& <> 0 And singleSum~& <> 0 Then
        If multiSum~& = singleSum~& Then check$ = "OK (images match)" Else check$ = "MISMATCH"
    End If
    If check$ = "MISMATCH" Then PT 16, "Image check  : " + check$, cBad~& Else PT 16, "Image check  : " + check$, cTxt~&

    If mode% = 3 Then
        remain# = LOOPSECS - (lb_now# - loopStart#)
        If remain# < 0 Then remain# = 0
        PT 18, "Loop run #" + LTrim$(Str$(loopRuns& + 1)) + "  " + LTrim$(Str$(Int(remain#))) + " s left", cHi~&
        If loopRuns& > 0 Then PT 19, "Min " + F2$(loopMin#) + "  Max " + F2$(loopMax#), cTxt~&
    End If

    '---------------- scaling sweep table ----------------
    If sweepN% > 0 And panelView% = 1 Then
        PT 21, "Threads  Score    Scale", cHi~&
        sweepMax# = 0
        For j% = 1 To sweepN%
            If sweepScore#(j%) > sweepMax# Then sweepMax# = sweepScore#(j%)
        Next
        For j% = 1 To sweepN%
            yy& = 10 + (21 + j%) * 18
            If sweepScore#(j%) > 0 Then
                PT 21 + j%, RPad$(LTrim$(Str$(sweepThr&(j%))), 9) + RPad$(F2$(sweepScore#(j%)), 9) + F2$(sweepScore#(j%) / sweepScore#(1)) + "x", cTxt~&
                bw& = 80 * sweepScore#(j%) / sweepMax#
                Line (PX + 205, yy& + 3)-(PX + 205 + bw&, yy& + 11), cHi~&, BF
            ElseIf mode% = 4 And j% = sweepIdx% Then
                PT 21 + j%, RPad$(LTrim$(Str$(sweepThr&(j%))), 9) + "running...", cDim~&
            End If
        Next
    End If

    '---------------- loop graph: score and temp vs time ----------------
    If panelView% = 2 And (loopRuns& > 0 Or tHistN% > 1) Then
        gx& = PX: gy& = 412: gw& = 280: gh& = 140
        PT 21, "Score", cHi~&
        PT 21, Space$(7) + "Temp (20-100 C)", _RGB32(255, 150, 40)
        Line (gx&, gy&)-(gx& + gw&, gy& + gh&), _RGB32(26, 26, 32), BF
        Line (gx&, gy&)-(gx& + gw&, gy& + gh&), _RGB32(70, 70, 80), B
        hN& = loopRuns&
        If hN& > 512 Then hN& = 512
        If hN& > 1 Then
            lo# = loopMin# * 0.95
            hi# = loopMax# * 1.02
            For j% = 2 To hN&
                x0& = gx& + gw& * loopT#(j% - 1) / LOOPSECS
                x1& = gx& + gw& * loopT#(j%) / LOOPSECS
                If x1& > gx& + gw& Then x1& = gx& + gw&
                y0& = gy& + gh& - gh& * (loopS#(j% - 1) - lo#) / (hi# - lo#)
                y1& = gy& + gh& - gh& * (loopS#(j%) - lo#) / (hi# - lo#)
                Line (x0&, y0&)-(x1&, y1&), cHi~&
            Next
        End If
        If tHistN% > 1 And tHist#(1) >= 0 Then
            For j% = 2 To tHistN%
                x0& = gx& + gw& * (j% - 2) * 2 / LOOPSECS
                x1& = gx& + gw& * (j% - 1) * 2 / LOOPSECS
                If x1& > gx& + gw& Then x1& = gx& + gw&
                y0& = gy& + gh& - gh& * (_Clamp(tHist#(j% - 1), 20, 100) - 20) / 80
                y1& = gy& + gh& - gh& * (_Clamp(tHist#(j%), 20, 100) - 20) / 80
                Line (x0&, y0&)-(x1&, y1&), _RGB32(255, 150, 40)
            Next
        End If
        If loopRuns& > 0 Then PT 31, "Score " + F2$(loopMin#) + "-" + F2$(loopMax#) + "  peak " + F1$(tempMax#) + " C", cTxt~&
    End If

    PT 33, "M  multi-core run", cDim~&
    PT 34, "S  single-core run", cDim~&
    PT 35, "L  10-minute loop", cDim~&
    PT 36, "W  thread scaling sweep", cDim~&
    PT 37, "+/- thread count", cDim~&
    PT 38, "Esc abort / quit", cDim~&

    _Display
    _Limit 30
Loop

If mode% <> 0 Then el# = lb_finish#
lb_unlock
_MemFree m
System

'==================================================================
Sub StartRun (thr&)
    If lb_lock& = 0 Then
        AddLog "BUSY: another Linabench (GUI or CLI) is benchmarking on this machine"
        runThr& = 0
        Exit Sub
    End If
    _Dest rimg&: Cls , _RGB32(20, 20, 24): _Dest scr&
    runPeak# = -1
    mhzSum# = 0
    mhzN& = 0
    runThr& = lb_start&(m.OFFSET, thr&)
    If runThr& = 0 Then AddLog "ERROR: could not start render threads"
End Sub

' Append one finished run to linabench_results.csv (header on first use)
Sub LogCsv (md$, thr&, sc#, secs#, mhz#, sum~&)
    Dim ff&, fn$, isNew%, d$, ln$, cpu$, i%
    fn$ = "linabench_results.csv"
    isNew% = (_FileExists(fn$) = 0)
    cpu$ = cpuName$
    For i% = 1 To Len(cpu$)
        If Mid$(cpu$, i%, 1) = "," Then Mid$(cpu$, i%, 1) = " "
    Next
    d$ = Date$
    ln$ = Mid$(d$, 7, 4) + "-" + Left$(d$, 2) + "-" + Mid$(d$, 4, 2) + "," + Time$ + "," + hostName$ + "," + cpu$ + "," + LBVER$ + "," + md$ + ","
    ln$ = ln$ + LTrim$(Str$(thr&)) + "," + F2$(sc#) + "," + F2$(secs#) + ","
    If mhz# > 0 Then ln$ = ln$ + LTrim$(Str$(Int(mhz#)))
    ln$ = ln$ + ","
    If runPeak# >= 0 Then ln$ = ln$ + F1$(runPeak#)
    ln$ = ln$ + "," + gov$ + "," + Hex$(sum~&)
    ff& = FreeFile
    Open fn$ For Append As #ff&
    If isNew% Then Print #ff&, "date,time,host,cpu,version,mode,threads,score,seconds,avg_mhz,peak_temp_c,governor,checksum"
    Print #ff&, ln$
    Close #ff&
End Sub

Sub AddLog (s$)
    Dim i%
    For i% = 1 To 7: logs$(i%) = logs$(i% + 1): Next
    logs$(8) = s$
End Sub

Sub PT (row%, txt$, clr~&)
    Color clr~&
    _PrintString (PX, 10 + row% * 18), txt$
End Sub

Function ScoreTxt$ (v#)
    If v# > 0 Then ScoreTxt$ = F2$(v#) + " pts" Else ScoreTxt$ = "--"
End Function

Function ClkTxt$ (v#)
    If v# > 0 Then ClkTxt$ = "  " + LTrim$(Str$(Int(v#))) + " MHz" Else ClkTxt$ = ""
End Function

Function RPad$ (s$, n%)
    RPad$ = Left$(s$ + Space$(n%), n%)
End Function

Function F2$ (v#)
    F2$ = FixD$(v#, 2)
End Function

Function F1$ (v#)
    F1$ = FixD$(v#, 1)
End Function

' fixed decimals, trailing zeros kept: FixD$(6, 2) = "6.00"
Function FixD$ (v#, d%)
    Dim sc#, t#, w#, f#, s$, neg%
    sc# = 10 ^ d%
    neg% = (v# < 0)
    t# = Int(Abs(v#) * sc# + 0.5)
    w# = Int(t# / sc#)
    f# = t# - w# * sc#
    s$ = LTrim$(Str$(w#))
    If d% > 0 Then s$ = s$ + "." + Right$(String$(d%, "0") + LTrim$(Str$(f#)), d%)
    If neg% Then s$ = "-" + s$
    FixD$ = s$
End Function
