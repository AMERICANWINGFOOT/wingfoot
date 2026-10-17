' ============================================================================
' SERPlay.bas  -  Minimal player for uncompressed SER video (8-bit MONO/RGB/BGR)
'
' The SER counterpart to the AVI player -- and a fraction of the size, because
' SER has nothing to walk. Read one 178-byte header, then jump straight to any
' frame by multiplication. Plays VideoTest.ser, or opens a dialog if it's not
' in the current folder. ESC or the close button quits.
'
' Files in the set:
'   SERCommon.bi  - the shared SER header structure + color constants
'   SERPlayLib.bm - ReadHeader, FrameToImage, PlaySER
' ============================================================================

'$Include:'SERCommon.bi'

' SER stores no frame rate, so we pick one for playback here:
Const PLAY_FPS = 30

' --- Header-derived state the helper subs read ---
Dim Shared g_fnum As Integer
Dim Shared g_w As Long, g_h As Long
Dim Shared g_colorID As Long
Dim Shared g_depth As Long
Dim Shared g_frameCount As Long
Dim Shared g_frameBytes As _Integer64
Dim Shared g_dataStart As Long
Dim Shared g_littleEndian As Long ' from header; matters only for 16-bit
Dim Shared g_planes As Long ' 1 (mono/bayer) or 3 (rgb/bgr)
Dim Shared g_sampleBytes As Long ' 1 for <=8-bit, 2 for 9..16-bit

' --- Find the file (fall back to a dialog) and open it ---
Dim serpath As String
serpath = "VideoTest.ser"
If Not _FileExists(serpath) Then
    serpath = _OpenFileDialog$("Open SER file", "", "*.ser", "SER files")
    If serpath = "" Then System
End If

g_fnum = FreeFile
Open serpath For Binary As #g_fnum

' --- Read the header, sanity-check, play, clean up ---
ReadHeader

If g_frameCount < 1 Then
    Close #g_fnum
    Print "No frames found in "; serpath
    End
End If

PlaySER

Close #g_fnum
System

'$INCLUDE:'SERPlayLib.bm'
