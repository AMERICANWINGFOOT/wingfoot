' GPU3DDemo.bas - pixel-based 3D shapes drawn by the GPU (GPU3D.bi / GPU3D.bm + libg3d.so)
'
' Every shape here is placed by screen pixel, like CIRCLE: x, y, a size in pixels,
' a depth z (0 = exact size, bigger = farther away) and three angles in degrees.
' The GPUs ray-trace every pixel; QB64 only lists the shapes and draws the HUD.
' Keep libg3d.so next to this program and run it from that folder.
Option _Explicit

'$Include:'GPU3D.bi'

Const SCR_W = 1280
Const SCR_H = 720
Const NORB = 8
Const MAXNAME = 255

Dim Shared nm(0 To MAXNAME) As String
Dim Shared orbWire(0 To NORB - 1) As Long, orbId(0 To NORB - 1) As Long

Dim scr As Long, bgImg As Long, ok As Long, maxDev As Long, nUse As Long, d As Long, i As Long, k As Long
Dim kh As Long, paused As Long, persp As Long, wireAll As Long, outlineAll As Long, fogOn As Long
Dim fillMode As Long, cursorOn As Long, hudOn As Long, aIdx As Long, extra As Long, st As Long, hov As Long
Dim lb As Long, lbPrev As Long, mx As Single, my As Single, mz As Single
Dim t As Single, dt As Single, a As Single, ox As Single, oy As Single, oz As Single, spin As Single
Dim focal As Single, tNow As Double, tPrev As Double, tFps As Double
Dim fps As Single, frames As Long, gpuMs As Single, hostMs As Single, sumGpu As Single, sumHost As Single
Dim devSum(0 To 7) As Single
Dim hud1 As String, hud2 As String, hud3 As String, hud4 As String, hud5 As String
Dim aaList(0 To 3) As Long, orbClr(0 To NORB - 1) As _Unsigned Long

aaList(0) = 1: aaList(1) = 4: aaList(2) = 9: aaList(3) = 16
orbClr(0) = _RGB32(230, 80, 70): orbClr(1) = _RGB32(70, 150, 255)
orbClr(2) = _RGB32(240, 200, 70): orbClr(3) = _RGB32(190, 110, 240)
orbClr(4) = _RGB32(250, 150, 60): orbClr(5) = _RGB32(80, 230, 230)
orbClr(6) = _RGB32(255, 255, 255): orbClr(7) = _RGB32(120, 230, 110)

scr = _NewImage(SCR_W, SCR_H, 32)
Screen scr
_Title "GPU3D demo - pixel-based 3D shapes on the GPU"
_PrintMode _KeepBackground

Print "Starting GPU3D..."
ok = GPUInit(0)
If ok = 0 Then
    Color _RGB32(255, 90, 90)
    Print "GPU3D error: "; GPUError$
    Print "Press any key to quit"
    Sleep
    System
End If
maxDev = GPUCount
nUse = maxDev

MakeTextures
bgImg = MakeBackground

persp = 1: focal = SCR_W: aIdx = 1: fogOn = 1: cursorOn = 1: hudOn = 1
GPUPerspective focal
GPUQuality aaList(aIdx), 1.5
GPUFog 900, 4200, _RGB32(26, 30, 44)
tPrev = Timer(0.001): tFps = tPrev

Do
    tNow = Timer(0.001)
    dt = tNow - tPrev
    If dt < 0 Or dt > 0.1 Then dt = 0.016
    tPrev = tNow
    If paused = 0 Then t = t + dt

    ' ---- keys
    kh = _KeyHit
    Select Case kh
        Case 27: Exit Do
        Case 32: paused = 1 - paused
        Case 80, 112
            persp = 1 - persp
            If persp Then GPUPerspective focal Else GPUPerspective 0
        Case 18432
            focal = focal / 1.2
            If focal < 200 Then focal = 200
            If persp Then GPUPerspective focal
        Case 20480
            focal = focal * 1.2
            If focal > 8000 Then focal = 8000
            If persp Then GPUPerspective focal
        Case 65, 97
            aIdx = (aIdx + 1) Mod 4
            GPUQuality aaList(aIdx), 1.5
        Case 87, 119: wireAll = 1 - wireAll
        Case 79, 111: outlineAll = 1 - outlineAll
        Case 70, 102
            fogOn = 1 - fogOn
            If fogOn Then GPUFog 900, 4200, _RGB32(26, 30, 44) Else GPUFogOff
        Case 66, 98: fillMode = 1 - fillMode
        Case 67, 99: cursorOn = 1 - cursorOn
        Case 82, 114: mz = 0
        Case 72, 104: hudOn = 1 - hudOn
        Case 71, 103
            ' G: cycle how many GPUs share the work; textures and settings carry over
            nUse = (nUse Mod maxDev) + 1
            ok = GPUInit(nUse)
            If ok = 0 Then
                Color _RGB32(255, 90, 90)
                Print "GPU3D error: "; GPUError$
                _Display
                Sleep
                Exit Do
            End If
    End Select
    If _Exit Then Exit Do

    ' ---- mouse: the wheel pushes the cursor ball into the screen or pulls it out
    Do While _MouseInput
        mz = mz - _MouseWheel * 40
    Loop
    mx = _MouseX: my = _MouseY
    lb = _MouseButton(1)

    ' ---- the scene: just a list of shapes placed by pixel
    extra = 0
    If wireAll Then extra = extra Or G3_WIRE
    If outlineAll Then extra = extra Or G3_OUTLINE
    GPUBegin

    ' a big wooden crate in the middle
    GPUStyle extra
    GPUTexture 1
    GCube 640, 360, 0, 190, t * 40, t * 55, t * 12, _RGB32(255, 255, 255)
    Tag "crate (textured cube)"
    GPUTexture 0

    ' eight shapes orbiting it: in front of it (z < 0) they grow, behind it (z > 0) they shrink
    For i = 0 To NORB - 1
        a = t * 0.6 + i * 2 * _Pi / NORB
        ox = 640 + Cos(a) * 400
        oz = Sin(a) * 400
        oy = 360 + Sin(a * 2 + i) * 50
        spin = t * (50 + i * 9)
        st = extra Or G3_SHINY
        If (i Mod 6) = 0 Or (i Mod 6) >= 4 Then st = extra
        If orbWire(i) Then st = extra Or G3_WIRE
        GPUStyle st
        Select Case i Mod 6
            Case 0
                GPUTexture 4
                GBox ox, oy, oz, 130, 80, 80, spin, spin * 0.7, 0, orbClr(i)
                Tag "brick box"
                GPUTexture 0
            Case 1
                GBall ox, oy, oz, 110, orbClr(i)
                Tag "ball"
            Case 2
                GCylinder ox, oy, oz, 80, 120, spin, 0, spin * 0.5, orbClr(i)
                Tag "cylinder"
            Case 3
                GCone ox, oy, oz, 100, 120, spin * 0.6, 0, spin * 0.4, orbClr(i)
                Tag "cone"
            Case 4
                GPyramid ox, oy, oz, 110, 100, 0, spin, 0, orbClr(i)
                Tag "pyramid"
            Case Else
                GDiamond ox, oy, oz, 100, 0, spin, spin * 0.3, orbClr(i)
                Tag "diamond"
        End Select
        orbId(i) = GPULastShape
    Next i

    ' a wireframe globe and a textured planet
    GPUStyle G3_WIRE
    GSphere 130, 560, 0, 200, 20, t * 30, 0, _RGB32(90, 230, 120)
    Tag "wire globe"
    GPUStyle extra Or G3_SHINY
    GPUTexture 3
    GSphere 1140, 170, 0, 190, 15, -t * 25, 0, _RGB32(255, 255, 255)
    Tag "planet (textured sphere)"
    GPUTexture 0

    ' a row of cubes going straight into the screen: same x and y, only z changes
    GPUStyle extra Or G3_OUTLINE
    For k = 0 To 9
        GCube 1150, 620, k * 400, 90, 0, t * 30 + k * 12, 0, _RGB32(110, 120, 255)
        Tag "cube at z =" + Str$(k * 400)
    Next k

    ' the cursor ball sits exactly at the mouse pixel
    If cursorOn Then
        GPUStyle extra Or G3_SHINY
        GBall mx, my, mz, 100, _RGB32(255, 200, 60)
        Tag "cursor ball"
    End If

    ' ---- draw: over a QB64 picture, or onto a plain fill (all on the GPU)
    If fillMode Then
        GPUDrawFill _RGB32(16, 18, 26)
    Else
        _PutImage , bgImg
        GPUDraw
    End If
    If G3Ok = 0 Then
        Color _RGB32(255, 90, 90)
        Print "GPU3D error: "; GPUError$
        _Display
        Sleep
        Exit Do
    End If

    ' QB64's own CIRCLE at the same pixel and radius as the cursor ball
    If cursorOn Then Circle (mx, my), 50, _RGB32(255, 255, 255)

    ' ---- which shape is under the mouse? Click an orbiting shape to make it wireframe.
    hov = -1
    If cursorOn = 0 Then
        hov = GPUPick(mx, my)
        If lb And lbPrev = 0 Then
            For i = 0 To NORB - 1
                If orbId(i) = hov Then orbWire(i) = 1 - orbWire(i)
            Next i
        End If
    End If
    lbPrev = lb

    ' ---- timings, averaged twice a second
    g3_stats gpuMs, hostMs
    sumGpu = sumGpu + gpuMs
    sumHost = sumHost + hostMs
    For d = 0 To nUse - 1
        devSum(d) = devSum(d) + g3_gpu_ms(d)
    Next d
    frames = frames + 1
    If tNow - tFps >= 0.5 Then
        fps = frames / (tNow - tFps)
        hud1 = "GPU3D DEMO  -  " + _Trim$(Str$(nUse)) + " of " + _Trim$(Str$(maxDev)) + " GPUs   " + _Trim$(Str$(g3_count)) + " shapes   FPS:" + FixNum$(fps, 1, 7)
        hud2 = "GPU + copy:" + FixNum$(sumGpu / frames, 2, 7) + " ms    Blend on CPU:" + FixNum$(sumHost / frames, 2, 6) + " ms"
        hud3 = "Per GPU:"
        For d = 0 To nUse - 1
            hud3 = hud3 + "  #" + _Trim$(Str$(d)) + FixNum$(devSum(d) / frames, 2, 7) + "ms"
        Next d
        For d = 0 To 7
            devSum(d) = 0
        Next d
        sumGpu = 0: sumHost = 0
        frames = 0
        tFps = tNow
    End If
    hud4 = "Perspective[P] "
    If persp Then hud4 = hud4 + _Trim$(Str$(Int(focal))) Else hud4 = hud4 + "off"
    hud4 = hud4 + "   AA[A] " + _Trim$(Str$(aaList(aIdx))) + "   Wire[W] " + OnOff$(wireAll) + "   Outline[O] " + OnOff$(outlineAll) + "   Fog[F] " + OnOff$(fogOn)
    If fillMode Then hud4 = hud4 + "   Back[B] fill" Else hud4 = hud4 + "   Back[B] picture"
    If cursorOn Then
        hud5 = "Cursor ball[C]  x" + Str$(Int(mx)) + "  y" + Str$(Int(my)) + "  z" + Str$(Int(mz)) + "   (wheel = depth, R = back to z 0)"
    ElseIf hov >= 0 And hov <= MAXNAME Then
        hud5 = "Under the mouse: shape #" + _Trim$(Str$(hov)) + "  " + nm(hov) + "   (click an orbiting shape to toggle wire)"
    Else
        hud5 = "Under the mouse: nothing   (C brings the cursor ball back)"
    End If

    ' ---- overlays
    If hudOn Then
        Line (6, 6)-(760, 104), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(255, 210, 140)
        _PrintString (14, 12), hud1
        Color _RGB32(200, 220, 255)
        _PrintString (14, 30), hud2
        _PrintString (14, 48), hud3
        Color _RGB32(170, 230, 190)
        _PrintString (14, 66), hud4
        Color _RGB32(255, 240, 160)
        _PrintString (14, 84), hud5

        Line (6, SCR_H - 26)-(SCR_W - 6, SCR_H - 6), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(170, 170, 170)
        _PrintString (14, SCR_H - 22), "Mouse + wheel move the ball | Up/Down perspective | P A W O F B C toggles | G GPUs | Space pause | H HUD | Esc quit"
    End If

    _Display
Loop

GPUShutdown
System

' remember a name for the shape just added (shown when the mouse is over it)
Sub Tag (s As String)
    Dim n As Long
    n = GPULastShape
    If n >= 0 And n <= MAXNAME Then nm(n) = s
End Sub

' ---- the picture behind the shapes, drawn once with ordinary QB64 commands
Function MakeBackground&
    Dim img As Long, x As Long, y As Long, oldDest As Long
    img = _NewImage(SCR_W, SCR_H, 32)
    oldDest = _Dest
    _Dest img
    For y = 0 To SCR_H - 1
        Line (0, y)-(SCR_W - 1, y), _RGB32(18 + y \ 14, 22 + y \ 12, 36 + y \ 9)
    Next y
    For x = 0 To SCR_W - 1 Step 40
        Line (x, 0)-(x, SCR_H - 1), _RGBA32(255, 255, 255, 14)
    Next x
    For y = 0 To SCR_H - 1 Step 40
        Line (0, y)-(SCR_W - 1, y), _RGBA32(255, 255, 255, 14)
    Next y
    Color _RGB32(120, 130, 160)
    _PrintMode _KeepBackground
    _PrintString (14, SCR_H - 46), "This grid and gradient are plain QB64 drawing - the GPU draws the shapes on top"
    _Dest oldDest
    MakeBackground& = img
End Function

' ---- procedural 128 x 128 textures sent to the GPUs
Sub MakeTextures
    Dim id As Long, img As Long, x As Long, y As Long, oldDest As Long
    For id = 1 To 4
        img = _NewImage(128, 128, 32)
        oldDest = _Dest
        _Dest img
        For y = 0 To 127
            For x = 0 To 127
                PSet (x, y), TexPixel~&(id, x, y)
            Next x
        Next y
        _Dest oldDest
        GPULoadTexture id, img
        _FreeImage img
    Next id
End Sub

Function TexPixel~& (id As Long, x As Long, y As Long)
    Dim n As Single, r As Single, g As Single, b As Single, v As Single, lat As Single
    Dim rowN As Long, bx As Long
    n = 0.88 + Rnd * 0.24
    Select Case id
        Case 1 ' wooden crate: planks, a frame and a diagonal brace
            r = 150 + Sin(y * 0.21 + (x \ 32) * 2.3) * 16: g = r * 0.66: b = r * 0.36
            If (x Mod 32) = 0 Then r = 70: g = 45: b = 22
            If Abs(x - y) < 7 Then r = 120: g = 80: b = 42
            If x < 12 Or y < 12 Or x > 115 Or y > 115 Then r = 105: g = 70: b = 36
            If (x = 12 Or y = 12 Or x = 115 Or y = 115) Then r = 50: g = 32: b = 16
        Case 2 ' checker
            If ((x \ 16) + (y \ 16)) Mod 2 = 0 Then r = 235: g = 235: b = 235 Else r = 70: g = 90: b = 140
        Case 3 ' a made-up planet: sea, land, ice caps
            v = Sin(x * 0.098 + 1.3) * Cos(y * 0.11) + Sin(x * 0.27 + y * 0.19) * 0.45 + Sin(x * 0.049 - y * 0.15) * 0.6
            lat = Abs(y - 63.5) / 63.5
            If v > 0.55 Then
                r = 70 + v * 40: g = 130 + v * 30: b = 60
                If v > 1.1 Then r = 140: g = 115: b = 80
            Else
                r = 25: g = 70 + v * 20: b = 160 + v * 30
            End If
            If lat > 0.82 Then r = 235: g = 240: b = 250
        Case 4 ' bricks
            rowN = y \ 16
            bx = (x + (rowN Mod 2) * 16) Mod 32
            If (y Mod 16) >= 14 Or bx >= 30 Then
                r = 170: g = 165: b = 155
            Else
                r = 165: g = 62: b = 45
            End If
    End Select
    TexPixel~& = _RGB32(_Clamp(r * n, 0, 255), _Clamp(g * n, 0, 255), _Clamp(b * n, 0, 255))
End Function

' Fixed-width number: always 'decs' decimals, right-aligned in 'wid' characters
Function FixNum$ (x As Single, decs As Long, wid As Long)
    Dim sc As Long, v As Long, s As String
    sc = 10 ^ decs
    v = Int(Abs(x) * sc + 0.5)
    s = _Trim$(Str$(v \ sc))
    If decs > 0 Then s = s + "." + Right$(String$(decs, "0") + _Trim$(Str$(v Mod sc)), decs)
    If x < 0 Then s = "-" + s
    If Len(s) < wid Then s = Space$(wid - Len(s)) + s
    FixNum$ = s
End Function

Function OnOff$ (v As Long)
    If v Then OnOff$ = "ON" Else OnOff$ = "OFF"
End Function

'$Include:'GPU3D.bm'
