'==============================================================
' OBJ3Demo.bas -- ButtonUI edition (QB64-PE 4.5.0)
'
' Wavefront .obj viewer built on the OBJ3 helper plus the
' ButtonUI immediate-mode button helper and the OptButton toggle.
'
' Put OBJ3.bi / OBJ3.bm, ButtonUI.bi / ButtonUI.bm and
' OptButton.bi / OptButton.bm in the same folder as this .bas.
'
' Mouse:  drag in the viewport to rotate, wheel to zoom, buttons
'         along the bottom for everything else.
' Keys:   1/2/3 mode   arrows rotate   A/Z zoom   C flip winding
'         SPACE spin   O open   R reset view   ESC quit
'==============================================================

'$Include:'ButtonUI.bi'
'$Include:'OptButton.bi'
'$Include:'OBJ3.bi'

Const SCR_W = 1024
Const SCR_H = 768

' bottom button strip
Const BAR_H = 44
Const BTN_Y = 726
Const BTN_H = 32
Const VIEW_H = 716 ' viewport ends where the bar begins

' QB64-PE needs this to parse the call below as a function rather
' than an array reference, since it is defined further down
Declare Function SpinName$ (sp As Integer)

Dim Shared scr As Long
scr = _NewImage(SCR_W, SCR_H, 32)
Screen scr
' fullscreen only takes reliably once the graphics screen is the
' active surface; asking for it against the startup text screen can
' enlarge the desktop before the window exists.  If the mode is
' refused, fall back to a window so we never strand the program on a
' black desktop.
_FullScreen _SquarePixels , _Smooth
If _FullScreen = 0 Then _FullScreen _Off
_Title "OBJ3 viewer"

MouseInit
' a slightly cooler face to sit against the dark viewport
uiFace = _RGB32(58, 68, 88)
uiFaceHover = _RGB32(80, 94, 120)
uiFaceDown = _RGB32(42, 50, 66)

OBJ3Init
OBJ3SetView 60, SCR_W / 2, VIEW_H / 2
OBJ3SetCamera 0, 0, 0
OBJ3SetLight -0.4, 0.7, -0.6, 0.25
OBJ3SetCull OBJ3_CULLBACK

Dim Shared modelPath As String
Dim Shared mdl As Long
Dim Shared statusMsg As String

modelPath = "ball.obj"
If Len(Command$(1)) > 0 Then modelPath = Command$(1)

mdl = OBJ3Load&(modelPath)
If mdl = 0 Then
    statusMsg = "Load failed: " + OBJ3Error$
Else
    statusMsg = "Loaded " + modelPath
End If

Dim dmode As Integer, spinOn As Integer, dist As Single
Dim ry As Single, rx As Single, kk As Long, flipWind As Integer
Dim dragging As Integer, lastMX As Integer, lastMY As Integer
Dim pick As String, newMdl As Long
Dim enWire As Integer, enFlat As Integer, enTex As Integer
Dim bg As _Unsigned Long

dmode = OBJ3_FLAT
spinOn = -1
dist = 3
flipWind = 0 ' 0 = normal (Cull: back), -1 = flipped (Cull: front)
dragging = 0
bg = _RGB32(16, 18, 24)

Do
    PollMouse

    '---------------- keyboard ----------------
    kk = _KeyHit
    If kk = 27 Then Exit Do
    If kk = Asc("1") Then dmode = OBJ3_WIRE
    If kk = Asc("2") Then dmode = OBJ3_FLAT
    If kk = Asc("3") Then dmode = OBJ3_TEX
    If kk = 32 Then spinOn = Not spinOn
    If kk = Asc("c") Or kk = Asc("C") Then flipWind = Not flipWind
    If kk = Asc("o") Or kk = Asc("O") Then GoSub OpenModel
    If kk = Asc("r") Or kk = Asc("R") Then rx = 0: ry = 0: dist = 3

    If _KeyDown(19200) Then ry = ry - 0.04
    If _KeyDown(19712) Then ry = ry + 0.04
    If _KeyDown(18432) Then rx = rx - 0.04
    If _KeyDown(20480) Then rx = rx + 0.04
    If _KeyDown(Asc("a")) Or _KeyDown(Asc("A")) Then dist = dist - 0.05
    If _KeyDown(Asc("z")) Or _KeyDown(Asc("Z")) Then dist = dist + 0.05

    '---------------- drag to rotate ----------------
    ' a drag only starts on a fresh press inside the viewport, so
    ' dragging off a button does not grab the model
    If gMouse.held = 0 Then
        dragging = 0
    ElseIf dragging = 0 And gMouse.prevHeld = 0 And gMouse.my < VIEW_H Then
        dragging = -1
        lastMX = gMouse.mx
        lastMY = gMouse.my
    End If
    If dragging Then
        ry = ry + (gMouse.mx - lastMX) * 0.01
        rx = rx + (gMouse.my - lastMY) * 0.01
        lastMX = gMouse.mx
        lastMY = gMouse.my
        spinOn = 0
    End If

    '---------------- wheel to zoom ----------------
    ' scroll zooms only over the viewport, so a scroll aimed at the
    ' button bar does not fight the pointer.  wheel is +1 per notch
    ' toward the user, which we treat as pulling the model closer.
    If gMouse.wheel <> 0 And gMouse.my < VIEW_H Then dist = dist + gMouse.wheel * 0.25

    If dist < 1.5 Then dist = 1.5
    If dist > 40 Then dist = 40
    If spinOn Then ry = ry + 0.01

    '---------------- render ----------------
    Cls , bg

    If mdl > 0 Then
        OBJ3SetRot mdl, rx, ry, 0
        OBJ3SetPos mdl, 0, 0, dist
        OBJ3Draw mdl, dmode
    End If

    '---------------- HUD ----------------
    Color _RGB32(190, 190, 200), bg
    If mdl > 0 Then
        _PrintString (8, 8), "verts:" + Str$(OBJ3VertCount&(mdl)) + "   tris:" + Str$(OBJ3TriCount&(mdl))
        _PrintString (8, 26), "dist:" + Str$(CInt(dist * 10) / 10)
    Else
        _PrintString (8, 8), "no model loaded -- press Open"
    End If
    Color _RGB32(150, 155, 170), bg
    _PrintString (8, VIEW_H - 20), statusMsg

    '---------------- button bar ----------------
    Line (0, VIEW_H)-(SCR_W, SCR_H), _RGB32(28, 32, 42), BF
    Line (0, VIEW_H)-(SCR_W, VIEW_H), _RGB32(60, 68, 86)

    ' the active mode button is drawn disabled, which reads as "you
    ' are already here" without needing a second widget style
    ' ButtonEx% tests the flag with Not, which is bitwise -- so the
    ' enable flag must be -1 or 0.  A comparison yields exactly that,
    ' but hand it over in a variable rather than as an expression.
    enWire = (dmode <> OBJ3_WIRE)
    enFlat = (dmode <> OBJ3_FLAT)
    enTex = (dmode <> OBJ3_TEX)
    If ButtonEx%(12, BTN_Y, 92, BTN_H, "Wire", enWire) Then dmode = OBJ3_WIRE
    If ButtonEx%(112, BTN_Y, 92, BTN_H, "Flat", enFlat) Then dmode = OBJ3_FLAT
    If ButtonEx%(212, BTN_Y, 104, BTN_H, "Textured", enTex) Then dmode = OBJ3_TEX

    ' Flip wind is a live toggle: it owns the cull setting, switching
    ' front/back so an inside-out model can be corrected per file.
    ' It replaces the old cull-cycle button -- only one thing should
    ' call OBJ3SetCull each frame or they fight.
    flipWind = OptionButton%(324, BTN_Y, 92, BTN_H, "Flip wind", flipWind)
    If flipWind Then OBJ3SetCull OBJ3_CULLFRONT Else OBJ3SetCull OBJ3_CULLBACK

    If Button%(424, BTN_Y, 92, BTN_H, SpinName$(spinOn)) Then spinOn = Not spinOn

    If Button%(524, BTN_Y, 64, BTN_H, "Zoom+") Then dist = dist - 0.35
    If Button%(596, BTN_Y, 64, BTN_H, "Zoom-") Then dist = dist + 0.35

    If Button%(668, BTN_Y, 92, BTN_H, "Recenter") Then rx = 0: ry = 0: dist = 3
    If Button%(768, BTN_Y, 110, BTN_H, "Open...") Then GoSub OpenModel
    If Button%(886, BTN_Y, 92, BTN_H, "Quit") Then Exit Do

    _Display
    _Limit 60
Loop

If mdl > 0 Then OBJ3Free mdl
OBJ3Reset
System

'--------------------------------------------------------------
OpenModel:
pick = _OpenFileDialog$("Open a Wavefront model", "", "*.obj", "Wavefront OBJ", 0)
If Len(pick) > 0 Then
    ' full teardown first: frees the old textures and rewinds the
    ' shared pools, so opening file after file does not grow memory
    OBJ3Reset
    newMdl = OBJ3Load&(pick)
    If newMdl = 0 Then
        mdl = 0
        statusMsg = "Load failed: " + OBJ3Error$
    Else
        mdl = newMdl
        modelPath = pick
        statusMsg = "Loaded " + pick
        rx = 0: ry = 0: dist = 3
    End If
End If
' the dialog eats the mouse-up, so clear the click edge by hand
gMouse.held = 0
gMouse.prevHeld = 0
gMouse.clicked = 0
Return

'--------------------------------------------------------------
Function SpinName$ (sp As Integer)
    If sp Then SpinName$ = "Spin: on" Else SpinName$ = "Spin: off"
End Function

'$Include:'ButtonUI.bm'
'$Include:'OptButton.bm'
'$Include:'OBJ3.bm'
