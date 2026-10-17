'=====================================================================
' SimTest.bas - headless check of QBGuide's helpers using the simulator
' Auto star -> calibrate -> guide, prints the results.
'=====================================================================
$Console:Only
Option _Explicit

'$Include:'ZWOCam.bi'
'$Include:'Guide.bi'
'$Include:'GuideUI.bi'

Dim r As Long, s As StarT, res As Long, n As Long, i As Long
Dim fl As Double, gr As Double, scl As Double, stepMs As Long, expMs As Long
Dim lockX As Double, lockY As Double, sra As Double, sra2 As Double, sde As Double, sde2 As Double
Dim cnt As Long, unguidedRa As Double, t0 As Double

GuideDefaults
fl = 600: gr = 0.5: expMs = 100
r = CamOpen(CAM_SIM, 1)
Print "open:"; r; " frame"; Cam.frameW; "x"; Cam.frameH
SimSetup fl, gr, 0
scl = ImageScale#(fl)
Print "scale arcsec/px:"; scl; "  sim raRate px/ms:"; Sim.raRate; " decRate:"; Sim.decRate

GrabFrame expMs
If StarAutoFind(s) = 0 Then Print "AUTOFIND FAILED": System
Print "auto star at"; s.x; s.y; " SNR"; s.snr; " HFD"; s.hfd
Print "expected near"; SimStarX(1); SimStarY(1)

stepMs = CalcCalStepMs(fl, gr, 0, GP.calDistance, 12)
Print "cal step ms:"; stepMs
CalBegin s.x, s.y, stepMs, -1
n = 0
Do
    WaitPulse
    GrabFrame expMs
    r = StarFind(s.x, s.y, GP.searchR, s)
    If StarWasFound(r) = 0 Then Print "star lost during cal, status"; r: System
    res = CalStep(s.x, s.y)
    n = n + 1
    If n Mod 5 = 0 Or res <> CAL_CONTINUE Then Print "  "; CalMsg
Loop Until res <> CAL_CONTINUE Or n > 300
If res <> CAL_DONE Then Print "CAL FAILED: "; CalMsg: System
Cal.calBin = 1: Cal.calDec = 0
Print "xAngle deg"; Cal.xAngle * 57.2958; " (sim"; Sim.angle * 57.2958; ")"
Print "xRate"; Cal.xRate; " (sim"; Sim.raRate; ")"
Print "yAngle deg"; Cal.yAngle * 57.2958; " (sim"; (Sim.angle + 1.5708) * 57.2958; ")"
Print "yRate"; Cal.yRate; " (sim"; Sim.decRate; ")"
Print "ortho err"; CalOrthoErr#

' guide
GuideReset
WaitPulse
GrabFrame expMs
r = StarFind(s.x, s.y, GP.searchR, s)
lockX = s.x: lockY = s.y
t0 = NowSec#
cnt = 0
For i = 1 To 400
    WaitPulse
    GrabFrame expMs
    r = StarFind(s.x, s.y, GP.searchR, s)
    If StarWasFound(r) Then
        GuideStep s.x - lockX, s.y - lockY
        If i > 50 Then
            cnt = cnt + 1
            sra = sra + GStep.raErr * scl: sra2 = sra2 + (GStep.raErr * scl) ^ 2
            sde = sde + GStep.decErr * scl: sde2 = sde2 + (GStep.decErr * scl) ^ 2
        End If
        If i Mod 50 = 0 Then Print Using "  #### ra ##.### dec ##.### px  pulse "; i; GStep.raErr; GStep.decErr;: Print DirName$(GStep.raDir); GStep.raMs; DirName$(GStep.decDir); GStep.decMs
    Else
        Print "lost at"; i
    End If
Next
Print "guided"; cnt; "frames over"; Int(NowSec# - t0); "s"
Print "RMS RA arcsec:"; Sqr(sra2 / cnt - (sra / cnt) ^ 2); "  Dec:"; Sqr(sde2 / cnt - (sde / cnt) ^ 2)
Print "sim seeing sigma arcsec 0.5, PE amplitude 9 arcsec / 480 s"
CamClose
System

Sub GrabFrame (ms As Long)
    Dim r As Long
    r = CamStart(ms, 100)
    Do While CamStatus <> EXP_DONE: _Limit 1000: Loop
    r = CamRead
End Sub

Sub WaitPulse
    Do While CamPulseBusy: _Limit 1000: Loop
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

'$Include:'ZWOCam.bm'
'$Include:'Guide.bm'
'$Include:'GuideUI.bm'
