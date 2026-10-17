'=======================================================================
'  W3.bi  --  3D wireframe helper for QB64-PE
'  Part of the QB64Starter toolkit.
'
'  Models are referenced by a Long handle. Right-handed-ish convention:
'  +x right, +y up, +z away from the viewer. The camera sits at
'  (w3camX, w3camY, w3camZ) looking down its own +z after yaw and pitch.
'
'  Call W3Init once, then W3SetViewport / W3SetLens / W3SetCamera.
'=======================================================================

Const W3_MAXMODELS = 16
Const W3_MAXVERT = 2048
Const W3_MAXEDGE = 4096

' --- model storage (parallel Single arrays: faster to index than a UDT) ---
Dim Shared w3vx(0 To W3_MAXMODELS - 1, 0 To W3_MAXVERT - 1) As Single
Dim Shared w3vy(0 To W3_MAXMODELS - 1, 0 To W3_MAXVERT - 1) As Single
Dim Shared w3vz(0 To W3_MAXMODELS - 1, 0 To W3_MAXVERT - 1) As Single
Dim Shared w3ea(0 To W3_MAXMODELS - 1, 0 To W3_MAXEDGE - 1) As Integer
Dim Shared w3eb(0 To W3_MAXMODELS - 1, 0 To W3_MAXEDGE - 1) As Integer
Dim Shared w3nv(0 To W3_MAXMODELS - 1) As Integer
Dim Shared w3ne(0 To W3_MAXMODELS - 1) As Integer
Dim Shared w3used(0 To W3_MAXMODELS - 1) As Integer

' --- per-model placement ---
Dim Shared w3posX(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3posY(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3posZ(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3rotX(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3rotY(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3rotZ(0 To W3_MAXMODELS - 1) As Single
Dim Shared w3scale(0 To W3_MAXMODELS - 1) As Single

' --- scratch: one model's vertices in VIEW space, reused every draw ---
Dim Shared w3tx(0 To W3_MAXVERT - 1) As Single
Dim Shared w3ty(0 To W3_MAXVERT - 1) As Single
Dim Shared w3tz(0 To W3_MAXVERT - 1) As Single

' --- camera + lens ---
Dim Shared w3camX As Single, w3camY As Single, w3camZ As Single
Dim Shared w3yaw As Single, w3pitch As Single
Dim Shared w3near As Single, w3far As Single
Dim Shared w3fov As Single, w3focal As Single
Dim Shared w3vw As Single, w3vh As Single
Dim Shared w3ox As Single, w3oy As Single

' --- depth cueing ---
Dim Shared w3cue As Integer '        -1 = fade distant edges toward w3fog
Dim Shared w3fog As _Unsigned Long
Dim Shared w3cueAmt As Single '      0..1, how far the furthest edge fades

Declare Function W3New& ()
Declare Function W3AddVert% (h As Long, x As Single, y As Single, z As Single)
Declare Function W3Mix~& (c1 As _Unsigned Long, c2 As _Unsigned Long, t As Single)

Declare Sub W3Init ()
Declare Sub W3Free (h As Long)
Declare Sub W3FreeAll ()
Declare Sub W3Clear (h As Long)
Declare Sub W3AddEdge (h As Long, a As Integer, b As Integer)
Declare Sub W3Cube (h As Long, sz As Single)
Declare Sub W3Box (h As Long, sx As Single, sy As Single, sz As Single)
Declare Sub W3Grid (h As Long, halfN As Integer, stepSize As Single)
Declare Sub W3Axes (h As Long, ln As Single)
Declare Sub W3SetPos (h As Long, x As Single, y As Single, z As Single)
Declare Sub W3SetRot (h As Long, rx As Single, ry As Single, rz As Single)
Declare Sub W3SetScale (h As Long, s As Single)
Declare Sub W3SetViewport (w As Single, hh As Single)
Declare Sub W3SetLens (fovDeg As Single, nearZ As Single, farZ As Single)
Declare Sub W3SetCamera (x As Single, y As Single, z As Single, yw As Single, pt As Single)
Declare Sub W3LookAt (x As Single, y As Single, z As Single, tx As Single, ty As Single, tz As Single)
Declare Sub W3SetDepthCue (onFlag As Integer, fogCol As _Unsigned Long)
Declare Sub W3SetCueAmount (amt As Single)
Declare Sub W3Draw (h As Long, col As _Unsigned Long)
Declare Sub W3DrawEdge (ax As Single, ay As Single, az As Single, bx As Single, by As Single, bz As Single, col As _Unsigned Long)
