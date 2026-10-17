'==========================================================
' QBScope.bas  -  strange attractors on a simulated analog
'                 oscilloscope, with live knobs
'
' Built on "Arneodo Attractor on simulated analog oscilloscope"
' by K Moerman (2026), inspired by Bernd Ulmann's analog
' computer. Same phosphor trick: each segment is drawn with a
' low alpha so busy paths glow brighter, and a translucent black
' overlay (carrying the grid) fades old traces like a CRT.
'
' Added:
'   - six attractors: Arneodo, Lorenz, Rossler, Chua, Thomas,
'     Halvorsen
'   - live a/b/c knobs (+/-), Reset to defaults
'   - channel select: X-Y, X-Z, Y-Z
'   - Euler or Runge-Kutta 4 integration
'   - speed, persistence and glow knobs
'   - Fit (auto-scale to the attractor), Clear, Pause
'   - runaway guard: a diverging solution restarts itself
'
' Keys:  Left/Right attractor   1/2/3 channel   Space pause
'        F fit   C clear   R reset knobs   Esc quit
'
' Command line: a number 1-6 starts on that attractor
'   (1 Arneodo, 2 Lorenz, 3 Rossler, 4 Chua, 5 Thomas, 6 Halvorsen)
'
' Requires (same folder): ButtonUI.bi ButtonUI.bm
'==========================================================
Option _Explicit
'$Include:'ButtonUI.bi'

'--- layout --------------------------------------------------
Const SW = 960
Const SH = 640
Const SCX = 10 '       scope image position on screen
Const SCY = 10
Const SCW = 620 '      scope image size
Const SCH = 620
Const BRD = 30 '       border inside the scope image
Const DIVX = 10 '      grid divisions
Const DIVY = 8
Const PX = 646 '       control panel left edge
Const PW = 304 '       control panel width
Const BH = 24

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
Dim Shared sx As Double, sy As Double, sz As Double ' state x, y, z
Dim Shared chan As Integer '       1 = X-Y, 2 = X-Z, 3 = Y-Z
Dim Shared useRK4 As Integer
Dim Shared stepsPerFrame As Long
Dim Shared persist As Integer '    overlay alpha (higher = faster fade)
Dim Shared glow As Integer '       plot alpha (higher = brighter)
Dim Shared paused As Integer
Dim Shared quitFlag As Integer
Dim Shared statusMsg As String

' view: centre and half-range of x, y, z (set by Fit)
Dim Shared vC(1 To 3) As Double
Dim Shared vH(1 To 3) As Double

Dim Shared scopeImg As Long
Dim Shared ovlImg As Long
Dim Shared colPlot As _Unsigned Long
Dim Shared cBG As _Unsigned Long, cPanel As _Unsigned Long, cFG As _Unsigned Long
Dim Shared cDim As _Unsigned Long, cHot As _Unsigned Long, cScale As _Unsigned Long

Dim k As String

Screen _NewImage(SW, SH, 32)
_Title "QBScope - attractors on a simulated analog oscilloscope"
_ScreenMove _Middle
MouseInit
cBG = _RGB32(14, 16, 20)
cPanel = _RGB32(26, 29, 36)
cFG = _RGB32(200, 204, 210)
cDim = _RGB32(110, 116, 126)
cHot = _RGB32(70, 230, 90)
cScale = _RGB32(80, 80, 80)

scopeImg = _NewImage(SCW, SCH, 32)
ovlImg = _NewImage(SCW, SCH, 32)

SetupAttractors
chan = 2 '            X-Z, like the original
useRK4 = -1
stepsPerFrame = 15000
persist = 10
glow = 12
' optional start-up choice: QBScope 2  -> Lorenz, etc.
If _CommandCount > 0 Then
    SelectAttractor _Clamp(Val(Command$(1)), 1, NATT)
Else
    SelectAttractor ATT_ARNEODO
End If

'==========================================================
' Frame loop
'==========================================================
Do
    _Limit 60
    PollMouse
    k = InKey$
    If Len(k) Then HandleKey k

    If Not paused Then RunSteps stepsPerFrame
    ' fade + grid, then the scope face onto the screen
    _PutImage , ovlImg, scopeImg

    _Dest 0
    Cls , cBG
    _PutImage (SCX, SCY), scopeImg
    DrawPanel
    _Display
Loop Until quitFlag

System


'==========================================================
' Attractor definitions
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
    ClearScope
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
' The math: derivatives, one Euler or RK4 step
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
            ' piecewise-linear Chua diode: slope m0 inside |x|<1, m1 outside
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

' Advance sx, sy, sz by one time step h.
Sub StepOnce (h As Double)
    Dim k1x As Double, k1y As Double, k1z As Double
    Dim k2x As Double, k2y As Double, k2z As Double
    Dim k3x As Double, k3y As Double, k3z As Double
    Dim k4x As Double, k4y As Double, k4z As Double
    Dim hh As Double

    Deriv sx, sy, sz, k1x, k1y, k1z
    If Not useRK4 Then
        sx = sx + h * k1x: sy = sy + h * k1y: sz = sz + h * k1z
        Exit Sub
    End If
    hh = h / 2
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

Function ScrX! (v As Double)
    ScrX! = SCW / 2 + (v - vC(ChanH%)) / vH(ChanH%) * (SCW / 2 - BRD)
End Function

Function ScrY! (v As Double)
    ScrY! = SCH / 2 - (v - vC(ChanV%)) / vH(ChanV%) * (SCH / 2 - BRD)
End Function

' Compute and draw n points onto the scope image.
Sub RunSteps (n As Long)
    Dim i As Long, h As Double, ch As Integer, cv As Integer
    Dim x0 As Single, y0 As Single, x1 As Single, y1 As Single

    _Dest scopeImg
    h = attDt(att)
    ch = ChanH%: cv = ChanV%
    x0 = ScrX!(StateOf#(ch)): y0 = ScrY!(StateOf#(cv))
    For i = 1 To n
        StepOnce h
        If Runaway% Then
            RestartState
            statusMsg = "Solution ran away - restarted. Try smaller knob changes or RK4."
            Exit For
        End If
        x1 = ScrX!(StateOf#(ch)): y1 = ScrY!(StateOf#(cv))
        Line (x0, y0)-(x1, y1), colPlot
        x0 = x1: y0 = y1
    Next
    _Dest 0
End Sub


'==========================================================
' View: auto-scale, grid overlay
'==========================================================
' Run the attractor off-screen, skip the start-up transient,
' and size the view to what it then visits (plus a margin).
Sub FitView
    Dim i As Long, nSkip As Long, nRun As Long, v As Integer, val3 As Double
    Dim lo(1 To 3) As Double, hi(1 To 3) As Double

    RestartState
    nSkip = 20 / attDt(att)
    nRun = 200 / attDt(att)
    For i = 1 To nSkip
        StepOnce attDt(att)
        If Runaway% Then Exit For
    Next
    For v = 1 To 3
        lo(v) = StateOf#(v): hi(v) = lo(v)
    Next
    For i = 1 To nRun
        StepOnce attDt(att)
        If Runaway% Then Exit For
        For v = 1 To 3
            val3 = StateOf#(v)
            If val3 < lo(v) Then lo(v) = val3
            If val3 > hi(v) Then hi(v) = val3
        Next
    Next
    For v = 1 To 3
        If Runaway% Or hi(v) - lo(v) < 1E-9 Then
            vC(v) = 0: vH(v) = 10
        Else
            vC(v) = (lo(v) + hi(v)) / 2
            vH(v) = (hi(v) - lo(v)) / 2 * 1.08
        End If
    Next
    RestartState
    BuildOverlay
End Sub

Sub BuildOverlay
    Dim i As Integer, xs As Integer, ys As Integer, ln As String
    Dim gx As Integer, gy As Integer, gw As Integer, gh As Integer

    colPlot = _RGBA32(20, 255, 20, glow)
    gx = BRD: gy = BRD: gw = SCW - 2 * BRD: gh = SCH - 2 * BRD
    _Dest ovlImg
    Cls , _RGBA32(0, 0, 0, 0)
    Line (0, 0)-(SCW, SCH), _RGBA32(0, 0, 0, persist), BF
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
    _PrintString (gx + 1, 8), "QBScope  -  " + ChanName$(chan) + "   " + attName(att)
    ln = "CH1: " + NumStr$(2 * vH(ChanH%) / DIVX) + "/DIV   CH2: " + NumStr$(2 * vH(ChanV%) / DIVY) + "/DIV"
    _PrintString (gx + 1, SCH - BRD + 8), ln
    _Dest 0
End Sub

Sub ClearScope
    _Dest scopeImg
    Cls , _RGB32(0, 0, 0)
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
        Case "F": FitView: ClearScope: statusMsg = "View fitted."
        Case "C": ClearScope
        Case "R": ResetParms: statusMsg = "Knobs reset to defaults."
    End Select
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
    ClearScope
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
    y = 22
    Txt PX + 6, y, "ATTRACTOR", cDim
    y = y + 20
    If Button%(PX + 6, y, 30, BH, "<") Then PrevAtt
    Line (PX + 44, y)-(PX + PW - 46, y + BH), _RGB32(10, 12, 16), BF
    Txt PX + 44 + (PW - 90 - 8 * Len(attName(att))) \ 2, y + 4, attName(att), cHot
    If Button%(PX + PW - 38, y, 30, BH, ">") Then NextAtt

    ' equations
    y = y + 34
    For i = 1 To 3
        Txt PX + 6, y, Left$(attEq(att, i), 36), cFG
        y = y + 16
    Next

    ' knobs
    y = y + 14
    Txt PX + 6, y, "KNOBS", cDim
    y = y + 20
    For p = 1 To 3
        If p <= attNParm(att) Then
            Txt PX + 6, y + 4, attPName(att, p) + " = " + NumStr$(parm(p)), cFG
            If Button%(PX + PW - 78, y, 34, BH, "-") Then TurnKnob p, -1
            If Button%(PX + PW - 40, y, 34, BH, "+") Then TurnKnob p, 1
        Else
            Txt PX + 6, y + 4, "-", cDim
        End If
        y = y + 30
    Next
    If Button%(PX + 6, y, 140, BH, "Reset knobs") Then ResetParms: statusMsg = "Knobs reset to defaults."
    If Button%(PX + 154, y, 140, BH, "Restart trace") Then RestartState: ClearScope

    ' channels
    y = y + 40
    Txt PX + 6, y, "CHANNELS  (CH1 - CH2)", cDim
    y = y + 20
    For i = 1 To 3
        x = PX + 6 + (i - 1) * 98
        If Button%(x, y, 90, BH, ChanName$(i)) Then SetChan i
        If chan = i Then Mark x, y, 90
    Next

    ' integrator
    y = y + 36
    Txt PX + 6, y, "INTEGRATOR", cDim
    y = y + 20
    If Button%(PX + 6, y, 140, BH, "Euler") Then useRK4 = 0: statusMsg = "Euler: fast but drifts off the true path."
    If Not useRK4 Then Mark PX + 6, y, 140
    If Button%(PX + 154, y, 140, BH, "Runge-Kutta 4") Then useRK4 = -1: statusMsg = "RK4: four slope samples per step, far more accurate."
    If useRK4 Then Mark PX + 154, y, 140

    ' beam
    y = y + 40
    Txt PX + 6, y, "BEAM", cDim
    y = y + 20
    KnobRow y, "Speed", LTrim$(Str$(stepsPerFrame)) + " pts/frame", 1
    y = y + 30
    KnobRow y, "Persistence", LTrim$(Str$(persist)), 2
    y = y + 30
    KnobRow y, "Glow", LTrim$(Str$(glow)), 3

    ' actions
    y = y + 38
    If Button%(PX + 6, y, 70, BH, "Fit") Then FitView: ClearScope: statusMsg = "View fitted."
    If Button%(PX + 82, y, 70, BH, "Clear") Then ClearScope
    If paused Then
        If Button%(PX + 158, y, 70, BH, "Run") Then paused = 0
    Else
        If Button%(PX + 158, y, 70, BH, "Pause") Then paused = -1
    End If
    If Button%(PX + 234, y, 60, BH, "Quit") Then quitFlag = -1

    ' status
    Txt PX + 6, SCY + SCH - 40, Left$(statusMsg, 36), cDim
    Txt PX + 6, SCY + SCH - 22, Mid$(statusMsg, 37, 36), cDim
End Sub

Sub KnobRow (y As Integer, lbl As String, valTxt As String, which As Integer)
    Dim dirn As Integer
    Txt PX + 6, y + 4, lbl + ": " + valTxt, cFG
    If Button%(PX + PW - 78, y, 34, BH, "-") Then dirn = -1
    If Button%(PX + PW - 40, y, 34, BH, "+") Then dirn = 1
    If dirn = 0 Then Exit Sub
    Select Case which
        Case 1
            If dirn > 0 Then stepsPerFrame = stepsPerFrame * 2 Else stepsPerFrame = stepsPerFrame \ 2
            If stepsPerFrame < 250 Then stepsPerFrame = 250
            If stepsPerFrame > 64000 Then stepsPerFrame = 64000
        Case 2
            persist = _Clamp(persist + dirn * 2, 2, 80)
            BuildOverlay
        Case 3
            glow = _Clamp(glow + dirn * 2, 2, 80)
            BuildOverlay
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

'$Include:'ButtonUI.bm'
