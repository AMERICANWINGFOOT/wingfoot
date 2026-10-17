'=======================================================================
'  W3Demo.bas  --  Exercises the W3 wireframe helper
'  QB64-PE 4.5.0
'
'  Arrow keys orbit the camera, W/S move it in and out, D toggles depth
'  cueing. Drive the camera close to the grid to watch the near-plane
'  clip: grid lines behind you are trimmed instead of smearing.
'=======================================================================
Option _Explicit

'$Include:'W3.bi'

Const SCRW = 800, SCRH = 600

Dim Shared cBg As _Unsigned Long
Dim cube As Long, grid As Long, axes As Long
Dim orbit As Single, elev As Single, dist As Single
Dim spin As Single
Dim k As Long

Screen _NewImage(SCRW, SCRH, 32)
_Title "W3 wireframe demo"
cBg = _RGB32(18, 20, 26)

W3Init
W3SetViewport SCRW, SCRH
W3SetLens 60, 0.2, 60
W3SetDepthCue -1, cBg '        fade toward the background colour

grid = W3New&
W3Grid grid, 10, 1

cube = W3New&
W3Cube cube, 1.6
W3SetPos cube, 0, 0.8, 0

axes = W3New&
W3Axes axes, 1.5

orbit = 0.6: elev = 2.5: dist = 8
spin = 0

Do
    _Limit 60
    k = _KeyHit

    If _KeyDown(19200) Then orbit = orbit - 0.02 '   left
    If _KeyDown(19712) Then orbit = orbit + 0.02 '   right
    If _KeyDown(18432) Then elev = elev + 0.06 '     up
    If _KeyDown(20480) Then elev = elev - 0.06 '     down
    If _KeyDown(119) Or _KeyDown(87) Then dist = dist - 0.06
    If _KeyDown(115) Or _KeyDown(83) Then dist = dist + 0.06
    If k = 100 Or k = 68 Then w3cue = Not w3cue
    If k = 27 Then Exit Do

    If dist < 0.4 Then dist = 0.4
    If dist > 40 Then dist = 40

    spin = spin + 0.012
    W3SetRot cube, spin * 0.6, spin, 0

    W3LookAt Sin(orbit) * dist, elev, Cos(orbit) * dist, 0, 0.8, 0

    Cls , cBg
    W3Draw grid, _RGB32(70, 90, 110)
    W3Draw axes, _RGB32(150, 130, 90)
    W3Draw cube, _RGB32(120, 220, 180)

    Color _RGB32(150, 160, 180)
    _PrintString (16, 16), "arrows orbit    W/S dolly    D depth cue    ESC quit"
    _PrintString (16, 34), "dist" + Str$(Int(dist * 10) / 10) + "   cue" + Str$(w3cue)

    _Display
Loop

W3FreeAll
System

'$Include:'W3.bm'
