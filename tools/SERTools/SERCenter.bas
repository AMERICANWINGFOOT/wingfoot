' ============================================================================
' SERCenter.bas  -  PIPP-style planet centering for SER captures
'
' Reads a SharpCap .ser, and for every frame: finds the planet's brightness
' centroid, shifts it to the middle of a crop box, and writes a new, smaller
' .ser ready for AutoStakkert. The input is never touched. A live preview
' shows the planet snapping to centre as it processes. ESC aborts (the partial
' output stays valid).
'
' What this build handles: mono/raw (MONO8/16, RAW8/16) and colour (RGB/BGR,
' 24/48-bit). The format-specific brightness work lives in SERFmtMono.bm and
' SERFmtRGB.bm; everything else (shift, crop, write) is byte-agnostic.
'
' Files in the set:
'   SERCommon.bi     - shared SER header structure + colour constants
'   SERCenterCore.bm - the format-agnostic engine (shift / crop / write)
'   SERFmtMono.bm    - the only format-specific part: mono/raw centroid + mean
' ============================================================================

'$INCLUDE:'SERCommon.bi'

' --- Tunables ---
Const CROP_W = 400          ' output width  (clamped to input if larger)
Const CROP_H = 400          ' output height
Const THRESH_LEVEL = 0      ' 0 = auto (mean * THRESH_MULT); or a fixed value
Const THRESH_MULT = 3       ' how far above the mean counts as "planet"
Const FORCE_EVEN = 0        ' -1 forces even shifts for all formats
                            ' (Bayer/RAW is auto-forced even regardless)
Const PREVIEW = -1          ' -1 shows the live centering window

' --- Shared state the core + helpers read ---
Dim Shared g_inNum As Integer, g_outNum As Integer
Dim Shared g_w As Long, g_h As Long, g_colorID As Long, g_depth As Long
Dim Shared g_littleEndian As Long, g_planes As Long, g_sampleBytes As Long, g_bpp As Long
Dim Shared g_frameBytes As _Integer64, g_frameCount As Long, g_dataStart As Long
Dim Shared g_cropW As Long, g_cropH As Long, g_cropBytes As Long
Dim Shared g_written As Long

' --- Pick the input capture ---
Dim inpath As String
inpath = _OpenFileDialog$("Open SER capture", "", "*.ser", "SER files")
If inpath = "" Then System
g_inNum = FreeFile
Open inpath For Binary As #g_inNum
ReadInHeader

' --- This build does 1-sample (mono/raw) and 3-sample (RGB/BGR) families ---
If g_planes <> 1 And g_planes <> 3 Then
    Print "Unsupported pixel layout."
    Close #g_inNum
    End
End If

' --- Crop box (never larger than the source) ---
g_cropW = CROP_W: g_cropH = CROP_H
If g_cropW > g_w Then g_cropW = g_w
If g_cropH > g_h Then g_cropH = g_h
g_cropBytes = g_cropW * g_cropH * g_bpp

' --- Even-shift snapping keeps a Bayer pattern intact through the crop ---
Dim snapEven As Integer
snapEven = 0
If FORCE_EVEN Then snapEven = -1
If IsBayer%(g_colorID) Then snapEven = -1

' --- Output file ---
Dim pad$
$If WIN Then
    pad$ = "\"
$Else
    pad$ = "/"
$End If
Dim outpath As String
outpath = _CWD$ + pad$ + "centered.ser"
OpenOutSER outpath

' --- Optional preview window ---
Dim prevImg As Long
If PREVIEW Then
    Screen _NewImage(g_cropW, g_cropH, 32)
    _Title "SERCenter  -  centering " + _Trim$(Str$(g_frameCount)) + " frames"
    _ScreenMove _Middle
    prevImg = _NewImage(g_cropW, g_cropH, 32)
End If

' --- Reusable buffers (allocated once) ---
Dim srcM As _MEM: srcM = _MemNew(g_frameBytes)
Dim dstM As _MEM: dstM = _MemNew(g_cropBytes)
Dim frameStr As String: frameStr = Space$(g_frameBytes)
Dim outBuf As String: outBuf = Space$(g_cropBytes)

Dim fr As Long, thr As Long
Dim cx As Double, cy As Double, total As Double
Dim shiftX As Long, shiftY As Long
Dim aborted As Integer: aborted = 0

For fr = 1 To g_frameCount
    ' Load one frame into the work buffer
    Get #g_inNum, g_dataStart + (fr - 1) * g_frameBytes, frameStr
    _MemPut srcM, srcM.OFFSET, frameStr

    ' Threshold, then centroid
    If THRESH_LEVEL > 0 Then thr = THRESH_LEVEL Else thr = AutoThresh&(srcM)
    FrameCentroid srcM, thr, cx, cy, total

    ' Shift that lands the centroid at the crop centre
    shiftX = Int(cx - g_cropW / 2 + 0.5)
    shiftY = Int(cy - g_cropH / 2 + 0.5)
    If snapEven Then
        shiftX = shiftX And -2
        shiftY = shiftY And -2
    End If

    ' Build and write the centered frame
    ShiftCropFrame srcM, g_w, g_h, g_bpp, shiftX, shiftY, dstM, g_cropW, g_cropH
    _MemGet dstM, dstM.OFFSET, outBuf
    Put #g_outNum, , outBuf
    g_written = g_written + 1

    ' Live preview
    If PREVIEW Then
        PreviewFrame dstM, g_cropW, g_cropH, g_sampleBytes, g_littleEndian, prevImg
        _PutImage (0, 0), prevImg
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

Print "Wrote "; outpath
Print "Frames written:"; g_written; " of"; g_frameCount
Print "Crop:"; g_cropW; "x"; g_cropH; "   Format kept as-is"
If aborted Then Print "(aborted early -- file is still valid)"
Print "Feed it to AutoStakkert. Press any key to close."
Sleep

'$INCLUDE:'SERCenterCore.bm'
'$INCLUDE:'SERFmtMono.bm'
'$INCLUDE:'SERFmtRGB.bm'
