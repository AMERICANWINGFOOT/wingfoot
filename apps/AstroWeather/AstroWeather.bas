'---------------------------------------------------------------
' AstroWeather.bas - Astronomy weather planner for QB64-PE
' (Windows/Linux).
'
' Forecast: 7Timer! ASTRO product (cloud cover, seeing,
' transparency, wind, humidity, temperature) over plain HTTP, no
' key needed. Sun and Moon (twilight, moonrise/set, phase, dark
' window) are computed locally, so they work offline.
'
' Keys: R refresh, L set the location (map, or T to type it), N red night mode,
' U units, Q or Esc quit
'
' Needs WorldMap.bi (coastline data for the map) in the same folder.
' The chosen site is kept in AstroWeather.ini next to the program.
'
' Command line: the word red starts in night mode. The word test
' reads astro_sample.json instead of the network, saves a
' screenshot (astro_shot.png) and exits.
'---------------------------------------------------------------

'~~~ Settings ~~~
' The site is normally set with the Location button and kept in
' AstroWeather.ini. These are only the defaults used until that file
' exists.
Const DEF_NAME = "Kitt Peak, AZ"
Const DEF_LAT = 31.958#
Const DEF_LON = -111.597#
' Time zone of the PC clock: hours from UTC in standard time. Every
' time on screen is shown in PC clock time, wherever the site is.
Const DEF_TZ = -5
' -1 = apply the US daylight saving rules, 0 = never
Const DEF_DST = -1
' Seconds between updates. 7Timer refreshes about 4 times a day,
' so there is no point going below 1800.
Const REFRESH_SECS = 3600
' Seconds before retrying after a failed update
Const RETRY_SECS = 120

' Internal constants
Const MAXSTEP = 24
Const NSAMP = 288
Const STEP_MIN = 5
Const D2R = 0.017453292519943295#
Const GX = 120
Const CW = 36
Const GY = 216
Const GRY = 252
Const ROWH = 24
Const MAPW = 1000
Const MAPH = 500
Const MINZOOM = 2.78#
Const MAXZOOM = 2000#
Const MAXPTS = 5000
Const MAXRING = 160

' Palette slots
Const P_BG = 0, P_TEXT = 1, P_DIM = 2, P_ACC = 3, P_WARN = 4
Const P_BTN = 5, P_BTNHOT = 6
Const P_L0 = 7
Const P_S0 = 12
Const P_MOON = 17

Dim Shared As String errMsg, statusMsg, stamp, initTxt
Dim Shared As String lnSun, lnMoon, lnDark, lnDso, lnLunar
Dim Shared As Long hasData, mx, my, mb, prevMb, clicked, secsLeft
Dim Shared As Long actRefresh, actUnits, actQuit, actRed, actLoc, pickAct
Dim Shared As String obsName, entryTxt, entryMsg, entryName
Dim Shared As Long entryOn, zipTest
Dim Shared As Double obsLat, obsLon, clockTz
Dim Shared As Long clockDst, nRings, nWorldPts
Dim Shared wLon(0 To MAXPTS) As Long
Dim Shared wLat(0 To MAXPTS) As Long
Dim Shared ringStart(0 To MAXRING + 1) As Long
Dim Shared As Long redMode, fahr, testMode, nSteps, firstCol
Dim Shared As Long bestDso, bestLunar, httpStatus
Dim Shared As Double initJD, winStart, moonIllum, tlNow
Dim Shared stepJD(1 To MAXSTEP) As Double
Dim Shared colSun(1 To MAXSTEP) As Double
Dim Shared colMoon(1 To MAXSTEP) As Double
Dim Shared sCloud(1 To MAXSTEP) As Long
Dim Shared sSeeing(1 To MAXSTEP) As Long
Dim Shared sTransp(1 To MAXSTEP) As Long
Dim Shared sWind(1 To MAXSTEP) As Long
Dim Shared sRh(1 To MAXSTEP) As Long
Dim Shared sTemp(1 To MAXSTEP) As Double
Dim Shared sPrec(1 To MAXSTEP) As String
Dim Shared sunA(0 To NSAMP) As Double
Dim Shared moonA(0 To NSAMP) As Double
Dim Shared pcol(0 To 24) As _Unsigned Long

If InStr(UCase$(Command$), "TEST") Then testMode = -1
If InStr(UCase$(Command$), "ZIPSAMPLE") Then zipTest = -1
fahr = -1
obsName = DEF_NAME
obsLat = DEF_LAT
obsLon = DEF_LON
clockTz = DEF_TZ
clockDst = DEF_DST
LoadSettings
If InStr(UCase$(Command$), "RED") Then redMode = -1
SetPalette redMode

Screen _NewImage(1000, 600, 32)
_Title "Astro Weather"

Dim As Long quitFlag, kk, pending, interval, sawDown
Dim As Double lastFetch, lastCalc, elapsed
Dim As Long rr, rk, rnp, rx, ry, rdx, rdy

' coastline for the location map (READ has to happen in the main
' module, where the WorldData label lives)
Restore WorldData
Read nRings
nWorldPts = 0
For rr = 1 To nRings
    Read rnp
    ringStart(rr) = nWorldPts
    Read rx, ry
    wLon(nWorldPts) = rx
    wLat(nWorldPts) = ry
    nWorldPts = nWorldPts + 1
    For rk = 2 To rnp
        Read rdx, rdy
        rx = rx + rdx
        ry = ry + rdy
        wLon(nWorldPts) = rx
        wLat(nWorldPts) = ry
        nWorldPts = nWorldPts + 1
    Next
Next
ringStart(nRings + 1) = nWorldPts

interval = REFRESH_SECS
pending = -1
lastFetch = Timer
lastCalc = Timer
Recalc

Do
    If _Exit Then quitFlag = -1

    ' mouse state, once per frame. A press that begins and ends inside
    ' one frame (a quick tap) still counts as a click.
    sawDown = 0
    Do While _MouseInput
        If _MouseButton(1) Then sawDown = -1
    Loop
    mx = _MouseX
    my = _MouseY
    mb = _MouseButton(1)
    clicked = (prevMb = 0) And ((mb <> 0) Or sawDown)
    prevMb = mb

    ' countdowns (both handle the midnight rollover of TIMER)
    elapsed = Timer - lastFetch
    If elapsed < 0 Then elapsed = elapsed + 86400
    secsLeft = interval - Int(elapsed)
    If secsLeft <= 0 Then pending = -1

    elapsed = Timer - lastCalc
    If elapsed < 0 Then elapsed = elapsed + 86400
    If elapsed >= 30 Then
        Recalc
        lastCalc = Timer
    End If

    DrawScreen
    _Display

    ' keyboard
    kk = _KeyHit
    Select Case kk
        Case 27, 81, 113: actQuit = -1
        Case 82, 114: actRefresh = -1
        Case 85, 117: actUnits = -1
        Case 78, 110: actRed = -1
        Case 76, 108: actLoc = -1
    End Select

    If actRefresh Then pending = -1
    If actUnits Then
        If fahr Then fahr = 0 Else fahr = -1
    End If
    If actRed Then
        If redMode Then redMode = 0 Else redMode = -1
        SetPalette redMode
    End If
    If actQuit Then quitFlag = -1
    If actLoc Then
        If PickLocation% Then
            SaveSettings
            hasData = 0
            nSteps = 0
            initTxt = ""
            stamp = ""
            errMsg = ""
            pending = -1
            Recalc
            lastCalc = Timer
        End If
        ' the button may still be held down; do not count it as a new click
        prevMb = -1
        clicked = 0
    End If
    actRefresh = 0
    actUnits = 0
    actRed = 0
    actQuit = 0
    actLoc = 0

    If pending <> 0 And quitFlag = 0 Then
        statusMsg = "Updating..."
        clicked = 0
        DrawScreen
        _Display
        If FetchAstro% Then interval = REFRESH_SECS Else interval = RETRY_SECS
        Recalc
        lastCalc = Timer
        lastFetch = Timer
        statusMsg = ""
        pending = 0
        If testMode Then
            DrawScreen
            _Display
            _SaveImage "astro_shot.png", 0
            If InStr(UCase$(Command$), "PICK") Then
                DrawPicker obsLon, obsLat, 40, obsLon, obsLat, 0, 0, 0
                _Display
                _SaveImage "astro_pick.png", 0
                DrawPicker 0, 0, MINZOOM, obsLon, obsLat, -1, 12.345#, 45.678#
                _Display
                _SaveImage "astro_world.png", 0
            End If
            quitFlag = -1
        End If
    End If

    _Limit 30
Loop Until quitFlag
System

'$Include:'WorldMap.bi'

'---------------------------------------------------------------
' Palette
'---------------------------------------------------------------
Sub SetPalette (redOn As Long)
    If redOn Then
        ' red only, to protect dark adaptation: brighter = better
        pcol(P_BG) = _RGB32(6, 0, 0)
        pcol(P_TEXT) = _RGB32(255, 60, 60)
        pcol(P_DIM) = _RGB32(150, 30, 30)
        pcol(P_ACC) = _RGB32(255, 80, 80)
        pcol(P_WARN) = _RGB32(255, 110, 110)
        pcol(P_BTN) = _RGB32(40, 0, 0)
        pcol(P_BTNHOT) = _RGB32(80, 0, 0)
        pcol(P_L0) = _RGB32(230, 40, 40)
        pcol(P_L0 + 1) = _RGB32(185, 30, 30)
        pcol(P_L0 + 2) = _RGB32(140, 24, 24)
        pcol(P_L0 + 3) = _RGB32(100, 16, 16)
        pcol(P_L0 + 4) = _RGB32(60, 8, 8)
        pcol(P_S0) = _RGB32(150, 20, 20)
        pcol(P_S0 + 1) = _RGB32(100, 12, 12)
        pcol(P_S0 + 2) = _RGB32(60, 8, 8)
        pcol(P_S0 + 3) = _RGB32(32, 4, 4)
        pcol(P_S0 + 4) = _RGB32(12, 0, 0)
        pcol(P_MOON) = _RGB32(200, 40, 40)
    Else
        pcol(P_BG) = _RGB32(12, 15, 20)
        pcol(P_TEXT) = _RGB32(225, 230, 240)
        pcol(P_DIM) = _RGB32(120, 130, 148)
        pcol(P_ACC) = _RGB32(90, 180, 255)
        pcol(P_WARN) = _RGB32(255, 190, 80)
        pcol(P_BTN) = _RGB32(34, 40, 54)
        pcol(P_BTNHOT) = _RGB32(52, 62, 84)
        pcol(P_L0) = _RGB32(30, 150, 90)
        pcol(P_L0 + 1) = _RGB32(110, 170, 60)
        pcol(P_L0 + 2) = _RGB32(200, 175, 45)
        pcol(P_L0 + 3) = _RGB32(220, 115, 40)
        pcol(P_L0 + 4) = _RGB32(200, 55, 55)
        pcol(P_S0) = _RGB32(95, 150, 215)
        pcol(P_S0 + 1) = _RGB32(60, 100, 170)
        pcol(P_S0 + 2) = _RGB32(38, 62, 118)
        pcol(P_S0 + 3) = _RGB32(24, 36, 78)
        pcol(P_S0 + 4) = _RGB32(10, 14, 38)
        pcol(P_MOON) = _RGB32(200, 195, 140)
    End If
End Sub

'---------------------------------------------------------------
' Drawing
'---------------------------------------------------------------
Sub DrawScreen
    Dim As Long c, ii, x0, nShow, lv, hh, prevHh, sl
    Dim As String hdr, t, windList
    Dim As Double tc, rhp, gap, tdisp

    Cls , pcol(P_BG)

    ' header
    Color pcol(P_ACC), pcol(P_BG)
    _PrintString (16, 12), "Astro Weather - " + obsName
    hdr = ""
    If Len(initTxt) Then hdr = initTxt + "   "
    If Len(stamp) Then hdr = hdr + "Updated " + stamp
    Color pcol(P_DIM), pcol(P_BG)
    _PrintString (1000 - 16 - Len(hdr) * 8, 12), hdr
    Line (0, 38)-(999, 38), pcol(P_DIM)

    ' summary lines
    InfoLine 46, "Sun", lnSun, pcol(P_TEXT)
    InfoLine 66, "Moon", lnMoon, pcol(P_TEXT)
    InfoLine 86, "Dark", lnDark, pcol(P_TEXT)
    InfoLine 106, "^D", lnDso, pcol(P_ACC)
    InfoLine 126, "^M", lnLunar, pcol(P_ACC)

    ' tonight timeline, local noon to local noon
    Color pcol(P_DIM), pcol(P_BG)
    _PrintString (16, 160), "Tonight"
    _PrintString (16, 176), "Moon up"
    For ii = 0 To NSAMP - 1
        Line (GX + ii * 3, 160)-(GX + ii * 3 + 2, 179), pcol(P_S0 + SkyClass%(sunA(ii))), BF
        If moonA(ii) > -0.833# Then Line (GX + ii * 3, 182)-(GX + ii * 3 + 2, 187), pcol(P_MOON), BF
    Next
    Color pcol(P_DIM), pcol(P_BG)
    For ii = 0 To 24 Step 2
        x0 = GX + ii * 36
        Line (x0, 188)-(x0, 191), pcol(P_DIM)
        _PrintString (x0 - 8, 194), Fmt2$(LocalHour%(winStart + ii / 24#))
    Next
    If tlNow >= 0 And tlNow <= NSAMP Then
        x0 = GX + Int(tlNow * 3)
        Line (x0, 156)-(x0, 190), pcol(P_TEXT)
    End If

    ' forecast grid
    If hasData = 0 Then
        Color pcol(P_DIM), pcol(P_BG)
        _PrintString (16, GRY + 8), "Waiting for the first forecast..."
    Else
        nShow = nSteps - firstCol + 1
        If nShow < 0 Then nShow = 0
        If nShow = 0 Then
            Color pcol(P_WARN), pcol(P_BG)
            _PrintString (16, GRY + 8), "Forecast has expired - press R to refresh."
        End If

        Color pcol(P_DIM), pcol(P_BG)
        _PrintString (16, GRY + 4), "Sky"
        _PrintString (16, GRY + ROWH + 4), "Moon alt"
        _PrintString (16, GRY + 2 * ROWH + 4), "Cloud %"
        _PrintString (16, GRY + 3 * ROWH + 4), "Seeing"
        _PrintString (16, GRY + 4 * ROWH + 4), "Transp"
        _PrintString (16, GRY + 5 * ROWH + 4), "Wind"
        _PrintString (16, GRY + 6 * ROWH + 4), "Humid %"
        _PrintString (16, GRY + 7 * ROWH + 4), "Dew gap"
        _PrintString (16, GRY + 8 * ROWH + 4), "Temp"
        _PrintString (16, GRY + 9 * ROWH + 4), "Precip"

        If fahr Then windList = "0,4,13,21,31,46,64,80" Else windList = "0,2,6,9,14,21,29,36"

        prevHh = -1
        For c = 1 To nShow
            ii = firstCol + c - 1
            x0 = GX + (c - 1) * CW
            hh = LocalHour%(stepJD(ii))

            ' header: weekday at each new day, hour on every column
            ' (the first label needs two columns of room before midnight)
            If (c = 1 And hh <= 18) Or (c > 1 And hh < prevHh) Then
                Color pcol(P_ACC), pcol(P_BG)
                _PrintString (x0 + 2, GY), WdAbbr$(LocalWd%(stepJD(ii))) + Str$(LocalDay%(stepJD(ii)))
            End If
            If c > 1 And hh < prevHh Then Line (x0 - 1, GY)-(x0 - 1, GRY + 10 * ROWH), pcol(P_DIM)
            prevHh = hh
            Color pcol(P_TEXT), pcol(P_BG)
            _PrintString (x0 + (CW - 16) \ 2, GY + 18), Fmt2$(hh)

            ' sky and moon
            Cell x0, GRY, CW, ROWH, pcol(P_S0 + SkyClass%(colSun(ii))), ""
            If colMoon(ii) > 0 Then
                Cell x0, GRY + ROWH, CW, ROWH, pcol(P_MOON), _Trim$(Str$(Int(colMoon(ii))))
            Else
                Cell x0, GRY + ROWH, CW, ROWH, pcol(P_BTN), ""
            End If

            ' rated rows
            DataCell x0, GRY + 2 * ROWH, sCloud(ii), "0,0,1,2,2,3,3,4,4", "3,12,25,37,50,62,75,87,97"
            DataCell x0, GRY + 3 * ROWH, sSeeing(ii), "0,0,1,2,3,3,4,4", "<0.5,0.6,0.9,1.1,1.4,1.7,2.2,>2.5"
            DataCell x0, GRY + 4 * ROWH, sTransp(ii), "0,0,1,2,2,3,4,4", "<0.3,0.35,0.45,0.55,0.65,0.78,0.92,>1.0"
            DataCell x0, GRY + 5 * ROWH, sWind(ii), "0,0,1,2,3,4,4,4", windList

            ' humidity and dew gap
            rhp = RhPct#(sRh(ii))
            If rhp < 0 Then
                Cell x0, GRY + 6 * ROWH, CW, ROWH, pcol(P_BTN), "-"
                Cell x0, GRY + 7 * ROWH, CW, ROWH, pcol(P_BTN), "-"
            Else
                If rhp < 60 Then
                    lv = 0
                ElseIf rhp < 75 Then
                    lv = 1
                ElseIf rhp < 85 Then
                    lv = 2
                ElseIf rhp < 93 Then
                    lv = 3
                Else
                    lv = 4
                End If
                Cell x0, GRY + 6 * ROWH, CW, ROWH, pcol(P_L0 + lv), _Trim$(Str$(Int(rhp + 0.5)))

                tc = sTemp(ii)
                gap = tc - DewPoint#(tc, rhp)
                If gap > 5 Then
                    lv = 0
                ElseIf gap > 3 Then
                    lv = 1
                ElseIf gap > 2 Then
                    lv = 2
                ElseIf gap > 1 Then
                    lv = 3
                Else
                    lv = 4
                End If
                If fahr Then gap = gap * 1.8#
                Cell x0, GRY + 7 * ROWH, CW, ROWH, pcol(P_L0 + lv), Dec1$(gap)
            End If

            ' temperature
            tdisp = sTemp(ii)
            If fahr Then tdisp = tdisp * 1.8# + 32
            Cell x0, GRY + 8 * ROWH, CW, ROWH, pcol(P_BTN), _Trim$(Str$(Int(tdisp + 0.5)))

            ' precipitation
            If sPrec(ii) = "none" Or Len(sPrec(ii)) = 0 Then
                Cell x0, GRY + 9 * ROWH, CW, ROWH, pcol(P_L0), ""
            Else
                Cell x0, GRY + 9 * ROWH, CW, ROWH, pcol(P_L0 + 4), UCase$(Left$(sPrec(ii), 4))
            End If

            ' best-slot markers
            Color pcol(P_ACC), pcol(P_BG)
            If ii = bestDso Then _PrintString (x0 + 10, GRY + 10 * ROWH + 2), "^D"
            If ii = bestLunar Then _PrintString (x0 + 10, GRY + 10 * ROWH + 2), "^M"
        Next

        ' legend
        Color pcol(P_DIM), pcol(P_BG)
        If fahr Then
            t = "Cloud %, seeing arcsec, transp mag/airmass, wind mph, temp F, dew gap = temp - dew point (F)."
        Else
            t = "Cloud %, seeing arcsec, transp mag/airmass, wind m/s, temp C, dew gap = temp - dew point (C)."
        End If
        If redMode Then t = t + "  Brighter = better." Else t = t + "  Green = best, red = worst."
        _PrintString (16, GRY + 10 * ROWH + 22), t
    End If

    ' status line
    sl = secsLeft
    If sl < 0 Then sl = 0
    If Len(statusMsg) Then
        Color pcol(P_ACC), pcol(P_BG)
        _PrintString (16, 536), statusMsg
    ElseIf Len(errMsg) Then
        Color pcol(P_WARN), pcol(P_BG)
        _PrintString (16, 536), errMsg + " - retry in" + Str$(sl) + "s"
    Else
        Color pcol(P_DIM), pcol(P_BG)
        _PrintString (16, 536), "Next update in" + Str$(sl) + "s"
    End If

    ' buttons (immediate mode: drawn and tested in one call)
    If DrawBtn%(16, 558, 150, 32, "Refresh (R)") Then actRefresh = -1
    If DrawBtn%(180, 558, 170, 32, "Red mode (N)") Then actRed = -1
    If fahr Then
        If DrawBtn%(364, 558, 150, 32, "Units: F (U)") Then actUnits = -1
    Else
        If DrawBtn%(364, 558, 150, 32, "Units: C (U)") Then actUnits = -1
    End If
    If DrawBtn%(528, 558, 170, 32, "Location (L)") Then actLoc = -1
    If DrawBtn%(850, 558, 134, 32, "Quit (Q)") Then actQuit = -1
End Sub

Sub InfoLine (yy As Long, lbl As String, vv As String, clr As _Unsigned Long)
    Color pcol(P_DIM), pcol(P_BG)
    _PrintString (16, yy), lbl
    Color clr, pcol(P_BG)
    _PrintString (64, yy), vv
End Sub

Sub Cell (xx As Long, yy As Long, ww As Long, hh As Long, fillc As _Unsigned Long, txt As String)
    Line (xx, yy)-(xx + ww - 2, yy + hh - 2), fillc, BF
    If Len(txt) Then
        Color TextOn~&(fillc), fillc
        _PrintString (xx + (ww - 1 - Len(txt) * 8) \ 2, yy + (hh - 1 - 16) \ 2), txt
    End If
End Sub

' One rated cell: level and text both looked up by the 1-based code
Sub DataCell (xx As Long, yy As Long, code As Long, levels As String, texts As String)
    If code < 1 Then
        Cell xx, yy, CW, ROWH, pcol(P_BTN), "-"
    Else
        Cell xx, yy, CW, ROWH, pcol(P_L0 + Val(Tbl$(levels, code))), Tbl$(texts, code)
    End If
End Sub

Function TextOn~& (bgc As _Unsigned Long)
    Dim As Double lum
    lum = 0.299# * _Red32(bgc) + 0.587# * _Green32(bgc) + 0.114# * _Blue32(bgc)
    If redMode Then
        If lum > 45 Then TextOn~& = _RGB32(0, 0, 0) Else TextOn~& = pcol(P_TEXT)
    Else
        If lum > 120 Then TextOn~& = _RGB32(8, 10, 14) Else TextOn~& = _RGB32(240, 244, 250)
    End If
End Function

Function DrawBtn% (xx As Long, yy As Long, ww As Long, hh As Long, lbl As String)
    Dim As Long hot, res
    Dim As _Unsigned Long fillc
    hot = (mx >= xx) And (mx < xx + ww) And (my >= yy) And (my < yy + hh)
    If hot Then fillc = pcol(P_BTNHOT) Else fillc = pcol(P_BTN)
    Line (xx, yy)-(xx + ww - 1, yy + hh - 1), fillc, BF
    Line (xx, yy)-(xx + ww - 1, yy + hh - 1), pcol(P_DIM), B
    Color pcol(P_TEXT), fillc
    _PrintString (xx + (ww - Len(lbl) * 8) \ 2, yy + (hh - 16) \ 2), lbl
    res = hot And clicked
    DrawBtn% = res
End Function

' idx-th (1-based) item of a comma-separated list
Function Tbl$ (csv As String, idx As Long)
    Dim As Long ii, p1, p2
    If idx < 1 Then Exit Function
    p1 = 1
    For ii = 2 To idx
        p1 = InStr(p1, csv, ",")
        If p1 = 0 Then Exit Function
        p1 = p1 + 1
    Next
    p2 = InStr(p1, csv, ",")
    If p2 = 0 Then Tbl$ = Mid$(csv, p1) Else Tbl$ = Mid$(csv, p1, p2 - p1)
End Function

' Number with exactly one decimal (avoids float noise like 9.300000000000001)
Function Dec1$ (x As Double)
    Dim As Long k
    k = Int(Abs(x) * 10 + 0.5#)
    If x < 0 And k > 0 Then
        Dec1$ = "-" + _Trim$(Str$(k \ 10)) + "." + _Trim$(Str$(k Mod 10))
    Else
        Dec1$ = _Trim$(Str$(k \ 10)) + "." + _Trim$(Str$(k Mod 10))
    End If
End Function

Function Fmt2$ (n As Long)
    Fmt2$ = Right$("0" + _Trim$(Str$(n)), 2)
End Function

Function WdAbbr$ (wd As Long)
    WdAbbr$ = Mid$("SunMonTueWedThuFriSat", wd * 3 + 1, 3)
End Function

'---------------------------------------------------------------
' Sky classes: 0 day, 1 civil, 2 nautical, 3 astronomical, 4 night
'---------------------------------------------------------------
Function SkyClass% (alt As Double)
    If alt > -0.833# Then
        SkyClass% = 0
    ElseIf alt > -6 Then
        SkyClass% = 1
    ElseIf alt > -12 Then
        SkyClass% = 2
    ElseIf alt > -18 Then
        SkyClass% = 3
    Else
        SkyClass% = 4
    End If
End Function

'---------------------------------------------------------------
' Time helpers (all times are UTC Julian dates unless noted)
'---------------------------------------------------------------
Function JulianDay# (y As Double, m As Double, d As Double, hh As Double)
    Dim As Double a, yy, mm, jdn
    a = Int((14 - m) / 12)
    yy = y + 4800 - a
    mm = m + 12 * a - 3
    jdn = d + Int((153 * mm + 2) / 5) + 365 * yy + Int(yy / 4) - Int(yy / 100) + Int(yy / 400) - 32045
    JulianDay# = jdn - 0.5# + hh / 24
End Function

Sub JDToDate (jd As Double, yr As Long, mo As Long, dy As Long, hrs As Double)
    Dim As Double z, f, alpha, aa, bb, cc, dd, ee
    z = Int(jd + 0.5#)
    f = jd + 0.5# - z
    alpha = Int((z - 1867216.25#) / 36524.25#)
    aa = z + 1 + alpha - Int(alpha / 4)
    bb = aa + 1524
    cc = Int((bb - 122.1#) / 365.25#)
    dd = Int(365.25# * cc)
    ee = Int((bb - dd) / 30.6001#)
    dy = Int(bb - dd - Int(30.6001# * ee))
    If ee < 14 Then mo = ee - 1 Else mo = ee - 13
    If mo > 2 Then yr = cc - 4716 Else yr = cc - 4715
    hrs = f * 24
End Sub

' JD (0h UTC) of the nth Sunday of a month
Function NthSunday# (yr As Double, mo As Double, nth As Double)
    Dim As Double jd1, wd, firstSun
    jd1 = JulianDay#(yr, mo, 1, 0)
    wd = Int(jd1 + 1.5#) Mod 7
    firstSun = 1 + (7 - wd) Mod 7
    NthSunday# = JulianDay#(yr, mo, firstSun + 7 * (nth - 1), 0)
End Function

' Site UTC offset in hours at a UTC Julian date
Function UtcOffset# (jdUtc As Double)
    Dim As Long yr, mo, dy
    Dim As Double hrs, jdStd, dstStart, dstEnd
    UtcOffset# = clockTz
    If clockDst = 0 Then Exit Function
    jdStd = jdUtc + clockTz / 24
    JDToDate jdStd, yr, mo, dy, hrs
    dstStart = NthSunday#(CDbl(yr), 3, 2) + (2 - clockTz) / 24
    dstEnd = NthSunday#(CDbl(yr), 11, 1) + (2 - (clockTz + 1)) / 24
    If jdUtc >= dstStart And jdUtc < dstEnd Then UtcOffset# = clockTz + 1
End Function

' PC clock (assumed site-local time) as a UTC Julian date
Function ClockJD#
    Dim As String d, t
    Dim As Double jl
    d = Date$
    t = Time$
    jl = JulianDay#(Val(Mid$(d, 7, 4)), Val(Left$(d, 2)), Val(Mid$(d, 4, 2)), Val(Left$(t, 2)) + Val(Mid$(t, 4, 2)) / 60 + Val(Right$(t, 2)) / 3600)
    ClockJD# = jl - UtcOffset#(jl - clockTz / 24) / 24
End Function

Function LocalHour% (jdUtc As Double)
    Dim As Long yr, mo, dy
    Dim As Double hrs
    JDToDate jdUtc + UtcOffset#(jdUtc) / 24 + 0.0003#, yr, mo, dy, hrs
    LocalHour% = Int(hrs)
End Function

Function LocalDay% (jdUtc As Double)
    Dim As Long yr, mo, dy
    Dim As Double hrs
    JDToDate jdUtc + UtcOffset#(jdUtc) / 24 + 0.0003#, yr, mo, dy, hrs
    LocalDay% = dy
End Function

' Weekday at the site, 0 = Sunday
Function LocalWd% (jdUtc As Double)
    LocalWd% = Int(jdUtc + UtcOffset#(jdUtc) / 24 + 0.0003# + 1.5#) Mod 7
End Function

Function FmtHM$ (jdUtc As Double)
    Dim As Long yr, mo, dy, hh, mi
    Dim As Double hrs
    JDToDate jdUtc + UtcOffset#(jdUtc) / 24, yr, mo, dy, hrs
    hh = Int(hrs)
    mi = Int((hrs - hh) * 60 + 0.5#)
    If mi = 60 Then
        mi = 0
        hh = (hh + 1) Mod 24
    End If
    FmtHM$ = Fmt2$(hh) + ":" + Fmt2$(mi)
End Function

' Clock time of a sample index inside tonight's window
Function EvTime$ (ix As Double)
    If ix < 0 Then
        EvTime$ = "--:--"
    Else
        EvTime$ = FmtHM$(winStart + ix * STEP_MIN / 1440#)
    End If
End Function

' Slot label such as "Tue 01:00" for a forecast column
Function SlotLabel$ (ii As Long)
    SlotLabel$ = WdAbbr$(LocalWd%(stepJD(ii))) + " " + Fmt2$(LocalHour%(stepJD(ii))) + ":00"
End Function

'---------------------------------------------------------------
' Astronomy (low-precision formulas: Sun to about 0.01 deg, Moon
' to about 0.3 deg, good for rise/set to a few minutes)
'---------------------------------------------------------------
Function Wrap360# (x As Double)
    Wrap360# = x - 360# * Int(x / 360#)
End Function

Sub SunPos (jd As Double, raDeg As Double, decDeg As Double, lamDeg As Double)
    Dim As Double n, ll, gg, eps
    n = jd - 2451545#
    ll = Wrap360#(280.46# + 0.9856474# * n)
    gg = Wrap360#(357.528# + 0.9856003# * n)
    lamDeg = Wrap360#(ll + 1.915# * Sin(gg * D2R) + 0.02# * Sin(2 * gg * D2R))
    eps = 23.439# - 0.0000004# * n
    raDeg = Wrap360#(_R2D(_Atan2(Cos(eps * D2R) * Sin(lamDeg * D2R), Cos(lamDeg * D2R))))
    decDeg = _R2D(_Asin(Sin(eps * D2R) * Sin(lamDeg * D2R)))
End Sub

Sub MoonPos (jd As Double, raDeg As Double, decDeg As Double, lamDeg As Double, parDeg As Double)
    Dim As Double t, lam, bet, l, m, n
    t = (jd - 2451545#) / 36525#
    lam = 218.32# + 481267.881# * t
    lam = lam + 6.29# * Sin((135# + 477198.87# * t) * D2R)
    lam = lam - 1.27# * Sin((259.3# - 413335.36# * t) * D2R)
    lam = lam + 0.66# * Sin((235.7# + 890534.22# * t) * D2R)
    lam = lam + 0.21# * Sin((269.9# + 954397.74# * t) * D2R)
    lam = lam - 0.19# * Sin((357.5# + 35999.05# * t) * D2R)
    lam = lam - 0.11# * Sin((186.5# + 966404.03# * t) * D2R)
    bet = 5.13# * Sin((93.3# + 483202.02# * t) * D2R)
    bet = bet + 0.28# * Sin((228.2# + 960400.89# * t) * D2R)
    bet = bet - 0.28# * Sin((318.3# + 6003.15# * t) * D2R)
    bet = bet - 0.17# * Sin((217.6# - 407332.21# * t) * D2R)
    parDeg = 0.9508# + 0.0518# * Cos((135# + 477198.87# * t) * D2R)
    parDeg = parDeg + 0.0095# * Cos((259.3# - 413335.36# * t) * D2R)
    parDeg = parDeg + 0.0078# * Cos((235.7# + 890534.22# * t) * D2R)
    parDeg = parDeg + 0.0028# * Cos((269.9# + 954397.74# * t) * D2R)
    l = Cos(bet * D2R) * Cos(lam * D2R)
    m = 0.9175# * Cos(bet * D2R) * Sin(lam * D2R) - 0.3978# * Sin(bet * D2R)
    n = 0.3978# * Cos(bet * D2R) * Sin(lam * D2R) + 0.9175# * Sin(bet * D2R)
    raDeg = Wrap360#(_R2D(_Atan2(m, l)))
    decDeg = _R2D(_Asin(n))
    lamDeg = Wrap360#(lam)
End Sub

' Geometric altitude in degrees for a given RA/Dec at the site
Function BodyAlt# (raDeg As Double, decDeg As Double, jd As Double)
    Dim As Double gmst, ha, sa
    gmst = Wrap360#(280.46061837# + 360.98564736629# * (jd - 2451545#))
    ha = (gmst + obsLon - raDeg) * D2R
    sa = Sin(obsLat * D2R) * Sin(decDeg * D2R) + Cos(obsLat * D2R) * Cos(decDeg * D2R) * Cos(ha)
    If sa > 1 Then sa = 1
    If sa < -1 Then sa = -1
    BodyAlt# = _R2D(_Asin(sa))
End Function

Function SunAlt# (jd As Double)
    Dim As Double ra, dec, lam
    SunPos jd, ra, dec, lam
    SunAlt# = BodyAlt#(ra, dec, jd)
End Function

' Topocentric Moon altitude (parallax removed)
Function MoonAlt# (jd As Double)
    Dim As Double ra, dec, lam, par, ga
    MoonPos jd, ra, dec, lam, par
    ga = BodyAlt#(ra, dec, jd)
    MoonAlt# = ga - par * Cos(ga * D2R)
End Function

Function PhaseName$ (e As Double)
    If e < 7 Or e >= 353 Then
        PhaseName$ = "new"
    ElseIf e < 83 Then
        PhaseName$ = "waxing crescent"
    ElseIf e < 97 Then
        PhaseName$ = "first quarter"
    ElseIf e < 173 Then
        PhaseName$ = "waxing gibbous"
    ElseIf e < 187 Then
        PhaseName$ = "full"
    ElseIf e < 263 Then
        PhaseName$ = "waning gibbous"
    ElseIf e < 277 Then
        PhaseName$ = "last quarter"
    Else
        PhaseName$ = "waning crescent"
    End If
End Function

' First crossing of a threshold in tonight's samples, as a fractional
' sample index, or -1. body 1 = Sun, 2 = Moon.
Function CrossIdx# (body As Long, thr As Double, goingDown As Long)
    Dim As Long ii
    Dim As Double a, b
    CrossIdx# = -1
    For ii = 0 To NSAMP - 1
        If body = 1 Then
            a = sunA(ii)
            b = sunA(ii + 1)
        Else
            a = moonA(ii)
            b = moonA(ii + 1)
        End If
        If goingDown Then
            If a >= thr And b < thr Then
                CrossIdx# = ii + (a - thr) / (a - b)
                Exit Function
            End If
        Else
            If a < thr And b >= thr Then
                CrossIdx# = ii + (thr - a) / (b - a)
                Exit Function
            End If
        End If
    Next
End Function

' Fills the samples, the summary lines and the best-slot picks
Sub Recalc
    Dim As Double nowJd, jd, sRa, sDec, sLam, mRa, mDec, mLam, mPar, elong
    Dim As Double ixSet, ixAd, ixAw, ixRise, ixMRise, ixMSet, mAltNow, offHr
    Dim As Double score, bestScore
    Dim As Long ii, runS, runLen, bestLen, bestS, bestE, nightMin, mins, bi
    Dim As String s

    nowJd = ClockJD#

    ' tonight's window: 24 hours from the last solar noon at the site,
    ' moved to a whole hour on the PC clock so the axis labels are tidy
    winStart = Int(nowJd + obsLon / 360#) - obsLon / 360#
    offHr = UtcOffset#(winStart)
    winStart = Int((winStart + offHr / 24) * 24 + 0.5#) / 24 - offHr / 24
    If winStart > nowJd Then winStart = winStart - 1
    If nowJd >= winStart + 1 Then winStart = winStart + 1
    tlNow = (nowJd - winStart) / (STEP_MIN / 1440#)

    For ii = 0 To NSAMP
        jd = winStart + ii * STEP_MIN / 1440#
        sunA(ii) = SunAlt#(jd)
        moonA(ii) = MoonAlt#(jd)
    Next

    ixSet = CrossIdx#(1, -0.833#, -1)
    ixAd = CrossIdx#(1, -18#, -1)
    ixAw = CrossIdx#(1, -18#, 0)
    ixRise = CrossIdx#(1, -0.833#, 0)
    ixMRise = CrossIdx#(2, -0.833#, 0)
    ixMSet = CrossIdx#(2, -0.833#, -1)

    lnSun = "Set " + EvTime$(ixSet) + "   Astro dusk " + EvTime$(ixAd) + "   Astro dawn " + EvTime$(ixAw) + "   Rise " + EvTime$(ixRise)

    ' Moon now
    SunPos nowJd, sRa, sDec, sLam
    MoonPos nowJd, mRa, mDec, mLam, mPar
    elong = Wrap360#(mLam - sLam)
    moonIllum = (1 - Cos(elong * D2R)) / 2 * 100
    mAltNow = MoonAlt#(nowJd)
    s = _Trim$(Str$(Int(moonIllum + 0.5#))) + "% " + PhaseName$(elong) + ", age " + Dec1$(elong / 360# * 29.53#) + "d"
    lnMoon = s + "   Rise " + EvTime$(ixMRise) + "   Set " + EvTime$(ixMSet) + "   Alt now " + _Trim$(Str$(Int(mAltNow + 0.5#)))

    ' longest stretch of astronomical night with the Moon down
    nightMin = 0
    runS = -1
    bestLen = 0
    bestS = -1
    bestE = -1
    For ii = 0 To NSAMP
        If sunA(ii) < -18 Then nightMin = nightMin + STEP_MIN
        If sunA(ii) < -18 And moonA(ii) < -0.833# Then
            If runS < 0 Then runS = ii
            runLen = ii - runS + 1
            If runLen > bestLen Then
                bestLen = runLen
                bestS = runS
                bestE = ii
            End If
        Else
            runS = -1
        End If
    Next
    If bestLen > 0 Then
        mins = bestLen * STEP_MIN
        lnDark = "Moon-free astronomical night " + EvTime$(bestS) + " - " + EvTime$(bestE + 1) + "  (" + _Trim$(Str$(mins \ 60)) + "h " + Fmt2$(mins Mod 60) + "m)"
    ElseIf nightMin > 0 Then
        lnDark = "No Moon-free darkness tonight (Moon is up during astronomical night)"
    Else
        lnDark = "No astronomical darkness tonight"
    End If

    ' forecast columns
    For ii = 1 To nSteps
        colSun(ii) = SunAlt#(stepJD(ii))
        colMoon(ii) = MoonAlt#(stepJD(ii))
    Next
    firstCol = nSteps + 1
    For ii = 1 To nSteps
        If stepJD(ii) >= nowJd - 1.5# / 24 Then
            firstCol = ii
            Exit For
        End If
    Next

    ' best deep-sky slot: astronomical night, clear, steady, dry
    bestDso = 0
    bestScore = 1E+9
    For ii = firstCol To nSteps
        If SkyClass%(colSun(ii)) = 4 And sCloud(ii) > 0 And sTransp(ii) > 0 And sSeeing(ii) > 0 Then
            score = sCloud(ii) * 12 + sTransp(ii) * 3 + sSeeing(ii)
            If colMoon(ii) > 0 Then score = score + moonIllum / 8
            If sPrec(ii) <> "none" Then score = score + 200
            If score < bestScore Then
                bestScore = score
                bestDso = ii
            End If
        End If
    Next
    If bestDso > 0 Then
        If sCloud(bestDso) > 6 Or sPrec(bestDso) <> "none" Then bestDso = 0
    End If
    If bestDso > 0 Then
        bi = bestDso
        lnDso = "Best deep-sky slot: " + SlotLabel$(bi) + "   cloud " + Tbl$("3,12,25,37,50,62,75,87,97", sCloud(bi)) + "%   transp " + Tbl$("<0.3,0.35,0.45,0.55,0.65,0.78,0.92,>1.0", sTransp(bi)) + "   seeing " + Tbl$("<0.5,0.6,0.9,1.1,1.4,1.7,2.2,>2.5", sSeeing(bi)) + " arcsec"
    ElseIf hasData Then
        lnDso = "Best deep-sky slot: none good in the forecast"
    Else
        lnDso = "Best deep-sky slot: waiting for forecast"
    End If

    ' best lunar / lucky-imaging slot: Moon up high, low cloud, seeing 2 arcsec or better
    bestLunar = 0
    bestScore = 1E+9
    If moonIllum >= 8 Then
        For ii = firstCol To nSteps
            If colMoon(ii) > 15 And sCloud(ii) > 0 And sSeeing(ii) > 0 And sSeeing(ii) <= 6 And sPrec(ii) = "none" Then
                score = sCloud(ii) * 12 + sSeeing(ii) * 6 + sWind(ii)
                If score < bestScore Then
                    bestScore = score
                    bestLunar = ii
                End If
            End If
        Next
        If bestLunar > 0 Then
            If sCloud(bestLunar) > 5 Then bestLunar = 0
        End If
    End If
    If moonIllum < 8 Then
        lnLunar = "Best lunar slot: Moon is too thin right now"
    ElseIf bestLunar > 0 Then
        bi = bestLunar
        lnLunar = "Best lunar slot: " + SlotLabel$(bi) + "   Moon alt " + _Trim$(Str$(Int(colMoon(bi) + 0.5#))) + "   seeing " + Tbl$("<0.5,0.6,0.9,1.1,1.4,1.7,2.2,>2.5", sSeeing(bi)) + " arcsec   cloud " + Tbl$("3,12,25,37,50,62,75,87,97", sCloud(bi)) + "%"
    ElseIf hasData Then
        lnLunar = "Best lunar slot: none good in the forecast (needs seeing of 2 arcsec or better)"
    Else
        lnLunar = "Best lunar slot: waiting for forecast"
    End If
End Sub

Function RhPct# (code As Long)
    If code < -4 Then
        RhPct# = -1
    ElseIf code >= 16 Then
        RhPct# = 100
    Else
        RhPct# = (code + 4) * 5 + 2.5#
    End If
End Function

' Dew point in C from temperature in C and relative humidity in %
Function DewPoint# (tc As Double, relHum As Double)
    Dim As Double r, g
    r = relHum
    If r < 1 Then r = 1
    g = Log(r / 100#) + (17.62# * tc) / (243.12# + tc)
    DewPoint# = 243.12# * g / (17.62# - g)
End Function

'---------------------------------------------------------------
' Data
'---------------------------------------------------------------
' Fetches and parses one forecast. Returns -1 on success, 0 on
' failure (errMsg says why; the last good data stays on screen).
Function FetchAstro%
    Dim As String url, raw
    errMsg = ""
    httpStatus = 0
    If testMode Then
        raw = ReadFile$("astro_sample.json")
        If Len(raw) = 0 Then
            errMsg = "astro_sample.json not found"
            Exit Function
        End If
    Else
        url = "www.7timer.info/bin/api.pl?lon=" + _Trim$(Str$(obsLon)) + "&lat=" + _Trim$(Str$(obsLat)) + "&product=astro&output=json&tzshift=0"
        raw = HttpGet$(url)
        ' plain HTTP refused or redirected? try curl over HTTPS
        If Len(raw) = 0 Then raw = CurlGet$(url)
        If Len(raw) = 0 Then
            If httpStatus Then errMsg = "HTTP status" + Str$(httpStatus) Else errMsg = "Connection failed"
            Exit Function
        End If
    End If
    If ParseAstro%(raw) Then
        hasData = -1
        stamp = Time$
        FetchAstro% = -1
    End If
End Function

Function HttpGet$ (url As String)
    Dim As Long client, st
    Dim As Double t0
    Dim As String chunk, result
    client = _OpenClient("HTTP:" + url)
    If client = 0 Then Exit Function
    st = _StatusCode(client)
    If st <> 200 Then
        httpStatus = st
        Close client
        Exit Function
    End If
    t0 = Timer
    Do While Not EOF(client)
        _Limit 60
        Get #client, , chunk
        result = result + chunk
        If Abs(Timer - t0) > 20 Then Exit Do
    Loop
    Close client
    HttpGet$ = result
End Function

' Fallback for when the server insists on HTTPS
Function CurlGet$ (url As String)
    If _FileExists("astro_data.json") Then Kill "astro_data.json"
    Shell _Hide "curl -s -L -m 25 -o astro_data.json " + Chr$(34) + "https://" + url + Chr$(34)
    CurlGet$ = ReadFile$("astro_data.json")
    If _FileExists("astro_data.json") Then Kill "astro_data.json"
End Function

Function ReadFile$ (fname As String)
    Dim As Long f
    Dim As String result
    If _FileExists(fname) = 0 Then Exit Function
    f = FreeFile
    Open fname For Binary As #f
    If LOF(f) > 0 Then
        result = Space$(LOF(f))
        Get #f, 1, result
    End If
    Close #f
    ReadFile$ = result
End Function

Function ParseAstro% (raw As String)
    Dim As Long p, depth, ii, n, objStart, cc
    Dim As String obj, s

    s = JsonStr$(raw, "init")
    If Len(s) < 10 Then
        errMsg = "Unexpected reply: " + Left$(raw, 50)
        Exit Function
    End If
    initJD = JulianDay#(Val(Left$(s, 4)), Val(Mid$(s, 5, 2)), Val(Mid$(s, 7, 2)), Val(Mid$(s, 9, 2)))
    initTxt = "Model run " + Left$(s, 4) + "-" + Mid$(s, 5, 2) + "-" + Mid$(s, 7, 2) + " " + Mid$(s, 9, 2) + " UTC"

    p = InStr(raw, Chr$(34) + "dataseries" + Chr$(34))
    If p > 0 Then p = InStr(p, raw, "[")
    If p = 0 Then
        errMsg = "No dataseries in reply"
        Exit Function
    End If

    ' walk the array; nested braces (wind10m) are handled by depth
    n = 0
    depth = 0
    For ii = p To Len(raw)
        cc = Asc(raw, ii)
        If cc = 123 Then
            If depth = 0 Then objStart = ii
            depth = depth + 1
        ElseIf cc = 125 Then
            depth = depth - 1
            If depth = 0 Then
                obj = Mid$(raw, objStart, ii - objStart + 1)
                n = n + 1
                If n <= MAXSTEP Then StoreStep n, obj
            End If
        ElseIf cc = 93 And depth = 0 Then
            Exit For
        End If
    Next

    If n = 0 Then
        errMsg = "Empty dataseries"
        Exit Function
    End If
    If n > MAXSTEP Then n = MAXSTEP
    nSteps = n
    ParseAstro% = -1
End Function

Sub StoreStep (n As Long, obj As String)
    stepJD(n) = initJD + JsonNum#(obj, "timepoint", 0) / 24
    sCloud(n) = JsonNum#(obj, "cloudcover", 0)
    sSeeing(n) = JsonNum#(obj, "seeing", 0)
    sTransp(n) = JsonNum#(obj, "transparency", 0)
    sWind(n) = JsonNum#(obj, "speed", 0)
    sRh(n) = JsonNum#(obj, "rh2m", -99)
    sTemp(n) = JsonNum#(obj, "temp2m", 0)
    sPrec(n) = JsonStr$(obj, "prec_type")
    ' -9999 marks an undefined value
    If sCloud(n) < 1 Or sCloud(n) > 9 Then sCloud(n) = 0
    If sSeeing(n) < 1 Or sSeeing(n) > 8 Then sSeeing(n) = 0
    If sTransp(n) < 1 Or sTransp(n) > 8 Then sTransp(n) = 0
    If sWind(n) < 1 Or sWind(n) > 8 Then sWind(n) = 0
    If sRh(n) < -4 Or sRh(n) > 16 Then sRh(n) = -99
End Sub

Function JsonNum# (obj As String, fld As String, dflt As Double)
    Dim As Long p, q
    JsonNum# = dflt
    p = InStr(obj, Chr$(34) + fld + Chr$(34))
    If p = 0 Then Exit Function
    q = InStr(p, obj, ":")
    If q = 0 Then Exit Function
    JsonNum# = Val(Mid$(obj, q + 1))
End Function

' String (or bare word/number) value of a field
Function JsonStr$ (obj As String, fld As String)
    Dim As Long p, q, a, b
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

'---------------------------------------------------------------
' Settings file (AstroWeather.ini, next to the program)
'---------------------------------------------------------------
Sub LoadSettings
    Dim As Long f, p
    Dim As String rec, k, v
    If _FileExists("AstroWeather.ini") = 0 Then Exit Sub
    f = FreeFile
    Open "AstroWeather.ini" For Input As #f
    Do While Not EOF(f)
        Line Input #f, rec
        ' QB64 writes CRLF line ends; drop any stray CR
        Do While Right$(rec, 1) = Chr$(13) Or Right$(rec, 1) = Chr$(10)
            rec = Left$(rec, Len(rec) - 1)
        Loop
        p = InStr(rec, "=")
        If p > 1 Then
            k = LCase$(_Trim$(Left$(rec, p - 1)))
            v = _Trim$(Mid$(rec, p + 1))
            Select Case k
                Case "name": obsName = v
                Case "lat": obsLat = Val(v)
                Case "lon": obsLon = Val(v)
                Case "tz": clockTz = Val(v)
                Case "dst": If Val(v) <> 0 Then clockDst = -1 Else clockDst = 0
            End Select
        End If
    Loop
    Close #f
    If obsLat < -90 Or obsLat > 90 Then obsLat = DEF_LAT
    If obsLon < -180 Or obsLon > 180 Then obsLon = DEF_LON
End Sub

Sub SaveSettings
    Dim As Long f
    f = FreeFile
    Open "AstroWeather.ini" For Output As #f
    Print #f, "name=" + obsName
    Print #f, "lat=" + FmtSigned$(obsLat, 4)
    Print #f, "lon=" + FmtSigned$(obsLon, 4)
    Print #f, "tz=" + _Trim$(Str$(clockTz))
    Print #f, "dst=" + _Trim$(Str$(-clockDst))
    Close #f
End Sub

'---------------------------------------------------------------
' Location map
'---------------------------------------------------------------
' Unsigned number with a fixed count of decimals (no float noise)
Function FmtNum$ (x As Double, dec As Long)
    Dim As Long scl, k, ip, fp, i
    Dim As String fs
    scl = 1
    For i = 1 To dec
        scl = scl * 10
    Next
    k = Int(Abs(x) * scl + 0.5#)
    ip = k \ scl
    fp = k Mod scl
    If dec = 0 Then
        FmtNum$ = _Trim$(Str$(ip))
    Else
        fs = _Trim$(Str$(fp))
        FmtNum$ = _Trim$(Str$(ip)) + "." + String$(dec - Len(fs), "0") + fs
    End If
End Function

Function FmtSigned$ (x As Double, dec As Long)
    If x < 0 Then FmtSigned$ = "-" + FmtNum$(x, dec) Else FmtSigned$ = FmtNum$(x, dec)
End Function

Function FmtLat$ (v As Double, dec As Long)
    If v >= 0 Then FmtLat$ = FmtNum$(v, dec) + " N" Else FmtLat$ = FmtNum$(v, dec) + " S"
End Function

Function FmtLon$ (v As Double, dec As Long)
    If v >= 0 Then FmtLon$ = FmtNum$(v, dec) + " E" Else FmtLon$ = FmtNum$(v, dec) + " W"
End Function

' Draws the whole picker screen. Its buttons set pickAct
' (1 cancel, 2 use marker, 3 world view, 4 type coordinates).
Sub DrawPicker (cLon As Double, cLat As Double, zoom As Double, mLon As Double, mLat As Double, hasCur As Long, curLon As Double, curLat As Double)
    Dim As Long r, i, k, dec, kStart, kEnd
    Dim As Double x1, y1, x2, y2, hx, hy, stepDeg, gv

    hx = MAPW / 2
    hy = MAPH / 2
    Cls , pcol(P_BG)

    ' graticule: the finest spacing that keeps lines 70 pixels apart
    stepDeg = 30
    For k = 1 To 15
        stepDeg = Val(Tbl$("0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.2,0.5,1,2,5,10,15,30", k))
        If stepDeg * zoom >= 70 Then Exit For
    Next
    If stepDeg >= 1 Then
        dec = 0
    ElseIf stepDeg >= 0.1# Then
        dec = 1
    ElseIf stepDeg >= 0.01# Then
        dec = 2
    Else
        dec = 3
    End If

    Color pcol(P_DIM), pcol(P_BG)
    kStart = Int((cLon - hx / zoom) / stepDeg)
    kEnd = Int((cLon + hx / zoom) / stepDeg) + 1
    For k = kStart To kEnd
        gv = k * stepDeg
        If gv >= -180 And gv <= 180 Then
            x1 = hx + (gv - cLon) * zoom
            Line (x1, 0)-(x1, MAPH - 1), pcol(P_BTNHOT)
            _PrintString (x1 + 3, 2), FmtLon$(gv, dec)
        End If
    Next
    kStart = Int((cLat - hy / zoom) / stepDeg)
    kEnd = Int((cLat + hy / zoom) / stepDeg) + 1
    For k = kStart To kEnd
        gv = k * stepDeg
        If gv >= -90 And gv <= 90 Then
            y1 = hy - (gv - cLat) * zoom
            Line (0, y1)-(MAPW - 1, y1), pcol(P_BTNHOT)
            If y1 > 40 Then _PrintString (3, y1 - 17), FmtLat$(gv, dec)
        End If
    Next

    ' coastlines
    For r = 1 To nRings
        For i = ringStart(r) To ringStart(r + 1) - 2
            x1 = hx + (wLon(i) / 10# - cLon) * zoom
            y1 = hy - (wLat(i) / 10# - cLat) * zoom
            x2 = hx + (wLon(i + 1) / 10# - cLon) * zoom
            y2 = hy - (wLat(i + 1) / 10# - cLat) * zoom
            If Not ((x1 < 0 And x2 < 0) Or (x1 > MAPW And x2 > MAPW) Or (y1 < 0 And y2 < 0) Or (y1 > MAPH And y2 > MAPH)) Then
                Line (x1, y1)-(x2, y2), pcol(P_ACC)
            End If
        Next
    Next

    ' saved site (small ring) and the marker being placed (crosshair)
    x1 = hx + (obsLon - cLon) * zoom
    y1 = hy - (obsLat - cLat) * zoom
    If x1 > 0 And x1 < MAPW And y1 > 0 And y1 < MAPH Then Circle (x1, y1), 3, pcol(P_TEXT)
    x1 = hx + (mLon - cLon) * zoom
    y1 = hy - (mLat - cLat) * zoom
    If x1 > -20 And x1 < MAPW + 20 And y1 > -20 And y1 < MAPH + 20 Then
        Circle (x1, y1), 7, pcol(P_WARN)
        Line (x1 - 15, y1)-(x1 - 5, y1), pcol(P_WARN)
        Line (x1 + 5, y1)-(x1 + 15, y1), pcol(P_WARN)
        Line (x1, y1 - 15)-(x1, y1 - 5), pcol(P_WARN)
        Line (x1, y1 + 5)-(x1, y1 + 15), pcol(P_WARN)
    End If

    ' bottom bar
    Line (0, MAPH)-(MAPW - 1, 599), pcol(P_BG), BF
    Line (0, MAPH)-(MAPW - 1, MAPH), pcol(P_DIM)
    Color pcol(P_TEXT), pcol(P_BG)
    _PrintString (16, MAPH + 8), "Marker  " + FmtLat$(mLat, 3) + "   " + FmtLon$(mLon, 3)
    If hasCur Then _PrintString (520, MAPH + 8), "Cursor  " + FmtLat$(curLat, 3) + "   " + FmtLon$(curLon, 3)
    If entryOn Then
        Color pcol(P_ACC), pcol(P_BG)
        _PrintString (16, MAPH + 28), "Coordinates: " + entryTxt + "_"
        If Len(entryMsg) Then
            Color pcol(P_WARN), pcol(P_BG)
            _PrintString (16, MAPH + 46), entryMsg
        Else
            Color pcol(P_DIM), pcol(P_BG)
            _PrintString (16, MAPH + 46), "Latitude then longitude (31.958 -111.597 or 31.958 N 111.597 W), or a US ZIP code. Enter applies, Esc cancels."
        End If
    Else
        Color pcol(P_DIM), pcol(P_BG)
        _PrintString (16, MAPH + 28), "Wheel/+/- zoom, drag pans, click places the marker, arrows nudge (Shift 0.1, Ctrl 0.001), H world, T type."
        _PrintString (16, MAPH + 46), "The small ring is the current site. Times on screen stay in PC clock time."
    End If
    If DrawBtn%(16, 566, 150, 32, "Use it (Enter)") Then pickAct = 2
    If DrawBtn%(180, 566, 170, 32, "Cancel (Esc)") Then pickAct = 1
    If DrawBtn%(364, 566, 150, 32, "World (H)") Then pickAct = 3
    If DrawBtn%(528, 566, 230, 32, "Type coords/ZIP (T)") Then pickAct = 4
End Sub

' Reads "lat lon" in decimal degrees: 31.958 -111.597, 31.958,-111.597
' or 31.958 N 111.597 W (S and W make the number negative).
' Returns -1 and the values when both parse and are in range.
Function ParseLatLon% (txt As String, lat As Double, lon As Double)
    Dim As String t, ch, tok
    Dim As Long ii, nNum
    Dim As Double num(1 To 2)
    Dim As Long southWest(1 To 2)
    t = UCase$(txt) + " "
    For ii = 1 To Len(t)
        ch = Mid$(t, ii, 1)
        If InStr("0123456789.-+", ch) > 0 Then
            tok = tok + ch
        Else
            If Len(tok) > 0 Then
                nNum = nNum + 1
                If nNum > 2 Then Exit Function
                num(nNum) = Val(tok)
                tok = ""
            End If
            If (ch = "S" Or ch = "W") And nNum >= 1 Then southWest(nNum) = -1
        End If
    Next
    If nNum <> 2 Then Exit Function
    If southWest(1) Then num(1) = -Abs(num(1))
    If southWest(2) Then num(2) = -Abs(num(2))
    If num(1) < -90 Or num(1) > 90 Or num(2) < -180 Or num(2) > 180 Then Exit Function
    lat = num(1)
    lon = num(2)
    ParseLatLon% = -1
End Function

' "85719" (or ZIP+4) becomes "us/85719"; "GB SW1A" becomes "gb/SW1A"
' (country code, then the first part of the postal code). "" if the
' text does not look like a postal code.
Function ZipPath$ (txt As String)
    Dim As String t, cc, code
    Dim As Long ii, allDigits, sp
    t = UCase$(_Trim$(txt))
    If Len(t) = 10 And Mid$(t, 6, 1) = "-" Then t = Left$(t, 5)
    If Len(t) = 5 Then
        allDigits = -1
        For ii = 1 To 5
            If Asc(t, ii) < 48 Or Asc(t, ii) > 57 Then allDigits = 0
        Next
        If allDigits Then
            ZipPath$ = "us/" + t
            Exit Function
        End If
    End If
    If Len(t) >= 4 And Mid$(t, 3, 1) = " " Then
        cc = Left$(t, 2)
        If Asc(cc, 1) >= 65 And Asc(cc, 1) <= 90 And Asc(cc, 2) >= 65 And Asc(cc, 2) <= 90 Then
            code = _Trim$(Mid$(t, 4))
            sp = InStr(code, " ")
            If sp > 0 Then code = Left$(code, sp - 1)
            If Len(code) > 0 Then ZipPath$ = LCase$(cc) + "/" + code
        End If
    End If
End Function

' Looks a postal code up at api.zippopotam.us (plain HTTP, free, no
' key). Gives the place centroid, which is fine for a forecast but not
' as exact as typed coordinates. Sets entryName to "Place, ST".
Function ZipLookup% (path As String, lat As Double, lon As Double)
    Dim As String raw, la, lo, pl, st
    httpStatus = 0
    If zipTest Then
        raw = ReadFile$("zip_sample.json")
    Else
        raw = HttpGet$("api.zippopotam.us/" + path)
        If Len(raw) = 0 And (httpStatus = 0 Or (httpStatus >= 300 And httpStatus < 400)) Then
            raw = CurlGet$("api.zippopotam.us/" + path)
        End If
    End If
    la = JsonStr$(raw, "latitude")
    lo = JsonStr$(raw, "longitude")
    If Len(la) = 0 Or Len(lo) = 0 Then Exit Function
    If Val(la) < -90 Or Val(la) > 90 Or Val(lo) < -180 Or Val(lo) > 180 Then Exit Function
    lat = Val(la)
    lon = Val(lo)
    pl = JsonStr$(raw, "place name")
    st = JsonStr$(raw, "state abbreviation")
    entryName = pl
    If Len(pl) > 0 And Len(st) > 0 Then entryName = pl + ", " + st
    ZipLookup% = -1
End Function

' Modal map picker. Returns -1 when a new site was chosen (obsLat,
' obsLon and obsName are then updated), 0 when cancelled.
Function PickLocation%
    Dim As Double cLon, cLat, zoom, mLon, mLat, curLon, curLat, lonU, latU, nudge, nLat, nLon
    Dim As Long done, dragging, moved, startX, startY, lastX, lastY, wheel, kk, inMap, shiftDn, ctrlDn, sawDown, gotIt
    Dim As String zipReq

    mLon = obsLon
    mLat = obsLat
    cLon = obsLon
    cLat = obsLat
    zoom = 40
    entryOn = 0
    entryTxt = ""
    entryMsg = ""
    entryName = ""

    Do
        If _Exit Then done = 1

        wheel = 0
        sawDown = 0
        Do While _MouseInput
            wheel = wheel + _MouseWheel
            If _MouseButton(1) Then sawDown = -1
        Loop
        mx = _MouseX
        my = _MouseY
        mb = _MouseButton(1)
        clicked = (prevMb = 0) And ((mb <> 0) Or sawDown)
        inMap = (mx >= 0) And (mx < MAPW) And (my >= 0) And (my < MAPH)
        curLon = cLon + (mx - MAPW / 2) / zoom
        curLat = cLat - (my - MAPH / 2) / zoom

        ' wheel zoom keeps the point under the cursor fixed
        If wheel <> 0 And inMap Then
            lonU = curLon
            latU = curLat
            zoom = _Clamp(zoom * 1.3# ^ (-wheel), MINZOOM, MAXZOOM)
            cLon = lonU - (mx - MAPW / 2) / zoom
            cLat = latU + (my - MAPH / 2) / zoom
        End If

        ' left button: a drag pans, a click without movement sets the marker
        If clicked And inMap Then
            dragging = -1
            moved = 0
            startX = mx
            startY = my
            lastX = mx
            lastY = my
        End If
        If dragging Then
            If mb <> 0 Then
                If Abs(mx - startX) + Abs(my - startY) > 4 Then moved = -1
                If moved Then
                    cLon = cLon - (mx - lastX) / zoom
                    cLat = cLat + (my - lastY) / zoom
                End If
                lastX = mx
                lastY = my
            Else
                If moved = 0 Then
                    mLon = curLon
                    mLat = curLat
                    entryName = ""
                End If
                dragging = 0
            End If
        End If

        ' keyboard: every pending key press (releases arrive as negative codes)
        shiftDn = _KeyDown(100303) Or _KeyDown(100304)
        ctrlDn = _KeyDown(100305) Or _KeyDown(100306)
        nudge = 0.01#
        If shiftDn Then nudge = 0.1#
        If ctrlDn Then nudge = 0.001#
        Do
            kk = _KeyHit
            If kk = 0 Then Exit Do
            If entryOn Then
                If kk = 27 Then
                    entryOn = 0
                    entryMsg = ""
                ElseIf kk = 13 Then
                    gotIt = 0
                    If ParseLatLon%(entryTxt, nLat, nLon) Then
                        entryName = ""
                        gotIt = -1
                    Else
                        zipReq = ZipPath$(entryTxt)
                        If Len(zipReq) > 0 Then
                            entryMsg = "Looking up " + zipReq + " ..."
                            DrawPicker cLon, cLat, zoom, mLon, mLat, inMap, curLon, curLat
                            _Display
                            If ZipLookup%(zipReq, nLat, nLon) Then
                                gotIt = -1
                            Else
                                entryMsg = "That ZIP or postal code was not found (or there is no network)."
                            End If
                        Else
                            entryMsg = "Need latitude and longitude, like 31.958 -111.597, or a 5-digit US ZIP code."
                        End If
                    End If
                    If gotIt Then
                        mLat = nLat
                        mLon = nLon
                        cLat = nLat
                        cLon = nLon
                        If zoom < 40 Then zoom = 40
                        entryOn = 0
                        entryMsg = ""
                    End If
                ElseIf kk = 8 Then
                    If Len(entryTxt) > 0 Then entryTxt = Left$(entryTxt, Len(entryTxt) - 1)
                ElseIf kk >= 32 And kk <= 126 Then
                    If Len(entryTxt) < 40 Then entryTxt = entryTxt + Chr$(kk)
                End If
            Else
                Select Case kk
                    Case 27: done = 1
                    Case 13: done = 2
                    Case 43, 61: zoom = _Clamp(zoom * 1.3#, MINZOOM, MAXZOOM)
                    Case 45, 95: zoom = _Clamp(zoom / 1.3#, MINZOOM, MAXZOOM)
                    Case 84, 116
                        entryOn = -1
                        entryTxt = ""
                        entryMsg = ""
                    Case 72, 104, 18176
                        cLon = 0
                        cLat = 0
                        zoom = MINZOOM
                    Case 18432
                        mLat = mLat + nudge
                        entryName = ""
                    Case 20480
                        mLat = mLat - nudge
                        entryName = ""
                    Case 19200
                        mLon = mLon - nudge
                        entryName = ""
                    Case 19712
                        mLon = mLon + nudge
                        entryName = ""
                End Select
            End If
        Loop

        cLat = _Clamp(cLat, -89, 89)
        cLon = _Clamp(cLon, -180, 180)
        mLat = _Clamp(mLat, -90, 90)
        mLon = _Clamp(mLon, -180, 180)

        pickAct = 0
        DrawPicker cLon, cLat, zoom, mLon, mLat, inMap, curLon, curLat
        _Display

        If pickAct = 1 Then done = 1
        If pickAct = 2 Then done = 2
        If pickAct = 3 Then
            cLon = 0
            cLat = 0
            zoom = MINZOOM
        End If
        If pickAct = 4 Then
            entryOn = -1
            entryTxt = ""
            entryMsg = ""
        End If

        prevMb = mb
        _Limit 30
    Loop Until done <> 0

    If done = 2 Then
        ' round half away from zero, the same way the readout does
        obsLat = Sgn(mLat) * Int(Abs(mLat) * 1000 + 0.5#) / 1000
        obsLon = Sgn(mLon) * Int(Abs(mLon) * 1000 + 0.5#) / 1000
        If Len(entryName) > 0 Then
            obsName = entryName
        Else
            obsName = FmtLat$(obsLat, 3) + ", " + FmtLon$(obsLon, 3)
        End If
        PickLocation% = -1
    End If
End Function

