' ============================================================================
' AVITypes.bi  -  Shared structures and globals for the AVI player
'
' Include this near the TOP of the main program:
'     '$INCLUDE:'AVITypes.bi'
'
' Holds the RIFF/AVI header layouts and every g_* value the helper subs read.
' ============================================================================

' --- AVI main header (avih), 56 bytes ---
Type AVIMainHeader
    microSecPerFrame As Long
    maxBytesPerSec As Long
    paddingGranularity As Long
    flags As Long
    totalFrames As Long
    initialFrames As Long
    streams As Long
    suggestedBufferSize As Long
    width As Long
    height As Long
    reserved As String * 16
End Type

' --- Stream header (strh), 64 bytes as written by the encoder ---
Type AVIStreamHeader
    fccType As String * 4
    fccHandler As String * 4
    flags As Long
    priority As Integer
    language As Integer
    initialFrames As Long
    scale As Long
    rate As Long
    start As Long
    length As Long
    suggestedBufferSize As Long
    quality As Long
    sampleSize As Long
    frameLeft As Long
    frameTop As Long
    frameRight As Long
    frameBottom As Long
End Type

' --- Video format (strf), BITMAPINFOHEADER, 40 bytes ---
Type BITMAPINFOHEADER
    biSize As Long
    biWidth As Long
    biHeight As Long
    biPlanes As Integer
    biBitCount As Integer
    biCompression As Long
    biSizeImage As Long
    biXPelsPerMeter As Long
    biYPelsPerMeter As Long
    biClrUsed As Long
    biClrImportant As Long
End Type

' --- Audio format (strf), WAVEFORMATEX, 18 bytes as written ---
Type WAVEFORMATEX
    wFormatTag As Integer
    nChannels As Integer
    nSamplesPerSec As Long
    nAvgBytesPerSec As Long
    nBlockAlign As Integer
    wBitsPerSample As Integer
    cbSize As Integer
End Type

' --- Parsed stream parameters (shared with the helper subs) ---
Dim Shared g_fnum As Integer
Dim Shared g_vidW As Long, g_vidH As Long, g_bitCount As Integer
Dim Shared g_fps As Single
Dim Shared g_numFrames As Long
Dim Shared g_frameBytes As Long
Dim Shared g_audRate As Long, g_audChannels As Integer, g_audBits As Integer
Dim Shared g_moviData As Long, g_moviLen As Long

' --- Chunk index built from the movi list ---
Dim Shared g_frCount As Long
ReDim Shared g_frPos(0) As Long
ReDim Shared g_frSize(0) As Long
Dim Shared g_audCount As Long
ReDim Shared g_aud(0) As Integer
