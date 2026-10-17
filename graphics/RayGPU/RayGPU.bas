' RayGPU.bas - Wolfenstein-style ray caster drawn by CUDA on the GTX 745s
' The CUDA library (librcgpu.so) casts the rays and draws every pixel;
' QB64-PE runs the game: map, textures, movement, doors, minimap and HUD.
' Keep librcgpu.so in the same folder as this program and run it from there.
Option _Explicit

Declare Dynamic Library "./rcgpu"
    Function rc_init& (ByVal maxdev As Long, ByVal w As Long, ByVal h As Long, ByVal mw As Long, ByVal mh As Long)
    Sub rc_shutdown
    Sub rc_set_weight (ByVal dev As Long, ByVal wt As Single)
    Sub rc_set_map (ByVal wallPtr As _Offset, ByVal floorPtr As _Offset, ByVal ceilPtr As _Offset)
    Sub rc_set_cell (ByVal cx As Long, ByVal cy As Long, ByVal value As Long)
    Sub rc_set_texture (ByVal id As Long, ByVal pixels As _Offset)
    Sub rc_set_door (ByVal cx As Long, ByVal cy As Long, ByVal openAmt As Single)
    Sub rc_set_sprites (ByVal sprPtr As _Offset, ByVal count As Long)
    Sub rc_camera (ByVal camX As Single, ByVal camY As Single, ByVal camAng As Single)
    Sub rc_params (ByVal fogDist As Single, ByVal fogColor As _Unsigned Long, ByVal shadeSides As Long)
    Function rc_frame& (ByVal pixels As _Offset)
    Sub rc_stats (gpuMs As Single, hostMs As Single)
    Function rc_device_count& ()
    Function rc_gpu_ms! (ByVal dev As Long)
    Sub rc_last_error (msg As String, ByVal msglen As Long)
End Declare

Const SCR_W = 1280
Const SCR_H = 720
Const MAP_W = 24
Const MAP_H = 24
Const DOOR_TEX = 8
Const TEX_BARREL = 10
Const TEX_LAMP = 11
Const TEX_WOODFLOOR = 12
Const FOG_COLOR = &HFF0C0E12~&

Dim Shared walls(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared floors(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared ceils(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared doorOpen(0 To MAP_W * MAP_H - 1) As Single
Dim Shared doorTarget(0 To MAP_W * MAP_H - 1) As Single
Dim Shared sprData(0 To 511) As Single   ' 4 per sprite: x, y, texture, scale
Dim Shared nSpr As Long
Dim Shared px As Single, py As Single, ang As Single

Dim scr As Long, m As _MEM, rc As Long, maxDev As Long, nUse As Long, d As Long
Dim tx As Long, ty As Long, i As Long, rowS As String, ch As String
Dim kh As Long, fogOn As Long, mapOn As Long, hudOn As Long
Dim tNow As Double, tPrev As Double, tFps As Double, dt As Single
Dim fps As Single, frames As Long
Dim spd As Single, turn As Single, mvx As Single, mvy As Single, dirX As Single, dirY As Single
Dim gpuMs As Single, hostMs As Single
Dim sumGpu As Single, sumHost As Single, devSum(0 To 7) As Single
Dim hud1 As String, hud2 As String, hud3 As String

scr = _NewImage(SCR_W, SCR_H, 32)
Screen scr
_Title "RayGPU - CUDA ray caster"
_PrintMode _KeepBackground
Randomize Timer

' GPU 0 also drives the monitor, so it gets a slightly smaller band
rc_set_weight 0, 0.8

Print "Starting CUDA ray caster..."
rc = rc_init(5, SCR_W, SCR_H, MAP_W, MAP_H)
If rc = 0 Then
    ShowErr
    Print "Press any key to quit"
    Sleep
    System
End If
maxDev = rc_device_count
nUse = maxDev

' ---- load the map from the DATA lines below
nSpr = 0
For ty = 0 To MAP_H - 1
    Read rowS
    For tx = 0 To MAP_W - 1
        ch = Mid$(rowS, tx + 1, 1)
        i = ty * MAP_W + tx
        walls(i) = 0: floors(i) = 6: ceils(i) = 7
        doorOpen(i) = 0: doorTarget(i) = 0
        Select Case ch
            Case "1" To "5": walls(i) = Asc(ch) - 48
            Case "D": walls(i) = 64 + DOOR_TEX
            Case "B": AddSprite tx + 0.5, ty + 0.5, TEX_BARREL, 0.75
            Case "L": AddSprite tx + 0.5, ty + 0.5, TEX_LAMP, 1
            Case "P": px = tx + 0.5: py = ty + 0.5: ang = 0
        End Select
        ' wooden floors in the start room and the bottom room
        If (tx >= 1 And tx <= 4 And ty >= 1 And ty <= 4) Or (tx >= 6 And tx <= 14 And ty >= 18 And ty <= 20) Then floors(i) = TEX_WOODFLOOR
    Next tx
Next ty

MakeTextures
rc_set_map _Offset(walls()), _Offset(floors()), _Offset(ceils())
rc_set_sprites _Offset(sprData()), nSpr

fogOn = 1: mapOn = 1: hudOn = 1
m = _MemImage(scr)
tPrev = Timer(0.001): tFps = tPrev

Do
    tNow = Timer(0.001)
    dt = tNow - tPrev
    If dt < 0 Or dt > 0.1 Then dt = 0.016
    tPrev = tNow

    ' ---- one-shot keys
    kh = _KeyHit
    Select Case kh
        Case 27: Exit Do
        Case 32: ToggleDoor
        Case 77, 109: mapOn = 1 - mapOn
        Case 70, 102: fogOn = 1 - fogOn
        Case 72, 104: hudOn = 1 - hudOn
        Case 71, 103
            ' G: cycle how many GPUs share the work (1..max)
            nUse = (nUse Mod maxDev) + 1
            rc = rc_init(nUse, SCR_W, SCR_H, MAP_W, MAP_H)
            If rc = 0 Then
                ShowErr
                _Display
                Sleep
                Exit Do
            End If
    End Select
    If _Exit Then Exit Do

    ' ---- movement
    spd = 3 * dt
    If _KeyDown(100304) Or _KeyDown(100303) Then spd = spd * 2
    turn = 2.4 * dt
    If _KeyDown(19200) Or _KeyDown(113) Or _KeyDown(81) Then ang = ang - turn
    If _KeyDown(19712) Or _KeyDown(101) Or _KeyDown(69) Then ang = ang + turn
    dirX = Cos(ang): dirY = Sin(ang)
    mvx = 0: mvy = 0
    If _KeyDown(119) Or _KeyDown(87) Or _KeyDown(18432) Then mvx = mvx + dirX: mvy = mvy + dirY
    If _KeyDown(115) Or _KeyDown(83) Or _KeyDown(20480) Then mvx = mvx - dirX: mvy = mvy - dirY
    If _KeyDown(100) Or _KeyDown(68) Then mvx = mvx - dirY: mvy = mvy + dirX
    If _KeyDown(97) Or _KeyDown(65) Then mvx = mvx + dirY: mvy = mvy - dirX
    TryMove mvx * spd, mvy * spd
    AnimateDoors dt

    ' ---- draw the 3D view on the GPUs, straight into the screen image
    If fogOn Then rc_params 9, FOG_COLOR, 1 Else rc_params 0, FOG_COLOR, 1
    rc_camera px, py, ang
    rc = rc_frame(m.OFFSET)
    If rc = 0 Then
        ShowErr
        _Display
        Sleep
        Exit Do
    End If
    rc_stats gpuMs, hostMs

    ' ---- average the timings and rebuild the HUD text twice a second
    sumGpu = sumGpu + gpuMs
    sumHost = sumHost + hostMs
    For d = 0 To nUse - 1
        devSum(d) = devSum(d) + rc_gpu_ms(d)
    Next d
    frames = frames + 1
    If tNow - tFps >= 0.5 Then
        fps = frames / (tNow - tFps)
        hud1 = "RAYGPU  -  " + _Trim$(Str$(nUse)) + " of " + _Trim$(Str$(maxDev)) + " GPUs   " + _Trim$(Str$(SCR_W)) + "x" + _Trim$(Str$(SCR_H)) + "   FPS:" + FixNum$(fps, 1, 7)
        hud2 = "GPU + copy:" + FixNum$(sumGpu / frames, 2, 7) + " ms    To screen:" + FixNum$(sumHost / frames, 2, 6) + " ms"
        hud3 = "Per GPU:"
        For d = 0 To nUse - 1
            hud3 = hud3 + "  #" + _Trim$(Str$(d)) + FixNum$(devSum(d) / frames, 2, 6) + "ms"
        Next d
        For d = 0 To 7
            devSum(d) = 0
        Next d
        sumGpu = 0: sumHost = 0
        frames = 0
        tFps = tNow
    End If

    ' ---- overlays
    If mapOn Then DrawMiniMap
    If hudOn Then
        Line (6, 6)-(640, 76), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(255, 210, 140)
        _PrintString (14, 12), hud1
        Color _RGB32(200, 220, 255)
        _PrintString (14, 30), hud2
        _PrintString (14, 48), hud3

        Line (6, SCR_H - 26)-(SCR_W - 6, SCR_H - 6), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(170, 170, 170)
        _PrintString (14, SCR_H - 22), "WASD move | Arrows or Q/E turn | Shift run | Space door | M map | F fog | G GPUs | H HUD | Esc quit"
    End If

    _Display
Loop

rc_shutdown
_MemFree m
System

' ---- 24 x 24 map:  1-5 walls  D door  B barrel  L lamp  P player  . floor
Data "111111111111111111111111"
Data "1....1........2........1"
Data "1.P..1..B.....2....L...1"
Data "1....D........2........1"
Data "1....1........2222D22221"
Data "11D111.................1"
Data "1.........D......D.....1"
Data "1...L.......B......L...1"
Data "1......................1"
Data "133D33333333..44444D4441"
Data "1.....3.......4........1"
Data "1..B..3.......4...B....1"
Data "1.....D.......D........1"
Data "1.....3.......4........1"
Data "1L....3...L...4....L...1"
Data "133D333.......4444444441"
Data "1......................1"
Data "1....55555D55555.......1"
Data "1....5.........5...B...1"
Data "1....5...L.....5.......1"
Data "1....5.........D.......1"
Data "1....55555555555...L...1"
Data "1......................1"
Data "111111111111111111111111"

Sub AddSprite (sx As Single, sy As Single, tex As Long, scl As Single)
    If nSpr >= 128 Then Exit Sub
    sprData(nSpr * 4 + 0) = sx
    sprData(nSpr * 4 + 1) = sy
    sprData(nSpr * 4 + 2) = tex
    sprData(nSpr * 4 + 3) = scl
    nSpr = nSpr + 1
End Sub

Function Passable% (fx As Single, fy As Single)
    Dim cx As Long, cy As Long, i As Long
    cx = Int(fx): cy = Int(fy)
    If cx < 0 Or cy < 0 Or cx >= MAP_W Or cy >= MAP_H Then
        Passable% = 0
        Exit Function
    End If
    i = cy * MAP_W + cx
    If walls(i) = 0 Then
        Passable% = -1
    ElseIf walls(i) >= 64 And doorOpen(i) > 0.85 Then
        Passable% = -1
    Else
        Passable% = 0
    End If
End Function

' Slide along walls: try x and y separately, keeping a small radius
Sub TryMove (mx As Single, my As Single)
    Const RAD = 0.22
    Dim nx As Single, ny As Single
    If mx <> 0 Then
        nx = px + mx
        If Passable%(nx + Sgn(mx) * RAD, py - RAD) And Passable%(nx + Sgn(mx) * RAD, py + RAD) Then px = nx
    End If
    If my <> 0 Then
        ny = py + my
        If Passable%(px - RAD, ny + Sgn(my) * RAD) And Passable%(px + RAD, ny + Sgn(my) * RAD) Then py = ny
    End If
End Sub

' Space: open or close the first door within reach in front of the player
Sub ToggleDoor
    Dim cx As Long, cy As Long, i As Long, k As Single
    For k = 0.5 To 1.5 Step 0.25
        cx = Int(px + Cos(ang) * k): cy = Int(py + Sin(ang) * k)
        If cx >= 0 And cy >= 0 And cx < MAP_W And cy < MAP_H Then
            i = cy * MAP_W + cx
            If walls(i) >= 64 Then
                If doorTarget(i) > 0.5 Then doorTarget(i) = 0 Else doorTarget(i) = 1
                Exit Sub
            End If
        End If
    Next k
End Sub

' Slide doors toward their target and tell the GPUs about any change
Sub AnimateDoors (dts As Single)
    Dim i As Long, o As Single, pc As Long
    pc = Int(py) * MAP_W + Int(px)
    For i = 0 To MAP_W * MAP_H - 1
        If walls(i) >= 64 Then
            o = doorOpen(i)
            If doorTarget(i) > o Then
                o = o + 1.5 * dts
                If o > 1 Then o = 1
            ElseIf doorTarget(i) < o And i <> pc Then
                o = o - 1.5 * dts
                If o < 0 Then o = 0
            End If
            If o <> doorOpen(i) Then
                doorOpen(i) = o
                rc_set_door i Mod MAP_W, i \ MAP_W, o
            End If
        End If
    Next i
End Sub

Sub DrawMiniMap
    Const CS = 6
    Dim x As Long, y As Long, ox As Long, oy As Long, i As Long, c As _Unsigned Long
    ox = SCR_W - MAP_W * CS - 10: oy = 10
    Line (ox - 3, oy - 3)-(ox + MAP_W * CS + 2, oy + MAP_H * CS + 2), _RGBA32(0, 0, 0, 160), BF
    For y = 0 To MAP_H - 1
        For x = 0 To MAP_W - 1
            i = y * MAP_W + x
            If walls(i) > 0 Then
                If walls(i) >= 64 Then
                    If doorOpen(i) > 0.85 Then c = _RGB32(90, 70, 20) Else c = _RGB32(220, 180, 40)
                Else
                    c = _RGB32(150, 150, 170)
                End If
                Line (ox + x * CS, oy + y * CS)-Step(CS - 2, CS - 2), c, BF
            End If
        Next x
    Next y
    For i = 0 To nSpr - 1
        Line (ox + sprData(i * 4) * CS - 1, oy + sprData(i * 4 + 1) * CS - 1)-Step(2, 2), _RGB32(90, 200, 120), BF
    Next i
    Circle (ox + px * CS, oy + py * CS), 2, _RGB32(255, 80, 80)
    Line (ox + px * CS, oy + py * CS)-(ox + (px + Cos(ang) * 1.5) * CS, oy + (py + Sin(ang) * 1.5) * CS), _RGB32(255, 80, 80)
End Sub

' ---- procedural 64x64 textures, sent to every GPU
Sub MakeTextures
    MakeTexture 1: MakeTexture 2: MakeTexture 3: MakeTexture 4: MakeTexture 5
    MakeTexture 6: MakeTexture 7: MakeTexture DOOR_TEX
    MakeTexture TEX_BARREL: MakeTexture TEX_LAMP: MakeTexture TEX_WOODFLOOR
End Sub

Sub MakeTexture (id As Long)
    Dim img As Long, x As Long, y As Long, mm As _MEM, oldDest As Long
    img = _NewImage(64, 64, 32)
    oldDest = _Dest
    _Dest img
    _DontBlend img
    For y = 0 To 63
        For x = 0 To 63
            PSet (x, y), TexPixel~&(id, x, y)
        Next x
    Next y
    _Dest oldDest
    mm = _MemImage(img)
    rc_set_texture id, mm.OFFSET
    _MemFree mm
    _FreeImage img
End Sub

Function TexPixel~& (id As Long, x As Long, y As Long)
    Dim n As Single, r As Single, g As Single, b As Single, a As Long
    Dim rowN As Long, bx As Long, hw As Single, ddx As Single, dd As Single
    n = 0.85 + Rnd * 0.3
    a = 255
    Select Case id
        Case 1 ' red brick
            rowN = y \ 8
            bx = (x + (rowN Mod 2) * 8) Mod 16
            If (y Mod 8) = 7 Or bx = 15 Then
                r = 150: g = 145: b = 135
            Else
                r = 155: g = 50: b = 38
            End If
        Case 2 ' grey stone blocks
            If (x Mod 32) = 0 Or (y Mod 32) = 0 Then
                r = 55: g = 55: b = 60
            Else
                r = 115 + ((x \ 32 + (y \ 32) * 3) Mod 3) * 12: g = r: b = r + 6
            End If
        Case 3 ' wood planks
            If (x Mod 16) = 0 Then
                r = 45: g = 28: b = 14
            Else
                r = 125 + Sin(y * 0.35 + (x \ 16) * 2.1 + x * 0.15) * 14: g = r * 0.62: b = r * 0.32
            End If
        Case 4 ' blue metal panel with rivets
            r = 70: g = 92: b = 135
            If x < 2 Or y < 2 Or x > 61 Or y > 61 Then r = 40: g = 52: b = 80
            If (Abs(x - 6) < 2 Or Abs(x - 57) < 2) And (Abs(y - 6) < 2 Or Abs(y - 57) < 2) Then r = 185: g = 195: b = 215
        Case 5 ' mossy green stone
            If (x Mod 21) = 0 Or (y Mod 16) = 0 Then
                r = 40: g = 50: b = 35
            Else
                r = 80: g = 108 + Sin(x * 0.4 + y * 0.25) * 18: b = 62
            End If
        Case 6 ' floor tiles
            If ((x \ 32) + (y \ 32)) Mod 2 = 0 Then r = 92: g = 86: b = 78 Else r = 62: g = 58: b = 54
            If (x Mod 32) = 0 Or (y Mod 32) = 0 Then r = 38: g = 36: b = 34
        Case 7 ' ceiling panels
            r = 52: g = 54: b = 60
            If (x Mod 32) = 0 Or (y Mod 32) = 0 Then r = 32: g = 33: b = 37
        Case DOOR_TEX ' metal door with a hazard stripe
            r = 110: g = 112: b = 120
            If (y Mod 16) < 2 Then r = 75: g = 77: b = 84
            If y >= 28 And y <= 35 Then
                If ((x + y) \ 4) Mod 2 = 0 Then r = 210: g = 175: b = 30 Else r = 30: g = 30: b = 30
            End If
            If x < 3 Or x > 60 Then r = 60: g = 62: b = 68
        Case TEX_BARREL ' barrel on a transparent background
            hw = 15 + 4 * (1 - ((y - 38) / 25) ^ 2)
            ddx = Abs(x - 31.5)
            If y < 13 Or ddx > hw Then
                a = 0
            Else
                dd = 1 - (ddx / hw) * 0.55
                r = 125 * dd: g = 72 * dd: b = 36 * dd
                If (y >= 19 And y <= 21) Or (y >= 54 And y <= 56) Then r = 95 * dd: g = 95 * dd: b = 100 * dd
            End If
        Case TEX_LAMP ' glowing globe on a pole
            a = 0
            dd = Sqr((x - 31.5) ^ 2 + (y - 13) ^ 2)
            If dd < 9 Then
                a = 255: r = 255: g = 225 + (9 - dd) * 3: b = 120 + (9 - dd) * 12: n = 1
            ElseIf x >= 30 And x <= 33 And y >= 21 And y <= 59 Then
                a = 255: r = 60: g = 60: b = 66
            ElseIf x >= 24 And x <= 39 And y >= 58 Then
                a = 255: r = 48: g = 48: b = 52
            End If
        Case TEX_WOODFLOOR ' floor boards
            If (y Mod 8) = 0 Or ((x + (y \ 8) * 23) Mod 64) = 0 Then
                r = 50: g = 32: b = 18
            Else
                r = 120 + Sin(x * 0.3 + (y \ 8) * 1.7) * 12: g = r * 0.6: b = r * 0.3
            End If
    End Select
    If a = 0 Then
        TexPixel~& = _RGBA32(0, 0, 0, 0)
    Else
        TexPixel~& = _RGBA32(_Clamp(r * n, 0, 255), _Clamp(g * n, 0, 255), _Clamp(b * n, 0, 255), a)
    End If
End Function

Sub ShowErr
    Dim msg As String
    msg = Space$(512)
    rc_last_error msg, Len(msg)
    Color _RGB32(255, 90, 90)
    Print "CUDA error: "; ZStr$(msg)
End Sub

' Trim a C string at its null terminator
Function ZStr$ (s As String)
    Dim p As Long
    p = InStr(s, Chr$(0))
    If p > 0 Then ZStr$ = Left$(s, p - 1) Else ZStr$ = RTrim$(s)
End Function

' Fixed-width number: always 'decs' decimals, right-aligned in 'wid' characters,
' so HUD text doesn't shift around as the values change
Function FixNum$ (x As Single, decs As Long, wid As Long)
    Dim sc As Long, v As Long, t As String
    sc = 10 ^ decs
    v = Int(Abs(x) * sc + 0.5)
    t = _Trim$(Str$(v \ sc))
    If decs > 0 Then t = t + "." + Right$(String$(decs, "0") + _Trim$(Str$(v Mod sc)), decs)
    If x < 0 Then t = "-" + t
    If Len(t) < wid Then t = Space$(wid - Len(t)) + t
    FixNum$ = t
End Function

Function Fmt1$ (x As Single)
    Dim t As String
    t = _Trim$(Str$(Int(x * 10 + 0.5) / 10))
    If Left$(t, 1) = "." Then t = "0" + t
    Fmt1$ = t
End Function

Function Fmt2$ (x As Single)
    Dim t As String
    t = _Trim$(Str$(Int(x * 100 + 0.5) / 100))
    If Left$(t, 1) = "." Then t = "0" + t
    Fmt2$ = t
End Function
