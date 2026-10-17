'============================================================
'  Schrodinger Wave Packet Demo   (QB64-PE 4.5.0)
'  Time-dependent 1D Schrodinger equation
'  i*hbar dPsi/dt = -(hbar^2/2m) d2Psi/dx2 + V(x)Psi
'
'  Method: Visscher staggered leapfrog (1991).
'  Split Psi = R + iI. With hbar = 1, m = 1 and
'  KC = hbar^2/(2m) = 1/2 :
'      dR/dt = -KC*I'' + V*I
'      dI/dt = +KC*R'' - V*R
'  R is held at integer times, I at half-integer times,
'  which makes the explicit scheme stable and norm-preserving.
'
'  Controls:
'    1-5        select potential
'    UP/DOWN    change momentum k0
'    LEFT/RIGHT change barrier/well height
'    SPACE      pause / resume
'    R          reset the wave packet
'    ESC        quit
'
'  Every key also has an on-screen button in the bottom bar
'  (mouse-driven via the ButtonUI helper).
'============================================================

Option _Explicit

Const NX = 500 ' grid points (0..NX)
Const DX = 0.08 ' spatial step
Const DT = 0.002 ' time step (stable: DT << DX^2 / KC)
Const SUBFRAMES = 30 ' evolution steps per rendered frame

Const SW = 1000 ' screen width
Const SH = 700 ' screen height
Const CY = 480 ' horizontal axis (pixels)

' --- shared state --------------------------------------------------
Dim Shared psiR(NX) As Double ' real part of wavefunction
Dim Shared psiI(NX) As Double ' imaginary part
Dim Shared potV(NX) As Double ' potential energy V(x)
Dim Shared absorb(NX) As Double ' edge damping mask (1 = keep)

Dim Shared k0 As Double ' initial momentum of the packet
Dim Shared barrierV As Double ' barrier / well height
Dim Shared potMode As Integer ' 0 free 1 barrier 2 well 3 step 4 harmonic
Dim Shared paused As Integer
Dim Shared quitReq As Integer ' set by the on-screen Quit button

' Pull in the ButtonUI declarations (Type + Shared theme vars). Kept in the
' declaration area so the Type registers before any executable statement.
'$Include:'ButtonUI.bi'

'-------------------------------------------------------------------
' main
'-------------------------------------------------------------------
Screen _NewImage(SW, SH, 32)
_FullScreen
_Title "Schrodinger Wave Packet Demo - QB64-PE"

MouseInit ' ButtonUI: load the default slate-blue button theme

k0 = 8
barrierV = 40
potMode = 1
paused = 0

BuildAbsorber
SetPotential
InitPacket
InitHalfStep

Dim kh As Long

Do
    PollMouse ' ButtonUI: refresh mouse state once per frame

    kh = _KeyHit
    Select Case kh
        Case 27: Exit Do ' ESC
        Case 32: paused = 1 - paused ' SPACE
        Case 114, 82 ' R / r
            InitPacket: InitHalfStep
        Case 49 ' 1  free particle
            potMode = 0: SetPotential: InitPacket: InitHalfStep
        Case 50 ' 2  barrier
            potMode = 1: SetPotential: InitPacket: InitHalfStep
        Case 51 ' 3  well
            potMode = 2: SetPotential: InitPacket: InitHalfStep
        Case 52 ' 4  step
            potMode = 3: SetPotential: InitPacket: InitHalfStep
        Case 53 ' 5  harmonic
            potMode = 4: SetPotential: InitPacket: InitHalfStep
        Case 18432 ' UP
            k0 = _Clamp(k0 + 0.5, -20, 20): InitPacket: InitHalfStep
        Case 20480 ' DOWN
            k0 = _Clamp(k0 - 0.5, -20, 20): InitPacket: InitHalfStep
        Case 19712 ' RIGHT
            barrierV = _Clamp(barrierV + 5, 0, 200): SetPotential
        Case 19200 ' LEFT
            barrierV = _Clamp(barrierV - 5, 0, 200): SetPotential
    End Select

    If paused = 0 Then Evolve ' NOTE: Not is bitwise in QB64, so test = 0

    RenderFrame
    DrawControls ' on-screen button bar, drawn on top of the plot
    If quitReq Then Exit Do
    _Display
    _Limit 60
Loop

System

'-------------------------------------------------------------------
' Build a Gaussian wave packet:  exp(-(x-x0)^2/2sigma^2) * e^(i k0 x)
' normalized so the total probability is 1.
'-------------------------------------------------------------------
Sub InitPacket
    Dim i As Integer
    Dim x As Double, x0 As Double, sigma As Double
    Dim gaussian As Double, nrm As Double, amp As Double

    x0 = NX * DX * 0.25 ' start in the left quarter
    sigma = 1.5
    nrm = 0

    For i = 0 To NX
        x = i * DX
        gaussian = Exp(-((x - x0) ^ 2) / (2 * sigma * sigma))
        psiR(i) = gaussian * Cos(k0 * x)
        psiI(i) = gaussian * Sin(k0 * x)
        nrm = nrm + (psiR(i) ^ 2 + psiI(i) ^ 2) * DX
    Next i

    amp = 1 / Sqr(nrm)
    For i = 0 To NX
        psiR(i) = psiR(i) * amp
        psiI(i) = psiI(i) * amp
    Next i
End Sub

'-------------------------------------------------------------------
' Advance I by half a time step so R and I are staggered as the
' Visscher leapfrog expects.
'-------------------------------------------------------------------
Sub InitHalfStep
    Dim i As Integer
    Dim lap As Double
    Dim halfDT As Double
    Const KC = 0.5

    halfDT = DT * 0.5
    For i = 1 To NX - 1
        lap = (psiR(i + 1) - 2 * psiR(i) + psiR(i - 1)) / (DX * DX)
        psiI(i) = psiI(i) + halfDT * (KC * lap - potV(i) * psiR(i))
    Next i
End Sub

'-------------------------------------------------------------------
' Fill the potential array for the selected mode.
'-------------------------------------------------------------------
Sub SetPotential
    Dim i As Integer
    Dim x As Double, cx As Double, w As Double, omega As Double

    For i = 0 To NX
        potV(i) = 0
    Next i

    Select Case potMode
        Case 1 ' rectangular barrier (tunneling)
            cx = NX * DX * 0.6: w = 0.8
            For i = 0 To NX
                x = i * DX
                If Abs(x - cx) < w Then potV(i) = barrierV
            Next i
        Case 2 ' square well
            cx = NX * DX * 0.6: w = 2#
            For i = 0 To NX
                x = i * DX
                If Abs(x - cx) < w Then potV(i) = -barrierV
            Next i
        Case 3 ' potential step
            cx = NX * DX * 0.6
            For i = 0 To NX
                x = i * DX
                If x > cx Then potV(i) = barrierV
            Next i
        Case 4 ' harmonic oscillator
            cx = NX * DX * 0.5: omega = 1.2
            For i = 0 To NX
                x = i * DX
                potV(i) = 0.5 * omega * omega * (x - cx) ^ 2
            Next i
    End Select
End Sub

'-------------------------------------------------------------------
' Graded edge absorber: multiply R and I by a ramp that fades to 0
' near the walls so outgoing waves leave instead of reflecting.
'-------------------------------------------------------------------
Sub BuildAbsorber
    Dim i As Integer
    Dim edge As Integer, t As Double

    edge = 40
    For i = 0 To NX
        absorb(i) = 1
    Next i
    For i = 0 To edge
        t = i / edge
        absorb(i) = t * t
        absorb(NX - i) = t * t
    Next i
End Sub

'-------------------------------------------------------------------
' One rendered frame's worth of leapfrog evolution.
'-------------------------------------------------------------------
Sub Evolve
    Dim s As Integer, i As Integer
    Dim lap As Double
    Const KC = 0.5 ' hbar^2 / (2 m)

    For s = 1 To SUBFRAMES
        ' update R using the (half-step-ahead) I
        For i = 1 To NX - 1
            lap = (psiI(i + 1) - 2 * psiI(i) + psiI(i - 1)) / (DX * DX)
            psiR(i) = psiR(i) + DT * (-KC * lap + potV(i) * psiI(i))
        Next i
        ' update I using the freshly-updated R
        For i = 1 To NX - 1
            lap = (psiR(i + 1) - 2 * psiR(i) + psiR(i - 1)) / (DX * DX)
            psiI(i) = psiI(i) + DT * (KC * lap - potV(i) * psiR(i))
        Next i
        ' absorb at the edges
        For i = 0 To NX
            psiR(i) = psiR(i) * absorb(i)
            psiI(i) = psiI(i) * absorb(i)
        Next i
    Next s
End Sub

'-------------------------------------------------------------------
' Draw potential, probability density, Re and Im, plus the HUD.
'-------------------------------------------------------------------
Sub RenderFrame
    Dim i As Integer
    Dim xs As Double
    Dim x1 As Integer, x2 As Integer
    Dim dens As Double
    Dim yV1 As Integer, yV2 As Integer
    Dim yD1 As Integer, yD2 As Integer
    Dim yR1 As Integer, yR2 As Integer
    Dim yI1 As Integer, yI2 As Integer
    Dim pScale As Double, aScale As Double, vScale As Double

    pScale = 650 ' probability density
    aScale = 150 ' Re / Im amplitude
    vScale = 2.5 ' potential
    xs = SW / NX

    Line (0, 0)-(SW, SH), _RGB32(6, 8, 16), BF
    Line (0, CY)-(SW, CY), _RGB32(50, 55, 75) ' axis

    For i = 0 To NX - 1
        x1 = Int(i * xs)
        x2 = Int((i + 1) * xs)

        ' potential outline
        yV1 = CY - Int(_Clamp(potV(i) * vScale, -240, 240))
        yV2 = CY - Int(_Clamp(potV(i + 1) * vScale, -240, 240))
        Line (x1, yV1)-(x2, yV2), _RGB32(70, 200, 120)

        ' probability density (filled column + bright outline)
        dens = psiR(i) ^ 2 + psiI(i) ^ 2
        yD1 = CY - Int(_Clamp(dens * pScale, 0, 430))
        Line (x1, CY)-(x1, yD1), _RGB32(28, 78, 120)
        dens = psiR(i + 1) ^ 2 + psiI(i + 1) ^ 2
        yD2 = CY - Int(_Clamp(dens * pScale, 0, 430))
        Line (x1, yD1)-(x2, yD2), _RGB32(90, 210, 255)

        ' real part
        yR1 = CY - Int(_Clamp(psiR(i) * aScale, -170, 170))
        yR2 = CY - Int(_Clamp(psiR(i + 1) * aScale, -170, 170))
        Line (x1, yR1)-(x2, yR2), _RGB32(255, 210, 90)

        ' imaginary part
        yI1 = CY - Int(_Clamp(psiI(i) * aScale, -170, 170))
        yI2 = CY - Int(_Clamp(psiI(i + 1) * aScale, -170, 170))
        Line (x1, yI1)-(x2, yI2), _RGB32(255, 110, 190)
    Next i

    DrawHUD
End Sub

'-------------------------------------------------------------------
' On-screen text.
'-------------------------------------------------------------------
Sub DrawHUD
    Dim modeName As String

    Select Case potMode
        Case 0: modeName = "Free particle"
        Case 1: modeName = "Rectangular barrier (tunneling)"
        Case 2: modeName = "Square well"
        Case 3: modeName = "Potential step"
        Case 4: modeName = "Harmonic oscillator"
    End Select

    Color _RGB32(230, 235, 245)
    _PrintString (16, 12), "SCHRODINGER WAVE PACKET  -  " + modeName
    _PrintString (16, 30), "k0 = " + Fmt$(k0) + "    E = k0^2/2 = " + Fmt$(k0 * k0 * 0.5) + "    P total = " + Fmt$(TotalProb#)
    If potMode <> 0 And potMode <> 4 Then
        _PrintString (16, 48), "Barrier/Well height = " + Fmt$(barrierV)
    End If

    Color _RGB32(90, 210, 255): _PrintString (SW - 250, 12), "|psi|^2  probability"
    Color _RGB32(255, 210, 90): _PrintString (SW - 250, 30), "Re(psi)"
    Color _RGB32(255, 110, 190): _PrintString (SW - 250, 48), "Im(psi)"
    Color _RGB32(70, 200, 120): _PrintString (SW - 250, 66), "V(x)  potential"

    Color _RGB32(150, 160, 180)
    _PrintString (16, SH - 74), "Keys: 1-5 potential   UP/DOWN k0   LEFT/RIGHT height   SPACE pause   R reset   ESC quit"

    If paused Then
        Color _RGB32(255, 90, 90): _PrintString (SW \ 2 - 40, 12), "[ PAUSED ]"
    End If
End Sub

'-------------------------------------------------------------------
' Total probability (drifts down as the packet is absorbed at edges).
'-------------------------------------------------------------------
Function TotalProb# ()
    Dim i As Integer, sm As Double
    sm = 0
    For i = 0 To NX
        sm = sm + (psiR(i) ^ 2 + psiI(i) ^ 2) * DX
    Next i
    TotalProb# = sm
End Function

'-------------------------------------------------------------------
' Format a Double to two decimals, trimmed.
'-------------------------------------------------------------------
Function Fmt$ (v As Double)
    Dim r As Double
    r = Int(Abs(v) * 100 + 0.5) / 100
    If v < 0 Then r = -r
    Fmt$ = _Trim$(Str$(r))
End Function

'-------------------------------------------------------------------
' Bottom control bar. Immediate-mode buttons (ButtonUI) that mirror the
' keyboard controls. The five potential buttons show the ACTIVE mode as
' a disabled (greyed) button, so it doubles as a selection indicator.
' Note: the enabled flag is passed as (potMode <> n), which yields -1/0
' as ButtonEx% expects -- do NOT negate it (Not is bitwise in QB64, and
' -(a <> b) would yield 1 and invert the disabled state).
'-------------------------------------------------------------------
Sub DrawControls
    Dim by As Integer, bh As Integer, bx As Integer
    Dim pauseCap As String

    ' Panel backing so the buttons don't sit over the wave traces.
    Line (0, SH - 52)-(SW, SH), _RGB32(14, 17, 28), BF
    Line (0, SH - 52)-(SW, SH - 52), _RGB32(50, 55, 75)

    by = SH - 42: bh = 28
    bx = 16

    ' --- potential modes (active mode drawn disabled = selected) ---
    If ButtonEx%(bx, by, 64, bh, "Free", (potMode <> 0)) Then potMode = 0: SetPotential: InitPacket: InitHalfStep
    bx = bx + 64 + 6
    If ButtonEx%(bx, by, 84, bh, "Barrier", (potMode <> 1)) Then potMode = 1: SetPotential: InitPacket: InitHalfStep
    bx = bx + 84 + 6
    If ButtonEx%(bx, by, 64, bh, "Well", (potMode <> 2)) Then potMode = 2: SetPotential: InitPacket: InitHalfStep
    bx = bx + 64 + 6
    If ButtonEx%(bx, by, 64, bh, "Step", (potMode <> 3)) Then potMode = 3: SetPotential: InitPacket: InitHalfStep
    bx = bx + 64 + 6
    If ButtonEx%(bx, by, 92, bh, "Harmonic", (potMode <> 4)) Then potMode = 4: SetPotential: InitPacket: InitHalfStep
    bx = bx + 92 + 18

    ' --- momentum k0 ---
    If Button%(bx, by, 52, bh, "k0 -") Then k0 = _Clamp(k0 - 0.5, -20, 20): InitPacket: InitHalfStep
    bx = bx + 52 + 6
    If Button%(bx, by, 52, bh, "k0 +") Then k0 = _Clamp(k0 + 0.5, -20, 20): InitPacket: InitHalfStep
    bx = bx + 52 + 18

    ' --- barrier / well height ---
    If Button%(bx, by, 46, bh, "V -") Then barrierV = _Clamp(barrierV - 5, 0, 200): SetPotential
    bx = bx + 46 + 6
    If Button%(bx, by, 46, bh, "V +") Then barrierV = _Clamp(barrierV + 5, 0, 200): SetPotential
    bx = bx + 46 + 18

    ' --- pause / reset / quit ---
    If paused Then pauseCap = "Resume" Else pauseCap = "Pause"
    If Button%(bx, by, 78, bh, pauseCap) Then paused = 1 - paused
    bx = bx + 78 + 12
    If Button%(bx, by, 66, bh, "Reset") Then InitPacket: InitHalfStep
    bx = bx + 66 + 12
    If Button%(bx, by, 60, bh, "Quit") Then quitReq = -1
End Sub

' ButtonUI implementation goes at the very bottom of the program.
'$Include:'ButtonUI.bm'
