' z64unchunker.bas -- Reassemble chunked files from a z64unpack folder.
'
' Reads a folder produced by z64unpack, finds the embedded manifest
' (.z64manifest), and reassembles each chunked file back into its
' original in the specified output folder.  Pass-through files that
' were never chunked aren't listed in the manifest and aren't handled
' by this tool.
'
' Usage:
'   z64unchunker.exe <chunks-folder> <output-folder> [/cleanup]
'
'   chunks-folder    Folder produced by z64unpack.  Must contain
'                    .z64manifest plus the chunk files it references.
'   output-folder    Where to write reassembled originals.  Created
'                    if missing.
'   /cleanup         After a successful reassembly of an entry, delete
'                    that entry's chunk files.  If a chunk was missing
'                    or the entry failed, its chunks are left in place
'                    so you can inspect them.  If every entry finished
'                    cleanly, the manifest is deleted and the input
'                    folder is removed if it winds up empty.
'
' Exit codes:
'   0  All originals reassembled successfully
'   1  Manifest missing, or input folder didn't exist
'   2  One or more chunks were missing from the input folder
'   3  Internal error (bad args, couldn't create output folder, etc.)

Option _Explicit
_Title "Z64 Unchunker"
'$Dynamic

Const MANIFEST_ENTRY = ".z64manifest"

Const EXIT_OK = 0
Const EXIT_NOMANIFEST = 1
Const EXIT_MISSING = 2
Const EXIT_ERROR = 3

' --- All main-scope Dims up front (QB64-PE hoists, but keep them visible) ---
Dim inputFolder$
Dim outputFolder$
Dim manifestPath$
Dim doCleanup As _Integer64: doCleanup = 0
Dim ai As Long

Dim fhManifest As Long
Dim fhChunk As Long
Dim fhOut As Long
Dim hasOutput As _Integer64: hasOutput = 0

Dim line$
Dim parts$(15)
Dim partCount As Long

Dim origName$, chunkName$
Dim chunkIdx As Long, totalChunks As Long
Dim buffer$
Dim chunkPath$, outputPath$

Dim currentOrig$: currentOrig$ = ""
Dim entrySuccess As _Integer64: entrySuccess = -1

Dim chunkListForEntry$(0)
Dim chunkListCount As Long: chunkListCount = 0
Dim maxChunkListSize As Long: maxChunkListSize = 0

Dim entriesOK As Long: entriesOK = 0
Dim entriesFailed As Long: entriesFailed = 0
Dim chunksMissing As Long: chunksMissing = 0
Dim ci As Long

' --- Parse CLI ---
If _CommandCount < 2 Then
    Print "z64unchunker -- reassemble chunked files"
    Print
    Print "Usage: z64unchunker <chunks-folder> <output-folder> [/cleanup]"
    Print
    Print "Exit codes: 0=ok, 1=no manifest, 2=missing chunks, 3=error"
    System EXIT_ERROR
End If

inputFolder$ = Command$(1)
outputFolder$ = Command$(2)

For ai = 3 To _CommandCount
    If LCase$(Command$(ai)) = "/cleanup" Then doCleanup = -1
Next ai

' --- Normalize folder paths with trailing backslash ---
If Len(inputFolder$) > 0 Then
    If Right$(inputFolder$, 1) <> "\" And Right$(inputFolder$, 1) <> "/" Then
        inputFolder$ = inputFolder$ + "\"
    End If
End If
If Len(outputFolder$) > 0 Then
    If Right$(outputFolder$, 1) <> "\" And Right$(outputFolder$, 1) <> "/" Then
        outputFolder$ = outputFolder$ + "\"
    End If
End If

' --- Preflight ---
If Not _DirExists(inputFolder$) Then
    Print "z64unchunker: input folder not found: "; inputFolder$
    System EXIT_NOMANIFEST
End If

manifestPath$ = inputFolder$ + MANIFEST_ENTRY
If Not _FileExists(manifestPath$) Then
    Print "z64unchunker: manifest not found: "; manifestPath$
    System EXIT_NOMANIFEST
End If

If Not _DirExists(outputFolder$) Then
    MkDir outputFolder$
    If Not _DirExists(outputFolder$) Then
        Print "z64unchunker: cannot create output folder: "; outputFolder$
        System EXIT_ERROR
    End If
End If

Print "z64unchunker: input  = "; inputFolder$
Print "z64unchunker: output = "; outputFolder$
Print "z64unchunker: reading "; manifestPath$
If doCleanup Then Print "z64unchunker: /cleanup enabled"
Print

' --- Walk the manifest ---
fhManifest = FreeFile
Open manifestPath$ For Input As #fhManifest

Do While Not EOF(fhManifest)
    Line Input #fhManifest, line$
    line$ = _Trim$(line$)
    If Len(line$) = 0 Then _Continue
    If Left$(line$, 1) = "#" Then _Continue

    SplitByPipe line$, parts$(), partCount
    If partCount < 5 Then
        Print "  bad manifest line: "; line$
        _Continue
    End If

    origName$ = _Trim$(parts$(0))
    chunkName$ = _Trim$(parts$(1))
    chunkIdx = Val(_Trim$(parts$(2)))
    totalChunks = Val(_Trim$(parts$(3)))
    ' parts$(4) is chunk_size -- we use actual file size instead

    chunkPath$ = inputFolder$ + chunkName$
    outputPath$ = outputFolder$ + origName$

    '--- Start of a new entry (chunkIdx = 1) ---
    If chunkIdx = 1 Then
        '--- Defensive: if previous entry didn't finalize, close it as failed ---
        If hasOutput Then
            Close #fhOut
            hasOutput = 0
            Print "  FAILED -- previous entry never reached its last chunk"
            entriesFailed = entriesFailed + 1
        End If

        currentOrig$ = origName$
        entrySuccess = -1
        chunkListCount = 0

        '--- Grow the per-entry chunk list if needed ---
        If totalChunks > maxChunkListSize Then
            ReDim chunkListForEntry$(totalChunks - 1)
            maxChunkListSize = totalChunks
        End If

        '--- Truncate any existing file at outputPath$, then reopen binary ---
        fhOut = FreeFile
        Open outputPath$ For Output As #fhOut
        Close #fhOut
        fhOut = FreeFile
        Open outputPath$ For Binary As #fhOut
        hasOutput = -1

        Print "Reassembling "; origName$; " ("; LTrim$(Str$(totalChunks)); " chunks)"
    End If

    '--- Append this chunk ---
    If Not _FileExists(chunkPath$) Then
        Print "  MISSING: "; chunkPath$
        chunksMissing = chunksMissing + 1
        entrySuccess = 0
    Else
        fhChunk = FreeFile
        Open chunkPath$ For Binary As #fhChunk
        buffer$ = Space$(LOF(fhChunk))
        If Len(buffer$) > 0 Then Get #fhChunk, 1, buffer$
        Close #fhChunk

        If Len(buffer$) > 0 And hasOutput Then Put #fhOut, , buffer$

        chunkListForEntry$(chunkListCount) = chunkPath$
        chunkListCount = chunkListCount + 1
    End If

    '--- End of entry (chunkIdx = totalChunks) ---
    If chunkIdx = totalChunks Then
        If hasOutput Then Close #fhOut
        hasOutput = 0

        If entrySuccess Then
            Print "  OK -> "; outputPath$
            entriesOK = entriesOK + 1

            '--- Per-entry chunk cleanup on success ---
            If doCleanup Then
                For ci = 0 To chunkListCount - 1
                    If _FileExists(chunkListForEntry$(ci)) Then
                        Kill chunkListForEntry$(ci)
                    End If
                Next ci
            End If
        Else
            Print "  FAILED -- output may be incomplete: "; outputPath$
            entriesFailed = entriesFailed + 1
        End If

        currentOrig$ = ""
    End If
Loop

Close #fhManifest

'--- Final folder cleanup on full success ---
If doCleanup And entriesFailed = 0 And chunksMissing = 0 Then
    If _FileExists(manifestPath$) Then Kill manifestPath$

    '--- rmdir silently fails if the folder still contains anything.
    '    That's the safe outcome -- unknown files stay put. ---
    Shell _Hide "rmdir " + Chr$(34) + _
          Left$(inputFolder$, Len(inputFolder$) - 1) + Chr$(34) + _
          " 2>nul"
End If

'--- Summary ---
Print
Print "z64unchunker: reassembled: "; entriesOK
Print "z64unchunker: failed:      "; entriesFailed
If chunksMissing > 0 Then Print "z64unchunker: missing chunks: "; chunksMissing

If chunksMissing > 0 Then System EXIT_MISSING
If entriesFailed > 0 Then System EXIT_ERROR
System EXIT_OK


' =====================================================================
' Helpers
' =====================================================================

Sub SplitByPipe (src$, result$(), partCount As Long)
    Dim i As Long
    Dim part$
    Dim idx As Long
    idx = 0
    part$ = ""
    For i = 1 To Len(src$)
        If Mid$(src$, i, 1) = "|" Then
            result$(idx) = part$
            idx = idx + 1
            part$ = ""
        Else
            part$ = part$ + Mid$(src$, i, 1)
        End If
    Next i
    result$(idx) = part$
    partCount = idx + 1
End Sub
