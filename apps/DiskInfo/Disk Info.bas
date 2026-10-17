'=======================================================================
' DiskInfo.bas  -  Linux disk drive information / monitor  (rewrite v2)
' QB64-PE 4.5.0  -  uses ButtonUI and GaugeUI (keep all files together)
'
' DATA SOURCES
'   lsblk -b -r           drives, partitions, fs size/used, mounts
'                         (partition usage rolls up to the parent disk)
'   /proc/diskstats       live read / write throughput, 1 s deltas
'   sudo -n smartctl      SMART health, temp, hours, error counters -
'                         runs in the BACKGROUND so the UI never stalls
'
' Internal drives only: USB and removable drives are skipped, and
' smartctl is only ever run on the drives shown.
'
' SMART needs root. Add a scoped rule with  sudo visudo :
'     russell ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
' Without it the SMART fields just read NO PERMISSION.
'
' CONDITION LINE
'   HDD / SATA SSD : Realloc (5)  Pending (197)  Uncorr (198)  CRC (199)
'                    Life = normalized 177/202/231/233 on SSDs
'   NVMe           : Media err, Warn (critical warning), Wear % used, Spare
'   Shown red if any error count is nonzero or wear / spare is critical.
'
' KEYS   Tab = next drive   R = refresh SMART   Esc = quit
'=======================================================================
'$Include:'ButtonUI.bi'
'$Include:'GaugeUI.bi'

Const MAXDRV = 16
Const MAXPART = 64
Const HISTLEN = 60
Const MAXPROWS = 8

' --- drives (parallel arrays, 1..drvCount) ---
Dim Shared drvCount As Integer
Dim Shared drvName$(1 To MAXDRV), drvModel$(1 To MAXDRV), drvSerial$(1 To MAXDRV), drvTran$(1 To MAXDRV)
Dim Shared drvRota(1 To MAXDRV) As Integer
Dim Shared drvSize(1 To MAXDRV) As _Integer64
Dim Shared drvFsSize(1 To MAXDRV) As _Integer64
Dim Shared drvFsUsed(1 To MAXDRV) As _Integer64
Dim Shared drvSig$

' --- partitions / child devices (1..partCount) ---
Dim Shared partCount As Integer
Dim Shared partDrv(1 To MAXPART) As Integer
Dim Shared partDepth(1 To MAXPART) As Integer
Dim Shared partName$(1 To MAXPART), partFs$(1 To MAXPART), partMount$(1 To MAXPART)
Dim Shared partSize(1 To MAXPART) As _Integer64
Dim Shared partFsSize(1 To MAXPART) As _Integer64
Dim Shared partFsUsed(1 To MAXPART) As _Integer64

' --- SMART (smTemp -999 = unknown, all counters -1 = unknown) ---
Dim Shared smStatus$(1 To MAXDRV), smHealth$(1 To MAXDRV), smExtra$(1 To MAXDRV)
Dim Shared smTemp(1 To MAXDRV) As Single
Dim Shared smHours(1 To MAXDRV) As Long
Dim Shared smRealloc(1 To MAXDRV) As Long
Dim Shared smPendSec(1 To MAXDRV) As Long
Dim Shared smUncorr(1 To MAXDRV) As Long
Dim Shared smCrc(1 To MAXDRV) As Long
Dim Shared smLife(1 To MAXDRV) As Long
Dim Shared smUsedPct(1 To MAXDRV) As Long
Dim Shared smSpare(1 To MAXDRV) As Long
Dim Shared smMediaErr(1 To MAXDRV) As Long
Dim Shared smCritWarn(1 To MAXDRV) As Long
Dim Shared smCondBad(1 To MAXDRV) As Integer
Dim Shared smPending As Integer
Dim Shared smStart As Double

' --- throughput (bytes per second) and history ---
Dim Shared prevRd(1 To MAXDRV) As _Integer64
Dim Shared prevWr(1 To MAXDRV) As _Integer64
Dim Shared ioPrimed(1 To MAXDRV) As Integer
Dim Shared rdRate(1 To MAXDRV) As Double
Dim Shared wrRate(1 To MAXDRV) As Double
Dim Shared rdHist(1 To MAXDRV, 0 To HISTLEN - 1) As Single
Dim Shared wrHist(1 To MAXDRV, 0 To HISTLEN - 1) As Single
Dim Shared histPos As Integer, histFill As Integer
Dim Shared sparkR(0 To HISTLEN - 1) As Single
Dim Shared sparkW(0 To HISTLEN - 1) As Single
Dim Shared sparkPeakR As Single, sparkPeakW As Single

' --- line tokenizer ---
Dim Shared tok$(1 To 40)
Dim Shared tokN As Integer

' --- settings / theme ---
Dim Shared useGiB As Integer, useF As Integer, sel As Integer
Dim Shared cBg As _Unsigned Long, cLbl As _Unsigned Long, cVal As _Unsigned Long
Dim Shared cHead As _Unsigned Long, cGood As _Unsigned Long, cBad As _Unsigned Long, cWarn As _Unsigned Long

Dim i As Integer, bx As Integer, bw As Integer
Dim k$, s$
Dim tnow As Double, tStat As Double, tLs As Double, tSm As Double

Screen _NewImage(900, 640, 32)
_FullScreen , _Smooth
_Title "Disk Info"
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

sel = 1
ReadLsblk
SampleDiskStats 0
tnow = Timer: tStat = tnow: tLs = tnow: tSm = tnow

Do
    _Limit 30
    PollMouse
    k$ = InKey$
    If k$ = Chr$(27) Then Exit Do
    If k$ = Chr$(9) And drvCount > 0 Then sel = (sel Mod drvCount) + 1
    If LCase$(k$) = "r" Then StartSmart: tSm = tnow

    ' ---- timed work ----
    tnow = Timer
    If tnow < tStat Then tStat = tnow: tLs = tnow: tSm = tnow
    If tnow - tStat >= 1 Then
        SampleDiskStats tnow - tStat
        tStat = tnow
    End If
    If tnow - tLs >= 15 Then ReadLsblk: tLs = tnow
    If tnow - tSm >= 60 Then StartSmart: tSm = tnow
    If smPending Then
        If _FileExists("/tmp/qb64_diskinfo_smart.tmp") Then
            ParseSmart
        ElseIf Abs(tnow - smStart) > 30 Then
            smPending = 0
            For i = 1 To drvCount
                If smStatus$(i) = "waiting" Then smStatus$(i) = "TIMEOUT"
            Next
        End If
    End If
    If sel > drvCount Then sel = 1

    ' ---- draw ----
    Cls , cBg
    Txt 20, 10, cHead, "DISK INFO"
    Txt 110, 10, cLbl, "internal drives    Tab: next drive    R: refresh SMART    Esc: quit"

    ' drive buttons shrink to fit when there are more than 8
    bw = 100
    If drvCount > 8 Then bw = 860 \ drvCount - 8
    For i = 1 To drvCount
        bx = 20 + (i - 1) * (bw + 8)
        If ButtonEx%(bx, 32, bw, 28, drvName$(i), (i <> sel)) Then sel = i
    Next

    If drvCount = 0 Then
        Txt 20, 90, cWarn, "No internal drives found."
    Else
        DrawDetails sel
    End If

    If useGiB Then s$ = "Units: GiB" Else s$ = "Units: GB"
    If Button%(20, 596, 130, 32, s$) Then useGiB = Not useGiB
    If useF Then s$ = "Temp: " + Chr$(248) + "F" Else s$ = "Temp: " + Chr$(248) + "C"
    If Button%(160, 596, 110, 32, s$) Then useF = Not useF
    If ButtonEx%(280, 596, 150, 32, "Refresh SMART", (smPending = 0)) Then StartSmart: tSm = tnow
    If smPending Then Txt 444, 604, cWarn, "Reading SMART..."
    If Button%(780, 596, 100, 32, "Quit") Then Exit Do

    _Display
Loop
CleanupTemp
System


'=======================================================================
' DRAWING
'=======================================================================

Sub DrawDetails (d As Integer)
    Dim y As Integer, p As Integer, r As Integer, extra As Integer
    Dim s$, u$, pct As Single, tv As Single, mnT As Single, mxT As Single
    Dim rMax As Single, wMax As Single
    Dim hc As _Unsigned Long

    ' ---- info column ----
    y = 76
    KV y, "Model", Left$(drvModel$(d), 40), cVal
    KV y, "Serial", Left$(drvSerial$(d), 40), cVal
    KV y, "Type", DriveKind$(d), cVal
    KV y, "Capacity", FmtBytes$(drvSize(d)), cVal
    If drvFsSize(d) > 0 Then
        pct = drvFsUsed(d) / drvFsSize(d) * 100
        s$ = FmtBytes$(drvFsUsed(d)) + " of " + FmtBytes$(drvFsSize(d)) + "  (" + Fix1$((pct)) + "%)"
    Else
        pct = 0
        s$ = "no mounted filesystems"
    End If
    KV y, "Used", s$, cVal
    KV y, "Read", FmtRate$(rdRate(d)), cVal
    KV y, "Write", FmtRate$(wrRate(d)), cVal

    If smStatus$(d) = "OK" Then hc = cGood Else hc = cWarn
    KV y, "SMART", smStatus$(d), hc
    If smHealth$(d) = "PASSED" Then
        hc = cGood
    ElseIf smHealth$(d) = "--" Then
        hc = cVal
    Else
        hc = cBad
    End If
    KV y, "Health", smHealth$(d), hc
    KV y, "Temperature", FmtTemp$(smTemp(d)), cVal
    If smHours(d) >= 0 Then
        s$ = LTrim$(Str$(smHours(d))) + " h  (" + LTrim$(Str$(smHours(d) \ 24)) + " days)"
    Else
        s$ = "--"
    End If
    KV y, "Power-on", s$, cVal
    If smCondBad(d) Then
        hc = cBad
    ElseIf smExtra$(d) = "--" Then
        hc = cVal
    Else
        hc = cGood
    End If
    KV y, "Condition", smExtra$(d), hc

    ' ---- gauges ----
    RingGauge 580, 170, 88, 60, (pct), "Space used"
    If smTemp(d) > -999 Then
        If useF Then
            tv = smTemp(d) * 9 / 5 + 32: mnT = 32: mxT = 176: u$ = Chr$(248) + "F"
        Else
            tv = smTemp(d): mnT = 0: mxT = 80: u$ = Chr$(248) + "C"
        End If
        DialGauge 790, 170, 88, (tv), (mnT), (mxT), u$, "Drive temp"
    Else
        Circle (790, 170), 88, cLbl
        Txt 778, 162, cLbl, "N/A"
    End If

    ' ---- partition table ----
    y = 296
    Txt 20, y, cHead, "PARTITION"
    Txt 170, y, cHead, "FS"
    Txt 260, y, cHead, "SIZE"
    Txt 350, y, cHead, "USED"
    Txt 570, y, cHead, "MOUNT"
    y = y + 20
    r = 0: extra = 0
    For p = 1 To partCount
        If partDrv(p) = d Then
            If r < MAXPROWS Then
                Txt 20 + (partDepth(p) - 1) * 16, y, cVal, Left$(partName$(p), 18 - partDepth(p) * 2)
                Txt 170, y, cVal, Left$(partFs$(p), 10)
                Txt 260, y, cVal, FmtBytes$(partSize(p))
                If partFsSize(p) > 0 Then
                    pct = partFsUsed(p) / partFsSize(p) * 100
                    HBar 350, y + 2, 100, 12, (pct)
                    Txt 460, y, cVal, Fix1$((pct)) + "%"
                Else
                    Txt 350, y, cLbl, "-"
                End If
                Txt 570, y, cVal, Left$(partMount$(p), 38)
                y = y + 18
                r = r + 1
            Else
                extra = extra + 1
            End If
        End If
    Next
    If r = 0 Then Txt 20, y, cLbl, "(no partitions)"
    If extra > 0 Then Txt 20, y, cLbl, "+" + LTrim$(Str$(extra)) + " more"

    ' ---- throughput sparklines ----
    BuildSpark d
    If useGiB Then u$ = " MiB/s" Else u$ = " MB/s"
    rMax = sparkPeakR * 1.15: If rMax < 1 Then rMax = 1
    wMax = sparkPeakW * 1.15: If wMax < 1 Then wMax = 1
    Sparkline 20, 500, 410, 72, sparkR(), histFill, 0, (rMax), "Read " + FmtRate$(rdRate(d)) + "   peak " + Fix1$((sparkPeakR)) + u$
    Sparkline 470, 500, 410, 72, sparkW(), histFill, 0, (wMax), "Write " + FmtRate$(wrRate(d)) + "   peak " + Fix1$((sparkPeakW)) + u$
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
    ' unwrap the circular history for drive d into chronological
    ' sparkR/sparkW, scaled to MB/s (or MiB/s)
    Dim i As Integer, src As Integer, startIx As Integer, dv As Double
    If useGiB Then dv = 1048576 Else dv = 1000000
    sparkPeakR = 0: sparkPeakW = 0
    startIx = (histPos - histFill + HISTLEN) Mod HISTLEN
    For i = 0 To histFill - 1
        src = (startIx + i) Mod HISTLEN
        sparkR(i) = rdHist(d, src) / dv
        sparkW(i) = wrHist(d, src) / dv
        If sparkR(i) > sparkPeakR Then sparkPeakR = sparkR(i)
        If sparkW(i) > sparkPeakW Then sparkPeakW = sparkW(i)
    Next
End Sub


'=======================================================================
' DATA: lsblk  (drives + partitions + usage, one call)
'=======================================================================

Sub ReadLsblk
    ' Columns: 1 NAME  2 PKNAME  3 TYPE  4 SIZE  5 ROTA  6 TRAN  7 RM
    '          8 FSTYPE  9 FSSIZE  10 FSUSED  11 MOUNTPOINT  12 MODEL  13 SERIAL
    ' Raw mode (-r) escapes spaces as \x20, so single-space splitting is
    ' safe and empty fields stay in position.
    Dim fh As Integer, ln$, nm$, pk$, typ$, sig$
    Dim d As Integer, p As Integer, i As Integer

    ' kill first so a failed lsblk can't leave stale data to be re-read
    If _FileExists("/tmp/qb64_diskinfo_lsblk.tmp") Then Kill "/tmp/qb64_diskinfo_lsblk.tmp"
    Shell _Hide "lsblk -b -n -r -o NAME,PKNAME,TYPE,SIZE,ROTA,TRAN,RM,FSTYPE,FSSIZE,FSUSED,MOUNTPOINT,MODEL,SERIAL > /tmp/qb64_diskinfo_lsblk.tmp 2>/dev/null"
    If Not _FileExists("/tmp/qb64_diskinfo_lsblk.tmp") Then Exit Sub

    drvCount = 0: partCount = 0: sig$ = ""
    fh = FreeFile
    Open "/tmp/qb64_diskinfo_lsblk.tmp" For Input As #fh
    Do While Not EOF(fh)
        Line Input #fh, ln$
        SplitRaw ln$
        If tokN >= 11 Then
            nm$ = tok$(1): pk$ = tok$(2): typ$ = tok$(3)
            If typ$ = "disk" Then
                If DriveWanted%(nm$, tok$(6), tok$(7)) And drvCount < MAXDRV Then
                    drvCount = drvCount + 1
                    d = drvCount
                    drvName$(d) = nm$
                    drvSize(d) = Val(tok$(4))
                    drvRota(d) = Val(tok$(5))
                    drvTran$(d) = tok$(6)
                    drvModel$(d) = "": drvSerial$(d) = ""
                    If tokN >= 12 Then drvModel$(d) = UnEsc$(tok$(12))
                    If tokN >= 13 Then drvSerial$(d) = UnEsc$(tok$(13))
                    drvFsSize(d) = 0: drvFsUsed(d) = 0
                    sig$ = sig$ + nm$ + ","
                End If
            ElseIf pk$ <> "" Then
                d = OwnerDrive%(pk$)
                If d > 0 And partCount < MAXPART Then
                    partCount = partCount + 1
                    p = partCount
                    partDrv(p) = d
                    partDepth(p) = DepthOf%(pk$, d)
                    partName$(p) = nm$
                    partSize(p) = Val(tok$(4))
                    partFs$(p) = UnEsc$(tok$(8))
                    partFsSize(p) = Val(tok$(9))
                    partFsUsed(p) = Val(tok$(10))
                    partMount$(p) = UnEsc$(tok$(11))
                    ' roll mounted filesystem usage up to the parent disk
                    If partFsSize(p) > 0 Then
                        drvFsSize(d) = drvFsSize(d) + partFsSize(p)
                        drvFsUsed(d) = drvFsUsed(d) + partFsUsed(p)
                    End If
                End If
            End If
        End If
    Loop
    Close #fh

    ' drive set changed (first run, or a drive came/went): start fresh
    If sig$ <> drvSig$ Then
        drvSig$ = sig$
        For i = 1 To MAXDRV
            SmartReset i, "waiting"
            ioPrimed(i) = 0: rdRate(i) = 0: wrRate(i) = 0
        Next
        histPos = 0: histFill = 0
        If sel > drvCount Then sel = 1
        If drvCount > 0 Then StartSmart
    End If
End Sub


Function DriveWanted% (nm$, tran$, rm$)
    DriveWanted% = 0
    If Left$(nm$, 4) = "loop" Or Left$(nm$, 4) = "zram" Or Left$(nm$, 3) = "ram" Then Exit Function
    If tran$ = "usb" Or rm$ = "1" Then Exit Function
    DriveWanted% = -1
End Function


Function DriveIndex% (nm$)
    Dim i As Integer
    DriveIndex% = 0
    For i = 1 To drvCount
        If drvName$(i) = nm$ Then
            DriveIndex% = i
            Exit Function
        End If
    Next
End Function


Function OwnerDrive% (pk$)
    ' parent may be the disk itself or an already-seen partition
    ' (LVM / LUKS children list their partition as PKNAME)
    Dim i As Integer, res As Integer
    res = DriveIndex%(pk$)
    If res = 0 Then
        For i = 1 To partCount
            If partName$(i) = pk$ Then
                res = partDrv(i)
                Exit For
            End If
        Next
    End If
    OwnerDrive% = res
End Function


Function DepthOf% (pk$, d As Integer)
    Dim i As Integer, res As Integer
    res = 1
    If pk$ <> drvName$(d) Then
        For i = 1 To partCount
            If partName$(i) = pk$ Then
                res = partDepth(i) + 1
                Exit For
            End If
        Next
    End If
    DepthOf% = res
End Function


'=======================================================================
' DATA: /proc/diskstats  (sectors are always 512 bytes here)
'=======================================================================

Sub SampleDiskStats (dt As Double)
    ' fields: 3 name   6 sectors read   10 sectors written
    Dim fh As Integer, ln$, d As Integer
    Dim rs As _Integer64, ws As _Integer64

    If _FileExists("/tmp/qb64_diskinfo_stats.tmp") Then Kill "/tmp/qb64_diskinfo_stats.tmp"
    Shell _Hide "cat /proc/diskstats > /tmp/qb64_diskinfo_stats.tmp 2>/dev/null"
    If Not _FileExists("/tmp/qb64_diskinfo_stats.tmp") Then Exit Sub

    fh = FreeFile
    Open "/tmp/qb64_diskinfo_stats.tmp" For Input As #fh
    Do While Not EOF(fh)
        Line Input #fh, ln$
        SplitWS ln$
        If tokN >= 10 Then
            d = DriveIndex%(tok$(3))
            If d > 0 Then
                rs = Val(tok$(6))
                ws = Val(tok$(10))
                If ioPrimed(d) And dt > 0 Then
                    rdRate(d) = (rs - prevRd(d)) * 512# / dt
                    wrRate(d) = (ws - prevWr(d)) * 512# / dt
                    If rdRate(d) < 0 Then rdRate(d) = 0
                    If wrRate(d) < 0 Then wrRate(d) = 0
                End If
                prevRd(d) = rs: prevWr(d) = ws
                ioPrimed(d) = -1
            End If
        End If
    Loop
    Close #fh

    If dt > 0 Then
        For d = 1 To drvCount
            rdHist(d, histPos) = rdRate(d)
            wrHist(d, histPos) = wrRate(d)
        Next
        histPos = (histPos + 1) Mod HISTLEN
        If histFill < HISTLEN Then histFill = histFill + 1
    End If
End Sub


'=======================================================================
' DATA: SMART  (background smartctl, parsed when the file appears)
'=======================================================================

Sub SmartReset (i As Integer, st$)
    smStatus$(i) = st$: smHealth$(i) = "--": smExtra$(i) = "--"
    smTemp(i) = -999: smHours(i) = -1
    smRealloc(i) = -1: smPendSec(i) = -1: smUncorr(i) = -1: smCrc(i) = -1
    smLife(i) = -1: smUsedPct(i) = -1: smSpare(i) = -1
    smMediaErr(i) = -1: smCritWarn(i) = -1
    smCondBad(i) = 0
End Sub


Sub StartSmart
    ' Only the drives we actually show get queried - built from drvName$()
    ' so USB drives are never touched and any device naming works.
    ' Whole job is one ( ) group so it backgrounds as a unit. Output goes
    ' to .part and is renamed when done, so we never read a half file.
    ' -n standby = don't spin up a sleeping HDD just to read it.
    Dim i As Integer, lst$
    If smPending Or drvCount = 0 Then Exit Sub
    For i = 1 To drvCount
        lst$ = lst$ + " /dev/" + drvName$(i)
    Next
    If _FileExists("/tmp/qb64_diskinfo_smart.tmp") Then Kill "/tmp/qb64_diskinfo_smart.tmp"
    Shell _DontWait _Hide "( ( for d in" + lst$ + "; do echo ==DEV $d; sudo -n smartctl -n standby -H -i -A $d; done ) > /tmp/qb64_diskinfo_smart.part 2>&1; mv /tmp/qb64_diskinfo_smart.part /tmp/qb64_diskinfo_smart.tmp )"
    smPending = -1
    smStart = Timer
End Sub


Sub ParseSmart
    Dim fh As Integer, ln$, nm$, d As Integer, i As Integer

    For i = 1 To drvCount
        SmartReset i, "NO DATA"
    Next

    d = 0
    fh = FreeFile
    Open "/tmp/qb64_diskinfo_smart.tmp" For Input As #fh
    Do While Not EOF(fh)
        Line Input #fh, ln$
        If Left$(ln$, 6) = "==DEV " Then
            nm$ = Mid$(ln$, 7)
            nm$ = Mid$(nm$, _InStrRev(nm$, "/") + 1)
            d = DriveIndex%(nm$)
            If d > 0 Then smStatus$(d) = "OK"
        ElseIf d > 0 Then
            ParseSmartLine d, ln$
        End If
    Loop
    Close #fh

    For i = 1 To drvCount
        BuildCondition i
    Next
    smPending = 0
End Sub


Sub ParseSmartLine (d As Integer, ln$)
    Dim p As Integer, idn As Integer, v As Long

    If InStr(ln$, "password is required") Then smStatus$(d) = "NO PERMISSION": Exit Sub
    If InStr(ln$, "command not found") Then smStatus$(d) = "SMARTCTL MISSING": Exit Sub
    If InStr(ln$, "STANDBY mode") Then smStatus$(d) = "STANDBY (not woken)": Exit Sub
    If InStr(ln$, "SLEEP mode") Then smStatus$(d) = "SLEEP (not woken)": Exit Sub

    ' health line - same wording for ATA and NVMe
    p = InStr(ln$, "test result:")
    If p Then smHealth$(d) = _Trim$(Mid$(ln$, p + Len("test result:"))): Exit Sub

    ' NVMe style "Key:   value" lines
    If Left$(ln$, 12) = "Temperature:" Then smTemp(d) = Val(AfterColon$(ln$)): Exit Sub
    If Left$(ln$, 15) = "Power On Hours:" Then smHours(d) = Val(NoCommas$(AfterColon$(ln$))): Exit Sub
    If Left$(ln$, 16) = "Percentage Used:" Then smUsedPct(d) = Val(AfterColon$(ln$)): Exit Sub
    If Left$(ln$, 16) = "Available Spare:" Then smSpare(d) = Val(AfterColon$(ln$)): Exit Sub
    If Left$(ln$, 32) = "Media and Data Integrity Errors:" Then smMediaErr(d) = Val(NoCommas$(AfterColon$(ln$))): Exit Sub
    If Left$(ln$, 17) = "Critical Warning:" Then smCritWarn(d) = Val("&H" + Mid$(AfterColon$(ln$), 3)): Exit Sub

    ' ATA attribute table: ID NAME FLAG VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW
    SplitWS ln$
    If tokN >= 10 Then
        idn = Val(tok$(1))
        If idn > 0 And tok$(1) = LTrim$(Str$(idn)) Then
            Select Case idn
                Case 5: smRealloc(d) = Val(tok$(10))
                Case 9: smHours(d) = Val(tok$(10))
                Case 190: If smTemp(d) = -999 Then smTemp(d) = Val(tok$(10))
                Case 194: smTemp(d) = Val(tok$(10))
                Case 197: smPendSec(d) = Val(tok$(10))
                Case 198: smUncorr(d) = Val(tok$(10))
                Case 199: smCrc(d) = Val(tok$(10))
                Case 177, 202, 231, 233
                    ' SSD life left = normalized VALUE; keep the lowest seen
                    If drvRota(d) = 0 Then
                        v = Val(tok$(4))
                        If smLife(d) < 0 Or v < smLife(d) Then smLife(d) = v
                    End If
            End Select
        End If
    End If
End Sub


Sub AddCond (d As Integer, s$, lbl$, v As Long)
    ' append "lbl v" if known; any nonzero error count flags the drive
    If v < 0 Then Exit Sub
    s$ = s$ + lbl$ + " " + LTrim$(Str$(v)) + "  "
    If v > 0 Then smCondBad(d) = -1
End Sub


Sub BuildCondition (d As Integer)
    Dim s$
    smCondBad(d) = 0
    AddCond d, s$, "Realloc", smRealloc(d)
    AddCond d, s$, "Pending", smPendSec(d)
    AddCond d, s$, "Uncorr", smUncorr(d)
    AddCond d, s$, "CRC", smCrc(d)
    AddCond d, s$, "Media err", smMediaErr(d)
    AddCond d, s$, "Warn", smCritWarn(d)
    If smLife(d) >= 0 Then
        s$ = s$ + "Life " + LTrim$(Str$(smLife(d))) + "%  "
        If smLife(d) <= 10 Then smCondBad(d) = -1
    End If
    If smUsedPct(d) >= 0 Then
        s$ = s$ + "Wear " + LTrim$(Str$(smUsedPct(d))) + "%  "
        If smUsedPct(d) >= 90 Then smCondBad(d) = -1
    End If
    If smSpare(d) >= 0 Then
        s$ = s$ + "Spare " + LTrim$(Str$(smSpare(d))) + "%  "
        If smSpare(d) <= 10 Then smCondBad(d) = -1
    End If
    s$ = RTrim$(s$)
    If s$ = "" Then s$ = "--"
    smExtra$(d) = s$
End Sub


Sub CleanupTemp
    If _FileExists("/tmp/qb64_diskinfo_lsblk.tmp") Then Kill "/tmp/qb64_diskinfo_lsblk.tmp"
    If _FileExists("/tmp/qb64_diskinfo_stats.tmp") Then Kill "/tmp/qb64_diskinfo_stats.tmp"
    If _FileExists("/tmp/qb64_diskinfo_smart.tmp") Then Kill "/tmp/qb64_diskinfo_smart.tmp"
    If _FileExists("/tmp/qb64_diskinfo_smart.part") Then Kill "/tmp/qb64_diskinfo_smart.part"
End Sub


'=======================================================================
' STRING HELPERS
'=======================================================================

Sub SplitRaw (s$)
    ' split on single spaces, keeping empty fields
    Dim p As Long, q As Long
    tokN = 0: p = 1
    Do
        q = InStr(p, s$, " ")
        tokN = tokN + 1
        If q = 0 Then
            tok$(tokN) = Mid$(s$, p)
            Exit Do
        End If
        tok$(tokN) = Mid$(s$, p, q - p)
        p = q + 1
        If tokN >= 40 Then Exit Do
    Loop
End Sub


Sub SplitWS (s$)
    ' split on runs of spaces / tabs
    Dim i As Long, c$, cur$
    tokN = 0: cur$ = ""
    For i = 1 To Len(s$)
        c$ = Mid$(s$, i, 1)
        If c$ = " " Or c$ = Chr$(9) Then
            If Len(cur$) > 0 And tokN < 40 Then tokN = tokN + 1: tok$(tokN) = cur$
            cur$ = ""
        Else
            cur$ = cur$ + c$
        End If
    Next
    If Len(cur$) > 0 And tokN < 40 Then tokN = tokN + 1: tok$(tokN) = cur$
End Sub


Function UnEsc$ (s$)
    ' decode lsblk raw-mode \xHH escapes
    Dim res$, i As Long
    i = 1
    Do While i <= Len(s$)
        If Mid$(s$, i, 2) = "\x" And i + 3 <= Len(s$) Then
            res$ = res$ + Chr$(Val("&H" + Mid$(s$, i + 2, 2)))
            i = i + 4
        Else
            res$ = res$ + Mid$(s$, i, 1)
            i = i + 1
        End If
    Loop
    UnEsc$ = _Trim$(res$)
End Function


Function AfterColon$ (s$)
    AfterColon$ = _Trim$(Mid$(s$, InStr(s$, ":") + 1))
End Function


Function NoCommas$ (s$)
    Dim res$, i As Long
    For i = 1 To Len(s$)
        If Mid$(s$, i, 1) <> "," Then res$ = res$ + Mid$(s$, i, 1)
    Next
    NoCommas$ = res$
End Function


Function Fix1$ (v As Double)
    ' one decimal place, e.g. 3.0 / 12.5 / 0.4
    Dim res$
    res$ = _Trim$(Str$(Int(v * 10 + 0.5) / 10))
    If Left$(res$, 1) = "." Then res$ = "0" + res$
    If InStr(res$, ".") = 0 Then res$ = res$ + ".0"
    Fix1$ = res$
End Function


Function FmtBytes$ (b As _Integer64)
    Dim bse As Double, v As Double, u$, i$
    If useGiB Then
        bse = 1024: i$ = "i"
    Else
        bse = 1000: i$ = ""
    End If
    v = b
    If v >= bse ^ 4 Then
        v = v / bse ^ 4: u$ = "T"
    ElseIf v >= bse ^ 3 Then
        v = v / bse ^ 3: u$ = "G"
    ElseIf v >= bse ^ 2 Then
        v = v / bse ^ 2: u$ = "M"
    ElseIf v >= bse Then
        v = v / bse: u$ = "K"
    Else
        FmtBytes$ = LTrim$(Str$(b)) + " B"
        Exit Function
    End If
    FmtBytes$ = Fix1$(v) + " " + u$ + i$ + "B"
End Function


Function FmtRate$ (bps As Double)
    Dim bse As Double, i$
    If useGiB Then
        bse = 1024: i$ = "i"
    Else
        bse = 1000: i$ = ""
    End If
    If bps >= bse * bse Then
        FmtRate$ = Fix1$(bps / (bse * bse)) + " M" + i$ + "B/s"
    Else
        FmtRate$ = Fix1$(bps / bse) + " K" + i$ + "B/s"
    End If
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


Function DriveKind$ (d As Integer)
    Dim kind$, t$
    t$ = drvTran$(d)
    If t$ = "nvme" Then
        kind$ = "NVMe SSD"
    ElseIf drvRota(d) = 0 Then
        kind$ = "SSD"
    Else
        kind$ = "HDD"
    End If
    If t$ = "" Then t$ = "unknown bus"
    DriveKind$ = kind$ + "  (" + UCase$(t$) + ")"
End Function

'$Include:'ButtonUI.bm'
'$Include:'GaugeUI.bm'

