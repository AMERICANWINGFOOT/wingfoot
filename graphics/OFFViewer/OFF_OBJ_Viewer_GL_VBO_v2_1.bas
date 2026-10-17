'$Dynamic
'$Include:'ButtonUI.bi'
' ============================================================
' off_viewer2.bas  -  OpenGL OFF / OBJ viewer  v2
'
' Loads either a Geomview .OFF or a Wavefront .OBJ (chosen by
' file extension) and renders it through a VBO/IBO.
'
' v2.2:  added an "Open..." button that loads a new model at
'        runtime.  The parse/build code now lives in LoadModel%,
'        and the VBO is re-uploaded on the GL thread via the
'        reloadPending flag (see SUB _GL).
'
' OBJ notes:
'   - v / vt / vn face refs all accepted; only the vertex index
'     is used ( vt / vn are ignored )
'   - n-gons are fan-triangulated
'   - negative (relative) vertex indices supported
'   - the model's own vn normals are ignored; per-vertex smooth
'     normals are recomputed, exactly like the OFF path
'
' Controls:
'   Mouse left-drag = rotate      Wheel = zoom
'   Arrows rotate   W/S/A/D pan   +/- zoom   R reset
'   Space spin  F flip-normals  C draw-mode  L light
'   V world-axes  H help  ESC/Q quit
' ============================================================
Declare Function PickFile$ (title As String)


Declare Library "offvbo v2"
    Sub initVBO (vx As Single, vy As Single, vz As Single, _
                 vnx As Single, vny As Single, vnz As Single, _
                 ByVal numV As _Unsigned _Integer64, _
                 ti0 As _Unsigned _Integer64, _
                 ti1 As _Unsigned _Integer64, _
                 ti2 As _Unsigned _Integer64, _
                 ByVal numTri As _Unsigned _Integer64)
    Sub renderMesh (ByVal flipNorm As Long)
    Sub freeVBO ()
End Declare

' ---- internal helpers (forward declared so the parser
'      calls below are unambiguous) ----
Declare Function objTok$ (s As String, n As Integer)
Declare Function objTokCount% (s As String)
Declare Function objFaceV& (tok As String, vcount As Long)
Declare Function FlagName$ (thebase As String, flag As Integer)
Declare Function LoadModel% (fname As String)

' ====================== SHARED GLOBALS ======================
Dim Shared doInit As Integer
Dim Shared vboLoaded As Integer
Dim Shared glReady As Integer

Dim Shared numV As _Unsigned _Integer64
Dim Shared numTri As _Unsigned _Integer64

' ---- geometry the GL thread reads (built by LoadModel%) ----
ReDim Shared vx(0) As Single
ReDim Shared vy(0) As Single
ReDim Shared vz(0) As Single
ReDim Shared vnx(0) As Single
ReDim Shared vny(0) As Single
ReDim Shared vnz(0) As Single
ReDim Shared ti0(0) As _Unsigned _Integer64
ReDim Shared ti1(0) As _Unsigned _Integer64
ReDim Shared ti2(0) As _Unsigned _Integer64

' View state
Dim Shared angX As Single, angY As Single
Dim Shared panX As Single, panY As Single, zDist As Single
Dim Shared autoSpin As Integer
Dim Shared flipNorm As Integer
Dim Shared drawMode As Integer ' 0=fill  1=wire  2=both
Dim Shared lightPre As Integer ' 0-3 light presets
Dim Shared showAxes As Integer ' world-space XYZ lines on/off
Dim Shared showHelp As Integer

' Load / reload state
Dim Shared modelName As String
Dim Shared reloadPending As Integer ' set by Open, consumed in SUB _GL

' Mouse state
Dim Shared mLastX As Long, mLastY As Long
Dim Shared mDrag As Integer
Dim Shared ih&
' ============================================================
ih& = _NewImage(1024, 768, 32)
Screen ih&
_Title "OFF / OBJ Viewer v2"

MouseInit ' set up the ButtonUI theme colours

' Render the OpenGL scene BEHIND the software layer. Without this the
' GL surface sits on top (the QB64 default) and hides the button bar
' and HUD. The software screen is never Cls'd, so everywhere we don't
' draw stays transparent and the 3D scene shows through.
_GLRender _Behind

' ---- top button bar geometry ----
Const SCRW = 1024
Const BAR_H = 40
Const BTN_Y = 6
Const BTN_H = 30

' ----------------------------------------------------------------
' Initial load (command line, else a default name)
' ----------------------------------------------------------------
Dim fname As String
fname = LTrim$(RTrim$(Command$))
If fname = "" Then fname = "apollo.obj"

If LoadModel%(fname) = 0 Then
    Print "Error - could not load: "; fname
    Print "(pass an .obj or .off on the command line, or use Open... in-app)"
    Sleep 4
    System
End If
modelName = fname

' ----------------------------------------------------------------
' Defaults
' ----------------------------------------------------------------
angX = 0.3: angY = 0.5
panX = 0: panY = 0: zDist = -3.0
autoSpin = 0: flipNorm = 0: drawMode = 0: lightPre = 0
showAxes = -1: showHelp = 0 ' axes visible by default
doInit = -1: vboLoaded = 0: glReady = -1
reloadPending = 0
mDrag = 0: mLastX = 0: mLastY = 0

_Title "OFF / OBJ Viewer v2  -  " + _Trim$(Str$(numV)) + " verts  " + _Trim$(Str$(numTri)) + " tris  [H=help]"

' ================================================================
' Main loop
' ================================================================
Dim k As Long
Dim lastTime As Double
Dim dt As Single
Dim mx As Long, my As Long
Dim mw As Long
Dim dmName As String, ltName As String

lastTime = Timer

Do
    ' ---- Mouse input (ButtonUI PollMouse + guarded drag-rotate) ----
    PollMouse ' drains the queue and refreshes gMouse for the buttons
    mw = _MouseWheel
    If mw <> 0 Then zDist = zDist + mw * 0.25

    ' A rotate-drag begins only on a fresh press in the 3D area (below
    ' the top bar), so pressing a button never grabs the model.
    If gMouse.held = 0 Then
        mDrag = 0
    ElseIf mDrag = 0 And gMouse.prevHeld = 0 And gMouse.my > BAR_H Then
        mDrag = -1
        mLastX = gMouse.mx
        mLastY = gMouse.my
    End If
    If mDrag Then
        angY = angY + (gMouse.mx - mLastX) * 0.012
        angX = angX + (gMouse.my - mLastY) * 0.012
        mLastX = gMouse.mx
        mLastY = gMouse.my
    End If

    ' ---- Keyboard ----
    k = _KeyHit
    Select Case k
        Case 27, 81, 113: Exit Do ' ESC / Q / q

        Case 18432: angX = angX - 0.04 ' Arrow Up
        Case 20480: angX = angX + 0.04 ' Arrow Down
        Case 19200: angY = angY - 0.04 ' Arrow Left
        Case 19712: angY = angY + 0.04 ' Arrow Right

        Case 43: zDist = zDist + 0.15 ' +  zoom in
        Case 45: zDist = zDist - 0.15 ' -  zoom out

        Case 87, 119: panY = panY + 0.05 ' W  pan up
        Case 83, 115: panY = panY - 0.05 ' S  pan down
        Case 65, 97: panX = panX - 0.05 ' A  pan left
        Case 68, 100: panX = panX + 0.05 ' D  pan right

        Case 82, 114: ' R  reset view
            angX = 0.3: angY = 0.5
            panX = 0: panY = 0: zDist = -3.0

        Case 32: autoSpin = Not autoSpin ' Space  auto-spin
        Case 70, 102: flipNorm = Not flipNorm ' F      flip normals
        Case 67, 99: drawMode = (drawMode + 1) Mod 3 ' C  cycle draw
        Case 76, 108: lightPre = (lightPre + 1) Mod 4 ' L  cycle light
        Case 86, 118: showAxes = Not showAxes ' V      toggle world axes
        Case 72, 104: showHelp = Not showHelp ' H      toggle help
        Case 79, 111: GoSub DoOpen ' O      open a file
    End Select

    ' ---- Auto-spin ----
    If autoSpin Then
        dt = (Timer - lastTime) * 60
        angY = angY + 0.008 * dt
        angX = angX + 0.003 * dt
    End If
    lastTime = Timer

    ' ---- top button bar (software layer, drawn over GL) ----
    ' opaque strip + divider so the buttons read cleanly over the scene
    Line (0, 0)-(SCRW, BAR_H), _RGB32(28, 32, 42), BF
    Line (0, BAR_H)-(SCRW, BAR_H), _RGB32(60, 68, 86)

    Select Case drawMode
        Case 0: dmName = "Draw: Fill"
        Case 1: dmName = "Draw: Wire"
        Case Else: dmName = "Draw: Both"
    End Select
    ltName = "Light:" + Str$(lightPre + 1)

    If Button%(8, BTN_Y, 110, BTN_H, dmName) Then drawMode = (drawMode + 1) Mod 3
    If Button%(126, BTN_Y, 92, BTN_H, ltName) Then lightPre = (lightPre + 1) Mod 4
    If Button%(226, BTN_Y, 84, BTN_H, FlagName$("Flip", flipNorm)) Then flipNorm = Not flipNorm
    If Button%(318, BTN_Y, 84, BTN_H, FlagName$("Axes", showAxes)) Then showAxes = Not showAxes
    If Button%(410, BTN_Y, 84, BTN_H, FlagName$("Spin", autoSpin)) Then autoSpin = Not autoSpin
    If Button%(502, BTN_Y, 80, BTN_H, "Reset") Then angX = 0.3: angY = 0.5: panX = 0: panY = 0: zDist = -3.0
    If Button%(590, BTN_Y, 64, BTN_H, "Zoom+") Then zDist = zDist + 0.2
    If Button%(662, BTN_Y, 64, BTN_H, "Zoom-") Then zDist = zDist - 0.2
    If Button%(734, BTN_Y, 64, BTN_H, "Help") Then showHelp = Not showHelp
    If Button%(806, BTN_Y, 96, BTN_H, "Open...") Then GoSub DoOpen
    If Button%(910, BTN_Y, 64, BTN_H, "Quit") Then Exit Do
    _Display
    ' ---- HUD help (below the bar) ----
    If showHelp Then
        _PrintString (10, 50), "Mouse drag  = rotate      Wheel = zoom"
        _PrintString (10, 66), "Arrow keys  = rotate"
        _PrintString (10, 82), "W/S/A/D     = pan         +/-   = zoom"
        _PrintString (10, 98), "R           = reset view"
        _PrintString (10, 114), "Space       = auto-spin   F = flip normals"
        _PrintString (10, 130), "C           = draw mode (fill / wire / both)"
        _PrintString (10, 146), "L           = cycle light preset"
        _PrintString (10, 162), "V           = toggle world XYZ axes"
        _PrintString (10, 178), "O           = open a model"
        _PrintString (10, 194), "H           = this help"
        _PrintString (10, 210), "ESC / Q     = quit"
        _PrintString (10, 234), "Gizmo (bottom-left): red=X  green=Y  blue=Z"
    End If

    Rem _Limit 60
Loop Until _Exit

freeVBO
System

'--------------------------------------------------------------
' Open a model at runtime.  Parses into the shared arrays and, on
' success, flags the GL thread to re-upload the VBO.  A failed
' load leaves the current model untouched.
'--------------------------------------------------------------
DoOpen:
Dim pick As String
pick = PickFile$("Open a model")
If Len(pick) > 0 Then
    If LoadModel%(pick) Then
        modelName = pick
        reloadPending = -1
        angX = 0.3: angY = 0.5: panX = 0: panY = 0: zDist = -3.0
        _Title "OFF / OBJ Viewer v2  -  " + _Trim$(Str$(numV)) + " verts  " + _Trim$(Str$(numTri)) + " tris  [H=help]"
    End If
End If
gMouse.held = 0: gMouse.prevHeld = 0: gMouse.clicked = 0
Return

' ================================================================
' Geometry loader  -  returns -1 on success, 0 on failure.
' Rebuilds the shared vx/vy/vz, vnx/vny/vnz, ti0/ti1/ti2 arrays
' and sets numV / numTri.  All failure exits happen BEFORE any
' shared array is overwritten, so the caller's current model
' survives a bad file.
' ================================================================
Function LoadModel% (fname As String)
    LoadModel% = 0 ' assume failure until we finish

    If Not _FileExists(fname) Then Exit Function

    Dim vertexCount As _Unsigned _Integer64
    Dim faceCount As _Unsigned _Integer64
    Dim edgeCount As _Unsigned _Integer64
    Dim totalTri As _Unsigned _Integer64
    Dim i As _Unsigned _Integer64
    Dim isOBJ As Integer

    isOBJ = (LCase$(Right$(fname, 4)) = ".obj")

    ' ---- local scratch (temp geometry before commit) ----
    ReDim tvx(0) As Single
    ReDim tvy(0) As Single
    ReDim tvz(0) As Single
    ReDim fv0(0) As _Unsigned _Integer64
    ReDim fv1(0) As _Unsigned _Integer64
    ReDim fv2(0) As _Unsigned _Integer64
    ReDim fv3(0) As _Unsigned _Integer64
    ReDim fSide(0) As Integer

    If isOBJ Then
        '=================== Wavefront .OBJ ===================
        Dim oln As String, otag As String, ontok As Integer, ok As Integer
        Dim nv As Long, nt As Long, va As Long, vb As Long, vcc As Long
        Dim cv As Long, cf As Long ' write cursors

        ' ---- pass 1: count vertices and fan-triangulated faces ----
        nv = 0: nt = 0
        Open fname For Input As #1
        Do While Not EOF(1)
            Line Input #1, oln
            oln = _Trim$(oln)
            If Len(oln) > 0 Then
                otag = LCase$(objTok$(oln, 1))
                If otag = "v" Then
                    nv = nv + 1
                ElseIf otag = "f" Then
                    ontok = objTokCount%(oln)
                    If ontok >= 4 Then nt = nt + (ontok - 3) ' (verts-2) triangles
                End If
            End If
        Loop
        Close #1

        If nv < 3 Or nt < 1 Then Exit Function ' nothing usable; keep old model

        vertexCount = nv
        edgeCount = 0
        ReDim tvx(nv - 1) As Single
        ReDim tvy(nv - 1) As Single
        ReDim tvz(nv - 1) As Single
        ReDim fv0(nt - 1) As _Unsigned _Integer64
        ReDim fv1(nt - 1) As _Unsigned _Integer64
        ReDim fv2(nt - 1) As _Unsigned _Integer64
        ReDim fv3(nt - 1) As _Unsigned _Integer64
        ReDim fSide(nt - 1) As Integer

        ' ---- pass 2: fill ----
        cv = 0: cf = 0
        Open fname For Input As #1
        Do While Not EOF(1)
            Line Input #1, oln
            oln = _Trim$(oln)
            If Len(oln) > 0 Then
                otag = LCase$(objTok$(oln, 1))
                If otag = "v" Then
                    tvx(cv) = Val(objTok$(oln, 2))
                    tvy(cv) = Val(objTok$(oln, 3))
                    tvz(cv) = Val(objTok$(oln, 4))
                    cv = cv + 1
                ElseIf otag = "f" Then
                    ontok = objTokCount%(oln)
                    If ontok >= 4 Then
                        ' fan: (1,2,3) (1,3,4) (1,4,5) ...   cv = verts seen
                        va = objFaceV&(objTok$(oln, 2), cv)
                        For ok = 3 To ontok - 1
                            vb = objFaceV&(objTok$(oln, ok), cv)
                            vcc = objFaceV&(objTok$(oln, ok + 1), cv)
                            If va >= 0 And vb >= 0 And vcc >= 0 Then
                                If va < nv And vb < nv And vcc < nv Then
                                    fv0(cf) = va: fv1(cf) = vb: fv2(cf) = vcc: fv3(cf) = 0
                                    fSide(cf) = 3
                                    cf = cf + 1
                                End If
                            End If
                        Next ok
                    End If
                End If
            End If
        Loop
        Close #1

        totalTri = cf
        faceCount = cf

    Else
        '=================== Geomview .OFF ===================
        Open fname For Input As #1
        Dim hdr As String
        Line Input #1, hdr
        hdr = UCase$(LTrim$(RTrim$(hdr)))

        If Left$(hdr, 3) = "OFF" Then
            Input #1, vertexCount, faceCount, edgeCount
        Else
            ' First line already contains the counts
            Dim ha(2) As _Unsigned _Integer64
            Dim hc As Integer, hp As Integer
            Dim tok As String
            hp = 1
            Do While hp <= Len(hdr) And hc < 3
                tok = ""
                Do While hp <= Len(hdr) And Mid$(hdr, hp, 1) <= " ": hp = hp + 1: Loop
                Do While hp <= Len(hdr) And Mid$(hdr, hp, 1) > " "
                    tok = tok + Mid$(hdr, hp, 1): hp = hp + 1
                Loop
                If Len(tok) > 0 Then ha(hc) = Val(tok): hc = hc + 1
            Loop
            vertexCount = ha(0): faceCount = ha(1): edgeCount = ha(2)
        End If

        If vertexCount < 3 Or faceCount < 1 Then Close #1: Exit Function

        ' ---- vertices ----
        ReDim tvx(vertexCount - 1) As Single
        ReDim tvy(vertexCount - 1) As Single
        ReDim tvz(vertexCount - 1) As Single
        For i = 0 To vertexCount - 1
            Input #1, tvx(i), tvy(i), tvz(i)
        Next i

        ' ---- faces (triangles + quads) ----
        ReDim fv0(faceCount - 1) As _Unsigned _Integer64
        ReDim fv1(faceCount - 1) As _Unsigned _Integer64
        ReDim fv2(faceCount - 1) As _Unsigned _Integer64
        ReDim fv3(faceCount - 1) As _Unsigned _Integer64
        ReDim fSide(faceCount - 1) As Integer
        Dim vc As _Unsigned _Integer64
        For i = 0 To faceCount - 1
            Input #1, vc
            fSide(i) = vc
            If vc = 3 Then
                Input #1, fv0(i), fv1(i), fv2(i)
                fv3(i) = 0
                totalTri = totalTri + 1
            ElseIf vc = 4 Then
                Input #1, fv0(i), fv1(i), fv2(i), fv3(i)
                totalTri = totalTri + 2
            Else
                fv0(i) = 0: fv1(i) = 0: fv2(i) = 0: fv3(i) = 0
            End If
        Next i
        Close #1
    End If

    If totalTri < 1 Then Exit Function

    ' ============================================================
    ' From here on we commit to the shared arrays.
    ' ============================================================

    ' ---- auto-scale & centre ----
    Dim minX As Single, maxX As Single
    Dim minY As Single, maxY As Single
    Dim minZ As Single, maxZ As Single
    minX = tvx(0): maxX = minX
    minY = tvy(0): maxY = minY
    minZ = tvz(0): maxZ = minZ

    For i = 1 To vertexCount - 1
        If tvx(i) < minX Then minX = tvx(i)
        If tvx(i) > maxX Then maxX = tvx(i)
        If tvy(i) < minY Then minY = tvy(i)
        If tvy(i) > maxY Then maxY = tvy(i)
        If tvz(i) < minZ Then minZ = tvz(i)
        If tvz(i) > maxZ Then maxZ = tvz(i)
    Next i

    Dim rng As Single
    rng = maxX - minX
    If maxY - minY > rng Then rng = maxY - minY
    If maxZ - minZ > rng Then rng = maxZ - minZ
    If rng < 0.00001 Then rng = 1

    Dim sc As Single: sc = 1.0 / rng
    Dim cx As Single: cx = (minX + maxX) / 2
    Dim cy As Single: cy = (minY + maxY) / 2
    Dim cz As Single: cz = (minZ + maxZ) / 2

    ' ---- vertex + normal arrays ----
    numV = vertexCount
    ReDim vx(numV - 1) As Single
    ReDim vy(numV - 1) As Single
    ReDim vz(numV - 1) As Single
    ReDim vnx(numV - 1) As Single
    ReDim vny(numV - 1) As Single
    ReDim vnz(numV - 1) As Single

    For i = 0 To numV - 1
        vx(i) = (tvx(i) - cx) * sc
        vy(i) = (tvy(i) - cy) * sc
        vz(i) = (tvz(i) - cz) * sc
    Next i

    ' ---- accumulate face normals -> per-vertex averaged normals ----
    Dim fa As _Unsigned _Integer64
    Dim fb As _Unsigned _Integer64
    Dim fc As _Unsigned _Integer64
    Dim e1x As Single, e1y As Single, e1z As Single
    Dim e2x As Single, e2y As Single, e2z As Single
    Dim fnx As Single, fny As Single, fnz As Single

    For i = 0 To faceCount - 1
        If fSide(i) >= 3 Then
            fa = fv0(i): fb = fv1(i): fc = fv2(i)

            e1x = vx(fb) - vx(fa): e1y = vy(fb) - vy(fa): e1z = vz(fb) - vz(fa)
            e2x = vx(fc) - vx(fa): e2y = vy(fc) - vy(fa): e2z = vz(fc) - vz(fa)
            fnx = e1y * e2z - e1z * e2y
            fny = e1z * e2x - e1x * e2z
            fnz = e1x * e2y - e1y * e2x

            vnx(fa) = vnx(fa) + fnx: vny(fa) = vny(fa) + fny: vnz(fa) = vnz(fa) + fnz
            vnx(fb) = vnx(fb) + fnx: vny(fb) = vny(fb) + fny: vnz(fb) = vnz(fb) + fnz
            vnx(fc) = vnx(fc) + fnx: vny(fc) = vny(fc) + fny: vnz(fc) = vnz(fc) + fnz

            If fSide(i) = 4 Then ' second triangle of quad
                fb = fv2(i): fc = fv3(i)
                e1x = vx(fb) - vx(fa): e1y = vy(fb) - vy(fa): e1z = vz(fb) - vz(fa)
                e2x = vx(fc) - vx(fa): e2y = vy(fc) - vy(fa): e2z = vz(fc) - vz(fa)
                fnx = e1y * e2z - e1z * e2y
                fny = e1z * e2x - e1x * e2z
                fnz = e1x * e2y - e1y * e2x
                vnx(fa) = vnx(fa) + fnx: vny(fa) = vny(fa) + fny: vnz(fa) = vnz(fa) + fnz
                vnx(fb) = vnx(fb) + fnx: vny(fb) = vny(fb) + fny: vnz(fb) = vnz(fb) + fnz
                vnx(fc) = vnx(fc) + fnx: vny(fc) = vny(fc) + fny: vnz(fc) = vnz(fc) + fnz
            End If
        End If
    Next i

    ' ---- normalise ----
    Dim nl As Single
    For i = 0 To numV - 1
        nl = Sqr(vnx(i) * vnx(i) + vny(i) * vny(i) + vnz(i) * vnz(i))
        If nl < 0.00001 Then nl = 1
        vnx(i) = vnx(i) / nl: vny(i) = vny(i) / nl: vnz(i) = vnz(i) / nl
    Next i

    ' ---- index arrays ----
    numTri = totalTri
    ReDim ti0(numTri - 1) As _Unsigned _Integer64
    ReDim ti1(numTri - 1) As _Unsigned _Integer64
    ReDim ti2(numTri - 1) As _Unsigned _Integer64

    Dim t As _Unsigned _Integer64
    t = 0
    For i = 0 To faceCount - 1
        ti0(t) = fv0(i): ti1(t) = fv1(i): ti2(t) = fv2(i): t = t + 1
        If fSide(i) = 4 Then
            ti0(t) = fv0(i): ti1(t) = fv2(i): ti2(t) = fv3(i): t = t + 1
        End If
    Next i

    LoadModel% = -1 ' success
End Function

' ================================================================
' OBJ helper functions
' ================================================================

' whitespace tokenizer (collapses runs of spaces and tabs)
Function objTokCount% (s As String)
    Dim i As Long, iinT As Integer, n As Integer, ch As String * 1
    iinT = 0: n = 0
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch = " " Or ch = Chr$(9) Then
            iinT = 0
        Else
            If iinT = 0 Then n = n + 1
            iinT = -1
        End If
    Next i
    objTokCount% = n
End Function

Function objTok$ (s As String, n As Integer)
    Dim i As Long, iinT As Integer, k As Integer, st As Long, ch As String * 1
    iinT = 0: k = 0: st = 0
    For i = 1 To Len(s)
        ch = Mid$(s, i, 1)
        If ch = " " Or ch = Chr$(9) Then
            If iinT Then
                If k = n Then objTok$ = Mid$(s, st, i - st): Exit Function
            End If
            iinT = 0
        Else
            If iinT = 0 Then
                k = k + 1
                st = i
            End If
            iinT = -1
        End If
    Next i
    If iinT And k = n Then objTok$ = Mid$(s, st) Else objTok$ = ""
End Function

' parse the vertex index out of a face token ("12", "12/7",
' "12//9", "12/7/9"), return it 0-based, resolving negative
' (relative) references against vcount (verts seen so far).
' returns -1 on failure.
Function objFaceV& (tok As String, vcount As Long)
    Dim p As Long, fld As String, raw As Long
    p = InStr(tok, "/")
    If p > 0 Then fld = Left$(tok, p - 1) Else fld = tok
    fld = _Trim$(fld)
    If Len(fld) = 0 Then objFaceV& = -1: Exit Function
    raw = Val(fld)
    If raw > 0 Then
        objFaceV& = raw - 1
    ElseIf raw < 0 Then
        objFaceV& = vcount + raw ' -1 -> last vertex read so far
    Else
        objFaceV& = -1
    End If
End Function

' caption for a toggle button, e.g. FlagName$("Spin", autoSpin) -> "Spin: on"
Function FlagName$ (thebase As String, flag As Integer)
    If flag Then FlagName$ = thebase + ": on" Else FlagName$ = thebase + ": off"
End Function

' ================================================================
Sub _GL ()
    ' ================================================================
    If Not glReady Then Exit Sub

    ' ---- Runtime reload: Open... parsed a new model into the shared
    '      arrays and raised reloadPending. Tear the old VBO down and
    '      re-arm the one-time upload below. Both must happen on this
    '      (GL) thread. ----
    If reloadPending Then
        freeVBO
        doInit = -1
        vboLoaded = 0
        reloadPending = 0
    End If

    ' ---- One-time VBO upload (must happen inside the GL thread) ----
    If doInit Then
        initVBO vx(0), vy(0), vz(0), vnx(0), vny(0), vnz(0), numV, _
                ti0(0), ti1(0), ti2(0), numTri
        doInit = 0
        vboLoaded = -1
    End If
    If Not vboLoaded Then Exit Sub

    ' ================================================================
    ' PASS 1 - main scene
    ' ================================================================
    Dim W As Long: W = _Width
    Dim H As Long: H = _Height

    _glViewport 0, 0, W, H

    ' Perspective projection
    _glMatrixMode _GL_PROJECTION
    _glLoadIdentity

    Dim fov As Single: fov = 0.7854 ' 45 deg
    Dim aspect As Single: aspect = W / H
    Dim f As Single: f = 1.0 / Tan(fov / 2)
    Dim zN As Single: zN = 0.1
    Dim zF As Single: zF = 200.0

    Dim pm(15) As Single
    pm(0) = f / aspect
    pm(5) = f
    pm(10) = -(zF + zN) / (zF - zN)
    pm(11) = -1
    pm(14) = -2 * zF * zN / (zF - zN)
    _glLoadMatrixf _Offset(pm(0))

    ' Modelview
    _glMatrixMode _GL_MODELVIEW
    _glLoadIdentity
    _glTranslatef panX, panY, zDist
    _glRotatef angX * 57.2958!, 1, 0, 0
    _glRotatef angY * 57.2958!, 0, 1, 0

    ' Clear
    _glClearColor 0.07, 0.07, 0.10, 1.0
    _glClear _GL_COLOR_BUFFER_BIT Or _GL_DEPTH_BUFFER_BIT

    _glEnable _GL_DEPTH_TEST
    _glDepthFunc _GL_LESS

    ' ---- Lighting ----
    _glEnable _GL_LIGHTING
    _glEnable _GL_NORMALIZE
    _glEnable _GL_LIGHT0
    _glEnable _GL_COLOR_MATERIAL
    _glColorMaterial _GL_FRONT_AND_BACK, _GL_AMBIENT_AND_DIFFUSE

    Dim lp(3) As Single
    Select Case lightPre
        Case 0: lp(0) = 1: lp(1) = 1: lp(2) = 1 ' top-right-front
        Case 1: lp(0) = 0: lp(1) = 1: lp(2) = 0 ' top
        Case 2: lp(0) = 1: lp(1) = 0: lp(2) = 0 ' right
        Case 3: lp(0) = 0: lp(1) = 0: lp(2) = 1 ' front
    End Select
    lp(3) = 0 ' directional
    _glLightfv _GL_LIGHT0, _GL_POSITION, _Offset(lp(0))

    Dim ms(3) As Single
    ms(0) = 0.3: ms(1) = 0.3: ms(2) = 0.35: ms(3) = 1
    _glMaterialfv _GL_FRONT_AND_BACK, _GL_SPECULAR, _Offset(ms(0))
    _glMaterialf _GL_FRONT_AND_BACK, _GL_SHININESS, 40

    If flipNorm Then _glFrontFace _GL_CW Else _glFrontFace _GL_CCW

    ' ---- Render mesh ----
    If drawMode = 0 Or drawMode = 2 Then
        _glPolygonMode _GL_FRONT_AND_BACK, _GL_FILL
        _glEnable _GL_LIGHTING
        _glColor3f 0.78, 0.72, 0.65
        renderMesh flipNorm
    End If

    If drawMode = 1 Or drawMode = 2 Then
        _glDisable _GL_LIGHTING
        _glPolygonMode _GL_FRONT_AND_BACK, _GL_LINE
        If drawMode = 2 Then
            _glEnable _GL_POLYGON_OFFSET_LINE
            _glPolygonOffset -1.0, -1.0
            _glColor3f 0.0, 0.6, 1.0
        Else
            _glColor3f 0.0, 0.9, 1.0
        End If
        renderMesh flipNorm
        If drawMode = 2 Then _glDisable _GL_POLYGON_OFFSET_LINE
    End If

    _glPolygonMode _GL_FRONT_AND_BACK, _GL_FILL
    _glFrontFace _GL_CCW

    ' ---- World-space XYZ axis lines (toggleable with V) ----
    If showAxes Then
        _glDisable _GL_LIGHTING
        _glDisable _GL_DEPTH_TEST ' draw over mesh so always visible

        Dim aLen As Single: aLen = 0.65

        _glLineWidth 2.5
        _glBegin _GL_LINES
        ' X  red
        _glColor3f 1.0, 0.18, 0.18
        _glVertex3f 0, 0, 0
        _glVertex3f aLen, 0, 0
        ' Y  green
        _glColor3f 0.18, 1.0, 0.18
        _glVertex3f 0, 0, 0
        _glVertex3f 0, aLen, 0
        ' Z  blue
        _glColor3f 0.2, 0.45, 1.0
        _glVertex3f 0, 0, 0
        _glVertex3f 0, 0, aLen
        _glEnd
        _glLineWidth 1.0

        ' Coloured tips (large dots)
        _glPointSize 7.0
        _glBegin _GL_POINTS
        _glColor3f 1.0, 0.18, 0.18
        _glVertex3f aLen, 0, 0
        _glColor3f 0.18, 1.0, 0.18
        _glVertex3f 0, aLen, 0
        _glColor3f 0.2, 0.45, 1.0
        _glVertex3f 0, 0, aLen
        _glEnd
        _glPointSize 1.0

        _glEnable _GL_DEPTH_TEST
    End If

    ' ================================================================
    ' PASS 2 - corner orientation gizmo  (bottom-left 120x120 px)
    '   Only rotation is applied - no pan/zoom - so it always shows
    '   the current orientation regardless of where the model is.
    ' ================================================================
    Dim gSz As Long: gSz = 120

    _glViewport 0, 0, gSz, gSz
    _glScissor 0, 0, gSz, gSz
    _glEnable _GL_SCISSOR_TEST

    ' Dark background for the gizmo panel
    _glClearColor 0.11, 0.11, 0.14, 1.0
    _glClear _GL_COLOR_BUFFER_BIT Or _GL_DEPTH_BUFFER_BIT

    ' Orthographic: world units span -1.4 .. +1.4 each side
    _glMatrixMode _GL_PROJECTION
    _glLoadIdentity
    _glOrtho -1.4, 1.4, -1.4, 1.4, -10.0, 10.0

    ' Same rotation as main view, but no translation / zoom
    _glMatrixMode _GL_MODELVIEW
    _glLoadIdentity
    _glRotatef angX * 57.2958!, 1, 0, 0
    _glRotatef angY * 57.2958!, 0, 1, 0

    _glDisable _GL_LIGHTING
    _glDisable _GL_DEPTH_TEST

    ' Thin dark outline arrows first (depth-cue trick)
    Dim gL As Single: gL = 0.9

    _glLineWidth 4.5
    _glBegin _GL_LINES
    _glColor3f 0.08, 0.08, 0.08
    _glVertex3f 0, 0, 0: _glVertex3f gL, 0, 0
    _glVertex3f 0, 0, 0: _glVertex3f 0, gL, 0
    _glVertex3f 0, 0, 0: _glVertex3f 0, 0, gL
    _glEnd

    ' Bright coloured arms on top
    _glLineWidth 2.5
    _glBegin _GL_LINES
    _glColor3f 1.0, 0.2, 0.2: _glVertex3f 0, 0, 0: _glVertex3f gL, 0, 0
    _glColor3f 0.2, 1.0, 0.2: _glVertex3f 0, 0, 0: _glVertex3f 0, gL, 0
    _glColor3f 0.3, 0.5, 1.0: _glVertex3f 0, 0, 0: _glVertex3f 0, 0, gL
    _glEnd
    _glLineWidth 1.0

    ' Tip dots
    _glPointSize 8.0
    _glBegin _GL_POINTS
    _glColor3f 1.0, 0.2, 0.2: _glVertex3f gL, 0, 0 ' X
    _glColor3f 0.2, 1.0, 0.2: _glVertex3f 0, gL, 0 ' Y
    _glColor3f 0.3, 0.5, 1.0: _glVertex3f 0, 0, gL ' Z
    _glEnd
    _glPointSize 1.0

    ' Origin dot
    _glPointSize 5.0
    _glBegin _GL_POINTS
    _glColor3f 0.7, 0.7, 0.7
    _glVertex3f 0, 0, 0
    _glEnd
    _glPointSize 1.0

    _glDisable _GL_SCISSOR_TEST

    ' Restore full viewport for next frame
    _glViewport 0, 0, W, H
    _Display
End Sub
'--------------------------------------------------------------
' In-app file picker.  Draws a modal list over the live GL scene
' and returns the chosen path (or "" if cancelled).  Replaces
' _OpenFileDialog$, which deadlocks against the GL render thread.
'--------------------------------------------------------------
Function PickFile$ (title As String)
    Dim ffiles(1 To 1024) As String
    Dim n As Integer, i As Integer, page As Integer, perPage As Integer
    Dim fn As String, k As Long, idx As Integer
    Dim px As Integer, py As Integer, pw As Integer, ph As Integer
    Dim rowY As Integer, navY As Integer

    ' gather *.obj then *.off in the current directory
    n = 0
    fn = _Files$("*.obj")
    Do While fn <> "" And n < 1024
        n = n + 1: ffiles(n) = fn
        fn = _Files$
    Loop
    fn = _Files$("*.off")
    Do While fn <> "" And n < 1024
        n = n + 1: ffiles(n) = fn
        fn = _Files$
    Loop

    perPage = 16
    page = 0
    px = 262: pw = 500
    py = 90: ph = 34 + perPage * 20 + 44

    PickFile$ = ""

    ' swallow the click edge that opened this picker
    gMouse.held = 0: gMouse.prevHeld = 0: gMouse.clicked = 0

    Do
        PollMouse
        k = _KeyHit
        If k = 27 Then Exit Do ' ESC cancels

        ' panel
        Line (px, py)-(px + pw, py + ph), _RGB32(24, 28, 38), BF
        Line (px, py)-(px + pw, py + ph), _RGB32(80, 90, 112), B
        Color _RGB32(210, 214, 224), _RGB32(24, 28, 38)
        _PrintString (px + 12, py + 9), title + "   (" + _Trim$(Str$(n)) + " files)"

        ' one button per visible file
        For i = 0 To perPage - 1
            idx = page * perPage + i + 1
            If idx <= n Then
                rowY = py + 32 + i * 20
                If Button%(px + 12, rowY, pw - 24, 18, ffiles(idx)) Then
                    PickFile$ = ffiles(idx): Exit Do
                End If
            End If
        Next i

        ' nav + cancel
        navY = py + ph - 34
        If page > 0 Then
            If Button%(px + 12, navY, 90, 26, "< Prev") Then page = page - 1
        End If
        If (page + 1) * perPage < n Then
            If Button%(px + 108, navY, 90, 26, "Next >") Then page = page + 1
        End If
        If Button%(px + pw - 100, navY, 88, 26, "Cancel") Then Exit Do

        _Display
        Rem _Limit 60
    Loop

    ' erase the panel back to transparent so the GL scene shows through
    _DontBlend
    Line (px, py)-(px + pw, py + ph), _RGBA32(0, 0, 0, 0), BF
    _Blend
End Function

'$Include:'ButtonUI.bm'
