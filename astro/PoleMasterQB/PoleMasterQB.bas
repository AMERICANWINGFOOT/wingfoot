'==================================================================
'  PoleMasterQB.bas  -  QHY PoleMaster polar alignment for Linux
'  v1.0  -  QB64-PE 4.6  +  libpmcam.so (C camera / star core)
'
'  Works like QHY's Windows PoleMaster program:
'    1. Region (north / south), exposure, gain, site
'    2. Double-click the pole star (Polaris / Sigma Octantis) - the star
'       pattern overlay is matched automatically (rotate it by hand if needed)
'    0. Start with the mount at HOME (counterweight down, scope at pole)
'    3. Find the RA axis: double-click a bright star, turn the mount in RA
'       with the hand controller, double-click it again (three positions),
'       then slew back to HOME
'    4. Rough alignment: put the pole star in the small green circle with
'       the altitude / azimuth knobs
'    5. Precise alignment: two stars are tracked in green boxes; bring the
'       red circle (true pole) onto the green circle (mount axis)
'    6. Leave the mount at HOME and do the SynScan star alignment
'
'  Needs next to the compiled program:
'    libpmcam.so   (sh build_pmcam.sh)
'    libqhyccd.so  (QHY SDK, for the real PoleMaster - the Simulator does
'                   not need it)
'
'  The Simulator (Connect menu) fakes a PoleMaster on a misaligned mount,
'  so the whole procedure can be practised in daylight.
'
'  Command line:  --selftest [south]   runs the procedure on the simulator
'                 by itself, prints the results and saves selftest.png
'
'  Keys: Left/Right = rotate overlay (Shift = bigger steps)
'        M = mirror overlay   Z = zoom   Esc = close menu / cancel edit
'==================================================================
Option _Explicit
$Console
_Title "PoleMasterQB"

'ButtonUI declarations (mouse + immediate-mode buttons)
'$Include:'ButtonUI.bi'

Declare Dynamic Library "pmcam"
    Function pm_version& ()
    Function pm_open& ()
    Function pm_open_sim& (ByVal w As Long, ByVal h As Long)
    Sub pm_close ()
    Function pm_is_open& ()
    Function pm_set& (ByVal expMs As Long, ByVal gain As Long)
    Function pm_info& (ByVal nameBuf As _Offset, ByVal blen As Long, w As Long, h As Long, frames As Long, sat As Long, errs As Long)
    Function pm_last_error& (ByVal buf As _Offset, ByVal blen As Long)
    Function pm_utc# ()
    Function pm_preview& (ByVal bgra As _Offset, ByVal imgW As Long, ByVal imgH As Long, ByVal dx As Long, ByVal dy As Long, ByVal dw As Long, ByVal dh As Long, ByVal sx As Long, ByVal sy As Long, ByVal sw As Long, ByVal sh As Long, ByVal force As Long, ByVal stretch As Long)
    Function pm_find_stars& (ByVal xs As _Offset, ByVal ys As _Offset, ByVal fl As _Offset, ByVal maxN As Long, sq As Long)
    Function pm_centroid& (ByVal x0 As Double, ByVal y0 As Double, ByVal r As Long, x As Double, y As Double, fl As Double)
    Function pm_sim_stars& (ByVal xs As _Offset, ByVal ys As _Offset, ByVal mg As _Offset, ByVal n As Long)
End Declare

'---------------- constants ----------------
Const D2R = 0.017453292519943295#
Const R2D = 57.29577951308232#
Const RAD2AS = 206264.80624709636#
Const PI2 = 6.283185307179586#
Const NOMINAL_ASPX = 30.9#          ' PoleMaster: about 11 deg across 1280 pixels
Const MAXDET = 120
Const MAXCAT = 300
Const PANEL_W = 300
Const MENU_H = 22
Const STAT_H = 22
Const EXP_LIST = "50|100|200|300|500|700|1000|1500|2000|3000|5000"

'---------------- colours (dark grey + orange, like the Windows app) ----------------
Dim Shared C_BG As _Unsigned Long, C_PANEL As _Unsigned Long, C_HEAD As _Unsigned Long
Dim Shared C_HEADON As _Unsigned Long, C_TEXT As _Unsigned Long, C_DIM As _Unsigned Long
Dim Shared C_ACC As _Unsigned Long, C_RED As _Unsigned Long, C_GREEN As _Unsigned Long
Dim Shared C_YEL As _Unsigned Long, C_BLUE As _Unsigned Long, C_MENU As _Unsigned Long

'---------------- window layout ----------------
Dim Shared SCR_W As Long, SCR_H As Long, IMG_X As Long, IMG_Y As Long, IMG_W As Long, IMG_H As Long
Dim Shared exeDir$, iniFile$, selfTest As Long, selfSouth As Long

'---------------- camera ----------------
Dim Shared camMode As Long, camName$, frW As Long, frH As Long, frames As Long, satFlag As Long, camErrs As Long
Dim Shared frameImg As Long, frameMem As _MEM, lastSeen As Long, newFrame As Long
Dim Shared expMs As Long, gainV As Long

'---------------- view ----------------
Dim Shared zoomF As Long, zoomCX As Double, zoomCY As Double
Dim Shared vSc As Double, vOX As Double, vOY As Double, vX0 As Double, vY0 As Double

'---------------- site / options ----------------
Dim Shared hemi As Long, latDeg As Double, lonDeg As Double, refrOn As Long, siteName$, httpStatus As Long

'---------------- catalogue ----------------
Dim Shared catN As Long
Dim Shared catRA(1 To MAXCAT) As Double, catDec(1 To MAXCAT) As Double
Dim Shared catPmA(1 To MAXCAT) As Double, catPmD(1 To MAXCAT) As Double, catMag(1 To MAXCAT) As Double
Dim Shared catVX(1 To MAXCAT) As Double, catVY(1 To MAXCAT) As Double, catVZ(1 To MAXCAT) As Double
Dim Shared catXi(1 To MAXCAT) As Double, catEta(1 To MAXCAT) As Double
Dim Shared jdCat As Double, poleName$
Dim Shared tpX As Double, tpY As Double, tpZ As Double       ' pole star (tangent point)
Dim Shared teX As Double, teY As Double, teZ As Double       ' east unit vector there
Dim Shared tnX As Double, tnY As Double, tnZ As Double       ' north unit vector there
Dim Shared poleXi As Double, poleEta As Double

'---------------- star pattern model (tangent plane -> frame pixels) ----------------
'  x = a*(f*xi) - b*eta + tx      y = b*(f*xi) + a*eta + ty
Dim Shared mA As Double, mB As Double, mTX As Double, mTY As Double, mF As Long, modelOK As Long
Dim Shared mMatched As Long, mScaleAS As Double
Dim Shared N0X As Double, N0Y As Double, P0X As Double, P0Y As Double
Dim Shared upX As Double, upY As Double, eastX As Double, eastY As Double

'---------------- detected stars ----------------
Dim Shared detN As Long, detSeq As Long
Dim Shared detX(0 To MAXDET - 1) As Single, detY(0 To MAXDET - 1) As Single, detF(0 To MAXDET - 1) As Single

'---------------- procedure state ----------------
' stage: 0 not connected, 1 settings, 2 confirm pole star, 3 RA axis, 4 rough, 5 precise
Dim Shared stage As Long, subStep As Long
Dim Shared raN As Long, raPX(1 To 3) As Double, raPY(1 To 3) As Double
Dim Shared raDN(1 To 3) As Long, raDX(1 To 3, 0 To MAXDET - 1) As Double, raDY(1 To 3, 0 To MAXDET - 1) As Double
Dim Shared raCX As Double, raCY As Double, raR As Double, raOK As Long, raPairs As Long, raSpan As Double
Dim Shared trkPX As Double, trkPY As Double, trkQX As Double, trkQY As Double, trkOn As Long, trkLost As Long
Dim Shared monPX As Double, monPY As Double, monQX As Double, monQY As Double, monNX As Double, monNY As Double
Dim Shared curNX As Double, curNY As Double, curUpX As Double, curUpY As Double, curEaX As Double, curEaY As Double
Dim Shared errAlt As Double, errAz As Double, errTot As Double, errOK As Long, doneFlag As Long
Dim Shared statusMsg$, helpOn As Long
Dim Shared logFile$, lastLogged$, logStage As Long, logErrT As Double ' PoleMasterQB.log

'---------------- input ----------------
Dim Shared wheelAcc As Long, lastClickT As Double, lastClickX As Long, lastClickY As Long
Dim Shared dblClick As Long, dblX As Long, dblY As Long
Dim Shared menuOpen As Long, editField As Long, editBuf$

'---------------- simulator (truth model) ----------------
Dim Shared simAX As Double, simAY As Double, simAZ As Double      ' mount RA axis
Dim Shared simBX As Double, simBY As Double, simBZ As Double      ' camera boresight
Dim Shared simUX As Double, simUY As Double, simUZ As Double      ' camera x axis
Dim Shared simVX As Double, simVY As Double, simVZ As Double      ' camera y axis
Dim Shared simScale As Double, simPar As Long, simJD As Double, simDirty As Long
Dim Shared simX(0 To MAXCAT) As Single, simY(0 To MAXCAT) As Single, simM(0 To MAXCAT) As Single

'==================================================================
'  MAIN
'==================================================================
C_BG = _RGB32(38, 38, 41): C_PANEL = _RGB32(52, 52, 56): C_HEAD = _RGB32(66, 66, 71)
C_HEADON = _RGB32(92, 78, 52): C_TEXT = _RGB32(222, 222, 222): C_DIM = _RGB32(140, 140, 146)
C_ACC = _RGB32(255, 168, 40): C_RED = _RGB32(255, 60, 50): C_GREEN = _RGB32(60, 230, 90)
C_YEL = _RGB32(250, 230, 90): C_BLUE = _RGB32(110, 180, 255): C_MENU = _RGB32(30, 30, 33)

If InStr(LCase$(Command$), "--selftest") Then selfTest = -1
If InStr(LCase$(Command$), "south") Then selfSouth = -1

exeDir$ = Command$(0)
If InStr(exeDir$, "/") > 0 Then exeDir$ = Left$(exeDir$, _InStrRev(exeDir$, "/")) Else exeDir$ = ""
If Left$(exeDir$, 2) = "./" Then exeDir$ = Mid$(exeDir$, 3)
If Left$(exeDir$, 1) <> "/" Then
    If Right$(_StartDir$, 1) = "/" Then exeDir$ = _StartDir$ + exeDir$ Else exeDir$ = _StartDir$ + "/" + exeDir$
End If
iniFile$ = exeDir$ + "PoleMasterQB.ini"

'--- fit the window to the desktop (taskbar + title bar need ~90 px)
SCR_H = _DesktopHeight - 90
If SCR_H > 820 Then SCR_H = 820
If SCR_H < 560 Then SCR_H = 560
SCR_W = _DesktopWidth - 40
If SCR_W > 1260 Then SCR_W = 1260
If SCR_W < 900 Then SCR_W = 900
If selfTest Then SCR_W = 1200: SCR_H = 700
IMG_X = PANEL_W: IMG_Y = MENU_H: IMG_W = SCR_W - PANEL_W: IMG_H = SCR_H - MENU_H - STAT_H

Screen _NewImage(SCR_W, SCR_H, 32)
_ScreenMove 10, 10
_PrintMode _KeepBackground
MouseInit
uiFace = _RGB32(78, 78, 84): uiFaceHover = _RGB32(98, 98, 106): uiFaceDown = _RGB32(60, 60, 64)
uiText = _RGB32(230, 230, 230): uiLight = _RGB32(120, 120, 128): uiDark = _RGB32(30, 30, 32)
uiDisFace = _RGB32(62, 62, 66): uiDisText = _RGB32(110, 110, 116)

' defaults (Kitt Peak, AZ), then the saved settings
hemi = 1: latDeg = 31.958: lonDeg = -111.6: refrOn = 0: expMs = 1000: gainV = 40: siteName$ = "Kitt Peak, AZ (default)"
LoadSettings
If selfTest Then
    If selfSouth Then hemi = -1: latDeg = -31.27: lonDeg = 149.06 Else hemi = 1: latDeg = 31.958: lonDeg = -111.6
End If
LoadCatalog
zoomF = 1
statusMsg$ = "Connect the PoleMaster (Connect menu), or try the Simulator."

If selfTest Then RunSelfTest: System

' session log: every status message, each stage, and the error readout while monitoring
logFile$ = exeDir$ + "PoleMasterQB.log"
LogLine ""
LogLine "===== PoleMasterQB session " + Date$ + " " + Time$ + " ====="
LogLine "site " + siteName$ + "  lat " + Fmt$(latDeg, 2) + "  lon " + Fmt$(lonDeg, 2) + "  hemisphere " + _Trim$(Str$(hemi)) + "  refraction " + OnOff$(refrOn)
logStage = -1

Do
    _Limit 30
    PollMouseEx
    HandleKeys
    UpdateCamera
    HandleImageClicks
    Cls , C_BG
    DrawImage
    DrawPanel
    DrawStatus
    DrawMenu
    If helpOn Then DrawHelp
    _Display
    LogTick
Loop

'==================================================================
'  STAR CATALOGUE (Hipparcos stars via the HYG database, V <= 8.0)
'  J2000 RA deg, Dec deg, pmRA*cos(dec) mas/yr, pmDec mas/yr, V mag
'  The first star of each list is the pole star.
'==================================================================
CatNorth:
'$Include:'catalog_north.bi'
CatSouth:
'$Include:'catalog_south.bi'

'==================================================================
'  SETTINGS FILE
'==================================================================
Sub LoadSettings
    Dim f As Long, l$, k$, v$, p As Long
    If Not _FileExists(iniFile$) Then Exit Sub
    f = FreeFile
    Open iniFile$ For Input As #f
    Do While Not EOF(f)
        Line Input #f, l$
        p = InStr(l$, "=")
        If p > 0 Then
            k$ = LCase$(_Trim$(Left$(l$, p - 1))): v$ = _Trim$(Mid$(l$, p + 1))
            Select Case k$
                Case "hemisphere": If LCase$(v$) = "south" Then hemi = -1 Else hemi = 1
                Case "latitude": latDeg = Val(v$)
                Case "longitude": lonDeg = Val(v$)
                Case "refraction": refrOn = (Val(v$) <> 0)
                Case "exposure": expMs = Val(v$)
                Case "gain": gainV = Val(v$)
                Case "site": siteName$ = v$
            End Select
        End If
    Loop
    Close #f
    expMs = _CLAMP(expMs, 1, 10000): gainV = _CLAMP(gainV, 0, 100)
End Sub

Sub SaveSettings
    Dim f As Long
    If selfTest Then Exit Sub
    f = FreeFile
    Open iniFile$ For Output As #f
    If hemi = 1 Then Print #f, "hemisphere=north" Else Print #f, "hemisphere=south"
    Print #f, "latitude=" + _Trim$(Str$(latDeg))
    Print #f, "longitude=" + _Trim$(Str$(lonDeg))
    Print #f, "refraction=" + _Trim$(Str$(-refrOn))
    Print #f, "exposure=" + _Trim$(Str$(expMs))
    Print #f, "gain=" + _Trim$(Str$(gainV))
    Print #f, "site=" + siteName$
    Close #f
End Sub

'==================================================================
'  CATALOGUE + APPARENT PLACES
'==================================================================
Sub LoadCatalog
    Dim n As Long, i As Long
    If hemi = 1 Then Restore CatNorth Else Restore CatSouth
    Read n
    If n > MAXCAT Then n = MAXCAT
    For i = 1 To n
        Read catRA(i), catDec(i), catPmA(i), catPmD(i), catMag(i)
    Next
    catN = n
    If hemi = 1 Then poleName$ = "Polaris" Else poleName$ = "Sigma Oct"
    ComputeApparent pm_utc# / 86400# + 2440587.5#
    modelOK = 0
End Sub

' apparent place (precession IAU 1976, main nutation terms, annual aberration,
' proper motion). Checked against astropy: within 0.4 arcsec near the poles.
Sub ApparentPlace (ra0 As Double, dec0 As Double, pma As Double, pmd As Double, jd As Double, raOut As Double, decOut As Double)
    Dim tc As Double, yrs As Double, ra As Double, dc As Double
    Dim zeta As Double, zz As Double, th As Double, aa As Double, bb As Double, cc As Double
    Dim al As Double, de As Double, om As Double, ls As Double, lm As Double
    Dim dpsi As Double, deps As Double, eps As Double, da1 As Double, dd1 As Double
    Dim l0 As Double, ma As Double, lam As Double, da2 As Double, dd2 As Double
    Const KAB = 20.49552#
    tc = (jd - 2451545#) / 36525#
    yrs = (jd - 2451545#) / 365.25#
    dc = dec0 + pmd * yrs / 3600000#
    ra = ra0 + pma * yrs / 3600000# / Cos(dec0 * D2R)
    zeta = (2306.2181# * tc + 0.30188# * tc * tc + 0.017998# * tc * tc * tc) / 3600# * D2R
    zz = (2306.2181# * tc + 1.09468# * tc * tc + 0.018203# * tc * tc * tc) / 3600# * D2R
    th = (2004.3109# * tc - 0.42665# * tc * tc - 0.041833# * tc * tc * tc) / 3600# * D2R
    aa = Cos(dc * D2R) * Sin(ra * D2R + zeta)
    bb = Cos(th) * Cos(dc * D2R) * Cos(ra * D2R + zeta) - Sin(th) * Sin(dc * D2R)
    cc = Sin(th) * Cos(dc * D2R) * Cos(ra * D2R + zeta) + Cos(th) * Sin(dc * D2R)
    al = _Atan2(aa, bb) + zz
    de = _Atan2(cc, Sqr(aa * aa + bb * bb))
    ' nutation (arcsec)
    om = (125.04452# - 1934.136261# * tc) * D2R
    ls = (280.4665# + 36000.7698# * tc) * D2R
    lm = (218.3165# + 481267.8813# * tc) * D2R
    dpsi = -17.2# * Sin(om) - 1.32# * Sin(2 * ls) - 0.23# * Sin(2 * lm) + 0.21# * Sin(2 * om)
    deps = 9.2# * Cos(om) + 0.57# * Cos(2 * ls) + 0.1# * Cos(2 * lm) - 0.09# * Cos(2 * om)
    eps = (23.439291# - 0.0130042# * tc) * D2R + deps / 3600# * D2R
    da1 = (Cos(eps) + Sin(eps) * Sin(al) * Tan(de)) * dpsi - Cos(al) * Tan(de) * deps
    dd1 = Sin(eps) * Cos(al) * dpsi + Sin(al) * deps
    ' annual aberration (arcsec)
    l0 = 280.46646# + 36000.76983# * tc
    ma = (357.52911# + 35999.05029# * tc) * D2R
    lam = (l0 + 1.914602# * Sin(ma) + 0.019993# * Sin(2 * ma)) * D2R
    da2 = -KAB * (Cos(al) * Cos(lam) * Cos(eps) + Sin(al) * Sin(lam)) / Cos(de)
    dd2 = -KAB * (Cos(lam) * Cos(eps) * (Tan(eps) * Cos(de) - Sin(al) * Sin(de)) + Cos(al) * Sin(de) * Sin(lam))
    al = al + (da1 + da2) / 3600# * D2R
    de = de + (dd1 + dd2) / 3600# * D2R
    raOut = al * R2D: decOut = de * R2D
End Sub

Sub ComputeApparent (jd As Double)
    Dim i As Long, ra As Double, dc As Double
    jdCat = jd
    For i = 1 To catN
        ApparentPlace catRA(i), catDec(i), catPmA(i), catPmD(i), jd, ra, dc
        catVX(i) = Cos(dc * D2R) * Cos(ra * D2R)
        catVY(i) = Cos(dc * D2R) * Sin(ra * D2R)
        catVZ(i) = Sin(dc * D2R)
    Next
    ' tangent plane at the pole star (east = increasing RA, north = towards +dec)
    Dim nrm As Double
    tpX = catVX(1): tpY = catVY(1): tpZ = catVZ(1)
    teX = -tpY: teY = tpX: teZ = 0
    nrm = Sqr(teX * teX + teY * teY): teX = teX / nrm: teY = teY / nrm
    tnX = tpY * teZ - tpZ * teY: tnY = tpZ * teX - tpX * teZ: tnZ = tpX * teY - tpY * teX
    For i = 1 To catN
        Project catVX(i), catVY(i), catVZ(i), catXi(i), catEta(i)
    Next
    Project 0, 0, hemi * 1#, poleXi, poleEta
End Sub

' gnomonic projection onto the tangent plane at the pole star (radians)
Sub Project (vx As Double, vy As Double, vz As Double, xi As Double, eta As Double)
    Dim dp As Double
    dp = vx * tpX + vy * tpY + vz * tpZ
    If dp < 0.01 Then dp = 0.01
    xi = (vx * teX + vy * teY + vz * teZ) / dp
    eta = (vx * tnX + vy * tnY + vz * tnZ) / dp
End Sub

' local sidereal time, degrees
Function LstDeg# (jd As Double)
    Dim tc As Double, g As Double
    tc = (jd - 2451545#) / 36525#
    g = 280.46061837# + 360.98564736629# * (jd - 2451545#) + 0.000387933# * tc * tc + lonDeg
    g = g - 360# * Int(g / 360#)
    LstDeg# = g
End Function

Sub SkyVec (raD As Double, decD As Double, vx As Double, vy As Double, vz As Double)
    vx = Cos(decD * D2R) * Cos(raD * D2R)
    vy = Cos(decD * D2R) * Sin(raD * D2R)
    vz = Sin(decD * D2R)
End Sub

Function NowJD# ()
    NowJD# = pm_utc# / 86400# + 2440587.5#
End Function

'==================================================================
'  STAR PATTERN MODEL
'==================================================================
Sub ModelPix (xi As Double, eta As Double, px As Double, py As Double)
    px = mA * (mF * xi) - mB * eta + mTX
    py = mB * (mF * xi) + mA * eta + mTY
End Sub

Sub GetStars
    detN = pm_find_stars&(_Offset(detX(0)), _Offset(detY(0)), _Offset(detF(0)), MAXDET, detSeq)
End Sub

' brute-force search for the overlay rotation / scale / mirror that puts the
' most catalogue stars on detected stars, with the pole star fixed at (px, py)
Function AutoMatch% (px As Double, py As Double, fullSearch As Long)
    Dim cand(1 To 40) As Long, nc As Long, i As Long, j As Long, k As Long
    Dim used(1 To MAXCAT) As Long, bestMag As Double, bi As Long, r As Double
    Dim fpar As Long, ks As Long, ia As Long, s0 As Double, sc As Double, ang As Double
    Dim a As Double, b As Double, x As Double, y As Double, dx As Double, dy As Double
    Dim score As Long, best As Long, bF As Long, bA As Double, bS As Double
    Dim f1 As Long, f2 As Long, k1 As Long, k2 As Long, tol2 As Double
    Dim cxi(1 To 40) As Double, ceta(1 To 40) As Double

    GetStars
    If detN < 4 Then AutoMatch% = 0: statusMsg$ = "Too few stars in the frame - raise the exposure or gain.": Exit Function
    ' brightest catalogue stars inside the field (not the pole star)
    nc = 0
    Do
        bestMag = 99: bi = 0
        For i = 2 To catN
            If used(i) = 0 Then
                r = Sqr(catXi(i) * catXi(i) + catEta(i) * catEta(i))
                If r < 0.14 And r > 0.004 And catMag(i) < bestMag Then bestMag = catMag(i): bi = i
            End If
        Next
        If bi = 0 Then Exit Do
        used(bi) = -1: nc = nc + 1: cand(nc) = bi: cxi(nc) = catXi(bi): ceta(nc) = catEta(bi)
    Loop Until nc = 30
    s0 = RAD2AS / NOMINAL_ASPX
    If fullSearch Then
        f1 = -1: f2 = 1: k1 = 0: k2 = 8
    Else
        f1 = mF: f2 = mF: k1 = 3: k2 = 5
        s0 = Sqr(mA * mA + mB * mB) / 1.0#: s0 = s0 / (0.92# + 4 * 0.02#)
    End If
    tol2 = 25: best = 0
    For fpar = f1 To f2 Step 2
        For ks = k1 To k2
            sc = s0 * (0.92# + ks * 0.02#)
            For ia = 0 To 719
                ang = ia * 0.5# * D2R
                a = sc * Cos(ang): b = sc * Sin(ang)
                score = 0
                For k = 1 To nc
                    x = a * (fpar * cxi(k)) - b * ceta(k) + px
                    y = b * (fpar * cxi(k)) + a * ceta(k) + py
                    If x > 3 And y > 3 And x < frW - 3 And y < frH - 3 Then
                        For j = 0 To detN - 1
                            dx = detX(j) - x: dy = detY(j) - y
                            If dx * dx + dy * dy < tol2 Then score = score + 1: Exit For
                        Next
                    End If
                Next
                If score > best Then best = score: bF = fpar: bA = ang: bS = sc
            Next
        Next
    Next
    If best < 4 Then
        AutoMatch% = 0
        statusMsg$ = "Could not match the star pattern around " + poleName$ + " (found" + Str$(best) + "). Is that " + poleName$ + "?"
        Exit Function
    End If
    mF = bF: mA = bS * Cos(bA): mB = bS * Sin(bA): mTX = px: mTY = py
    r = RefineModel&(6)
    r = RefineModel&(3)
    If r < 5 Then AutoMatch% = 0: statusMsg$ = "Star pattern match too weak (" + _Trim$(Str$(r)) + " stars).": Exit Function
    AutoMatch% = -1
End Function

' least-squares fit of the model to the catalogue stars that have a detected
' star within tol pixels; returns the number of stars used
Function RefineModel& (tol As Double)
    Dim i As Long, j As Long, n As Long, x As Double, y As Double, dx As Double, dy As Double
    Dim bd As Double, bj As Long, d2 As Double
    Dim wx(1 To MAXCAT) As Double, wy(1 To MAXCAT) As Double, zx(1 To MAXCAT) As Double, zy(1 To MAXCAT) As Double
    Dim mwx As Double, mwy As Double, mzx As Double, mzy As Double, sre As Double, sim As Double, snn As Double
    Dim taken(0 To MAXDET - 1) As Long
    n = 0
    For i = 1 To catN
        ModelPix catXi(i), catEta(i), x, y
        If x > 3 And y > 3 And x < frW - 3 And y < frH - 3 Then
            bd = tol * tol: bj = -1
            For j = 0 To detN - 1
                If taken(j) = 0 Then
                    dx = detX(j) - x: dy = detY(j) - y: d2 = dx * dx + dy * dy
                    If d2 < bd Then bd = d2: bj = j
                End If
            Next
            If bj >= 0 Then
                taken(bj) = -1: n = n + 1
                wx(n) = mF * catXi(i): wy(n) = catEta(i): zx(n) = detX(bj): zy(n) = detY(bj)
            End If
        End If
    Next
    RefineModel& = n
    If n < 3 Then Exit Function
    For i = 1 To n: mwx = mwx + wx(i): mwy = mwy + wy(i): mzx = mzx + zx(i): mzy = mzy + zy(i): Next
    mwx = mwx / n: mwy = mwy / n: mzx = mzx / n: mzy = mzy / n
    ' complex fit z = c*w + t,  c = a + ib
    For i = 1 To n
        dx = wx(i) - mwx: dy = wy(i) - mwy: x = zx(i) - mzx: y = zy(i) - mzy
        sre = sre + dx * x + dy * y
        sim = sim + dx * y - dy * x
        snn = snn + dx * dx + dy * dy
    Next
    If snn <= 0 Then Exit Function
    mA = sre / snn: mB = sim / snn
    mTX = mzx - (mA * mwx - mB * mwy)
    mTY = mzy - (mB * mwx + mA * mwy)
    mMatched = n
    mScaleAS = RAD2AS / Sqr(mA * mA + mB * mB)
End Function

' after a match: pole pixel, pole-star pixel and the sky "up" / "east" directions
Sub ModelDerived
    Dim jd As Double, lst As Double, vx As Double, vy As Double, vz As Double
    Dim xi As Double, eta As Double, x As Double, y As Double, l As Double, dec89 As Double
    ModelPix poleXi, poleEta, N0X, N0Y
    ModelPix 0, 0, P0X, P0Y
    jd = NowJD#: lst = LstDeg#(jd)
    dec89 = 89# * hemi
    ' up: the meridian above the pole (hour angle 0)
    SkyVec lst, dec89, vx, vy, vz: Project vx, vy, vz, xi, eta: ModelPix xi, eta, x, y
    upX = x - N0X: upY = y - N0Y: l = Sqr(upX * upX + upY * upY): upX = upX / l: upY = upY / l
    ' east: hour angle -6h
    SkyVec lst + 90#, dec89, vx, vy, vz: Project vx, vy, vz, xi, eta: ModelPix xi, eta, x, y
    eastX = x - N0X: eastY = y - N0Y: l = Sqr(eastX * eastX + eastY * eastY): eastX = eastX / l: eastY = eastY / l
End Sub

Sub RotateModel (deg As Double)
    Dim c As Double, s As Double, a As Double, b As Double, x As Double, y As Double
    If modelOK = 0 Then Exit Sub
    ModelPix 0, 0, x, y
    c = Cos(deg * D2R): s = Sin(deg * D2R)
    a = mA * c - mB * s: b = mA * s + mB * c
    mA = a: mB = b
    mTX = x: mTY = y
    ModelDerived
End Sub

Sub MirrorModel
    If modelOK = 0 Then Exit Sub
    mF = -mF
    ModelDerived
End Sub

' the user double-clicked the pole star at frame (fx, fy)
Sub MatchAt (fx As Double, fy As Double, fullSearch As Long)
    Dim x As Double, y As Double, fl As Double, ok As Long
    If pm_centroid&(fx, fy, 15, x, y, fl) = 0 Then statusMsg$ = "No star there - double-click right on " + poleName$ + ".": Exit Sub
    ComputeApparent NowJD#
    ok = AutoMatch%(x, y, fullSearch)
    If ok = 0 And fullSearch = 0 Then ok = AutoMatch%(x, y, -1)
    If ok Then
        modelOK = -1
        ModelDerived
        statusMsg$ = "Matched " + _Trim$(Str$(mMatched)) + " stars around " + poleName$ + ",  scale " + Fmt$(mScaleAS, 1) + Chr$(34) + "/px"
        trkPX = P0X: trkPY = P0Y: trkOn = -1: trkLost = 0
    Else
        modelOK = 0
    End If
End Sub

'==================================================================
'  RA AXIS
'==================================================================
Sub RaAddPoint (fx As Double, fy As Double)
    Dim x As Double, y As Double, fl As Double, i As Long
    If pm_centroid&(fx, fy, 15, x, y, fl) = 0 Then statusMsg$ = "No star there - double-click right on the star.": Exit Sub
    raN = raN + 1
    raPX(raN) = x: raPY(raN) = y
    GetStars
    raDN(raN) = detN
    For i = 0 To detN - 1: raDX(raN, i) = detX(i): raDY(raN, i) = detY(i): Next
    If raN < 3 Then
        statusMsg$ = "Position" + Str$(raN) + " stored. Turn the mount in RA (about 30 deg), then click Finished."
        subStep = 1
    Else
        SolveRaAxis
    End If
End Sub

Sub SolveRaAxis
    Dim x1 As Double, y1 As Double, x2 As Double, y2 As Double, x3 As Double, y3 As Double, dd As Double
    Dim cx0 As Double, cy0 As Double, k As Long, sw As Double, sx As Double, sy As Double, w As Double
    Dim ok As Long, cx As Double, cy As Double, a1 As Double, a2 As Double, span As Double
    x1 = raPX(1): y1 = raPY(1): x2 = raPX(2): y2 = raPY(2): x3 = raPX(3): y3 = raPY(3)
    dd = 2 * (x1 * (y2 - y3) + x2 * (y3 - y1) + x3 * (y1 - y2))
    If Abs(dd) < 1 Then statusMsg$ = "The three positions are in a line - turn the mount further and try again.": RaReset: Exit Sub
    cx0 = ((x1 * x1 + y1 * y1) * (y2 - y3) + (x2 * x2 + y2 * y2) * (y3 - y1) + (x3 * x3 + y3 * y3) * (y1 - y2)) / dd
    cy0 = ((x1 * x1 + y1 * y1) * (x3 - x2) + (x2 * x2 + y2 * y2) * (x1 - x3) + (x3 * x3 + y3 * y3) * (x2 - x1)) / dd
    a1 = _Atan2(y1 - cy0, x1 - cx0): a2 = _Atan2(y3 - cy0, x3 - cx0)
    span = Abs(AngDiff#(a2, a1)) * R2D
    ' refine with every star that moved with the mount (rotation about the axis)
    raPairs = 0: sw = 0: sx = 0: sy = 0
    For k = 2 To 3
        ok = RotationCentre&(1, k, cx0, cy0, cx, cy, w)
        If ok > 0 Then sx = sx + cx * w: sy = sy + cy * w: sw = sw + w: raPairs = raPairs + ok
    Next
    If sw > 0 Then raCX = sx / sw: raCY = sy / sw Else raCX = cx0: raCY = cy0
    raR = Sqr((x1 - raCX) ^ 2 + (y1 - raCY) ^ 2)
    raOK = -1: subStep = 3: raSpan = span
    statusMsg$ = "RA axis found (" + Fmt$(span, 0) + " deg of turn, " + _Trim$(Str$(raPairs)) + " star pairs). Slew back to HOME: the star should follow the green circle."
    If span < 40 Then statusMsg$ = "RA axis found, but the turn was only" + Str$(Int(span)) + " deg - Reset and turn further for a better axis. " + statusMsg$
End Sub

' fit z' = r*z + t between the star lists of RA positions i and k (matched with
' the first guess of the centre) and return the centre t/(1-r)
Function RotationCentre& (i As Long, k As Long, cx0 As Double, cy0 As Double, cx As Double, cy As Double, w As Double)
    Dim ang As Double, c As Double, s As Double, n As Long, a As Long, b As Long
    Dim px As Double, py As Double, dx As Double, dy As Double, bd As Double, bb As Long
    Dim wx(0 To MAXDET - 1) As Double, wy(0 To MAXDET - 1) As Double, zx(0 To MAXDET - 1) As Double, zy(0 To MAXDET - 1) As Double
    Dim mwx As Double, mwy As Double, mzx As Double, mzy As Double, sre As Double, sim As Double, snn As Double
    Dim rr As Double, ri As Double, tx As Double, ty As Double, den As Double, it As Long
    ang = AngDiff#(_Atan2(raPY(k) - cy0, raPX(k) - cx0), _Atan2(raPY(i) - cy0, raPX(i) - cx0))
    c = Cos(ang): s = Sin(ang)
    rr = c: ri = s: tx = cx0 - (c * cx0 - s * cy0): ty = cy0 - (s * cx0 + c * cy0)
    For it = 1 To 2
        n = 0
        For a = 0 To raDN(i) - 1
            px = rr * raDX(i, a) - ri * raDY(i, a) + tx
            py = ri * raDX(i, a) + rr * raDY(i, a) + ty
            bd = 36: bb = -1
            For b = 0 To raDN(k) - 1
                dx = raDX(k, b) - px: dy = raDY(k, b) - py
                If dx * dx + dy * dy < bd Then bd = dx * dx + dy * dy: bb = b
            Next
            If bb >= 0 Then wx(n) = raDX(i, a): wy(n) = raDY(i, a): zx(n) = raDX(k, bb): zy(n) = raDY(k, bb): n = n + 1
        Next
        If n < 4 Then RotationCentre& = 0: Exit Function
        mwx = 0: mwy = 0: mzx = 0: mzy = 0: sre = 0: sim = 0: snn = 0
        For a = 0 To n - 1: mwx = mwx + wx(a): mwy = mwy + wy(a): mzx = mzx + zx(a): mzy = mzy + zy(a): Next
        mwx = mwx / n: mwy = mwy / n: mzx = mzx / n: mzy = mzy / n
        For a = 0 To n - 1
            dx = wx(a) - mwx: dy = wy(a) - mwy: px = zx(a) - mzx: py = zy(a) - mzy
            sre = sre + dx * px + dy * py: sim = sim + dx * py - dy * px: snn = snn + dx * dx + dy * dy
        Next
        rr = sre / snn: ri = sim / snn
        tx = mzx - (rr * mwx - ri * mwy): ty = mzy - (ri * mwx + rr * mwy)
    Next
    ' centre = t / (1 - r)
    den = (1 - rr) * (1 - rr) + ri * ri
    If den < 0.0004 Then RotationCentre& = 0: Exit Function
    cx = (tx * (1 - rr) - ty * ri) / den
    cy = (ty * (1 - rr) + tx * ri) / den
    w = den * n
    RotationCentre& = n
End Function

Function AngDiff# (a As Double, b As Double)
    Dim d As Double
    d = a - b
    Do While d > _Pi: d = d - PI2: Loop
    Do While d < -_Pi: d = d + PI2: Loop
    AngDiff# = d
End Function

Sub RaReset
    raN = 0: raOK = 0: subStep = 0: raPairs = 0
End Sub

'==================================================================
'  TRACKING + ERROR
'==================================================================
Sub UpdateTracking
    Dim x As Double, y As Double, fl As Double, ok As Long
    Dim vsx As Double, vsy As Double, vx As Double, vy As Double, den As Double, rr As Double, ri As Double
    Dim dx As Double, dy As Double, nx As Double, ny As Double
    If trkOn = 0 Or modelOK = 0 Then Exit Sub
    If pm_centroid&(trkPX, trkPY, 40, x, y, fl) Then
        trkPX = x: trkPY = y: trkLost = 0
    Else
        trkLost = -1: Exit Sub
    End If
    If stage = 5 And subStep = 1 Then
        ok = pm_centroid&(trkQX, trkQY, 40, x, y, fl)
        If ok Then trkQX = x: trkQY = y Else trkLost = -1: Exit Sub
        ' rotation (+ tiny scale) from the two tracked stars
        vsx = monQX - monPX: vsy = monQY - monPY: vx = trkQX - trkPX: vy = trkQY - trkPY
        den = vsx * vsx + vsy * vsy
        rr = (vx * vsx + vy * vsy) / den: ri = (vy * vsx - vx * vsy) / den
        dx = monNX - monPX: dy = monNY - monPY
        curNX = trkPX + rr * dx - ri * dy: curNY = trkPY + ri * dx + rr * dy
        den = Sqr(rr * rr + ri * ri): rr = rr / den: ri = ri / den
        curUpX = rr * upX - ri * upY: curUpY = ri * upX + rr * upY
        curEaX = rr * eastX - ri * eastY: curEaY = ri * eastX + rr * eastY
    Else
        curNX = N0X + (trkPX - P0X): curNY = N0Y + (trkPY - P0Y)
        curUpX = upX: curUpY = upY: curEaX = eastX: curEaY = eastY
    End If
    ComputeError
End Sub

' error of the mount axis (raCX, raCY) against the pole (curNX, curNY)
Sub ComputeError
    Dim ex As Double, ey As Double, nx As Double, ny As Double, rpx As Double
    If raOK = 0 Then errOK = 0: Exit Sub
    nx = curNX: ny = curNY
    If refrOn Then
        rpx = RefractionAM# * 60# / mScaleAS
        nx = nx - rpx * curUpX: ny = ny - rpx * curUpY
    End If
    ex = nx - raCX: ey = ny - raCY
    errTot = Sqr(ex * ex + ey * ey) * mScaleAS / 60#
    errAlt = (ex * curUpX + ey * curUpY) * mScaleAS / 60#       ' + : pole above the axis -> raise
    errAz = (ex * curEaX + ey * curEaY) * mScaleAS / 60#        ' + : pole east of the axis -> move east
    errOK = -1
End Sub

' refraction at the pole's altitude (Bennett), arc minutes
Function RefractionAM# ()
    Dim h As Double
    h = Abs(latDeg)
    If h < 1 Then h = 1
    RefractionAM# = 1# / Tan((h + 7.31# / (h + 4.4#)) * D2R)
End Function

Sub StartMonitor
    ' second star: a bright matched star well away from the pole star
    Dim i As Long, x As Double, y As Double, d As Double, best As Double, bx As Double, by As Double
    Dim cx As Double, cy As Double, fl As Double, ok As Long
    If trkLost Then statusMsg$ = "Lost " + poleName$ + " - double-click it first.": Exit Sub
    best = 99: ok = 0
    For i = 2 To catN
        ModelPix catXi(i), catEta(i), x, y
        x = x + (trkPX - P0X): y = y + (trkPY - P0Y)
        d = Sqr((x - trkPX) ^ 2 + (y - trkPY) ^ 2)
        If d > 120 And x > 40 And y > 40 And x < frW - 40 And y < frH - 40 And catMag(i) < best Then
            If pm_centroid&(x, y, 12, cx, cy, fl) Then best = catMag(i): bx = cx: by = cy: ok = -1
        End If
    Next
    If ok = 0 Then statusMsg$ = "No second star found for monitoring - raise the exposure.": Exit Sub
    trkQX = bx: trkQY = by
    monPX = trkPX: monPY = trkPY: monQX = trkQX: monQY = trkQY
    monNX = N0X + (trkPX - P0X): monNY = N0Y + (trkPY - P0Y)
    subStep = 1: doneFlag = 0
    statusMsg$ = "Monitoring. Turn the altitude / azimuth knobs until the red circle sits on the green one."
End Sub

'==================================================================
'  CAMERA
'==================================================================
Sub ConnectCamera (simMode As Long)
    Dim r As Long
    If camMode Then DisconnectCamera
    If simMode Then
        r = pm_open_sim&(1280, 960)
    Else
        r = pm_open&
    End If
    If r <> 0 Then statusMsg$ = "Connect failed: " + LibErr$: Exit Sub
    r = pm_set&(expMs, gainV)
    ReadInfo
    If frameImg Then _MemFree frameMem: _FreeImage frameImg
    frameImg = _NewImage(frW, frH, 32)
    frameMem = _MemImage(frameImg)
    lastSeen = 0
    stage = 1: subStep = 0: modelOK = 0: RaReset: trkOn = 0: errOK = 0
    zoomF = 1: zoomCX = frW / 2: zoomCY = frH / 2
    If simMode Then SimInit
    statusMsg$ = "Connected: " + camName$ + "  " + _Trim$(Str$(frW)) + " x " + _Trim$(Str$(frH)) + ".  Pick the region, exposure and gain, then click Finished."
End Sub

Sub DisconnectCamera
    pm_close
    camMode = 0: stage = 0: trkOn = 0: modelOK = 0: errOK = 0
    statusMsg$ = "Disconnected."
End Sub

Sub ReadInfo
    Dim b$, r As Long
    b$ = Space$(64)
    camMode = pm_info&(_Offset(b$), 64, frW, frH, frames, satFlag, camErrs)
    r = InStr(b$, Chr$(0))
    If r > 0 Then camName$ = Left$(b$, r - 1) Else camName$ = _Trim$(b$)
End Sub

Function LibErr$ ()
    Dim b$, r As Long
    b$ = Space$(200)
    r = pm_last_error&(_Offset(b$), 200)
    r = InStr(b$, Chr$(0))
    If r > 0 Then LibErr$ = Left$(b$, r - 1) Else LibErr$ = _Trim$(b$)
End Function

Sub UpdateCamera
    Dim r As Long
    newFrame = 0
    If camMode = 0 Then Exit Sub
    If camMode = 2 And simDirty Then SimSendStars
    ReadInfo
    If frames <> lastSeen Then
        r = pm_preview&(frameMem.OFFSET, frW, frH, 0, 0, frW, frH, 0, 0, frW, frH, 0, 0)
        If r Then
            lastSeen = frames: newFrame = -1
            If stage >= 4 Then UpdateTracking
        End If
    End If
End Sub

'==================================================================
'  SIMULATOR (a misaligned mount, for practice and the self test)
'==================================================================
Sub SimInit
    Dim l As Double, ax As Double, ay As Double, az As Double
    simJD = NowJD#
    simAX = 0: simAY = 0: simAZ = hemi
    ' camera boresight 0.35 deg off the axis (the PoleMaster is never exactly coaxial)
    simBX = 0.0061: simBY = 0.0012: simBZ = hemi
    l = Sqr(simBX * simBX + simBY * simBY + simBZ * simBZ): simBX = simBX / l: simBY = simBY / l: simBZ = simBZ / l
    ' camera x axis: some roll, perpendicular to the boresight
    ax = Cos(37 * D2R): ay = Sin(37 * D2R): az = 0
    l = ax * simBX + ay * simBY + az * simBZ
    simUX = ax - l * simBX: simUY = ay - l * simBY: simUZ = az - l * simBZ
    l = Sqr(simUX * simUX + simUY * simUY + simUZ * simUZ): simUX = simUX / l: simUY = simUY / l: simUZ = simUZ / l
    ' y axis = boresight x X
    simVX = simBY * simUZ - simBZ * simUY: simVY = simBZ * simUX - simBX * simUZ: simVZ = simBX * simUY - simBY * simUX
    simScale = RAD2AS / (NOMINAL_ASPX * 1.017#)
    simPar = -1
    ' a mount polar-aligned with a compass: 23' low and 17' west
    SimAdjust -23, -17
    simDirty = -1
End Sub

' rotate vector v about unit axis k by ang radians (Rodrigues)
Sub RotVec (vx As Double, vy As Double, vz As Double, kx As Double, ky As Double, kz As Double, ang As Double)
    Dim c As Double, s As Double, d As Double, cx As Double, cy As Double, cz As Double
    c = Cos(ang): s = Sin(ang): d = kx * vx + ky * vy + kz * vz
    cx = ky * vz - kz * vy: cy = kz * vx - kx * vz: cz = kx * vy - ky * vx
    vx = vx * c + cx * s + kx * d * (1 - c)
    vy = vy * c + cy * s + ky * d * (1 - c)
    vz = vz * c + cz * s + kz * d * (1 - c)
End Sub

Sub SimRotAll (kx As Double, ky As Double, kz As Double, ang As Double)
    RotVec simAX, simAY, simAZ, kx, ky, kz, ang
    RotVec simBX, simBY, simBZ, kx, ky, kz, ang
    RotVec simUX, simUY, simUZ, kx, ky, kz, ang
    RotVec simVX, simVY, simVZ, kx, ky, kz, ang
    simDirty = -1
End Sub

' turn the mount in RA by deg
Sub SimRotateRA (deg As Double)
    Dim kx As Double, ky As Double, kz As Double
    kx = simAX: ky = simAY: kz = simAZ
    RotVec simBX, simBY, simBZ, kx, ky, kz, deg * D2R
    RotVec simUX, simUY, simUZ, kx, ky, kz, deg * D2R
    RotVec simVX, simVY, simVZ, kx, ky, kz, deg * D2R
    simDirty = -1
End Sub

' altitude knob (+ raises the axis) and azimuth knob (+ moves the axis east), arc minutes on the sky
Sub SimAdjust (altAM As Double, azAM As Double)
    Dim zx As Double, zy As Double, zz As Double, kx As Double, ky As Double, kz As Double, l As Double
    SkyVec LstDeg#(NowJD#), latDeg, zx, zy, zz
    If altAM <> 0 Then
        kx = simAY * zz - simAZ * zy: ky = simAZ * zx - simAX * zz: kz = simAX * zy - simAY * zx
        l = Sqr(kx * kx + ky * ky + kz * kz): kx = kx / l: ky = ky / l: kz = kz / l
        SimRotAll kx, ky, kz, altAM / 60# * D2R
    End If
    ' azimuth: the knob amount is given as arc on the sky at the pole's altitude
    If azAM <> 0 Then SimRotAll zx, zy, zz, -hemi * azAM / 60# * D2R / Cos(latDeg * D2R)
End Sub

Sub SimPix (vx As Double, vy As Double, vz As Double, x As Double, y As Double, ok As Long)
    Dim d As Double
    d = vx * simBX + vy * simBY + vz * simBZ
    ok = 0
    If d < 0.98 Then Exit Sub
    x = frW / 2 + simScale * simPar * (vx * simUX + vy * simUY + vz * simUZ) / d
    y = frH / 2 + simScale * (vx * simVX + vy * simVY + vz * simVZ) / d
    ok = -1
End Sub

Sub SimSendStars
    Dim i As Long, n As Long, x As Double, y As Double, ok As Long, r As Long
    n = 0
    For i = 1 To catN
        SimPix catVX(i), catVY(i), catVZ(i), x, y, ok
        If ok And x > -10 And y > -10 And x < frW + 10 And y < frH + 10 Then
            simX(n) = x: simY(n) = y: simM(n) = catMag(i): n = n + 1
        End If
    Next
    r = pm_sim_stars&(_Offset(simX(0)), _Offset(simY(0)), _Offset(simM(0)), n)
    simDirty = 0
End Sub

' true error of the simulated mount (arc minutes): total, altitude (+ = raise), azimuth (+ = move east)
Sub SimTruth (tot As Double, ta As Double, tz As Double)
    Dim zx As Double, zy As Double, zz As Double, ex As Double, ey As Double, ez As Double, lst As Double
    Dim dx As Double, dy As Double, dz As Double, d As Double
    lst = LstDeg#(NowJD#)
    SkyVec lst, latDeg, zx, zy, zz
    SkyVec lst + 90#, 0, ex, ey, ez
    d = simAX * 0 + simAY * 0 + simAZ * hemi
    If d > 1 Then d = 1
    tot = _Acos(d) * R2D * 60#
    dx = 0 - simAX: dy = 0 - simAY: dz = hemi - simAZ
    ' altitude difference: pole minus axis
    ta = (_Asin(hemi * zz) - _Asin(simAX * zx + simAY * zy + simAZ * zz)) * R2D * 60#
    tz = (dx * ex + dy * ey + dz * ez) * R2D * 60#
End Sub

Sub SimAxisPix (x As Double, y As Double, ok As Long)
    SimPix simAX, simAY, simAZ, x, y, ok
End Sub

'==================================================================
'  INPUT
'==================================================================
Sub PollMouseEx
    ' like ButtonUI's PollMouse, plus the mouse wheel and double clicks.
    ' Every queued mouse event is looked at, so a quick tap (press and
    ' release between two frames) still counts as a click.
    Static evDown As Long
    Dim clickNow As Long, cx As Long, cy As Long
    Do While _MouseInput
        wheelAcc = wheelAcc + _MouseWheel
        If _MouseButton(1) Then
            evDown = -1
        ElseIf evDown Then
            evDown = 0: clickNow = -1: cx = _MouseX: cy = _MouseY
        End If
    Loop
    gMouse.prevHeld = gMouse.held
    gMouse.mx = _MouseX
    gMouse.my = _MouseY
    If _MouseButton(1) Then gMouse.held = -1 Else gMouse.held = 0
    dblClick = 0
    gMouse.clicked = clickNow
    If clickNow Then
        gMouse.mx = cx: gMouse.my = cy
        If Timer(0.001) - lastClickT < 0.45 And Abs(cx - lastClickX) < 6 And Abs(cy - lastClickY) < 6 Then
            dblClick = -1: dblX = cx: dblY = cy: lastClickT = 0
        Else
            lastClickT = Timer(0.001): lastClickX = cx: lastClickY = cy
        End If
    End If
End Sub

Sub HandleKeys
    Dim k As Long, shf As Long, c$
    shf = _KeyDown(100303) Or _KeyDown(100304)
    Do
        k = _KeyHit
        If k <= 0 Then Exit Do
        If editField Then
            Select Case k
                Case 13: CommitEdit
                Case 27: editField = 0
                Case 8: If Len(editBuf$) > 0 Then editBuf$ = Left$(editBuf$, Len(editBuf$) - 1)
                Case 45, 46, 48 To 57
                    If Len(editBuf$) < 12 Then editBuf$ = editBuf$ + Chr$(k)
                Case 32, 65 To 90, 97 To 122
                    If editField = 3 And Len(editBuf$) < 12 Then editBuf$ = editBuf$ + UCase$(Chr$(k))
            End Select
        Else
            Select Case k
                Case 27: If menuOpen Then menuOpen = 0 Else helpOn = 0
                Case 19200: If stage = 2 Or (stage = 4 And subStep = 0) Then RotateModel -0.5 + 4.5 * (shf <> 0)
                Case 19712: If stage = 2 Or (stage = 4 And subStep = 0) Then RotateModel 0.5 - 4.5 * (shf <> 0)
                Case 77, 109: If stage = 2 Or (stage = 4 And subStep = 0) Then MirrorModel
                Case 90, 122: CycleZoom
                Case 15104: helpOn = Not helpOn
            End Select
        End If
    Loop
    ' mouse wheel over the image rotates the overlay while matching
    If wheelAcc <> 0 Then
        If (stage = 2 Or (stage = 4 And subStep = 0)) And modelOK Then RotateModel wheelAcc * 0.5
        wheelAcc = 0
    End If
    c$ = ""
End Sub

Sub CommitEdit
    Dim v As Double
    v = Val(editBuf$)
    If editField = 1 Then
        If v >= -90 And v <= 90 Then latDeg = v: siteName$ = "typed in" Else statusMsg$ = "Latitude must be -90 to 90."
    ElseIf editField = 2 Then
        If v >= -180 And v <= 180 Then lonDeg = v: siteName$ = "typed in" Else statusMsg$ = "Longitude must be -180 to 180 (east positive)."
    ElseIf editField = 3 Then
        editField = 0
        SiteFromZip editBuf$
    End If
    editField = 0
    SaveSettings
End Sub

Sub CycleZoom
    If camMode = 0 Then Exit Sub
    If zoomF = 1 Then
        zoomF = 2
    ElseIf zoomF = 2 Then
        zoomF = 4
    Else
        zoomF = 1
    End If
    If modelOK Then zoomCX = trkPX: zoomCY = trkPY
    If raOK And stage >= 4 Then zoomCX = raCX: zoomCY = raCY
End Sub

' frame <-> screen
Sub ViewSetup
    Dim fs As Double, vw As Double, vh As Double
    fs = IMG_W / frW
    If IMG_H / frH < fs Then fs = IMG_H / frH
    vSc = fs * zoomF
    vw = IMG_W / vSc: vh = IMG_H / vSc
    If vw > frW Then vw = frW
    If vh > frH Then vh = frH
    If zoomF = 1 Then zoomCX = frW / 2: zoomCY = frH / 2
    If zoomCX < vw / 2 Then zoomCX = vw / 2
    If zoomCX > frW - vw / 2 Then zoomCX = frW - vw / 2
    If zoomCY < vh / 2 Then zoomCY = vh / 2
    If zoomCY > frH - vh / 2 Then zoomCY = frH - vh / 2
    vX0 = zoomCX - vw / 2: vY0 = zoomCY - vh / 2
    vOX = IMG_X + (IMG_W - vw * vSc) / 2: vOY = IMG_Y + (IMG_H - vh * vSc) / 2
End Sub

Function ScrX# (fx As Double)
    ScrX# = vOX + (fx - vX0) * vSc
End Function

Function ScrY# (fy As Double)
    ScrY# = vOY + (fy - vY0) * vSc
End Function

Sub HandleImageClicks
    Dim fx As Double, fy As Double
    If dblClick = 0 Or camMode = 0 Or menuOpen Then Exit Sub
    If dblX < IMG_X Or dblY < IMG_Y Or dblY > IMG_Y + IMG_H Then Exit Sub
    ViewSetup
    fx = vX0 + (dblX - vOX) / vSc: fy = vY0 + (dblY - vOY) / vSc
    If fx < 0 Or fy < 0 Or fx >= frW Or fy >= frH Then Exit Sub
    ImageDoubleClick fx, fy
End Sub

Sub ImageDoubleClick (fx As Double, fy As Double)
    Dim x As Double, y As Double, fl As Double
    Select Case stage
        Case 2
            MatchAt fx, fy, -1
        Case 3
            If subStep = 0 Or subStep = 2 Then RaAddPoint fx, fy
        Case 4
            If subStep = 0 Then
                MatchAt fx, fy, 0
            Else
                If pm_centroid&(fx, fy, 15, x, y, fl) Then
                    ' re-acquire the pole star (the model moves with it)
                    trkPX = x: trkPY = y: trkLost = 0
                End If
            End If
        Case 5
            If pm_centroid&(fx, fy, 15, x, y, fl) Then
                trkPX = x: trkPY = y: trkLost = 0
                If subStep = 1 Then StartMonitor
            End If
    End Select
End Sub

'==================================================================
'  DRAWING
'==================================================================
Sub DrawImage
    Dim x1 As Double, y1 As Double, w As Double, h As Double
    Line (IMG_X, IMG_Y)-(IMG_X + IMG_W - 1, IMG_Y + IMG_H - 1), _RGB32(16, 16, 18), BF
    If camMode = 0 Or frameImg = 0 Then
        Color C_DIM
        _PrintString (IMG_X + IMG_W \ 2 - 160, IMG_Y + IMG_H \ 2 - 8), "No camera - use the Connect menu"
        Exit Sub
    End If
    ViewSetup
    w = IMG_W / vSc: h = IMG_H / vSc
    If w > frW Then w = frW
    If h > frH Then h = frH
    _PutImage (vOX, vOY)-(vOX + w * vSc - 1, vOY + h * vSc - 1), frameImg, 0, (vX0, vY0)-(vX0 + w - 1, vY0 + h - 1)
    View Screen (IMG_X, IMG_Y)-(IMG_X + IMG_W - 1, IMG_Y + IMG_H - 1)
    DrawOverlay
    View
    Color C_BLUE
    _PrintString (IMG_X + 8, IMG_Y + 6), camName$ + "   frame" + Str$(frames) + "   " + _Trim$(Str$(expMs)) + " ms   gain" + Str$(gainV) + "   zoom x" + _Trim$(Str$(zoomF))
    If satFlag Then Color C_RED: _PrintString (IMG_X + 8, IMG_Y + 24), "SATURATED - lower the exposure or gain"
    If camMode = 2 Then Color C_ACC: _PrintString (IMG_X + IMG_W - 100, IMG_Y + 6), "SIMULATOR"
End Sub

Sub DrawOverlay
    Dim i As Long, x As Double, y As Double, r As Double, dx As Double, dy As Double
    Dim ox As Double, oy As Double, tx As Double, ty As Double, nx As Double, ny As Double, rpx As Double

    ' star pattern overlay (confirm / rough match)
    If modelOK And (stage = 2 Or (stage = 4 And subStep = 0)) Then
        ox = 0: oy = 0
        For i = 2 To catN
            If catMag(i) <= 7# Then
                ModelPix catXi(i), catEta(i), x, y
                If x > -20 And y > -20 And x < frW + 20 And y < frH + 20 Then
                    r = 12 - catMag(i)
                    If r < 4 Then r = 4
                    Circle (ScrX#(x), ScrY#(y)), r * 1.2, C_RED
                End If
            End If
        Next
        ModelPix 0, 0, x, y
        Circle (ScrX#(x), ScrY#(y)), 14, C_RED
        Circle (ScrX#(x), ScrY#(y)), 15, C_RED
        Color C_RED: _PrintString (ScrX#(x) - 20 - 8 * Len(poleName$), ScrY#(y) - 8), poleName$
        ModelPix poleXi, poleEta, x, y
        Cross ScrX#(x), ScrY#(y), 7, C_GREEN
        Color C_GREEN: _PrintString (ScrX#(x) + 8, ScrY#(y) - 22), "pole"
    End If

    ' RA axis points / circle
    If stage = 3 Then
        For i = 1 To raN
            Circle (ScrX#(raPX(i)), ScrY#(raPY(i))), 10, C_YEL
            Color C_YEL: _PrintString (ScrX#(raPX(i)) + 12, ScrY#(raPY(i)) - 8), _Trim$(Str$(i))
        Next
        If raOK Then
            Circle (ScrX#(raCX), ScrY#(raCY)), raR * vSc, C_GREEN
            Cross ScrX#(raCX), ScrY#(raCY), 8, C_GREEN
        End If
    End If

    ' rough alignment: where the pole star has to go
    If stage = 4 And subStep = 1 And raOK Then
        Cross ScrX#(raCX), ScrY#(raCY), 6, C_GREEN
        nx = curNX: ny = curNY
        If refrOn Then rpx = RefractionAM# * 60# / mScaleAS: nx = nx - rpx * curUpX: ny = ny - rpx * curUpY
        tx = trkPX + (raCX - nx): ty = trkPY + (raCY - ny)
        Circle (ScrX#(tx), ScrY#(ty)), 7, C_GREEN
        Circle (ScrX#(tx), ScrY#(ty)), 8, C_GREEN
        Color C_GREEN: _PrintString (ScrX#(tx) - 4 - 8 * Len("put " + poleName$ + " here"), ScrY#(ty) - 20), "put " + poleName$ + " here"
        If trkLost Then Color C_RED Else Color C_YEL
        Circle (ScrX#(trkPX), ScrY#(trkPY)), 12, _RGB32(250, 230, 90)
        Line (ScrX#(trkPX), ScrY#(trkPY))-(ScrX#(tx), ScrY#(ty)), _RGBA32(250, 230, 90, 120)
    End If

    ' precise alignment: red = pole, green = axis, green boxes = tracked stars
    If stage = 5 And raOK Then
        Circle (ScrX#(raCX), ScrY#(raCY)), 6, C_GREEN
        Circle (ScrX#(raCX), ScrY#(raCY)), 7, C_GREEN
        If subStep = 1 Or errOK Then
            nx = curNX: ny = curNY
            If refrOn Then rpx = RefractionAM# * 60# / mScaleAS: nx = nx - rpx * curUpX: ny = ny - rpx * curUpY
            Circle (ScrX#(nx), ScrY#(ny)), 6, C_RED
            Circle (ScrX#(nx), ScrY#(ny)), 7, C_RED
        End If
        BoxAt ScrX#(trkPX), ScrY#(trkPY), 22, C_GREEN
        If subStep = 1 Then BoxAt ScrX#(trkQX), ScrY#(trkQY), 22, C_GREEN
        If raOK And errOK Then
            ' direction arrows for the knobs
            dx = curUpX: dy = curUpY
            Color C_BLUE
            Line (ScrX#(raCX), ScrY#(raCY))-(ScrX#(raCX) + dx * 60, ScrY#(raCY) + dy * 60), C_BLUE
            _PrintString (ScrX#(raCX) + dx * 66 - 8, ScrY#(raCY) + dy * 66 - 8), "up"
            Line (ScrX#(raCX), ScrY#(raCY))-(ScrX#(raCX) + curEaX * 60, ScrY#(raCY) + curEaY * 60), C_BLUE
            _PrintString (ScrX#(raCX) + curEaX * 66 - 16, ScrY#(raCY) + curEaY * 66 - 8), "east"
        End If
    End If
End Sub

Sub Cross (x As Double, y As Double, r As Double, c As _Unsigned Long)
    Line (x - r, y)-(x + r, y), c
    Line (x, y - r)-(x, y + r), c
End Sub

Sub BoxAt (x As Double, y As Double, r As Double, c As _Unsigned Long)
    Line (x - r, y - r)-(x + r, y + r), c, B
End Sub

Sub DrawMenu
    Dim mx As Long, my As Long, items$(1 To 4), xs(1 To 5) As Long, i As Long, sel As Long, hit As Long
    Line (0, 0)-(SCR_W - 1, MENU_H - 1), C_MENU, BF
    items$(1) = "File": items$(2) = "Connect": items$(3) = "Zoom": items$(4) = "Help"
    xs(1) = 8
    For i = 1 To 4
        xs(i + 1) = xs(i) + 8 * Len(items$(i)) + 24
        If menuOpen = i Then Line (xs(i) - 6, 0)-(xs(i + 1) - 14, MENU_H - 1), C_HEADON, BF
        Color C_TEXT: _PrintString (xs(i), 3), items$(i)
    Next
    mx = gMouse.mx: my = gMouse.my
    ' open / close menus
    If gMouse.clicked And my < MENU_H Then
        hit = 0
        For i = 1 To 4
            If mx >= xs(i) - 6 And mx < xs(i + 1) - 14 Then hit = i
        Next
        If hit = menuOpen Then menuOpen = 0 Else menuOpen = hit
        gMouse.clicked = 0
        Exit Sub
    End If
    If menuOpen = 0 Then Exit Sub
    sel = MenuList%(xs(menuOpen) - 6, MenuItems$(menuOpen))
    If sel = 0 Then Exit Sub
    Select Case menuOpen
        Case 1
            If sel = 1 Then SaveBmp
            If sel = 2 Then SaveSettings: pm_close: System
        Case 2
            If sel = 1 Then ConnectCamera 0
            If sel = 2 Then ConnectCamera -1
            If sel = 3 Then DisconnectCamera
        Case 3
            If sel = 1 Then zoomF = 1
            If sel = 2 Then zoomF = 2
            If sel = 3 Then zoomF = 4
            If sel > 1 Then
                If modelOK Then zoomCX = trkPX: zoomCY = trkPY Else zoomCX = frW / 2: zoomCY = frH / 2
                If raOK And stage >= 4 Then zoomCX = raCX: zoomCY = raCY
            End If
        Case 4
            helpOn = -1
    End Select
    menuOpen = 0
End Sub

Function MenuItems$ (m As Long)
    Select Case m
        Case 1: MenuItems$ = "Save as BMP|Exit"
        Case 2: MenuItems$ = "PoleMaster|Simulator|Disconnect"
        Case 3: MenuItems$ = "Fit|2x|4x"
        Case 4: MenuItems$ = "How to use"
    End Select
End Function

' draws a drop-down list; returns the picked item (1..n) or 0
Function MenuList% (x As Long, lst$)
    Dim n As Long, i As Long, p As Long, q As Long, it$(1 To 10), w As Long, y As Long, over As Long
    q = 1
    Do
        p = InStr(q, lst$, "|")
        n = n + 1
        If p = 0 Then it$(n) = Mid$(lst$, q): Exit Do
        it$(n) = Mid$(lst$, q, p - q): q = p + 1
    Loop
    w = 0
    For i = 1 To n
        If Len(it$(i)) * 8 + 24 > w Then w = Len(it$(i)) * 8 + 24
    Next
    Line (x, MENU_H)-(x + w, MENU_H + n * 22 + 4), C_MENU, BF
    Line (x, MENU_H)-(x + w, MENU_H + n * 22 + 4), C_HEAD, B
    For i = 1 To n
        y = MENU_H + 2 + (i - 1) * 22
        over = PtInRect%(gMouse.mx, gMouse.my, x, y, w, 21)
        If over Then Line (x + 1, y)-(x + w - 1, y + 21), C_HEADON, BF
        Color C_TEXT: _PrintString (x + 12, y + 3), it$(i)
        If over And gMouse.clicked Then MenuList% = i: gMouse.clicked = 0
    Next
    ' click elsewhere closes the menu
    If gMouse.clicked And Not PtInRect%(gMouse.mx, gMouse.my, x, MENU_H, w, n * 22 + 4) Then menuOpen = 0: gMouse.clicked = 0
End Function

Sub SaveBmp
    Dim f$
    If camMode = 0 Then statusMsg$ = "Nothing to save - no camera.": Exit Sub
    f$ = exeDir$ + "polemaster_" + Mid$(Date$, 7, 4) + Left$(Date$, 2) + Mid$(Date$, 4, 2) + "_" + Left$(Time$, 2) + Mid$(Time$, 4, 2) + Right$(Time$, 2) + ".bmp"
    _SaveImage f$, frameImg
    statusMsg$ = "Saved " + f$
End Sub

Sub DrawStatus
    Line (0, SCR_H - STAT_H)-(SCR_W - 1, SCR_H - 1), C_MENU, BF
    Color C_TEXT
    _PrintString (8, SCR_H - STAT_H + 3), Left$(statusMsg$, (SCR_W - 16) \ 8)
End Sub

' section header; returns -1 if clicked
Function Header% (y As Long, num As Long, title$, active As Long)
    Dim c As _Unsigned Long, arrow$
    If active Then c = C_HEADON Else c = C_HEAD
    Line (4, y)-(PANEL_W - 6, y + 22), c, BF
    If active Then arrow$ = "v" Else arrow$ = ">"
    If active Then Color C_ACC Else Color C_TEXT
    _PrintString (12, y + 3), arrow$ + " " + _Trim$(Str$(num)) + "  " + title$
    Header% = gMouse.clicked And PtInRect%(gMouse.mx, gMouse.my, 4, y, PANEL_W - 10, 22) And menuOpen = 0
End Function

' word-wrapped text in the panel; returns the next y
Function PText& (y As Long, t$, c As _Unsigned Long)
    Dim maxC As Long, s$, p As Long, yy As Long, cut As Long
    maxC = (PANEL_W - 24) \ 8
    s$ = t$: yy = y
    Color c
    Do While Len(s$) > 0
        If Len(s$) <= maxC Then
            _PrintString (14, yy), s$: yy = yy + 16: Exit Do
        End If
        cut = 0
        For p = maxC + 1 To 1 Step -1
            If Mid$(s$, p, 1) = " " Then cut = p: Exit For
        Next
        If cut = 0 Then cut = maxC
        _PrintString (14, yy), RTrim$(Left$(s$, cut)): yy = yy + 16
        s$ = LTrim$(Mid$(s$, cut + 1))
    Loop
    PText& = yy
End Function

Function PButton% (x As Long, y As Long, w As Long, cap$, onFlag As Long)
    If menuOpen Then
        PButton% = 0
        If onFlag Then DrawBevel x, y, w, 24, cap$, 0 Else DrawBevel x, y, w, 24, cap$, 3
    Else
        PButton% = ButtonEx%(x, y, w, 24, cap$, onFlag)
    End If
    _PrintMode _KeepBackground
End Function

' a toggle-looking button: drawn in orange when selected
Function PChoice% (x As Long, y As Long, w As Long, cap$, selected As Long)
    Dim r As Long
    r = PButton%(x, y, w, cap$, -1)
    If selected Then
        Line (x, y)-(x + w, y + 24), C_ACC, B
        Line (x + 1, y + 1)-(x + w - 1, y + 23), C_ACC, B
    End If
    PChoice% = r
End Function

Sub DrawPanel
    Dim y As Long, i As Long, x As Long, e$, v As Long, ok As Long, t As Double, ta As Double, tz As Double
    Dim lst$, ev As Long
    Line (0, MENU_H)-(PANEL_W - 1, SCR_H - STAT_H - 1), C_PANEL, BF
    y = MENU_H + 6

    '--- 1 Region / settings
    If Header%(y, 1, "Region + PoleMaster Setting", stage = 1) And camMode Then stage = 1: subStep = 0: trkOn = 0
    y = y + 26
    If stage = 1 Then
        Color C_TEXT: _PrintString (14, y + 4), "Region"
        If PChoice%(84, y, 90, "North", hemi = 1) Then SetHemi 1
        If PChoice%(184, y, 90, "South", hemi = -1) Then SetHemi -1
        y = y + 30
        Color C_TEXT: _PrintString (14, y + 4), "Exp(ms)"
        Color C_ACC: _PrintString (84, y + 4), _Trim$(Str$(expMs))
        If PButton%(184, y, 42, "-", camMode <> 0) Then expMs = ListStep&(EXP_LIST, expMs, -1): ApplyCam
        If PButton%(232, y, 42, "+", camMode <> 0) Then expMs = ListStep&(EXP_LIST, expMs, 1): ApplyCam
        y = y + 28
        x = 14
        For i = 1 To 5
            v = Val(Mid$("100 |200 |500 |1000|2000", (i - 1) * 5 + 1, 4))
            If PChoice%(x, y, 48, _Trim$(Str$(v)), expMs = v) Then expMs = v: ApplyCam
            x = x + 54
        Next
        y = y + 30
        Color C_TEXT: _PrintString (14, y + 4), "Gain"
        Color C_ACC: _PrintString (84, y + 4), _Trim$(Str$(gainV))
        If PButton%(184, y, 42, "-", camMode <> 0) Then gainV = _CLAMP(gainV - 5, 0, 100): ApplyCam
        If PButton%(232, y, 42, "+", camMode <> 0) Then gainV = _CLAMP(gainV + 5, 0, 100): ApplyCam
        y = y + 28
        x = 14
        For i = 1 To 4
            v = 30 + (i - 1) * 20
            If PChoice%(x, y, 60, _Trim$(Str$(v)), gainV = v) Then gainV = v: ApplyCam
            x = x + 66
        Next
        y = y + 32
        y = EditRow&(y, 1, "Latitude", latDeg)
        y = EditRow&(y, 2, "Longitude", lonDeg)
        y = ZipRow&(y)
        Color C_DIM: _PrintString (14, y), "Site: " + Left$(siteName$, 28): y = y + 20
        If PChoice%(14, y, 260, "Refraction correction: " + OnOff$(refrOn), refrOn) Then refrOn = Not refrOn: SaveSettings
        y = y + 32
        y = PText&(y, "Night sky: about 1-2 s at gain 40-60 shows " + poleName$ + " and many fainter stars.", C_DIM)
        If PButton%(14, y + 4, 260, "Finished", camMode <> 0) Then
            SaveSettings: stage = 2: subStep = 0: modelOK = 0
            statusMsg$ = "Double-click " + poleName$ + " in the image."
        End If
        y = y + 34
    End If

    '--- 2 Confirm pole star
    If Header%(y, 2, "Confirm " + poleName$, stage = 2) And camMode Then stage = 2: subStep = 0: trkOn = 0
    y = y + 26
    If stage = 2 Then
        y = PText&(y, "Double-click " + poleName$ + ". The star pattern is matched automatically: every red circle should hold a star. If not, turn it with the arrow keys / mouse wheel, or Mirror.", C_TEXT)
        y = y + 4
        If PButton%(14, y, 40, "<<", modelOK) Then RotateModel -5
        If PButton%(58, y, 40, "<", modelOK) Then RotateModel -0.5
        If PButton%(102, y, 40, ">", modelOK) Then RotateModel 0.5
        If PButton%(146, y, 40, ">>", modelOK) Then RotateModel 5
        If PButton%(192, y, 82, "Mirror", modelOK) Then MirrorModel
        y = y + 30
        If PButton%(14, y, 128, "Snap to stars", modelOK) Then
            GetStars: ev = RefineModel&(6): ev = RefineModel&(3)
            If ev >= 3 Then ModelDerived: statusMsg$ = "Snapped to" + Str$(ev) + " stars." Else statusMsg$ = "Nothing to snap to - turn the overlay closer first."
        End If
        If PButton%(146, y, 128, "Auto match", modelOK) Then MatchAt P0X, P0Y, -1
        y = y + 30
        If modelOK Then y = PText&(y, "Matched" + Str$(mMatched) + " stars, " + Fmt$(mScaleAS, 1) + Chr$(34) + "/px", C_GREEN)
        Color C_TEXT: _PrintString (14, y + 8), "Does it match?"
        If PButton%(146, y + 2, 128, "Success", modelOK) Then
            stage = 3: RaReset
            statusMsg$ = "Double-click a bright star (not " + poleName$ + ") well away from the centre."
        End If
        y = y + 34
    End If

    '--- 3 RA axis
    If Header%(y, 3, "Determine the RA axis", stage = 3) And modelOK Then stage = 3: RaReset: trkOn = 0
    y = y + 26
    If stage = 3 Then
        Select Case subStep
            Case 0
                If raN = 0 Then
                    y = PText&(y, "The mount should be at HOME (counterweight down, scope at the pole) - this is where you slew back to later.", C_YEL)
                    y = PText&(y, "Double-click a bright star (not " + poleName$ + "), well away from it.", C_TEXT)
                Else
                    y = PText&(y, "Double-click the same star again.", C_TEXT)
                End If
            Case 1
                y = PText&(y, "Turn the mount in RA with the hand controller so the star moves about 30 deg along its arc (do not loosen the RA clutch). Then click Finished.", C_TEXT)
                y = PText&(y, "Bigger turns give a better axis: aim for 50-60 deg in total over the two turns.", C_DIM)
                If PButton%(14, y + 4, 260, "Finished", -1) Then
                    subStep = 2: statusMsg$ = "Double-click the same star again."
                End If
                y = y + 34
            Case 2
                y = PText&(y, "Double-click the same star again.", C_TEXT)
            Case 3
                If raSpan < 40 Then
                    y = PText&(y, "Only" + Str$(Int(raSpan + 0.5)) + " deg of RA turn - the green circle may be off and the circles will drift apart later. Best: Reset and redo with bigger turns (50-60 deg total).", C_YEL)
                Else
                    y = PText&(y, _Trim$(Str$(Int(raSpan + 0.5))) + " deg of RA turn - good axis.", C_GREEN)
                End If
                y = PText&(y, "Slew back to HOME: the other RA direction, the same amount you turned (or Utility > Park Scope > Home Position on the hand controller). The star should run along the green circle.", C_TEXT)
                If PButton%(14, y + 4, 128, "Correct", -1) Then
                    stage = 4: subStep = 0: trkOn = 0
                    statusMsg$ = "Double-click " + poleName$ + " again to place the overlay."
                End If
                If PButton%(146, y + 4, 128, "Reset", -1) Then RaReset: statusMsg$ = "Double-click a bright star."
                y = y + 34
        End Select
        Color C_DIM: _PrintString (14, y), "Positions stored:" + Str$(raN): y = y + 20
        If raN > 0 And subStep < 3 Then
            If PButton%(14, y, 128, "Reset", -1) Then RaReset
            y = y + 30
        End If
    End If

    '--- 4 Rough alignment
    If Header%(y, 4, "Rough Polar Alignment", stage = 4) And raOK Then stage = 4: subStep = 0: trkOn = 0
    y = y + 26
    If stage = 4 Then
        If subStep = 0 Then
            y = PText&(y, "Double-click " + poleName$ + " again and check the overlay (turn it if needed), then Success.", C_TEXT)
            If PButton%(14, y + 4, 128, "Success", modelOK And trkOn) Then subStep = 1: errOK = 0
            y = y + 34
        Else
            y = PText&(y, "With the mount still at HOME, use the altitude and azimuth knobs to move " + poleName$ + " into the small green circle. Then Finished.", C_TEXT)
            y = ErrorBlock&(y)
            If PButton%(14, y + 4, 128, "Finished", -1) Then
                stage = 5: subStep = 0
                statusMsg$ = "Click Start Monitor."
            End If
            y = y + 34
        End If
    End If

    '--- 5 Precise alignment
    If Header%(y, 5, "Precise Polar Alignment", stage = 5) And raOK Then stage = 5: subStep = 0
    y = y + 26
    If stage = 5 Then
        If subStep = 0 Then
            y = PText&(y, "Click Start Monitor. " + poleName$ + " and a second star are tracked in the green boxes.", C_TEXT)
            If PButton%(14, y + 4, 128, "Start Monitor", -1) Then StartMonitor
            y = y + 34
        Else
            y = PText&(y, "Bring the red circle (pole) onto the green circle (mount axis).", C_TEXT)
            y = ErrorBlock&(y)
            If PButton%(14, y + 4, 128, "Restart", -1) Then StartMonitor
            If PButton%(146, y + 4, 128, "Finished", -1) Then doneFlag = -1: statusMsg$ = "Polar alignment finished: " + Fmt$(errTot, 1) + "' from the pole. Leave the mount at HOME."
            y = y + 34
            If doneFlag Then y = PText&(y, "Done. Leave the mount at HOME and run the SynScan star alignment. Not sure it's home? Hand controller: Utility > Park Scope > Home Position.", C_GREEN)
        End If
    End If

    '--- simulator controls
    If camMode = 2 Then
        y = y + 4
        Line (4, y)-(PANEL_W - 6, y), C_HEAD
        y = y + 6
        Color C_ACC: _PrintString (12, y), "Simulator mount": y = y + 20
        Color C_TEXT: _PrintString (14, y + 4), "RA"
        If PButton%(84, y, 60, "-30", -1) Then SimRotateRA -30
        If PButton%(148, y, 60, "+30", -1) Then SimRotateRA 30
        If PButton%(212, y, 62, "+90", -1) Then SimRotateRA 90
        y = y + 28
        Color C_TEXT: _PrintString (14, y + 4), "Alt"
        If PButton%(84, y, 44, "-5'", -1) Then SimAdjust -5, 0
        If PButton%(132, y, 44, "-1'", -1) Then SimAdjust -1, 0
        If PButton%(180, y, 44, "+1'", -1) Then SimAdjust 1, 0
        If PButton%(228, y, 46, "+5'", -1) Then SimAdjust 5, 0
        y = y + 28
        Color C_TEXT: _PrintString (14, y + 4), "Az"
        If PButton%(84, y, 44, "W5'", -1) Then SimAdjust 0, -5
        If PButton%(132, y, 44, "W1'", -1) Then SimAdjust 0, -1
        If PButton%(180, y, 44, "E1'", -1) Then SimAdjust 0, 1
        If PButton%(228, y, 46, "E5'", -1) Then SimAdjust 0, 5
        y = y + 28
        SimTruth t, ta, tz
        Color C_DIM: _PrintString (14, y), "true: " + Fmt$(t, 1) + "'  alt " + Fmt$(ta, 1) + "'  az " + Fmt$(tz, 1) + "'"
    End If

    ' edit-field clicks are handled in EditRow
    lst$ = ""
End Sub

Function ErrorBlock& (y As Long)
    Dim yy As Long
    yy = y + 4
    If errOK = 0 Then
        Color C_DIM: _PrintString (14, yy), "waiting for the pole star...": ErrorBlock& = yy + 20: Exit Function
    End If
    If trkLost Then Color C_RED: _PrintString (14, yy), "lost the star - double-click it": yy = yy + 18
    Color C_ACC: _PrintString (14, yy), "Total error   " + Fmt$(errTot, 1) + "'": yy = yy + 18
    Color C_TEXT
    If errAlt >= 0 Then
        _PrintString (14, yy), "Altitude: RAISE " + Fmt$(Abs(errAlt), 1) + "'"
    Else
        _PrintString (14, yy), "Altitude: LOWER " + Fmt$(Abs(errAlt), 1) + "'"
    End If
    yy = yy + 18
    If errAz >= 0 Then
        _PrintString (14, yy), "Azimuth:  move EAST " + Fmt$(Abs(errAz), 1) + "'"
    Else
        _PrintString (14, yy), "Azimuth:  move WEST " + Fmt$(Abs(errAz), 1) + "'"
    End If
    yy = yy + 18
    If refrOn Then Color C_DIM: _PrintString (14, yy), "(refraction " + Fmt$(RefractionAM#, 1) + "' included)": yy = yy + 18
    ErrorBlock& = yy
End Function

Function EditRow& (y As Long, idx As Long, label$, v As Double)
    Dim t$
    Color C_TEXT: _PrintString (14, y + 4), label$
    If editField = idx Then t$ = editBuf$ + "_" Else t$ = Fmt$(v, 4)
    Line (110, y)-(274, y + 22), _RGB32(28, 28, 30), BF
    If editField = idx Then Line (110, y)-(274, y + 22), C_ACC, B Else Line (110, y)-(274, y + 22), C_HEAD, B
    Color C_ACC: _PrintString (116, y + 3), t$
    If gMouse.clicked And menuOpen = 0 And PtInRect%(gMouse.mx, gMouse.my, 110, y, 164, 22) Then
        If editField And editField <> idx Then CommitEdit
        editField = idx: editBuf$ = ""
    End If
    EditRow& = y + 28
End Function

' ZIP / postal code box: typing a code and Enter sets latitude and longitude
Function ZipRow& (y As Long)
    Dim t$
    Color C_TEXT: _PrintString (14, y + 4), "or ZIP"
    Line (110, y)-(274, y + 22), _RGB32(28, 28, 30), BF
    If editField = 3 Then
        Line (110, y)-(274, y + 22), C_ACC, B
        Color C_ACC: _PrintString (116, y + 3), editBuf$ + "_"
    Else
        Line (110, y)-(274, y + 22), C_HEAD, B
        Color C_DIM: _PrintString (116, y + 3), "type it, Enter"
    End If
    If gMouse.clicked And menuOpen = 0 And PtInRect%(gMouse.mx, gMouse.my, 110, y, 164, 22) Then
        If editField And editField <> 3 Then CommitEdit
        editField = 3: editBuf$ = ""
    End If
    ZipRow& = y + 28
End Function

'==================================================================
'  SITE FROM A ZIP / POSTAL CODE
'  (same lookup as AstroWeather: api.zippopotam.us, plain HTTP, free,
'   no key; curl over HTTPS as the fallback). The ZIP's centre is only
'   a general location - plenty for polar alignment, where the site is
'   used for the "up" / "east" directions and the refraction amount.
'==================================================================
Sub SiteFromZip (txt$)
    Dim path$, raw$, la As Double, lo As Double, nm$
    path$ = ZipPath$(txt$)
    If path$ = "" Then statusMsg$ = "Not a ZIP code: " + txt$ + "  (5 digits, or country + code like GB SW1A)": Exit Sub
    statusMsg$ = "Looking up " + txt$ + "...": DrawStatus: _Display
    httpStatus = 0
    raw$ = HttpGet$("api.zippopotam.us/" + path$)
    If Len(raw$) = 0 And (httpStatus = 0 Or (httpStatus >= 300 And httpStatus < 400)) Then raw$ = CurlGet$("api.zippopotam.us/" + path$)
    If Len(raw$) = 0 Then
        If httpStatus = 404 Then statusMsg$ = "ZIP " + txt$ + " not found." Else statusMsg$ = "ZIP lookup failed (no internet?) - type latitude / longitude instead."
        Exit Sub
    End If
    If ZipParse%(raw$, la, lo, nm$) = 0 Then statusMsg$ = "ZIP " + txt$ + " not found.": Exit Sub
    ' two decimals (about 1 km) - a general location is all that is needed
    latDeg = Int(la * 100 + 0.5) / 100: lonDeg = Int(lo * 100 + 0.5) / 100
    siteName$ = nm$ + " (ZIP " + _Trim$(txt$) + ")"
    If (latDeg < 0 And hemi = 1) Or (latDeg > 0 And hemi = -1) Then
        statusMsg$ = "Site set: " + nm$ + "  " + Fmt$(latDeg, 2) + ", " + Fmt$(lonDeg, 2) + "  - note: that is the other hemisphere's pole."
    Else
        statusMsg$ = "Site set: " + nm$ + "  " + Fmt$(latDeg, 2) + ", " + Fmt$(lonDeg, 2)
    End If
    SaveSettings
End Sub

' "85719" (or ZIP+4) -> "us/85719";  "GB SW1A 1AA" -> "gb/SW1A";  "" if not a code
Function ZipPath$ (txt As String)
    Dim t$, cc$, code$, ii As Long, allDigits As Long, sp As Long
    t$ = UCase$(_Trim$(txt))
    If Len(t$) = 10 And Mid$(t$, 6, 1) = "-" Then t$ = Left$(t$, 5)
    If Len(t$) = 5 Then
        allDigits = -1
        For ii = 1 To 5
            If Asc(t$, ii) < 48 Or Asc(t$, ii) > 57 Then allDigits = 0
        Next
        If allDigits Then ZipPath$ = "us/" + t$: Exit Function
    End If
    If Len(t$) >= 4 And Mid$(t$, 3, 1) = " " Then
        cc$ = Left$(t$, 2)
        If Asc(cc$, 1) >= 65 And Asc(cc$, 1) <= 90 And Asc(cc$, 2) >= 65 And Asc(cc$, 2) <= 90 Then
            code$ = _Trim$(Mid$(t$, 4))
            sp = InStr(code$, " ")
            If sp > 0 Then code$ = Left$(code$, sp - 1)
            If Len(code$) > 0 Then ZipPath$ = LCase$(cc$) + "/" + code$
        End If
    End If
End Function

' pull latitude, longitude and "Place, ST" out of a zippopotam.us reply
Function ZipParse% (raw$, lat As Double, lon As Double, nm$)
    Dim la$, lo$, pl$, st$
    la$ = JsonStr$(raw$, "latitude")
    lo$ = JsonStr$(raw$, "longitude")
    If Len(la$) = 0 Or Len(lo$) = 0 Then Exit Function
    If Val(la$) < -90 Or Val(la$) > 90 Or Val(lo$) < -180 Or Val(lo$) > 180 Then Exit Function
    lat = Val(la$): lon = Val(lo$)
    pl$ = JsonStr$(raw$, "place name")
    st$ = JsonStr$(raw$, "state abbreviation")
    nm$ = pl$
    If Len(pl$) > 0 And Len(st$) > 0 Then nm$ = pl$ + ", " + st$
    If nm$ = "" Then nm$ = "ZIP area"
    ZipParse% = -1
End Function

Function JsonStr$ (obj As String, fld As String)
    Dim p As Long, q As Long, a As Long, b As Long
    p = InStr(obj, Chr$(34) + fld + Chr$(34))
    If p = 0 Then Exit Function
    q = InStr(p, obj, ":")
    If q = 0 Then Exit Function
    q = q + 1
    Do While q <= Len(obj) And Mid$(obj, q, 1) = " "
        q = q + 1
    Loop
    If Mid$(obj, q, 1) = Chr$(34) Then
        a = q + 1
        b = InStr(a, obj, Chr$(34))
        If b = 0 Then Exit Function
        JsonStr$ = Mid$(obj, a, b - a)
    Else
        b = q
        Do While b <= Len(obj)
            If InStr(",}] " + Chr$(13) + Chr$(10), Mid$(obj, b, 1)) > 0 Then Exit Do
            b = b + 1
        Loop
        JsonStr$ = Mid$(obj, q, b - q)
    End If
End Function

Function HttpGet$ (url As String)
    Dim client As Long, st As Long, t0 As Double, chunk$, result$
    client = _OpenClient("HTTP:" + url)
    If client = 0 Then Exit Function
    st = _StatusCode(client)
    If st <> 200 Then httpStatus = st: Close client: Exit Function
    t0 = Timer
    Do While Not EOF(client)
        _Limit 60
        Get #client, , chunk$
        result$ = result$ + chunk$
        If Abs(Timer - t0) > 15 Then Exit Do
    Loop
    Close client
    HttpGet$ = result$
End Function

' fallback for when the server insists on HTTPS
Function CurlGet$ (url As String)
    Dim f$, fh As Long, r$
    f$ = exeDir$ + "zip_lookup.json"
    If _FileExists(f$) Then Kill f$
    Shell _Hide "curl -s -L -m 15 -o " + Chr$(34) + f$ + Chr$(34) + " " + Chr$(34) + "https://" + url + Chr$(34)
    If _FileExists(f$) = 0 Then Exit Function
    fh = FreeFile
    Open f$ For Binary As #fh
    r$ = Space$(LOF(fh))
    Get #fh, , r$
    Close #fh
    Kill f$
    CurlGet$ = r$
End Function

Function OnOff$ (f As Long)
    If f Then OnOff$ = "ON" Else OnOff$ = "OFF"
End Function

Sub SetHemi (h As Long)
    hemi = h
    LoadCatalog
    SaveSettings
    If camMode = 2 Then SimInit
End Sub

Sub ApplyCam
    Dim r As Long
    If camMode Then r = pm_set&(expMs, gainV)
    SaveSettings
End Sub

' next / previous value of a "|" list
Function ListStep& (lst$, cur As Long, dirn As Long)
    Dim vals(1 To 30) As Long, n As Long, p As Long, q As Long, i As Long
    q = 1
    Do
        p = InStr(q, lst$, "|")
        n = n + 1
        If p = 0 Then vals(n) = Val(Mid$(lst$, q)): Exit Do
        vals(n) = Val(Mid$(lst$, q, p - q)): q = p + 1
    Loop
    ListStep& = cur
    If dirn > 0 Then
        For i = 1 To n
            If vals(i) > cur Then ListStep& = vals(i): Exit Function
        Next
    Else
        For i = n To 1 Step -1
            If vals(i) < cur Then ListStep& = vals(i): Exit Function
        Next
    End If
End Function

Sub LogLine (t$)
    Dim ff As Long
    If logFile$ = "" Then Exit Sub
    ff = FreeFile
    Open logFile$ For Append As #ff
    If t$ = "" Or Left$(t$, 5) = "=====" Then Print #ff, t$ Else Print #ff, Time$; "  "; t$
    Close #ff
End Sub

' called once per frame of the main loop
Sub LogTick
    Dim a$, z$
    If logFile$ = "" Then Exit Sub
    If statusMsg$ <> lastLogged$ Then LogLine statusMsg$: lastLogged$ = statusMsg$
    If stage <> logStage Then
        logStage = stage
        LogLine "-- stage" + Str$(stage) + "   exposure" + Str$(expMs) + " ms  gain" + Str$(gainV) + "  camera mode" + Str$(camMode)
    End If
    ' error readout every 15 s while aligning (rough + precise)
    If (stage = 4 Or stage = 5) And errOK Then
        If Timer(0.01) - logErrT > 15 Or Timer(0.01) < logErrT Then
            logErrT = Timer(0.01)
            If errAlt >= 0 Then a$ = "RAISE " Else a$ = "LOWER "
            If errAz >= 0 Then z$ = "EAST " Else z$ = "WEST "
            a$ = "error: total " + Fmt$(errTot, 1) + "'  alt " + a$ + Fmt$(Abs(errAlt), 1) + "'  az " + z$ + Fmt$(Abs(errAz), 1) + "'"
            If trkLost Then a$ = a$ + "  (star lost)"
            LogLine a$
        End If
    End If
End Sub

Function Fmt$ (v As Double, dp As Long)
    Dim s$, m As Double
    m = 10 ^ dp
    s$ = _Trim$(Str$(Int(Abs(v) * m + 0.5) / m))
    If Left$(s$, 1) = "." Then s$ = "0" + s$
    If dp > 0 And InStr(s$, ".") = 0 Then s$ = s$ + "." + String$(dp, "0")
    If v < 0 And Val(s$) <> 0 Then s$ = "-" + s$
    Fmt$ = s$
End Function

Sub DrawHelp
    Dim x As Long, y As Long, w As Long, h As Long
    w = 640: h = 456: x = (SCR_W - w) \ 2: y = (SCR_H - h) \ 2
    Line (x, y)-(x + w, y + h), _RGB32(24, 24, 27), BF
    Line (x, y)-(x + w, y + h), C_ACC, B
    Color C_ACC: _PrintString (x + 16, y + 12), "PoleMasterQB - how to use"
    Color C_YEL
    _PrintString (x + 16, y + 40), "Before you start: mount in HOME position (counterweight down,"
    _PrintString (x + 16, y + 56), "scope at the pole), then power on the hand controller."
    Color C_TEXT
    _PrintString (x + 16, y + 72), "Rough polar align with a compass and the latitude scale, so"
    _PrintString (x + 16, y + 88), "the pole star is in the 11 x 8 deg view."
    _PrintString (x + 16, y + 112), "1  Connect, pick North/South, exposure and gain. Finished."
    _PrintString (x + 16, y + 132), "2  Double-click the pole star. Check the red circles. Success."
    _PrintString (x + 16, y + 152), "3  Double-click a bright star. Turn RA ~30 deg (hand controller),"
    _PrintString (x + 16, y + 168), "   Finished, double-click it again. Repeat (50-60 deg in total)."
    _PrintString (x + 16, y + 184), "   Slew back to HOME: the star should follow the green circle."
    _PrintString (x + 16, y + 204), "4  At home: double-click the pole star, Success. Move it into"
    _PrintString (x + 16, y + 220), "   the small green circle with the altitude / azimuth knobs."
    _PrintString (x + 16, y + 240), "5  Start Monitor. Bring the red circle onto the green circle."
    _PrintString (x + 16, y + 260), "6  Done: leave the mount at HOME and run the SynScan star"
    _PrintString (x + 16, y + 276), "   alignment. Not sure? Utility > Park Scope > Home Position."
    _PrintString (x + 16, y + 300), "Keep tracking ON. Do not move the mount with the clutches."
    _PrintString (x + 16, y + 324), "Keys: Left/Right rotate overlay (Shift = 5 deg), M mirror,"
    _PrintString (x + 16, y + 340), "      Z zoom, F1 this help, Esc close."
    _PrintString (x + 16, y + 364), "Simulator (Connect menu): a fake misaligned mount for practice."
    _PrintString (x + 16, y + 380), "Its panel has RA turn and alt/az knob buttons."
    Color C_DIM: _PrintString (x + 16, y + h - 26), "click anywhere to close"
    If gMouse.clicked Then helpOn = 0: gMouse.clicked = 0
End Sub

'==================================================================
'  SELF TEST (simulator, no user needed)
'==================================================================
Sub WaitFrames (n As Long)
    Dim f0 As Long, t0 As Double
    If simDirty Then SimSendStars
    ReadInfo: f0 = frames: t0 = Timer(0.001)
    Do
        _Delay 0.02
        ReadInfo
        If Timer(0.001) - t0 > 10 Then Exit Do
    Loop Until frames >= f0 + n
    UpdateCamera
End Sub

Sub Snap (tag$)
    PollMouseEx
    Cls , C_BG
    DrawImage: DrawPanel: DrawStatus: DrawMenu
    _Display
    If selfSouth Then tag$ = tag$ + "_south"
    _SaveImage exeDir$ + "selftest_" + tag$ + ".png", 0
End Sub

Sub Say (t$)
    _Echo t$
End Sub

Sub RunSelfTest
    Dim x As Double, y As Double, ok As Long, i As Long, best As Double, bi As Long, d As Double
    Dim px As Double, py As Double, t As Double, ta As Double, tz As Double, ax As Double, ay As Double
    Dim fails As Long, k As Long, ev As Long
    Say "PoleMasterQB self test  (libpmcam version" + Str$(pm_version&) + ")"
    Dim zr$, zla As Double, zlo As Double, znm$
    zr$ = "{" + Chr$(34) + "post code" + Chr$(34) + ": " + Chr$(34) + "85719" + Chr$(34) + ", " + Chr$(34) + "places" + Chr$(34) + ": [{" + Chr$(34) + "place name" + Chr$(34) + ": " + Chr$(34) + "Tucson" + Chr$(34) + ", " + Chr$(34) + "longitude" + Chr$(34) + ": " + Chr$(34) + "-110.9493" + Chr$(34) + ", " + Chr$(34) + "state abbreviation" + Chr$(34) + ": " + Chr$(34) + "AZ" + Chr$(34) + ", " + Chr$(34) + "latitude" + Chr$(34) + ": " + Chr$(34) + "32.2474" + Chr$(34) + "}]}"
    If ZipPath$("85719") <> "us/85719" Or ZipPath$("85719-1234") <> "us/85719" Or ZipPath$("GB SW1A 1AA") <> "gb/SW1A" Or ZipPath$("abc") <> "" Then fails = fails + 1: Say "FAIL: ZipPath$"
    If ZipParse%(zr$, zla, zlo, znm$) = 0 Or Abs(zla - 32.2474) > 0.00001 Or Abs(zlo + 110.9493) > 0.00001 Or znm$ <> "Tucson, AZ" Then fails = fails + 1: Say "FAIL: ZipParse%" Else Say "ZIP parse: " + znm$ + "  " + Fmt$(zla, 4) + ", " + Fmt$(zlo, 4)
    If selfSouth Then Say "Hemisphere: SOUTH" Else Say "Hemisphere: NORTH"
    expMs = 1000: gainV = 40
    ConnectCamera -1
    If camMode <> 2 Then Say "FAIL: simulator did not open: " + LibErr$: System 1
    WaitFrames 2
    SimTruth t, ta, tz
    Say "Simulated mount error: total " + Fmt$(t, 2) + "'  alt " + Fmt$(ta, 2) + "'  az " + Fmt$(tz, 2) + "'"

    '--- 2: double-click the pole star
    stage = 2
    SimPix catVX(1), catVY(1), catVZ(1), px, py, ok
    MatchAt px + 3, py - 2, -1
    If modelOK = 0 Then Say "FAIL: pattern match: " + statusMsg$: System 1
    Say "Match: " + statusMsg$ + "   mirror" + Str$(mF)
    ' check the overlay against the truth
    best = 0
    For i = 2 To catN
        ModelPix catXi(i), catEta(i), x, y
        SimPix catVX(i), catVY(i), catVZ(i), ax, ay, ok
        If ok And x > 0 And y > 0 And x < frW And y < frH Then
            d = Sqr((x - ax) ^ 2 + (y - ay) ^ 2)
            If d > best Then best = d
        End If
    Next
    Say "Overlay worst star error vs truth: " + Fmt$(best, 2) + " px"
    If best > 1.5 Then fails = fails + 1: Say "  ^ FAIL (more than 1.5 px)"
    Snap "2match"

    '--- 3: RA axis from three positions 30 deg apart
    stage = 3: RaReset
    bi = 0: best = 99
    For i = 2 To catN
        SimPix catVX(i), catVY(i), catVZ(i), x, y, ok
        d = Sqr((x - px) ^ 2 + (y - py) ^ 2)
        If ok And d > 180 And d < 380 And x > 60 And y > 60 And x < frW - 60 And y < frH - 60 And catMag(i) < best Then best = catMag(i): bi = i
    Next
    For k = 1 To 3
        If k > 1 Then SimRotateRA 30: WaitFrames 2
        SimPix catVX(bi), catVY(bi), catVZ(bi), x, y, ok
        ImageDoubleClick x + 2, y + 1
        If k < 3 Then subStep = 2
    Next
    If raOK = 0 Then Say "FAIL: RA axis: " + statusMsg$: System 1
    SimAxisPix ax, ay, ok
    d = Sqr((raCX - ax) ^ 2 + (raCY - ay) ^ 2)
    Say "RA axis: " + statusMsg$
    Say "RA axis centre error vs truth: " + Fmt$(d, 2) + " px  (" + Fmt$(d * mScaleAS, 1) + Chr$(34) + ")"
    If d * mScaleAS > 20 Then fails = fails + 1: Say "  ^ FAIL (more than 20 arcsec)"
    Snap "3axis"
    SimRotateRA -60: WaitFrames 2

    '--- 4: rough
    stage = 4: subStep = 0
    SimPix catVX(1), catVY(1), catVZ(1), px, py, ok
    ImageDoubleClick px - 2, py + 2
    If modelOK = 0 Then Say "FAIL: re-match: " + statusMsg$: System 1
    Snap "4rematch"
    subStep = 1: WaitFrames 2
    Snap "4rough"
    SimTruth t, ta, tz
    Say "Rough: app says total " + Fmt$(errTot, 2) + "' alt " + Fmt$(errAlt, 2) + "' az " + Fmt$(errAz, 2) + "'   truth " + Fmt$(t, 2) + "' / " + Fmt$(ta, 2) + "' / " + Fmt$(tz, 2) + "'"
    If Abs(errTot - t) > 0.5 Or Abs(errAlt - ta) > 0.5 Or Abs(errAz - tz) > 0.5 Then fails = fails + 1: Say "  ^ FAIL (more than 0.5' off)"
    ' turn the knobs as told (90% of it, like a person would)
    ta = errAlt * 0.9: tz = errAz * 0.9
    For k = 1 To 10
        SimAdjust ta / 10, tz / 10
        WaitFrames 1
    Next
    WaitFrames 2
    SimTruth t, ta, tz
    Say "After knobs: app " + Fmt$(errTot, 2) + "'  truth " + Fmt$(t, 2) + "'"

    '--- 5: precise
    stage = 5: subStep = 0
    StartMonitor
    If subStep <> 1 Then Say "FAIL: monitor: " + statusMsg$: System 1
    SimAdjust errAlt, errAz
    WaitFrames 3
    SimTruth t, ta, tz
    Say "Precise: app total " + Fmt$(errTot * 60, 1) + Chr$(34) + " (alt " + Fmt$(errAlt * 60, 1) + Chr$(34) + ", az " + Fmt$(errAz * 60, 1) + Chr$(34) + ")   truth " + Fmt$(t * 60, 1) + Chr$(34)
    If t * 60 > 30 Then fails = fails + 1: Say "  ^ FAIL (final true error over 30 arcsec)"

    ' screenshot of the screen as the user would see it
    PollMouseEx
    Cls , C_BG
    DrawImage: DrawPanel: DrawStatus: DrawMenu
    _Display
    If selfSouth Then _SaveImage exeDir$ + "selftest_south.png", 0 Else _SaveImage exeDir$ + "selftest.png", 0
    pm_close
    If fails = 0 Then Say "SELF TEST PASSED" Else Say "SELF TEST: " + _Trim$(Str$(fails)) + " FAIL(S)"
    If fails Then System 1
End Sub

'ButtonUI routines
'$Include:'ButtonUI.bm'
