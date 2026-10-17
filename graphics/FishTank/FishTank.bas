' FishTank.bas  -  a GPU aquarium for QB64-PE 4.5.0 (Linux)
'
' QB64 runs the fish: wandering, schooling space, chasing food, fleeing taps.
' libfishtank.so (fishtank.cu) shades every pixel straight into the screen.
'
' Controls:
'   Left click   drop food at that spot on the surface
'   Right click  tap the glass (fish nearby scatter)
'   Space        drop food somewhere random
'   + / -        add / remove a fish
'   B            bubblers on/off
'   F            fullscreen on/off
'   H            hide/show the info panel
'   Esc          quit

Option _Explicit
_Title "FishTank"

Const SW = 1280
Const SH = 720
Const MAXFISH = 40
Const MAXBUB = 300
Const MAXFOOD = 100

' One fish. rot is the screen tilt passed to the GPU, zt the depth it drifts toward,
' sx/sy the spot it is fleeing from while fright > 0.
Type FishT
    x As Single
    y As Single
    vx As Single
    vy As Single
    face As Single
    rot As Single
    size As Single
    hue As Single
    phase As Single
    z As Single
    zt As Single
    tx As Single
    ty As Single
    spd As Single
    hunger As Single
    fright As Single
    sx As Single
    sy As Single
End Type

Type BubT
    x As Single
    y As Single
    r As Single
    wob As Single
    alive As Integer
End Type

Type FoodT
    x As Single
    y As Single
    age As Single
    alive As Integer
End Type

Declare Dynamic Library "./fishtank"
    Function ft_init& (ByVal w As Long, ByVal h As Long)
    Function ft_render& (ByVal tt As Single, ByVal fishPtr As _Offset, ByVal nf As Long, ByVal bubPtr As _Offset, ByVal nb As Long, ByVal foodPtr As _Offset, ByVal nfd As Long, ByVal outPtr As _Offset)
    Sub ft_shutdown
    Sub ft_last_error (ByVal buf As _Offset, ByVal n As Long)
    Sub ft_device_name (ByVal buf As _Offset, ByVal n As Long)
    Function ft_sand_top! (ByVal x As Single, ByVal h As Long)
End Declare

Dim Shared fish(1 To MAXFISH) As FishT
Dim Shared bub(1 To MAXBUB) As BubT
Dim Shared food(1 To MAXFOOD) As FoodT
Dim Shared nFish As Long
Dim Shared fishBuf(0 To MAXFISH * 8 - 1) As Single
Dim Shared bubBuf(0 To MAXBUB * 3 - 1) As Single
Dim Shared foodBuf(0 To MAXFOOD * 2 - 1) As Single
Dim Shared order(1 To MAXFISH) As Long
Dim Shared tankTime As Single
Dim Shared bubblersOn As Integer

Dim scr As Long
scr = _NewImage(SW, SH, 32)
Screen scr
_ScreenMove _Middle

Dim errBuf As String * 256
Dim devBuf As String * 128
Dim tmp As String
Dim devName As String

If ft_init(SW, SH) = 0 Then
    ft_last_error _Offset(errBuf), 256
    tmp = errBuf
    Print "Could not start the GPU renderer:"
    Print ZStr$(tmp)
    Print
    Print "Press any key."
    Sleep
    System
End If
ft_device_name _Offset(devBuf), 128
tmp = devBuf
devName = ZStr$(tmp)

Dim scrMem As _MEM, fishMem As _MEM, bubMem As _MEM, foodMem As _MEM
scrMem = _MemImage(scr)
fishMem = _Mem(fishBuf())
bubMem = _Mem(bubBuf())
foodMem = _Mem(foodBuf())

Randomize Timer
Dim i As Long
For i = 1 To 14
    AddFish
Next i
bubblersOn = -1

Dim lastT As Double, nowT As Double, fpsT As Double
Dim dt As Single
Dim kk As String
Dim showHelp As Integer, fsOn As Integer
Dim fpsCount As Long, fps As Long
Dim mb1 As Integer, mb2 As Integer, oldMb1 As Integer, oldMb2 As Integer
Dim mx As Single, my As Single
Dim nf As Long, nb As Long, nfd As Long

showHelp = -1
lastT = Timer(0.001)
fpsT = lastT

Do
    nowT = Timer(0.001)
    dt = nowT - lastT
    If dt <= 0 Then dt = 1 / 60
    If dt > 0.1 Then dt = 0.1
    lastT = nowT
    tankTime = tankTime + dt

    Do While _MouseInput
    Loop
    mx = _MouseX
    my = _MouseY
    mb1 = _MouseButton(1)
    mb2 = _MouseButton(2)
    If mb1 And Not oldMb1 Then DropFood mx
    If mb2 And Not oldMb2 Then TapGlass mx, my
    oldMb1 = mb1
    oldMb2 = mb2

    kk = UCase$(InKey$)
    Select Case kk
        Case Chr$(27)
            Exit Do
        Case "H"
            showHelp = Not showHelp
        Case "F"
            fsOn = Not fsOn
            If fsOn Then
                _FullScreen _SquarePixels , _Smooth
            Else
                _FullScreen _Off
            End If
        Case "+", "="
            AddFish
        Case "-", "_"
            RemoveFish
        Case " "
            DropFood SW * (0.15 + Rnd * 0.7)
        Case "B"
            bubblersOn = Not bubblersOn
    End Select

    UpdateFood dt
    UpdateFish dt
    UpdateBubbles dt

    PackScene nf, nb, nfd
    If ft_render(tankTime, fishMem.OFFSET, nf, bubMem.OFFSET, nb, foodMem.OFFSET, nfd, scrMem.OFFSET) = 0 Then
        ft_last_error _Offset(errBuf), 256
        tmp = errBuf
        _AutoDisplay
        Cls
        Print "Render failed: "; ZStr$(tmp)
        Print "Press any key."
        Sleep
        Exit Do
    End If

    fpsCount = fpsCount + 1
    If nowT - fpsT >= 1 Or nowT < fpsT Then
        fps = fpsCount
        fpsCount = 0
        fpsT = nowT
    End If
    If showHelp Then DrawHelp devName, fps

    _Display
    _Limit 60
Loop

_MemFree fishMem
_MemFree bubMem
_MemFree foodMem
_MemFree scrMem
ft_shutdown
System

' ------------------------------------------------------------------ helpers

Function ZStr$ (s As String)
    Dim p As Long
    p = InStr(s, Chr$(0))
    If p > 0 Then ZStr$ = Left$(s, p - 1) Else ZStr$ = _Trim$(s)
End Function

Function SwimFloor! (x As Single, sz As Single)
    SwimFloor! = ft_sand_top(x, SH) - sz * 0.3 - 12
End Function

Sub PickTarget (i As Long)
    fish(i).tx = SW * (0.06 + Rnd * 0.88)
    fish(i).ty = SH * 0.1 + Rnd * (SwimFloor(fish(i).tx, fish(i).size) - SH * 0.1)
    If Rnd < 0.3 Then fish(i).zt = Rnd * 0.9
End Sub

Sub AddFish
    If nFish >= MAXFISH Then Exit Sub
    nFish = nFish + 1
    fish(nFish).size = 55 + Rnd * 60
    fish(nFish).x = SW * (0.1 + Rnd * 0.8)
    fish(nFish).y = SH * (0.15 + Rnd * 0.45)
    fish(nFish).spd = 45 + Rnd * 55
    fish(nFish).vx = (Rnd - 0.5) * 2 * fish(nFish).spd
    fish(nFish).vy = 0
    If fish(nFish).vx < 0 Then fish(nFish).face = -1 Else fish(nFish).face = 1
    fish(nFish).rot = 0
    fish(nFish).hue = Rnd
    fish(nFish).phase = Rnd * 6.2832
    fish(nFish).z = Rnd * 0.9
    fish(nFish).zt = fish(nFish).z
    fish(nFish).hunger = Rnd * 0.5
    fish(nFish).fright = 0
    PickTarget nFish
End Sub

Sub RemoveFish
    If nFish > 1 Then nFish = nFish - 1
End Sub

Sub AddBubble (x As Single, y As Single, r As Single)
    Dim k As Long
    For k = 1 To MAXBUB
        If bub(k).alive = 0 Then
            bub(k).x = x
            bub(k).y = y
            bub(k).r = r
            bub(k).wob = Rnd * 6.2832
            bub(k).alive = -1
            Exit Sub
        End If
    Next k
End Sub

Sub DropFood (x As Single)
    Dim k As Long, n As Long
    For k = 1 To MAXFOOD
        If food(k).alive = 0 Then
            food(k).x = _Clamp(x + (Rnd - 0.5) * 60, 20, SW - 20)
            food(k).y = SH * 0.03 + Rnd * 12
            food(k).age = 0
            food(k).alive = -1
            n = n + 1
            If n >= 7 Then Exit Sub
        End If
    Next k
End Sub

Sub TapGlass (x As Single, y As Single)
    Dim i As Long, dx As Single, dy As Single
    For i = 1 To nFish
        dx = fish(i).x - x
        dy = fish(i).y - y
        If dx * dx + dy * dy < 380 * 380 Then
            fish(i).fright = 1
            fish(i).sx = x
            fish(i).sy = y
        End If
    Next i
End Sub

Function NearestFood& (x As Single, y As Single)
    Dim k As Long, best As Long, d2 As Single, bestD As Single
    bestD = 1E+20
    For k = 1 To MAXFOOD
        If food(k).alive Then
            d2 = (food(k).x - x) ^ 2 + (food(k).y - y) ^ 2
            If d2 < bestD Then
                bestD = d2
                best = k
            End If
        End If
    Next k
    NearestFood& = best
End Function

' ------------------------------------------------------------------ simulation

Sub UpdateFood (dt As Single)
    Dim k As Long, floorY As Single
    For k = 1 To MAXFOOD
        If food(k).alive Then
            floorY = ft_sand_top(food(k).x, SH) - 3
            If food(k).y < floorY Then
                food(k).y = food(k).y + dt * 24
                food(k).x = food(k).x + Sin(tankTime * 2 + k) * dt * 10
            Else
                food(k).y = floorY
            End If
            food(k).age = food(k).age + dt
            If food(k).age > 45 Then food(k).alive = 0
        End If
    Next k
End Sub

Sub UpdateFish (dt As Single)
    Dim i As Long, j As Long, fi As Long
    Dim gx As Single, gy As Single, dx As Single, dy As Single, d As Single
    Dim sp As Single, boost As Single, desx As Single, desy As Single
    Dim ox As Single, oy As Single, od2 As Single, od As Single, rr As Single
    Dim k As Single, ftarget As Single, pitch As Single, margin As Single
    Dim mouthX As Single, sc As Single, floorY As Single

    For i = 1 To nFish
        ' --- where do I want to go?
        gx = fish(i).tx
        gy = fish(i).ty
        boost = 1
        fi = 0
        If fish(i).hunger > 0.25 Then fi = NearestFood(fish(i).x, fish(i).y)
        If fi > 0 Then
            gx = food(fi).x
            gy = food(fi).y
            boost = 1.8
        End If
        dx = gx - fish(i).x
        dy = gy - fish(i).y
        d = Sqr(dx * dx + dy * dy)
        If fi = 0 Then
            If d < 30 Or Rnd < dt * 0.08 Then PickTarget i
        End If

        sp = fish(i).spd * boost
        If fi = 0 And d < 120 Then sp = sp * (0.25 + d / 160)
        If d > 1 Then
            desx = dx / d * sp
            desy = dy / d * sp * 0.6
        Else
            desx = 0
            desy = 0
        End If

        ' --- startled: bolt away from the tap
        If fish(i).fright > 0.05 Then
            dx = fish(i).x - fish(i).sx
            dy = fish(i).y - fish(i).sy
            d = Sqr(dx * dx + dy * dy) + 0.01
            sp = fish(i).spd * (1.5 + fish(i).fright * 2.5)
            desx = dx / d * sp
            desy = dy / d * sp * 0.7
        End If

        ' --- personal space with fish at a similar depth
        For j = 1 To nFish
            If j <> i Then
                If Abs(fish(j).z - fish(i).z) < 0.25 Then
                    ox = fish(i).x - fish(j).x
                    oy = fish(i).y - fish(j).y
                    od2 = ox * ox + oy * oy
                    rr = (fish(i).size + fish(j).size) * 0.45
                    If od2 < rr * rr And od2 > 0.01 Then
                        od = Sqr(od2)
                        desx = desx + ox / od * (rr - od) * 3
                        desy = desy + oy / od * (rr - od) * 3
                    End If
                End If
            End If
        Next j

        ' --- steer and move
        k = dt * 1.6
        If fish(i).fright > 0.05 Then k = dt * 5
        If k > 1 Then k = 1
        fish(i).vx = fish(i).vx + (desx - fish(i).vx) * k
        fish(i).vy = fish(i).vy + (desy - fish(i).vy) * k
        fish(i).x = fish(i).x + fish(i).vx * dt
        fish(i).y = fish(i).y + fish(i).vy * dt

        margin = fish(i).size * 0.45
        If fish(i).x < margin Then
            fish(i).x = margin
            fish(i).vx = Abs(fish(i).vx) * 0.5
        ElseIf fish(i).x > SW - margin Then
            fish(i).x = SW - margin
            fish(i).vx = -Abs(fish(i).vx) * 0.5
        End If
        floorY = SwimFloor(fish(i).x, fish(i).size)
        If fish(i).y < SH * 0.08 Then
            fish(i).y = SH * 0.08
            fish(i).vy = Abs(fish(i).vy) * 0.3
        ElseIf fish(i).y > floorY Then
            fish(i).y = floorY
            fish(i).vy = -Abs(fish(i).vy) * 0.3
        End If

        ' --- eat
        If fi > 0 Then
            sc = 1 - 0.35 * fish(i).z
            mouthX = fish(i).x + Sgn(fish(i).face) * fish(i).size * 0.3 * sc
            dx = food(fi).x - mouthX
            dy = food(fi).y - fish(i).y
            If dx * dx + dy * dy < (fish(i).size * 0.15 * sc + 8) ^ 2 Then
                food(fi).alive = 0
                fish(i).hunger = _Clamp(fish(i).hunger - 0.35, 0, 1)
                If fish(i).size < 135 Then fish(i).size = fish(i).size + 0.8
                If Rnd < 0.5 Then AddBubble mouthX, fish(i).y - 4, 2 + Rnd * 2
            End If
        End If

        ' --- turn around smoothly (face sweeps through 0 = edge-on)
        If Abs(fish(i).vx) > 8 Then
            ftarget = Sgn(fish(i).vx)
        ElseIf fish(i).face < 0 Then
            ftarget = -1
        Else
            ftarget = 1
        End If
        fish(i).face = fish(i).face + (ftarget - fish(i).face) * _Clamp(dt * 3.5, 0, 1)

        pitch = _Clamp(_Atan2(fish(i).vy, Abs(fish(i).vx) + 20), -0.55, 0.55)
        If fish(i).face < 0 Then fish(i).rot = -pitch Else fish(i).rot = pitch

        fish(i).phase = fish(i).phase + dt * (5 + Sqr(fish(i).vx ^ 2 + fish(i).vy ^ 2) * 0.06)
        fish(i).hunger = _Clamp(fish(i).hunger + dt * 0.015, 0, 1)
        fish(i).fright = _Clamp(fish(i).fright - dt * 0.6, 0, 1)
        fish(i).z = fish(i).z + (fish(i).zt - fish(i).z) * _Clamp(dt * 0.15, 0, 1)

        ' the occasional idle burp
        If Rnd < dt * 0.03 Then
            AddBubble fish(i).x + Sgn(fish(i).face) * fish(i).size * 0.3, fish(i).y - 4, 1.5 + Rnd * 2
        End If
    Next i
End Sub

Sub UpdateBubbles (dt As Single)
    Static acc As Single
    Dim k As Long, bx As Single

    If bubblersOn Then
        acc = acc + dt
        Do While acc > 0.09
            acc = acc - 0.09
            If Rnd < 0.5 Then bx = SW * 0.2 Else bx = SW * 0.83
            AddBubble bx + (Rnd - 0.5) * 6, ft_sand_top(bx, SH) - 2, 2.5 + Rnd * 5
        Loop
    End If

    For k = 1 To MAXBUB
        If bub(k).alive Then
            bub(k).y = bub(k).y - dt * (35 + bub(k).r * 9)
            bub(k).x = bub(k).x + Sin(tankTime * 3 + bub(k).wob) * dt * 18
            If bub(k).y < SH * 0.035 Then bub(k).alive = 0
        End If
    Next k
End Sub

' ------------------------------------------------------------------ GPU hand-off

Sub PackScene (nf As Long, nb As Long, nfd As Long)
    Dim i As Long, j As Long, k As Long, tmpI As Long, b As Long

    ' painter's order: far (big z) first
    For i = 1 To nFish
        order(i) = i
    Next i
    For i = 2 To nFish
        tmpI = order(i)
        j = i - 1
        Do While j >= 1
            If fish(order(j)).z >= fish(tmpI).z Then Exit Do
            order(j + 1) = order(j)
            j = j - 1
        Loop
        order(j + 1) = tmpI
    Next i

    nf = nFish
    For k = 1 To nFish
        i = order(k)
        b = (k - 1) * 8
        fishBuf(b) = fish(i).x
        fishBuf(b + 1) = fish(i).y
        fishBuf(b + 2) = fish(i).face
        fishBuf(b + 3) = fish(i).rot
        fishBuf(b + 4) = fish(i).size
        fishBuf(b + 5) = fish(i).hue
        fishBuf(b + 6) = fish(i).phase
        fishBuf(b + 7) = fish(i).z
    Next k

    nb = 0
    For k = 1 To MAXBUB
        If bub(k).alive Then
            b = nb * 3
            bubBuf(b) = bub(k).x
            bubBuf(b + 1) = bub(k).y
            bubBuf(b + 2) = bub(k).r
            nb = nb + 1
        End If
    Next k

    nfd = 0
    For k = 1 To MAXFOOD
        If food(k).alive Then
            b = nfd * 2
            foodBuf(b) = food(k).x
            foodBuf(b + 1) = food(k).y
            nfd = nfd + 1
        End If
    Next k
End Sub

Sub ShadowText (x As Long, y As Long, s As String, c As _Unsigned Long)
    Color _RGB32(0, 0, 0)
    _PrintString (x + 1, y + 1), s
    Color c
    _PrintString (x, y), s
End Sub

Sub DrawHelp (devName As String, fps As Long)
    Dim c As _Unsigned Long
    c = _RGB32(220, 240, 255)
    _PrintMode _KeepBackground
    ShadowText 12, 22, "FishTank  |  " + devName + "  |  " + _Trim$(Str$(fps)) + " fps  |  fish: " + _Trim$(Str$(nFish)), c
    ShadowText 12, 40, "Left click: feed   Right click: tap glass   Space: feed", c
    ShadowText 12, 58, "+/- fish   B bubblers   F fullscreen   H hide   Esc quit", c
End Sub
