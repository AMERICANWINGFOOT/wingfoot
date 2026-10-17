' IndexView.bas - viewer for astrometry.net plate-solving index files
' QB64-PE 4.5.0
'
' Shows what is really inside an index-*.fits file: the HDU (table) list,
' every header card, a hex peek at each table's data, and a sky map of the
' stars decoded from the star kd-tree, with the solver's quads drawn on top.
'
' Usage:  ./IndexView [index-xxxx.fits]     (no argument = open dialog)
'
' Keys
'   M  sky map            H  header + hex view of the selected HDU
'   A  all-sky view       Q  toggle quads       G  toggle grid
'   N / P  next / previous .fits file in the same folder
'   O  open file          Esc  quit
' Mouse
'   Map, all-sky view : click a spot to zoom into it
'   Map, close view   : wheel zooms at the cursor, drag pans
'   Left panel        : click an HDU to view its header
'   Header view       : wheel or Up/Down/PgUp/PgDn scrolls
'
' Index file layout (as written by astrometry.net's build-astrometry-index):
'   primary HDU   no image; header has INDEXID, SCALE_L/SCALE_U (radians),
'                 HEALPIX/HPNSIDE, NSTARS, NQUADS, DIMQUADS
'   quads         DIMQUADS x u32 star numbers per row (native little-endian)
'   kdtree_*_codes  the quad hash-code tree
'   kdtree_header_stars  KDT_DATA type (u32/u16/double/float), KDT_NDAT
'   kdtree_range_stars   doubles: min x,y,z  max x,y,z  scale
'   kdtree_data_stars    star unit vectors; integer types decode as
'                        value = min + raw / scale
'   sweep, tagalong      optional extras; tagalong may hold a MAG column
'                        (standard FITS, big-endian)

Option _Explicit

Const SW = 1280
Const SH = 800
Const PANEL_W = 330
Const STATUS_H = 22
Const MAP_X0 = PANEL_W
Const MAP_W = SW - PANEL_W
Const MAP_H = SH - STATUS_H
Const LINE_H = 16
Const HDU_LIST_Y = 236
Const MAX_ALLSKY_QUADS = 20000

Type HduInfo
    hdrOfs As _Integer64
    dataOfs As _Integer64
    dataLen As _Integer64
    firstCard As Long
    nCards As Long
    rowBytes As Long
    nRows As Long
End Type

ReDim Shared hdu(1 To 16) As HduInfo
ReDim Shared hduName(1 To 16) As String
ReDim Shared cards(1 To 256) As String
Dim Shared nHdu As Long, nCard As Long, truncated As Integer

ReDim Shared starX(1 To 1) As Double
ReDim Shared starY(1 To 1) As Double
ReDim Shared starZ(1 To 1) As Double
ReDim Shared starMag(1 To 1) As Single
ReDim Shared scrX(1 To 1) As Single
ReDim Shared scrY(1 To 1) As Single
ReDim Shared onScr(1 To 1) As _Byte
Dim Shared nStar As Long, hasMag As Integer, magLo As Single, magHi As Single

ReDim Shared quadStar(1 To 1) As Long
Dim Shared nQuad As Long, dimQ As Long

Dim Shared curFile As String, statusMsg As String, kdtType As String
Dim Shared idxId As String, scaleLo As Double, scaleHi As Double
Dim Shared hpText As String

' 0 = all-sky map, 1 = close (gnomonic) map, 2 = header view
Dim Shared viewMode As Integer
Dim Shared mapMode As Integer
Dim Shared cenX As Double, cenY As Double, cenZ As Double
Dim Shared eastX As Double, eastY As Double, eastZ As Double
Dim Shared northX As Double, northY As Double, northZ As Double
Dim Shared zoomS As Double, panX As Double, panY As Double
Dim Shared selHdu As Long, hdrScroll As Long
Dim Shared showQuads As Integer, showGrid As Integer
Dim Shared hoverStar As Long

ReDim Shared viewLines(1 To 1) As String
Dim Shared nViewLines As Long

Screen _NewImage(SW, SH, 32)
_Title "IndexView"
_PrintMode _KeepBackground
showGrid = -1

Dim startFile As String
If _CommandCount >= 1 Then
    startFile = Command$(1)
Else
    startFile = _OpenFileDialog$("Open index file", "", "*.fits|*.fit", "FITS index files")
End If
If Len(startFile) = 0 Then System
LoadIndex startFile

Dim k As String, wheel As Long, mx As Long, my As Long, mb As Integer
Dim lastB As Integer, downX As Long, downY As Long, dragging As Integer
Dim lastX As Long, lastY As Long, quitNow As Integer, picked As String

Do
    wheel = 0
    Do While _MouseInput
        wheel = wheel + _MouseWheel
        mx = _MouseX: my = _MouseY: mb = _MouseButton(1)

        ' ----- mouse: press / drag / release, per event -----
        If mb And Not lastB Then
            downX = mx: downY = my: lastX = mx: lastY = my: dragging = 0
            If mx < PANEL_W Then PanelClick mx, my
        End If
        If mb And lastB Then
            If viewMode = 1 And downX >= MAP_X0 Then
                If Abs(mx - downX) + Abs(my - downY) > 3 Then dragging = -1
                If dragging Then
                    panX = panX + (mx - lastX) / zoomS
                    panY = panY + (my - lastY) / zoomS
                End If
            End If
            lastX = mx: lastY = my
        End If
        If lastB And Not mb Then
            If downX >= MAP_X0 And my < MAP_H Then
                If viewMode = 0 And Not dragging Then
                    AllSkyClick mx, my
                ElseIf viewMode = 1 And dragging Then
                    Recenter
                End If
            End If
            dragging = 0
        End If
        lastB = mb
    Loop
    mx = _MouseX: my = _MouseY

    ' ----- mouse wheel -----
    If wheel <> 0 Then
        If viewMode = 1 And mx >= MAP_X0 Then
            ZoomAt mx, my, wheel
        ElseIf viewMode = 2 Then
            hdrScroll = hdrScroll + wheel * 3
        End If
    End If

    ' ----- keyboard -----
    k = InKey$
    If Len(k) Then
        Select Case UCase$(k)
            Case Chr$(27): quitNow = -1
            Case "M": viewMode = mapMode
            Case "H": viewMode = 2: BuildViewLines
            Case "A": viewMode = 0: mapMode = 0
            Case "Q": showQuads = Not showQuads
            Case "G": showGrid = Not showGrid
            Case "N": StepFile 1
            Case "P": StepFile -1
            Case "O"
                picked = _OpenFileDialog$("Open index file", FolderOf$(curFile), "*.fits|*.fit", "FITS index files")
                If Len(picked) Then LoadIndex picked
            Case Chr$(0) + "H": hdrScroll = hdrScroll - 1
            Case Chr$(0) + "P": hdrScroll = hdrScroll + 1
            Case Chr$(0) + "I": hdrScroll = hdrScroll - 40
            Case Chr$(0) + "Q": hdrScroll = hdrScroll + 40
        End Select
    End If

    ' ----- draw -----
    Line (0, 0)-(SW - 1, SH - 1), _RGB32(0, 0, 0), BF
    If viewMode = 2 Then
        DrawHeaderView
    Else
        DrawMap mx, my
    End If
    DrawPanel
    DrawStatus
    _Display
    _Limit 30
Loop Until quitNow
System


' ======================================================================
' File loading
' ======================================================================

Sub LoadIndex (fileName As String)
    Dim fh As Long
    If Not _FileExists(fileName) Then
        statusMsg = "File not found: " + fileName
        Exit Sub
    End If
    curFile = fileName
    nHdu = 0: nCard = 0: truncated = 0
    nStar = 0: nQuad = 0: dimQ = 0: hasMag = 0
    selHdu = 1: hdrScroll = 0: hoverStar = 0
    statusMsg = ""
    kdtType = "": idxId = "?": scaleLo = 0: scaleHi = 0: hpText = ""

    fh = FreeFile
    Open fileName For Binary As #fh
    ParseHdus fh
    ReadIndexInfo
    ReadStars fh
    ReadMags fh
    ReadQuads fh
    Close #fh

    _Title "IndexView - " + FileOnly$(curFile)
    If truncated Then statusMsg = "File is truncated or damaged - last HDU incomplete"
    If nStar > 0 Then
        FitView
    Else
        viewMode = 2
        mapMode = 0
        If Len(statusMsg) = 0 Then statusMsg = "No star kd-tree found - showing headers"
    End If
    BuildViewLines
End Sub


' Walks the file in 2880-byte FITS blocks, recording each HDU's cards,
' data offset and data length.
Sub ParseHdus (fh As Long)
    Dim p As _Integer64, fileLen As _Integer64, blk As String
    Dim i As Long, c As String, done As Integer, naxis As Long
    Dim dataSize As _Integer64, ax As Long, bpix As Long

    fileLen = LOF(fh)
    p = 0
    blk = Space$(2880)
    Do While p + 2880 <= fileLen
        nHdu = nHdu + 1
        If nHdu > UBound(hdu) Then
            ReDim _Preserve hdu(1 To nHdu + 16) As HduInfo
            ReDim _Preserve hduName(1 To nHdu + 16) As String
        End If
        hdu(nHdu).hdrOfs = p
        hdu(nHdu).firstCard = nCard + 1
        hdu(nHdu).nCards = 0
        done = 0
        Do
            If p + 2880 > fileLen Then truncated = -1: Exit Do
            Get #fh, p + 1, blk
            p = p + 2880
            For i = 0 To 35
                c = Mid$(blk, i * 80 + 1, 80)
                nCard = nCard + 1
                If nCard > UBound(cards) Then ReDim _Preserve cards(1 To nCard + 256) As String
                cards(nCard) = c
                hdu(nHdu).nCards = hdu(nHdu).nCards + 1
                If Left$(c, 3) = "END" And Len(_Trim$(Mid$(c, 4))) = 0 Then
                    done = -1
                    Exit For
                End If
            Next i
        Loop Until done
        If truncated Then
            hdu(nHdu).dataOfs = p
            hdu(nHdu).dataLen = 0
            hduName(nHdu) = "(incomplete)"
            Exit Do
        End If

        naxis = Val(HduKey$(nHdu, "NAXIS"))
        bpix = Abs(Val(HduKey$(nHdu, "BITPIX")))
        If bpix = 0 Then bpix = 8
        If naxis = 0 Then
            dataSize = 0
        Else
            dataSize = 1
            For ax = 1 To naxis
                dataSize = dataSize * Val(HduKey$(nHdu, "NAXIS" + _Trim$(Str$(ax))))
            Next ax
            dataSize = dataSize * bpix \ 8
        End If
        dataSize = dataSize + Val(HduKey$(nHdu, "PCOUNT"))
        hdu(nHdu).dataOfs = p
        hdu(nHdu).dataLen = dataSize
        hdu(nHdu).rowBytes = Val(HduKey$(nHdu, "NAXIS1"))
        hdu(nHdu).nRows = Val(HduKey$(nHdu, "NAXIS2"))

        If nHdu = 1 Then
            hduName(nHdu) = "primary"
        Else
            hduName(nHdu) = HduKey$(nHdu, "EXTNAME")
            If Len(hduName(nHdu)) = 0 Then hduName(nHdu) = HduKey$(nHdu, "TTYPE1")
            If Len(hduName(nHdu)) = 0 Then hduName(nHdu) = "(unnamed)"
        End If

        p = p + ((dataSize + 2879) \ 2880) * 2880
        If p > fileLen Then truncated = -1
    Loop
End Sub


Sub ReadIndexInfo
    Dim hpx As String, nside As String
    idxId = HduKey$(1, "INDEXID")
    If Len(idxId) = 0 Then idxId = "?"
    scaleLo = Val(HduKey$(1, "SCALE_L")) * 180# / _Pi * 60#
    scaleHi = Val(HduKey$(1, "SCALE_U")) * 180# / _Pi * 60#
    hpx = HduKey$(1, "HEALPIX")
    nside = HduKey$(1, "HPNSIDE")
    If HduKey$(1, "ALLSKY") = "T" Or Val(hpx) < 0 Then
        hpText = "all-sky"
    Else
        hpText = "healpix " + hpx + " (nside " + nside + ")"
    End If
End Sub


' Decodes the star kd-tree data into unit vectors.
Sub ReadStars (fh As Long)
    Dim hHdr As Long, hData As Long, hRange As Long
    Dim ndim As Long, ndat As Long, i As Long, j As Long
    Dim rmin(1 To 3) As Double, inv As Double, scl As Double
    Dim vx As Double, vy As Double, vz As Double, nrm As Double
    Dim rr(1 To 7) As Double

    hHdr = FindHdu&("kdtree_header_stars")
    hData = FindHdu&("kdtree_data_stars")
    hRange = FindHdu&("kdtree_range_stars")
    If hHdr = 0 Or hData = 0 Then Exit Sub

    kdtType = LCase$(HduKey$(hHdr, "KDT_DATA"))
    ndim = Val(HduKey$(hHdr, "KDT_NDIM"))
    ndat = Val(HduKey$(hHdr, "KDT_NDAT"))
    If ndim <> 3 Or ndat < 1 Then
        statusMsg = "Star tree is not 3-D unit vectors"
        Exit Sub
    End If
    If hdu(hData).dataLen < ndat * 3 * TypeBytes&(kdtType) Then
        statusMsg = "Star data shorter than expected"
        Exit Sub
    End If

    If kdtType = "u32" Or kdtType = "u16" Then
        If hRange = 0 Then
            statusMsg = "Integer star tree without range table"
            Exit Sub
        End If
        Get #fh, hdu(hRange).dataOfs + 1, rr()
        rmin(1) = rr(1): rmin(2) = rr(2): rmin(3) = rr(3)
        scl = rr(7)
        If scl = 0 Then Exit Sub
        inv = 1# / scl
    End If

    ReDim starX(1 To ndat) As Double
    ReDim starY(1 To ndat) As Double
    ReDim starZ(1 To ndat) As Double
    ReDim starMag(1 To ndat) As Single
    ReDim scrX(1 To ndat) As Single
    ReDim scrY(1 To ndat) As Single
    ReDim onScr(1 To ndat) As _Byte

    Select Case kdtType
        Case "u32"
            ReDim rawL(1 To ndat * 3) As _Unsigned Long
            Get #fh, hdu(hData).dataOfs + 1, rawL()
            For i = 1 To ndat
                j = (i - 1) * 3
                starX(i) = rmin(1) + rawL(j + 1) * inv
                starY(i) = rmin(2) + rawL(j + 2) * inv
                starZ(i) = rmin(3) + rawL(j + 3) * inv
            Next i
        Case "u16"
            ReDim rawI(1 To ndat * 3) As _Unsigned Integer
            Get #fh, hdu(hData).dataOfs + 1, rawI()
            For i = 1 To ndat
                j = (i - 1) * 3
                starX(i) = rmin(1) + rawI(j + 1) * inv
                starY(i) = rmin(2) + rawI(j + 2) * inv
                starZ(i) = rmin(3) + rawI(j + 3) * inv
            Next i
        Case "double"
            ReDim rawD(1 To ndat * 3) As Double
            Get #fh, hdu(hData).dataOfs + 1, rawD()
            For i = 1 To ndat
                j = (i - 1) * 3
                starX(i) = rawD(j + 1): starY(i) = rawD(j + 2): starZ(i) = rawD(j + 3)
            Next i
        Case "float"
            ReDim rawS(1 To ndat * 3) As Single
            Get #fh, hdu(hData).dataOfs + 1, rawS()
            For i = 1 To ndat
                j = (i - 1) * 3
                starX(i) = rawS(j + 1): starY(i) = rawS(j + 2): starZ(i) = rawS(j + 3)
            Next i
        Case Else
            statusMsg = "Unknown star data type: " + kdtType
            Exit Sub
    End Select

    ' re-normalise (integer packing leaves tiny length errors)
    For i = 1 To ndat
        vx = starX(i): vy = starY(i): vz = starZ(i)
        nrm = Sqr(vx * vx + vy * vy + vz * vz)
        If nrm > 0 Then
            starX(i) = vx / nrm: starY(i) = vy / nrm: starZ(i) = vz / nrm
        End If
    Next i
    nStar = ndat
End Sub


' Looks for a MAG column (any case) in a table with one row per star.
Sub ReadMags (fh As Long)
    Dim h As Long, nf As Long, f As Long, colOfs As Long, w As Long
    Dim tf As String, tt As String, found As Integer, colType As String
    Dim blkData As String, i As Long, rb As Long, s As String, m As Single

    If nStar = 0 Then Exit Sub
    For h = 2 To nHdu
        If hdu(h).nRows = nStar And Not found Then
            nf = Val(HduKey$(h, "TFIELDS"))
            colOfs = 0
            For f = 1 To nf
                tf = UCase$(HduKey$(h, "TFORM" + _Trim$(Str$(f))))
                tt = UCase$(HduKey$(h, "TTYPE" + _Trim$(Str$(f))))
                w = FormBytes&(tf)
                If tt = "MAG" And (Right$(tf, 1) = "D" Or Right$(tf, 1) = "E") And Not found Then
                    found = -1
                    colType = Right$(tf, 1)
                    Exit For
                End If
                colOfs = colOfs + w
            Next f
            If found Then
                rb = hdu(h).rowBytes
                blkData = Space$(rb * nStar)
                Get #fh, hdu(h).dataOfs + 1, blkData
                magLo = 999: magHi = -999
                For i = 1 To nStar
                    If colType = "D" Then
                        s = Reverse$(Mid$(blkData, (i - 1) * rb + colOfs + 1, 8))
                        m = CVD(s)
                    Else
                        s = Reverse$(Mid$(blkData, (i - 1) * rb + colOfs + 1, 4))
                        m = CVS(s)
                    End If
                    starMag(i) = m
                    If m < magLo Then magLo = m
                    If m > magHi Then magHi = m
                Next i
                hasMag = -1
                If magHi - magLo < 0.01 Then magHi = magLo + 0.01
            End If
        End If
    Next h
End Sub


Sub ReadQuads (fh As Long)
    Dim h As Long, i As Long
    h = FindHdu&("quads")
    If h = 0 Then Exit Sub
    If hdu(h).rowBytes < 12 Or hdu(h).nRows < 1 Then Exit Sub
    dimQ = hdu(h).rowBytes \ 4
    nQuad = hdu(h).nRows
    If hdu(h).dataLen < nQuad * dimQ * 4 Then nQuad = 0: Exit Sub
    ReDim rawQ(1 To nQuad * dimQ) As _Unsigned Long
    Get #fh, hdu(h).dataOfs + 1, rawQ()
    ReDim quadStar(1 To nQuad * dimQ) As Long
    For i = 1 To nQuad * dimQ
        If rawQ(i) < nStar Then
            quadStar(i) = rawQ(i) + 1
        Else
            quadStar(i) = 0
        End If
    Next i
End Sub


' ======================================================================
' FITS helpers
' ======================================================================

' Value of the first card with this keyword in HDU h ("" if absent).
' String values come back without quotes.
Function HduKey$ (h As Long, kw As String)
    Dim i As Long, c As String, v As String, q As Long
    HduKey$ = ""
    If h < 1 Or h > nHdu Then Exit Function
    For i = hdu(h).firstCard To hdu(h).firstCard + hdu(h).nCards - 1
        c = cards(i)
        If RTrim$(Left$(c, 8)) = kw And Mid$(c, 9, 2) = "= " Then
            v = LTrim$(Mid$(c, 11))
            If Left$(v, 1) = "'" Then
                q = InStr(2, v, "'")
                If q = 0 Then q = Len(v) + 1
                HduKey$ = RTrim$(Mid$(v, 2, q - 2))
            Else
                q = InStr(v, "/")
                If q > 0 Then v = Left$(v, q - 1)
                HduKey$ = _Trim$(v)
            End If
            Exit Function
        End If
    Next i
End Function


Function FindHdu& (nm As String)
    Dim h As Long
    FindHdu& = 0
    For h = 2 To nHdu
        If hduName(h) = nm Then
            FindHdu& = h
            Exit Function
        End If
    Next h
End Function


Function TypeBytes& (t As String)
    Select Case t
        Case "u32", "float": TypeBytes& = 4
        Case "u16": TypeBytes& = 2
        Case "double": TypeBytes& = 8
        Case Else: TypeBytes& = 1
    End Select
End Function


' Bytes taken by a binary-table TFORM such as 1D, 3J, 12A.
Function FormBytes& (tf As String)
    Dim rep As Long, code As String, digits As String, i As Long
    For i = 1 To Len(tf)
        If InStr("0123456789", Mid$(tf, i, 1)) = 0 Then Exit For
        digits = digits + Mid$(tf, i, 1)
    Next i
    code = Mid$(tf, i, 1)
    If Len(digits) = 0 Then rep = 1 Else rep = Val(digits)
    Select Case code
        Case "L", "B", "A": FormBytes& = rep
        Case "I": FormBytes& = rep * 2
        Case "J", "E": FormBytes& = rep * 4
        Case "K", "D", "C": FormBytes& = rep * 8
        Case "M": FormBytes& = rep * 16
        Case Else: FormBytes& = rep
    End Select
End Function


Function Reverse$ (s As String)
    Dim i As Long, r As String
    r = Space$(Len(s))
    For i = 1 To Len(s)
        Mid$(r, Len(s) - i + 1, 1) = Mid$(s, i, 1)
    Next i
    Reverse$ = r
End Function


' ======================================================================
' View geometry
' ======================================================================

' Chooses the starting view: a close view for a sky tile, all-sky otherwise.
Sub FitView
    Dim i As Long, sx As Double, sy As Double, sz As Double, nrm As Double
    Dim maxAng As Double, d As Double
    For i = 1 To nStar
        sx = sx + starX(i): sy = sy + starY(i): sz = sz + starZ(i)
    Next i
    nrm = Sqr(sx * sx + sy * sy + sz * sz) / nStar
    If nrm < 0.5 Then
        viewMode = 0: mapMode = 0
        showQuads = 0
        Exit Sub
    End If
    nrm = nrm * nStar
    SetCenter sx / nrm, sy / nrm, sz / nrm
    maxAng = 0
    For i = 1 To nStar
        d = starX(i) * cenX + starY(i) * cenY + starZ(i) * cenZ
        If d > 1 Then d = 1
        d = _Acos(d)
        If d > maxAng Then maxAng = d
    Next i
    If maxAng > 1.3 Then maxAng = 1.3
    If maxAng < 0.0001 Then maxAng = 0.0001
    zoomS = 0.46 * MAP_H / Tan(maxAng)
    viewMode = 1: mapMode = 1
    showQuads = 0
End Sub


Sub SetCenter (vx As Double, vy As Double, vz As Double)
    Dim raRad As Double, decRad As Double
    cenX = vx: cenY = vy: cenZ = vz
    raRad = _Atan2(vy, vx)
    decRad = _Atan2(vz, Sqr(vx * vx + vy * vy))
    eastX = -Sin(raRad): eastY = Cos(raRad): eastZ = 0
    northX = -Sin(decRad) * Cos(raRad)
    northY = -Sin(decRad) * Sin(raRad)
    northZ = Cos(decRad)
    panX = 0: panY = 0
End Sub


' Folds the current pan back into the projection centre.
Sub Recenter
    Dim vx As Double, vy As Double, vz As Double, nrm As Double
    vx = cenX + panX * eastX + panY * northX
    vy = cenY + panX * eastY + panY * northY
    vz = cenZ + panX * eastZ + panY * northZ
    nrm = Sqr(vx * vx + vy * vy + vz * vz)
    SetCenter vx / nrm, vy / nrm, vz / nrm
End Sub


Sub ZoomAt (mx As Long, my As Long, wheel As Long)
    Dim f As Double, tx As Double, ty As Double, mcx As Double, mcy As Double
    mcx = MAP_X0 + MAP_W / 2: mcy = MAP_H / 2
    tx = panX - (mx - mcx) / zoomS
    ty = panY - (my - mcy) / zoomS
    If wheel < 0 Then f = 1.25 ^ (-wheel) Else f = 0.8 ^ wheel
    zoomS = zoomS * f
    If zoomS < 200 Then zoomS = 200
    If zoomS > 50000000 Then zoomS = 50000000
    panX = tx + (mx - mcx) / zoomS
    panY = ty + (my - mcy) / zoomS
End Sub


' Projects a unit vector to the screen for the current map.
' Returns 0 when the point is behind the view or outside the map.
Function Project% (vx As Double, vy As Double, vz As Double, sx As Single, sy As Single)
    Dim d As Double, tx As Double, ty As Double
    Dim lon As Double, lat As Double, den As Double, hx As Double, hy As Double, sc As Double
    Project% = 0
    If mapMode = 1 Then
        d = vx * cenX + vy * cenY + vz * cenZ
        If d <= 0.01 Then Exit Function
        tx = (vx * eastX + vy * eastY + vz * eastZ) / d
        ty = (vx * northX + vy * northY + vz * northZ) / d
        sx = MAP_X0 + MAP_W / 2 - (tx - panX) * zoomS
        sy = MAP_H / 2 - (ty - panY) * zoomS
    Else
        lon = _Atan2(vy, vx)
        lat = _Atan2(vz, Sqr(vx * vx + vy * vy))
        den = Sqr(1 + Cos(lat) * Cos(lon / 2))
        hx = 2 * Sqr(2) * Cos(lat) * Sin(lon / 2) / den
        hy = Sqr(2) * Sin(lat) / den
        sc = AllSkyScale#
        sx = MAP_X0 + MAP_W / 2 - hx * sc
        sy = MAP_H / 2 - hy * sc
    End If
    If sx < MAP_X0 Or sx >= SW Or sy < 0 Or sy >= MAP_H Then Exit Function
    Project% = -1
End Function


Function AllSkyScale#
    Dim a As Double, b As Double
    a = (MAP_W - 20) / (4 * Sqr(2))
    b = (MAP_H - 20) / (2 * Sqr(2))
    If a < b Then AllSkyScale# = a Else AllSkyScale# = b
End Function


' Click on the all-sky map: zoom into that spot.
Sub AllSkyClick (mx As Long, my As Long)
    Dim hx As Double, hy As Double, zz As Double, lon As Double, lat As Double
    Dim sc As Double
    sc = AllSkyScale#
    hx = -(mx - (MAP_X0 + MAP_W / 2)) / sc
    hy = -(my - MAP_H / 2) / sc
    If (hx / (2 * Sqr(2))) ^ 2 + (hy / Sqr(2)) ^ 2 > 1 Then Exit Sub
    zz = Sqr(1 - (hx / 4) ^ 2 - (hy / 2) ^ 2)
    lon = 2 * _Atan2(zz * hx, 2 * (2 * zz * zz - 1))
    lat = _Asin(zz * hy)
    SetCenter Cos(lat) * Cos(lon), Cos(lat) * Sin(lon), Sin(lat)
    zoomS = 0.5 * MAP_H / Tan(0.26)
    viewMode = 1: mapMode = 1
End Sub


' ======================================================================
' Drawing
' ======================================================================

Sub DrawMap (mx As Long, my As Long)
    Dim i As Long, sx As Single, sy As Single, r As Long, t As Single, c As _Unsigned Long
    Dim best As Single, d As Single, lv As Long

    _Dest 0
    If showGrid Then DrawGrid

    For i = 1 To nStar
        onScr(i) = Project%(starX(i), starY(i), starZ(i), sx, sy)
        scrX(i) = sx: scrY(i) = sy
    Next i

    hoverStar = 0: best = 64
    For i = 1 To nStar
        If onScr(i) Then
            If hasMag Then
                t = (magHi - starMag(i)) / (magHi - magLo)
                r = Int(t * t * 2.4 + 0.15)
                lv = 70 + Int(185 * t)
            Else
                r = 1: lv = 220
            End If
            If mapMode = 0 And r > 1 Then r = 1
            c = _RGB32(lv, lv, lv * 0.9 + 25)
            Dot scrX(i), scrY(i), r, c
            If mx >= MAP_X0 And my < MAP_H Then
                d = (scrX(i) - mx) ^ 2 + (scrY(i) - my) ^ 2
                If d < best Then best = d: hoverStar = i
            End If
        End If
    Next i

    If showQuads And nQuad > 0 Then DrawQuads

    If hoverStar Then
        Circle (scrX(hoverStar), scrY(hoverStar)), 6, _RGB32(255, 200, 0)
    End If
End Sub


Sub Dot (x As Single, y As Single, r As Long, c As _Unsigned Long)
    Dim dy As Long, w As Long
    If r <= 0 Then
        PSet (x, y), c
        Exit Sub
    End If
    For dy = -r To r
        w = Int(Sqr(r * r - dy * dy) + 0.5)
        Line (x - w, y + dy)-(x + w, y + dy), c
    Next dy
End Sub


Sub DrawQuads
    Dim q As Long, a As Long, b As Long, sa As Long, sb As Long
    Dim stepQ As Long, qBase As Long, anyOn As Integer, c As _Unsigned Long
    c = _RGB32(0, 200, 230)
    stepQ = 1
    If mapMode = 0 And nQuad > MAX_ALLSKY_QUADS Then stepQ = nQuad \ MAX_ALLSKY_QUADS
    For q = 1 To nQuad Step stepQ
        qBase = (q - 1) * dimQ
        anyOn = 0
        For a = 1 To dimQ
            sa = quadStar(qBase + a)
            If sa > 0 Then
                If onScr(sa) Then anyOn = -1
            End If
        Next a
        If anyOn Then
            For a = 1 To dimQ - 1
                For b = a + 1 To dimQ
                    sa = quadStar(qBase + a): sb = quadStar(qBase + b)
                    If sa > 0 And sb > 0 Then
                        If onScr(sa) And onScr(sb) Then
                            If Abs(scrX(sa) - scrX(sb)) < MAP_W / 2 Then
                                Line (scrX(sa), scrY(sa))-(scrX(sb), scrY(sb)), c
                            End If
                        End If
                    End If
                Next b
            Next a
        End If
    Next q
End Sub


' RA/Dec grid: sampled meridians and parallels.
Sub DrawGrid
    Dim stepDeg As Double, fovDeg As Double, raD As Double, decD As Double
    Dim t As Double, sampleDeg As Double, c As _Unsigned Long
    Dim raStart As Double, raEnd As Double, decStart As Double, decEnd As Double
    c = _RGB32(35, 45, 70)
    If mapMode = 0 Then
        stepDeg = 30
        raStart = 0: raEnd = 360: decStart = -90: decEnd = 90
        sampleDeg = 2
    Else
        fovDeg = (MAP_W / zoomS) * 180 / _Pi
        stepDeg = NiceStep#(fovDeg / 6)
        raStart = 0: raEnd = 360: decStart = -90: decEnd = 90
        sampleDeg = stepDeg / 10
        If fovDeg < 60 Then
            ' limit the grid to the neighbourhood of the view centre
            decD = _Asin(cenZ) * 180 / _Pi
            raD = _Atan2(cenY, cenX) * 180 / _Pi
            decStart = Int((decD - fovDeg) / stepDeg) * stepDeg
            decEnd = decD + fovDeg
            If decStart < -90 Then decStart = -90
            If decEnd > 90 Then decEnd = 90
            If Abs(decD) + fovDeg < 85 Then
                t = fovDeg / Cos(decD * _Pi / 180)
                raStart = Int((raD - t) / stepDeg) * stepDeg
                raEnd = raD + t
            End If
        End If
    End If

    ' meridians (constant RA)
    For raD = raStart To raEnd Step stepDeg
        GridCurve raD, decStart, raD, decEnd, sampleDeg, c
    Next raD
    ' parallels (constant Dec)
    For decD = Int(decStart / stepDeg) * stepDeg To decEnd Step stepDeg
        If Abs(decD) < 89.999 Then GridCurve raStart, decD, raEnd, decD, sampleDeg, c
    Next decD
    If mapMode = 0 Then
        ' outline of the all-sky ellipse
        GridCurve 179.999, -90, 179.999, 90, 1, _RGB32(60, 70, 100)
        GridCurve -179.999, -90, -179.999, 90, 1, _RGB32(60, 70, 100)
    End If
End Sub


Sub GridCurve (ra1 As Double, de1 As Double, ra2 As Double, de2 As Double, sampleDeg As Double, c As _Unsigned Long)
    Dim n As Long, i As Long, f As Double, ra As Double, de As Double
    Dim vx As Double, vy As Double, vz As Double, sx As Single, sy As Single
    Dim px As Single, py As Single, havePrev As Integer, ok As Integer
    n = Abs(ra2 - ra1)
    If Abs(de2 - de1) > n Then n = Abs(de2 - de1)
    n = Int(n / sampleDeg) + 1
    If n > 2000 Then n = 2000
    For i = 0 To n
        f = i / n
        ra = (ra1 + (ra2 - ra1) * f) * _Pi / 180
        de = (de1 + (de2 - de1) * f) * _Pi / 180
        vx = Cos(de) * Cos(ra): vy = Cos(de) * Sin(ra): vz = Sin(de)
        ok = Project%(vx, vy, vz, sx, sy)
        If ok And havePrev Then
            If Abs(sx - px) < MAP_W / 3 Then Line (px, py)-(sx, sy), c
        End If
        havePrev = ok: px = sx: py = sy
    Next i
End Sub


Function NiceStep# (target As Double)
    Dim i As Long, s As Double
    Dim steps(1 To 13) As Double
    steps(1) = 30: steps(2) = 15: steps(3) = 10: steps(4) = 5: steps(5) = 2
    steps(6) = 1: steps(7) = 0.5: steps(8) = 0.25: steps(9) = 0.1
    steps(10) = 0.05: steps(11) = 0.02: steps(12) = 0.01: steps(13) = 0.005
    s = 30
    For i = 1 To 13
        If steps(i) >= target Then s = steps(i)
    Next i
    NiceStep# = s
End Function


Sub DrawPanel
    Dim y As Long, h As Long, s As String, rowY As Long, maxRows As Long
    Line (0, 0)-(PANEL_W - 1, SH - 1), _RGB32(18, 20, 28), BF
    Line (PANEL_W - 1, 0)-(PANEL_W - 1, SH - 1), _RGB32(60, 64, 80)

    Color _RGB32(255, 210, 120)
    _PrintString (8, 6), Left$(FileOnly$(curFile), 39)
    Color _RGB32(200, 200, 210)
    y = 30
    _PrintString (8, y), "Index ID   " + idxId: y = y + LINE_H
    _PrintString (8, y), "Quad size  " + Fmt$(scaleLo, 1) + " - " + Fmt$(scaleHi, 1) + " arcmin": y = y + LINE_H
    _PrintString (8, y), "Sky        " + hpText: y = y + LINE_H
    _PrintString (8, y), "Stars      " + _Trim$(Str$(nStar)) + "  (" + kdtType + ")": y = y + LINE_H
    _PrintString (8, y), "Quads      " + _Trim$(Str$(nQuad)) + "  x" + _Trim$(Str$(dimQ)) + " stars": y = y + LINE_H
    If hasMag Then
        s = "Mag        " + Fmt$(magLo, 2) + " to " + Fmt$(magHi, 2)
    Else
        s = "Mag        (none stored)"
    End If
    _PrintString (8, y), s: y = y + LINE_H
    _PrintString (8, y), "File size  " + _Trim$(Str$(FileBytes&&)) + " bytes": y = y + LINE_H
    y = y + 8
    Color _RGB32(120, 180, 255)
    _PrintString (8, y), "View: " + ViewName$: y = y + LINE_H
    _PrintString (8, y), "Quads " + OnOff$(showQuads) + "   Grid " + OnOff$(showGrid)

    Color _RGB32(255, 210, 120)
    _PrintString (8, HDU_LIST_Y - LINE_H - 4), "HDUs (click for header)"
    maxRows = (SH - 150 - HDU_LIST_Y) \ LINE_H
    For h = 1 To nHdu
        If h > maxRows Then Exit For
        rowY = HDU_LIST_Y + (h - 1) * LINE_H
        If h = selHdu Then Line (2, rowY - 1)-(PANEL_W - 3, rowY + LINE_H - 2), _RGB32(40, 50, 90), BF
        If hduName(h) = "(incomplete)" Then Color _RGB32(255, 90, 90) Else Color _RGB32(210, 210, 220)
        s = Right$(" " + _Trim$(Str$(h - 1)), 2) + " " + Left$(hduName(h) + Space$(22), 22)
        s = s + Right$(Space$(10) + RowText$(h), 10)
        _PrintString (6, rowY), s
    Next h

    Color _RGB32(130, 130, 150)
    y = SH - 136
    _PrintString (8, y), "M map  H header  A all-sky": y = y + LINE_H
    _PrintString (8, y), "Q quads  G grid": y = y + LINE_H
    _PrintString (8, y), "N/P next/prev file  O open": y = y + LINE_H
    _PrintString (8, y), "Wheel zoom  Drag pan": y = y + LINE_H
    _PrintString (8, y), "Click all-sky to zoom in": y = y + LINE_H
    _PrintString (8, y), "Esc quit"
End Sub


Function RowText$ (h As Long)
    If h = 1 Or hdu(h).nRows = 0 Then
        RowText$ = _Trim$(Str$(hdu(h).dataLen)) + "B"
    Else
        RowText$ = _Trim$(Str$(hdu(h).nRows)) + "x" + _Trim$(Str$(hdu(h).rowBytes))
    End If
End Function


Sub PanelClick (mx As Long, my As Long)
    Dim h As Long
    If my < HDU_LIST_Y Then Exit Sub
    h = (my - HDU_LIST_Y) \ LINE_H + 1
    If h >= 1 And h <= nHdu Then
        selHdu = h
        hdrScroll = 0
        viewMode = 2
        BuildViewLines
    End If
End Sub


Sub DrawStatus
    Dim s As String, raD As Double, decD As Double
    Line (MAP_X0, SH - STATUS_H)-(SW - 1, SH - 1), _RGB32(18, 20, 28), BF
    If Len(statusMsg) Then
        Color _RGB32(255, 110, 110)
        _PrintString (MAP_X0 + 8, SH - STATUS_H + 3), Left$(statusMsg, 115)
        Exit Sub
    End If
    Color _RGB32(200, 200, 210)
    If viewMode <> 2 And hoverStar > 0 Then
        raD = _Atan2(starY(hoverStar), starX(hoverStar)) * 180 / _Pi
        If raD < 0 Then raD = raD + 360
        decD = _Asin(starZ(hoverStar)) * 180 / _Pi
        s = "Star #" + _Trim$(Str$(hoverStar - 1)) + "   RA " + RaText$(raD) + "   Dec " + DecText$(decD)
        s = s + "   (" + Fmt$(raD, 5) + ", " + Fmt$(decD, 5) + ")"
        If hasMag Then s = s + "   mag " + Fmt$(starMag(hoverStar), 2)
    ElseIf viewMode = 1 Then
        raD = _Atan2(cenY + panX * eastY + panY * northY, cenX + panX * eastX + panY * northX) * 180 / _Pi
        If raD < 0 Then raD = raD + 360
        decD = _Asin(_Clamp(cenZ + panX * eastZ + panY * northZ, -1, 1)) * 180 / _Pi
        s = "Centre RA " + RaText$(raD) + "  Dec " + DecText$(decD)
        s = s + "   Field width " + Fmt$(2 * Atn(MAP_W / 2 / zoomS) * 180 / _Pi, 3) + " deg"
    ElseIf viewMode = 2 Then
        s = "HDU " + _Trim$(Str$(selHdu - 1)) + "  " + hduName(selHdu) + "   header at byte " + _Trim$(Str$(hdu(selHdu).hdrOfs))
        s = s + ", data at byte " + _Trim$(Str$(hdu(selHdu).dataOfs)) + ", " + _Trim$(Str$(hdu(selHdu).dataLen)) + " data bytes"
    Else
        s = "All-sky Hammer-Aitoff map, RA 0h at centre, east to the left"
    End If
    _PrintString (MAP_X0 + 8, SH - STATUS_H + 3), Left$(s, 115)
End Sub


' Header cards plus a hex dump of the first 512 data bytes of selHdu.
Sub BuildViewLines
    Dim i As Long, c As String, n As Long, fh As Long, peekLen As Long
    Dim buf As String, j As Long, hexPart As String, txt As String, b As Long
    n = 0
    ReDim viewLines(1 To hdu(selHdu).nCards + 48) As String
    For i = hdu(selHdu).firstCard To hdu(selHdu).firstCard + hdu(selHdu).nCards - 1
        c = cards(i)
        If Len(_Trim$(c)) Then
            n = n + 1
            viewLines(n) = c
        End If
    Next i
    n = n + 1: viewLines(n) = ""
    peekLen = hdu(selHdu).dataLen
    If peekLen > 512 Then peekLen = 512
    If peekLen > 0 And Len(curFile) Then
        n = n + 1: viewLines(n) = "Data, first " + _Trim$(Str$(peekLen)) + " of " + _Trim$(Str$(hdu(selHdu).dataLen)) + " bytes:"
        fh = FreeFile
        Open curFile For Binary As #fh
        If hdu(selHdu).dataOfs + peekLen <= LOF(fh) Then
            buf = Space$(peekLen)
            Get #fh, hdu(selHdu).dataOfs + 1, buf
        End If
        Close #fh
        For i = 0 To Len(buf) - 1 Step 16
            hexPart = "": txt = ""
            For j = 1 To 16
                If i + j <= Len(buf) Then
                    b = Asc(buf, i + j)
                    hexPart = hexPart + Right$("0" + Hex$(b), 2) + " "
                    If b >= 32 And b < 127 Then txt = txt + Chr$(b) Else txt = txt + "."
                Else
                    hexPart = hexPart + "   "
                End If
            Next j
            n = n + 1
            viewLines(n) = Right$("0000" + Hex$(i), 4) + "  " + hexPart + " " + txt
        Next i
    Else
        n = n + 1: viewLines(n) = "(no data in this HDU)"
    End If
    nViewLines = n
End Sub


Sub DrawHeaderView
    Dim rows As Long, i As Long, y As Long, ln As String
    rows = (MAP_H - 16) \ LINE_H
    If hdrScroll > nViewLines - rows Then hdrScroll = nViewLines - rows
    If hdrScroll < 0 Then hdrScroll = 0
    y = 8
    For i = hdrScroll + 1 To nViewLines
        If y + LINE_H > MAP_H Then Exit For
        ln = viewLines(i)
        Select Case Left$(ln, 7)
            Case "HISTORY", "COMMENT": Color _RGB32(110, 120, 140)
            Case Else
                If Mid$(ln, 9, 2) = "= " Then
                    Color _RGB32(120, 200, 255)
                    _PrintString (MAP_X0 + 12, y), Left$(ln, 8)
                    Color _RGB32(230, 230, 235)
                    _PrintString (MAP_X0 + 12 + 64, y), Mid$(ln, 9, 72)
                    y = y + LINE_H
                    _Continue
                End If
                Color _RGB32(230, 230, 235)
        End Select
        _PrintString (MAP_X0 + 12, y), Left$(ln, 118)
        y = y + LINE_H
    Next i
End Sub


' ======================================================================
' Small helpers
' ======================================================================

Sub StepFile (dirn As Long)
    Dim folder As String, f As String, n As Long, i As Long, cur As Long
    Dim tmp As String, j As Long, lc As String
    ReDim fl(1 To 64) As String
    folder = FolderOf$(curFile)
    If Len(folder) Then f = _Files$(folder + "*") Else f = _Files$("*")
    Do While Len(f)
        lc = LCase$(f)
        If Right$(lc, 5) = ".fits" Or Right$(lc, 4) = ".fit" Then
            n = n + 1
            If n > UBound(fl) Then ReDim _Preserve fl(1 To n + 64) As String
            fl(n) = f
        End If
        f = _Files$
    Loop
    If n = 0 Then Exit Sub
    For i = 2 To n
        tmp = fl(i): j = i - 1
        Do While j >= 1
            If fl(j) <= tmp Then Exit Do
            fl(j + 1) = fl(j): j = j - 1
        Loop
        fl(j + 1) = tmp
    Next i
    cur = 0
    For i = 1 To n
        If fl(i) = FileOnly$(curFile) Then cur = i
    Next i
    cur = cur + dirn
    If cur < 1 Then cur = n
    If cur > n Then cur = 1
    LoadIndex folder + fl(cur)
End Sub


Function FolderOf$ (p As String)
    Dim i As Long
    FolderOf$ = ""
    For i = Len(p) To 1 Step -1
        If Mid$(p, i, 1) = "/" Or Mid$(p, i, 1) = "\" Then
            FolderOf$ = Left$(p, i)
            Exit Function
        End If
    Next i
End Function


Function FileOnly$ (p As String)
    FileOnly$ = Mid$(p, Len(FolderOf$(p)) + 1)
End Function


Function FileBytes&&
    Dim fh As Long
    FileBytes&& = 0
    If Len(curFile) = 0 Then Exit Function
    If Not _FileExists(curFile) Then Exit Function
    fh = FreeFile
    Open curFile For Binary As #fh
    FileBytes&& = LOF(fh)
    Close #fh
End Function


Function ViewName$
    Select Case viewMode
        Case 0: ViewName$ = "all-sky map"
        Case 1: ViewName$ = "close map (gnomonic)"
        Case Else: ViewName$ = "header / hex"
    End Select
End Function


Function OnOff$ (flag As Integer)
    If flag Then OnOff$ = "on" Else OnOff$ = "off"
End Function


Function Fmt$ (v As Double, places As Long)
    Dim s As String, neg As Integer, ip As _Integer64, fp As _Integer64, m As _Integer64
    m = 10 ^ places
    neg = (v < 0)
    fp = _Round(Abs(v) * m)
    ip = fp \ m
    fp = fp - ip * m
    s = _Trim$(Str$(ip))
    If places > 0 Then s = s + "." + Right$(String$(places, "0") + _Trim$(Str$(fp)), places)
    If neg Then s = "-" + s
    Fmt$ = s
End Function


Function RaText$ (raDeg As Double)
    Dim tsec As Double, hh As Long, mm As Long, ss As Double
    tsec = raDeg / 15 * 3600
    hh = Int(tsec / 3600): tsec = tsec - hh * 3600
    mm = Int(tsec / 60): ss = tsec - mm * 60
    RaText$ = Right$("0" + _Trim$(Str$(hh)), 2) + "h" + Right$("0" + _Trim$(Str$(mm)), 2) + "m" + Right$("0" + Fmt$(ss, 1), 4) + "s"
End Function


Function DecText$ (decDeg As Double)
    Dim a As Double, dd As Long, mm As Long, ss As Double, signTxt As String
    If decDeg < 0 Then signTxt = "-" Else signTxt = "+"
    a = Abs(decDeg) * 3600
    dd = Int(a / 3600): a = a - dd * 3600
    mm = Int(a / 60): ss = a - mm * 60
    DecText$ = signTxt + Right$("0" + _Trim$(Str$(dd)), 2) + Chr$(248) + Right$("0" + _Trim$(Str$(mm)), 2) + "'" + Right$("0" + Fmt$(ss, 0), 2) + Chr$(34)
End Function

