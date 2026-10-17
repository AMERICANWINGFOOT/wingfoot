' GPU3D.bi - pixel-based 3D shapes, drawn by the GPU (CUDA library libg3d.so v1)
'
' Shapes are placed like a CIRCLE: x, y in screen pixels, a size in pixels,
' plus z (depth into the screen, in pixels) and three rotation angles in degrees.
' At z = 0 a shape is exactly the size you ask for; bigger z = farther away.
'
' Include this file near the top of your program and GPU3D.bm at the bottom
' (with QB64's include metacommand). Keep libg3d.so in the program's folder
' and run the program from there.

Const G3_BOX = 0
Const G3_SPHERE = 1
Const G3_CYLINDER = 2
Const G3_CONE = 3
Const G3_PYRAMID = 4
Const G3_DIAMOND = 5

' style flags for GPUStyle (add them together)
Const G3_SOLID = 0
Const G3_WIRE = 1
Const G3_OUTLINE = 2
Const G3_SHINY = 4
Const G3_FLAT = 8
Const G3_HIDDEN = 16

Declare Dynamic Library "./g3d"
    Function g3_init& (ByVal maxdev As Long, ByVal w As Long, ByVal h As Long)
    Sub g3_shutdown
    Sub g3_set_weight (ByVal dev As Long, ByVal wt As Single)
    Sub g3_view (ByVal focal As Single, ByVal vx As Single, ByVal vy As Single)
    Sub g3_light (ByVal lx As Single, ByVal ly As Single, ByVal lz As Single, ByVal ambient As Single)
    Sub g3_fog (ByVal nearZ As Single, ByVal farZ As Single, ByVal fogColor As _Unsigned Long)
    Sub g3_quality (ByVal aa As Long, ByVal lineWidth As Single)
    Sub g3_set_texture (ByVal id As Long, ByVal pixels As _Offset)
    Sub g3_begin
    Function g3_add& (ByVal shape As Long, ByVal x As Single, ByVal y As Single, ByVal z As Single, ByVal w As Single, ByVal h As Single, ByVal d As Single, ByVal ax As Single, ByVal ay As Single, ByVal az As Single, ByVal clr As _Unsigned Long, ByVal tex As Long, ByVal flags As Long)
    Function g3_count& ()
    Function g3_draw& (ByVal pixels As _Offset, ByVal mode As Long, ByVal bg As _Unsigned Long)
    Function g3_pick& (ByVal sx As Single, ByVal sy As Single)
    Sub g3_stats (gpuMs As Single, hostMs As Single)
    Function g3_device_count& ()
    Function g3_gpu_ms! (ByVal dev As Long)
    Function g3_vram_mb! (ByVal dev As Long)
    Sub g3_last_error (msg As String, ByVal msglen As Long)
End Declare

' current style and texture for new shapes, set by GPUStyle / GPUTexture
Dim Shared G3Style As Long, G3Tex As Long
' number of the last shape added (for GPUPick), image size, last draw result
Dim Shared G3LastShape As Long, G3W As Long, G3H As Long, G3Ok As Long
