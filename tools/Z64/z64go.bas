' z64go.bas -- UI hub for the Z64 archive toolchain
'
' Replaces the old one-button test harness with a real two-mode UI:
'   PACK    -- pick files, set options, run picker -> chunker -> packer
'   EXTRACT -- point at archive + output folder, run unpack -> unchunker
'
' All five pipeline stages still run as separate shell-outs to the
' existing .exes.  Their stdout+stderr is captured to a temp file
' (> log 2>&1) and streamed into the log pane between steps.
'
' Chunk size is HARDCODED to 1 MB.  The chunker will crash at larger
' sizes, so it is not exposed as a UI option and never will be.
'
' Requires alongside this .exe:
'   z64picker.exe   z64chunker.exe   z64pack.exe
'   z64unpack.exe   z64unchunker.exe
'   z64fs.h       z64io.h

Option _Explicit
'$Dynamic
_Title "Z64 Archive Tool"

' =====================================================================
' Layout constants
' =====================================================================
Const SCR_W = 1024
Const SCR_H = 768

Const TITLE_Y = 10

Const TAB_Y1 = 40
Const TAB_Y2 = 74
Const TAB_PACK_X1 = 20
Const TAB_PACK_X2 = 200
Const TAB_EXT_X1 = 210
Const TAB_EXT_X2 = 390

Const QUIT_BTN_X1 = SCR_W - 120
Const QUIT_BTN_X2 = SCR_W - 20
Const QUIT_BTN_Y1 = 40
Const QUIT_BTN_Y2 = 74

Const CONTENT_Y = 96

' -- Pack widgets ------------------------------------------------------
Const PICK_BTN_X1 = 660
Const PICK_BTN_X2 = 900
Const PICK_BTN_Y1 = 110
Const PICK_BTN_Y2 = 150

Const ARCHIVE_FIELD_X1 = 240
Const ARCHIVE_FIELD_X2 = 900
Const ARCHIVE_FIELD_Y1 = 175
Const ARCHIVE_FIELD_Y2 = 210

Const COMPRESS_CBOX_X1 = 40
Const COMPRESS_CBOX_Y1 = 235
Const COMPRESS_CBOX_X2 = 62
Const COMPRESS_CBOX_Y2 = 257

Const PNG_CBOX_X1 = 40
Const PNG_CBOX_Y1 = 270
Const PNG_CBOX_X2 = 62
Const PNG_CBOX_Y2 = 292

' -- Extract widgets ---------------------------------------------------
Const EXT_ARCH_FIELD_X1 = 240
Const EXT_ARCH_FIELD_X2 = 740
Const EXT_ARCH_FIELD_Y1 = 115
Const EXT_ARCH_FIELD_Y2 = 150

Const EXT_BROWSE_BTN_X1 = 760
Const EXT_BROWSE_BTN_X2 = 900
Const EXT_BROWSE_BTN_Y1 = 115
Const EXT_BROWSE_BTN_Y2 = 150

Const EXT_OUT_FIELD_X1 = 240
Const EXT_OUT_FIELD_X2 = 900
Const EXT_OUT_FIELD_Y1 = 175
Const EXT_OUT_FIELD_Y2 = 210

Const CLEANUP_CBOX_X1 = 40
Const CLEANUP_CBOX_Y1 = 235
Const CLEANUP_CBOX_X2 = 62
Const CLEANUP_CBOX_Y2 = 257

' -- Run button + log --------------------------------------------------
Const RUN_BTN_X1 = 380
Const RUN_BTN_X2 = 644
Const RUN_BTN_Y1 = 330
Const RUN_BTN_Y2 = 395

Const LOG_Y1 = 420
Const LOG_Y2 = 748
Const LOG_X1 = 20
Const LOG_X2 = 1004
Const LOG_ROW_H = 14
Const LOG_TOP_PAD = 8

' =====================================================================
' Modes
' =====================================================================
Const MODE_PACK = 0
Const MODE_EXTRACT = 1

' =====================================================================
' Focus IDs (which text field currently accepts keystrokes)
' =====================================================================
Const FOCUS_NONE = 0
Const FOCUS_ARCHIVE = 1 ' pack mode archive filename
Const FOCUS_EXT_ARCH = 2 ' extract mode archive path
Const FOCUS_EXT_OUT = 3 ' extract mode output folder

' =====================================================================
' Temp files used to marshal data between .exes
' =====================================================================
Const PICKS_FILE = "_z64go_picks.txt"
Const EXT_PICKS_FILE = "_z64go_extpicks.txt"
Const MANIFEST_FILE = "_z64go_manifest.txt"
Const LOG_FILE = "_z64go_shellout.txt"
Const ARCH_PICK_FILE = "_z64go_archpick.txt"

' Chunker size (MB).  DO NOT raise this -- larger values crash.
Const CHUNK_MB = "1"

' =====================================================================
' State (module-level so drawing + input + pipeline share it)
' =====================================================================
Dim Shared curMode As Integer
Dim Shared optCompress As Integer
Dim Shared optPNG As Integer
Dim Shared optCleanup As Integer

Dim Shared archivePath As String
Dim Shared extArchivePath As String
Dim Shared extOutputPath As String

Dim Shared pickedCount As Long
Dim Shared focusField As Integer

Dim Shared logLines$(500)
Dim Shared logCount As Long
Dim Shared logScroll As Long

Dim Shared statusText As String

Dim Shared frameCounter As Long

' =====================================================================
' Defaults
' =====================================================================
curMode = MODE_PACK
optCompress = -1
optPNG = 0
optCleanup = -1
archivePath = "default_archive.z64"
extArchivePath = "default_archive.z64"
extOutputPath = "unpacked_files"
pickedCount = 0
focusField = FOCUS_NONE
logCount = -1
logScroll = 0
statusText = "Ready."

Screen _NewImage(SCR_W, SCR_H, 32)
_PrintMode _KeepBackground

' =====================================================================
' Main loop
' =====================================================================
Dim mx As Long, my As Long
Dim mb As Integer, lastMB As Integer
Dim wheelDelta As Long
Dim kbd$
Dim done As Integer: done = 0

Do
    frameCounter = frameCounter + 1

    Cls , _RGB32(24, 26, 32)

    DrawTitleBar
    DrawTabs mx, my
    DrawQuitButton mx, my
    If curMode = MODE_PACK Then
        DrawPackPane mx, my
    Else
        DrawExtractPane mx, my
    End If
    DrawRunButton mx, my
    DrawLogPane

    _Display

    ' --- Input -------------------------------------------------------
    kbd$ = InKey$

    While _MouseInput
        wheelDelta = wheelDelta + _MouseWheel
    Wend
    mx = _MouseX
    my = _MouseY
    mb = _MouseButton(1)

    If mb And Not lastMB Then
        HandleClick mx, my, done
    End If
    lastMB = mb

    If wheelDelta <> 0 Then
        ' Log pane scrolls if mouse is over it.  Otherwise ignored.
        If PtInRect(mx, my, LOG_X1, LOG_Y1, LOG_X2, LOG_Y2) Then
            logScroll = logScroll + wheelDelta * 3
            ClampLogScroll
        End If
        wheelDelta = 0
    End If

    If Len(kbd$) > 0 Then HandleKey kbd$, done

    _Limit 60
Loop Until done

System 0


' =====================================================================
' Drawing
' =====================================================================

Sub DrawTitleBar
    Color _RGB32(230, 240, 255)
    _PrintString (20, TITLE_Y), "Z64 Archive Tool  --  Pack or extract, driven by mouse"
End Sub


Sub DrawTabs (mx As Long, my As Long)
    DrawTab TAB_PACK_X1, TAB_PACK_X2, "PACK", curMode = MODE_PACK, _
            PtInRect(mx, my, TAB_PACK_X1, TAB_Y1, TAB_PACK_X2, TAB_Y2)
    DrawTab TAB_EXT_X1, TAB_EXT_X2, "EXTRACT", curMode = MODE_EXTRACT, _
            PtInRect(mx, my, TAB_EXT_X1, TAB_Y1, TAB_EXT_X2, TAB_Y2)

    ' Divider under tab strip
    Line (0, TAB_Y2 + 1)-(SCR_W, TAB_Y2 + 1), _RGB32(80, 90, 110)
End Sub


Sub DrawTab (x1 As Long, x2 As Long, label$, active As Integer, hover As Integer)
    Dim fillC As _Unsigned Long
    Dim borderC As _Unsigned Long

    If active Then
        fillC = _RGB32(70, 130, 90)
        borderC = _RGB32(160, 210, 170)
    ElseIf hover Then
        fillC = _RGB32(60, 80, 110)
        borderC = _RGB32(140, 170, 210)
    Else
        fillC = _RGB32(45, 50, 62)
        borderC = _RGB32(100, 115, 140)
    End If

    Line (x1, TAB_Y1)-(x2, TAB_Y2), fillC, BF
    Line (x1, TAB_Y1)-(x2, TAB_Y2), borderC, B
    Color _RGB32(255, 255, 255)
    _PrintString (x1 + (x2 - x1) \ 2 - Len(label$) * 4, TAB_Y1 + 10), label$
End Sub


Sub DrawQuitButton (mx As Long, my As Long)
    Dim hover As Integer
    hover = PtInRect(mx, my, QUIT_BTN_X1, QUIT_BTN_Y1, QUIT_BTN_X2, QUIT_BTN_Y2)

    Dim fillC As _Unsigned Long, borderC As _Unsigned Long
    If hover Then
        fillC = _RGB32(170, 90, 90)
        borderC = _RGB32(240, 180, 180)
    Else
        fillC = _RGB32(110, 50, 50)
        borderC = _RGB32(200, 140, 140)
    End If

    Line (QUIT_BTN_X1, QUIT_BTN_Y1)-(QUIT_BTN_X2, QUIT_BTN_Y2), fillC, BF
    Line (QUIT_BTN_X1, QUIT_BTN_Y1)-(QUIT_BTN_X2, QUIT_BTN_Y2), borderC, B
    Color _RGB32(255, 255, 255)
    Dim label$: label$ = "QUIT"
    _PrintString (QUIT_BTN_X1 + (QUIT_BTN_X2 - QUIT_BTN_X1) \ 2 - Len(label$) * 4, _
                  QUIT_BTN_Y1 + 10), label$
End Sub


Sub DrawPackPane (mx As Long, my As Long)
    Color _RGB32(200, 220, 240)
    _PrintString (40, 115), "Picked files: " + LTrim$(Str$(pickedCount))

    DrawButton PICK_BTN_X1, PICK_BTN_Y1, PICK_BTN_X2, PICK_BTN_Y2, _
               "Pick Files...", _
               PtInRect(mx, my, PICK_BTN_X1, PICK_BTN_Y1, PICK_BTN_X2, PICK_BTN_Y2), _
               _RGB32(50, 90, 140), _RGB32(70, 120, 180)

    Color _RGB32(200, 220, 240)
    _PrintString (40, 185), "Output archive:"

    DrawTextField ARCHIVE_FIELD_X1, ARCHIVE_FIELD_Y1, _
                  ARCHIVE_FIELD_X2, ARCHIVE_FIELD_Y2, _
                  archivePath, focusField = FOCUS_ARCHIVE

    DrawCheckbox COMPRESS_CBOX_X1, COMPRESS_CBOX_Y1, _
                 COMPRESS_CBOX_X2, COMPRESS_CBOX_Y2, optCompress
    Color _RGB32(220, 230, 250)
    _PrintString (COMPRESS_CBOX_X2 + 10, COMPRESS_CBOX_Y1 + 4), _
                 "Compression (deflate)"

    DrawCheckbox PNG_CBOX_X1, PNG_CBOX_Y1, PNG_CBOX_X2, PNG_CBOX_Y2, optPNG
    Color _RGB32(220, 230, 250)
    _PrintString (PNG_CBOX_X2 + 10, PNG_CBOX_Y1 + 4), _
                 "PNG container (wraps .z64 into a .png)"

    Color _RGB32(140, 150, 170)
    _PrintString (40, 302), "(chunk size fixed at 1 MB -- larger sizes are unsafe)"
End Sub


Sub DrawExtractPane (mx As Long, my As Long)
    Color _RGB32(200, 220, 240)
    _PrintString (40, 125), "Archive path:"

    DrawTextField EXT_ARCH_FIELD_X1, EXT_ARCH_FIELD_Y1, _
                  EXT_ARCH_FIELD_X2, EXT_ARCH_FIELD_Y2, _
                  extArchivePath, focusField = FOCUS_EXT_ARCH

    DrawButton EXT_BROWSE_BTN_X1, EXT_BROWSE_BTN_Y1, _
               EXT_BROWSE_BTN_X2, EXT_BROWSE_BTN_Y2, _
               "Browse...", _
               PtInRect(mx, my, EXT_BROWSE_BTN_X1, EXT_BROWSE_BTN_Y1, _
                                EXT_BROWSE_BTN_X2, EXT_BROWSE_BTN_Y2), _
               _RGB32(50, 90, 140), _RGB32(70, 120, 180)

    Color _RGB32(200, 220, 240)
    _PrintString (40, 185), "Output folder:"

    DrawTextField EXT_OUT_FIELD_X1, EXT_OUT_FIELD_Y1, _
                  EXT_OUT_FIELD_X2, EXT_OUT_FIELD_Y2, _
                  extOutputPath, focusField = FOCUS_EXT_OUT

    DrawCheckbox CLEANUP_CBOX_X1, CLEANUP_CBOX_Y1, _
                 CLEANUP_CBOX_X2, CLEANUP_CBOX_Y2, optCleanup
    Color _RGB32(220, 230, 250)
    _PrintString (CLEANUP_CBOX_X2 + 10, CLEANUP_CBOX_Y1 + 4), _
                 "Cleanup chunk files after unchunking (/cleanup)"
End Sub


Sub DrawRunButton (mx As Long, my As Long)
    Dim label$
    If curMode = MODE_PACK Then label$ = "RUN PACK" Else label$ = "RUN EXTRACT"

    Dim hover As Integer
    hover = PtInRect(mx, my, RUN_BTN_X1, RUN_BTN_Y1, RUN_BTN_X2, RUN_BTN_Y2)

    Dim fillC As _Unsigned Long, borderC As _Unsigned Long
    If hover Then
        fillC = _RGB32(80, 170, 90)
        borderC = _RGB32(180, 240, 190)
    Else
        fillC = _RGB32(50, 130, 60)
        borderC = _RGB32(130, 200, 140)
    End If

    Line (RUN_BTN_X1, RUN_BTN_Y1)-(RUN_BTN_X2, RUN_BTN_Y2), fillC, BF
    Line (RUN_BTN_X1, RUN_BTN_Y1)-(RUN_BTN_X2, RUN_BTN_Y2), borderC, B
    Color _RGB32(255, 255, 255)
    _PrintString (RUN_BTN_X1 + (RUN_BTN_X2 - RUN_BTN_X1) \ 2 - Len(label$) * 4, _
                  RUN_BTN_Y1 + (RUN_BTN_Y2 - RUN_BTN_Y1) \ 2 - 8), label$
End Sub


Sub DrawLogPane
    Line (LOG_X1, LOG_Y1)-(LOG_X2, LOG_Y2), _RGB32(18, 20, 26), BF
    Line (LOG_X1, LOG_Y1)-(LOG_X2, LOG_Y2), _RGB32(80, 100, 130), B

    Color _RGB32(180, 220, 255)
    _PrintString (LOG_X1 + 8, LOG_Y1 + 6), "Log:  " + statusText

    Line (LOG_X1 + 6, LOG_Y1 + 26)-(LOG_X2 - 6, LOG_Y1 + 27), _RGB32(60, 75, 100)

    Dim pageRows As Long
    pageRows = (LOG_Y2 - (LOG_Y1 + 30) - LOG_TOP_PAD) \ LOG_ROW_H

    Dim firstRow As Long
    firstRow = (logCount + 1) - pageRows - logScroll
    If firstRow < 0 Then firstRow = 0

    Dim i As Long
    Dim y As Long: y = LOG_Y1 + 32 + LOG_TOP_PAD
    Color _RGB32(210, 220, 235)
    For i = firstRow To firstRow + pageRows - 1
        If i > logCount Then Exit For
        _PrintString (LOG_X1 + 10, y), TruncateRight$(logLines$(i), 158)
        y = y + LOG_ROW_H
    Next i
End Sub


Sub DrawTextField (x1 As Long, y1 As Long, x2 As Long, y2 As Long, _
                   value$, focused As Integer)
    Dim borderC As _Unsigned Long
    If focused Then
        borderC = _RGB32(120, 200, 130)
    Else
        borderC = _RGB32(100, 115, 140)
    End If

    Line (x1, y1)-(x2, y2), _RGB32(30, 33, 40), BF
    Line (x1, y1)-(x2, y2), borderC, B

    Color _RGB32(220, 230, 250)
    _PrintString (x1 + 8, y1 + 10), TruncateLeftFit$(value$, x2 - x1 - 20)

    ' Blinking cursor when focused
    If focused And ((frameCounter \ 30) Mod 2 = 0) Then
        Dim cx As Long
        cx = x1 + 8 + _PrintWidth(TruncateLeftFit$(value$, x2 - x1 - 20))
        If cx > x2 - 6 Then cx = x2 - 6
        Line (cx, y1 + 8)-(cx, y2 - 8), _RGB32(230, 240, 255)
    End If
End Sub


Sub DrawButton (x1 As Long, y1 As Long, x2 As Long, y2 As Long, _
                label$, hover As Integer, baseC As _Unsigned Long, _
                hoverC As _Unsigned Long)
    Dim fillC As _Unsigned Long
    If hover Then fillC = hoverC Else fillC = baseC

    Line (x1, y1)-(x2, y2), fillC, BF
    Line (x1, y1)-(x2, y2), _RGB32(180, 200, 240), B
    Color _RGB32(255, 255, 255)
    _PrintString (x1 + (x2 - x1) \ 2 - Len(label$) * 4, _
                  y1 + (y2 - y1) \ 2 - 8), label$
End Sub


Sub DrawCheckbox (x1 As Long, y1 As Long, x2 As Long, y2 As Long, checked As Integer)
    Line (x1, y1)-(x2, y2), _RGB32(30, 33, 40), BF
    Line (x1, y1)-(x2, y2), _RGB32(200, 210, 230), B
    If checked Then
        Line (x1 + 3, y1 + 3)-(x2 - 3, y2 - 3), _RGB32(80, 200, 90), BF
        Line (x1 + 3, y1 + 3)-(x2 - 3, y2 - 3), _RGB32(20, 60, 20)
        Line (x1 + 3, y2 - 3)-(x2 - 3, y1 + 3), _RGB32(20, 60, 20)
    End If
End Sub


' =====================================================================
' Input handling
' =====================================================================

Sub HandleClick (mx As Long, my As Long, done As Integer)
    ' Quit -- checked first so it always wins.
    If PtInRect(mx, my, QUIT_BTN_X1, QUIT_BTN_Y1, QUIT_BTN_X2, QUIT_BTN_Y2) Then
        done = -1: Exit Sub
    End If

    ' Tabs
    If PtInRect(mx, my, TAB_PACK_X1, TAB_Y1, TAB_PACK_X2, TAB_Y2) Then
        curMode = MODE_PACK: focusField = FOCUS_NONE: Exit Sub
    End If
    If PtInRect(mx, my, TAB_EXT_X1, TAB_Y1, TAB_EXT_X2, TAB_Y2) Then
        curMode = MODE_EXTRACT: focusField = FOCUS_NONE: Exit Sub
    End If

    ' Run button
    If PtInRect(mx, my, RUN_BTN_X1, RUN_BTN_Y1, RUN_BTN_X2, RUN_BTN_Y2) Then
        focusField = FOCUS_NONE
        If curMode = MODE_PACK Then
            RunPackPipeline
        Else
            RunExtractPipeline
        End If
        Exit Sub
    End If

    If curMode = MODE_PACK Then
        If PtInRect(mx, my, PICK_BTN_X1, PICK_BTN_Y1, PICK_BTN_X2, PICK_BTN_Y2) Then
            focusField = FOCUS_NONE
            RunPickFiles
            Exit Sub
        End If

        If PtInRect(mx, my, ARCHIVE_FIELD_X1, ARCHIVE_FIELD_Y1, _
                            ARCHIVE_FIELD_X2, ARCHIVE_FIELD_Y2) Then
            focusField = FOCUS_ARCHIVE: Exit Sub
        End If

        If PtInRect(mx, my, COMPRESS_CBOX_X1, COMPRESS_CBOX_Y1, _
                            COMPRESS_CBOX_X2 + 200, COMPRESS_CBOX_Y2) Then
            optCompress = Not optCompress: Exit Sub
        End If
        If PtInRect(mx, my, PNG_CBOX_X1, PNG_CBOX_Y1, _
                            PNG_CBOX_X2 + 300, PNG_CBOX_Y2) Then
            optPNG = Not optPNG
            NormalizeArchiveExt
            Exit Sub
        End If
    Else
        If PtInRect(mx, my, EXT_ARCH_FIELD_X1, EXT_ARCH_FIELD_Y1, _
                            EXT_ARCH_FIELD_X2, EXT_ARCH_FIELD_Y2) Then
            focusField = FOCUS_EXT_ARCH: Exit Sub
        End If
        If PtInRect(mx, my, EXT_BROWSE_BTN_X1, EXT_BROWSE_BTN_Y1, _
                            EXT_BROWSE_BTN_X2, EXT_BROWSE_BTN_Y2) Then
            focusField = FOCUS_NONE
            RunBrowseArchive
            Exit Sub
        End If
        If PtInRect(mx, my, EXT_OUT_FIELD_X1, EXT_OUT_FIELD_Y1, _
                            EXT_OUT_FIELD_X2, EXT_OUT_FIELD_Y2) Then
            focusField = FOCUS_EXT_OUT: Exit Sub
        End If
        If PtInRect(mx, my, CLEANUP_CBOX_X1, CLEANUP_CBOX_Y1, _
                            CLEANUP_CBOX_X2 + 400, CLEANUP_CBOX_Y2) Then
            optCleanup = Not optCleanup: Exit Sub
        End If
    End If

    ' Click outside any field defocuses.
    focusField = FOCUS_NONE
End Sub


Sub HandleKey (k$, done As Integer)
    ' Global key: ESC always defocuses; if nothing focused, quits.
    If k$ = Chr$(27) Then
        If focusField <> FOCUS_NONE Then
            focusField = FOCUS_NONE
        Else
            done = -1
        End If
        Exit Sub
    End If

    If focusField = FOCUS_NONE Then Exit Sub

    Select Case k$
        Case Chr$(8) ' backspace
            Select Case focusField
                Case FOCUS_ARCHIVE
                    If Len(archivePath) > 0 Then _
                        archivePath = Left$(archivePath, Len(archivePath) - 1)
                Case FOCUS_EXT_ARCH
                    If Len(extArchivePath) > 0 Then _
                        extArchivePath = Left$(extArchivePath, Len(extArchivePath) - 1)
                Case FOCUS_EXT_OUT
                    If Len(extOutputPath) > 0 Then _
                        extOutputPath = Left$(extOutputPath, Len(extOutputPath) - 1)
            End Select
        Case Chr$(13) ' enter -- commit
            focusField = FOCUS_NONE
        Case Chr$(9) ' tab -- cycle focus in current mode
            CycleFocus
        Case Else
            If Len(k$) = 1 Then
                Dim c As Integer: c = Asc(k$)
                If c >= 32 And c < 127 Then
                    Select Case focusField
                        Case FOCUS_ARCHIVE: archivePath = archivePath + k$
                        Case FOCUS_EXT_ARCH: extArchivePath = extArchivePath + k$
                        Case FOCUS_EXT_OUT: extOutputPath = extOutputPath + k$
                    End Select
                End If
            End If
    End Select
End Sub


Sub CycleFocus
    If curMode = MODE_PACK Then
        If focusField = FOCUS_ARCHIVE Then
            focusField = FOCUS_NONE
        Else
            focusField = FOCUS_ARCHIVE
        End If
    Else
        Select Case focusField
            Case FOCUS_EXT_ARCH: focusField = FOCUS_EXT_OUT
            Case FOCUS_EXT_OUT: focusField = FOCUS_NONE
            Case Else: focusField = FOCUS_EXT_ARCH
        End Select
    End If
End Sub


' =====================================================================
' Pipeline runners
' =====================================================================

Sub RunPickFiles
    LogClear
    LogAdd "-- Running z64picker..."
    ShowBusy "Picking files (external picker window)..."

    ' Clear any stale picks file so we can tell "picker didn't run"
    ' from "picker returned empty".
    If _FileExists(PICKS_FILE) Then Kill PICKS_FILE

    ' Direct Shell -- z64picker is a graphical app, its own window is
    ' the UI, and wrapping it in cmd /c ... > log with _Hide can prevent
    ' the picker window from showing on some setups.
    Shell "z64picker.exe " + Q$(PICKS_FILE)

    If _FileExists(PICKS_FILE) Then
        pickedCount = CountLines&(PICKS_FILE)
        LogAdd "z64picker returned " + LTrim$(Str$(pickedCount)) + " picked file(s)."
        statusText = "Picked " + LTrim$(Str$(pickedCount)) + " file(s)."
    Else
        LogAdd "z64picker did not produce " + PICKS_FILE + "."
        LogAdd "Check that z64picker.exe and z64fs.dll are next to z64go.exe."
        pickedCount = 0
        statusText = "Picker did not run."
    End If
End Sub


Sub RunBrowseArchive
    LogClear
    LogAdd "-- Browsing for archive (via z64picker)..."
    ShowBusy "Browsing (external picker window)..."

    ' Clear any stale pick file so we can detect picker failure.
    If _FileExists(ARCH_PICK_FILE) Then Kill ARCH_PICK_FILE

    ' Direct Shell -- same reasoning as RunPickFiles.
    Shell "z64picker.exe " + Q$(ARCH_PICK_FILE)

    ' Grab first non-empty non-comment line as the chosen archive.
    Dim fh As Long
    Dim line$
    Dim picked$: picked$ = ""

    If _FileExists(ARCH_PICK_FILE) Then
        fh = FreeFile
        Open ARCH_PICK_FILE For Input As #fh
        Do While Not EOF(fh)
            Line Input #fh, line$
            line$ = _Trim$(line$)
            If Len(line$) > 0 And Left$(line$, 1) <> "#" Then
                picked$ = line$
                Exit Do
            End If
        Loop
        Close #fh
        Kill ARCH_PICK_FILE
    End If

    If Len(picked$) > 0 Then
        extArchivePath = picked$
        LogAdd "Selected archive: " + picked$
        statusText = "Archive selected."
    Else
        LogAdd "No archive picked."
        statusText = "No archive picked."
    End If
End Sub


Sub RunPackPipeline
    If pickedCount <= 0 Then
        statusText = "No files picked -- click 'Pick Files...' first."
        Exit Sub
    End If
    If Len(_Trim$(archivePath)) = 0 Then
        statusText = "Please enter an output archive name."
        Exit Sub
    End If

    ' Make sure the archive filename matches the current PNG toggle
    ' before we shell out, so the on-screen name matches what lands
    ' on disk (z64pack.exe would rewrite it internally otherwise).
    NormalizeArchiveExt

    LogClear
    LogAdd "=== PACK ==="

    ' 1) Chunker: extended picks + manifest
    Dim cmd$
    cmd$ = "z64chunker.exe " + Q$(PICKS_FILE) + " " + _
                                Q$(EXT_PICKS_FILE) + " " + _
                                Q$(MANIFEST_FILE) + " " + CHUNK_MB
    LogAdd "-- Step 1/2: chunker"
    LogAdd "   " + cmd$
    ShowBusy "Step 1/2: planning chunks..."
    ShellCapture cmd$

    ' 2) Packer: archive
    cmd$ = "z64pack.exe " + Q$(EXT_PICKS_FILE) + " " + Q$(archivePath)
    If optCompress Then cmd$ = cmd$ + " /compress"
    If optPNG Then cmd$ = cmd$ + " /png"
    cmd$ = cmd$ + " /manifest " + Q$(MANIFEST_FILE)

    LogAdd "-- Step 2/2: packer"
    LogAdd "   " + cmd$
    ShowBusy "Step 2/2: packing archive..."
    ShellCapture cmd$

    LogAdd "=== PACK COMPLETE ==="
    statusText = "Pack complete: " + archivePath
End Sub


Sub RunExtractPipeline
    If Len(_Trim$(extArchivePath)) = 0 Then
        statusText = "Please enter an archive path."
        Exit Sub
    End If
    If Not _FileExists(extArchivePath) Then
        statusText = "Archive not found: " + extArchivePath
        Exit Sub
    End If
    If Len(_Trim$(extOutputPath)) = 0 Then
        statusText = "Please enter an output folder."
        Exit Sub
    End If

    LogClear
    LogAdd "=== EXTRACT ==="

    ' 1) Unpack
    Dim cmd$
    cmd$ = "z64unpack.exe " + Q$(extArchivePath) + " " + Q$(extOutputPath)
    LogAdd "-- Step 1/2: unpacker"
    LogAdd "   " + cmd$
    ShowBusy "Step 1/2: unpacking archive..."
    ShellCapture cmd$

    ' 2) Unchunker (in-place; input dir == output dir)
    cmd$ = "z64unchunker.exe " + Q$(extOutputPath) + " " + Q$(extOutputPath)
    If optCleanup Then cmd$ = cmd$ + " /cleanup"
    LogAdd "-- Step 2/2: unchunker"
    LogAdd "   " + cmd$
    ShowBusy "Step 2/2: reassembling chunks..."
    ShellCapture cmd$

    LogAdd "=== EXTRACT COMPLETE ==="
    statusText = "Extract complete: " + extOutputPath
End Sub


Sub ShowBusy (msg$)
    ' Quick redraw so the user sees what's happening before Shell blocks.
    statusText = msg$
    Cls , _RGB32(24, 26, 32)
    DrawTitleBar
    DrawTabs -1, -1
    DrawQuitButton -1, -1
    If curMode = MODE_PACK Then DrawPackPane -1, -1 Else DrawExtractPane -1, -1
    DrawRunButton -1, -1
    DrawLogPane

    Color _RGB32(255, 220, 100)
    _PrintString (RUN_BTN_X1, RUN_BTN_Y2 + 15), "Working: " + msg$
    _Display
End Sub


Sub ShellCapture (cmd$)
    ' Run cmd$ with output redirected to LOG_FILE, then splice that file
    ' into logLines$().  Using cmd /c wraps the whole command in one
    ' invocation so redirection works reliably regardless of the child.
    Dim wrapped$
    wrapped$ = "cmd /c " + Chr$(34) + cmd$ + " > " + LOG_FILE + " 2>&1" + Chr$(34)
    Shell _Hide wrapped$
    AppendFileToLog LOG_FILE
    If _FileExists(LOG_FILE) Then Kill LOG_FILE
End Sub


Sub AppendFileToLog (path$)
    If Not _FileExists(path$) Then Exit Sub
    Dim fh As Long
    Dim line$
    fh = FreeFile
    Open path$ For Input As #fh
    Do While Not EOF(fh)
        Line Input #fh, line$
        LogAdd line$
    Loop
    Close #fh
End Sub


' =====================================================================
' Log buffer helpers
' =====================================================================

Sub LogClear
    logCount = -1
    logScroll = 0
End Sub


Sub LogAdd (s$)
    ' Ring-buffer-ish: if the array fills, drop the oldest half.
    If logCount + 1 >= UBound(logLines$) Then
        Dim i As Long
        Dim keep As Long: keep = UBound(logLines$) \ 2
        For i = 0 To keep - 1
            logLines$(i) = logLines$(logCount - keep + 1 + i)
        Next i
        logCount = keep - 1
    End If
    logCount = logCount + 1
    logLines$(logCount) = s$
    logScroll = 0
End Sub


Sub ClampLogScroll
    Dim pageRows As Long
    pageRows = (LOG_Y2 - (LOG_Y1 + 30) - LOG_TOP_PAD) \ LOG_ROW_H
    Dim maxScroll As Long
    maxScroll = (logCount + 1) - pageRows
    If maxScroll < 0 Then maxScroll = 0
    If logScroll < 0 Then logScroll = 0
    If logScroll > maxScroll Then logScroll = maxScroll
End Sub


' =====================================================================
' Small helpers
' =====================================================================

Function PtInRect (px As Long, py As Long, x1 As Long, y1 As Long, x2 As Long, y2 As Long)
    If px >= x1 And px <= x2 And py >= y1 And py <= y2 Then _
        PtInRect = -1 Else PtInRect = 0
End Function


Function Q$ (s$)
    ' Wrap in double quotes -- lets us safely pass paths with spaces.
    Q$ = Chr$(34) + s$ + Chr$(34)
End Function


Sub NormalizeArchiveExt
    ' Mirror z64pack.exe's internal extension normalization so the UI
    ' matches what will actually land on disk.  If PNG mode is on, the
    ' file is written as .png; otherwise .z64.
    Dim currentExt$
    If Len(archivePath) >= 4 Then
        currentExt$ = LCase$(Right$(archivePath, 4))
    End If

    If optPNG Then
        If currentExt$ = ".z64" Then
            archivePath = Left$(archivePath, Len(archivePath) - 4) + ".png"
        ElseIf currentExt$ <> ".png" Then
            archivePath = archivePath + ".png"
        End If
    Else
        If currentExt$ = ".png" Then
            archivePath = Left$(archivePath, Len(archivePath) - 4) + ".z64"
        ElseIf currentExt$ <> ".z64" Then
            archivePath = archivePath + ".z64"
        End If
    End If
End Sub


Function CountLines& (path$)
    If Not _FileExists(path$) Then Exit Function
    Dim fh As Long
    Dim n As Long: n = 0
    Dim line$
    fh = FreeFile
    Open path$ For Input As #fh
    Do While Not EOF(fh)
        Line Input #fh, line$
        line$ = _Trim$(line$)
        If Len(line$) > 0 And Left$(line$, 1) <> "#" Then n = n + 1
    Loop
    Close #fh
    CountLines& = n
End Function


Function TruncateLeftFit$ (s$, maxPx As Long)
    ' If s$ is wider than maxPx pixels, show "..." + right slice that fits.
    If _PrintWidth(s$) <= maxPx Then
        TruncateLeftFit$ = s$
        Exit Function
    End If
    Dim n As Long: n = Len(s$)
    Do While n > 0
        n = n - 1
        If _PrintWidth("..." + Right$(s$, n)) <= maxPx Then
            TruncateLeftFit$ = "..." + Right$(s$, n)
            Exit Function
        End If
    Loop
    TruncateLeftFit$ = "..."
End Function


Function TruncateRight$ (s$, maxLen As Long)
    If Len(s$) <= maxLen Then
        TruncateRight$ = s$
    Else
        TruncateRight$ = Left$(s$, maxLen - 3) + "..."
    End If
End Function
