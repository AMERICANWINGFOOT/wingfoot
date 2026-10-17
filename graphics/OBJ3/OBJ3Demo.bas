'==============================================================
' OBJ3Demo.bas -- demo for the OBJ3D model helper (QB64-PE 4.5.0)
'
' Keys:  1 wireframe   2 flat shaded   3 textured
'        arrows  rotate      A / Z  zoom       C  cycle cull
'        SPACE   pause spin  ESC    quit
'==============================================================

'$Include:'OBJ3.bi'

Dim Shared scr As Long
scr = _NewImage(1024, 768, 32)
Screen scr
_Title "OBJ3 viewer"

OBJ3Init
OBJ3SetView 60, 512, 384
OBJ3SetCamera 0, 0, 0
OBJ3SetLight -0.4, 0.7, -0.6, 0.25
OBJ3SetCull OBJ3_CULLBACK

Dim modelPath As String
modelPath = "ball.obj"
If Len(Command$(1)) > 0 Then modelPath = Command$(1)

Dim mdl As Long
mdl = OBJ3Load&(modelPath)
If mdl = 0 Then
    Print "Load failed: "; OBJ3Error$
    Print "Usage: OBJ3Demo <path to .obj>"
    Sleep
    System
End If

' model is auto-centred and normalized to radius 1 by the loader,
' so a fixed camera distance always frames it
OBJ3SetPos mdl, 0, 0, 3
OBJ3SetScale mdl, 1

Dim dmode As Integer, spin As Integer, dist As Single
Dim ry As Single, rx As Single, kk As Long, cullIdx As Integer
dmode = OBJ3_FLAT
spin = -1
dist = 3
cullIdx = OBJ3_CULLBACK

Do
    kk = _KeyHit
    If kk = 27 Then Exit Do
    If kk = Asc("1") Then dmode = OBJ3_WIRE
    If kk = Asc("2") Then dmode = OBJ3_FLAT
    If kk = Asc("3") Then dmode = OBJ3_TEX
    If kk = 32 Then spin = Not spin
    If kk = Asc("c") Or kk = Asc("C") Then
        cullIdx = cullIdx + 1
        If cullIdx > 2 Then cullIdx = 0
        OBJ3SetCull cullIdx
    End If

    If _KeyDown(19200) Then ry = ry - 0.04
    If _KeyDown(19712) Then ry = ry + 0.04
    If _KeyDown(18432) Then rx = rx - 0.04
    If _KeyDown(20480) Then rx = rx + 0.04
    If _KeyDown(Asc("a")) Or _KeyDown(Asc("A")) Then dist = dist - 0.05
    If _KeyDown(Asc("z")) Or _KeyDown(Asc("Z")) Then dist = dist + 0.05
    If dist < 1.5 Then dist = 1.5
    If dist > 40 Then dist = 40

    If spin Then ry = ry + 0.01

    Cls , _RGB32(16, 18, 24)

    OBJ3SetRot mdl, rx, ry, 0
    OBJ3SetPos mdl, 0, 0, dist
    OBJ3Draw mdl, dmode

    Color _RGB32(190, 190, 200), _RGB32(16, 18, 24)
    _PrintString (8, 8), "verts:" + Str$(OBJ3VertCount&(mdl)) + "  tris:" + Str$(OBJ3TriCount&(mdl))
    Dim mn As String
    If dmode = OBJ3_WIRE Then mn = "wire"
    If dmode = OBJ3_FLAT Then mn = "flat"
    If dmode = OBJ3_TEX Then mn = "textured"
    _PrintString (8, 20), "mode: " + mn + "   cull:" + Str$(cullIdx) + "   dist:" + Str$(CInt(dist * 10) / 10)
    _PrintString (8, 32), "1/2/3 mode  arrows rotate  A/Z zoom  C cull  SPACE spin  ESC quit"

    _Display
    _Limit 60
Loop

System

'$Include:'OBJ3.bm'
