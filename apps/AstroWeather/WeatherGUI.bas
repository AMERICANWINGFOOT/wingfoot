'---------------------------------------------------------------
' WeatherGUI.bas - Simple Weather GUI for QB64-PE (Windows/Linux)
' Data comes from wttr.in in its one-line custom format (no key).
' Keys: R = refresh, U = toggle F/C, L = location, Q or Esc = quit
'
' Location picker (L key or button): click the world map to pick
' a point, or type a place name, ZIP/postal code, airport code or
' "lat,lon". Right-drag pans, the wheel zooms. The chosen location
' and units are saved in WeatherGUI.ini next to the program.
' Needs WorldMap.bi (coastline DATA) in the same folder.
'---------------------------------------------------------------

'~~~ Settings ~~~
' Seconds between updates. wttr.in is a free service, so please
' keep this at 300 or more.
Const REFRESH_SECS = 600
' Seconds before retrying after a failed update
Const RETRY_SECS = 60

' Field positions in the wttr.in reply
Const F_LOC = 1
Const F_COND = 2
Const F_TEMP = 3
Const F_FEEL = 4
Const F_HUM = 5
Const F_WIND = 6
Const F_PRESS = 7
Const F_PREC = 8
Const F_SUNRISE = 9
Const F_SUNSET = 10
Const F_UV = 11

' Location picker map area (screen pixels)
Const MAP_Y1 = 40
Const MAP_Y2 = 371
Const MAP_H = 332
Const MAP_CX = 400
Const MAP_CY = 206
Const MAX_PPD = 400

Dim Shared As String sLocation, units, errMsg, statusMsg, stamp
Dim Shared wx(1 To 11) As String
Dim Shared As Long hasData, mx, my, mb, prevMb, clicked, secsLeft
Dim Shared As Long actRefresh, actUnits, actQuit, actLocation
Dim Shared As _Unsigned Long cBg, cText, cDim, cAccent, cWarn, cBtn, cBtnHot
Dim Shared As _Unsigned Long cSea, cLand, cGrid

' location picker state
Dim Shared As Long pickMode, needFetch, hasPin, candPin
Dim Shared As Long mb2, prevMb2, wheelDelta, dragging, dragX, dragY
Dim Shared As Long pkApply, pkCancel, pkZoomIn, pkZoomOut
Dim Shared As Double pinLat, pinLon, candLat, candLon
Dim Shared As Double viewLon, viewLat, ppd, minPpd
Dim Shared As String entry, pickMsg

' coastline rings loaded from WorldMap.bi
Dim Shared As Long ringCount
ReDim Shared ringFirst(0) As Long
ReDim Shared ringLen(0) As Long
ReDim Shared ptLon(0) As Single
ReDim Shared ptLat(0) As Single

' Default location: use a plus sign instead of a space or comma,
' for example Dallas+Texas. A ZIP code or "lat,lon" also works.
' WeatherGUI.ini (written by the location picker) overrides this.
sLocation = "Kitt+Peak+AZ"
hasPin = -1
pinLat = 31.958
pinLon = -111.597

' Units: "u" = Fahrenheit/mph, "m" = Celsius/kmh (U key toggles)
units = "u"

LoadSettings

cBg = _RGB32(14, 17, 23)
cText = _RGB32(225, 230, 240)
cDim = _RGB32(120, 130, 148)
cAccent = _RGB32(90, 180, 255)
cWarn = _RGB32(255, 190, 80)
cBtn = _RGB32(34, 40, 54)
cBtnHot = _RGB32(52, 62, 84)
cSea = _RGB32(10, 24, 40)
cLand = _RGB32(120, 200, 140)
cGrid = _RGB32(34, 52, 72)

LoadWorld
minPpd = MAP_H / 180
If 800 / 360 < minPpd Then minPpd = 800 / 360

Screen _NewImage(800, 480, 32)
_Title "Simple Weather"

Dim As Long quitFlag, kk, pending, interval
Dim As Double lastFetch, elapsed

interval = REFRESH_SECS
pending = -1
lastFetch = Timer

Do
    If _Exit Then quitFlag = -1

    ' mouse state, once per frame
    wheelDelta = 0
    Do While _MouseInput
        wheelDelta = wheelDelta + _MouseWheel
    Loop
    mx = _MouseX
    my = _MouseY
    mb = _MouseButton(1)
    mb2 = _MouseButton(2)
    clicked = (mb <> 0) And (prevMb = 0)

    ' countdown (handles the midnight rollover of TIMER)
    elapsed = Timer - lastFetch
    If elapsed < 0 Then elapsed = elapsed + 86400
    secsLeft = interval - Int(elapsed)
    If secsLeft <= 0 Then pending = -1

    kk = _KeyHit

    If pickMode Then
        ' picker owns the keyboard and mouse; updates wait until it closes
        PickerFrame kk
        _Display
    Else
        DrawScreen
        _Display

        ' keyboard
        Select Case kk
            Case 27, 81, 113: actQuit = -1
            Case 82, 114: actRefresh = -1
            Case 85, 117: actUnits = -1
            Case 76, 108: actLocation = -1
        End Select

        If actRefresh Then pending = -1
        If actUnits Then
            If units = "u" Then units = "m" Else units = "u"
            SaveSettings
            pending = -1
        End If
        If actQuit Then quitFlag = -1
        If actLocation Then OpenPicker
        actRefresh = 0
        actUnits = 0
        actQuit = 0
        actLocation = 0

        If needFetch Then
            pending = -1
            needFetch = 0
        End If

        If pending <> 0 And quitFlag = 0 And pickMode = 0 Then
            statusMsg = "Updating..."
            clicked = 0
            DrawScreen
            _Display
            If FetchWeather% Then interval = REFRESH_SECS Else interval = RETRY_SECS
            statusMsg = ""
            lastFetch = Timer
            pending = 0
            actRefresh = 0
            actUnits = 0
            actQuit = 0
            actLocation = 0
        End If
    End If

    prevMb = mb
    prevMb2 = mb2
    _Limit 30
Loop Until quitFlag
System

' Coastline data for the location picker (label WorldData)
'$Include:'WorldMap.bi'

'---------------------------------------------------------------
' Drawing
'---------------------------------------------------------------
Sub DrawScreen
    Dim As Long sl
    Dim As String hdr

    Cls , cBg

    ' header
    Color cAccent, cBg
    If hasData Then
        _PrintString (16, 12), Left$(wx(F_LOC), 60)
    Else
        _PrintString (16, 12), "Simple Weather"
    End If
    If Len(stamp) Then
        hdr = "Updated " + stamp
        Color cDim, cBg
        _PrintString (800 - 16 - Len(hdr) * 8, 12), hdr
    End If
    Line (0, 38)-(799, 38), cDim

    If hasData Then
        ' left side: big temperature and condition
        BigText 24, 56, wx(F_TEMP), 9, cText
        WrapBig 24, 214, wx(F_COND), 24, 2, cAccent
        BigText 24, 294, "Feels like " + wx(F_FEEL), 2, cDim

        ' right side: detail rows
        InfoRow 56, "Humidity", wx(F_HUM)
        HBar 440, 90, 344, 8, Val(wx(F_HUM))
        InfoRow 104, "Wind", wx(F_WIND)
        InfoRow 152, "Pressure", wx(F_PRESS)
        InfoRow 200, "Precip 3h", wx(F_PREC)
        InfoRow 248, "UV index", wx(F_UV)
        InfoRow 296, "Sunrise", wx(F_SUNRISE)
        InfoRow 344, "Sunset", wx(F_SUNSET)
    Else
        Color cDim, cBg
        _PrintString (24, 80), "Waiting for first update..."
    End If

    ' status line
    sl = secsLeft
    If sl < 0 Then sl = 0
    If Len(statusMsg) Then
        Color cAccent, cBg
        _PrintString (16, 396), statusMsg
    ElseIf Len(errMsg) Then
        Color cWarn, cBg
        _PrintString (16, 396), errMsg + " - retry in" + Str$(sl) + "s"
    Else
        Color cDim, cBg
        _PrintString (16, 396), "Next update in" + Str$(sl) + "s"
    End If

    ' buttons (immediate mode: drawn and tested in one call)
    If DrawBtn%(16, 430, 150, 34, "Refresh (R)") Then actRefresh = -1
    If units = "u" Then
        If DrawBtn%(180, 430, 150, 34, "Units: F (U)") Then actUnits = -1
    Else
        If DrawBtn%(180, 430, 150, 34, "Units: C (U)") Then actUnits = -1
    End If
    If DrawBtn%(344, 430, 150, 34, "Location (L)") Then actLocation = -1
    If DrawBtn%(650, 430, 134, 34, "Quit (Q)") Then actQuit = -1
End Sub

' Scaled-up text: prints into a small image, then stretches it
Sub BigText (xx As Long, yy As Long, txt As String, sc As Long, clr As _Unsigned Long)
    Dim As Long tw, th, src, prevDest
    If Len(txt) = 0 Then Exit Sub
    tw = Len(txt) * 8
    th = 16
    src = _NewImage(tw, th, 32)
    prevDest = _Dest
    _Dest src
    Cls , cBg
    Color clr, cBg
    _PrintString (0, 0), txt
    _Dest prevDest
    _PutImage (xx, yy)-(xx + tw * sc - 1, yy + th * sc - 1), src, prevDest
    _FreeImage src
End Sub

Sub InfoRow (yy As Long, lbl As String, vv As String)
    Color cDim, cBg
    _PrintString (440, yy + 8), lbl
    BigText 600, yy, Left$(vv, 11), 2, cText
End Sub

Sub HBar (xx As Long, yy As Long, ww As Long, hh As Long, pct As Double)
    Dim As Long fw
    pct = _Clamp(pct, 0, 100)
    fw = Int((ww - 2) * pct / 100)
    Line (xx, yy)-(xx + ww - 1, yy + hh - 1), cDim, B
    If fw > 0 Then Line (xx + 1, yy + 1)-(xx + fw, yy + hh - 2), cAccent, BF
End Sub

Function DrawBtn% (xx As Long, yy As Long, ww As Long, hh As Long, lbl As String)
    Dim As Long hot, res
    Dim As _Unsigned Long fillc
    hot = (mx >= xx) And (mx < xx + ww) And (my >= yy) And (my < yy + hh)
    If hot Then fillc = cBtnHot Else fillc = cBtn
    Line (xx, yy)-(xx + ww - 1, yy + hh - 1), fillc, BF
    Line (xx, yy)-(xx + ww - 1, yy + hh - 1), cDim, B
    Color cText, fillc
    _PrintString (xx + (ww - Len(lbl) * 8) \ 2, yy + (hh - 16) \ 2), lbl
    res = hot And clicked
    DrawBtn% = res
End Function

'---------------------------------------------------------------
' Data
'---------------------------------------------------------------
' Fetches and parses one reply. Returns -1 on success, 0 on failure
' (errMsg then says why; the last good data stays on screen).
Function FetchWeather%
    Dim As Long client, st, n, pp, sp, ii
    Dim As Double t0
    Dim As String url, raw, chunk, part
    Dim tmp(1 To 11) As String

    errMsg = ""
    url = "wttr.in/" + sLocation + "?" + units + "&format=%l~%C~%t~%f~%h~%w~%P~%p~%S~%s~%u"
    client = _OpenClient("HTTP:" + url)
    If client = 0 Then
        errMsg = "Connection failed"
        Exit Function
    End If

    st = _StatusCode(client)
    If st <> 200 Then
        If st = 404 Then
            errMsg = "Location not found - press L"
        Else
            errMsg = "HTTP status" + Str$(st)
        End If
        Close client
        Exit Function
    End If

    t0 = Timer
    Do While Not EOF(client)
        _Limit 60
        Get #client, , chunk
        raw = raw + chunk
        If Abs(Timer - t0) > 15 Then Exit Do
    Loop
    Close client

    ' split on "~"
    n = 0
    sp = 1
    Do
        pp = InStr(sp, raw, "~")
        If pp = 0 Then
            part = Mid$(raw, sp)
        Else
            part = Mid$(raw, sp, pp - sp)
        End If
        n = n + 1
        If n <= 11 Then tmp(n) = _Trim$(Clean$(part))
        If pp = 0 Then Exit Do
        sp = pp + 1
    Loop

    If n < 11 Then
        errMsg = "Unexpected reply: " + Left$(Clean$(raw), 50)
        Exit Function
    End If

    ' wttr.in puts a leading + on positive temperatures
    If Left$(tmp(F_TEMP), 1) = "+" Then tmp(F_TEMP) = Mid$(tmp(F_TEMP), 2)
    If Left$(tmp(F_FEEL), 1) = "+" Then tmp(F_FEEL) = Mid$(tmp(F_FEEL), 2)

    For ii = 1 To 11
        wx(ii) = tmp(ii)
    Next
    hasData = -1
    stamp = Time$
    FetchWeather% = -1
End Function

' Keeps plain ASCII, turns the UTF-8 degree sign into the
' CP437 degree character the default font has, drops the rest
' (arrows, emoji, CR/LF).
Function Clean$ (s As String)
    Dim As Long ii, cc
    Dim As String r
    ii = 1
    Do While ii <= Len(s)
        cc = Asc(s, ii)
        If cc = 194 And ii < Len(s) Then
            If Asc(s, ii + 1) = 176 Then
                r = r + Chr$(248)
                ii = ii + 1
            End If
        ElseIf cc >= 32 And cc < 127 Then
            r = r + Chr$(cc)
        End If
        ii = ii + 1
    Loop
    Clean$ = r
End Function
' BigText that breaks at the last space before maxc characters,
' second line capped at maxc. Line height = 16 * scale.
Sub WrapBig (xx As Long, yy As Long, txt As String, maxc As Long, sc As Long, clr As _Unsigned Long)
    Dim As String l1, l2
    Dim As Long cut
    If Len(txt) <= maxc Then
        BigText xx, yy, txt, sc, clr
        Exit Sub
    End If
    cut = _InStrRev(Left$(txt, maxc + 1), " ")
    If cut = 0 Then cut = maxc + 1
    l1 = RTrim$(Left$(txt, cut - 1))
    l2 = LTrim$(Mid$(txt, cut))
    BigText xx, yy, l1, sc, clr
    BigText xx, yy + 16 * sc, Left$(l2, maxc), sc, clr
End Sub


'---------------------------------------------------------------
' Location picker
'---------------------------------------------------------------
Sub OpenPicker
    Dim As Long ii
    Dim As String cc
    pickMode = -1
    pickMsg = ""
    dragging = 0
    ' show the current location as editable text (plus signs to spaces)
    entry = ""
    For ii = 1 To Len(sLocation)
        cc = Mid$(sLocation, ii, 1)
        If cc = "+" Then entry = entry + " " Else entry = entry + cc
    Next
    candPin = hasPin
    candLat = pinLat
    candLon = pinLon
    If hasPin Then
        ppd = 8
        viewLon = pinLon
        viewLat = pinLat
    Else
        ppd = minPpd
        viewLon = 0
        viewLat = 0
    End If
    ClampView
End Sub

' One frame of the picker: input, then drawing, then button actions
Sub PickerFrame (kk As Long)
    Dim As Long inMap, cc
    Dim As Double la, lo

    inMap = (my >= MAP_Y1) And (my <= MAP_Y2)

    ' wheel zooms around the cursor (negative = wheel up = zoom in)
    If inMap Then
        If wheelDelta < 0 Then ZoomAt mx, my, 1.5
        If wheelDelta > 0 Then ZoomAt mx, my, 1 / 1.5
    End If

    ' right-drag pans
    If mb2 <> 0 And prevMb2 = 0 And inMap Then
        dragging = -1
        dragX = mx
        dragY = my
    End If
    If mb2 = 0 Then dragging = 0
    If dragging Then
        viewLon = viewLon - (mx - dragX) / ppd
        viewLat = viewLat + (my - dragY) / ppd
        dragX = mx
        dragY = my
        ClampView
    End If

    ' left-click on the map picks a point
    If clicked And inMap Then
        lo = viewLon + (mx - MAP_CX) / ppd
        la = viewLat - (my - MAP_CY) / ppd
        If la >= -90 And la <= 90 And lo >= -180 And lo <= 180 Then
            candLat = la
            candLon = lo
            candPin = -1
            entry = CoordStr$(la) + "," + CoordStr$(lo)
            pickMsg = ""
        End If
    End If

    ' keyboard: typing edits the entry, arrows pan, PgUp/PgDn zoom
    Select Case kk
        Case 13: pkApply = -1
        Case 27: pkCancel = -1
        Case 8
            If Len(entry) Then entry = Left$(entry, Len(entry) - 1)
            candPin = ParseCoords%(entry, candLat, candLon)
        Case 18432: viewLat = viewLat + 40 / ppd: ClampView
        Case 20480: viewLat = viewLat - 40 / ppd: ClampView
        Case 19200: viewLon = viewLon - 40 / ppd: ClampView
        Case 19712: viewLon = viewLon + 40 / ppd: ClampView
        Case 18688: pkZoomIn = -1
        Case 20736: pkZoomOut = -1
        Case 32 To 126
            cc = kk
            If AllowedChar%(cc) And Len(entry) < 60 Then
                entry = entry + Chr$(cc)
                candPin = ParseCoords%(entry, candLat, candLon)
                pickMsg = ""
            End If
    End Select

    DrawPicker

    If pkZoomIn Then ZoomAt MAP_CX, MAP_CY, 1.5
    If pkZoomOut Then ZoomAt MAP_CX, MAP_CY, 1 / 1.5
    If pkApply Then ApplyPick
    If pkCancel Then pickMode = 0
    pkApply = 0
    pkCancel = 0
    pkZoomIn = 0
    pkZoomOut = 0
End Sub

' Turns the entry into the new location, saves it and asks for an update
Sub ApplyPick
    Dim As String txt
    Dim As Double la, lo
    txt = _Trim$(entry)
    If Len(txt) = 0 Then
        pickMsg = "Type a place or ZIP, or click the map"
        Exit Sub
    End If
    If ParseCoords%(txt, la, lo) Then
        sLocation = CoordStr$(la) + "," + CoordStr$(lo)
        hasPin = -1
        pinLat = la
        pinLon = lo
    Else
        sLocation = ToQuery$(txt)
        If Len(sLocation) = 0 Then
            pickMsg = "Type a place or ZIP, or click the map"
            Exit Sub
        End If
        hasPin = 0
    End If
    SaveSettings
    pickMode = 0
    hasData = 0
    errMsg = ""
    stamp = ""
    needFetch = -1
End Sub

Sub DrawPicker
    Dim As Long ii, jj, pp, pq, bx
    Dim As Single x1, y1, x2, y2, gg, gstep
    Dim As Double la, lo
    Dim As String hdr

    Cls , cBg

    ' header: title and cursor position
    Color cAccent, cBg
    _PrintString (16, 12), "Choose location"
    If my >= MAP_Y1 And my <= MAP_Y2 Then
        lo = viewLon + (mx - MAP_CX) / ppd
        la = viewLat - (my - MAP_CY) / ppd
        If la >= -90 And la <= 90 And lo >= -180 And lo <= 180 Then
            hdr = "Cursor " + CoordStr$(la) + ", " + CoordStr$(lo)
            Color cDim, cBg
            _PrintString (800 - 16 - Len(hdr) * 8, 12), hdr
        End If
    End If

    ' map, clipped to its area
    View Screen (0, MAP_Y1)-(799, MAP_Y2)
    Line (0, MAP_Y1)-(799, MAP_Y2), cBg, BF

    x1 = MAP_CX + (-180 - viewLon) * ppd
    x2 = MAP_CX + (180 - viewLon) * ppd
    y1 = MAP_CY - (90 - viewLat) * ppd
    y2 = MAP_CY - (-90 - viewLat) * ppd
    Line (x1, y1)-(x2, y2), cSea, BF

    ' graticule, spaced about 40+ pixels apart
    gstep = 30
    If 10 * ppd >= 40 Then gstep = 10
    If 5 * ppd >= 40 Then gstep = 5
    If 1 * ppd >= 40 Then gstep = 1
    If 0.25 * ppd >= 40 Then gstep = 0.25
    gg = -180
    Do While gg <= 180
        x1 = MAP_CX + (gg - viewLon) * ppd
        If x1 >= 0 And x1 <= 799 Then Line (x1, y1)-(x1, y2), cGrid
        gg = gg + gstep
    Loop
    x1 = MAP_CX + (-180 - viewLon) * ppd
    gg = -90
    Do While gg <= 90
        y1 = MAP_CY - (gg - viewLat) * ppd
        If y1 >= MAP_Y1 And y1 <= MAP_Y2 Then Line (x1, y1)-(x2, y1), cGrid
        gg = gg + gstep
    Loop

    ' coastlines (segments that jump across the date line are skipped)
    For ii = 1 To ringCount
        For jj = 0 To ringLen(ii) - 1
            pp = ringFirst(ii) + jj
            If jj = ringLen(ii) - 1 Then pq = ringFirst(ii) Else pq = pp + 1
            If Abs(ptLon(pq) - ptLon(pp)) < 180 Then
                x1 = MAP_CX + (ptLon(pp) - viewLon) * ppd
                y1 = MAP_CY - (ptLat(pp) - viewLat) * ppd
                x2 = MAP_CX + (ptLon(pq) - viewLon) * ppd
                y2 = MAP_CY - (ptLat(pq) - viewLat) * ppd
                Line (x1, y1)-(x2, y2), cLand
            End If
        Next
    Next

    ' picked point
    If candPin Then
        x1 = MAP_CX + (candLon - viewLon) * ppd
        y1 = MAP_CY - (candLat - viewLat) * ppd
        Circle (x1, y1), 6, cWarn
        Line (x1 - 10, y1)-(x1 + 10, y1), cWarn
        Line (x1, y1 - 10)-(x1, y1 + 10), cWarn
    End If
    View
    Line (0, MAP_Y1 - 1)-(799, MAP_Y1 - 1), cDim
    Line (0, MAP_Y2 + 1)-(799, MAP_Y2 + 1), cDim

    ' entry box
    Color cDim, cBg
    _PrintString (16, 386), "Place, ZIP or lat,lon:"
    bx = 200
    Line (bx, 380)-(783, 407), cBtn, BF
    Line (bx, 380)-(783, 407), cAccent, B
    Color cText, cBtn
    If (Int(Timer * 2) Mod 2) = 0 Then
        _PrintString (bx + 8, 386), entry + "_"
    Else
        _PrintString (bx + 8, 386), entry
    End If

    ' help or message line
    If Len(pickMsg) Then
        Color cWarn, cBg
        _PrintString (16, 416), pickMsg
    Else
        Color cDim, cBg
        _PrintString (16, 416), "Left-click: pick   Right-drag/arrows: pan   Wheel/PgUp/PgDn: zoom"
    End If

    If DrawBtn%(16, 440, 150, 34, "Apply (Enter)") Then pkApply = -1
    If DrawBtn%(180, 440, 90, 34, "Zoom +") Then pkZoomIn = -1
    If DrawBtn%(284, 440, 90, 34, "Zoom -") Then pkZoomOut = -1
    If DrawBtn%(650, 440, 134, 34, "Cancel (Esc)") Then pkCancel = -1
End Sub

' Zooms by fac while keeping the map point under (sx, sy) in place
Sub ZoomAt (sx As Long, sy As Long, fac As Double)
    Dim As Double la, lo
    lo = viewLon + (sx - MAP_CX) / ppd
    la = viewLat - (sy - MAP_CY) / ppd
    ppd = _Clamp(ppd * fac, minPpd, MAX_PPD)
    viewLon = lo - (sx - MAP_CX) / ppd
    viewLat = la + (sy - MAP_CY) / ppd
    ClampView
End Sub

' Keeps the view inside the world (centred when the world is smaller)
Sub ClampView
    Dim As Double halfW, halfH
    ppd = _Clamp(ppd, minPpd, MAX_PPD)
    halfW = 400 / ppd
    halfH = (MAP_H / 2) / ppd
    If halfW >= 180 Then
        viewLon = 0
    Else
        viewLon = _Clamp(viewLon, -180 + halfW, 180 - halfW)
    End If
    If halfH >= 90 Then
        viewLat = 0
    Else
        viewLat = _Clamp(viewLat, -90 + halfH, 90 - halfH)
    End If
End Sub

' Reads the coastline DATA into the ring and point arrays
Sub LoadWorld
    Dim As Long nr, ii, jj, np, total, dd, xx, yy, ddx, ddy, pn
    Restore WorldData
    Read nr
    total = 0
    For ii = 1 To nr
        Read np
        total = total + np
        For jj = 1 To np * 2
            Read dd
        Next
    Next
    ReDim ringFirst(1 To nr) As Long
    ReDim ringLen(1 To nr) As Long
    ReDim ptLon(1 To total) As Single
    ReDim ptLat(1 To total) As Single

    Restore WorldData
    Read nr
    pn = 0
    For ii = 1 To nr
        Read np
        ringFirst(ii) = pn + 1
        ringLen(ii) = np
        Read xx, yy
        pn = pn + 1
        ptLon(pn) = xx / 10
        ptLat(pn) = yy / 10
        For jj = 2 To np
            Read ddx, ddy
            xx = xx + ddx
            yy = yy + ddy
            pn = pn + 1
            ptLon(pn) = xx / 10
            ptLat(pn) = yy / 10
        Next
    Next
    ringCount = nr
End Sub

'---------------------------------------------------------------
' Location text helpers
'---------------------------------------------------------------
' True (-1) when s is "lat,lon" with both numbers in range
Function ParseCoords% (s As String, la As Double, lo As Double)
    Dim As Long cm, ii, digits, cc
    Dim As String p1, p2
    Dim As Double a1, a2
    cm = InStr(s, ",")
    If cm = 0 Then Exit Function
    If InStr(cm + 1, s, ",") Then Exit Function
    p1 = _Trim$(Left$(s, cm - 1))
    p2 = _Trim$(Mid$(s, cm + 1))
    If Len(p1) = 0 Or Len(p2) = 0 Then Exit Function
    For ii = 1 To Len(s)
        cc = Asc(s, ii)
        Select Case cc
            Case 48 To 57: digits = digits + 1
            Case 32, 43, 44, 45, 46
            Case Else: Exit Function
        End Select
    Next
    If digits < 2 Then Exit Function
    a1 = Val(p1)
    a2 = Val(p2)
    If a1 < -90 Or a1 > 90 Or a2 < -180 Or a2 > 180 Then Exit Function
    la = a1
    lo = a2
    ParseCoords% = -1
End Function

' Letters, digits, space and , . - + ~ @ are safe in a wttr.in URL
Function AllowedChar% (cc As Long)
    Dim As Long ok
    Select Case cc
        Case 48 To 57, 65 To 90, 97 To 122: ok = -1
        Case 32, 43, 44, 45, 46, 64, 126: ok = -1
    End Select
    AllowedChar% = ok
End Function

' Spaces and commas become single plus signs (Dallas, TX -> Dallas+TX)
Function ToQuery$ (s As String)
    Dim As Long ii
    Dim As String cc, r
    For ii = 1 To Len(s)
        cc = Mid$(s, ii, 1)
        If cc = " " Or cc = "," Then cc = "+"
        If cc = "+" Then
            If Len(r) > 0 And Right$(r, 1) <> "+" Then r = r + "+"
        Else
            r = r + cc
        End If
    Next
    If Right$(r, 1) = "+" Then r = Left$(r, Len(r) - 1)
    ToQuery$ = r
End Function

' Degrees with three decimals, e.g. -111.597
Function CoordStr$ (v As Double)
    Dim As Long r, ip, fp
    Dim As String sg
    r = CLng(v * 1000)
    If r < 0 Then
        sg = "-"
        r = -r
    End If
    ip = r \ 1000
    fp = r Mod 1000
    CoordStr$ = sg + _Trim$(Str$(ip)) + "." + Right$("00" + _Trim$(Str$(fp)), 3)
End Function

'---------------------------------------------------------------
' Settings file
'---------------------------------------------------------------
Sub LoadSettings
    Dim As Long ff, eq
    Dim As String ln, kname, kv
    If _FileExists("WeatherGUI.ini") = 0 Then Exit Sub
    ff = FreeFile
    Open "WeatherGUI.ini" For Input As #ff
    Do While Not EOF(ff)
        Line Input #ff, ln
        eq = InStr(ln, "=")
        If eq > 0 Then
            kname = UCase$(_Trim$(Left$(ln, eq - 1)))
            kv = _Trim$(Mid$(ln, eq + 1))
            Select Case kname
                Case "LOCATION"
                    If Len(kv) Then sLocation = kv
                Case "UNITS"
                    If kv = "u" Or kv = "m" Then units = kv
                Case "HASPIN"
                    hasPin = (Val(kv) <> 0)
                Case "PINLAT"
                    pinLat = Val(kv)
                Case "PINLON"
                    pinLon = Val(kv)
            End Select
        End If
    Loop
    Close #ff
End Sub

Sub SaveSettings
    Dim As Long ff
    ff = FreeFile
    Open "WeatherGUI.ini" For Output As #ff
    Print #ff, "Location=" + sLocation
    Print #ff, "Units=" + units
    If hasPin Then Print #ff, "HasPin=1" Else Print #ff, "HasPin=0"
    Print #ff, "PinLat=" + CoordStr$(pinLat)
    Print #ff, "PinLon=" + CoordStr$(pinLon)
    Close #ff
End Sub
