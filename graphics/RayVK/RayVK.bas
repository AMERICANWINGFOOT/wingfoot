' RayVK.bas -- Vulkan ray caster demo for QB64-PE 4.5.0 (Linux)
'
' The ray casting runs as a Vulkan compute shader in librcvk.so, so it works on
' any Vulkan GPU: the Intel Arc B580, the GTX 745s, even the CPU (llvmpipe).
' QB64-PE builds the map and textures, handles input, the minimap and the HUD.
' Keep librcvk.so in the same folder as this program and run it from there.
'
' Controls:  W/S or Up/Down = move    A/D = strafe    Left/Right = turn
'            Shift = run   Tab = switch GPU   R = readback method
'            F = fog       M = minimap        H = HUD     Esc = quit
'            E or Space = open/close the door in front of you
'
' Doors (D on the map) are wall cells with texture 8. While a door moves it
' switches to texture 9, which is redrawn each frame with the panel slid aside;
' when fully open the cell is cleared with rv_set_cell. Open doors close on
' their own after DOOR_HOLD seconds unless you are standing in the doorway.
'
' HUD: timings are smoothed every frame and the shown numbers refresh
' 4 times a second, in fixed-width columns, so the text holds still.

Option _Explicit

Declare Dynamic Library "./rcvk"
    Function rv_device_count& ()
    Sub rv_device_name (ByVal idx As Long, buf As String, ByVal buflen As Long)
    Function rv_current_device& ()
    Function rv_init& (ByVal dev As Long, ByVal w As Long, ByVal h As Long, ByVal mw As Long, ByVal mh As Long)
    Sub rv_shutdown
    Sub rv_set_map (ByVal wallPtr As _Offset, ByVal floorPtr As _Offset, ByVal ceilPtr As _Offset)
    Sub rv_set_cell (ByVal cx As Long, ByVal cy As Long, ByVal wallId As Long)
    Sub rv_set_texture (ByVal id As Long, ByVal pixels As _Offset)
    Sub rv_set_sprites (ByVal sprPtr As _Offset, ByVal count As Long)
    Sub rv_camera (ByVal camX As Single, ByVal camY As Single, ByVal camAng As Single)
    Sub rv_params (ByVal fogDist As Single, ByVal fogColor As _Unsigned Long, ByVal shadeSides As Long)
    Function rv_frame& (ByVal pixels As _Offset)
    Sub rv_stats (gpuMs As Single, hostMs As Single)
    Sub rv_last_error (msg As String, ByVal msglen As Long)
    Function rv_set_mode& (ByVal mode As Long)
    Function rv_mode& ()
    Sub rv_mode_name (buf As String, ByVal buflen As Long)
    Function rv_rebar_mb& ()
    Sub rv_stats2 (shaderMs As Single, copyMs As Single, waitMs As Single, cpuMs As Single)
End Declare

Const SCR_W = 1280
Const SCR_H = 720
Const MAP_W = 24
Const MAP_H = 24
Const TEX_FLOOR = 6
Const TEX_CEIL = 7
Const TEX_BARREL = 10
Const TEX_LAMP = 11
Const FOG_COLOR = &HFF0C0E12~&
Const MAX_SPR = 64
Const HUD_RATE = .25 ' seconds between HUD number refreshes
Const SMOOTH_K = .1 ' 0..1, smaller = steadier timing averages
Const TEX_DOOR = 8 ' closed door (wall id = texture id)
Const TEX_DOOR_MOVE = 9 ' the door that is currently sliding
Const MAX_DOOR = 32
Const DOOR_SPEED = 1.6 ' fraction of the slide per second (about 0.6 s)
Const DOOR_HOLD = 4 ' seconds an open door stays open
Const DOOR_GAP = &HFF08090C~& ' colour shown where the panel has slid away

Dim Shared walls(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared floors(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared ceils(0 To MAP_W * MAP_H - 1) As _Unsigned _Byte
Dim Shared tex(0 To 4095) As _Unsigned Long
Dim Shared sprData(0 To MAX_SPR * 4 - 1) As Single
Dim Shared nSpr As Long
Dim Shared px As Single, py As Single, ang As Single
Dim Shared fogOn As Long

Dim scr As Long, m As _MEM, rc As Long, devCount As Long, newDev As Long
Dim kk$, devName$, i As Long
Dim mapOn As Long, hudOn As Long
Dim tNow As Double, tPrev As Double, tFps As Double, dt As Single
Dim fps As Single, frames As Long
Dim spd As Single, turnSpd As Single, mvx As Single, mvy As Single, dirX As Single, dirY As Single
Dim gpuMs As Single, hostMs As Single
Dim Shared shaderMs As Single, copyMs As Single, waitMs As Single, cpuMs As Single
Dim Shared modeName$, rebarMB As Long, wantMode As Long

' smoothed timings (updated every frame) and the values the HUD shows (updated at HUD_RATE)
Dim Shared avHost As Single, avShader As Single, avCopy As Single, avWait As Single, avCpu As Single
Dim Shared shFps As Single, shHost As Single, shShader As Single, shCopy As Single, shWait As Single, shCpu As Single
Dim Shared avReady As Long

' doors: cell index, how far open (0..1), direction (1 opening, -1 closing, 0 still), hold timer
Dim Shared doorCell(0 To MAX_DOOR - 1) As Long, doorAmt(0 To MAX_DOOR - 1) As Single
Dim Shared doorDir(0 To MAX_DOOR - 1) As Long, doorWait(0 To MAX_DOOR - 1) As Single
Dim Shared nDoor As Long, movingDoor As Long
Dim Shared doorTex(0 To 4095) As _Unsigned Long, moveTex(0 To 4095) As _Unsigned Long
movingDoor = -1

scr = _NewImage(SCR_W, SCR_H, 32)
Screen scr
_Title "RayVK - Vulkan ray caster"
_PrintMode _KeepBackground

LoadMap

Print "Starting Vulkan ray caster..."
devCount = rv_device_count
If devCount = 0 Then
    ShowErr
    Print "Press any key to quit"
    Sleep
    System
End If
For i = 0 To devCount - 1
    Print "  Vulkan device"; i; ": "; DevNameOf$(i)
Next i

' -1 = let the library choose (it prefers an Intel discrete GPU, then any discrete GPU)
rc = rv_init(-1, SCR_W, SCR_H, MAP_W, MAP_H)
If rc = 0 Then
    ShowErr
    Print "Press any key to quit"
    Sleep
    System
End If
UploadScene
devName$ = DevNameOf$(-1)
UpdateModeInfo

m = _MemImage(scr)
fogOn = -1: mapOn = -1: hudOn = -1
tPrev = Timer(.001): tFps = tPrev

Do
    ' ---------- timing ----------
    tNow = Timer(.001)
    If tNow < tPrev Then tPrev = tNow: tFps = tNow ' midnight wrap
    dt = tNow - tPrev
    If dt > .1 Then dt = .1
    tPrev = tNow

    ' ---------- input ----------
    kk$ = InKey$
    Select Case UCase$(kk$)
        Case Chr$(27)
            Exit Do
        Case "F"
            fogOn = Not fogOn
            ApplyParams
        Case "M"
            mapOn = Not mapOn
        Case "H"
            hudOn = Not hudOn
        Case "E", " "
            UseDoor
        Case "R"
            ' next readback method that this GPU supports
            For i = 1 To 4
                If rv_set_mode((rv_mode + i) Mod 4) Then Exit For
            Next i
            wantMode = rv_mode
            UpdateModeInfo
            frames = 0: tFps = Timer(.001): avReady = 0
        Case Chr$(9)
            If devCount > 1 Then
                newDev = (rv_current_device + 1) Mod devCount
                rc = rv_init(newDev, SCR_W, SCR_H, MAP_W, MAP_H)
                If rc = 0 Then rc = rv_init(-1, SCR_W, SCR_H, MAP_W, MAP_H)
                If rc = 0 Then
                    Cls
                    ShowErr
                    Print "Press any key to quit"
                    _Display
                    Sleep
                    System
                End If
                UploadScene
                devName$ = DevNameOf$(-1)
                If rv_set_mode(wantMode) = 0 Then wantMode = 0
                UpdateModeInfo
                frames = 0: tFps = Timer(.001): avReady = 0
            End If
    End Select

    spd = 3.0 * dt
    If _KeyDown(100304) Or _KeyDown(100303) Then spd = spd * 2
    turnSpd = 2.4 * dt
    If _KeyDown(19200) Then ang = ang - turnSpd
    If _KeyDown(19712) Then ang = ang + turnSpd
    dirX = Cos(ang): dirY = Sin(ang)
    mvx = 0: mvy = 0
    If _KeyDown(18432) Or _KeyDown(119) Or _KeyDown(87) Then mvx = mvx + dirX: mvy = mvy + dirY
    If _KeyDown(20480) Or _KeyDown(115) Or _KeyDown(83) Then mvx = mvx - dirX: mvy = mvy - dirY
    If _KeyDown(97) Or _KeyDown(65) Then mvx = mvx + dirY: mvy = mvy - dirX
    If _KeyDown(100) Or _KeyDown(68) Then mvx = mvx - dirY: mvy = mvy + dirX
    MovePlayer mvx * spd, mvy * spd
    UpdateDoors dt

    ' ---------- render on the GPU straight into the screen image ----------
    rv_camera px, py, ang
    If rv_frame(m.OFFSET) = 0 Then
        Cls
        ShowErr
        Print "Press any key to quit"
        _Display
        Sleep
        Exit Do
    End If
    rv_stats gpuMs, hostMs
    rv_stats2 shaderMs, copyMs, waitMs, cpuMs
    SmoothStats hostMs

    ' ---------- overlays ----------
    frames = frames + 1
    If tNow - tFps >= HUD_RATE Then
        fps = frames / (tNow - tFps)
        frames = 0: tFps = tNow
        ' snapshot: the HUD only changes here, not every frame
        If shFps = 0 Then shFps = fps Else shFps = shFps * .5 + fps * .5
        shHost = avHost: shShader = avShader: shCopy = avCopy
        shWait = avWait: shCpu = avCpu
    End If
    If mapOn Then DrawMinimap
    If hudOn Then DrawHud devName$, devCount

    _Display
Loop

_MemFree m
rv_shutdown
System

' ---------------- map: # brick, S stone, W wood, M metal, G green tech
'                  D door, b barrel, l lamp, P player start, . empty
Data "########################"
Data "#P.....S..........M....#"
Data "#......S...l......M..b.#"
Data "#..l...S..........M....#"
Data "#......SSSSSDSSSSSM....#"
Data "#......................#"
Data "#######.....b.....MMMDMM"
Data "W...........WWW....G...#"
Data "W..b........W.W....G.l.#"
Data "W...........W.W....G...#"
Data "WWWW..WWWWWWWDW....GGGGG"
Data "#.............W........#"
Data "#..l..........W..l.....#"
Data "#.............W........#"
Data "#......GGGG...W...MMMMM#"
Data "#......G..G............#"
Data "#..b...G..G.....b......#"
Data "#......G.lG............#"
Data "#......GGDG...SSSSS..SS#"
Data "#.............S.......l#"
Data "#..l..........S.b......#"
Data "#.............S........#"
Data "#.....b.......S.....b..#"
Data "########################"

Sub LoadMap
    Dim tx As Long, ty As Long, i As Long, rowS As String, ch As String
    nSpr = 0: nDoor = 0: movingDoor = -1
    px = 1.5: py = 1.5: ang = 0
    For ty = 0 To MAP_H - 1
        Read rowS
        rowS = Left$(rowS + String$(MAP_W, "#"), MAP_W)
        For tx = 0 To MAP_W - 1
            ch = Mid$(rowS, tx + 1, 1)
            i = ty * MAP_W + tx
            floors(i) = TEX_FLOOR: ceils(i) = TEX_CEIL
            Select Case ch
                Case "#": walls(i) = 1
                Case "S": walls(i) = 2
                Case "W": walls(i) = 3
                Case "M": walls(i) = 4
                Case "G": walls(i) = 5
                Case "D": walls(i) = TEX_DOOR: AddDoor i
                Case "b": walls(i) = 0: AddSprite tx + .5, ty + .5, TEX_BARREL, .6
                Case "l": walls(i) = 0: AddSprite tx + .5, ty + .5, TEX_LAMP, 1
                Case "P": walls(i) = 0: px = tx + .5: py = ty + .5
                Case Else: walls(i) = 0
            End Select
            ' outer border is always solid
            If tx = 0 Or ty = 0 Or tx = MAP_W - 1 Or ty = MAP_H - 1 Then
                If walls(i) = 0 Then walls(i) = 1
            End If
        Next tx
    Next ty
End Sub

Sub AddSprite (sx As Single, sy As Single, texId As Long, scl As Single)
    If nSpr >= MAX_SPR Then Exit Sub
    sprData(nSpr * 4) = sx
    sprData(nSpr * 4 + 1) = sy
    sprData(nSpr * 4 + 2) = texId
    sprData(nSpr * 4 + 3) = scl
    nSpr = nSpr + 1
End Sub

' everything the GPU needs; called after every rv_init (also after a GPU switch)
Sub UploadScene
    Dim id As Long
    rv_set_map _Offset(walls(0)), _Offset(floors(0)), _Offset(ceils(0))
    Dim k As Long
    For id = 1 To 11
        If GenTexture(id) Then
            rv_set_texture id, _Offset(tex(0))
            If id = TEX_DOOR Then
                For k = 0 To 4095: doorTex(k) = tex(k): Next k
            End If
        End If
    Next id
    ' a door caught mid-slide by a GPU switch keeps its look
    If movingDoor >= 0 Then SetMoveTex doorAmt(movingDoor)
    rv_set_sprites _Offset(sprData(0)), nSpr
    ApplyParams
End Sub

Sub ApplyParams
    If fogOn Then
        rv_params 14, FOG_COLOR, 1
    Else
        rv_params 0, FOG_COLOR, 1
    End If
End Sub

' fills tex() with texture id; returns -1 if the id exists
Function GenTexture% (id As Long)
    Dim x As Long, y As Long, n As Single, c As _Unsigned Long
    Dim rowN As Long, offs As Long, dx As Single, dy As Single, d As Single
    Dim isEdge As Long
    Dim dummy As Single
    dummy = Rnd(-id) ' reseed per texture, so textures look the same after a GPU switch
    GenTexture% = -1
    For y = 0 To 63
        For x = 0 To 63
            n = Rnd
            Select Case id
                Case 1 ' red brick
                    rowN = y \ 16
                    offs = (rowN Mod 2) * 16
                    If (y Mod 16) = 0 Or ((x + offs) Mod 32) = 0 Then
                        c = _RGB32(75 + n * 15, 72 + n * 15, 70 + n * 15)
                    Else
                        c = _RGB32(150 + n * 35, 52 + n * 20, 38 + n * 10)
                    End If
                Case 2 ' grey stone blocks
                    offs = ((y \ 32) Mod 2) * 16
                    If (y Mod 32) < 2 Or ((x + offs) Mod 32) < 2 Then
                        c = _RGB32(40, 40, 44)
                    Else
                        c = _RGB32(105 + n * 40, 105 + n * 40, 110 + n * 40)
                    End If
                Case 3 ' wood planks
                    If (x Mod 16) = 0 Then
                        c = _RGB32(50, 30, 15)
                    Else
                        d = Sin((y + (x \ 16) * 23) * .35 + Sin(x * .9) * 1.5)
                        c = _RGB32(120 + d * 18 + n * 12, 78 + d * 12 + n * 8, 40 + d * 6)
                    End If
                Case 4 ' metal panel with rivets
                    isEdge = (x < 2 Or y < 2 Or x > 61 Or y > 61)
                    dx = (x Mod 56) - 4: dy = (y Mod 56) - 4
                    If isEdge Then
                        c = _RGB32(60, 64, 70)
                    ElseIf dx * dx + dy * dy <= 4 Then
                        c = _RGB32(210, 215, 220)
                    Else
                        c = _RGB32(120 + y + n * 10, 125 + y + n * 10, 135 + y + n * 10)
                    End If
                Case 5 ' green tech panel
                    If (x Mod 16) = 0 Or (y Mod 16) = 0 Then
                        c = _RGB32(40, 220, 120)
                    Else
                        c = _RGB32(15 + n * 10, 60 + n * 25, 35 + n * 10)
                    End If
                Case 6 ' floor tiles
                    If ((x \ 32) + (y \ 32)) Mod 2 Then
                        c = _RGB32(95 + n * 15, 95 + n * 15, 100 + n * 15)
                    Else
                        c = _RGB32(60 + n * 12, 60 + n * 12, 66 + n * 12)
                    End If
                Case 7 ' ceiling panels
                    If (x Mod 32) = 0 Or (y Mod 32) = 0 Then
                        c = _RGB32(25, 25, 30)
                    Else
                        c = _RGB32(70 + n * 8, 68 + n * 8, 62 + n * 8)
                    End If
                Case TEX_DOOR, TEX_DOOR_MOVE ' steel sliding door: frame, ribs, handle
                    If x < 3 Or x > 60 Or y < 3 Or y > 60 Then
                        c = _RGB32(45, 48, 55)
                    ElseIf (y Mod 12) < 2 Then
                        c = _RGB32(65, 72, 86)
                    ElseIf x >= 50 And x <= 53 And y >= 26 And y <= 38 Then
                        c = _RGB32(205, 170, 60)
                    Else
                        c = _RGB32(95 + n * 12, 105 + n * 12, 125 + n * 12)
                    End If
                Case TEX_BARREL ' barrel sprite, alpha 0 = transparent
                    If x >= 14 And x <= 49 And y >= 6 Then
                        d = Abs(x - 31.5) / 18
                        If (y Mod 18) < 3 Then
                            c = _RGB32(70 * (1 - d * .5), 70 * (1 - d * .5), 75 * (1 - d * .5))
                        Else
                            c = _RGB32((140 + n * 20) * (1 - d * .6), (85 + n * 10) * (1 - d * .6), 40 * (1 - d * .6))
                        End If
                    Else
                        c = 0
                    End If
                Case TEX_LAMP ' lamp post sprite
                    dx = x - 31.5: dy = y - 12
                    If dx * dx + dy * dy <= 81 Then
                        d = Sqr(dx * dx + dy * dy) / 9
                        c = _RGB32(255, 240 - d * 60, 150 - d * 100)
                    ElseIf x >= 30 And x <= 33 And y > 20 Then
                        c = _RGB32(50, 50, 55)
                    ElseIf x >= 24 And x <= 39 And y >= 60 Then
                        c = _RGB32(40, 40, 45)
                    Else
                        c = 0
                    End If
                Case Else
                    GenTexture% = 0
                    Exit Function
            End Select
            tex(y * 64 + x) = c
        Next x
    Next y
End Function

Sub MovePlayer (ddx As Single, ddy As Single)
    Const R = .22
    Dim nx As Single, ny As Single
    nx = px + ddx
    If Solid(nx + Sgn(ddx) * R, py - R) = 0 And Solid(nx + Sgn(ddx) * R, py + R) = 0 Then px = nx
    ny = py + ddy
    If Solid(px - R, ny + Sgn(ddy) * R) = 0 And Solid(px + R, ny + Sgn(ddy) * R) = 0 Then py = ny
End Sub

Function Solid% (wx As Single, wy As Single)
    Dim cx As Long, cy As Long
    cx = Int(wx): cy = Int(wy)
    If cx < 0 Or cy < 0 Or cx >= MAP_W Or cy >= MAP_H Then
        Solid% = -1
    ElseIf walls(cy * MAP_W + cx) <> 0 Then
        Solid% = -1
    Else
        Solid% = 0
    End If
End Function

Sub DrawMinimap
    Const CS = 6
    Dim ox As Long, oy As Long, tx As Long, ty As Long, i As Long
    Dim c As _Unsigned Long
    ox = SCR_W - MAP_W * CS - 12: oy = 12
    Line (ox - 2, oy - 2)-(ox + MAP_W * CS + 1, oy + MAP_H * CS + 1), _RGBA32(0, 0, 0, 160), BF
    For ty = 0 To MAP_H - 1
        For tx = 0 To MAP_W - 1
            Select Case walls(ty * MAP_W + tx)
                Case 0: c = 0
                Case 1: c = _RGB32(150, 55, 40)
                Case 2: c = _RGB32(120, 120, 125)
                Case 3: c = _RGB32(130, 85, 40)
                Case 4: c = _RGB32(150, 155, 165)
                Case TEX_DOOR, TEX_DOOR_MOVE: c = _RGB32(230, 160, 40)
                Case Else: c = _RGB32(40, 200, 110)
            End Select
            If c Then Line (ox + tx * CS, oy + ty * CS)-Step(CS - 1, CS - 1), c, BF
        Next tx
    Next ty
    ' open doors as a dim outline
    For i = 0 To nDoor - 1
        If walls(doorCell(i)) = 0 Then
            tx = doorCell(i) Mod MAP_W: ty = doorCell(i) \ MAP_W
            Line (ox + tx * CS, oy + ty * CS)-Step(CS - 1, CS - 1), _RGB32(120, 85, 25), B
        End If
    Next i
    For i = 0 To nSpr - 1
        PSet (ox + sprData(i * 4) * CS, oy + sprData(i * 4 + 1) * CS), _RGB32(255, 220, 90)
    Next i
    Circle (ox + px * CS, oy + py * CS), 2, _RGB32(255, 255, 255)
    Line (ox + px * CS, oy + py * CS)-(ox + (px + Cos(ang) * 1.5) * CS, oy + (py + Sin(ang) * 1.5) * CS), _RGB32(255, 255, 255)
End Sub

' ---------------- doors ----------------

Sub AddDoor (cell As Long)
    If nDoor >= MAX_DOOR Then Exit Sub
    doorCell(nDoor) = cell
    doorAmt(nDoor) = 0: doorDir(nDoor) = 0: doorWait(nDoor) = 0
    nDoor = nDoor + 1
End Sub

Function FindDoor% (cell As Long)
    Dim d As Long
    FindDoor% = -1
    For d = 0 To nDoor - 1
        If doorCell(d) = cell Then FindDoor% = d: Exit Function
    Next d
End Function

' E / Space: act on the first door within reach straight ahead
Sub UseDoor
    Dim reach As Single, cx As Long, cy As Long, d As Long
    reach = .5
    Do While reach <= 1.5
        cx = Int(px + Cos(ang) * reach): cy = Int(py + Sin(ang) * reach)
        If cx >= 0 And cy >= 0 And cx < MAP_W And cy < MAP_H Then
            d = FindDoor(cy * MAP_W + cx)
            If d >= 0 Then
                ToggleDoor d
                Exit Sub
            End If
            If walls(cy * MAP_W + cx) <> 0 Then Exit Sub ' a plain wall is in the way
        End If
        reach = reach + .25
    Loop
End Sub

Sub ToggleDoor (d As Long)
    If doorDir(d) = 0 And doorAmt(d) = 0 Then
        ' closed: start opening (only one door slides at a time)
        If movingDoor = -1 Then
            movingDoor = d: doorDir(d) = 1
            SetDoorCell d, TEX_DOOR_MOVE
            SetMoveTex 0
        End If
    ElseIf doorDir(d) = -1 Then
        doorDir(d) = 1 ' closing: reverse it
    ElseIf doorDir(d) = 0 Then
        doorWait(d) = 0 ' open: close it now (UpdateDoors checks the doorway is clear)
    End If
End Sub

Sub UpdateDoors (ddt As Single)
    Dim d As Long
    For d = 0 To nDoor - 1
        Select Case doorDir(d)
            Case 1
                doorAmt(d) = doorAmt(d) + DOOR_SPEED * ddt
                If doorAmt(d) >= 1 Then
                    doorAmt(d) = 1: doorDir(d) = 0: doorWait(d) = DOOR_HOLD
                    SetDoorCell d, 0
                    movingDoor = -1
                Else
                    SetMoveTex doorAmt(d)
                End If
            Case -1
                doorAmt(d) = doorAmt(d) - DOOR_SPEED * ddt
                If doorAmt(d) <= 0 Then
                    doorAmt(d) = 0: doorDir(d) = 0
                    SetDoorCell d, TEX_DOOR
                    movingDoor = -1
                Else
                    SetMoveTex doorAmt(d)
                End If
            Case Else
                If doorAmt(d) >= 1 Then
                    doorWait(d) = doorWait(d) - ddt
                    If doorWait(d) <= 0 Then
                        If PlayerInCell(doorCell(d)) Or movingDoor <> -1 Then
                            doorWait(d) = .5 ' blocked or busy: try again shortly
                        Else
                            movingDoor = d: doorDir(d) = -1
                            SetDoorCell d, TEX_DOOR_MOVE
                            SetMoveTex 1
                        End If
                    End If
                End If
        End Select
    Next d
End Sub

' keep the collision map and the GPU map in step
Sub SetDoorCell (d As Long, wallId As Long)
    Dim cell As Long
    cell = doorCell(d)
    walls(cell) = wallId
    rv_set_cell cell Mod MAP_W, cell \ MAP_W, wallId
End Sub

' redraw texture 9: the panel slid sideways by amt (0 shut .. 1 gone)
Sub SetMoveTex (amt As Single)
    Dim x As Long, y As Long, slideX As Long, sx As Long
    slideX = Int(amt * 64)
    For y = 0 To 63
        For x = 0 To 63
            sx = x + slideX
            If sx < 64 Then
                moveTex(y * 64 + x) = doorTex(y * 64 + sx)
            Else
                moveTex(y * 64 + x) = DOOR_GAP
            End If
        Next x
    Next y
    rv_set_texture TEX_DOOR_MOVE, _Offset(moveTex(0))
End Sub

' true if the player's body overlaps the given cell
Function PlayerInCell% (cell As Long)
    Const PR = .25
    Dim cx As Long, cy As Long
    cx = cell Mod MAP_W: cy = cell \ MAP_W
    PlayerInCell% = 0
    If px + PR > cx And px - PR < cx + 1 And py + PR > cy And py - PR < cy + 1 Then PlayerInCell% = -1
End Function

' running averages of the per-frame timings; first sample after a reset seeds them
Sub SmoothStats (hMs As Single)
    If avReady = 0 Then
        avHost = hMs: avShader = shaderMs: avCopy = copyMs
        avWait = waitMs: avCpu = cpuMs
        shHost = avHost: shShader = avShader: shCopy = avCopy
        shWait = avWait: shCpu = avCpu: shFps = 0
        avReady = -1
    Else
        avHost = avHost + (hMs - avHost) * SMOOTH_K
        avShader = avShader + (shaderMs - avShader) * SMOOTH_K
        avCopy = avCopy + (copyMs - avCopy) * SMOOTH_K
        avWait = avWait + (waitMs - avWait) * SMOOTH_K
        avCpu = avCpu + (cpuMs - avCpu) * SMOOTH_K
    End If
End Sub

Sub DrawHud (dname$, devCount As Long)
    Line (8, 8)-(520, 162), _RGBA32(0, 0, 0, 150), BF
    Color _RGB32(120, 200, 255)
    _PrintString (16, 14), "RayVK  -  Vulkan compute ray caster"
    Color _RGB32(230, 230, 230)
    _PrintString (16, 34), "GPU   : " + Left$(dname$, 48)
    _PrintString (16, 52), "FPS   : " + FixN$(shFps, 1, 6) + "   (" + _Trim$(Str$(SCR_W)) + "x" + _Trim$(Str$(SCR_H)) + ")"
    _PrintString (16, 70), "Frame : " + FixN$(shHost, 2, 6) + " ms = shader " + FixN$(shShader, 2, 5) + " + copy " + FixN$(shCopy, 2, 5)
    _PrintString (16, 88), "Wait  : " + FixN$(shWait, 2, 6) + " ms (incl. GPU)  memcpy " + FixN$(shCpu, 2, 5) + " ms"
    _PrintString (16, 106), "Readback: " + modeName$
    If rebarMB >= 1024 Then
        _PrintString (16, 124), "ReBAR : ON  (" + _Trim$(Str$(rebarMB)) + " MB CPU-visible VRAM)"
    Else
        _PrintString (16, 124), "ReBAR : off (" + _Trim$(Str$(rebarMB)) + " MB CPU-visible VRAM)"
    End If
    Color _RGB32(160, 160, 160)
    If devCount > 1 Then
        _PrintString (16, 142), "Tab next GPU (" + _Trim$(Str$(rv_current_device + 1)) + "/" + _Trim$(Str$(devCount)) + ")  E door  R readback  F fog  M map  H hud"
    Else
        _PrintString (16, 142), "E door   R readback   F fog   M map   H hud   Esc quit"
    End If
End Sub

Function DevNameOf$ (idx As Long)
    Dim b$
    b$ = Space$(128)
    rv_device_name idx, b$, 128
    DevNameOf$ = _Trim$(b$)
End Function

Sub ShowErr
    Dim e$
    e$ = Space$(300)
    rv_last_error e$, 300
    Print "Vulkan error: "; _Trim$(e$)
End Sub

Sub UpdateModeInfo
    Dim b$
    b$ = Space$(80)
    rv_mode_name b$, 80
    modeName$ = _Trim$(b$)
    rebarMB = rv_rebar_mb
End Sub

' fixed decimals, right-aligned in a field of wid characters (e.g. FixN$(3.5, 2, 6) = "  3.50")
Function FixN$ (v As Single, dec As Long, wid As Long)
    Dim sc As Long, iv As Long, s$, vv As Single
    vv = v
    If vv < 0 Then vv = 0
    sc = 10 ^ dec
    iv = Int(vv * sc + .5)
    s$ = _Trim$(Str$(iv \ sc))
    If dec > 0 Then s$ = s$ + "." + Right$(String$(dec, "0") + _Trim$(Str$(iv Mod sc)), dec)
    If Len(s$) < wid Then s$ = Space$(wid - Len(s$)) + s$
    FixN$ = s$
End Function

