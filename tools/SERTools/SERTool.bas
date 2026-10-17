' ============================================================================
' SERTool.bas  -  Button-driven launcher for the SER PPIP toolkit
'
' One window, three tools: Stacker, Player, Center. A menu picks the tool; each
' tool's panel has its key actions (Choose File / Start / Back) plus a few LIVE
' settings you change with buttons instead of editing constants and recompiling.
'
' The pipeline it front-ends:  SharpCap .ser  ->  Center  ->  Stack  ->  image.
' It drives the SAME engine routines the standalone programs use, from live
' variables instead of Const values.
'
' Put these in one folder with it:
'   SERCommon.bi   ButtonUI.bi   ButtonUI.bm
'   SERPlayLib.bm  SERCenterCore.bm  SERFmtMono.bm  SERStackLib.bm
' ============================================================================

'$Include:'SERCommon.bi'
'$Include:'ButtonUI.bi'

' These two Consts only satisfy helper routines we include but never call
' directly (PlaySER wants PLAY_FPS; AutoThresh& wants THRESH_MULT). The
' launcher drives playback and thresholding from live variables instead.
Const PLAY_FPS = 30
Const THRESH_MULT = 3
Const STAR_BOX = 10 ' +/- search radius (px) for tracking a picked star
Const PATCH_R = 12 ' surface feature patch is (2*PATCH_R+1) square
Const SURF_SEARCH = 12 ' +/- search radius (px) for block-matching the feature
Const STACK_BOX = 26 ' larger star search for cross-file re-acquisition
Const STACK_SEARCH = 26 ' larger patch search for cross-file surface align
' Where the plate-solve FITS is written (SynScan Pro's watch folder).
' Edit to match your machine; falls back to the current folder if missing.
Const FITS_DIR = "H:\Astronomy\synscanpro_windows_2611\SynScanPro\fits\"
' Plate solver executable + optional scale hint (min,max degrees field width).
' Leave SOLVER_SCALE empty for a blind solve (slower). Edit to your rig.
Const SOLVER_DIR = "H:\Astronomy\synscanpro_windows_2611\SynScanPro"
Const SOLVER_EXE = "platesolver.exe"
Const SOLVER_SCALE = "0.3,15"

' --- App states ---
Const ST_MENU = 0
Const ST_STACK = 1
Const ST_PLAYER = 2
Const ST_CENTER = 3
Const ST_VIEWER = 4
Const ST_PROCESS = 5
Const ST_STACKSET = 6
Const ST_DEBAYER = 7
Const ST_SOLVE = 8
Const ST_QUIT = -1

' --- SER engine state (union of what the included helpers read) ---
Dim Shared g_fnum As Integer, g_inNum As Integer, g_outNum As Integer
Dim Shared g_w As Long, g_h As Long, g_colorID As Long, g_depth As Long
Dim Shared g_frameCount As Long, g_littleEndian As Long, g_planes As Long, g_sampleBytes As Long
Dim Shared g_frameBytes As _Integer64
Dim Shared g_dataStart As Long, g_bpp As Long
Dim Shared g_cropW As Long, g_cropH As Long, g_cropBytes As Long, g_written As Long

' --- Live settings the buttons change ---
Dim Shared setKeepPct As Long ' % of best frames to stack
Dim Shared setPlayFps As Long
Dim Shared setCrop As Long
Dim Shared setFullSize As Long ' -1 = keep full frame size, 0 = crop to setCrop
Dim Shared setTarget As Long ' TGT_PLANET / TGT_DSO / TGT_OFF
Dim Shared setThreshMult As Long
Dim Shared setPreview As Long ' -1 / 0
Dim Shared setInPath As String
Dim Shared gHub As Long ' the launcher's own screen (restored after runs)
Dim Shared gRptFont As Long ' big monospace for report/result screens

' --- 3-star DSO alignment state ---
Dim Shared refStarX(0 To 2) As Double, refStarY(0 To 2) As Double ' reference frame
Dim Shared trackX(0 To 2) As Double, trackY(0 To 2) As Double ' current guess

' --- Surface (crater) tracking state ---
Dim Shared refCX As Long, refCY As Long ' reference feature centre
Dim Shared trackCX As Double, trackCY As Double ' current guess
Dim Shared gSurfPatch(0 To (2 * PATCH_R + 1) * (2 * PATCH_R + 1) - 1) As Long

' --- Multi-file (Stack Set) state ---
Dim Shared gStackFiles(1 To 500) As String ' selected SER paths
Dim Shared gStackCount As Long

setKeepPct = 50
setPlayFps = 30
setCrop = 400
setFullSize = -1
setTarget = TGT_PLANET
setThreshMult = 3
setPreview = -1
setInPath = ""

gHub = _NewImage(680, 384, 32)

Screen gHub
_FullScreen
_FullScreen _SquarePixels
GoFull
_Title "SER PPIP Toolkit"
InitReportFont '  <-- add this

Rem REM _ScreenMove _Middle
MouseInit

Dim state As Long
state = ST_MENU

Do
    _Limit 60
    PollMouse
    Cls , _RGB32(24, 26, 32)
    _PrintMode _KeepBackground

    Select Case state
        Case ST_MENU: state = DoMenu&
        Case ST_STACK: state = DoStacker&
        Case ST_PLAYER: state = DoPlayer&
        Case ST_CENTER: state = DoCenter&
        Case ST_VIEWER: state = DoViewer&
        Case ST_PROCESS: state = DoProcess&
        Case ST_STACKSET: state = DoStackSet&
        Case ST_DEBAYER: state = DoDebayer&
        Case ST_SOLVE: state = DoSolve&
    End Select

    _Display
Loop Until state = ST_QUIT Or _Exit

System

' ============================================================================
' PANELS  -  each draws itself and returns the next state
' ============================================================================

Function DoMenu&
    DoMenu& = ST_MENU
    Color uiText
    _PrintString (232, 32), "SER PPIP Toolkit"
    If Button%(70, 70, 180, 38, "SER Process") Then DoMenu& = ST_PROCESS
    If Button%(70, 112, 180, 38, "SER Center") Then DoMenu& = ST_CENTER
    If Button%(70, 154, 180, 38, "SER Stacker") Then DoMenu& = ST_STACK
    If Button%(70, 196, 180, 38, "SER Debayer") Then DoMenu& = ST_DEBAYER
    If Button%(310, 70, 180, 38, "SER Stack Set") Then DoMenu& = ST_STACKSET
    If Button%(310, 112, 180, 38, "SER Viewer") Then DoMenu& = ST_VIEWER
    If Button%(310, 154, 180, 38, "SER Player") Then DoMenu& = ST_PLAYER
    If Button%(310, 196, 180, 38, "Plate Solve") Then DoMenu& = ST_SOLVE
    If Button%(190, 254, 180, 34, "Quit") Then DoMenu& = ST_QUIT
End Function

Function DoStacker&
    DoStacker& = ST_STACK
    Color uiText
    _PrintString (20, 18), "SER Stacker  -  writes stacked.ser"
    _PrintString (20, 52), "Expects a centered .ser (run Center first)."
    _PrintString (20, 92), "File : " + FileLabel$(setInPath)
    If Button%(410, 86, 130, 28, "Choose File") Then PickFile
    _PrintString (20, 132), "Keep best :" + Str$(setKeepPct) + "%"
    If Button%(200, 126, 120, 28, "25/50/75/100") Then setKeepPct = NextKeep&(setKeepPct)
    If Button%(20, 214, 180, 42, "Start / Stack") Then RunStacker
    If Button%(220, 214, 110, 42, "Back") Then DoStacker& = ST_MENU
End Function

Function DoProcess&
    DoProcess& = ST_PROCESS
    Color uiText
    _PrintString (20, 14), "SER Process  -  center + stack -> stacked.ser"
    _PrintString (20, 42), "File : " + FileLabel$(setInPath)
    If Button%(410, 36, 130, 24, "Choose File") Then PickFile

    _PrintString (20, 70), "Target : " + TargetLabel$
    If Button%(280, 64, 130, 24, "Planet/DSO/Off") Then setTarget = NextTarget&(setTarget)

    _PrintString (20, 98), "Size : " + SizeLabel$
    If Button%(280, 92, 130, 24, "Full / Crop") Then setFullSize = Not setFullSize

    _PrintString (20, 126), "Crop :" + Str$(setCrop)
    If Button%(150, 120, 36, 24, "-") Then
        setCrop = setCrop - 50
        If setCrop < 100 Then setCrop = 100
    End If
    If Button%(194, 120, 36, 24, "+") Then
        setCrop = setCrop + 50
        If setCrop > 1200 Then setCrop = 1200
    End If

    _PrintString (20, 154), "Keep best :" + Str$(setKeepPct) + "%"
    If Button%(200, 148, 120, 24, "25/50/75/100") Then setKeepPct = NextKeep&(setKeepPct)

    If Button%(20, 200, 190, 42, "Start / Process") Then RunProcess
    If Button%(240, 200, 110, 42, "Back") Then DoProcess& = ST_MENU
End Function

Function DoStackSet&
    DoStackSet& = ST_STACKSET
    Color uiText
    _PrintString (20, 14), "SER Stack Set  -  align + stack many files"
    _PrintString (20, 44), "Files :" + Str$(gStackCount) + " selected"
    If Button%(300, 38, 150, 26, "Select Files") Then SelectStackFiles

    _PrintString (20, 76), "Target : " + TargetLabel$
    If Button%(280, 70, 130, 26, "Planet/DSO/Off") Then setTarget = NextTarget&(setTarget)

    _PrintString (20, 108), "Size : " + SizeLabel$
    If Button%(280, 102, 130, 26, "Full / Crop") Then setFullSize = Not setFullSize

    _PrintString (20, 140), "Crop :" + Str$(setCrop)
    If Button%(150, 134, 36, 26, "-") Then
        setCrop = setCrop - 50
        If setCrop < 100 Then setCrop = 100
    End If
    If Button%(194, 134, 36, 26, "+") Then
        setCrop = setCrop + 50
        If setCrop > 1200 Then setCrop = 1200
    End If

    If Button%(20, 200, 200, 42, "Start / Stack Set") Then RunStackSet
    If Button%(250, 200, 110, 42, "Back") Then DoStackSet& = ST_MENU
End Function

' Multi-select SER files; _OpenFileDialog$ returns them '|'-delimited.
Sub SelectStackFiles
    Dim s As String
    s = _OpenFileDialog$("Select SER files (multi-select)", "", "*.ser", "SER files", -1)
    If s = "" Then Exit Sub
    gStackCount = 0
    Dim p As Long, segg As String
    Do
        p = InStr(s, "|")
        If p > 0 Then
            segg = Left$(s, p - 1): s = Mid$(s, p + 1)
        Else
            segg = s: s = ""
        End If
        If segg <> "" And gStackCount < 500 Then
            gStackCount = gStackCount + 1
            gStackFiles(gStackCount) = segg
        End If
    Loop While s <> ""
End Sub

Function DoDebayer&
    DoDebayer& = ST_DEBAYER
    Color uiText
    _PrintString (20, 22), "SER Debayer  -  RAW/Bayer -> colour RGB SER"
    _PrintString (20, 52), "Uses the file's Bayer pattern (RGGB / GRBG / ...)."
    _PrintString (20, 92), "File : " + FileLabel$(setInPath)
    If Button%(410, 86, 130, 28, "Choose File") Then PickFile
    If Button%(20, 214, 180, 42, "Start / Debayer") Then RunDebayer
    If Button%(220, 214, 110, 42, "Back") Then DoDebayer& = ST_MENU
End Function

' ============================================================================
' DEBAYER  -  demosaic a RAW/Bayer SER into a colour RGB SER
' ============================================================================
Sub RunDebayer
    If setInPath = "" Then Exit Sub
    g_inNum = FreeFile
    Open setInPath For Binary As #g_inNum
    ReadInHeader

    If Not IsBayer%(g_colorID) Then
        StackMsg "Input is not a RAW/Bayer SER (nothing to demosaic)."
        Close #g_inNum: _Delay 2: Exit Sub
    End If
    If g_frameCount < 1 Then Close #g_inNum: Exit Sub

    Dim bayerID As Long: bayerID = g_colorID ' remember the mosaic pattern

    ' Buffers: mono input frame, RGB output frame
    Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
    Dim obytes As Long: obytes = g_w * g_h * 3 * g_sampleBytes
    Dim outM As _MEM: outM = _MemNew(obytes)
    Dim frameStr As String: frameStr = Space$(g_frameBytes)
    Dim outBuf As String: outBuf = Space$(obytes)

    ' Output header describes an RGB SER (same depth / dims / frame count)
    g_cropW = g_w: g_cropH = g_h
    g_colorID = SER_RGB
    g_planes = 3 ' so the result preview shows colour

    Dim pad$
    $If WIN Then
        pad$ = "\"
    $Else
        pad$ = "/"
    $End If
    Dim outpath As String
    outpath = _CWD$ + pad$ + "debayered.ser"
    OpenOutSER outpath

    Dim fr As Long, aborted As Integer
    aborted = 0
    For fr = 1 To g_frameCount
        Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
        _MemPut srcM, srcM.OFFSET, frameStr
        DebayerFrame srcM, g_w, g_h, g_sampleBytes, g_littleEndian, bayerID, outM
        _MemGet outM, outM.OFFSET, outBuf
        Put #g_outNum, , outBuf
        g_written = g_written + 1
        StackMsg "Debayering frame" + Str$(fr) + " /" + Str$(g_frameCount)
        If _KeyHit = 27 Or _Exit Then aborted = -1: Exit For
    Next fr

    CloseOutSER
    Close #g_inNum

    ' Show the colour result




    ' Show the colour result
    Dim rimg As Long: rimg = _NewImage(g_w, g_h, 32)
    PreviewFrame outM, g_w, g_h, g_sampleBytes, g_littleEndian, rimg
    ShowImageResult rimg, g_w, g_h, "Debayered" + Str$(g_written) + " frames"
    _FreeImage rimg


    _MemFree srcM
    _MemFree outM
End Sub

Function DoSolve&
    DoSolve& = ST_SOLVE
    Color uiText
    _PrintString (20, 22), "Plate Solve  -  export FITS + run platesolver"
    _PrintString (20, 52), "Best on a stacked frame (most stars)."
    _PrintString (20, 92), "File : " + FileLabel$(setInPath)
    If Button%(410, 86, 130, 28, "Choose File") Then PickFile
    If Button%(20, 214, 180, 42, "Start / Solve") Then RunSolve
    If Button%(220, 214, 110, 42, "Back") Then DoSolve& = ST_MENU
End Function

' ============================================================================
' PLATE SOLVE  -  export the frame to FITS, run platesolver, show its output
' ============================================================================
Sub RunSolve
    If setInPath = "" Then Exit Sub
    g_inNum = FreeFile
    Open setInPath For Binary As #g_inNum
    ReadInHeader
    If g_frameCount < 1 Then Close #g_inNum: Exit Sub

    ' Export frame 1 (the stacked result if that's what you picked) to FITS
    Dim outdir As String
    outdir = FITS_DIR
    If Not _DirExists(outdir) Then outdir = ""
    Dim fitsPath As String: fitsPath = outdir + "solve.fits"
    Dim em As _MEM: em = _MemNew(g_frameBytes)
    Dim es As String: es = Space$(g_frameBytes)
    Get #g_inNum, g_dataStart, es
    _MemPut em, em.OFFSET, es
    WriteFits fitsPath, em, g_w, g_h, g_sampleBytes, g_littleEndian, g_planes
    _MemFree em
    Close #g_inNum

    ' Native-size screen: scale x1, no fractional upscale, no garble
    Dim W As Long, H As Long, M As Long
    W = _DesktopWidth: H = _DesktopHeight: M = 28 ' RPT_MARGIN (a Const in SERReport.bm, which is included later)
    Dim scr As Long: scr = _NewImage(W, H, 32)
    Screen scr
    GoFull
    _PrintMode _KeepBackground
    Rem REM _ScreenMove _Middle
    _Title "Plate Solve"
    Cls , _RGB32(20, 22, 28)
    UseRpt
    Color uiText
    _PrintString (M, M), "Solving:  " + SOLVER_EXE + " -i solve.fits"
    _PrintString (M, M + _FontHeight + 6), "Running... the window may pause while platesolver works."
    UseSmall
    _Display

    ' Build the command as a BATCH FILE (SHELL mangles nested quotes)
    Dim q As String: q = Chr$(34)
    Dim cr As String: cr = Chr$(13) + Chr$(10)
    Dim resultPath As String: resultPath = outdir + "solve_result.txt"
    Dim batPath As String: batPath = outdir + "solve.bat"
    Dim argline As String
    argline = q + SOLVER_EXE + q + " -i " + q + fitsPath + q
    If SOLVER_SCALE <> "" Then argline = argline + " -s " + q + SOLVER_SCALE + q
    argline = argline + " > " + q + resultPath + q + " 2>&1"
    Dim bat As String
    bat = "@echo off" + cr
    bat = bat + "cd /d " + q + SOLVER_DIR + q + cr
    bat = bat + argline + cr
    Dim bf As Integer
    If _FileExists(batPath) Then Kill batPath
    bf = FreeFile
    Open batPath For Binary As #bf
    Put #bf, 1, bat
    Close #bf
    Shell _Hide q + batPath + q
    GoFull ' hidden console can drop fullscreen
    _PrintMode _KeepBackground

    ' Read the whole result file
    Dim txt As String, ln As String, rf As Integer
    txt = ""
    If _FileExists(resultPath) Then
        rf = FreeFile
        Open resultPath For Input As #rf
        Do Until EOF(rf)
            Line Input #rf, ln
            txt = txt + ln + Chr$(10)
        Loop
        Close #rf
    End If

    Cls , _RGB32(20, 22, 28)
    UseRpt
    Dim lead As Long: lead = _FontHeight + 10
    Dim raDeg As Double: raDeg = JsonNum#(txt, "ra_j2000")

    If raDeg > -90000 Then
        Dim decDeg As Double, scl As Double, rot As Double, fw As Double, fh As Double
        decDeg = JsonNum#(txt, "dec_j2000")
        scl = JsonNum#(txt, "pixel_scale")
        rot = JsonNum#(txt, "rotation")
        fw = JsonNum#(txt, "field_width")
        fh = JsonNum#(txt, "field_height")
        Dim yy As Long: yy = M
        Color _RGB32(120, 230, 140)
        _PrintString (M, yy), "SOLVED": yy = yy + lead + lead \ 2
        Color uiText
        _PrintString (M, yy), "RA  (J2000) :  " + RAstr$(raDeg) + "     (" + Round2$(raDeg) + " deg)": yy = yy + lead
        _PrintString (M, yy), "Dec (J2000) :  " + DECstr$(decDeg) + "     (" + Round2$(decDeg) + " deg)": yy = yy + lead
        _PrintString (M, yy), "Pixel scale :  " + Round2$(scl) + " arcsec/pixel": yy = yy + lead
        _PrintString (M, yy), "Field size  :  " + Round2$(fw) + " x " + Round2$(fh) + " arcmin   (" + Round2$(fw / 60) + " x " + Round2$(fh / 60) + " deg)": yy = yy + lead
        _PrintString (M, yy), "Rotation    :  " + Round2$(rot) + " deg"
    Else
        Color _RGB32(240, 180, 120)
        Dim yy2 As Long: yy2 = M
        _PrintString (M, yy2), "No solution parsed. Raw output:": yy2 = yy2 + lead + lead \ 2
        Color uiText
        Dim cw As Long: cw = _PrintWidth("M"): If cw < 1 Then cw = 8
        Dim maxChars As Long: maxChars = (W - 2 * M) \ cw
        Dim p As Long, nl As Long, segg As String
        p = 1
        Do While p <= Len(txt) And yy2 < H - M - lead
            nl = InStr(p, txt, Chr$(10))
            If nl = 0 Then
                segg = Mid$(txt, p): p = Len(txt) + 1
            Else
                segg = Mid$(txt, p, nl - p): p = nl + 1
            End If
            WrapDraw segg, M, yy2, maxChars, lead, H - M
        Loop
    End If
    Color _RGB32(150, 160, 180)
    _PrintString (M, H - M - _FontHeight), "Press any key to close."
    UseSmall
    _Display
    Do: _Limit 30: Loop Until _KeyHit <> 0 Or _Exit

    Screen gHub
    GoFull
    _FreeImage scr
    _Title "SER PPIP Toolkit"
End Sub

Function DoPlayer&
    DoPlayer& = ST_PLAYER
    Color uiText
    _PrintString (20, 22), "SER Player"
    _PrintString (20, 64), "File : " + FileLabel$(setInPath)
    If Button%(410, 58, 130, 28, "Choose File") Then PickFile
    _PrintString (20, 110), "FPS  :" + Str$(setPlayFps)
    If Button%(150, 104, 40, 28, "-") Then
        setPlayFps = setPlayFps - 5
        If setPlayFps < 5 Then setPlayFps = 5
    End If
    If Button%(196, 104, 40, 28, "+") Then
        setPlayFps = setPlayFps + 5
        If setPlayFps > 120 Then setPlayFps = 120
    End If
    If Button%(20, 210, 170, 42, "Start / Play") Then RunPlayer
    If Button%(210, 210, 120, 42, "Back") Then DoPlayer& = ST_MENU
End Function

Function DoViewer&
    DoViewer& = ST_VIEWER
    Color uiText
    _PrintString (20, 22), "SER Viewer  -  step through frames"
    _PrintString (20, 64), "File : " + FileLabel$(setInPath)
    If Button%(410, 58, 130, 28, "Choose File") Then PickFile
    _PrintString (20, 108), "Arrows step - drag pans at 1:1"
    If Button%(20, 210, 170, 42, "Open / View") Then RunViewer
    If Button%(210, 210, 120, 42, "Back") Then DoViewer& = ST_MENU
End Function

Function DoCenter&
    DoCenter& = ST_CENTER
    Color uiText
    _PrintString (20, 14), "SER Center  -  writes centered.ser"
    _PrintString (20, 42), "File : " + FileLabel$(setInPath)
    If Button%(410, 36, 130, 24, "Choose File") Then PickFile

    _PrintString (20, 70), "Target : " + TargetLabel$
    If Button%(280, 64, 130, 24, "Planet/DSO/Off") Then setTarget = NextTarget&(setTarget)

    _PrintString (20, 98), "Size : " + SizeLabel$
    If Button%(280, 92, 130, 24, "Full / Crop") Then setFullSize = Not setFullSize

    _PrintString (20, 126), "Crop :" + Str$(setCrop)
    If Button%(150, 120, 36, 24, "-") Then
        setCrop = setCrop - 50
        If setCrop < 100 Then setCrop = 100
    End If
    If Button%(194, 120, 36, 24, "+") Then
        setCrop = setCrop + 50
        If setCrop > 1200 Then setCrop = 1200
    End If

    _PrintString (20, 154), "Thresh x" + Str$(setThreshMult)
    If Button%(150, 148, 36, 24, "-") Then
        setThreshMult = setThreshMult - 1
        If setThreshMult < 1 Then setThreshMult = 1
    End If
    If Button%(194, 148, 36, 24, "+") Then
        setThreshMult = setThreshMult + 1
        If setThreshMult > 10 Then setThreshMult = 10
    End If

    _PrintString (20, 182), "Preview: " + OnOff$(setPreview)
    If Button%(150, 176, 80, 24, "Toggle") Then setPreview = Not setPreview

    If Button%(20, 214, 180, 42, "Start / Center") Then RunCenter
    If Button%(220, 214, 110, 42, "Back") Then DoCenter& = ST_MENU
End Function

' ============================================================================
' RUN FLOWS  -  drive the engine helpers from the live settings
' ============================================================================

Sub RunStacker
    If setInPath = "" Then Exit Sub
    g_inNum = FreeFile
    Open setInPath For Binary As #g_inNum
    ReadInHeader

    If g_planes <> 1 And g_planes <> 3 Then
        StackMsg "Unsupported pixel layout."
        Close #g_inNum: _Delay 2: Exit Sub
    End If
    If g_frameCount < 1 Then Close #g_inNum: Exit Sub

    Dim n As Long
    n = g_frameCount

    Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
    Dim frameStr As String: frameStr = Space$(g_frameBytes)
    Dim fr As Long, aborted As Integer
    aborted = 0

    ' --- Pass 1: score every frame for sharpness ---
    ReDim scores(1 To n) As Double
    For fr = 1 To n
        Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
        _MemPut srcM, srcM.OFFSET, frameStr
        If g_planes = 3 Then
            scores(fr) = QualityRGB#(srcM, g_w, g_h, g_sampleBytes, g_littleEndian)
        Else
            scores(fr) = QualityMono#(srcM, g_w, g_h, g_sampleBytes, g_littleEndian)
        End If
        If (fr And 7) = 0 Then
            StackMsg "Scoring frame" + Str$(fr) + " /" + Str$(n)
            If _KeyHit = 27 Or _Exit Then aborted = -1: Exit For
        End If
    Next fr
    If aborted Then _MemFree srcM: Close #g_inNum: Exit Sub

    ' --- Cutoff for the best setKeepPct% ---
    Dim keep As Long, i As Long
    keep = Int(n * setKeepPct / 100)
    If keep < 1 Then keep = 1
    ReDim sorted(1 To n) As Double
    For i = 1 To n: sorted(i) = scores(i): Next i
    SortDescD sorted(), n
    Dim cutoff As Double
    cutoff = sorted(keep)

    ' --- Pass 2: average the kept frames ---
    ReDim accum(0 To g_w * g_h * g_planes - 1) As Double
    Dim used As Long
    used = 0
    For fr = 1 To n
        If scores(fr) >= cutoff Then
            Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
            _MemPut srcM, srcM.OFFSET, frameStr
            If g_planes = 3 Then
                AccumRGB srcM, g_w, g_h, g_sampleBytes, g_littleEndian, accum()
            Else
                AccumMono srcM, g_w, g_h, g_sampleBytes, g_littleEndian, accum()
            End If
            used = used + 1
            If (used And 7) = 0 Then
                StackMsg "Stacking frame" + Str$(used) + " /" + Str$(keep)
                If _KeyHit = 27 Or _Exit Then Exit For
            End If
        End If
    Next fr

    If used < 1 Then _MemFree srcM: Close #g_inNum: Exit Sub

    ' --- Finalize -> a single averaged frame, same format as the input ---
    Dim outM As _MEM: outM = _MemNew(g_frameBytes)
    If g_planes = 3 Then
        FinalizeRGB accum(), used, g_w, g_h, g_sampleBytes, g_littleEndian, outM
    Else
        FinalizeMono accum(), used, g_w, g_h, g_sampleBytes, g_littleEndian, outM
    End If

    ' --- Write a 1-frame SER via the shared output writer ---
    g_cropW = g_w: g_cropH = g_h
    Dim pad$
    $If WIN Then
        pad$ = "\"
    $Else
        pad$ = "/"
    $End If
    Dim outpath As String
    outpath = _CWD$ + pad$ + "stacked.ser"
    OpenOutSER outpath
    Dim outBuf As String: outBuf = Space$(g_frameBytes)
    _MemGet outM, outM.OFFSET, outBuf
    Put #g_outNum, , outBuf
    g_written = 1
    CloseOutSER

    Close #g_inNum

    ' --- Show the result until a key/close ---
    Dim rimg As Long
    rimg = _NewImage(g_w, g_h, 32)
    PreviewFrame outM, g_w, g_h, g_sampleBytes, g_littleEndian, rimg
    Dim rscr As Long, rdw As Long, rdh As Long
    FitSize g_w, g_h, rdw, rdh
    rscr = _NewImage(rdw, rdh, 32)
    Screen rscr
    _FullScreen
    GoFull
    Rem REM _ScreenMove _Middle
    _Title "Stacked" + Str$(used) + " of" + Str$(n) + " frames   (any key to close)"
    _PutImage (0, 0)-(rdw - 1, rdh - 1), rimg
    _Display
    Do: _Limit 30: Loop Until _KeyHit <> 0 Or _Exit
    _FreeImage rimg
    Screen gHub
    GoFull
    _FreeImage rscr
    _Title "SER PPIP Toolkit"

    _MemFree srcM
    _MemFree outM
End Sub

' --- Reference-position star search (stateless) for cross-file alignment.
'     Each frame independently re-finds the 3 stars near their REFERENCE spots
'     with a larger box, so jumps between separate files don't break tracking. ---
Sub StarShiftAbs (m As _MEM, dxAvg As Double, dyAvg As Double)
    Dim i As Long, ok As Integer, gxi As Long, gyi As Long
    Dim fx As Double, fy As Double, sumdx As Double, sumdy As Double, cnt As Long
    sumdx = 0: sumdy = 0: cnt = 0
    For i = 0 To 2
        gxi = Int(refStarX(i)): gyi = Int(refStarY(i))
        StarCentroid m, g_w, g_h, g_sampleBytes, g_littleEndian, gxi, gyi, STACK_BOX, fx, fy, ok
        If ok Then
            sumdx = sumdx + (fx - refStarX(i))
            sumdy = sumdy + (fy - refStarY(i))
            cnt = cnt + 1
        End If
    Next i
    If cnt > 0 Then
        dxAvg = sumdx / cnt: dyAvg = sumdy / cnt
    Else
        dxAvg = 0: dyAvg = 0
    End If
End Sub

' --- Reference-position surface match (larger search) for cross-file align ---
Sub SurfaceShiftAbs (m As _MEM, dxOut As Double, dyOut As Double)
    Dim fx As Long, fy As Long
    SurfaceMatch m, g_w, g_h, g_sampleBytes, g_littleEndian, gSurfPatch(), PATCH_R, refCX, refCY, STACK_SEARCH, fx, fy
    dxOut = fx - refCX
    dyOut = fy - refCY
End Sub

' --- Per-frame shift for Stack Set: reference-position align (not incremental) ---
Sub ComputeShiftAbs (srcM As _MEM, shiftX As Long, shiftY As Long)
    Dim cx As Double, cy As Double, total As Double, thr As Long
    Dim dxAvg As Double, dyAvg As Double
    If setTarget = TGT_STARS Then
        StarShiftAbs srcM, dxAvg, dyAvg
        shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
        shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
    ElseIf setTarget = TGT_SURFACE Then
        SurfaceShiftAbs srcM, dxAvg, dyAvg
        shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
        shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
    ElseIf setTarget = TGT_OFF Then
        shiftX = (g_w - g_cropW) \ 2
        shiftY = (g_h - g_cropH) \ 2
    Else
        thr = ThreshFor&(srcM, setTarget, setThreshMult)
        FrameCentroid srcM, thr, cx, cy, total
        shiftX = Int(cx - g_cropW / 2 + 0.5)
        shiftY = Int(cy - g_cropH / 2 + 0.5)
    End If
    If IsBayer%(g_colorID) Then
        shiftX = shiftX And -2
        shiftY = shiftY And -2
    End If
End Sub

' ============================================================================
' STACK SET  -  validate many SER files, align each to a reference, stack all
' ============================================================================
Sub RunStackSet
    If gStackCount < 1 Then StackMsg "No files selected.": _Delay 2: Exit Sub

    ' --- Validate: keep files whose header matches the first valid one ---
    Dim kept As Long, i As Long, fn As Integer
    Dim refW As Long, refH As Long, refCID As Long, refDepth As Long
    Dim hdr As SERHeader
    ReDim keepIdx(1 To gStackCount) As Long
    kept = 0: refW = 0
    For i = 1 To gStackCount
        fn = FreeFile
        Open gStackFiles(i) For Binary As #fn
        Get #fn, 1, hdr
        Close #fn
        If hdr.FileID = "LUCAM-RECORDER" Then
            If refW = 0 Then
                refW = hdr.ImageWidth: refH = hdr.ImageHeight
                refCID = hdr.ColorID: refDepth = hdr.PixelDepth
                kept = kept + 1: keepIdx(kept) = i
            ElseIf hdr.ImageWidth = refW And hdr.ImageHeight = refH And hdr.ColorID = refCID And hdr.PixelDepth = refDepth Then
                kept = kept + 1: keepIdx(kept) = i
            End If
        End If
    Next i
    If kept < 1 Then StackMsg "No matching SER files.": _Delay 2: Exit Sub

    ' --- Open first kept file to set g_* format state ---
    g_inNum = FreeFile
    Open gStackFiles(keepIdx(1)) For Binary As #g_inNum
    ReadInHeader
    If g_planes <> 1 And g_planes <> 3 Then
        StackMsg "Unsupported pixel layout."
        Close #g_inNum: _Delay 2: Exit Sub
    End If

    If setFullSize Then
        g_cropW = g_w: g_cropH = g_h
    Else
        g_cropW = setCrop: g_cropH = setCrop
        If g_cropW > g_w Then g_cropW = g_w
        If g_cropH > g_h Then g_cropH = g_h
    End If
    g_cropBytes = g_cropW * g_cropH * g_bpp

    ' --- Alignment reference: pick on frame 1 of the first file ---
    If setTarget = TGT_STARS Then
        If PickStars% = 0 Then Close #g_inNum: Exit Sub
    ElseIf setTarget = TGT_SURFACE Then
        If PickSurface% = 0 Then Close #g_inNum: Exit Sub
    End If
    Close #g_inNum

    ' --- Accumulate every frame of every kept file ---
    Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
    Dim dstM As _MEM: dstM = _MemNew(g_cropBytes)
    Dim frameStr As String: frameStr = Space$(g_frameBytes)
    ReDim accum(0 To g_cropW * g_cropH * g_planes - 1) As Double
    Dim used As Long, fr As Long, sxv As Long, syv As Long, aborted As Integer
    used = 0: aborted = 0

    For i = 1 To kept
        g_inNum = FreeFile
        Open gStackFiles(keepIdx(i)) For Binary As #g_inNum
        ReadInHeader
        For fr = 1 To g_frameCount
            Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
            _MemPut srcM, srcM.OFFSET, frameStr
            ComputeShiftAbs srcM, sxv, syv
            ShiftCropFrame srcM, g_w, g_h, g_bpp, sxv, syv, dstM, g_cropW, g_cropH
            If g_planes = 3 Then
                AccumRGB dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, accum()
            Else
                AccumMono dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, accum()
            End If
            used = used + 1
            If (used And 7) = 0 Then
                StackMsg "File" + Str$(i) + " /" + Str$(kept) + "   stacked" + Str$(used) + " frames"
                If _KeyHit = 27 Or _Exit Then aborted = -1: Exit For
            End If
        Next fr
        Close #g_inNum
        If aborted Then Exit For
    Next i

    If used < 1 Then _MemFree srcM: _MemFree dstM: Exit Sub

    ' --- Finalize -> one averaged frame ---
    Dim outM As _MEM: outM = _MemNew(g_cropBytes)
    If g_planes = 3 Then
        FinalizeRGB accum(), used, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, outM
    Else
        FinalizeMono accum(), used, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, outM
    End If

    ' --- Write stacked.ser ---
    Dim pad$
    $If WIN Then
        pad$ = "\"
    $Else
        pad$ = "/"
    $End If
    Dim outpath As String
    outpath = _CWD$ + pad$ + "stacked.ser"
    OpenOutSER outpath
    Dim outBuf As String: outBuf = Space$(g_cropBytes)
    _MemGet outM, outM.OFFSET, outBuf
    Put #g_outNum, , outBuf
    g_written = 1
    CloseOutSER

    ' --- Show the result ---
    Dim rimg As Long: rimg = _NewImage(g_cropW, g_cropH, 32)
    PreviewFrame outM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, rimg
    Dim rscr As Long, rdw As Long, rdh As Long
    FitSize g_cropW, g_cropH, rdw, rdh
    rscr = _NewImage(rdw, rdh, 32)
    Screen rscr
    _FullScreen
    GoFull
    Rem REM _ScreenMove _Middle
    _Title "Stacked" + Str$(used) + " frames from" + Str$(kept) + " files   (any key)"
    _PutImage (0, 0)-(rdw - 1, rdh - 1), rimg
    _Display
    Do: _Limit 30: Loop Until _KeyHit <> 0 Or _Exit
    _FreeImage rimg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage rscr
    _Title "SER PPIP Toolkit"

    _MemFree srcM
    _MemFree dstM
    _MemFree outM
End Sub

' Compute the crop shift for the current frame per the active Target mode.
' Shared by the one-pass Process flow (mirrors the Center loop's shift logic).
Sub ComputeShift (srcM As _MEM, shiftX As Long, shiftY As Long)
    Dim cx As Double, cy As Double, total As Double, thr As Long
    Dim dxAvg As Double, dyAvg As Double
    If setTarget = TGT_STARS Then
        StarShift srcM, dxAvg, dyAvg
        shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
        shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
    ElseIf setTarget = TGT_SURFACE Then
        SurfaceShift srcM, dxAvg, dyAvg
        shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
        shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
    ElseIf setTarget = TGT_OFF Then
        shiftX = (g_w - g_cropW) \ 2
        shiftY = (g_h - g_cropH) \ 2
    Else
        thr = ThreshFor&(srcM, setTarget, setThreshMult)
        FrameCentroid srcM, thr, cx, cy, total
        shiftX = Int(cx - g_cropW / 2 + 0.5)
        shiftY = Int(cy - g_cropH / 2 + 0.5)
    End If
    If IsBayer%(g_colorID) Then
        shiftX = shiftX And -2
        shiftY = shiftY And -2
    End If
End Sub

' ============================================================================
' PROCESS  -  center + quality-rank + stack in one pass -> stacked.ser
' ============================================================================
Sub RunProcess
    If setInPath = "" Then Exit Sub
    g_inNum = FreeFile
    Open setInPath For Binary As #g_inNum
    ReadInHeader

    If g_planes <> 1 And g_planes <> 3 Then
        StackMsg "Unsupported pixel layout."
        Close #g_inNum: _Delay 2: Exit Sub
    End If
    If g_frameCount < 1 Then Close #g_inNum: Exit Sub

    ' Crop box (same rule as Center)
    If setFullSize Then
        g_cropW = g_w: g_cropH = g_h
    Else
        g_cropW = setCrop: g_cropH = setCrop
        If g_cropW > g_w Then g_cropW = g_w
        If g_cropH > g_h Then g_cropH = g_h
    End If
    g_cropBytes = g_cropW * g_cropH * g_bpp

    ' Star / surface modes need the interactive pick first
    If setTarget = TGT_STARS Then
        If PickStars% = 0 Then Close #g_inNum: Exit Sub
    ElseIf setTarget = TGT_SURFACE Then
        If PickSurface% = 0 Then Close #g_inNum: Exit Sub
    End If

    Dim n As Long: n = g_frameCount
    Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
    Dim dstM As _MEM: dstM = _MemNew(g_cropBytes)
    Dim frameStr As String: frameStr = Space$(g_frameBytes)
    Dim fr As Long, aborted As Integer
    aborted = 0

    ReDim shX(1 To n) As Long
    ReDim shY(1 To n) As Long
    ReDim scores(1 To n) As Double

    ' --- Pass 1: center each frame, score the CENTERED result ---
    Dim sxv As Long, syv As Long
    For fr = 1 To n
        Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
        _MemPut srcM, srcM.OFFSET, frameStr
        ComputeShift srcM, sxv, syv
        shX(fr) = sxv: shY(fr) = syv
        ShiftCropFrame srcM, g_w, g_h, g_bpp, sxv, syv, dstM, g_cropW, g_cropH
        If g_planes = 3 Then
            scores(fr) = QualityRGB#(dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian)
        Else
            scores(fr) = QualityMono#(dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian)
        End If
        If (fr And 7) = 0 Then
            StackMsg "Aligning + scoring" + Str$(fr) + " /" + Str$(n)
            If _KeyHit = 27 Or _Exit Then aborted = -1: Exit For
        End If
    Next fr
    If aborted Then _MemFree srcM: _MemFree dstM: Close #g_inNum: Exit Sub

    ' --- Cutoff for the best setKeepPct% ---
    Dim keep As Long, i As Long
    keep = Int(n * setKeepPct / 100)
    If keep < 1 Then keep = 1
    ReDim sorted(1 To n) As Double
    For i = 1 To n: sorted(i) = scores(i): Next i
    SortDescD sorted(), n
    Dim cutoff As Double
    cutoff = sorted(keep)

    ' --- Pass 2: re-center kept frames (stored shift) and accumulate ---
    ReDim accum(0 To g_cropW * g_cropH * g_planes - 1) As Double
    Dim used As Long
    used = 0
    For fr = 1 To n
        If scores(fr) >= cutoff Then
            Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
            _MemPut srcM, srcM.OFFSET, frameStr
            ShiftCropFrame srcM, g_w, g_h, g_bpp, shX(fr), shY(fr), dstM, g_cropW, g_cropH
            If g_planes = 3 Then
                AccumRGB dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, accum()
            Else
                AccumMono dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, accum()
            End If
            used = used + 1
            If (used And 7) = 0 Then
                StackMsg "Stacking" + Str$(used) + " /" + Str$(keep)
                If _KeyHit = 27 Or _Exit Then Exit For
            End If
        End If
    Next fr

    If used < 1 Then _MemFree srcM: _MemFree dstM: Close #g_inNum: Exit Sub

    ' --- Finalize -> one averaged crop-sized frame ---
    Dim outM As _MEM: outM = _MemNew(g_cropBytes)
    If g_planes = 3 Then
        FinalizeRGB accum(), used, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, outM
    Else
        FinalizeMono accum(), used, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, outM
    End If

    ' --- Write stacked.ser (crop dims already in g_cropW/H) ---
    Dim pad$
    $If WIN Then
        pad$ = "\"
    $Else
        pad$ = "/"
    $End If
    Dim outpath As String
    outpath = _CWD$ + pad$ + "stacked.ser"
    OpenOutSER outpath
    Dim outBuf As String: outBuf = Space$(g_cropBytes)
    _MemGet outM, outM.OFFSET, outBuf
    Put #g_outNum, , outBuf
    g_written = 1
    CloseOutSER
    Close #g_inNum

    ' --- Show the result ---
    Dim rimg As Long
    rimg = _NewImage(g_cropW, g_cropH, 32)
    PreviewFrame outM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, rimg
    Dim rscr As Long, rdw As Long, rdh As Long
    FitSize g_cropW, g_cropH, rdw, rdh
    rscr = _NewImage(rdw, rdh, 32)
    Screen rscr
    _FullScreen
    GoFull
    Rem REM _ScreenMove _Middle
    _Title "Processed" + Str$(used) + " of" + Str$(n) + " frames   (any key to close)"
    _PutImage (0, 0)-(rdw - 1, rdh - 1), rimg
    _Display
    Do: _Limit 30: Loop Until _KeyHit <> 0 Or _Exit
    _FreeImage rimg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage rscr
    _Title "SER PPIP Toolkit"

    _MemFree srcM
    _MemFree dstM
    _MemFree outM
End Sub

Sub RunPlayer
    If setInPath = "" Then Exit Sub
    g_fnum = FreeFile
    Open setInPath For Binary As #g_fnum
    ReadHeader
    If g_frameCount < 1 Then Close #g_fnum: Exit Sub

    Dim pscr As Long, fimg As Long, dw As Long, dh As Long
    FitSize g_w, g_h, dw, dh
    pscr = _NewImage(dw, dh, 32)
    Screen pscr
    _FullScreen
    GoFull
    _Title "Playing  -  " + FormatName$(g_colorID, g_depth) + "   (ESC to stop)"
    Rem REM _ScreenMove _Middle
    fimg = _NewImage(g_w, g_h, 32)

    Dim shownFrame As Long, targetFrame As Long, quitFlag As Integer
    Dim playT As Single, startT As Double, s As String
    shownFrame = 0: quitFlag = 0
    startT = Timer(0.001)
    Do
        playT = Timer(0.001) - startT
        If playT < 0 Then playT = 0
        targetFrame = Int(playT * setPlayFps) + 1
        If targetFrame > g_frameCount Then targetFrame = g_frameCount
        If targetFrame < 1 Then targetFrame = 1
        If targetFrame <> shownFrame Then
            shownFrame = targetFrame
            s = Space$(g_frameBytes)
            Get #g_fnum, g_dataStart + (shownFrame - 1) * g_frameBytes, s
            FrameToImage s, fimg
            _PutImage (0, 0)-(dw - 1, dh - 1), fimg
            _Display
        End If
        If _KeyHit = 27 Then quitFlag = -1
        If _Exit Then quitFlag = -1
        _Limit 240
        If shownFrame >= g_frameCount Then quitFlag = -1
    Loop Until quitFlag

    Close #g_fnum
    _FreeImage fimg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage pscr
    _Title "SER PPIP Toolkit"
End Sub

' Write the given frame of the open viewer file as a mono FITS for plate solving.
Sub ExportViewFits (frameNo As Long)
    Dim outdir As String
    outdir = FITS_DIR
    If Not _DirExists(outdir) Then outdir = "" ' fall back to current folder
    Dim em As _MEM: em = _MemNew(g_frameBytes)
    Dim es As String: es = Space$(g_frameBytes)
    Get #g_fnum, g_dataStart + (frameNo - 1) * g_frameBytes, es
    _MemPut em, em.OFFSET, es
    WriteFits outdir + "solve.fits", em, g_w, g_h, g_sampleBytes, g_littleEndian, g_planes
    _MemFree em
End Sub

' ============================================================================
' VIEWER  -  hold one frame still, step through, zoom Fit <-> 1:1 (drag to pan)
' ============================================================================
Sub RunViewer
    If setInPath = "" Then Exit Sub
    g_fnum = FreeFile
    Open setInPath For Binary As #g_fnum
    ReadHeader
    If g_frameCount < 1 Then Close #g_fnum: Exit Sub

    ' Fitted image size; window is at least 480 wide so the button bar fits
    Dim dw As Long, dh As Long, winW As Long, imgX0 As Long
    FitSize g_w, g_h, dw, dh
    winW = dw: If winW < 560 Then winW = 560
    imgX0 = (winW - dw) \ 2

    Dim scr As Long: scr = _NewImage(winW, dh, 32)
    Screen scr
    _FullScreen
    GoFull
    _Title "SER Viewer  -  " + FormatName$(g_colorID, g_depth) + "   (arrows step, ESC closes)"
    Rem _ScreenMove _Middle

    Dim fimg As Long: fimg = _NewImage(g_w, g_h, 32)
    Dim cur As Long, loaded As Long, s As String
    cur = 1: loaded = 0

    Dim zoom11 As Integer, panX As Long, panY As Long
    Dim dragging As Integer, lastMX As Long, lastMY As Long
    Dim stretch As Integer
    Dim savedFrames As Long
    zoom11 = 0: panX = 0: panY = 0: dragging = 0: stretch = 0: savedFrames = 0

    Dim quitFlag As Integer, k As Long, barY As Long
    quitFlag = 0: barY = dh - 38

    Do
        _Limit 60
        PollMouse

        If loaded <> cur Then
            s = Space$(g_frameBytes)
            Get #g_fnum, g_dataStart + (cur - 1) * g_frameBytes, s
            FrameToImage s, fimg
            If stretch Then StretchImage fimg ' display-only faint-detail boost
            loaded = cur: panX = 0: panY = 0
        End If

        ' keyboard navigation
        k = _KeyHit
        Select Case k
            Case 19200: cur = cur - 1 ' left
            Case 19712, 32: cur = cur + 1 ' right / space
            Case 18176: cur = 1 ' Home
            Case 20224: cur = g_frameCount ' End
            Case 83, 115: stretch = Not stretch: loaded = 0 ' S = toggle stretch
            Case 70, 102: ExportViewFits cur: savedFrames = 120 ' F = save FITS
            Case 27: quitFlag = -1 ' ESC
        End Select
        If cur < 1 Then cur = 1
        If cur > g_frameCount Then cur = g_frameCount

        ' drag-to-pan (1:1 only, in the image area)
        If zoom11 And gMouse.down And gMouse.y < barY Then
            If dragging Then
                panX = panX - (gMouse.x - lastMX)
                panY = panY - (gMouse.y - lastMY)
            End If
            dragging = -1: lastMX = gMouse.x: lastMY = gMouse.y
        Else
            dragging = 0
        End If
        If panX > g_w - dw Then panX = g_w - dw
        If panX < 0 Then panX = 0
        If panY > g_h - dh Then panY = g_h - dh
        If panY < 0 Then panY = 0

        ' draw frame
        Cls , _RGB32(16, 16, 20)
        If zoom11 Then
            _PutImage (imgX0, 0)-(imgX0 + dw - 1, dh - 1), fimg, , (panX, panY)-(panX + dw - 1, panY + dh - 1)
        Else
            _PutImage (imgX0, 0)-(imgX0 + dw - 1, dh - 1), fimg
        End If

        ' status strip
        Line (0, 0)-(winW, 20), _RGB32(0, 0, 0), BF
        Color _RGB32(230, 235, 245)
        _PrintString (6, 2), "Frame" + Str$(cur) + " /" + Str$(g_frameCount) + "    " + FormatName$(g_colorID, g_depth) + "    " + _Trim$(Str$(g_w)) + "x" + _Trim$(Str$(g_h)) + "    " + ZoomLabel$(zoom11)

        ' button bar
        Line (0, barY - 2)-(winW, dh), _RGB32(24, 26, 32), BF
        If Button%(6, barY, 46, 32, "|<") Then cur = 1
        If Button%(56, barY, 46, 32, "<") Then cur = cur - 1
        If Button%(106, barY, 46, 32, ">") Then cur = cur + 1
        If Button%(156, barY, 46, 32, ">|") Then cur = g_frameCount
        If Button%(212, barY, 66, 32, ZoomBtn$(zoom11)) Then
            zoom11 = Not zoom11: panX = 0: panY = 0
        End If
        If Button%(288, barY, 90, 32, "Str " + OnOff$(stretch)) Then
            stretch = Not stretch: loaded = 0
        End If
        If Button%(388, barY, 84, 32, "-> FITS") Then
            ExportViewFits cur: savedFrames = 120
        End If
        If Button%(winW - 66, barY, 60, 32, "Close") Then quitFlag = -1
        If savedFrames > 0 Then
            Color _RGB32(120, 230, 140)
            _PrintString (6, 24), "Saved solve.fits to the plate-solve folder"
            savedFrames = savedFrames - 1
        End If
        If cur < 1 Then cur = 1
        If cur > g_frameCount Then cur = g_frameCount

        _Display
        If _Exit Then quitFlag = -1
    Loop Until quitFlag

    Close #g_fnum
    _FreeImage fimg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage scr
    _Title "SER PPIP Toolkit"
End Sub

Sub RunCenter
    If setInPath = "" Then Exit Sub
    g_inNum = FreeFile
    Open setInPath For Binary As #g_inNum
    ReadInHeader

    If g_planes <> 1 And g_planes <> 3 Then
        StackMsg "Unsupported pixel layout."
        Close #g_inNum: _Delay 2: Exit Sub
    End If

    If setFullSize Then
        ' Recenter within the original dimensions -- no downsize, edges black-filled
        g_cropW = g_w: g_cropH = g_h
    Else
        g_cropW = setCrop: g_cropH = setCrop
        If g_cropW > g_w Then g_cropW = g_w
        If g_cropH > g_h Then g_cropH = g_h
    End If
    g_cropBytes = g_cropW * g_cropH * g_bpp

    Dim snapEven As Integer
    snapEven = 0
    If IsBayer%(g_colorID) Then snapEven = -1

    ' Star / surface modes need an interactive pick on a reference frame first
    If setTarget = TGT_STARS Then
        If PickStars% = 0 Then Close #g_inNum: Exit Sub
    ElseIf setTarget = TGT_SURFACE Then
        If PickSurface% = 0 Then Close #g_inNum: Exit Sub
    End If

    Dim pad$
    $If WIN Then
        pad$ = "\"
    $Else
        pad$ = "/"
    $End If
    Dim outpath As String
    outpath = _CWD$ + pad$ + "centered.ser"
    OpenOutSER outpath

    Dim pscr As Long, prevImg As Long, cdw As Long, cdh As Long
    If setPreview Then
        FitSize g_cropW, g_cropH, cdw, cdh
        pscr = _NewImage(cdw, cdh, 32)
        Screen pscr
        _FullScreen
        GoFull
        Rem _ScreenMove _Middle
        _Title "Centering ...   (ESC to stop)"
        prevImg = _NewImage(g_cropW, g_cropH, 32)
    End If

    Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
    Dim dstM As _MEM: dstM = _MemNew(g_cropBytes)
    Dim frameStr As String: frameStr = Space$(g_frameBytes)
    Dim outBuf As String: outBuf = Space$(g_cropBytes)
    Dim fr As Long, thr As Long, cx As Double, cy As Double, total As Double
    Dim shiftX As Long, shiftY As Long, aborted As Integer
    Dim dxAvg As Double, dyAvg As Double
    aborted = 0

    For fr = 1 To g_frameCount
        Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
        _MemPut srcM, srcM.OFFSET, frameStr
        If setTarget = TGT_STARS Then
            StarShift srcM, dxAvg, dyAvg
            shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
            shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
        ElseIf setTarget = TGT_SURFACE Then
            SurfaceShift srcM, dxAvg, dyAvg
            shiftX = Int(dxAvg + 0.5) + (g_w - g_cropW) \ 2
            shiftY = Int(dyAvg + 0.5) + (g_h - g_cropH) \ 2
        ElseIf setTarget = TGT_OFF Then
            ' No tracking: pass through (full) or crop a fixed centre box
            shiftX = (g_w - g_cropW) \ 2
            shiftY = (g_h - g_cropH) \ 2
        Else
            thr = ThreshFor&(srcM, setTarget, setThreshMult)
            FrameCentroid srcM, thr, cx, cy, total
            shiftX = Int(cx - g_cropW / 2 + 0.5)
            shiftY = Int(cy - g_cropH / 2 + 0.5)
        End If
        If snapEven Then
            shiftX = shiftX And -2
            shiftY = shiftY And -2
        End If
        ShiftCropFrame srcM, g_w, g_h, g_bpp, shiftX, shiftY, dstM, g_cropW, g_cropH
        _MemGet dstM, dstM.OFFSET, outBuf
        Put #g_outNum, , outBuf
        g_written = g_written + 1
        If setPreview Then
            PreviewFrame dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, prevImg
            _PutImage (0, 0)-(cdw - 1, cdh - 1), prevImg
            _Display
            If _KeyHit = 27 Then aborted = -1
            If _Exit Then aborted = -1
            _Limit 120
        End If
        If aborted Then Exit For
    Next fr

    CloseOutSER
    Close #g_inNum
    _MemFree srcM
    _MemFree dstM
    If setPreview Then
        _FreeImage prevImg
        Screen gHub
        _FullScreen
        GoFull
        _FreeImage pscr
        _Title "SER PPIP Toolkit"
    End If
End Sub

' ============================================================================
' SMALL HELPERS  -  labels, the file picker, and a hub status line
' ============================================================================

' Put the current screen into aspect-preserving fullscreen. Re-asserted after
' every Screen change (a new Screen starts windowed). QB64 auto-maps the mouse
' back to software-screen coords, so buttons/picks keep working.
Sub GoFull
    _FullScreen _SquarePixels
End Sub

' Compute a display size that fits the desktop (preserving aspect ratio, never
' upscaling). Full-res frames are scaled into this window with _PutImage.
Sub FitSize (srcW As Long, srcH As Long, dispW As Long, dispH As Long)
    Dim maxW As Long, maxH As Long, sc As Double
    maxW = Int(_DesktopWidth * 0.92)
    maxH = Int(_DesktopHeight * 0.88) ' headroom for title bar / taskbar
    sc = 1#
    If maxW / srcW < sc Then sc = maxW / srcW
    If maxH / srcH < sc Then sc = maxH / srcH
    dispW = Int(srcW * sc): If dispW < 1 Then dispW = 1
    dispH = Int(srcH * sc): If dispH < 1 Then dispH = 1
End Sub

Sub PickFile
    Dim f As String
    f = _OpenFileDialog$("Open SER file", "", "*.ser", "SER files")
    If f <> "" Then setInPath = f
End Sub

' A one-line status message on the hub screen (used during long runs).
Sub StackMsg (msg As String)
    Line (16, 300)-(544, 324), _RGB32(24, 26, 32), BF
    Color uiText
    _PrintString (20, 304), msg
    _Display
End Sub

Function NextKeep& (k As Long)
    Select Case k
        Case 25: NextKeep& = 50
        Case 50: NextKeep& = 75
        Case 75: NextKeep& = 100
        Case Else: NextKeep& = 25
    End Select
End Function

Function OnOff$ (v As Long)
    If v Then OnOff$ = "On" Else OnOff$ = "Off"
End Function

' Pull a numeric value for "key" out of the solver's JSON. Returns -99999 if absent.
Function JsonNum# (js As String, kkey As String)
    Dim p As Long, e As Long, ch As String
    p = InStr(js, Chr$(34) + kkey + Chr$(34))
    If p = 0 Then JsonNum# = -99999: Exit Function
    p = InStr(p, js, ":")
    If p = 0 Then JsonNum# = -99999: Exit Function
    p = p + 1
    Do While p <= Len(js)
        ch = Mid$(js, p, 1)
        If ch <> " " And ch <> Chr$(9) Then Exit Do
        p = p + 1
    Loop
    e = p
    Do While e <= Len(js)
        ch = Mid$(js, e, 1)
        If ch = "," Or ch = "}" Or ch = Chr$(13) Or ch = Chr$(10) Then Exit Do
        e = e + 1
    Loop
    JsonNum# = Val(_Trim$(Mid$(js, p, e - p)))
End Function

Function Round2$ (v As Double)
    Dim r As Double
    r = Sgn(v) * Int(Abs(v) * 100 + 0.5) / 100
    Round2$ = _Trim$(Str$(r))
End Function

Function Pad2$ (n As Long)
    Pad2$ = Right$("0" + _Trim$(Str$(n)), 2)
End Function

' RA degrees -> "HHh MMm SSs"
Function RAstr$ (deg As Double)
    Dim hrs As Double, hh As Long, mm As Long, ss As Long
    hrs = deg / 15
    If hrs < 0 Then hrs = hrs + 24
    hh = Int(hrs)
    mm = Int((hrs - hh) * 60)
    ss = Int(((hrs - hh) * 60 - mm) * 60 + 0.5)
    If ss >= 60 Then ss = 0: mm = mm + 1
    If mm >= 60 Then mm = 0: hh = hh + 1
    RAstr$ = Pad2$(hh) + "h " + Pad2$(mm) + "m " + Pad2$(ss) + "s"
End Function

' Dec degrees -> "+DDd MMm SSs"
Function DECstr$ (deg As Double)
    Dim ssgn As String, ad As Double, dd As Long, mm As Long, ss As Long
    If deg < 0 Then ssgn = "-" Else ssgn = "+"
    ad = Abs(deg)
    dd = Int(ad)
    mm = Int((ad - dd) * 60)
    ss = Int(((ad - dd) * 60 - mm) * 60 + 0.5)
    If ss >= 60 Then ss = 0: mm = mm + 1
    If mm >= 60 Then mm = 0: dd = dd + 1
    DECstr$ = ssgn + Pad2$(dd) + "d " + Pad2$(mm) + "m " + Pad2$(ss) + "s"
End Function

Function ZoomLabel$ (z As Integer)
    If z Then ZoomLabel$ = "1:1 (drag to pan)" Else ZoomLabel$ = "Fit"
End Function

Function ZoomBtn$ (z As Integer)
    If z Then ZoomBtn$ = "Fit" Else ZoomBtn$ = "1:1"
End Function

Function SizeLabel$
    If setFullSize Then
        SizeLabel$ = "Full frame"
    Else
        SizeLabel$ = "Crop " + _Trim$(Str$(setCrop))
    End If
End Function

Function TargetLabel$
    Select Case setTarget
        Case TGT_PLANET: TargetLabel$ = "Planet (centroid)"
        Case TGT_DSO: TargetLabel$ = "DSO core (tight)"
        Case TGT_STARS: TargetLabel$ = "DSO stars (3-pt)"
        Case TGT_SURFACE: TargetLabel$ = "Surface (crater)"
        Case Else: TargetLabel$ = "Off (no tracking)"
    End Select
End Function

Function NextTarget& (t As Long)
    Select Case t
        Case TGT_PLANET: NextTarget& = TGT_DSO
        Case TGT_DSO: NextTarget& = TGT_STARS
        Case TGT_STARS: NextTarget& = TGT_SURFACE
        Case TGT_SURFACE: NextTarget& = TGT_OFF
        Case Else: NextTarget& = TGT_PLANET
    End Select
End Function

Function FileLabel$ (p As String)
    Dim i As Long, sep As Long, ch As String
    If p = "" Then
        FileLabel$ = "(none)"
        Exit Function
    End If
    sep = 0
    For i = 1 To Len(p)
        ch = Mid$(p, i, 1)
        If ch = "\" Or ch = "/" Then sep = i
    Next i
    FileLabel$ = Mid$(p, sep + 1)
End Function

' ============================================================================
' STAR ALIGNMENT  -  pick 3 stars on a reference frame, then track them
' ============================================================================

' Pick 3 stars on frame 1. Returns -1 when three are chosen, 0 if cancelled.
Function PickStars%
    Dim refStr As String: refStr = Space$(g_frameBytes)
    Get #g_inNum, g_dataStart, refStr
    Dim refM As _MEM: refM = _MemNew(g_frameBytes)
    _MemPut refM, refM.OFFSET, refStr

    Dim refImg As Long: refImg = _NewImage(g_w, g_h, 32)
    PreviewFrame refM, g_w, g_h, g_sampleBytes, g_littleEndian, refImg
    StretchImage refImg ' display-only boost so faint stars are clickable

    Dim dw As Long, dh As Long, sx As Double, sy As Double
    FitSize g_w, g_h, dw, dh
    sx = g_w / dw: sy = g_h / dh ' image pixels per screen pixel

    Dim pscr As Long: pscr = _NewImage(dw, dh, 32)
    Screen pscr
    _FullScreen
    GoFull
    _Title "Pick 3 stars  -  click each  (ESC cancels)"
    Rem _ScreenMove _Middle

    Dim picked As Long, i As Long, ok As Integer
    Dim fx As Double, fy As Double, cancelled As Integer
    Dim imx As Long, imy As Long
    picked = 0: cancelled = 0
    Do
        PollMouse
        _PutImage (0, 0)-(dw - 1, dh - 1), refImg
        For i = 0 To picked - 1
            DrawStarMark refStarX(i) / sx, refStarY(i) / sy, i + 1
        Next i
        Color _RGB32(255, 255, 0)
        _PrintString (8, 8), "Click star" + Str$(picked + 1) + " of 3   (ESC cancels)"
        _Display
        If gMouse.clicked Then
            imx = Int(gMouse.x * sx): imy = Int(gMouse.y * sy)
            StarCentroid refM, g_w, g_h, g_sampleBytes, g_littleEndian, imx, imy, STAR_BOX, fx, fy, ok
            refStarX(picked) = fx: refStarY(picked) = fy
            trackX(picked) = fx: trackY(picked) = fy
            picked = picked + 1
        End If
        If _KeyHit = 27 Then cancelled = -1
        If _Exit Then cancelled = -1
        _Limit 60
    Loop Until picked >= 3 Or cancelled

    _MemFree refM
    _FreeImage refImg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage pscr
    _Title "SER PPIP Toolkit"
    If cancelled Then PickStars% = 0 Else PickStars% = -1
End Function

' Re-find the 3 stars in this frame; return the average displacement from the
' reference positions. Tracks incrementally (search around the last position),
' and quietly drops any star that couldn't be located this frame.
Sub StarShift (m As _MEM, dxAvg As Double, dyAvg As Double)
    Dim i As Long, ok As Integer, gxi As Long, gyi As Long
    Dim fx As Double, fy As Double
    Dim sumdx As Double, sumdy As Double, cnt As Long
    sumdx = 0: sumdy = 0: cnt = 0
    For i = 0 To 2
        gxi = Int(trackX(i)): gyi = Int(trackY(i))
        StarCentroid m, g_w, g_h, g_sampleBytes, g_littleEndian, gxi, gyi, STAR_BOX, fx, fy, ok
        If ok Then
            trackX(i) = fx: trackY(i) = fy
            sumdx = sumdx + (fx - refStarX(i))
            sumdy = sumdy + (fy - refStarY(i))
            cnt = cnt + 1
        End If
    Next i
    If cnt > 0 Then
        dxAvg = sumdx / cnt
        dyAvg = sumdy / cnt
    Else
        dxAvg = 0: dyAvg = 0
    End If
End Sub

Sub DrawStarMark (x As Double, y As Double, num As Integer)
    Circle (x, y), 8, _RGB32(255, 255, 0)
    Color _RGB32(255, 255, 0)
    _PrintString (x + 10, y - 8), _Trim$(Str$(num))
End Sub

' Gamma-0.5 boost of the 8-bit preview (display only -- centroids use raw data).
Sub StretchImage (img As Long)
    Dim d As _MEM, i As Long, total As Long, v As Long
    total = _Width(img) * _Height(img) * 4
    d = _MemImage(img)
    For i = 0 To total - 1 Step 4
        v = _MemGet(d, d.OFFSET + i + 0, _Unsigned _Byte)
        _MemPut d, d.OFFSET + i + 0, Int(Sqr(v / 255.0) * 255) As _Unsigned _Byte
        v = _MemGet(d, d.OFFSET + i + 1, _Unsigned _Byte)
        _MemPut d, d.OFFSET + i + 1, Int(Sqr(v / 255.0) * 255) As _Unsigned _Byte
        v = _MemGet(d, d.OFFSET + i + 2, _Unsigned _Byte)
        _MemPut d, d.OFFSET + i + 2, Int(Sqr(v / 255.0) * 255) As _Unsigned _Byte
    Next i
    _MemFree d
End Sub

' ============================================================================
' SURFACE ALIGNMENT  -  pick one crater/feature, then block-match it per frame
' ============================================================================

' Pick one surface feature on frame 1 and grab its reference patch.
' Returns -1 when picked, 0 if cancelled.
Function PickSurface%
    Dim refStr As String: refStr = Space$(g_frameBytes)
    Get #g_inNum, g_dataStart, refStr
    Dim refM As _MEM: refM = _MemNew(g_frameBytes)
    _MemPut refM, refM.OFFSET, refStr

    Dim refImg As Long: refImg = _NewImage(g_w, g_h, 32)
    PreviewFrame refM, g_w, g_h, g_sampleBytes, g_littleEndian, refImg
    StretchImage refImg

    Dim dw As Long, dh As Long, sx As Double, sy As Double
    FitSize g_w, g_h, dw, dh
    sx = g_w / dw: sy = g_h / dh

    Dim pscr As Long: pscr = _NewImage(dw, dh, 32)
    Screen pscr
    _FullScreen
    GoFull
    _Title "Pick a surface feature (crater)  -  click it  (ESC cancels)"
    Rem _ScreenMove _Middle

    Dim hr As Long, cancelled As Integer, done As Integer
    Dim imx As Long, imy As Long
    hr = Int(PATCH_R / sx): If hr < 3 Then hr = 3
    cancelled = 0: done = 0
    Do
        PollMouse
        _PutImage (0, 0)-(dw - 1, dh - 1), refImg
        Line (gMouse.x - hr, gMouse.y - hr)-(gMouse.x + hr, gMouse.y + hr), _RGB32(255, 255, 0), B
        Color _RGB32(255, 255, 0)
        _PrintString (8, 8), "Click a crater / feature   (ESC cancels)"
        _Display
        If gMouse.clicked Then
            imx = Int(gMouse.x * sx): imy = Int(gMouse.y * sy)
            refCX = imx: refCY = imy
            ExtractPatch refM, g_w, g_h, g_sampleBytes, g_littleEndian, imx, imy, PATCH_R, gSurfPatch()
            trackCX = imx: trackCY = imy
            done = -1
        End If
        If _KeyHit = 27 Then cancelled = -1
        If _Exit Then cancelled = -1
        _Limit 60
    Loop Until done Or cancelled

    _MemFree refM
    _FreeImage refImg
    Screen gHub
    _FullScreen
    GoFull
    _FreeImage pscr
    _Title "SER PPIP Toolkit"
    If cancelled Then PickSurface% = 0 Else PickSurface% = -1
End Function

' Block-match the reference patch in this frame; return its displacement from
' the reference position. Tracks incrementally (search around last position).
Sub SurfaceShift (m As _MEM, dxOut As Double, dyOut As Double)
    Dim fx As Long, fy As Long, gx As Long, gy As Long
    gx = Int(trackCX): gy = Int(trackCY)
    SurfaceMatch m, g_w, g_h, g_sampleBytes, g_littleEndian, gSurfPatch(), PATCH_R, gx, gy, SURF_SEARCH, fx, fy
    trackCX = fx: trackCY = fy
    dxOut = fx - refCX
    dyOut = fy - refCY
End Sub
'$Include:'SERReport.bm'
'$Include:'ButtonUI.bm'
'$Include:'SERPlayLib.bm'
'$Include:'SERCenterCore.bm'
'$Include:'SERFmtMono.bm'
'$Include:'SERFmtRGB.bm'
'$Include:'SERStars.bm'
'$Include:'SERSurface.bm'
'$Include:'SERDebayer.bm'
'$Include:'SERFits.bm'
'$Include:'SERStackLib.bm'
