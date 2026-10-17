' RayMaze.bas - a big generated maze for the RayGPU CUDA engine (librcgpu.so v2)
' with volumetric smoke and reflective, rippling water, all simulated and drawn
' on the GPUs. QB64-PE builds the maze, handles input, doors, minimap and HUD.
' Keep librcgpu.so (v2) in the same folder as this program and run it from there.
Option _Explicit

Declare Dynamic Library "./rcgpu"
    Function rc_init& (ByVal maxdev As Long, ByVal w As Long, ByVal h As Long, ByVal mw As Long, ByVal mh As Long)
    Sub rc_shutdown
    Sub rc_set_weight (ByVal dev As Long, ByVal wt As Single)
    Sub rc_set_map (ByVal wallPtr As _Offset, ByVal floorPtr As _Offset, ByVal ceilPtr As _Offset)
    Sub rc_set_texture (ByVal id As Long, ByVal pixels As _Offset)
    Sub rc_set_door (ByVal cx As Long, ByVal cy As Long, ByVal openAmt As Single)
    Sub rc_clear_doors
    Sub rc_set_sprites (ByVal sprPtr As _Offset, ByVal count As Long)
    Sub rc_camera (ByVal camX As Single, ByVal camY As Single, ByVal camAng As Single)
    Sub rc_params (ByVal fogDist As Single, ByVal fogColor As _Unsigned Long, ByVal shadeSides As Long)
    Function rc_smoke_setup& (ByVal res As Long)
    Sub rc_smoke_add (ByVal sx As Single, ByVal sy As Single, ByVal amt As Single, ByVal radius As Single)
    Sub rc_smoke_params (ByVal rise As Single, ByVal swirl As Single, ByVal decay As Single, ByVal sigma As Single, ByVal marchSteps As Long)
    Function rc_water_setup& (ByVal res As Long)
    Sub rc_water_drop (ByVal wx As Single, ByVal wy As Single, ByVal strength As Single)
    Sub rc_water_params (ByVal rainPerSec As Single, ByVal damping As Single)
    Sub rc_tick (ByVal dts As Single)
    Function rc_frame& (ByVal pixels As _Offset)
    Sub rc_stats (gpuMs As Single, hostMs As Single)
    Function rc_device_count& ()
    Function rc_gpu_ms! (ByVal dev As Long)
    Function rc_vram_mb! (ByVal dev As Long)
    Sub rc_last_error (msg As String, ByVal msglen As Long)
End Declare

Const SCR_W = 1280
Const SCR_H = 720
Const MAP_W = 129
Const MAP_H = 129
Const DOOR_TEX = 8
Const TEX_BARREL = 10
Const TEX_LAMP = 11
Const TEX_WOODFLOOR = 12
Const TEX_VENT = 13
Const WATER_ID = 63
Const MAX_SPR = 512
Const MAX_VENT = 64
Const FOG_COLOR = &HFF0C0E12~&

Dim Shared walls(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared floors(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared ceils(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared doorOpen(0 To MAP_W * MAP_H - 1) As Single
Dim Shared doorTarget(0 To MAP_W * MAP_H - 1) As Single
Dim Shared sprData(0 To MAX_SPR * 4 - 1) As Single ' 4 per sprite: x, y, texture, scale
Dim Shared nSpr As Long
Dim Shared ventX(0 To MAX_VENT - 1) As Long, ventY(0 To MAX_VENT - 1) As Long, nVent As Long
Dim Shared nadeX(0 To 7) As Single, nadeY(0 To 7) As Single, nadeLife(0 To 7) As Single
Dim Shared px As Single, py As Single, ang As Single

' effect settings the keys step through
Dim Shared smokeRes(0 To 6) As Long, sIdx As Long
smokeRes(0) = 0: smokeRes(1) = 4: smokeRes(2) = 8: smokeRes(3) = 12
smokeRes(4) = 16: smokeRes(5) = 20: smokeRes(6) = 24
Dim Shared marchList(0 To 3) As Long, kIdx As Long
marchList(0) = 16: marchList(1) = 32: marchList(2) = 64: marchList(3) = 128
Dim Shared waterRes(0 To 3) As Long, wIdx As Long
waterRes(0) = 0: waterRes(1) = 8: waterRes(2) = 16: waterRes(3) = 32
Dim Shared fxMsg As String

Dim scr As Long, m As _MEM, rc As Long, maxDev As Long, nUse As Long, d As Long, i As Long, k As Long
Dim kh As Long, fogOn As Long, mapOn As Long, hudOn As Long, rainOn As Long
Dim tNow As Double, tPrev As Double, tFps As Double, dt As Single, stepT As Single
Dim fps As Single, frames As Long
Dim spd As Single, turn As Single, mvx As Single, mvy As Single, dirX As Single, dirY As Single
Dim gpuMs As Single, hostMs As Single
Dim sumGpu As Single, sumHost As Single, devSum(0 To 7) As Single
Dim hud1 As String, hud2 As String, hud3 As String, hud4 As String, hud5 As String
Dim cellNow As Long, ddx As Single, ddy As Single

scr = _NewImage(SCR_W, SCR_H, 32)
Screen scr
_Title "RayMaze - CUDA ray caster with smoke and water"
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

Print "Making textures and a"; MAP_W; "x"; MAP_H; "maze..."
MakeTextures
NewLevel
sIdx = 2: kIdx = 1: wIdx = 2
ApplySmoke
ApplyWater

fogOn = 1: mapOn = 1: hudOn = 1: rainOn = 0
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
        Case 82, 114: rainOn = 1 - rainOn
        Case 86, 118
            ' V: smoke grid resolution (and VRAM) up a step
            sIdx = (sIdx + 1) Mod 7
            ApplySmoke
        Case 75, 107
            ' K: smoke ray-march quality
            kIdx = (kIdx + 1) Mod 4
        Case 66, 98
            ' B: water ripple resolution
            wIdx = (wIdx + 1) Mod 4
            ApplyWater
        Case 88, 120
            ThrowSmoke
        Case 78, 110
            ' N: a new maze
            NewLevel
            ApplySmoke
            ApplyWater
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
            ' the engine re-creates the effect grids empty, or turns them off if they no longer fit
            ApplySmoke
            ApplyWater
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

    ' ---- feed the effects
    k = 0
    For i = 0 To nVent - 1
        ddx = ventX(i) + 0.5 - px: ddy = ventY(i) + 0.5 - py
        If ddx * ddx + ddy * ddy < 900 And k < 20 Then
            rc_smoke_add ventX(i) + 0.5, ventY(i) + 0.5, 6, 0.45
            k = k + 1
        End If
    Next i
    For i = 0 To 7
        If nadeLife(i) > 0 Then
            rc_smoke_add nadeX(i), nadeY(i), 40, 0.9
            nadeLife(i) = nadeLife(i) - dt
        End If
    Next i
    ' footsteps make ripples when wading
    cellNow = Int(py) * MAP_W + Int(px)
    stepT = stepT - dt
    If floors(cellNow) = WATER_ID And (mvx <> 0 Or mvy <> 0) And stepT <= 0 Then
        rc_water_drop px, py, 0.7
        stepT = 0.14
    End If
    rc_smoke_params 0.22, 0.35, 0.93, 2.5, marchList(kIdx)
    If rainOn Then rc_water_params 25, 0.985 Else rc_water_params 0, 0.985
    rc_tick dt

    ' ---- simulate + draw on the GPUs, straight into the screen image
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
        hud1 = "RAYMAZE  -  " + _Trim$(Str$(nUse)) + " of " + _Trim$(Str$(maxDev)) + " GPUs   " + _Trim$(Str$(MAP_W)) + "x" + _Trim$(Str$(MAP_H)) + " maze   FPS:" + FixNum$(fps, 1, 7)
        hud2 = "GPU + copy:" + FixNum$(sumGpu / frames, 2, 7) + " ms    To screen:" + FixNum$(sumHost / frames, 2, 6) + " ms"
        hud3 = "Per GPU:"
        hud4 = "VRAM:   "
        For d = 0 To nUse - 1
            hud3 = hud3 + "  #" + _Trim$(Str$(d)) + FixNum$(devSum(d) / frames, 2, 7) + "ms"
            hud4 = hud4 + "  #" + _Trim$(Str$(d)) + FixNum$(rc_vram_mb(d), 0, 7) + "MB"
        Next d
        hud5 = "Smoke[V] " + SmokeText$ + "   Steps[K]" + FixNum$(CSng(marchList(kIdx)), 0, 4) + "   Water[B] " + WaterText$ + "   Rain[R] " + OnOff$(rainOn)
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
        Line (6, 6)-(860, 112), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(255, 210, 140)
        _PrintString (14, 12), hud1
        Color _RGB32(200, 220, 255)
        _PrintString (14, 30), hud2
        _PrintString (14, 48), hud3
        _PrintString (14, 66), hud4
        Color _RGB32(170, 230, 190)
        _PrintString (14, 84), hud5
        If fxMsg <> "" Then
            Color _RGB32(255, 110, 110)
            _PrintString (14, 120), fxMsg
        End If

        Line (6, SCR_H - 44)-(SCR_W - 6, SCR_H - 6), _RGBA32(0, 0, 0, 150), BF
        Color _RGB32(170, 170, 170)
        _PrintString (14, SCR_H - 40), "WASD move | Arrows or Q/E turn | Shift run | Space door | X smoke bomb | N new maze"
        _PrintString (14, SCR_H - 22), "V smoke grid | K smoke quality | B water ripples | R rain | M map | F fog | G GPUs | H HUD | Esc quit"
    End If

    _Display
Loop

rc_shutdown
_MemFree m
System

' ---- effects on / off and their sizes

Sub ApplySmoke
    Dim ok As Long
    fxMsg = ""
    ok = rc_smoke_setup(smokeRes(sIdx))
    If ok = 0 Then
        fxMsg = "Smoke grid " + _Trim$(Str$(smokeRes(sIdx))) + " does not fit in VRAM - smoke off"
        sIdx = 0
        ok = rc_smoke_setup(0)
    End If
End Sub

Sub ApplyWater
    Dim ok As Long
    ok = rc_water_setup(waterRes(wIdx))
    If ok = 0 Then
        fxMsg = "Ripple grid " + _Trim$(Str$(waterRes(wIdx))) + " does not fit in VRAM - ripples off"
        wIdx = 0
        ok = rc_water_setup(0)
    End If
End Sub

Function SmokeText$
    Dim r As Long
    r = smokeRes(sIdx)
    If r = 0 Then
        SmokeText$ = "off"
    Else
        SmokeText$ = _Trim$(Str$(r)) + " (" + _Trim$(Str$(MAP_W * r)) + "x" + _Trim$(Str$(MAP_H * r)) + "x" + _Trim$(Str$(r)) + ")"
    End If
End Function

Function WaterText$
    If waterRes(wIdx) = 0 Then WaterText$ = "mirror only" Else WaterText$ = "ripples " + _Trim$(Str$(waterRes(wIdx)))
End Function

' X: a smoke bomb lands a little way ahead and pours smoke for 4 seconds
Sub ThrowSmoke
    Dim i As Long, tx As Single, ty As Single, k As Single
    tx = px: ty = py
    For k = 0.5 To 2.5 Step 0.5
        If Passable%(px + Cos(ang) * k, py + Sin(ang) * k) = 0 Then Exit For
        tx = px + Cos(ang) * k: ty = py + Sin(ang) * k
    Next k
    For i = 0 To 7
        If nadeLife(i) <= 0 Then
            nadeX(i) = tx: nadeY(i) = ty: nadeLife(i) = 4
            Exit Sub
        End If
    Next i
End Sub

' ---- maze

' True while (x, y) is an uncarved maze cell inside the border
Function Uncarved% (x As Long, y As Long)
    Uncarved% = 0
    If x < 1 Or y < 1 Or x > MAP_W - 2 Or y > MAP_H - 2 Then Exit Function
    If walls(y * MAP_W + x) <> 0 Then Uncarved% = -1
End Function

Sub NewLevel
    Dim x As Long, y As Long, i As Long, sp As Long, nb As Long, k As Long, pick As Long
    Dim cx As Long, cy As Long, nx As Long, ny As Long
    Dim stX(0 To 8191) As Long, stY(0 To 8191) As Long, cand(0 To 3) As Long
    Dim r As Long, rw As Long, rh As Long, rx As Long, ry As Long, kind As Single

    ' 1) solid rock, wall texture changing by region
    For y = 0 To MAP_H - 1
        For x = 0 To MAP_W - 1
            i = y * MAP_W + x
            walls(i) = 1 + ((x \ 16) + (y \ 16) * 3) Mod 5
            floors(i) = 6: ceils(i) = 7
            doorOpen(i) = 0: doorTarget(i) = 0
        Next x
    Next y
    nSpr = 0: nVent = 0
    For i = 0 To 7
        nadeLife(i) = 0
    Next i

    ' 2) carve a maze on the odd cells (depth-first backtracker)
    walls(1 * MAP_W + 1) = 0
    sp = 0: stX(0) = 1: stY(0) = 1
    Do While sp >= 0
        cx = stX(sp): cy = stY(sp)
        nb = 0
        If Uncarved%(cx + 2, cy) Then cand(nb) = 0: nb = nb + 1
        If Uncarved%(cx - 2, cy) Then cand(nb) = 1: nb = nb + 1
        If Uncarved%(cx, cy + 2) Then cand(nb) = 2: nb = nb + 1
        If Uncarved%(cx, cy - 2) Then cand(nb) = 3: nb = nb + 1
        If nb = 0 Then
            sp = sp - 1
        Else
            pick = cand(Int(Rnd * nb))
            Select Case pick
                Case 0: nx = cx + 2: ny = cy
                Case 1: nx = cx - 2: ny = cy
                Case 2: nx = cx: ny = cy + 2
                Case Else: nx = cx: ny = cy - 2
            End Select
            walls(((cy + ny) \ 2) * MAP_W + (cx + nx) \ 2) = 0
            walls(ny * MAP_W + nx) = 0
            sp = sp + 1: stX(sp) = nx: stY(sp) = ny
        End If
    Loop

    ' 3) open rooms: some flooded, some with wooden floors, some with smoke vents
    For r = 1 To 30
        rw = 5 + 2 * Int(Rnd * 4): rh = 5 + 2 * Int(Rnd * 4)
        rx = 1 + 2 * Int(Rnd * ((MAP_W - rw - 2) \ 2))
        ry = 1 + 2 * Int(Rnd * ((MAP_H - rh - 2) \ 2))
        If rx < 6 And ry < 6 Then rx = rx + 8
        kind = Rnd
        For y = ry To ry + rh - 1
            For x = rx To rx + rw - 1
                i = y * MAP_W + x
                walls(i) = 0
                If kind < 0.3 Then
                    floors(i) = WATER_ID
                ElseIf kind < 0.55 Then
                    floors(i) = TEX_WOODFLOOR
                End If
            Next x
        Next y
        AddSprite rx + 0.5, ry + 0.5, TEX_LAMP, 1
        AddSprite rx + rw - 0.5, ry + rh - 0.5, TEX_LAMP, 1
        For k = 1 To 1 + Int(Rnd * 3)
            AddSprite rx + 1.5 + Int(Rnd * (rw - 2)), ry + 1.5 + Int(Rnd * (rh - 2)), TEX_BARREL, 0.75
        Next k
        If kind >= 0.3 And Rnd < 0.6 And nVent < MAX_VENT Then
            ventX(nVent) = rx + rw \ 2: ventY(nVent) = ry + rh \ 2
            AddSprite ventX(nVent) + 0.5, ventY(nVent) + 0.5, TEX_VENT, 0.3
            nVent = nVent + 1
        End If
    Next r

    ' 4) doors across some corridors (walls on both sides, open ahead and behind)
    For y = 2 To MAP_H - 3
        For x = 2 To MAP_W - 3
            i = y * MAP_W + x
            If walls(i) = 0 And floors(i) = 6 And Rnd < 0.03 Then
                If walls(i - 1) <> 0 And walls(i - 1) < 64 And walls(i + 1) <> 0 And walls(i + 1) < 64 And walls(i - MAP_W) = 0 And walls(i + MAP_W) = 0 Then
                    walls(i) = 64 + DOOR_TEX
                ElseIf walls(i - MAP_W) <> 0 And walls(i - MAP_W) < 64 And walls(i + MAP_W) <> 0 And walls(i + MAP_W) < 64 And walls(i - 1) = 0 And walls(i + 1) = 0 Then
                    walls(i) = 64 + DOOR_TEX
                End If
            End If
        Next x
    Next y

    ' 5) start in the corner, facing the open way
    px = 1.5: py = 1.5
    If walls(1 * MAP_W + 2) = 0 Then ang = 0 Else ang = _Pi / 2

    rc_set_map _Offset(walls()), _Offset(floors()), _Offset(ceils())
    rc_clear_doors
    rc_set_sprites _Offset(sprData()), nSpr
End Sub

Sub AddSprite (sx As Single, sy As Single, tex As Long, scl As Single)
    If nSpr >= MAX_SPR Then Exit Sub
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

' Minimap of the 41 x 41 cells around the player
Sub DrawMiniMap
    Const CS = 4
    Const MR = 20
    Dim x As Long, y As Long, ox As Long, oy As Long, cx As Long, cy As Long, i As Long, c As _Unsigned Long
    Dim hx As Single, hy As Single
    ox = SCR_W - (2 * MR + 1) * CS - 10: oy = 10
    Line (ox - 3, oy - 3)-(ox + (2 * MR + 1) * CS + 2, oy + (2 * MR + 1) * CS + 2), _RGBA32(0, 0, 0, 170), BF
    For y = -MR To MR
        For x = -MR To MR
            cx = Int(px) + x: cy = Int(py) + y
            If cx >= 0 And cy >= 0 And cx < MAP_W And cy < MAP_H Then
                i = cy * MAP_W + cx
                c = 0
                If walls(i) >= 64 Then
                    If doorOpen(i) > 0.85 Then c = _RGB32(90, 70, 20) Else c = _RGB32(220, 180, 40)
                ElseIf walls(i) > 0 Then
                    c = _RGB32(130, 130, 150)
                ElseIf floors(i) = WATER_ID Then
                    c = _RGB32(40, 90, 150)
                End If
                If c <> 0 Then Line (ox + (x + MR) * CS, oy + (y + MR) * CS)-Step(CS - 1, CS - 1), c, BF
            End If
        Next x
    Next y
    For i = 0 To nVent - 1
        cx = ventX(i) - Int(px): cy = ventY(i) - Int(py)
        If Abs(cx) <= MR And Abs(cy) <= MR Then Line (ox + (cx + MR) * CS, oy + (cy + MR) * CS)-Step(CS - 1, CS - 1), _RGB32(230, 230, 230), BF
    Next i
    hx = ox + (MR + px - Int(px)) * CS: hy = oy + (MR + py - Int(py)) * CS
    Circle (hx, hy), 2, _RGB32(255, 80, 80)
    Line (hx, hy)-(hx + Cos(ang) * 8, hy + Sin(ang) * 8), _RGB32(255, 80, 80)
End Sub

' ---- procedural 64x64 textures, sent to every GPU
Sub MakeTextures
    MakeTexture 1: MakeTexture 2: MakeTexture 3: MakeTexture 4: MakeTexture 5
    MakeTexture 6: MakeTexture 7: MakeTexture DOOR_TEX
    MakeTexture TEX_BARREL: MakeTexture TEX_LAMP: MakeTexture TEX_WOODFLOOR: MakeTexture TEX_VENT
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
        Case TEX_VENT ' smoke vent: a slatted metal box
            If x < 4 Or x > 59 Or y < 4 Or y > 59 Then
                r = 90: g = 92: b = 98
            ElseIf (y Mod 8) < 4 Then
                r = 25: g = 25: b = 28
            Else
                r = 120: g = 122: b = 128
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

Function OnOff$ (v As Long)
    If v Then OnOff$ = "ON" Else OnOff$ = "OFF"
End Function
