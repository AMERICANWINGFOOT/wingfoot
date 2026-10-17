'==================================================================
' LinabenchCLI v1.4 - headless Linabench for terminals and SSH
' Same kernel and scoring as Linabench.bas; needs linabench.h in
' the same folder. No window, so it runs with no X display.
'
' Usage:  ./LinabenchCLI          multi-core run, all threads
'         ./LinabenchCLI -m 8     multi-core run with 8 threads
'         ./LinabenchCLI -s       single-core run
'         ./LinabenchCLI -w       thread scaling sweep
'         ./LinabenchCLI -h       this help
'
' Results are appended to linabench_results.csv, same format as
' the GUI, so both can share one file.
'==================================================================
$Console:Only
Option _Explicit

Declare Library "./linabench"
    Function lb_start& (ByVal buf As _Offset, ByVal threads As Long)
    Function lb_finish# ()
    Function lb_is_done& ()
    Function lb_tiles_done& ()
    Function lb_tiles_total& ()
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

Const LBVER$ = "1.4"

Dim Shared m As _MEM
Dim Shared cpuName$, hostName$, gov$
Dim Shared runPeak#, mhzSum#, mhzN&

Dim args$, a$, md$, nCpu&, thr&, t&, n%, i%, sc#, one#
Dim thrList&(1 To 12)

m = _MemNew(lb_width& * lb_height& * 4)
cpuName$ = lb_cpu_model$
hostName$ = lb_hostname$
gov$ = lb_governor$
nCpu& = lb_cpu_count&

args$ = LCase$(_Trim$(Command$))
md$ = "multi"
thr& = nCpu&
Select Case Left$(args$, 2)
    Case "-h", "--"
        Print "LinabenchCLI v" + LBVER$
        Print "  (no args)  multi-core run, all threads"
        Print "  -m N       multi-core run with N threads"
        Print "  -s         single-core run"
        Print "  -w         thread scaling sweep"
        _MemFree m
        System
    Case "-s"
        md$ = "single"
        thr& = 1
    Case "-w"
        md$ = "sweep"
    Case "-m"
        a$ = _Trim$(Mid$(args$, 3))
        If Len(a$) > 0 Then thr& = Val(a$)
        If thr& < 1 Then thr& = nCpu&
End Select

Print "Linabench v" + LBVER$ + " (CLI)"
Print "CPU      : " + cpuName$
Print "Host     : " + hostName$
Print "Threads  : " + LTrim$(Str$(nCpu&)) + " logical"
Print "Freq     : " + lb_freq_driver$ + " / " + gov$
Print

If lb_lock& = 0 Then
    Print "BUSY: another Linabench (GUI or CLI) is benchmarking on this machine."
    _MemFree m
    System
End If

If md$ = "sweep" Then
    n% = 0
    t& = 1
    Do While t& < nCpu&
        n% = n% + 1
        thrList&(n%) = t&
        t& = t& * 2
    Loop
    n% = n% + 1
    thrList&(n%) = nCpu&
    For i% = 1 To n%
        sc# = RunOne#(thrList&(i%), "sweep")
        If i% = 1 Then one# = sc#
    Next
    If one# > 0 Then
        Print
        Print "Scaling: " + LTrim$(Str$(nCpu&)) + " threads = " + F2$(sc# / one#) + "x one thread"
    End If
Else
    sc# = RunOne#(thr&, md$)
End If

lb_unlock
_MemFree m
System

'==================================================================
' One render; prints a dot per 5% and the result line, logs to CSV
Function RunOne# (thr&, md$)
    Dim got&, el#, sc#, nxt#, tmp#, mhz#, avg#, dots%, d%, ln$
    runPeak# = -1
    mhzSum# = 0
    mhzN& = 0
    got& = lb_start&(m.OFFSET, thr&)
    If got& = 0 Then
        Print "ERROR: could not start render threads"
        RunOne# = 0
        Exit Function
    End If
    Print RPad$(md$ + " x" + LTrim$(Str$(got&)), 12);
    Do Until lb_is_done&
        _Limit 20
        If lb_now# >= nxt# Then
            nxt# = lb_now# + 0.5
            tmp# = lb_cpu_temp#
            If tmp# > runPeak# Then runPeak# = tmp#
            mhz# = lb_cpu_mhz_top#(got&)
            If mhz# > 0 Then mhzSum# = mhzSum# + mhz#: mhzN& = mhzN& + 1
        End If
        d% = 20 * lb_tiles_done& / lb_tiles_total&
        Do While dots% < d%
            Print ".";
            dots% = dots% + 1
        Loop
    Loop
    el# = lb_finish#
    Do While dots% < 20
        Print ".";
        dots% = dots% + 1
    Loop
    sc# = lb_rays# / el# / 100000
    If mhzN& > 0 Then avg# = mhzSum# / mhzN& Else avg# = -1
    ln$ = " " + F2$(sc#) + " pts  " + F2$(el#) + " s"
    If avg# > 0 Then ln$ = ln$ + "  " + LTrim$(Str$(Int(avg#))) + " MHz"
    If runPeak# >= 0 Then ln$ = ln$ + "  " + F1$(runPeak#) + " C"
    Print ln$ + "  " + Hex$(lb_checksum~&)
    LogCsv md$, got&, sc#, el#, avg#, lb_checksum~&
    RunOne# = sc#
End Function

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
