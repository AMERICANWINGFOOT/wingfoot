'==============================================================================
' USS GPU MONITOR - Tactical Status
'==============================================================================
' LCARS-styled NVIDIA GPU monitor for QB64-PE (Linux). Companion to
' USSMonitor.bas - same header/sidebar/pill-bar look.
'
' Shows, for the selected GPU: core load, VRAM (+ memory bus load),
' temperature, power draw vs. limit, fan speed, clocks, P-state and
' driver version, plus a 120-second load/VRAM history graph. A "fleet"
' strip at the bottom shows load for every GPU at once.
'
' Stats come from gpumon.h via DECLARE LIBRARY. It runs nvidia-smi once
' per refresh and caches all GPUs; values a card doesn't report show N/A.
'
' Controls:
'   GPU n buttons / fleet strip / keys 0-7 - pick which GPU gets the detail view
'   Tab            - next GPU
'   SWITCH F / C   - temperature units (or press F / C)
'   PAUSE/RESUME   - freeze polling, keep last values on screen
'   CLEAR LOG      - wipe history graphs
'   QUIT / ESC     - exit
'
' Dependencies: ButtonUI.bi / ButtonUI.bm, gpumon.h
'==============================================================================

'$Include:'ButtonUI.bi'

Declare Library "gpumon"
    Function GPUMonRefresh& ()
    Function GPUMonCount& ()
    Function GPUMonValue# (ByVal idx As Long, ByVal fld As Long)
    Sub GPUMonText (ByVal idx As Long, ByVal which As Long, buf As String, ByVal buflen As Long)
End Declare

' --- gpumon field indexes (must match gpumon.h) ---
Const GF_UTIL = 0
Const GF_MEMUTIL = 1
Const GF_MEMUSED = 2
Const GF_MEMTOTAL = 3
Const GF_TEMP = 4
Const GF_POWER = 5
Const GF_PLIMIT = 6
Const GF_CLK = 7
Const GF_CLKMAX = 8
Const GF_MEMCLK = 9
Const GF_FAN = 10
Const GF_INDEX = 11
Const GT_NAME = 0
Const GT_PSTATE = 1
Const GT_DRIVER = 2

' --- Layout ---
Const MAX_GPUS = 8
Const HEADER_Y = 20
Const HEADER_H = 50
Const SIDEBAR_X = 20
Const SIDEBAR_W = 80
Const SIDEBAR_TOP = 90
Const SIDEBAR_BOTTOM = 690
Const CONTENT_X = 120
Const CONTENT_RIGHT = 620
Const BAR_H = 30
Const GRAPH_Y = 456
Const GRAPH_H = 170
Const FLEET_Y = 652
Const HIST_LEN = 120
Const REFRESH_SECONDS = 1

' --- LCARS palette ---
Dim Shared colOrange As _Unsigned Long, colOrangeHi As _Unsigned Long
Dim Shared colTan As _Unsigned Long, colLilac As _Unsigned Long
Dim Shared colBlueViolet As _Unsigned Long, colGold As _Unsigned Long
Dim Shared colAlertRed As _Unsigned Long, colTrack As _Unsigned Long
Dim Shared colText As _Unsigned Long, colPanelBorder As _Unsigned Long
Dim Shared colGrid As _Unsigned Long

' --- State ---
Dim gpuCount As Long, sel As Long, g As Long, j As Long
Dim utilHist(0 To MAX_GPUS - 1, 1 To HIST_LEN) As Double
Dim vramHist(0 To MAX_GPUS - 1, 1 To HIST_LEN) As Double
Dim histCount(0 To MAX_GPUS - 1) As Long
Dim useF As Integer, doQuit As Integer, doPause As Integer
Dim lastUpdate As Double, kh As Long

' --- Per-frame scratch ---
Dim u As Double, v As Double, t As Double, peak As Double
Dim pw As Double, pl As Double, pp As Double, fanPct As Double, mbus As Double
Dim s As String, nm As String
Dim bx As Integer, slotW As Integer, fx As Integer, fw As Integer, w As Integer
Dim gy As Integer
Dim stepX As Single, x1 As Single, x2 As Single

Screen _NewImage(640, 780, 32)
_FullScreen _SquarePixels
_PrintMode _KeepBackground
_Title "USS GPU MONITOR - Tactical Status"
MouseInit

colOrange = _RGB32(255, 153, 0)
colOrangeHi = _RGB32(255, 187, 102)
colTan = _RGB32(255, 204, 153)
colLilac = _RGB32(204, 153, 255)
colBlueViolet = _RGB32(153, 153, 255)
colGold = _RGB32(255, 204, 0)
colAlertRed = _RGB32(204, 0, 0)
colTrack = _RGB32(40, 40, 60)
colText = _RGB32(255, 204, 102)
colPanelBorder = _RGB32(153, 153, 255)
colGrid = _RGB32(35, 35, 55)

uiFace = colOrange
uiFaceHover = colOrangeHi
uiFaceDown = _RGB32(204, 102, 0)
uiText = _RGB32(0, 0, 0)
uiLight = colTan
uiDark = _RGB32(153, 76, 0)
uiDisFace = _RGB32(60, 60, 60)
uiDisText = _RGB32(120, 120, 120)

sel = 0
useF = 0
doQuit = 0
doPause = 0
lastUpdate = -1 ' forces an immediate first poll

Do
    _Limit 30
    PollMouse

    kh = _KeyHit
    If kh = 27 Then doQuit = -1
    If kh = 99 Or kh = 67 Then useF = 0 ' c / C
    If kh = 102 Or kh = 70 Then useF = -1 ' f / F  (-1, not 1: Not is bitwise)
    If kh >= 48 And kh <= 55 Then
        If kh - 48 < gpuCount Then sel = kh - 48
    End If
    If kh = 9 And gpuCount > 0 Then sel = (sel + 1) Mod gpuCount

    ' --- Poll nvidia-smi once per REFRESH_SECONDS ---
    If Not doPause Then
        If Timer < lastUpdate Then lastUpdate = -1 ' midnight rollover
        If lastUpdate < 0 Or Timer - lastUpdate >= REFRESH_SECONDS Then
            lastUpdate = Timer
            gpuCount = GPUMonRefresh&
            If gpuCount > MAX_GPUS Then gpuCount = MAX_GPUS
            For g = 0 To gpuCount - 1
                u = GPUMonValue#(g, GF_UTIL)
                If u < 0 Then u = 0
                v = VramPct#(g)
                If v < 0 Then v = 0
                If histCount(g) < HIST_LEN Then
                    histCount(g) = histCount(g) + 1
                    utilHist(g, histCount(g)) = u
                    vramHist(g, histCount(g)) = v
                Else
                    For j = 1 To HIST_LEN - 1
                        utilHist(g, j) = utilHist(g, j + 1)
                        vramHist(g, j) = vramHist(g, j + 1)
                    Next j
                    utilHist(g, HIST_LEN) = u
                    vramHist(g, HIST_LEN) = v
                End If
            Next g
        End If
    End If
    If sel >= gpuCount Then sel = 0

    Cls , _RGB32(0, 0, 0)
    Color colText

    If doPause Then
        Color colAlertRed
        _PrintString (540, 4), "* PAUSED *"
        Color colText
    End If

    ' --- Header ---
    RoundRect 20, HEADER_Y, CONTENT_RIGHT, HEADER_Y + HEADER_H, HEADER_H \ 2, colOrange
    Color _RGB32(0, 0, 0)
    _PrintString (60, HEADER_Y + 17), "GPU CORE - TACTICAL STATUS"
    _PrintString (420, HEADER_Y + 17), "STARDATE " + Stardate$
    Color colText

    ' --- Sidebar spine (decorative) ---
    DrawSidebar

    If gpuCount = 0 Then
        Color colAlertRed
        _PrintString (CONTENT_X, 110), "NO NVIDIA GPU DETECTED"
        Color colText
        _PrintString (CONTENT_X, 134), "nvidia-smi not found or returned no data."
        _PrintString (CONTENT_X, 152), "Retrying every " + _Trim$(Str$(REFRESH_SECONDS)) + " second(s)..."
    Else
        ' --- GPU selector buttons ---
        slotW = (CONTENT_RIGHT - CONTENT_X + 8) \ gpuCount
        For g = 0 To gpuCount - 1
            bx = CONTENT_X + g * slotW
            If g = sel Then
                uiFace = colLilac
                uiFaceHover = colLilac
            End If
            If Button%(bx, 90, slotW - 8, 26, "GPU " + _Trim$(Str$(CLng(GPUMonValue#(g, GF_INDEX))))) Then sel = g
            uiFace = colOrange
            uiFaceHover = colOrangeHi
        Next g

        ' --- Identity lines ---
        nm = GpuText$(sel, GT_NAME)
        If Len(nm) > 50 Then nm = Left$(nm, 50)
        Color colTan
        _PrintString (CONTENT_X, 124), "UNIT " + _Trim$(Str$(CLng(GPUMonValue#(sel, GF_INDEX)))) + ": " + nm
        Color colText
        _PrintString (CONTENT_X, 142), "STATE " + GpuText$(sel, GT_PSTATE) + "   DRIVER " + GpuText$(sel, GT_DRIVER)

        ' --- Core load ---
        u = GPUMonValue#(sel, GF_UTIL)
        PillBar 162, u, (u >= 0)
        peak = 0
        For j = 1 To histCount(sel)
            If utilHist(sel, j) > peak Then peak = utilHist(sel, j)
        Next j
        If u >= 0 Then
            _PrintString (CONTENT_X, 196), "GPU CORE LOAD:" + Fmt1$(u) + "%   LOG PEAK:" + Fmt1$(peak) + "%"
        Else
            _PrintString (CONTENT_X, 196), "GPU CORE LOAD: N/A"
        End If

        ' --- VRAM ---
        v = VramPct#(sel)
        PillBar 216, v, (v >= 0)
        If v >= 0 Then
            s = "VRAM: " + NumStr$(GPUMonValue#(sel, GF_MEMUSED)) + " / " + NumStr$(GPUMonValue#(sel, GF_MEMTOTAL)) + " MB (" + _Trim$(Fmt1$(v)) + "%)"
            mbus = GPUMonValue#(sel, GF_MEMUTIL)
            If mbus >= 0 Then s = s + "   BUS: " + NumStr$(mbus) + "%"
        Else
            s = "VRAM: N/A"
        End If
        _PrintString (CONTENT_X, 250), s

        ' --- Temperature (fixed 0-100 C bar scale) ---
        t = GPUMonValue#(sel, GF_TEMP)
        PillBar 270, t, (t >= 0)
        If t < 0 Then
            s = "THERMAL: N/A"
        ElseIf useF Then
            s = "THERMAL:" + Fmt1$(t * 9 / 5 + 32) + " F"
        Else
            s = "THERMAL:" + Fmt1$(t) + " C"
        End If
        _PrintString (CONTENT_X, 304), s

        ' --- Power draw vs. limit ---
        pw = GPUMonValue#(sel, GF_POWER)
        pl = GPUMonValue#(sel, GF_PLIMIT)
        If pw >= 0 And pl > 0 Then pp = pw / pl * 100 Else pp = -1
        PillBar 324, pp, (pp >= 0)
        If pw >= 0 Then
            s = "POWER: " + _Trim$(Fmt1$(pw)) + " W"
            If pl > 0 Then s = s + " / " + _Trim$(Fmt1$(pl)) + " W LIMIT (" + _Trim$(Fmt1$(pp)) + "%)"
        Else
            s = "POWER: N/A (not reported by this card)"
        End If
        _PrintString (CONTENT_X, 358), s

        ' --- Fan ---
        fanPct = GPUMonValue#(sel, GF_FAN)
        PillBar 378, fanPct, (fanPct >= 0)
        If fanPct >= 0 Then
            s = "COOLANT FAN:" + Fmt1$(fanPct) + "%"
        Else
            s = "COOLANT FAN: N/A (passive / not reported)"
        End If
        _PrintString (CONTENT_X, 412), s

        ' --- Clocks ---
        _PrintString (CONTENT_X, 432), "CLOCKS: GFX " + NumStr$(GPUMonValue#(sel, GF_CLK)) + " / " + NumStr$(GPUMonValue#(sel, GF_CLKMAX)) + " MHZ   MEM " + NumStr$(GPUMonValue#(sel, GF_MEMCLK)) + " MHZ"

        ' --- History graph: load (orange) + VRAM (lilac) ---
        Line (CONTENT_X, GRAPH_Y)-(CONTENT_RIGHT, GRAPH_Y + GRAPH_H), _RGB32(10, 10, 20), BF
        For j = 1 To 3
            gy = GRAPH_Y + GRAPH_H - (j * GRAPH_H) \ 4
            Line (CONTENT_X + 1, gy)-(CONTENT_RIGHT - 1, gy), colGrid
        Next j
        Line (CONTENT_X, GRAPH_Y)-(CONTENT_RIGHT, GRAPH_Y + GRAPH_H), colPanelBorder, B
        If histCount(sel) > 1 Then
            stepX = (CONTENT_RIGHT - CONTENT_X) / (HIST_LEN - 1)
            For j = 1 To histCount(sel) - 1
                x1 = CONTENT_X + (j - 1) * stepX
                x2 = CONTENT_X + j * stepX
                Line (x1, GraphY!(vramHist(sel, j)))-(x2, GraphY!(vramHist(sel, j + 1))), colLilac
                Line (x1, GraphY!(utilHist(sel, j)))-(x2, GraphY!(utilHist(sel, j + 1))), colOrange
            Next j
        End If
        s = "SENSOR LOG (LAST " + _Trim$(Str$(HIST_LEN * REFRESH_SECONDS)) + "S): "
        _PrintString (CONTENT_X, GRAPH_Y + GRAPH_H + 4), s
        Color colOrange
        _PrintString (CONTENT_X + Len(s) * 8, GRAPH_Y + GRAPH_H + 4), "LOAD"
        Color colLilac
        _PrintString (CONTENT_X + (Len(s) + 6) * 8, GRAPH_Y + GRAPH_H + 4), "VRAM"
        Color colText

        ' --- Fleet strip: every GPU's load at a glance (click to select) ---
        fw = (CONTENT_RIGHT - CONTENT_X) \ gpuCount
        For g = 0 To gpuCount - 1
            fx = CONTENT_X + g * fw
            Line (fx + 2, FLEET_Y)-(fx + fw - 4, FLEET_Y + 26), colTrack, BF
            u = GPUMonValue#(g, GF_UTIL)
            If u > 0 Then
                w = _Clamp(u / 100 * (fw - 6), 0, fw - 6)
                Line (fx + 2, FLEET_Y)-(fx + 2 + w, FLEET_Y + 26), BarColor&(u), BF
            End If
            If g = sel Then Line (fx + 1, FLEET_Y - 1)-(fx + fw - 3, FLEET_Y + 27), colLilac, B
            _PrintString (fx + 2, FLEET_Y + 30), _Trim$(Str$(CLng(GPUMonValue#(g, GF_INDEX)))) + ":" + NumStr$(u) + "%"
            If gMouse.clicked Then
                If PtInRect%(gMouse.mx, gMouse.my, fx, FLEET_Y, fw, 26) Then sel = g
            End If
        Next g
    End If

    ' --- Button row ---
    If Button%(20, 710, 140, 30, "SWITCH F / C") Then useF = Not useF
    If doPause Then
        If Button%(180, 710, 120, 30, "RESUME") Then doPause = 0
    Else
        If Button%(180, 710, 120, 30, "PAUSE") Then doPause = -1
    End If
    If Button%(320, 710, 120, 30, "CLEAR LOG") Then
        For g = 0 To MAX_GPUS - 1
            histCount(g) = 0
        Next g
    End If
    If Button%(520, 710, 100, 30, "QUIT") Then doQuit = -1

    _Display
Loop Until doQuit

System

'------------------------------------------------------------------------------

' Track + colored fill pill. valid = -1/0; invalid draws the empty track only.
Sub PillBar (y As Integer, pct As Double, valid As Integer)
    Dim bw As Integer
    RoundRect CONTENT_X, y, CONTENT_RIGHT, y + BAR_H, BAR_H \ 2, colTrack
    If valid Then
        bw = _Clamp(pct / 100 * (CONTENT_RIGHT - CONTENT_X), 0, CONTENT_RIGHT - CONTENT_X)
        If bw > BAR_H Then RoundRect CONTENT_X, y, CONTENT_X + bw, y + BAR_H, BAR_H \ 2, BarColor&(pct)
    End If
End Sub

Sub DrawSidebar
    Dim sbGap As Integer, sbBandH As Integer, sbStartY As Integer, b As Integer
    Dim bandY As Integer, bandCol As _Unsigned Long
    RoundRect SIDEBAR_X, SIDEBAR_TOP, SIDEBAR_X + SIDEBAR_W, SIDEBAR_BOTTOM, SIDEBAR_W \ 2, _RGB32(50, 30, 70)
    sbGap = 10
    sbStartY = SIDEBAR_TOP + (SIDEBAR_W \ 2) + 6
    sbBandH = (SIDEBAR_BOTTOM - (SIDEBAR_W \ 2) - sbStartY - sbGap * 4) \ 5
    For b = 0 To 4
        bandY = sbStartY + b * (sbBandH + sbGap)
        Select Case b
            Case 0: bandCol = colOrange
            Case 1: bandCol = colTan
            Case 2: bandCol = colLilac
            Case 3: bandCol = colBlueViolet
            Case Else: bandCol = colGold
        End Select
        Line (SIDEBAR_X + 5, bandY)-(SIDEBAR_X + SIDEBAR_W - 5, bandY + sbBandH), bandCol, BF
    Next b
End Sub

Function VramPct# (g As Long)
    Dim mu As Double, mt As Double
    mu = GPUMonValue#(g, GF_MEMUSED)
    mt = GPUMonValue#(g, GF_MEMTOTAL)
    If mu < 0 Or mt <= 0 Then
        VramPct# = -1
    Else
        VramPct# = mu / mt * 100
    End If
End Function

Function GpuText$ (g As Long, what As Long)
    Dim buf As String, z As Long
    buf = Space$(128)
    GPUMonText g, what, buf, 128
    z = InStr(buf, Chr$(0))
    If z > 0 Then buf = Left$(buf, z - 1)
    GpuText$ = _Trim$(buf)
End Function

Function GraphY! (pct As Double)
    GraphY! = GRAPH_Y + GRAPH_H - 1 - _Clamp(pct, 0, 100) / 100 * (GRAPH_H - 2)
End Function

Function Stardate$
    Dim ds As String, sd As Long
    ds = Date$
    sd = (Val(Right$(ds, 4)) - 1976) * 1000 + Val(Left$(ds, 2)) * 30 + Val(Mid$(ds, 4, 2))
    Stardate$ = _Trim$(Str$(sd))
End Function

Function BarColor& (pct As Double)
    If pct < 50 Then
        BarColor& = _RGB32(255, 153, 0)
    ElseIf pct < 80 Then
        BarColor& = _RGB32(255, 204, 0)
    Else
        BarColor& = _RGB32(204, 0, 0)
    End If
End Function

' Whole number, or "N/A" for the -1 "not reported" value
Function NumStr$ (x As Double)
    If x < 0 Then
        NumStr$ = "N/A"
    Else
        NumStr$ = _Trim$(Str$(CLng(x)))
    End If
End Function

' 1 decimal, left-padded to 5 chars so mid-line values don't jitter.
' Works on a local copy so the caller's variable is never modified.
Function Fmt1$ (x As Double)
    Dim n As Double, whole As Long, dec As Long, s As String
    n = x
    If n < 0 Then n = 0
    whole = Int(n)
    dec = Int((n - whole) * 10 + 0.5)
    If dec >= 10 Then whole = whole + 1: dec = 0
    s = _Trim$(Str$(whole)) + "." + _Trim$(Str$(dec))
    Do While Len(s) < 5
        s = " " + s
    Loop
    Fmt1$ = s
End Function

Sub CircleFillHelper (cx As Integer, cy As Integer, r As Integer, col As _Unsigned Long)
    Circle (cx, cy), r, col
    Paint (cx, cy), col, col
End Sub

Sub RoundRect (x1 As Integer, y1 As Integer, x2 As Integer, y2 As Integer, r As Integer, col As _Unsigned Long)
    Line (x1 + r, y1)-(x2 - r, y2), col, BF
    Line (x1, y1 + r)-(x2, y2 - r), col, BF
    CircleFillHelper x1 + r, y1 + r, r, col
    CircleFillHelper x2 - r, y1 + r, r, col
    CircleFillHelper x1 + r, y2 - r, r, col
    CircleFillHelper x2 - r, y2 - r, r, col
End Sub

'$Include:'ButtonUI.bm'
