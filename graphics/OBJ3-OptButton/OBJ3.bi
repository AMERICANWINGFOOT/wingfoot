'==============================================================
' OBJ3.bi -- Wavefront .OBJ display helper for QB64-PE 4.5.0
' Companion to W3 (wireframe helper).  Handle-based models,
' shared geometry pools, painter's-algorithm solid rendering.
'
' Include this file at the TOP of your .bas
' Include OBJ3.bm at the BOTTOM of your .bas
'==============================================================

Const OBJ3_MAXMODEL = 16
Const OBJ3_MAXMAT = 256

' render modes for OBJ3Draw
Const OBJ3_WIRE = 0
Const OBJ3_FLAT = 1
Const OBJ3_TEX = 2

' cull modes for OBJ3SetCull
Const OBJ3_CULLNONE = 0
Const OBJ3_CULLBACK = 1
Const OBJ3_CULLFRONT = 2

Type OBJ3MatType
    nam As String * 64
    kr As Single
    kg As Single
    kb As Single
    tex As Long
    hasTex As Integer
End Type

Type OBJ3ModelType
    used As Integer
    nam As String * 128
    vFirst As Long
    vNum As Long
    tFirst As Long
    tNum As Long
    fFirst As Long
    fNum As Long
    px As Single
    py As Single
    pz As Single
    rx As Single
    ry As Single
    rz As Single
    scl As Single
    radius As Single
End Type

' ---- shared geometry pools (dynamic, grown by OBJ3Load) ----
ReDim Shared obj3VX(1 To 1024) As Single
ReDim Shared obj3VY(1 To 1024) As Single
ReDim Shared obj3VZ(1 To 1024) As Single
Dim Shared obj3VCount As Long

ReDim Shared obj3TU(1 To 1024) As Single
ReDim Shared obj3TV(1 To 1024) As Single
Dim Shared obj3TCount As Long

ReDim Shared obj3FA(1 To 1024) As Long
ReDim Shared obj3FB(1 To 1024) As Long
ReDim Shared obj3FC(1 To 1024) As Long
ReDim Shared obj3FTA(1 To 1024) As Long
ReDim Shared obj3FTB(1 To 1024) As Long
ReDim Shared obj3FTC(1 To 1024) As Long
ReDim Shared obj3FM(1 To 1024) As Long
Dim Shared obj3FCount As Long

Dim Shared obj3Mat(1 To OBJ3_MAXMAT) As OBJ3MatType
Dim Shared obj3MatCount As Long

Dim Shared obj3Model(1 To OBJ3_MAXMODEL) As OBJ3ModelType

' ---- per-frame scratch (grown to fit the largest model) ----
ReDim Shared obj3SX(1 To 1024) As Single
ReDim Shared obj3SY(1 To 1024) As Single
ReDim Shared obj3WX(1 To 1024) As Single
ReDim Shared obj3WY(1 To 1024) As Single
ReDim Shared obj3WZ(1 To 1024) As Single
ReDim Shared obj3Ord(1 To 1024) As Long
ReDim Shared obj3Dep(1 To 1024) As Single

' ---- camera / lighting / state ----
Dim Shared obj3CamX As Single, obj3CamY As Single, obj3CamZ As Single
Dim Shared obj3Fov As Single
Dim Shared obj3Near As Single
Dim Shared obj3CX As Single, obj3CY As Single
Dim Shared obj3LX As Single, obj3LY As Single, obj3LZ As Single
Dim Shared obj3Ambient As Single
Dim Shared obj3Cull As Integer
Dim Shared obj3WireColor As _Unsigned Long
Dim Shared obj3Ready As Integer
Dim Shared obj3LastError As String

Declare Sub OBJ3Init ()
Declare Sub OBJ3SetView (fovDeg As Single, cx As Single, cy As Single)
Declare Sub OBJ3SetCamera (x As Single, y As Single, z As Single)
Declare Sub OBJ3SetLight (x As Single, y As Single, z As Single, ambient As Single)
Declare Sub OBJ3SetCull (kmode As Integer)
Declare Sub OBJ3SetPos (h As Long, x As Single, y As Single, z As Single)
Declare Sub OBJ3SetRot (h As Long, x As Single, y As Single, z As Single)
Declare Sub OBJ3SetScale (h As Long, s As Single)
Declare Sub OBJ3Normalize (h As Long)
Declare Sub OBJ3Draw (h As Long, dmode As Integer)
Declare Sub OBJ3FillTri (x1 As Single, y1 As Single, x2 As Single, y2 As Single, x3 As Single, y3 As Single, c As _Unsigned Long)
Declare Sub OBJ3LoadMTL (filePath As String)
Declare Sub OBJ3Free (h As Long)
Declare Sub OBJ3Reset ()
Declare Sub OBJ3GrowVerts (n As Long)
Declare Sub OBJ3GrowTexs (n As Long)
Declare Sub OBJ3GrowFaces (n As Long)
Declare Sub OBJ3GrowScratch (n As Long)
Declare Function OBJ3Load& (filePath As String)
Declare Function OBJ3Tok$ (s As String, n As Integer)
Declare Function OBJ3TokCount% (s As String)
Declare Function OBJ3RefIdx& (tok As String, part As Integer, cnt As Long)
Declare Function OBJ3DirOf$ (filePath As String)
Declare Function OBJ3MatFind& (nm As String)
Declare Function OBJ3TriCount& (h As Long)
Declare Function OBJ3VertCount& (h As Long)
Declare Function OBJ3Error$ ()
