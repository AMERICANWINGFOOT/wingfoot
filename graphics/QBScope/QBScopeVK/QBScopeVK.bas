'==========================================================
' QBScopeVK.bas  -  strange attractors on a simulated analog
'                   oscilloscope, driven by a Vulkan GPU
'
' The Vulkan sibling of QBScope.bas (which grew from K Moerman's
' "Arneodo Attractor on simulated analog oscilloscope", 2026).
' The integration and the phosphor now run on the GPU in
' libscopevk.so, so instead of one beam you can fire up to
' four million at once.
'
' What the GPU adds:
'   - ENSEMBLE: N beams start in a tiny cloud around the same
'     point. Watch them stay together, then smear across the
'     whole attractor - sensitive dependence, made visible.
'     N = 1 with lots of steps is the classic single beam.
'   - HDR PHOSPHOR: beam energy builds up in 32-bit counters,
'     decays like a CRT, and is tone-mapped with bloom. A fast
'     beam spreads its energy thinner, just like a real tube.
'   - SPEED COLOUR: slow parts of the path glow blue, fast
'     parts orange.
'
' Keys:  Left/Right attractor   1/2/3 channel   Space pause
'        F fit   C clear   R reset knobs   S respawn cloud
'        V phosphor/speed colour   Tab next GPU   Esc quit
'
' Command line: a number 1-6 starts on that attractor
'   (1 Arneodo, 2 Lorenz, 3 Rossler, 4 Chua, 5 Thomas, 6 Halvorsen)
' To start on a particular GPU: SCOPEVK_GPU=1 ./QBScopeVK
'
' Requires (same folder): ButtonUI.bi ButtonUI.bm libscopevk.so
' Build libscopevk.so with ./build.sh (needs libvulkan-dev).
'==========================================================
Option _Explicit
'$Include:'ButtonUI.bi'

Declare Dynamic Library "./scopevk"
    Function sv_device_count& ()
    Sub sv_device_name (ByVal dIdx As Long, dBuf As String, ByVal dLen As Long)
    Function sv_current_device& ()
    Function sv_init& (ByVal dDev As Long, ByVal dW As Long, ByVal dH As Long, ByVal dMaxN As Long)
    Sub sv_shutdown
    Sub sv_last_error (dMsg As String, ByVal dLen As Long)
    Sub sv_system (ByVal dAtt As Long, ByVal dA As Single, ByVal dB As Single, ByVal dC As Single, ByVal dDt As Single, ByVal dRk4 As Long)
    Sub sv_view (ByVal dChH As Long, ByVal dChV As Long, ByVal dCx As Single, ByVal dCy As Single, ByVal dHx As Single, ByVal dHy As Single, ByVal dBorder As Long)
    Sub sv_beam (ByVal dDecay As Single, ByVal dGain As Single, ByVal dBloom As Single, ByVal dColMode As Long)
    Sub sv_spawn (ByVal dN As Long, ByVal dX0 As Single, ByVal dY0 As Single, ByVal dZ0 As Single, ByVal dSpread As Single)
    Sub sv_clear
    Function sv_frame& (ByVal dSteps As Long, ByVal dPixels As _Offset)
    Function sv_runaways& ()
    Sub sv_stats (dGpuMs As Single, dHostMs As Single)
End Declare

'--- layout --------------------------------------------------
Const SW = 1080
Const SH = 760
Const SCX = 10 '       scope image position on screen
Const SCY = 10
Const SCW = 740 '      scope image size
Const SCH = 740
Const BRD = 30 '       border inside the scope image
Const DIVX = 10 '      grid divisions
Const DIVY = 8
Const PX = 766 '       control panel left edge
Const PW = 304 '       control panel width
Const BH = 24
Const RH = 28 '        knob row spacing

'--- GPU limits ----------------------------------------------
Const MAXPARTS = 4194304 '  particles allocated on the GPU (64 MB)
Const MAXWORK = 134217728 ' particles x steps per frame (2^27)

'--- attractors ----------------------------------------------
Const NATT = 6
Const ATT_ARNEODO = 1
Const ATT_LORENZ = 2
Const ATT_ROSSLER = 3
Const ATT_CHUA = 4
Const ATT_THOMAS = 5
Const ATT_HALVORSEN = 6

Dim Shared attName(1 To NATT) As String
Dim Shared attDt(1 To NATT) As Double
Dim Shared attInit(1 To NATT, 1 To 3) As Double
Dim Shared attNParm(1 To NATT) As Integer
Dim Shared attPName(1 To NATT, 1 To 3) As String
Dim Shared attPDef(1 To NATT, 1 To 3) As Double
Dim Shared attEq(1 To NATT, 1 To 3) As String

'--- live state ----------------------------------------------
Dim Shared att As Integer '        current attractor
Dim Shared parm(1 To 3) As Double ' current a, b, c
Dim Shared sx As Double, sy As Double, sz As Double ' CPU state (Fit only)
Dim Shared chan As Integer '       1 = X-Y, 2 = X-Z, 3 = Y-Z
Dim Shared useRK4 As Integer
Dim Shared paused As Integer
Dim Shared quitFlag As Integer
Dim Shared statusMsg As String

' ensemble and beam knobs
Dim Shared nParts As Long '        beams in flight
Dim Shared stepsPF As Long '       integration steps per beam per frame
Dim Shared cloudExp As Integer '   start cloud size = 10 ^ cloudExp
Dim Shared persistLvl As Integer ' decay = 1 - 0.5 ^ persistLvl
Dim Shared gainV As Single '       phosphor brightness
Dim Shared bloomV As Single '      halo strength
Dim Shared colMode As Long '       0 phosphor green, 1 speed colour

' view: centre and half-range of x, y, z (set by Fit)
Dim Shared vC(1 To 3) As Double
Dim Shared vH(1 To 3) As Double

' GPU
Dim Shared gpuOK As Integer
Dim Shared gpuName As String
Dim Shared gpuMs As Single, hostMs As Single
Dim Shared gpuS As Single, fpsS As Single ' smoothed for the HUD
Dim Shared mScope As _MEM

Dim Shared scopeImg As Long
Dim Shared ovlImg As Long
Dim Shared cBG As _Unsigned Long, cPanel As _Unsigned Long, cFG As _Unsigned Long
Dim Shared cDim As _Unsigned Long, cHot As _Unsigned Long, cScale As _Unsigned Long

Dim k As String, ns As Long, ran As Long, tNow As Double, tLast As Double, dtF As Double

Screen _NewImage(SW, SH, 32)
_FullScreen , _Smooth

_Title "QBScopeVK - attractors on a Vulkan analog oscilloscope"
_ScreenMove _Middle
MouseInit
cBG = _RGB32(14, 16, 20)
cPanel = _RGB32(26, 29, 36)
cFG = _RGB32(200, 204, 210)
cDim = _RGB32(110, 116, 126)
cHot = _RGB32(70, 230, 90)
cScale = _RGB32(84, 88, 84)

scopeImg = _NewImage(SCW, SCH, 32)
ovlImg = _NewImage(SCW, SCH, 32)
mScope = _MemImage(scopeImg)

SetupAttractors
chan = 2 '            X-Z, like the original
useRK4 = -1
nParts = 65536
stepsPF = 64
cloudExp = -3
persistLvl = 4
gainV = 1.5
bloomV = 0.4
colMode = 0

If Not StartGPU%(-1) Then
    Cls , cBG
    Color _RGB32(255, 120, 100)
    _PrintString (20, 20), "Could not start Vulkan:"
    _PrintString (20, 40), LastErr$
    Color cFG
    _PrintString (20, 80), "Check that libscopevk.so is next to this program (./build.sh),"
    _PrintString (20, 100), "and that a Vulkan driver is installed (vulkaninfo --summary)."
    _PrintString (20, 140), "Press any key."
    _Display
    Sleep
    System
End If

' optional start-up choice: QBScopeVK 2  -> Lorenz, etc.
If _CommandCount > 0 Then
    SelectAttractor _Clamp(Val(Command$(1)), 1, NATT)
Else
    SelectAttractor ATT_ARNEODO
End If

'==========================================================
' Frame loop
'==========================================================
tLast = Timer(.001)
Do
    _Limit 60
    PollMouse
    k = InKey$
    If Len(k) Then HandleKey k

    If gpuOK Then
        PushParams
        If paused Then ns = 0 Else ns = stepsPF
        If sv_frame&(ns, mScope.OFFSET) Then
            ran = sv_runaways&
            If ran > 0 Then statusMsg = LTrim$(Str$(ran)) + " beams ran away and were respawned. Try RK4 or a smaller knob change."
            sv_stats gpuMs, hostMs
        Else
            gpuOK = 0
            statusMsg = "GPU error: " + LastErr$ + "  (Tab tries the next GPU)"
        End If
    End If

    tNow = Timer(.001)
    dtF = tNow - tLast
    If dtF < 0 Then dtF = dtF + 86400 ' midnight rollover
    tLast = tNow
    If dtF > 0 Then fpsS = fpsS * 0.92 + (1 / dtF) * 0.08
    gpuS = gpuS * 0.92 + hostMs * 0.08

    _Dest 0
    Cls , cBG
    _PutImage (SCX, SCY), scopeImg
    _PutImage (SCX, SCY), ovlImg
    DrawPanel
    _Display
Loop Until quitFlag

_MemFree mScope
sv_shutdown
System


'==========================================================
' GPU
'==========================================================
Function StartGPU% (dev As Long)
    Dim b As String
    gpuOK = 0
    If sv_init&(dev, SCW, SCH, MAXPARTS) = 0 Then Exit Function
    b = Space$(256)
    sv_device_name sv_current_device&, b, 256
    gpuName = CStr$(b)
    gpuOK = -1
    StartGPU% = -1
End Function

Sub NextGPU
    Dim cnt As Long, cur As Long, nxt As Long
    cnt = sv_device_count&
    If cnt < 2 Then statusMsg = "Only one Vulkan device found.": Exit Sub
    cur = sv_current_device&
    If cur < 0 Then cur = 0
    nxt = (cur + 1) Mod cnt
    If StartGPU%(nxt) Then
        SpawnCloud
        statusMsg = "Switched to " + gpuName
    Else
        statusMsg = "GPU " + LTrim$(Str$(nxt)) + " failed: " + LastErr$
        If StartGPU%(cur) Then SpawnCloud
    End If
End Sub

Sub PushParams
    sv_system att, parm(1), parm(2), parm(3), attDt(att), useRK4
    sv_view ChanH%, ChanV%, vC(ChanH%), vC(ChanV%), vH(ChanH%), vH(ChanV%), BRD
    sv_beam DecayVal!, gainV, bloomV, colMode
End Sub

' New cloud of beams at the start point, phosphor wiped.
Sub SpawnCloud
    If Not gpuOK Then Exit Sub
    sv_spawn nParts, attInit(att, 1), attInit(att, 2), attInit(att, 3), 10 ^ cloudExp
    sv_clear
End Sub

Function DecayVal! ()
    DecayVal! = 1 - 0.5 ^ persistLvl
End Function

Function LastErr$ ()
    Dim b As String
    b = Space$(256)
    sv_last_error b, 256
    LastErr$ = CStr$(b)
End Function

' C string in a QB64 buffer -> QB64 string (cut at the first zero byte)
Function CStr$ (b As String)
    Dim z As Long
    z = InStr(b, Chr$(0))
    If z Then CStr$ = Left$(b, z - 1) Else CStr$ = RTrim$(b)
End Function


'==========================================================
' Attractor definitions (same as QBScope.bas)
'==========================================================
Sub DefAtt (i As Integer, nm As String, dt As Double, x0 As Double, y0 As Double, z0 As Double)
    attName(i) = nm
    attDt(i) = dt
    attInit(i, 1) = x0: attInit(i, 2) = y0: attInit(i, 3) = z0
End Sub

Sub DefParm (i As Integer, p As Integer, nm As String, v As Double)
    attPName(i, p) = nm
    attPDef(i, p) = v
    If p > attNParm(i) Then attNParm(i) = p
End Sub

Sub DefEq (i As Integer, e1 As String, e2 As String, e3 As String)
    attEq(i, 1) = e1: attEq(i, 2) = e2: attEq(i, 3) = e3
End Sub

Sub SetupAttractors
    DefAtt ATT_ARNEODO, "Arneodo", 0.005, 1, 1, 0
    DefParm ATT_ARNEODO, 1, "a", 5.5
    DefParm ATT_ARNEODO, 2, "b", 3.5
    DefParm ATT_ARNEODO, 3, "c", 1
    DefEq ATT_ARNEODO, "dx = y", "dy = z", "dz = a*x - c*x^3 - b*y - z"

    DefAtt ATT_LORENZ, "Lorenz", 0.005, 1, 1, 1
    DefParm ATT_LORENZ, 1, "sigma", 10
    DefParm ATT_LORENZ, 2, "rho", 28
    DefParm ATT_LORENZ, 3, "beta", 8 / 3
    DefEq ATT_LORENZ, "dx = sigma*(y - x)", "dy = x*(rho - z) - y", "dz = x*y - beta*z"

    DefAtt ATT_ROSSLER, "Rossler", 0.01, 1, 1, 0
    DefParm ATT_ROSSLER, 1, "a", 0.2
    DefParm ATT_ROSSLER, 2, "b", 0.2
    DefParm ATT_ROSSLER, 3, "c", 5.7
    DefEq ATT_ROSSLER, "dx = -y - z", "dy = x + a*y", "dz = b + z*(x - c)"

    DefAtt ATT_CHUA, "Chua circuit", 0.005, 0.7, 0, 0
    DefParm ATT_CHUA, 1, "alpha", 15.6
    DefParm ATT_CHUA, 2, "beta", 28
    DefParm ATT_CHUA, 3, "m0", -1.143
    DefEq ATT_CHUA, "dx = alpha*(y - x - f(x))", "dy = x - y + z", "dz = -beta*y   (diode f, m1=-0.714)"

    DefAtt ATT_THOMAS, "Thomas", 0.05, 1.1, 1.1, -0.01
    DefParm ATT_THOMAS, 1, "b", 0.208186
    DefEq ATT_THOMAS, "dx = sin(y) - b*x", "dy = sin(z) - b*y", "dz = sin(x) - b*z"

    DefAtt ATT_HALVORSEN, "Halvorsen", 0.005, -1.48, -1.51, 2.04
    DefParm ATT_HALVORSEN, 1, "a", 1.4
    DefEq ATT_HALVORSEN, "dx = -a*x - 4y - 4z - y^2", "dy = -a*y - 4z - 4x - z^2", "dz = -a*z - 4x - 4y - x^2"
End Sub

Sub SelectAttractor (i As Integer)
    att = i
    ResetParms
    FitView
    SpawnCloud
    statusMsg = attName(att) + " loaded."
End Sub

Sub ResetParms
    Dim p As Integer
    For p = 1 To 3
        parm(p) = attPDef(att, p)
    Next
    RestartState
End Sub

Sub RestartState
    sx = attInit(att, 1): sy = attInit(att, 2): sz = attInit(att, 3)
End Sub


'==========================================================
' CPU copy of the math - used only by Fit to size the view
'==========================================================
Sub Deriv (x As Double, y As Double, z As Double, dx As Double, dy As Double, dz As Double)
    Dim fx As Double
    Select Case att
        Case ATT_ARNEODO
            dx = y
            dy = z
            dz = parm(1) * x - parm(3) * x * x * x - parm(2) * y - z
        Case ATT_LORENZ
            dx = parm(1) * (y - x)
            dy = x * (parm(2) - z) - y
            dz = x * y - parm(3) * z
        Case ATT_ROSSLER
            dx = -y - z
            dy = x + parm(1) * y
            dz = parm(2) + z * (x - parm(3))
        Case ATT_CHUA
            fx = -0.714 * x + 0.5 * (parm(3) + 0.714) * (Abs(x + 1) - Abs(x - 1))
            dx = parm(1) * (y - x - fx)
            dy = x - y + z
            dz = -parm(2) * y
        Case ATT_THOMAS
            dx = Sin(y) - parm(1) * x
            dy = Sin(z) - parm(1) * y
            dz = Sin(x) - parm(1) * z
        Case ATT_HALVORSEN
            dx = -parm(1) * x - 4 * y - 4 * z - y * y
            dy = -parm(1) * y - 4 * z - 4 * x - z * z
            dz = -parm(1) * z - 4 * x - 4 * y - x * x
    End Select
End Sub

' Fit always uses RK4 so the view is right even when the beam runs Euler.
Sub StepOnce (h As Double)
    Dim k1x As Double, k1y As Double, k1z As Double
    Dim k2x As Double, k2y As Double, k2z As Double
    Dim k3x As Double, k3y As Double, k3z As Double
    Dim k4x As Double, k4y As Double, k4z As Double
    Dim hh As Double

    hh = h / 2
    Deriv sx, sy, sz, k1x, k1y, k1z
    Deriv sx + hh * k1x, sy + hh * k1y, sz + hh * k1z, k2x, k2y, k2z
    Deriv sx + hh * k2x, sy + hh * k2y, sz + hh * k2z, k3x, k3y, k3z
    Deriv sx + h * k3x, sy + h * k3y, sz + h * k3z, k4x, k4y, k4z
    sx = sx + h / 6 * (k1x + 2 * k2x + 2 * k3x + k4x)
    sy = sy + h / 6 * (k1y + 2 * k2y + 2 * k3y + k4y)
    sz = sz + h / 6 * (k1z + 2 * k2z + 2 * k3z + k4z)
End Sub

' NaN fails every comparison, so "not under the limit" catches it too.
Function Runaway% ()
    If Not (Abs(sx) < 1E+6 And Abs(sy) < 1E+6 And Abs(sz) < 1E+6) Then Runaway% = -1
End Function

Function StateOf# (v As Integer)
    Select Case v
        Case 1: StateOf# = sx
        Case 2: StateOf# = sy
        Case Else: StateOf# = sz
    End Select
End Function

' Which state variables feed the horizontal / vertical inputs.
Function ChanH% ()
    If chan = 3 Then ChanH% = 2 Else ChanH% = 1
End Function

Function ChanV% ()
    If chan = 1 Then ChanV% = 2 Else ChanV% = 3
End Function


'==========================================================
' View: auto-scale, grid overlay
'==========================================================
' Run the attractor off-screen, skip the start-up transient,
' and size the view to what it then visits (plus a margin).
Sub FitView
    Dim i As Long, nSkip As Long, nRun As Long, v As Integer, val3 As Double
    Dim lo(1 To 3) As Double, hi(1 To 3) As Double, bad As Integer

    RestartState
    nSkip = 20 / attDt(att)
    nRun = 200 / attDt(att)
    For i = 1 To nSkip
        StepOnce attDt(att)
        If Runaway% Then bad = -1: Exit For
    Next
    For v = 1 To 3
        lo(v) = StateOf#(v): hi(v) = lo(v)
    Next
    If Not bad Then
        For i = 1 To nRun
            StepOnce attDt(att)
            If Runaway% Then bad = -1: Exit For
            For v = 1 To 3
                val3 = StateOf#(v)
                If val3 < lo(v) Then lo(v) = val3
                If val3 > hi(v) Then hi(v) = val3
            Next
        Next
    End If
    For v = 1 To 3
        If bad Or hi(v) - lo(v) < 1E-9 Then
            vC(v) = 0: vH(v) = 10
        Else
            vC(v) = (lo(v) + hi(v)) / 2
            vH(v) = (hi(v) - lo(v)) / 2 * 1.08
        End If
    Next
    RestartState
    BuildOverlay
End Sub

' Graticule and labels on a transparent layer laid over the GPU frame.
Sub BuildOverlay
    Dim i As Integer, xs As Integer, ys As Integer, ln As String
    Dim gx As Integer, gy As Integer, gw As Integer, gh As Integer

    gx = BRD: gy = BRD: gw = SCW - 2 * BRD: gh = SCH - 2 * BRD
    _Dest ovlImg
    Cls , _RGBA32(0, 0, 0, 0)
    ' centre lines, frame (2 px)
    Line (gx, SCH \ 2)-(gx + gw, SCH \ 2 + 1), cScale, BF
    Line (SCW \ 2, gy)-(SCW \ 2 + 1, gy + gh), cScale, BF
    Line (gx, gy)-(gx + gw, gy + gh), cScale, B
    Line (gx + 1, gy + 1)-(gx + gw - 1, gy + gh - 1), cScale, B
    ' small ticks on the centre lines
    For i = 1 To DIVX * 5 - 1
        xs = gx + i * gw \ (DIVX * 5)
        Line (xs, SCH \ 2 - 5)-(xs, SCH \ 2 + 5), cScale
    Next
    For i = 1 To DIVY * 5 - 1
        ys = gy + i * gh \ (DIVY * 5)
        Line (SCW \ 2 - 5, ys)-(SCW \ 2 + 5, ys), cScale
    Next
    ' main graticule
    For i = 1 To DIVX - 1
        xs = gx + i * gw \ DIVX
        Line (xs, gy)-(xs, gy + gh), cScale
    Next
    For i = 1 To DIVY - 1
        ys = gy + i * gh \ DIVY
        Line (gx, ys)-(gx + gw, ys), cScale
    Next
    ' labels
    _PrintMode _KeepBackground
    Color cScale
    _PrintString (gx + 1, 8), "QBScopeVK  -  " + ChanName$(chan) + "   " + attName(att) + "   " + BeamsTxt$
    ln = "CH1: " + NumStr$(2 * vH(ChanH%) / DIVX) + "/DIV   CH2: " + NumStr$(2 * vH(ChanV%) / DIVY) + "/DIV"
    _PrintString (gx + 1, SCH - BRD + 8), ln
    _Dest 0
End Sub

Function ChanName$ (c As Integer)
    Select Case c
        Case 1: ChanName$ = "X-Y"
        Case 2: ChanName$ = "X-Z"
        Case Else: ChanName$ = "Y-Z"
    End Select
End Function


'==========================================================
' Input
'==========================================================
Sub HandleKey (k As String)
    Select Case UCase$(k)
        Case Chr$(27): quitFlag = -1
        Case Chr$(0) + Chr$(75): PrevAtt
        Case Chr$(0) + Chr$(77): NextAtt
        Case "1", "2", "3": SetChan Val(k)
        Case " ": paused = Not paused
        Case "F": DoFit
        Case "C": ClearScope
        Case "R": ResetParms: statusMsg = "Knobs reset to defaults."
        Case "S": SpawnCloud: statusMsg = "New cloud of " + BeamsTxt$ + "."
        Case "V": colMode = 1 - colMode
        Case Chr$(9): NextGPU
    End Select
End Sub

Sub DoFit
    FitView
    ClearScope
    statusMsg = "View fitted."
End Sub

Sub ClearScope
    If gpuOK Then sv_clear
End Sub

Sub PrevAtt
    If att > 1 Then SelectAttractor att - 1 Else SelectAttractor NATT
End Sub

Sub NextAtt
    If att < NATT Then SelectAttractor att + 1 Else SelectAttractor 1
End Sub

Sub SetChan (c As Integer)
    If c = chan Then Exit Sub
    chan = c
    If gpuOK Then sv_clear
    BuildOverlay
End Sub

' Knob step: 2% of the default value (so every knob turns at a
' sensible rate whatever its size).
Sub TurnKnob (p As Integer, dirn As Integer)
    Dim stp As Double
    stp = Abs(attPDef(att, p)) * 0.02
    If stp = 0 Then stp = 0.01
    parm(p) = parm(p) + dirn * stp
    If Abs(parm(p)) < stp / 100 Then parm(p) = 0
    statusMsg = attPName(att, p) + " = " + NumStr$(parm(p))
End Sub


'==========================================================
' Control panel
'==========================================================
Sub Txt (x As Integer, y As Integer, s As String, clr As _Unsigned Long)
    Color clr
    _PrintString (x, y), s
End Sub

' Green frame marks the active choice in a button group.
Sub Mark (x As Integer, y As Integer, w As Integer)
    Line (x - 2, y - 2)-(x + w + 2, y + BH + 2), cHot, B
End Sub

Sub DrawPanel
    Dim y As Integer, p As Integer, x As Integer, i As Integer

    Line (PX - 6, SCY)-(PX + PW, SCY + SCH), cPanel, BF
    _PrintMode _KeepBackground

    ' attractor
    y = 18
    Txt PX + 6, y, "ATTRACTOR", cDim
    y = y + 18
    If Button%(PX + 6, y, 30, BH, "<") Then PrevAtt
    Line (PX + 44, y)-(PX + PW - 46, y + BH), _RGB32(10, 12, 16), BF
    Txt PX + 44 + (PW - 90 - 8 * Len(attName(att))) \ 2, y + 4, attName(att), cHot
    If Button%(PX + PW - 38, y, 30, BH, ">") Then NextAtt

    ' equations
    y = y + 32
    For i = 1 To 3
        Txt PX + 6, y, Left$(attEq(att, i), 37), cFG
        y = y + 16
    Next

    ' knobs
    y = y + 8
    Txt PX + 6, y, "KNOBS", cDim
    y = y + 18
    For p = 1 To 3
        If p <= attNParm(att) Then
            Txt PX + 6, y + 4, attPName(att, p) + " = " + NumStr$(parm(p)), cFG
            If Button%(PX + PW - 78, y, 34, BH, "-") Then TurnKnob p, -1
            If Button%(PX + PW - 40, y, 34, BH, "+") Then TurnKnob p, 1
        Else
            Txt PX + 6, y + 4, "-", cDim
        End If
        y = y + RH
    Next
    If Button%(PX + 6, y, 140, BH, "Reset knobs") Then ResetParms: statusMsg = "Knobs reset to defaults."
    If Button%(PX + 154, y, 140, BH, "Respawn cloud") Then SpawnCloud: statusMsg = "New cloud of " + BeamsTxt$ + "."

    ' channels
    y = y + 34
    Txt PX + 6, y, "CHANNELS  (CH1 - CH2)", cDim
    y = y + 18
    For i = 1 To 3
        x = PX + 6 + (i - 1) * 98
        If Button%(x, y, 90, BH, ChanName$(i)) Then SetChan i
        If chan = i Then Mark x, y, 90
    Next

    ' integrator
    y = y + 34
    Txt PX + 6, y, "INTEGRATOR", cDim
    y = y + 18
    If Button%(PX + 6, y, 140, BH, "Euler") Then useRK4 = 0: statusMsg = "Euler: fast but drifts off the true path."
    If Not useRK4 Then Mark PX + 6, y, 140
    If Button%(PX + 154, y, 140, BH, "Runge-Kutta 4") Then useRK4 = -1: statusMsg = "RK4: four slope samples per step, far more accurate."
    If useRK4 Then Mark PX + 154, y, 140

    ' ensemble
    y = y + 34
    Txt PX + 6, y, "ENSEMBLE", cDim
    y = y + 18
    KnobRow y, "Beams", Commas$(nParts), 1
    y = y + RH
    KnobRow y, "Steps", LTrim$(Str$(stepsPF)) + " /beam/frame", 2
    y = y + RH
    KnobRow y, "Cloud", "1E" + LTrim$(Str$(cloudExp)), 3

    ' beam
    y = y + 34
    Txt PX + 6, y, "PHOSPHOR", cDim
    y = y + 18
    KnobRow y, "Persistence", NumStr$(DecayVal!), 4
    y = y + RH
    KnobRow y, "Glow", NumStr$(gainV), 5
    y = y + RH
    KnobRow y, "Bloom", NumStr$(bloomV), 6
    y = y + RH
    If Button%(PX + 6, y, 140, BH, "Green P31") Then colMode = 0
    If colMode = 0 Then Mark PX + 6, y, 140
    If Button%(PX + 154, y, 140, BH, "Speed colour") Then colMode = 1
    If colMode = 1 Then Mark PX + 154, y, 140

    ' actions
    y = y + 36
    If Button%(PX + 6, y, 70, BH, "Fit") Then DoFit
    If Button%(PX + 82, y, 70, BH, "Clear") Then ClearScope
    If paused Then
        If Button%(PX + 158, y, 70, BH, "Run") Then paused = 0
    Else
        If Button%(PX + 158, y, 70, BH, "Pause") Then paused = -1
    End If
    If Button%(PX + 234, y, 60, BH, "Quit") Then quitFlag = -1

    ' status
    y = y + 34
    Txt PX + 6, y, Left$(statusMsg, 37), cDim
    Txt PX + 6, y + 16, Mid$(statusMsg, 38, 37), cDim
    Txt PX + 6, y + 16 * 2, Mid$(statusMsg, 75, 37), cDim

    ' GPU line
    Txt PX + 6, SCY + SCH - 38, Left$(gpuName, 37), cHot
    Txt PX + 6, SCY + SCH - 20, "gpu " + Fix1$(gpuMs) + "  frame " + Fix1$(gpuS) + " ms  " + Fix1$(fpsS) + " fps", cFG
End Sub

Sub KnobRow (y As Integer, lbl As String, valTxt As String, which As Integer)
    Dim dirn As Integer
    Txt PX + 6, y + 4, lbl + ": " + valTxt, cFG
    If Button%(PX + PW - 78, y, 34, BH, "-") Then dirn = -1
    If Button%(PX + PW - 40, y, 34, BH, "+") Then dirn = 1
    If dirn = 0 Then Exit Sub
    Select Case which
        Case 1 ' beams: x4 per click, 1 .. 4M
            If dirn > 0 Then
                If nParts * 4 > MAXPARTS Then Exit Sub
                If CDbl(nParts) * 4 * stepsPF > MAXWORK Then statusMsg = "Work limit: lower Steps first.": Exit Sub
                nParts = nParts * 4
            Else
                If nParts = 1 Then Exit Sub
                nParts = nParts \ 4
                If nParts < 1 Then nParts = 1
            End If
            SpawnCloud
            BuildOverlay
            statusMsg = BeamsTxt$ + "."
        Case 2 ' steps: x2 per click, 1 .. 16384
            If dirn > 0 Then
                If stepsPF >= 16384 Then Exit Sub
                If CDbl(nParts) * stepsPF * 2 > MAXWORK Then statusMsg = "Work limit: lower Beams first.": Exit Sub
                stepsPF = stepsPF * 2
            Else
                If stepsPF > 1 Then stepsPF = stepsPF \ 2
            End If
        Case 3 ' cloud size: 1E-7 .. 1E0
            cloudExp = _Clamp(cloudExp + dirn, -7, 0)
            SpawnCloud
            statusMsg = "Cloud 1E" + LTrim$(Str$(cloudExp)) + " - respawned."
        Case 4
            persistLvl = _Clamp(persistLvl + dirn, 1, 8)
        Case 5
            If dirn > 0 Then gainV = gainV * 1.25 Else gainV = gainV / 1.25
            gainV = _Clamp(gainV, 0.05, 50)
        Case 6
            bloomV = _Clamp(bloomV + dirn * 0.1, 0, 2)
            If bloomV < 0.05 Then bloomV = 0
    End Select
End Sub


'==========================================================
' Helpers
'==========================================================
' Up to 4 decimals, trailing zeros trimmed.
Function NumStr$ (v As Double)
    Dim r As _Integer64, s As String, neg As String, whole As _Integer64, frac As String
    If v < 0 Then neg = "-"
    r = Int(Abs(v) * 10000 + 0.5)
    whole = r \ 10000
    frac = Right$("0000" + LTrim$(Str$(r Mod 10000)), 4)
    Do While Len(frac) And Right$(frac, 1) = "0"
        frac = Left$(frac, Len(frac) - 1)
    Loop
    s = LTrim$(Str$(whole))
    If Len(frac) Then s = s + "." + frac
    If s = "0" Then neg = ""
    NumStr$ = neg + s
End Function

' Exactly one decimal, for the HUD (keeps the width steady).
Function Fix1$ (v As Single)
    Dim r As Long
    r = Int(Abs(v) * 10 + 0.5)
    Fix1$ = LTrim$(Str$(r \ 10)) + "." + LTrim$(Str$(r Mod 10))
End Function

'"1 beam", "65,536 beams"
Function BeamsTxt$ ()
    If nParts = 1 Then BeamsTxt$ = "1 beam" Else BeamsTxt$ = Commas$(nParts) + " beams"
End Function

' 4194304 -> 4,194,304
Function Commas$ (v As Long)
    Dim s As String, o As String, i As Integer, c As Integer
    s = LTrim$(Str$(v))
    For i = Len(s) To 1 Step -1
        o = Mid$(s, i, 1) + o
        c = c + 1
        If c Mod 3 = 0 And i > 1 Then o = "," + o
    Next
    Commas$ = o
End Function

'$Include:'ButtonUI.bm'
