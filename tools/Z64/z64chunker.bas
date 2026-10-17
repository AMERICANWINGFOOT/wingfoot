' z64chunker.bas -- standalone chunk planner for QB64-PE 4.5.0
'
' Reads a picks file, examines each listed file's size, and produces
' two output files: an extended picks file that describes how the
' packer should read each entry (whole file or slice by offset+len),
' and a manifest that describes how the unchunker should reassemble
' chunks back into their originals on the extract side.
'
' No actual file splitting happens on disk.  This tool only PLANS.
' The packer does the reading in slices when it processes the
' extended picks file.  Original source files are never modified.
'
' Usage:
'   z64chunker.exe <input-picks> <output-picks> <output-manifest> [chunk-mb]
'
'   input-picks      Standard z64picker output: one absolute path per line.
'   output-picks     Extended picks file for the packer.
'   output-manifest  Reassembly plan for the unchunker.
'   chunk-mb         Optional chunk size in MB (default 64).  Files up to
'                    2x this size pass through unchunked; larger files get
'                    split into <chunk-mb>-sized pieces.
'
' Exit codes:
'   0  Chunking analyzed successfully, both output files written
'   1  Input picks file didn't exist or was empty
'   2  One or more listed files couldn't be measured (didn't exist)
'   3  Internal error (bad args, couldn't write output, etc.)
'
' Extended picks file format:
'   Blank lines and lines starting with # are comments/skipped.
'
'   Passthrough entry (small files):
'     C:\path\to\file.ext
'
'   Chunk entry (large files, one line per chunk):
'     C:\path\to\huge.avi | huge.avi.chunk001 | 0        | 67108864
'     C:\path\to\huge.avi | huge.avi.chunk002 | 67108864 | 67108864
'     ...
'
'   Fields (chunk lines): source_path | stored_name | byte_offset | length
'   Whitespace around | is stripped by the packer.
'
' Manifest format (compressed into the archive as .z64manifest):
'   # z64 chunk manifest v1
'   # ...comments...
'   original_name | chunk_name | chunk_index | total_chunks | chunk_size
'
'   Only chunked files appear in the manifest.  Passthrough files aren't
'   listed because they don't need reassembly.
_Title ("Z64 Chunker")
Option _Explicit
'$Dynamic

Const EXIT_OK = 0
Const EXIT_NOPICKS = 1
Const EXIT_MISSING = 2
Const EXIT_ERROR = 3

Const DEFAULT_CHUNK_MB = 64
Const MANIFEST_ENTRY = ".z64manifest"

Dim inputPicks$
Dim outputPicks$
Dim outputManifest$
Dim chunkSizeMB As _Unsigned _Integer64
Dim chunkSize As _Unsigned _Integer64
Dim chunkThreshold As _Unsigned _Integer64
Dim i As Long

'--- Parse CLI ---
If _CommandCount < 3 Then
    Print "z64chunker -- standalone chunk planner"
    Print
    Print "Usage: z64chunker <input-picks> <output-picks> <output-manifest> [chunk-mb]"
    Print
    Print "  input-picks      Standard z64picker output."
    Print "  output-picks     Extended picks file for the packer."
    Print "  output-manifest  Reassembly plan for the unchunker."
    Print "  chunk-mb         Optional chunk size in MB (default 64)."
    Print
    Print "Exit codes: 0=ok, 1=no picks, 2=missing input, 3=error"
    System EXIT_ERROR
End If

inputPicks$ = Command$(1)
outputPicks$ = Command$(2)
outputManifest$ = Command$(3)

If _CommandCount >= 4 Then
    chunkSizeMB = Val(Command$(4))
    If chunkSizeMB < 1 Then chunkSizeMB = DEFAULT_CHUNK_MB
Else
    chunkSizeMB = DEFAULT_CHUNK_MB
End If

chunkSize = chunkSizeMB * 1024 * 1024
chunkThreshold = chunkSize * 2

Print "z64chunker: chunk size ="; chunkSizeMB; "MB"
Print "z64chunker: files above"; (chunkThreshold \ (1024 * 1024)); "MB get chunked"
Print

'--- Read input picks file ---
Dim paths$(0)
Dim pathCount As Long: pathCount = -1
Dim line$
Dim fh As Long

If Not _FileExists(inputPicks$) Then
    Print "z64chunker: input picks file not found: "; inputPicks$
    System EXIT_NOPICKS
End If

fh = FreeFile
Open inputPicks$ For Input As #fh
Do While Not EOF(fh)
    Line Input #fh, line$
    line$ = _Trim$(line$)
    If Len(line$) = 0 Then _Continue
    If Left$(line$, 1) = "#" Then _Continue
    '--- Reject already-chunked entries (contains |).  Chunker only
    '--- accepts plain picks files as input for now.
    If InStr(line$, "|") > 0 Then
        Print "z64chunker: input contains chunked entries, aborting"
        Print "  (line: "; line$; ")"
        Print "  chunker only accepts plain picks files"
        System EXIT_ERROR
    End If
    pathCount = pathCount + 1
    ReDim _Preserve paths$(pathCount)
    paths$(pathCount) = line$
Loop
Close #fh

If pathCount < 0 Then
    Print "z64chunker: input picks file was empty"
    System EXIT_NOPICKS
End If

Print "z64chunker: read"; pathCount + 1; "path(s) from"; inputPicks$
Print

'--- Open output files ---
Dim outPicksFH As Long
Dim outManifestFH As Long

outPicksFH = FreeFile
Open outputPicks$ For Output As #outPicksFH
Print #outPicksFH, "# z64 extended picks file"
Print #outPicksFH, "# Generated by z64chunker.exe"
Print #outPicksFH, "# Chunk size: "; LTrim$(Str$(chunkSizeMB)); " MB"
Print #outPicksFH, "#"
Print #outPicksFH, "# Passthrough:  path"
Print #outPicksFH, "# Chunk entry:  source_path | stored_name | offset | length"
Print #outPicksFH, ""

outManifestFH = FreeFile
Open outputManifest$ For Output As #outManifestFH
Print #outManifestFH, "# z64 chunk manifest v1"
Print #outManifestFH, "# Generated by z64chunker.exe"
Print #outManifestFH, "# Chunk size: "; LTrim$(Str$(chunkSizeMB)); " MB"
Print #outManifestFH, "#"
Print #outManifestFH, "# Format: original_name | chunk_name | chunk_index | total_chunks | chunk_size"
Print #outManifestFH, "# (only chunked files appear here; passthrough files omitted)"
Print #outManifestFH, ""

'--- Analyze each input path ---
Dim missingCount As Long: missingCount = 0
Dim passthruCount As Long: passthruCount = 0
Dim chunkedCount As Long: chunkedCount = 0
Dim totalChunksWritten As _Unsigned _Integer64: totalChunksWritten = 0
Dim srcSize As _Unsigned _Integer64
Dim bareName$
Dim chunkIdx As _Unsigned _Integer64
Dim totalChunks As _Unsigned _Integer64
Dim thisOffset As _Unsigned _Integer64
Dim thisLen As _Unsigned _Integer64
Dim chunkName$

For i = 0 To pathCount
    Print "  ["; LTrim$(Str$(i + 1)); "/"; LTrim$(Str$(pathCount + 1)); "] "; paths$(i);

    If Not _FileExists(paths$(i)) Then
        Print "  -- NOT FOUND (skipped)"
        missingCount = missingCount + 1
        _Continue
    End If

    '--- Measure the file ---
    fh = FreeFile
    Open paths$(i) For Binary As #fh
    srcSize = LOF(fh)
    Close #fh

    bareName$ = BareFilename$(paths$(i))

    If srcSize < chunkThreshold Then
        '--- Passthrough: small file, packer handles it whole ---
        Print "  passthrough ("; LTrim$(Str$(srcSize)); " bytes)"
        Print #outPicksFH, paths$(i)
        passthruCount = passthruCount + 1
    Else
        '--- Chunk: file is large enough to split ---
        totalChunks = (srcSize + chunkSize - 1) \ chunkSize
        Print "  chunk into"; totalChunks; "pieces ("; LTrim$(Str$(srcSize)); " bytes)"

        For chunkIdx = 1 To totalChunks
            thisOffset = (chunkIdx - 1) * chunkSize
            thisLen = chunkSize
            If thisOffset + thisLen > srcSize Then
                thisLen = srcSize - thisOffset
            End If

            chunkName$ = bareName$ + ".chunk" + PadZero$(chunkIdx, 3)

            '--- Write extended picks line ---
            Print #outPicksFH, paths$(i); " | "; chunkName$; " | "; _
                               LTrim$(Str$(thisOffset)); " | "; LTrim$(Str$(thisLen))

            '--- Write manifest line ---
            Print #outManifestFH, bareName$; " | "; chunkName$; " | "; _
                                  LTrim$(Str$(chunkIdx)); " | "; _
                                  LTrim$(Str$(totalChunks)); " | "; _
                                  LTrim$(Str$(thisLen))

            totalChunksWritten = totalChunksWritten + 1
        Next chunkIdx

        chunkedCount = chunkedCount + 1
    End If
Next i
Sleep 1
Close #outPicksFH
Close #outManifestFH

'--- Summary ---
Print
Print "z64chunker: passthrough files: "; passthruCount
Print "z64chunker: chunked files:     "; chunkedCount
Print "z64chunker: total chunks:      "; totalChunksWritten
If missingCount > 0 Then Print "z64chunker: missing files:     "; missingCount
Print
Print "z64chunker: wrote "; outputPicks$
Print "z64chunker: wrote "; outputManifest$

If missingCount > 0 Then System EXIT_MISSING
System EXIT_OK


'=======================================================================
'   Helpers
'=======================================================================

Function BareFilename$ (path$)
    Dim i As Long, ch$
    For i = Len(path$) To 1 Step -1
        ch$ = Mid$(path$, i, 1)
        If ch$ = "\" Or ch$ = "/" Or ch$ = ":" Then
            BareFilename$ = Mid$(path$, i + 1)
            Exit Function
        End If
    Next i
    BareFilename$ = path$
End Function


Function PadZero$ (n As _Unsigned _Integer64, width As Long)
    '--- Return n as a decimal string, zero-padded to at least width chars.
    '--- "1" width 3 -> "001".  For chunk numbering.
    Dim s$: s$ = LTrim$(Str$(n))
    Do While Len(s$) < width
        s$ = "0" + s$
    Loop
    PadZero$ = s$
End Function
