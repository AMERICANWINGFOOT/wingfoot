'=======================================================================
'  W3Showcase.bas  --  Five-scene 3D wireframe showcase for the W3 helper
'  QB64-PE 4.5.0   --  needs W3.bi and W3.bm in the same folder
'
'  SCENES
'    1  Torus       spinning ring around a counter-spinning cube
'    2  Globe       lat/long sphere with an orbiting moon
'    3  Ripples     animated two-source wave surface (rebuilt each frame)
'    4  Knot        (2,3) torus-knot tube with a Frenet-frame cross section
'    5  Tunnel      endless curving fly-through - rings behind the camera
'                   are trimmed by W3's near-plane clip
'
'  KEYS   1-5 pick scene   Space next scene   arrows orbit   W/S zoom
'         (tunnel: W/S speed)   A auto-orbit   D depth cue   Esc quit
'=======================================================================
Option _Explicit

'$Include:'W3.bi'

Const SCRW = 960, SCRH = 640
Const NSCENES = 5

Dim Shared cBg As _Unsigned Long

Dim scName$(1 To NSCENES)
Dim scDist(1 To NSCENES) As Single
Dim scElev(1 To NSCENES) As Single
Dim scTgtY(1 To NSCENES) As Single

Dim grid As Long, torus As Long, core As Long
Dim globe As Long, moon As Long, moonPath As Long
Dim wave As Long, knot As Long, tunnel As Long

Dim scene As Integer, lastScene As Integer
Dim orbit As Single, elev As Single, dist As Single, tgtY As Single
Dim autoOrb As Integer
Dim tm As Single, travel As Single, speed As Single
Dim yw As Single, pt As Single
Dim k As Long
Dim frames As Long, fps As Long, fpsT As Double
Dim hud$

Screen _NewImage(SCRW, SCRH, 32)
_Title "W3 Showcase"
cBg = _RGB32(12, 14, 20)

W3Init
W3SetViewport SCRW, SCRH
W3SetLens 60, 0.15, 80
W3SetDepthCue -1, cBg

' ---- scene table: name, camera distance, height, look-at height ----
scName$(1) = "Torus": scDist(1) = 9: scElev(1) = 3.5: scTgtY(1) = 1.2
scName$(2) = "Globe": scDist(2) = 9: scElev(2) = 2.5: scTgtY(2) = 0
scName$(3) = "Ripples": scDist(3) = 11: scElev(3) = 5.5: scTgtY(3) = 0
scName$(4) = "Torus knot": scDist(4) = 10: scElev(4) = 3: scTgtY(4) = 0
scName$(5) = "Tunnel": scDist(5) = 0: scElev(5) = 0: scTgtY(5) = 0

' ---- static models, built once ----
grid = W3New&
W3Grid grid, 8, 1

torus = W3New&
BuildTorus torus, 2.2, 0.7, 28, 12
W3SetPos torus, 0, 1.2, 0

core = W3New&
W3Cube core, 1
W3SetPos core, 0, 1.2, 0

globe = W3New&
BuildSphere globe, 2, 12, 24

moon = W3New&
W3Cube moon, 0.5

moonPath = W3New&
BuildCircle moonPath, 3.4, 64

knot = W3New&
BuildKnot knot, 2, 3, 1.1, 0.32, 180, 6

' ---- dynamic models, rebuilt every frame ----
wave = W3New&
tunnel = W3New&

scene = 1: lastScene = 0
autoOrb = -1
speed = 0.08
fpsT = Timer

Do
    _Limit 60

    ' ---------------- input ----------------
    k = _KeyHit
    If k = 27 Then Exit Do
    If k = 32 Then scene = (scene Mod NSCENES) + 1
    If k >= 49 And k <= 48 + NSCENES Then scene = k - 48
    If k = 100 Or k = 68 Then w3cue = Not w3cue
    If k = 97 Or k = 65 Then autoOrb = Not autoOrb

    If scene <> lastScene Then
        dist = scDist(scene): elev = scElev(scene): tgtY = scTgtY(scene)
        orbit = 0.6
        If scene = 5 Then W3SetCueAmount 0.95 Else W3SetCueAmount 0.75
        lastScene = scene
    End If

    If _KeyDown(19200) Then orbit = orbit - 0.025
    If _KeyDown(19712) Then orbit = orbit + 0.025
    If _KeyDown(18432) Then elev = elev + 0.08
    If _KeyDown(20480) Then elev = elev - 0.08
    If scene = 5 Then
        If _KeyDown(119) Or _KeyDown(87) Then speed = speed + 0.002
        If _KeyDown(115) Or _KeyDown(83) Then speed = speed - 0.002
        speed = _Clamp(speed, 0, 0.4)
    Else
        If _KeyDown(119) Or _KeyDown(87) Then dist = dist - 0.08
        If _KeyDown(115) Or _KeyDown(83) Then dist = dist + 0.08
        dist = _Clamp(dist, 1.5, 40)
    End If

    ' ---------------- animate ----------------
    tm = tm + 1 / 60
    If autoOrb Then orbit = orbit + 0.004

    Cls , cBg

    Select Case scene
        Case 1 ' ---- torus + counter-spinning cube ----
            W3SetRot torus, tm * 0.7, tm * 0.45, tm * 0.2
            W3SetRot core, -tm * 0.9, -tm * 1.2, 0
            OrbitCam orbit, dist, elev, tgtY
            W3Draw grid, _RGB32(50, 70, 95)
            W3Draw torus, _RGB32(110, 200, 255)
            W3Draw core, _RGB32(255, 190, 90)

        Case 2 ' ---- globe + moon ----
            W3SetRot globe, 0, tm * 0.35, 0
            W3SetPos moon, Cos(tm * 0.8) * 3.4, 0, Sin(tm * 0.8) * 3.4
            W3SetRot moon, tm * 1.1, tm * 1.7, 0
            OrbitCam orbit, dist, elev, tgtY
            W3Draw moonPath, _RGB32(70, 80, 100)
            W3Draw globe, _RGB32(100, 230, 160)
            W3Draw moon, _RGB32(230, 230, 240)

        Case 3 ' ---- rippling surface ----
            BuildWave wave, 30, 0.4, tm
            OrbitCam orbit, dist, elev, tgtY
            W3Draw wave, _RGB32(120, 170, 255)

        Case 4 ' ---- torus knot ----
            W3SetRot knot, tm * 0.3, tm * 0.5, 0
            OrbitCam orbit, dist, elev, tgtY
            W3Draw knot, _RGB32(255, 120, 200)

        Case 5 ' ---- tunnel fly-through ----
            travel = travel + speed
            BuildTunnel tunnel, travel
            ' steer the camera along the tunnel's local slope
            yw = _Atan2(2.2 * 0.12 * Cos(travel * 0.12), 1)
            pt = _Atan2(-1.4 * 0.09 * Sin(travel * 0.09), 1)
            W3SetCamera 0, 0, 0, yw, pt
            W3Draw tunnel, _RGB32(255, 170, 80)
    End Select

    ' ---------------- HUD ----------------
    frames = frames + 1
    If Timer - fpsT >= 1 Or Timer < fpsT Then fps = frames: frames = 0: fpsT = Timer

    Color _RGB32(120, 200, 255)
    _PrintString (16, 14), "W3 SHOWCASE  -  " + LTrim$(Str$(scene)) + "/" + LTrim$(Str$(NSCENES)) + "  " + scName$(scene)
    Color _RGB32(140, 150, 170)
    If scene = 5 Then
        hud$ = "1-5 scene   Space next   W/S speed   D depth cue   Esc quit"
    Else
        hud$ = "1-5 scene   Space next   arrows orbit   W/S zoom   A auto-orbit   D depth cue   Esc quit"
    End If
    _PrintString (16, SCRH - 26), hud$
    hud$ = LTrim$(Str$(fps)) + " fps"
    If w3cue Then hud$ = hud$ + "   cue on" Else hud$ = hud$ + "   cue off"
    If scene <> 5 And Not autoOrb Then hud$ = hud$ + "   orbit held"
    _PrintString (SCRW - 16 - 8 * Len(hud$), 14), hud$

    _Display
Loop

W3FreeAll
System


'=======================================================================
' CAMERA
'=======================================================================
Sub OrbitCam (orb As Single, dst As Single, ht As Single, ty As Single)
    W3LookAt Sin(orb) * dst, ht, Cos(orb) * dst, 0, ty, 0
End Sub


'=======================================================================
' MODEL BUILDERS  (all add every vertex first, then the edges)
'=======================================================================

'--- Torus in the xz plane: bigR = ring radius, smallR = tube radius.
Sub BuildTorus (h As Long, bigR As Single, smallR As Single, nMaj As Integer, nMin As Integer)
    Dim i As Integer, j As Integer, a As Integer, b As Integer, dummy As Integer
    Dim u As Single, v As Single, x As Single, y As Single, z As Single

    W3Clear h
    For i = 0 To nMaj - 1
        u = i * 2 * _Pi / nMaj
        For j = 0 To nMin - 1
            v = j * 2 * _Pi / nMin
            x = (bigR + smallR * Cos(v)) * Cos(u)
            y = smallR * Sin(v)
            z = (bigR + smallR * Cos(v)) * Sin(u)
            dummy = W3AddVert%(h, x, y, z)
        Next j
    Next i

    For i = 0 To nMaj - 1
        For j = 0 To nMin - 1
            a = i * nMin + j
            b = i * nMin + ((j + 1) Mod nMin) '            around the tube
            W3AddEdge h, a, b
            b = ((i + 1) Mod nMaj) * nMin + j '            along the ring
            W3AddEdge h, a, b
        Next j
    Next i
End Sub


'--- Latitude/longitude sphere centred on the origin.
Sub BuildSphere (h As Long, rad As Single, nLat As Integer, nLon As Integer)
    Dim la As Integer, lo As Integer, a As Integer, b As Integer, dummy As Integer
    Dim phi As Single, th As Single, x As Single, y As Single, z As Single

    W3Clear h
    For la = 0 To nLat
        phi = la * _Pi / nLat
        For lo = 0 To nLon - 1
            th = lo * 2 * _Pi / nLon
            x = rad * Sin(phi) * Cos(th)
            y = rad * Cos(phi)
            z = rad * Sin(phi) * Sin(th)
            dummy = W3AddVert%(h, x, y, z)
        Next lo
    Next la

    For la = 0 To nLat
        For lo = 0 To nLon - 1
            a = la * nLon + lo
            If la > 0 And la < nLat Then '                 parallels (skip the poles)
                b = la * nLon + ((lo + 1) Mod nLon)
                W3AddEdge h, a, b
            End If
            If la < nLat Then '                            meridians
                b = (la + 1) * nLon + lo
                W3AddEdge h, a, b
            End If
        Next lo
    Next la
End Sub


'--- Flat circle in the xz plane.
Sub BuildCircle (h As Long, rad As Single, n As Integer)
    Dim i As Integer, a As Integer, b As Integer, dummy As Integer
    Dim x As Single, y As Single, z As Single

    W3Clear h
    y = 0
    For i = 0 To n - 1
        x = rad * Cos(i * 2 * _Pi / n)
        z = rad * Sin(i * 2 * _Pi / n)
        dummy = W3AddVert%(h, x, y, z)
    Next i
    For i = 0 To n - 1
        a = i: b = (i + 1) Mod n
        W3AddEdge h, a, b
    Next i
End Sub


'--- (p,q) torus-knot curve point at parameter t, scaled by sc.
Sub KnotPoint (p As Integer, q As Integer, sc As Single, t As Single, x As Single, y As Single, z As Single)
    Dim r As Single
    r = 2 + Cos(q * t)
    x = r * Cos(p * t) * sc
    y = -Sin(q * t) * sc
    z = r * Sin(p * t) * sc
End Sub


'--- Tube swept along a torus knot. The cross-section ring is oriented
'    with a finite-difference Frenet frame: T from the chord through the
'    neighbours, N from the second difference, B = T x N.
Sub BuildKnot (h As Long, p As Integer, q As Integer, sc As Single, tubeR As Single, nSeg As Integer, nSide As Integer)
    Dim i As Integer, s As Integer, a As Integer, b As Integer, dummy As Integer
    Dim t As Single, e As Single, tA As Single, tB As Single, ang As Single, ln As Single
    Dim cx As Single, cy As Single, cz As Single
    Dim ax As Single, ay As Single, az As Single
    Dim bx As Single, by As Single, bz As Single
    Dim tx As Single, ty As Single, tz As Single
    Dim nx As Single, ny As Single, nz As Single
    Dim qx As Single, qy As Single, qz As Single
    Dim x As Single, y As Single, z As Single

    W3Clear h
    e = 0.01
    For i = 0 To nSeg - 1
        t = i * 2 * _Pi / nSeg
        tA = t - e: tB = t + e
        KnotPoint p, q, sc, t, cx, cy, cz
        KnotPoint p, q, sc, tA, ax, ay, az
        KnotPoint p, q, sc, tB, bx, by, bz

        ' tangent
        tx = bx - ax: ty = by - ay: tz = bz - az
        ln = Sqr(tx * tx + ty * ty + tz * tz): If ln < 0.000001 Then ln = 0.000001
        tx = tx / ln: ty = ty / ln: tz = tz / ln

        ' normal (toward the centre of curvature)
        nx = ax + bx - 2 * cx: ny = ay + by - 2 * cy: nz = az + bz - 2 * cz
        ln = Sqr(nx * nx + ny * ny + nz * nz): If ln < 0.000001 Then ln = 0.000001
        nx = nx / ln: ny = ny / ln: nz = nz / ln

        ' binormal = T x N, then re-square N = B x T
        qx = ty * nz - tz * ny: qy = tz * nx - tx * nz: qz = tx * ny - ty * nx
        ln = Sqr(qx * qx + qy * qy + qz * qz): If ln < 0.000001 Then ln = 0.000001
        qx = qx / ln: qy = qy / ln: qz = qz / ln
        nx = qy * tz - qz * ty: ny = qz * tx - qx * tz: nz = qx * ty - qy * tx

        For s = 0 To nSide - 1
            ang = s * 2 * _Pi / nSide
            x = cx + tubeR * (Cos(ang) * nx + Sin(ang) * qx)
            y = cy + tubeR * (Cos(ang) * ny + Sin(ang) * qy)
            z = cz + tubeR * (Cos(ang) * nz + Sin(ang) * qz)
            dummy = W3AddVert%(h, x, y, z)
        Next s
    Next i

    For i = 0 To nSeg - 1
        For s = 0 To nSide - 1
            a = i * nSide + s
            b = i * nSide + ((s + 1) Mod nSide) '          ring
            W3AddEdge h, a, b
            b = ((i + 1) Mod nSeg) * nSide + s '           along the tube
            W3AddEdge h, a, b
        Next s
    Next i
End Sub


'--- Square grid of (n+1)^2 points displaced by two interfering ripples.
Sub BuildWave (h As Long, n As Integer, cell As Single, tt As Single)
    Dim i As Integer, j As Integer, a As Integer, b As Integer, dummy As Integer
    Dim x As Single, y As Single, z As Single, half As Single
    Dim d1 As Single, d2 As Single

    W3Clear h
    half = n * cell / 2
    For i = 0 To n
        z = i * cell - half
        For j = 0 To n
            x = j * cell - half
            d1 = Sqr((x - 1.5) * (x - 1.5) + (z - 1.5) * (z - 1.5))
            d2 = Sqr((x + 2) * (x + 2) + (z + 1) * (z + 1))
            y = 0.45 * Sin(d1 * 2.2 - tt * 3) / (1 + 0.25 * d1) + 0.35 * Sin(d2 * 2.6 - tt * 2.3) / (1 + 0.25 * d2)
            dummy = W3AddVert%(h, x, y, z)
        Next j
    Next i

    For i = 0 To n
        For j = 0 To n
            a = i * (n + 1) + j
            If j < n Then b = a + 1: W3AddEdge h, a, b
            If i < n Then b = a + n + 1: W3AddEdge h, a, b
        Next j
    Next i
End Sub


'--- Tunnel of rings in front of a camera sitting at the origin. Rings
'    are fixed in WORLD z (world z = ring number + Int(dist)), so they
'    stream past instead of swimming. Ring 0 is just behind the camera,
'    so its struts cross the near plane and get clipped by W3DrawEdge.
Sub BuildTunnel (h As Long, dist As Single)
    Const RINGS = 36, SIDES = 16, TRAD = 1.6
    Dim j As Integer, s As Integer, a As Integer, b As Integer, dummy As Integer
    Dim frac As Single, zl As Single, wz As Single, ang As Single
    Dim cx As Single, cy As Single, x As Single, y As Single

    W3Clear h
    frac = dist - Int(dist)
    For j = 0 To RINGS - 1
        zl = j - frac
        wz = j + Int(dist)
        ' curve offset relative to where the camera is right now
        cx = 2.2 * (Sin(wz * 0.12) - Sin(dist * 0.12))
        cy = 1.4 * (Cos(wz * 0.09) - Cos(dist * 0.09))
        For s = 0 To SIDES - 1
            ang = s * 2 * _Pi / SIDES + wz * 0.06
            x = cx + TRAD * Cos(ang)
            y = cy + TRAD * Sin(ang)
            dummy = W3AddVert%(h, x, y, zl)
        Next s
    Next j

    For j = 0 To RINGS - 1
        For s = 0 To SIDES - 1
            a = j * SIDES + s
            b = j * SIDES + ((s + 1) Mod SIDES)
            W3AddEdge h, a, b
            If j < RINGS - 1 Then
                b = (j + 1) * SIDES + s
                W3AddEdge h, a, b
            End If
        Next s
    Next j
End Sub

'$Include:'W3.bm'

