'=====================================================================
' QBGuide.bas - PHD2-style autoguider for ZWO cameras, in QB64-PE
'
' Guide camera: any ZWO ASI camera, an Orion StarShoot Autoguider or a QHY5,
'               picked at startup (or Simulator)
' Guide output: ST-4 cable from the camera's guide port to the mount
' No INDI, no wxWidgets, no cmake: compile this file in QB64-PE.
'
' Files that must sit in the same folder (no spaces in the path):
'   QBGuide.bas  ZWOCam.bi  ZWOCam.bm  Guide.bi  Guide.bm
'   GuideUI.bi  GuideUI.bm  zwoguide.h  libzwoguide.so
' libzwoguide.so is made once by running build.sh.
'
' Keys: L loop, S stop, A auto star, C calibrate, G guide, Esc quit
' Click a star in the image to select it.
'=====================================================================
Option _Explicit

'$Include:'ZWOCam.bi'
'$Include:'Guide.bi'
'$Include:'GuideUI.bi'

Const SW = 1200
Const SH = 760
Const VW = 800
Const VH = 600
Const GY = 604
Const GH = 152
Const PANELX = 812

Const MODE_IDLE = 0
Const MODE_LOOP = 1
Const MODE_CAL = 2
Const MODE_GUIDE = 3
Const MODE_DARKS = 4

Const HISTN = 400
Const TGTW = 156
Const TGTDOTS = 100
Const INIFILE = "QBGuide.ini"

Dim Shared Mode As Long
Dim Shared CamIdx As Long
Dim Shared CamBusy As Long, ExpT0 As Double
Dim Shared FrameNum As Long
Dim Shared Msg As String, MsgColor As _Unsigned Long

' settings
Dim Shared ExpList(1 To 12) As Long, ExpIdx As Long
Dim Shared GainSet As Long, BinSet As Long
Dim Shared FocalMm As Double, GuideRate As Double
Dim Shared CalStepMs As Long, CalStepAuto As Long
Dim Shared Stretch As Long, GraphScale As Double
Dim Shared PulseTestMs As Long

' star
Dim Shared Sel As Long, StarCur As StarT, Lost As Long
Dim Shared LockX As Double, LockY As Double
Dim Shared GuideAfterCal As Long

' darks
'   DARK_HOT: the master dark is only used to find hot pixels; each frame
'             then gets those pixels replaced by the median of their
'             neighbours. Adds no noise and works at any exposure or gain
'             (same as PHD2's bad-pixel map). This is the default.
'   DARK_SUB: full dark subtraction. Only applied when exposure, gain and
'             binning match the darks - otherwise "Dark: mismatch".
Const DARK_OFF = 0
Const DARK_HOT = 1
Const DARK_SUB = 2
Const DARK_FRAMES = 16
Dim Shared DarkMode As Long, DarkHave As Long, DarkN As Long, DarkTarget As Long
Dim Shared DarkW As Long, DarkH As Long, DarkExp As Long, DarkGain As Long
ReDim Shared DarkSum(0) As Single
ReDim Shared HotIdx(0) As Long
Dim Shared HotN As Long

' display
Dim Shared ViewImg As Long
Dim Shared VScale As Double, VOX As Long, VOY As Long, DispW As Long, DispH As Long
ReDim Shared Lut(0 To 65535) As _Unsigned Long
Dim Shared Saturated As Long, BrightView As Long
ReDim Shared DispMax(0) As _Unsigned Integer
ReDim Shared XMap(0) As Long

' graph + stats
Dim Shared HistRa(0 To HISTN - 1) As Double, HistDec(0 To HISTN - 1) As Double
Dim Shared HistRaMs(0 To HISTN - 1) As Long, HistDecMs(0 To HISTN - 1) As Long
Dim Shared HistCount As Long, HistPos As Long
Dim Shared StN As Long, StRa As Double, StRa2 As Double, StDec As Double, StDec2 As Double
Dim Shared GuideT0 As Double
Dim Shared LogFile As Long

Dim Shared QuitNow As Long

'---------------------------------------------------------------------
' main
'---------------------------------------------------------------------
Screen _NewImage(SW, SH, 32)
_Title "QBGuide - ST-4 autoguider"
' fit the window on smaller screens (a window taller than the screen
' hides the top button row and throws the mouse off on Linux)
If _DesktopWidth < SW + 20 Or _DesktopHeight < SH + 80 Then
    _FullScreen , _Smooth
Else
    ' give the window manager a moment, then place the window below the
    ' top panel so the title bar can't cover the top button row
    _Delay 0.3
    _ScreenMove (_DesktopWidth - SW) \ 2, 60
End If
ViewImg = _NewImage(VW, VH, 32)

ExpList(1) = 100: ExpList(2) = 200: ExpList(3) = 500: ExpList(4) = 1000
ExpList(5) = 1500: ExpList(6) = 2000: ExpList(7) = 2500: ExpList(8) = 3000
ExpList(9) = 4000: ExpList(10) = 5000: ExpList(11) = 7000: ExpList(12) = 10000

GuideDefaults
LoadSettings

Do
    CamIdx = PickCamera
    If CamIdx = -2 Then Exit Do
    If OpenGuideCamera(CamIdx) Then
        RunGuider
        ShutDownCamera
    End If
Loop Until QuitNow

SaveSettings
System

'---------------------------------------------------------------------
' camera picker
'---------------------------------------------------------------------
Function PickCamera& ()
    Dim n As Long, i As Long, y As Long, choice As Long, r As Long, ns As Long, nq As Long
    n = CamCount
    ns = SSAGCount
    nq = QHY5Count
    choice = -99
    Do
        _Limit 30
        UIPoll
        Line (0, 0)-(SW - 1, SH - 1), C_BG, BF
        Line (300, 120)-(900, 620), C_PANEL, BF
        TextAt 330, 140, "QBGuide - choose the guide camera", C_TEXT
        TextAt 330, 160, "Guide pulses go out the camera's ST-4 port.", C_DIM
        y = 200
        If n = 0 And ns = 0 And nq = 0 Then TextAt 330, y, "No cameras found. Plug one in and press Rescan.", C_WARN: y = y + 30
        For i = 0 To n - 1
            If Btn(330, y, 540, 30, Str$(i + 1) + ": " + CamName$(i), 0) Then choice = i
            y = y + 36
        Next
        If ns > 0 Then
            If Btn(330, y, 540, 30, "O: Orion StarShoot Autoguider", 0) Then choice = CAM_SSAG
            y = y + 36
        End If
        If nq > 0 Then
            If Btn(330, y, 540, 30, "Q: QHY5", 0) Then choice = CAM_QHY5
            y = y + 36
        End If
        y = y + 10
        If Btn(330, y, 540, 30, "Simulator (no camera needed)", 0) Then choice = CAM_SIM
        If Btn(330, 560, 260, 30, "Rescan", 0) Then n = CamCount: ns = SSAGCount: nq = QHY5Count
        If Btn(610, 560, 260, 30, "Quit", 0) Then choice = -2
        If UIKey >= "1" And UIKey <= "9" Then
            r = Val(UIKey) - 1
            If r < n Then choice = r
        End If
        If LCase$(UIKey) = "s" Then choice = CAM_SIM
        If LCase$(UIKey) = "o" And ns > 0 Then choice = CAM_SSAG
        If LCase$(UIKey) = "q" And nq > 0 Then choice = CAM_QHY5
        If UIKey = Chr$(27) Then choice = -2
        If _Exit Then choice = -2: QuitNow = -1
        _Display
    Loop Until choice <> -99
    PickCamera& = choice
End Function

Function OpenGuideCamera& (idx As Long)
    Dim r As Long, nm As String
    If idx = CAM_SSAG Then
        Line (0, 0)-(SW - 1, SH - 1), C_BG, BF
        TextAt 330, 300, "Connecting to the StarShoot Autoguider...", C_TEXT
        TextAt 330, 320, "(first time after plugging in: loading its firmware, up to 10 s)", C_DIM
        _Display
    End If
    r = CamOpen(idx, BinSet)
    If r <> 0 Then
        Msg = "Could not open camera (error" + Str$(r) + ")": MsgColor = C_DEC
        OpenGuideCamera& = 0
        Exit Function
    End If
    nm = _Trim$(Cam.camName)
    If IniGet$("gain_" + nm, "") = "" Then GainSet = Cam.gainBest Else GainSet = Val(IniGet$("gain_" + nm, ""))
    GainSet = _Clamp(GainSet, Cam.gainMin, Cam.gainMax)
    BinSet = Cam.bin
    LoadCalibration
    UpdateDerived
    Sel = 0: Mode = MODE_IDLE: CamBusy = 0
    DarkHave = 0
    Msg = "Camera open. Press Loop to start exposures.": MsgColor = C_GOOD
    If Cam.hasST4 = 0 Then Msg = "Warning: this camera has no ST-4 port - it cannot guide.": MsgColor = C_WARN
    OpenGuideCamera& = -1
End Function

Sub ShutDownCamera
    StopAll
    CamClose
End Sub

' recompute things that depend on settings
Sub UpdateDerived
    If CalStepAuto Then CalStepMs = CalcCalStepMs(FocalMm, GuideRate, GP.decNow, GP.calDistance, 12)
    If Cam.isSim Then SimSetup FocalMm, GuideRate, GP.decNow
End Sub

'---------------------------------------------------------------------
' main guider loop
'---------------------------------------------------------------------
Sub RunGuider
    Dim leave As Long
    leave = 0
    Do
        _Limit 60
        UIPoll
        CameraTick
        Line (0, 0)-(SW - 1, SH - 1), C_BG, BF
        _PutImage (0, 0), ViewImg
        DrawOverlay
        DrawGraph
        Line (PANELX - 4, 0)-(SW - 1, SH - 1), C_PANEL, BF
        If DrawPanel Then leave = -1
        HandleKeys
        If _Exit Then QuitNow = -1
        If QuitNow Then leave = -1
        _Display
    Loop Until leave
End Sub

Sub HandleKeys
    Select Case LCase$(UIKey)
        Case "l": StartLoop
        Case "s": StopAll
        Case "a": AutoStar
        Case "c": StartCal 0
        Case "g": StartGuide
        Case Chr$(27): QuitNow = -1
    End Select
    ' click in the image selects a star
    If MClick And MX < VW And MY < VH And Mode <> MODE_GUIDE And Mode <> MODE_CAL Then
        If FrameNum > 0 And VScale > 0 Then ClickStar (MX - VOX) / VScale, (MY - VOY) / VScale
    End If
End Sub

'---------------------------------------------------------------------
' actions
'---------------------------------------------------------------------
Sub StartLoop
    If Mode = MODE_IDLE Then Mode = MODE_LOOP
    Msg = "Looping exposures": MsgColor = C_TEXT
End Sub

Sub StopAll
    If Mode = MODE_GUIDE Then CloseLog
    Mode = MODE_IDLE
    GuideAfterCal = 0
    If CamBusy Then CamAbort: CamBusy = 0
    CamPulseStop
    Msg = "Stopped": MsgColor = C_TEXT
End Sub

Sub AutoStar
    Dim s As StarT
    If FrameNum = 0 Then Msg = "Loop first, then auto-select": MsgColor = C_WARN: Exit Sub
    If Mode = MODE_CAL Or Mode = MODE_GUIDE Then Exit Sub
    If StarAutoFind(s) Then
        StarCur = s: Sel = -1: Lost = 0
        Msg = "Star selected  SNR " + Fmt$(s.snr, 1) + "  HFD " + Fmt$(s.hfd, 2): MsgColor = C_GOOD
    Else
        Msg = "No suitable star found - try a longer exposure": MsgColor = C_WARN
    End If
End Sub

Sub ClickStar (ix As Double, iy As Double)
    Dim s As StarT, r As Long
    If ix < 0 Or iy < 0 Or ix >= Cam.frameW Or iy >= Cam.frameH Then Exit Sub
    r = StarFind(ix, iy, GP.searchR, s)
    If StarWasFound(r) Then
        StarCur = s: Sel = -1: Lost = 0
        Msg = "Star selected  SNR " + Fmt$(s.snr, 1) + "  HFD " + Fmt$(s.hfd, 2): MsgColor = C_GOOD
        If r = STAR_SATURATED Then Msg = "Star is saturated - lower exposure/gain or pick another": MsgColor = C_WARN
    Else
        Msg = "No star there (" + StarStatusName$(r) + ")": MsgColor = C_WARN
    End If
End Sub

Sub StartCal (thenGuide As Long)
    If Sel = 0 Or StarWasFound(StarCur.status) = 0 Then Msg = "Select a star first": MsgColor = C_WARN: Exit Sub
    If Mode = MODE_IDLE Or Mode = MODE_DARKS Then Mode = MODE_LOOP
    UpdateDerived
    CalBegin StarCur.x, StarCur.y, CalStepMs, (GP.decMode <> DEC_OFF)
    GuideAfterCal = thenGuide
    Mode = MODE_CAL
    Msg = "Calibrating, step" + Str$(CalStepMs) + " ms": MsgColor = C_TEXT
End Sub

Sub StartGuide
    If Sel = 0 Or StarWasFound(StarCur.status) = 0 Then Msg = "Select a star first": MsgColor = C_WARN: Exit Sub
    If Cal.valid = 0 Then StartCal -1: Exit Sub
    If Mode = MODE_CAL Then Exit Sub
    LockX = StarCur.x: LockY = StarCur.y
    GuideReset
    StN = 0: StRa = 0: StRa2 = 0: StDec = 0: StDec2 = 0
    HistCount = 0: HistPos = 0
    GuideT0 = NowSec#
    OpenLog
    Mode = MODE_GUIDE
    Msg = "Guiding": MsgColor = C_GOOD
End Sub

Sub StartDarks
    If Mode = MODE_CAL Or Mode = MODE_GUIDE Then Exit Sub
    If CamBusy Then CamAbort: CamBusy = 0
    DarkW = Cam.frameW: DarkH = Cam.frameH: DarkExp = ExpList(ExpIdx): DarkGain = GainSet
    ReDim DarkSum(0 To DarkW * DarkH - 1) As Single
    DarkN = 0: DarkTarget = DARK_FRAMES: DarkHave = 0: HotN = 0
    Mode = MODE_DARKS
    Msg = "Taking" + Str$(DARK_FRAMES) + " darks - scope must be CAPPED": MsgColor = C_WARN
End Sub

' True when the darks can be used on the current frames
Function DarkUsable& ()
    DarkUsable& = 0
    If DarkHave = 0 Or DarkMode = DARK_OFF Then Exit Function
    If DarkW <> Cam.frameW Or DarkH <> Cam.frameH Then Exit Function
    If DarkMode = DARK_SUB Then
        If DarkExp <> ExpList(ExpIdx) Or DarkGain <> GainSet Then Exit Function
    End If
    DarkUsable& = -1
End Function

Function DarkText$ ()
    If DarkHave = 0 Then DarkText$ = "Dark: none": Exit Function
    Select Case DarkMode
        Case DARK_OFF: DarkText$ = "Dark: off"
        Case DARK_HOT
            If DarkUsable& Then DarkText$ = "Dark: hot px" Else DarkText$ = "Dark: mismatch"
        Case DARK_SUB
            If DarkUsable& Then DarkText$ = "Dark: subtract" Else DarkText$ = "Dark: mismatch"
    End Select
End Function

' Find hot pixels in the master dark: anything well above the typical
' level (median + 6 x robust sigma), capped at 0.5 % of the frame.
Sub BuildHotMap
    Dim n As Long, i As Long, v As Long, med As Long, mad As Long, c As Long
    Dim thresh As Long, cap As Long, sig As Double
    ReDim hist(0 To 65535) As Long
    n = DarkW * DarkH
    For i = 0 To n - 1
        v = Int(DarkSum(i) + 0.5)
        If v < 0 Then v = 0
        If v > 65535 Then v = 65535
        hist(v) = hist(v) + 1
    Next
    c = 0: med = 0
    For i = 0 To 65535
        c = c + hist(i)
        If c >= n \ 2 Then med = i: Exit For
    Next
    ' median absolute deviation
    ReDim hd(0 To 65535) As Long
    For i = 0 To 65535
        If hist(i) Then v = Abs(i - med): hd(v) = hd(v) + hist(i)
    Next
    c = 0: mad = 0
    For i = 0 To 65535
        c = c + hd(i)
        If c >= n \ 2 Then mad = i: Exit For
    Next
    sig = 1.4826 * mad
    If sig < 2 Then sig = 2
    thresh = med + Int(6 * sig + 0.5)
    If thresh > 65535 Then thresh = 65535
    ' cap the count: raise the threshold until no more than 0.5 % qualify
    cap = n \ 200
    c = 0
    For i = 65535 To thresh Step -1
        If c + hist(i) > cap Then thresh = i + 1: Exit For
        c = c + hist(i)
    Next
    HotN = 0
    For i = 0 To n - 1
        If DarkSum(i) >= thresh Then HotN = HotN + 1
    Next
    If HotN > 0 Then
        ReDim HotIdx(0 To HotN - 1) As Long
        c = 0
        For i = 0 To n - 1
            If DarkSum(i) >= thresh Then HotIdx(c) = i: c = c + 1
        Next
    End If
End Sub

' Replace each hot pixel with the median of its in-frame neighbours
Sub FixHotPixels
    Dim k As Long, i As Long, x As Long, y As Long, w As Long, h As Long
    Dim dx As Long, dy As Long, xx As Long, yy As Long, m As Long, a As Long, b As Long, t As Long
    Dim nb(0 To 7) As Long
    w = Cam.frameW: h = Cam.frameH
    For k = 0 To HotN - 1
        i = HotIdx(k)
        y = i \ w: x = i - y * w
        m = 0
        For dy = -1 To 1
            yy = y + dy
            If yy >= 0 And yy < h Then
                For dx = -1 To 1
                    xx = x + dx
                    If (dx Or dy) And xx >= 0 And xx < w Then
                        nb(m) = Frame(yy * w + xx): m = m + 1
                    End If
                Next
            End If
        Next
        If m > 0 Then
            ' insertion sort (at most 8 values)
            For a = 1 To m - 1
                t = nb(a): b = a - 1
                Do While b >= 0
                    If nb(b) <= t Then Exit Do
                    nb(b + 1) = nb(b): b = b - 1
                Loop
                nb(b + 1) = t
            Next
            Frame(i) = nb(m \ 2)
        End If
    Next
End Sub

Sub ManualPulse (d As Long)
    Dim r As Long
    If Mode = MODE_CAL Or Mode = MODE_GUIDE Then Exit Sub
    If CamPulseBusy Then Exit Sub
    If d = DIR_EAST Or d = DIR_WEST Then
        r = CamPulse(d, PulseTestMs, DIR_NONE, 0)
    Else
        r = CamPulse(DIR_NONE, 0, d, PulseTestMs)
    End If
    Msg = "Manual pulse " + DirName$(d) + Str$(PulseTestMs) + " ms": MsgColor = C_TEXT
End Sub

'---------------------------------------------------------------------
' camera state machine
'---------------------------------------------------------------------
Sub CameraTick
    Dim s As Long, r As Long
    If Cam.isOpen = 0 Then Exit Sub
    If Mode = MODE_IDLE Then Exit Sub
    If CamBusy = 0 Then
        ' never expose while a guide pulse is still running
        If CamPulseBusy Then Exit Sub
        r = CamStart(ExpList(ExpIdx), GainSet)
        If r <> 0 Then Msg = "Exposure start failed (" + Str$(r) + ")": MsgColor = C_DEC: Exit Sub
        CamBusy = -1
        ExpT0 = NowSec#
        Exit Sub
    End If
    ' don't hammer the USB bus: only poll near the end of the exposure
    If NowSec# - ExpT0 < ExpList(ExpIdx) / 1000# - 0.05 Then Exit Sub
    s = CamStatus
    Select Case s
        Case EXP_DONE
            r = CamRead
            CamBusy = 0
            If r = 0 Then
                ProcessFrame
            Else
                Msg = "Frame download failed (" + Str$(r) + ")": MsgColor = C_DEC
            End If
        Case EXP_FAILED
            CamBusy = 0
            Msg = "Exposure failed - retrying": MsgColor = C_WARN
        Case Else
            If NowSec# - ExpT0 > ExpList(ExpIdx) / 1000# + 15 Then
                CamAbort
                CamBusy = 0
                Msg = "Camera timeout - retrying": MsgColor = C_DEC
            End If
    End Select
End Sub

Sub ProcessFrame
    Dim r As Long, s As StarT, res As Long, i As Long, n As Long, v As Long
    FrameNum = FrameNum + 1

    If Mode = MODE_DARKS Then
        n = Cam.frameW * Cam.frameH
        If n <> DarkW * DarkH Or DarkExp <> ExpList(ExpIdx) Or DarkGain <> GainSet Then
            ' settings changed part way - start the darks again
            StartDarks
            Msg = "Exposure/gain/binning changed - darks restarted": MsgColor = C_WARN
            BuildView
            Exit Sub
        End If
        For i = 0 To n - 1: DarkSum(i) = DarkSum(i) + Frame(i): Next
        DarkN = DarkN + 1
        Msg = "Dark" + Str$(DarkN) + " of" + Str$(DarkTarget): MsgColor = C_WARN
        If DarkN >= DarkTarget Then
            For i = 0 To n - 1: DarkSum(i) = DarkSum(i) / DarkN: Next
            BuildHotMap
            DarkHave = -1
            If DarkMode = DARK_OFF Then DarkMode = DARK_HOT
            Mode = MODE_LOOP
            Msg = "Darks done," + Str$(HotN) + " hot pixels - uncap the scope": MsgColor = C_GOOD
        End If
        BuildView
        Exit Sub
    End If

    If DarkUsable& Then
        If DarkMode = DARK_HOT Then
            FixHotPixels
        Else
            ' pedestal keeps the background noise from being clipped at 0
            n = DarkW * DarkH
            For i = 0 To n - 1
                v = Frame(i) - DarkSum(i) + 1000
                If v < 0 Then v = 0
                If v > 65535 Then v = 65535
                Frame(i) = v
            Next
        End If
    End If

    If Sel Then
        r = StarFind(StarCur.x, StarCur.y, GP.searchR, s)
        If StarWasFound(r) Then
            StarCur = s
            Lost = 0
        Else
            StarCur.status = r
            Lost = Lost + 1
        End If
    End If

    Select Case Mode
        Case MODE_CAL
            If StarWasFound(StarCur.status) Then
                res = CalStep(StarCur.x, StarCur.y)
                Msg = CalMsg: MsgColor = C_TEXT
                If res = CAL_DONE Then
                    Cal.calDec = GP.decNow
                    Cal.calBin = Cam.bin
                    SaveCalibration
                    MsgColor = C_GOOD
                    If GuideAfterCal Then
                        Mode = MODE_LOOP
                        StartGuide
                    Else
                        Mode = MODE_LOOP
                    End If
                    GuideAfterCal = 0
                ElseIf res = CAL_FAIL Then
                    Mode = MODE_LOOP
                    GuideAfterCal = 0
                    MsgColor = C_DEC
                End If
            Else
                If Lost >= 3 Then
                    Mode = MODE_LOOP
                    Msg = "Calibration stopped: star lost (" + StarStatusName$(StarCur.status) + ")": MsgColor = C_DEC
                End If
            End If
        Case MODE_GUIDE
            If StarWasFound(StarCur.status) Then
                GuideStep StarCur.x - LockX, StarCur.y - LockY
                RecordStep
                If StarCur.status = STAR_SATURATED Then
                    Msg = "Guiding (star saturated)": MsgColor = C_WARN
                Else
                    Msg = "Guiding": MsgColor = C_GOOD
                End If
            Else
                Msg = "Star lost (" + StarStatusName$(StarCur.status) + ") - still trying": MsgColor = C_DEC
                LogLine -1
            End If
    End Select
    BuildView
End Sub

Sub RecordStep
    Dim scl As Double, ra As Double, de As Double
    scl = ImageScale#(FocalMm)
    ra = GStep.raErr * scl
    de = GStep.decErr * scl
    HistRa(HistPos) = ra
    HistDec(HistPos) = de
    If GStep.raDir = DIR_WEST Then HistRaMs(HistPos) = -GStep.raMs Else HistRaMs(HistPos) = GStep.raMs
    If GStep.decDir = DIR_NORTH Then HistDecMs(HistPos) = -GStep.decMs Else HistDecMs(HistPos) = GStep.decMs
    HistPos = (HistPos + 1) Mod HISTN
    If HistCount < HISTN Then HistCount = HistCount + 1
    StN = StN + 1
    StRa = StRa + ra: StRa2 = StRa2 + ra * ra
    StDec = StDec + de: StDec2 = StDec2 + de * de
    LogLine 0
End Sub

Function RmsOf# (s As Double, s2 As Double, n As Long)
    Dim v As Double
    If n < 2 Then RmsOf# = 0: Exit Function
    v = s2 / n - (s / n) * (s / n)
    If v < 0 Then v = 0
    RmsOf# = Sqr(v)
End Function

'---------------------------------------------------------------------
' guide log (CSV, one per guiding run)
'---------------------------------------------------------------------
Sub OpenLog
    Dim fn As String, d As String, t As String
    CloseLog
    d = Date$: t = Time$
    fn = "QBGuide_" + Mid$(d, 7, 4) + Left$(d, 2) + Mid$(d, 4, 2) + "_" + Left$(t, 2) + Mid$(t, 4, 2) + Right$(t, 2) + ".csv"
    LogFile = FreeFile
    Open fn For Output As #LogFile
    Print #LogFile, "# QBGuide log  camera=" + _Trim$(Cam.camName) + "  exp_ms=" + _Trim$(Str$(ExpList(ExpIdx))) + "  scale=" + Fmt$(ImageScale#(FocalMm), 3) + " arcsec/px  gain=" + _Trim$(Str$(GainSet)) + "  bin=" + _Trim$(Str$(Cam.bin)) + "  " + LogDarkText$
    Print #LogFile, "# cal xAngle=" + Fmt$(Cal.xAngle * 57.2957795, 1) + " xRate_px_s=" + Fmt$(Cal.xRate * 1000, 3) + " yAngle=" + Fmt$(Cal.yAngle * 57.2957795, 1) + " yRate_px_s=" + Fmt$(Cal.yRate * 1000, 3)
    Print #LogFile, "frame,time_s,dx_px,dy_px,ra_err_px,dec_err_px,ra_dir,ra_ms,dec_dir,dec_ms,snr,hfd,status"
End Sub

Function LogDarkText$ ()
    Dim s As String
    s = "dark=none"
    If DarkHave Then
        s = "dark_ms=" + _Trim$(Str$(DarkExp)) + " dark_gain=" + _Trim$(Str$(DarkGain))
        If DarkUsable& = 0 Then
            s = s + " dark=not_applied"
        ElseIf DarkMode = DARK_HOT Then
            s = s + " dark=hot_px(" + _Trim$(Str$(HotN)) + ")"
        Else
            s = s + " dark=subtract"
        End If
    End If
    LogDarkText$ = s
End Function

Sub CloseLog
    If LogFile Then Close #LogFile: LogFile = 0
End Sub

Sub LogLine (lostFlag As Long)
    Dim s As String
    If LogFile = 0 Then Exit Sub
    s = _Trim$(Str$(FrameNum)) + "," + Fmt$(NowSec# - GuideT0, 2) + ","
    If lostFlag Then
        s = s + ",,,,,,,,,," + StarStatusName$(StarCur.status)
    Else
        s = s + Fmt$(GStep.dx, 3) + "," + Fmt$(GStep.dy, 3) + "," + Fmt$(GStep.raErr, 3) + "," + Fmt$(GStep.decErr, 3) + ","
        s = s + DirName$(GStep.raDir) + "," + _Trim$(Str$(GStep.raMs)) + "," + DirName$(GStep.decDir) + "," + _Trim$(Str$(GStep.decMs)) + ","
        s = s + Fmt$(StarCur.snr, 1) + "," + Fmt$(StarCur.hfd, 2) + "," + StarStatusName$(StarCur.status)
    End If
    Print #LogFile, s
End Sub

Function DirName$ (d As Long)
    Select Case d
        Case DIR_NORTH: DirName$ = "N"
        Case DIR_SOUTH: DirName$ = "S"
        Case DIR_EAST: DirName$ = "E"
        Case DIR_WEST: DirName$ = "W"
        Case Else: DirName$ = "-"
    End Select
End Function

Function StarStatusName$ (s As Long)
    Select Case s
        Case STAR_OK: StarStatusName$ = "ok"
        Case STAR_SATURATED: StarStatusName$ = "saturated"
        Case STAR_LOWSNR: StarStatusName$ = "low SNR"
        Case STAR_LOWMASS: StarStatusName$ = "too faint"
        Case STAR_LOWHFD: StarStatusName$ = "hot pixel?"
        Case STAR_HIHFD: StarStatusName$ = "too big"
        Case Else: StarStatusName$ = "error"
    End Select
End Function

'---------------------------------------------------------------------
' display
'---------------------------------------------------------------------
' darkest (0.5 %) and brightest (99.9 %) pixel levels of the frame
Sub FrameRange (lo As Double, hi As Double)
    Dim hist(0 To 4095) As Long, i As Long, stp As Long, n As Long, c As Long, total As Long
    Dim plo As Long, phi As Long
    total = Cam.frameW * Cam.frameH
    stp = total \ 20000
    If stp < 1 Then stp = 1
    For i = 0 To total - 1 Step stp
        hist(Frame(i) \ 16) = hist(Frame(i) \ 16) + 1
        n = n + 1
    Next
    c = 0: plo = -1: phi = 4095
    For i = 0 To 4095
        c = c + hist(i)
        If plo < 0 And c >= n * 0.005 Then plo = i
        If c >= n * 0.999 Then phi = i: Exit For
    Next
    If plo < 0 Then plo = 0
    lo = plo * 16
    hi = phi * 16 + 15
End Sub

Sub BuildView
    Dim med As Double, noise As Double, blk As Double, wht As Double, i As Long
    Dim v As Double, c As Long, w As Long, h As Long, x As Long, y As Long
    Dim lo As Double, hi As Double
    Dim m As _MEM, rowOff As _Offset, rowIdx As Long, dy As Long, src As Long, sy As Long, k As Long
    Dim p As _Unsigned Integer
    w = Cam.frameW: h = Cam.frameH
    If w < 1 Or h < 1 Then Exit Sub

    VScale = VW / w
    If VH / h < VScale Then VScale = VH / h

    ' auto stretch from the background level and noise
    ' (a shrunk view keeps block maxima, which lifts the noise floor)
    FrameStats med, noise
    FrameRange lo, hi
    Saturated = (med >= 64000)
    If med >= 30000 Or Saturated Then
        ' bright scene (cap off indoors, daylight, a lit wall): plain
        ' linear stretch from the darkest to the brightest pixel
        BrightView = -1
        blk = lo - 1
        wht = hi
        If wht <= blk + 256 Then blk = wht - 256
    Else
        ' star field: dark background, faint stars pulled up
        BrightView = 0
        blk = med - 0.5 * noise
        If VScale < 0.9 Then blk = med + 2 * noise
        wht = med + noise * (80 / Stretch)
        If wht <= blk + 16 Then wht = blk + 16
    End If
    If blk < 0 Then blk = 0
    For i = 0 To 65535
        If i <= blk Then
            c = 0
        ElseIf i >= wht Then
            c = 255
        ElseIf BrightView Then
            c = Int(255 * (i - blk) / (wht - blk))
        Else
            c = Int(255 * Sqr((i - blk) / (wht - blk)))
        End If
        Lut(i) = _RGB32(c, c, c)
    Next

    DispW = Int(w * VScale): DispH = Int(h * VScale)
    If DispW < 1 Then DispW = 1
    If DispH < 1 Then DispH = 1
    VOX = (VW - DispW) \ 2: VOY = (VH - DispH) \ 2

    _Dest ViewImg
    Cls , &HFF000000
    _Dest 0
    m = _MemImage(ViewImg)

    If VScale < 1 Then
        ' shrinking: keep the brightest pixel of each block so stars survive
        ReDim DispMax(0 To DispW * DispH - 1) As _Unsigned Integer
        ReDim XMap(0 To w - 1) As Long
        For x = 0 To w - 1
            k = Int(x * VScale): If k > DispW - 1 Then k = DispW - 1
            XMap(x) = k
        Next
        For y = 0 To h - 1
            dy = Int(y * VScale): If dy > DispH - 1 Then dy = DispH - 1
            src = y * w
            rowIdx = dy * DispW
            For x = 0 To w - 1
                p = Frame(src + x)
                k = rowIdx + XMap(x)
                If p > DispMax(k) Then DispMax(k) = p
            Next
        Next
        For y = 0 To DispH - 1
            rowOff = m.OFFSET + ((VOY + y) * VW + VOX) * 4
            For x = 0 To DispW - 1
                _MemPut m, rowOff + x * 4, Lut(DispMax(y * DispW + x)) As _Unsigned Long
            Next
        Next
    Else
        ReDim XMap(0 To DispW - 1) As Long
        For x = 0 To DispW - 1
            k = Int(x / VScale): If k > w - 1 Then k = w - 1
            XMap(x) = k
        Next
        For y = 0 To DispH - 1
            sy = Int(y / VScale): If sy > h - 1 Then sy = h - 1
            src = sy * w
            rowOff = m.OFFSET + ((VOY + y) * VW + VOX) * 4
            For x = 0 To DispW - 1
                _MemPut m, rowOff + x * 4, Lut(Frame(src + XMap(x))) As _Unsigned Long
            Next
        Next
    End If
    _MemFree m
End Sub

Sub DrawOverlay
    Dim sx As Double, sy As Double, bx As Long, c As _Unsigned Long, lx As Double, ly As Double
    If FrameNum = 0 Then
        TextAt 300, 290, "No image yet - press Loop", C_DIM
        Exit Sub
    End If
    If Saturated Then
        Line (VW \ 2 - 230, 8)-(VW \ 2 + 230, 30), &HFF7A1010, BF
        Color &HFFFFFFFF, &HFF7A1010
        _PrintString (VW \ 2 - 220, 11), "SATURATED - lower the exposure or gain"
    ElseIf BrightView Then
        TextAt 8, 8, "Bright scene - linear view", C_DIM
    End If
    If Sel Then
        sx = VOX + StarCur.x * VScale: sy = VOY + StarCur.y * VScale
        bx = GP.searchR * VScale
        If bx < 8 Then bx = 8
        c = C_GOOD
        If StarCur.status = STAR_SATURATED Then c = C_WARN
        If StarWasFound(StarCur.status) = 0 Then c = C_DEC
        Line (sx - bx, sy - bx)-(sx + bx, sy + bx), c, B
    End If
    If Mode = MODE_GUIDE Then
        lx = VOX + LockX * VScale: ly = VOY + LockY * VScale
        Line (lx - 14, ly)-(lx + 14, ly), C_GOOD
        Line (lx, ly - 14)-(lx, ly + 14), C_GOOD
    End If
    If Mode = MODE_CAL Then
        lx = VOX + CalRun.startX * VScale: ly = VOY + CalRun.startY * VScale
        Circle (lx, ly), CalRun.distance * VScale, C_WARN
    End If
End Sub

Sub DrawGraph
    ' bottom strip: bullseye target on the left, time graph on the right
    Dim i As Long, j As Long, x As Long, y As Long, x0 As Long, y0 As Long, yc As Long
    Dim xs As Double, ys As Double, cnt As Long, scl As Double, maxMs As Long, bh As Long
    Dim gx0 As Long, gw As Long
    Line (0, GY)-(VW - 1, GY + GH - 1), C_PANEL, BF
    DrawTarget
    gx0 = TGTW: gw = VW - TGTW
    Line (gx0 - 3, GY + 4)-(gx0 - 3, GY + GH - 5), C_GRID
    yc = GY + GH \ 2
    ys = (GH \ 2 - 4) / GraphScale
    Line (gx0, yc)-(VW - 1, yc), C_GRID
    Line (gx0, yc - GraphScale / 2 * ys)-(VW - 1, yc - GraphScale / 2 * ys), C_GRID, , &HF0F0
    Line (gx0, yc + GraphScale / 2 * ys)-(VW - 1, yc + GraphScale / 2 * ys), C_GRID, , &HF0F0
    xs = gw / HISTN
    cnt = HistCount
    maxMs = GP.maxRaMs
    If GP.maxDecMs > maxMs Then maxMs = GP.maxDecMs
    If maxMs < 1 Then maxMs = 1
    ' pulse bars
    For i = 0 To cnt - 1
        j = (HistPos - cnt + i + HISTN) Mod HISTN
        x = gx0 + i * xs
        bh = HistRaMs(j) / maxMs * (GH \ 2 - 4)
        If bh <> 0 Then Line (x, yc)-(x, yc - bh), &HFF24486E
        bh = HistDecMs(j) / maxMs * (GH \ 2 - 4)
        If bh <> 0 Then Line (x + 1, yc)-(x + 1, yc - bh), &HFF6E2C2C
    Next
    ' error traces
    For i = 0 To cnt - 1
        j = (HistPos - cnt + i + HISTN) Mod HISTN
        x = gx0 + i * xs
        y = yc - _Clamp(HistRa(j), -GraphScale, GraphScale) * ys
        If i > 0 Then
            Line (x0, y0)-(x, y), C_RA
        End If
        x0 = x: y0 = y
    Next
    For i = 0 To cnt - 1
        j = (HistPos - cnt + i + HISTN) Mod HISTN
        x = gx0 + i * xs
        y = yc - _Clamp(HistDec(j), -GraphScale, GraphScale) * ys
        If i > 0 Then
            Line (x0, y0)-(x, y), C_DEC
        End If
        x0 = x: y0 = y
    Next
    scl = ImageScale#(FocalMm)
    TextAt gx0 + 4, GY + 4, "+" + Fmt$(GraphScale, 0) + Chr$(34), C_DIM
    TextAt gx0 + 4, GY + GH - 20, "-" + Fmt$(GraphScale, 0) + Chr$(34), C_DIM
    TextAt gx0 + 50, GY + 4, "RA", C_RA
    TextAt gx0 + 74, GY + 4, "Dec", C_DEC
    TextAt gx0 + 110, GY + 4, "RMS  RA " + Fmt$(RmsOf#(StRa, StRa2, StN), 2) + Chr$(34) + "  Dec " + Fmt$(RmsOf#(StDec, StDec2, StN), 2) + Chr$(34) + "  Total " + Fmt$(Sqr(RmsOf#(StRa, StRa2, StN) ^ 2 + RmsOf#(StDec, StDec2, StN) ^ 2), 2) + Chr$(34) + "  (" + _Trim$(Str$(StN)) + ")", C_TEXT
    TextAt VW - 136, GY + GH - 20, "scale " + Fmt$(scl, 2) + Chr$(34) + "/px", C_DIM
End Sub

' Bullseye target like PHD2's: RA across, Dec up, in arcseconds.
' Rings at 1/4, 1/2 and all of the Graph scale (1", 2", 4" at +/-4").
' The last TGTDOTS steps are dots; older ones fade, the newest is
' brightest. The yellow circle is the total RMS since guiding started.
Sub DrawTarget
    Dim cx As Long, cy As Long, rr As Long, n As Long, i As Long, j As Long, k As Long
    Dim px As Double, py As Double, d As Double, b As Long, c As _Unsigned Long, rms As Double
    cx = TGTW \ 2 - 2: cy = GY + GH \ 2
    rr = GH \ 2 - 8
    Circle (cx, cy), rr, C_GRID
    Circle (cx, cy), rr / 2, C_GRID
    Circle (cx, cy), rr / 4, C_GRID
    Line (cx - rr, cy)-(cx + rr, cy), C_GRID, , &HCCCC
    Line (cx, cy - rr)-(cx, cy + rr), C_GRID, , &HCCCC
    TextAt 2, GY + 2, Fmt$(GraphScale, 0) + Chr$(34), C_DIM
    TextAt cx + rr - 14, cy + 2, "RA", C_RA
    TextAt cx + 3, GY + 2, "Dec", C_DEC

    n = HistCount
    If n > TGTDOTS Then n = TGTDOTS
    For k = 0 To n - 1
        ' k = 0 oldest shown ... n-1 newest
        j = (HistPos - n + k + HISTN) Mod HISTN
        px = HistRa(j) / GraphScale * rr
        py = HistDec(j) / GraphScale * rr
        d = Sqr(px * px + py * py)
        If n > 1 Then b = 50 + (205 * k) \ (n - 1) Else b = 255
        c = _RGB32(b * 0.75, b, b * 0.85)
        If d > rr Then
            ' off the target: pin it to the edge in red
            px = px * rr / d: py = py * rr / d
            c = _RGB32(b, b * 0.3, b * 0.3)
        End If
        If k = n - 1 Then
            Line (cx + px - 2, cy - py - 2)-(cx + px + 2, cy - py + 2), _RGB32(255, 255, 255), BF
        Else
            PSet (cx + px, cy - py), c
            PSet (cx + px + 1, cy - py), c
        End If
    Next

    If StN >= 2 Then
        rms = Sqr(RmsOf#(StRa, StRa2, StN) ^ 2 + RmsOf#(StDec, StDec2, StN) ^ 2)
        d = rms / GraphScale * rr
        If d > rr Then d = rr
        If d >= 1 Then Circle (cx, cy), d, C_WARN
    End If
End Sub

' Right-hand panel. Returns -1 when the Camera button is pressed.
Function DrawPanel& ()
    Dim y As Long, d As Long, s As String, x0 As Long, r As Long, modeName As String
    Dim i As Long, j As Long, zx As Long, zy As Long, px0 As Long, py0 As Long, v As Long
    x0 = PANELX
    DrawPanel& = 0
    TextAt x0, 6, "QBGuide", C_TEXT
    TextAt x0 + 72, 6, "ST-4 autoguider", C_DIM
    TextAt x0, 26, _Trim$(Cam.camName) + "  " + _Trim$(Str$(Cam.frameW)) + "x" + _Trim$(Str$(Cam.frameH)) + " bin" + _Trim$(Str$(Cam.bin)) + TempText$, C_DIM

    If Btn(x0, 48, 120, 26, "Camera...", 0) Then DrawPanel& = -1
    If Btn(x0 + 126, 48, 120, 26, "Loop", (Mode <> MODE_IDLE)) Then StartLoop
    If Btn(x0 + 252, 48, 120, 26, "Stop", 0) Then StopAll
    If Btn(x0, 80, 120, 26, "Auto Star", 0) Then AutoStar
    If Btn(x0 + 126, 80, 120, 26, "Calibrate", (Mode = MODE_CAL)) Then StartCal 0
    If Btn(x0 + 252, 80, 120, 26, "Guide", (Mode = MODE_GUIDE)) Then StartGuide
    If Btn(x0, 112, 120, 26, "Take Darks", (Mode = MODE_DARKS)) Then StartDarks
    s = DarkText$
    If Btn(x0 + 126, 112, 120, 26, s, 0) Then
        If DarkHave Then
            ' cycle: hot px -> subtract -> off -> hot px
            Select Case DarkMode
                Case DARK_HOT: DarkMode = DARK_SUB
                Case DARK_SUB: DarkMode = DARK_OFF
                Case Else: DarkMode = DARK_HOT
            End Select
            SaveSettings
            Select Case DarkMode
                Case DARK_HOT: Msg = "Darks: fixing" + Str$(HotN) + " hot pixels (any exposure)": MsgColor = C_TEXT
                Case DARK_SUB
                    Msg = "Darks: full subtract (" + _Trim$(Str$(DarkExp)) + " ms, gain" + Str$(DarkGain) + ")": MsgColor = C_TEXT
                    If DarkUsable& = 0 Then Msg = "Dark mismatch - darks were " + _Trim$(Str$(DarkExp)) + " ms gain" + Str$(DarkGain) + ", not applied": MsgColor = C_WARN
                Case DARK_OFF: Msg = "Darks off": MsgColor = C_TEXT
            End Select
        Else
            Msg = "No darks yet": MsgColor = C_WARN
        End If
    End If
    If Btn(x0 + 252, 112, 120, 26, "Clear Cal", 0) Then
        If Mode <> MODE_GUIDE And Mode <> MODE_CAL Then Cal.valid = 0: Cal.decValid = 0: SaveCalibration: Msg = "Calibration cleared": MsgColor = C_TEXT
    End If
    TextAt x0, 148, "Pulse", C_DIM
    If Btn(x0 + 48, 144, 70, 24, "N", 0) Then ManualPulse DIR_NORTH
    If Btn(x0 + 122, 144, 70, 24, "S", 0) Then ManualPulse DIR_SOUTH
    If Btn(x0 + 196, 144, 70, 24, "E", 0) Then ManualPulse DIR_EAST
    If Btn(x0 + 270, 144, 70, 24, "W", 0) Then ManualPulse DIR_WEST
    TextAt x0 + 346, 148, _Trim$(Str$(PulseTestMs)), C_DIM

    Select Case Mode
        Case MODE_IDLE: modeName = "Idle"
        Case MODE_LOOP: modeName = "Looping"
        Case MODE_CAL: modeName = "Calibrating"
        Case MODE_GUIDE: modeName = "Guiding"
        Case MODE_DARKS: modeName = "Darks"
    End Select
    TextAt x0, 176, modeName + "  frame" + Str$(FrameNum), C_TEXT
    TextAt x0, 194, Left$(Msg, 47), MsgColor

    ' zoomed star (24x24 pixels at 4x)
    zx = x0: zy = 216
    Line (zx - 1, zy - 1)-(zx + 96, zy + 96), C_GRID, B
    If Sel And FrameNum > 0 Then
        px0 = Int(StarCur.x) - 12: py0 = Int(StarCur.y) - 12
        For j = 0 To 23
            For i = 0 To 23
                If px0 + i >= 0 And px0 + i < Cam.frameW And py0 + j >= 0 And py0 + j < Cam.frameH Then
                    v = Frame((py0 + j) * Cam.frameW + px0 + i)
                    Line (zx + i * 4, zy + j * 4)-(zx + i * 4 + 3, zy + j * 4 + 3), Lut(v), BF
                End If
            Next
        Next
        TextAt x0 + 108, 216, "X " + Fmt$(StarCur.x, 2) + "  Y " + Fmt$(StarCur.y, 2), C_TEXT
        TextAt x0 + 108, 234, "SNR " + Fmt$(StarCur.snr, 1), C_TEXT
        TextAt x0 + 108, 252, "HFD " + Fmt$(StarCur.hfd, 2) + " px", C_TEXT
        TextAt x0 + 108, 270, "Peak" + Str$(StarCur.peak) + "  bg" + Str$(Int(StarCur.bg)), C_TEXT
        TextAt x0 + 108, 288, StarStatusName$(StarCur.status), C_DIM
    Else
        TextAt x0 + 108, 216, "No star selected", C_DIM
        TextAt x0 + 108, 234, "Click one, or Auto Star", C_DIM
    End If

    ' settings
    y = 322
    d = SpinRow(x0, y, "Exposure", _Trim$(Str$(ExpList(ExpIdx))) + " ms")
    If d Then ExpIdx = _Clamp(ExpIdx + d, 1, 12): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Gain", _Trim$(Str$(GainSet)))
    If d Then
        If Cam.gainMax - Cam.gainMin <= 30 Then GainSet = GainSet + d Else GainSet = GainSet + d * 10
        GainSet = _Clamp(GainSet, Cam.gainMin, Cam.gainMax): SaveSettings
    End If
    y = y + 22
    d = SpinRow(x0, y, "Binning", _Trim$(Str$(Cam.bin)))
    If d Then ChangeBin Cam.bin + d
    y = y + 22
    d = SpinRow(x0, y, "Guide FL", Fmt$(FocalMm, 0) + " mm")
    If d Then FocalMm = _Clamp(FocalMm + d * 10, 50, 4000): UpdateDerived: SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Guide rate", Fmt$(GuideRate, 2) + " x")
    If d Then GuideRate = _Clamp(GuideRate + d * 0.05, 0.1, 1.0): UpdateDerived: SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Declination", Fmt$(GP.decNow, 0) + " deg")
    If d Then GP.decNow = _Clamp(GP.decNow + d * 5, -90, 90): UpdateDerived: SaveSettings
    y = y + 22
    s = _Trim$(Str$(CalStepMs)) + " ms"
    If CalStepAuto Then s = s + " auto"
    d = SpinRow(x0, y, "Cal step", s)
    If d Then
        CalStepAuto = 0
        CalStepMs = _Clamp(CalStepMs + d * 25, 50, 10000)
        If CalStepMs = 50 And d < 0 Then CalStepAuto = -1: UpdateDerived
        SaveSettings
    End If
    y = y + 22
    d = SpinRow(x0, y, "RA aggression", Fmt$(GP.raAggr * 100, 0) + " %")
    If d Then GP.raAggr = _Clamp(GP.raAggr + d * 0.05, 0, 1.2): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "RA hysteresis", Fmt$(GP.raHyst * 100, 0) + " %")
    If d Then GP.raHyst = _Clamp(GP.raHyst + d * 0.05, 0, 0.5): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "RA min move", Fmt$(GP.raMinMove, 2) + " px")
    If d Then GP.raMinMove = _Clamp(GP.raMinMove + d * 0.05, 0, 5): SaveSettings
    y = y + 22
    Select Case GP.decMode
        Case DEC_OFF: s = "Off"
        Case DEC_AUTO: s = "Auto"
        Case DEC_NORTH: s = "North only"
        Case DEC_SOUTH: s = "South only"
    End Select
    d = SpinRow(x0, y, "Dec mode", s)
    If d And Mode <> MODE_CAL Then GP.decMode = (GP.decMode + d + 4) Mod 4: SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Dec min move", Fmt$(GP.decMinMove, 2) + " px")
    If d Then GP.decMinMove = _Clamp(GP.decMinMove + d * 0.05, 0, 5): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Max RA pulse", _Trim$(Str$(GP.maxRaMs)) + " ms")
    If d Then GP.maxRaMs = _Clamp(GP.maxRaMs + d * 100, 100, 10000): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Max Dec pulse", _Trim$(Str$(GP.maxDecMs)) + " ms")
    If d Then GP.maxDecMs = _Clamp(GP.maxDecMs + d * 100, 100, 10000): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Search box", _Trim$(Str$(GP.searchR * 2)) + " px")
    If d Then GP.searchR = _Clamp(GP.searchR + d * 2, 6, 50): SaveSettings
    y = y + 22
    d = SpinRow(x0, y, "Stretch", _Trim$(Str$(Stretch)))
    If d Then Stretch = _Clamp(Stretch + d, 1, 20): SaveSettings: If FrameNum > 0 Then BuildView
    y = y + 22
    d = SpinRow(x0, y, "Graph scale", "+/-" + Fmt$(GraphScale, 0) + Chr$(34))
    If d Then
        If d > 0 Then GraphScale = GraphScale * 2 Else GraphScale = GraphScale / 2
        GraphScale = _Clamp(GraphScale, 1, 32): SaveSettings
    End If
    y = y + 26

    ' calibration summary
    If Cal.valid Then
        TextAt x0, y, "Cal RA " + Fmt$(Cal.xAngle * 57.2957795, 1) + " deg " + Fmt$(Cal.xRate * 1000 * ImageScale#(FocalMm) * Cal.calBin / Cam.bin, 1) + Chr$(34) + "/s", C_TEXT
        If Cal.decValid Then
            TextAt x0, y + 18, "Cal Dec " + Fmt$(Cal.yAngle * 57.2957795, 1) + " deg " + Fmt$(Cal.yRate * 1000 * ImageScale#(FocalMm) * Cal.calBin / Cam.bin, 1) + Chr$(34) + "/s  ortho " + Fmt$(CalOrthoErr#, 1), C_TEXT
        Else
            TextAt x0, y + 18, "Dec not calibrated", C_DIM
        End If
    Else
        TextAt x0, y, "Not calibrated", C_WARN
    End If
End Function

Function TempText$ ()
    Dim t As Double
    t = CamTempCached#
    If t < -900 Then TempText$ = "" Else TempText$ = "  " + Fmt$(t, 1) + "C"
End Function

' temperature read once every few seconds (it is a USB round trip)
Function CamTempCached# ()
    Static lastT As Double, lastV As Double
    If NowSec# - lastT > 5 Or lastT = 0 Then lastT = NowSec#: lastV = CamTemp#
    CamTempCached# = lastV
End Function

Sub ChangeBin (b As Long)
    Dim r As Long
    If Mode = MODE_CAL Or Mode = MODE_GUIDE Then Exit Sub
    If b < 1 Or b > Cam.maxBin Then Exit Sub
    If CamBusy Then CamAbort: CamBusy = 0
    r = CamSetBin(b)
    BinSet = Cam.bin
    Sel = 0: FrameNum = 0
    UpdateDerived
    SaveSettings
    Msg = "Binning" + Str$(Cam.bin) + " - reselect the star": MsgColor = C_TEXT
End Sub

'---------------------------------------------------------------------
' settings + calibration file
'---------------------------------------------------------------------
Sub LoadSettings
    IniLoad INIFILE
    ExpIdx = _Clamp(IniNum#("exposure_idx", 5), 1, 12)
    BinSet = _Clamp(IniNum#("binning", 1), 1, 4)
    FocalMm = IniNum#("guide_fl_mm", 600)
    GuideRate = IniNum#("guide_rate", 0.5)
    CalStepAuto = (IniNum#("cal_step_auto", 1) <> 0)
    CalStepMs = IniNum#("cal_step_ms", 500)
    Stretch = _Clamp(IniNum#("stretch", 4), 1, 20)
    GraphScale = _Clamp(IniNum#("graph_scale", 4), 1, 32)
    PulseTestMs = IniNum#("manual_pulse_ms", 1000)
    GP.raAggr = IniNum#("ra_aggression", 0.7)
    GP.raHyst = IniNum#("ra_hysteresis", 0.1)
    GP.raMinMove = IniNum#("ra_min_move", 0.2)
    GP.decAggr = IniNum#("dec_aggression", 1.0)
    GP.decMinMove = IniNum#("dec_min_move", 0.2)
    GP.decMode = IniNum#("dec_mode", DEC_AUTO)
    GP.maxRaMs = IniNum#("max_ra_ms", 2500)
    GP.maxDecMs = IniNum#("max_dec_ms", 2500)
    GP.searchR = IniNum#("search_r", 15)
    GP.calDistance = IniNum#("cal_distance_px", 25)
    GP.decNow = IniNum#("declination", 0)
    GP.minHFD = IniNum#("min_hfd", 1.5)
    GP.maxHFD = IniNum#("max_hfd", 10)
    DarkMode = _Clamp(IniNum#("dark_mode", DARK_HOT), DARK_OFF, DARK_SUB)
End Sub

Sub SaveSettings
    IniSet "exposure_idx", _Trim$(Str$(ExpIdx))
    IniSet "binning", _Trim$(Str$(BinSet))
    IniSet "guide_fl_mm", Fmt$(FocalMm, 3)
    IniSet "guide_rate", Fmt$(GuideRate, 3)
    IniSet "cal_step_auto", _Trim$(Str$(-(CalStepAuto <> 0)))
    IniSet "cal_step_ms", _Trim$(Str$(CalStepMs))
    IniSet "stretch", _Trim$(Str$(Stretch))
    IniSet "graph_scale", Fmt$(GraphScale, 3)
    IniSet "manual_pulse_ms", _Trim$(Str$(PulseTestMs))
    IniSet "ra_aggression", Fmt$(GP.raAggr, 3)
    IniSet "ra_hysteresis", Fmt$(GP.raHyst, 3)
    IniSet "ra_min_move", Fmt$(GP.raMinMove, 3)
    IniSet "dec_aggression", Fmt$(GP.decAggr, 3)
    IniSet "dec_min_move", Fmt$(GP.decMinMove, 3)
    IniSet "dec_mode", _Trim$(Str$(GP.decMode))
    IniSet "max_ra_ms", _Trim$(Str$(GP.maxRaMs))
    IniSet "max_dec_ms", _Trim$(Str$(GP.maxDecMs))
    IniSet "search_r", _Trim$(Str$(GP.searchR))
    IniSet "cal_distance_px", _Trim$(Str$(GP.calDistance))
    IniSet "declination", Fmt$(GP.decNow, 3)
    IniSet "min_hfd", Fmt$(GP.minHFD, 3)
    IniSet "max_hfd", Fmt$(GP.maxHFD, 3)
    IniSet "dark_mode", _Trim$(Str$(DarkMode))
    If Cam.isOpen Then IniSet "gain_" + _Trim$(Cam.camName), _Trim$(Str$(GainSet))
    IniSave INIFILE
End Sub

' calibration is kept per camera name
Sub SaveCalibration
    Dim k As String
    k = "cal_" + _Trim$(Cam.camName) + "_"
    IniSet k + "valid", _Trim$(Str$(-(Cal.valid <> 0)))
    IniSet k + "dec_valid", _Trim$(Str$(-(Cal.decValid <> 0)))
    IniSet k + "x_angle", Fmt$(Cal.xAngle, 6)
    IniSet k + "x_rate_px_s", Fmt$(Cal.xRate * 1000, 5)
    IniSet k + "y_angle", Fmt$(Cal.yAngle, 6)
    IniSet k + "y_rate_px_s", Fmt$(Cal.yRate * 1000, 5)
    IniSet k + "dec", Fmt$(Cal.calDec, 3)
    IniSet k + "bin", _Trim$(Str$(Cal.calBin))
    IniSet k + "step_ms", _Trim$(Str$(Cal.stepMs))
    IniSave INIFILE
End Sub

Sub LoadCalibration
    Dim k As String
    k = "cal_" + _Trim$(Cam.camName) + "_"
    Cal.valid = (IniNum#(k + "valid", 0) <> 0)
    Cal.decValid = (IniNum#(k + "dec_valid", 0) <> 0)
    Cal.xAngle = IniNum#(k + "x_angle", 0)
    Cal.xRate = IniNum#(k + "x_rate_px_s", 0) / 1000
    Cal.yAngle = IniNum#(k + "y_angle", 0)
    Cal.yRate = IniNum#(k + "y_rate_px_s", 0) / 1000
    Cal.calDec = IniNum#(k + "dec", 0)
    Cal.calBin = IniNum#(k + "bin", 1)
    Cal.stepMs = IniNum#(k + "step_ms", 0)
    If Cal.xRate <= 0 Then Cal.valid = 0
End Sub

'$Include:'ZWOCam.bm'
'$Include:'Guide.bm'
'$Include:'GuideUI.bm'
