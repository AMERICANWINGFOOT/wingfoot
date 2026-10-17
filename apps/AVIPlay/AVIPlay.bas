' ============================================================================
' AVIPlay.bas  -  Minimal player for uncompressed AVI (32-bit video + 16-bit PCM)
'
' Companion to the AVI writer. Plays VideoTest.avi with the video paced by an
' audio master clock so the two stay locked. If VideoTest.avi isn't in the
' current folder, an Open dialog appears. ESC or the close button quits.
'
' How it works, in reverse of the writer:
'   * Walk the RIFF tree for width/height/fps and the audio format.  -> AVIRiff.bm
'   * Index every chunk in the 'movi' list and decode all audio.     -> AVIRiff.bm
'   * Show the frame the audio clock lands on; feed PCM to _SndRaw.   -> AVIPlayback.bm
'
' The heavy lifting lives in the helper includes; this file is just the flow:
'   AVITypes.bi    - structures + shared globals
'   AVIRiff.bm     - ReadID$, ParseTop, ScanHdrl, IndexMovi
'   AVIPlayback.bm - PlayAVI
' ============================================================================

'$INCLUDE:'AVITypes.bi'

' --- Sensible defaults, overwritten by whatever the file actually declares ---
g_fps = 30
g_audRate = 44100
g_audChannels = 2
g_audBits = 16
g_bitCount = 32

' --- Find the file (fall back to a dialog) and open it ---
Dim avipath As String
avipath = "VideoTest.avi"
If Not _FileExists(avipath) Then
    avipath = _OpenFileDialog$("Open AVI file", "", "*.avi", "AVI files")
    If avipath = "" Then System
End If

g_fnum = FreeFile
Open avipath For Binary As #g_fnum

' --- Parse the headers, then build the frame/audio index ---
ParseTop
IndexMovi

If g_frCount < 1 Then
    Close #g_fnum
    Print "No video frames found in "; avipath
    End
End If

g_frameBytes = g_vidW * g_vidH * (g_bitCount \ 8)

' --- Play, then clean up ---
PlayAVI

Close #g_fnum
System

'$INCLUDE:'AVIRiff.bm'
'$INCLUDE:'AVIPlayback.bm'
