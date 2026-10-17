' z64extract.bas -- standalone archive extractor for QB64-PE 4.5.0
'
' Reads a .z64 archive (or a .png container) and writes each stored
' file into an output folder.  The output folder is created if it
' doesn't exist.
'
' Usage:
'   z64extract.exe <archive-file> <output-folder>
'
'   archive-file    Path to a .z64 or .png archive.  If the file
'                   ends in .png it's treated as a PNG container.
'                   Otherwise it's read as a raw .z64 stream.
'   output-folder   Where to write the extracted files.  Created
'                   if missing.  Trailing backslash optional.
'
' Exit codes:
'   0  All entries extracted successfully
'   1  Archive file didn't exist or wasn't a valid Z64 archive
'   2  Some entries were rejected (unsafe names) but at least one
'      valid entry was extracted, OR at least one file already
'      existed and was auto-renamed
'   3  Internal error (bad args, couldn't create output folder, etc.)
'
' Safety features carried over from v11+:
'   * Zip-slip guard: entries whose stored name contains path
'     separators, drive letters, ".." traversal, or control chars
'     are silently rejected.
'   * Overwrite protection: if an output file already exists, the
'     new entry is auto-renamed with a "(N)" suffix.  Nothing on
'     disk is ever silently replaced.
'
' Archive format (matches v9+, unchanged):
'   Long  magic       = &H50503635
'   Long  modeFlags     bit0 = compressed, bit1 = PNG container
'   Long  count
'   For each entry:
'     Long  nameLen
'     Bytes name        (bare filename only, no path)
'     Long  rawLen      original uncompressed size
'     Long  dataLen     stored bytes
'     Bytes data
'
' PNG container: full archive stream packed into 32-bit image pixel
' memory, prefixed with "Z64P" magic + 4-byte little-endian length.
_Title ("Z64 unpacker")
Option _Explicit
'$Dynamic

Const ARCHIVE_MAGIC = &H50503635

Const EXIT_OK = 0
Const EXIT_BADARCHIVE = 1
Const EXIT_PARTIAL = 2
Const EXIT_ERROR = 3

Dim archiveFile$
Dim outputFolder$
Dim usePNG As Integer: usePNG = 0
Dim i As Long

'--- Parse CLI ---
If _CommandCount < 2 Then
    Print "z64extract -- standalone archive extractor"
    Print
    Print "Usage: z64extract <archive-file> <output-folder>"
    Print
    Print "  archive-file    Path to a .z64 or .png archive."
    Print "  output-folder   Where to write the extracted files."
    Print
    Print "Exit codes: 0=ok, 1=bad archive, 2=partial, 3=error"
    System EXIT_ERROR
End If

archiveFile$ = Command$(1)
outputFolder$ = Command$(2)

'--- Detect PNG container by extension ---
If LCase$(Right$(archiveFile$, 4)) = ".png" Then usePNG = -1

'--- Make sure output folder ends with a backslash ---
If Len(outputFolder$) > 0 Then
    If Right$(outputFolder$, 1) <> "\" And Right$(outputFolder$, 1) <> "/" Then
        outputFolder$ = outputFolder$ + "\"
    End If
End If

'--- Check archive exists ---
If Not _FileExists(archiveFile$) Then
    Print "z64extract: archive not found: "; archiveFile$
    System EXIT_BADARCHIVE
End If

'--- Create output folder if missing ---
If Not _DirExists(outputFolder$) Then
    MkDir outputFolder$
    If Not _DirExists(outputFolder$) Then
        Print "z64extract: cannot create output folder: "; outputFolder$
        Print "  (drive may be read-only or the name is invalid)"
        System EXIT_ERROR
    End If
End If

Print "z64extract: reading "; archiveFile$
If usePNG Then Print "  (PNG container mode)"
Print "z64extract: output folder is "; outputFolder$
Print

'--- If PNG mode, decode pixels back into a raw .z64 stream on disk ---
Dim workingArchive$
Dim tempZ64$: tempZ64$ = "_z64extract_tmp.z64"

If usePNG Then
    Dim img As Long
    Dim archBytes$
    Dim fh As Long

    img = _LoadImage(archiveFile$, 32)
    If img >= -1 Then
        Print "z64extract: PNG failed to load."
        System EXIT_BADARCHIVE
    End If

    archBytes$ = ImageToBytes$(img)
    _FreeImage img

    If Len(archBytes$) = 0 Then
        Print "z64extract: not a Z64P PNG (missing header)."
        System EXIT_BADARCHIVE
    End If

    '--- Bounce through a temp .z64 so the same reader handles both cases ---
    fh = FreeFile: Open tempZ64$ For Output As #fh: Close #fh
    fh = FreeFile
    Open tempZ64$ For Binary As #fh
    Put #fh, 1, archBytes$

    Close #fh
    workingArchive$ = tempZ64$
Else
    workingArchive$ = archiveFile$
End If

'--- Read the archive ---
Dim vnames$(0), vdata$(0)
Dim vcount As Long, vmode As Long

ReadArchive workingArchive$, vnames$(), vdata$(), vcount, vmode

If usePNG Then Kill tempZ64$

If vcount < 0 Then
    Print "z64extract: bad archive (magic mismatch or corrupt count)."
    System EXIT_BADARCHIVE
End If

'--- Write each entry, applying safety guards ---
Dim written As Long: written = 0
Dim rejected As Long: rejected = 0
Dim renamed As Long: renamed = 0
Dim outPath$
Dim finalPath$
Dim fhOut As Long

Print "z64extract: archive has"; vcount; "entries"
If vmode And 1 Then Print "  (compressed)"
Print

For i = 0 To vcount - 1
    Print "  ["; LTrim$(Str$(i + 1)); "/"; LTrim$(Str$(vcount)); "] "; vnames$(i);

    If Not IsSafeName%(vnames$(i)) Then
        Print "  -- UNSAFE NAME (rejected)"
        rejected = rejected + 1
        _Continue
    End If

    outPath$ = outputFolder$ + vnames$(i)

    '--- Overwrite protection: if the file exists, pick a "(N)" variant ---
    If _FileExists(outPath$) Then
        finalPath$ = MakeUniquePath$(outputFolder$, vnames$(i))
        renamed = renamed + 1
        Print "  -> "; finalPath$;
    Else
        finalPath$ = outPath$
    End If

    fhOut = FreeFile: Open finalPath$ For Output As #fhOut: Close #fhOut
    fhOut = FreeFile
    Open finalPath$ For Binary As #fhOut
    If Len(vdata$(i)) > 0 Then Put #fhOut, 1, vdata$(i)
    Close #fhOut

    Print "  OK ("; LTrim$(Str$(Len(vdata$(i)))); " bytes)"
    written = written + 1
Next i

Print
Print "z64extract:"; written; "written,"; rejected; "rejected,"; renamed; "renamed"
Print "z64extract: output folder = "; outputFolder$

If rejected > 0 Or renamed > 0 Then System EXIT_PARTIAL

System EXIT_OK


'=======================================================================
'   Archive I/O (unchanged from v9)
'=======================================================================

Sub ReadArchive (path$, fnames$(), fdata$(), count As Long, modeFlags As Long)
    Dim magic As Long
    Dim nameLen As Long, rawLen As Long, dataLen As Long
    Dim stored$
    Dim i As Long, fh As Long

    fh = FreeFile
    Open path$ For Binary As #fh
    Get #fh, , magic
    If magic <> ARCHIVE_MAGIC Then
        Close #fh: count = -1: Exit Sub
    End If
    Get #fh, , modeFlags
    Get #fh, , count

    '--- Sanity check: reject nonsense counts from corrupt files ---
    If count < 0 Or count > 1000000 Then
        Close #fh: count = -1: Exit Sub
    End If

    ReDim fnames$(count - 1), fdata$(count - 1)

    For i = 0 To count - 1
        Get #fh, , nameLen
        fnames$(i) = Space$(nameLen)
        If nameLen > 0 Then Get #fh, , fnames$(i)

        Get #fh, , rawLen
        Get #fh, , dataLen
        stored$ = Space$(dataLen)
        If dataLen > 0 Then Get #fh, , stored$

        If (modeFlags And 1) And rawLen > 0 Then
            fdata$(i) = _Inflate$(stored$)
        Else
            fdata$(i) = stored$
        End If
    Next i
    Close #fh
End Sub


'=======================================================================
'   PNG container -- pixel memory decode
'=======================================================================

Function ImageToBytes$ (img As Long)
    Dim m As _MEM
    Dim header$
    Dim byteCount As Long
    Dim bytes$

    m = _MemImage(img)
    header$ = Space$(8)
    _MemGet m, m.OFFSET, header$

    If Left$(header$, 4) <> "Z64P" Then
        _MemFree m: ImageToBytes$ = "": Exit Function
    End If

    byteCount = Asc(Mid$(header$, 5, 1)) + _
                Asc(Mid$(header$, 6, 1)) * 256& + _
                Asc(Mid$(header$, 7, 1)) * 65536 + _
                Asc(Mid$(header$, 8, 1)) * 16777216

    If byteCount <= 0 Or byteCount > m.SIZE - 8 Then
        _MemFree m: ImageToBytes$ = "": Exit Function
    End If

    bytes$ = Space$(byteCount)
    _MemGet m, m.OFFSET + 8, bytes$
    _MemFree m
    ImageToBytes$ = bytes$
End Function


'=======================================================================
'   Safety helpers (zip-slip guard + auto-rename)
'=======================================================================

Function IsSafeName% (nname$)
    '--- Zip-slip guard.  Return true only if nname$ is a bare filename
    '    with no path separators, no drive colon, no ".." traversal,
    '    and no control characters.
    Dim i As Long, c As Integer
    If Len(nname$) = 0 Then Exit Function
    If InStr(nname$, "\") > 0 Then Exit Function
    If InStr(nname$, "/") > 0 Then Exit Function
    If InStr(nname$, ":") > 0 Then Exit Function
    If nname$ = "." Or nname$ = ".." Then Exit Function
    If Left$(nname$, 2) = ".." Then Exit Function
    For i = 1 To Len(nname$)
        c = Asc(Mid$(nname$, i, 1))
        If c < 32 Then Exit Function
    Next i
    IsSafeName% = -1
End Function


Function MakeUniquePath$ (dirPath$, baseName$)
    '--- Return dirPath$ + baseName$ (or a "(N)" variant) that does
    '    not yet exist on disk.  "readme.txt" -> "readme (1).txt".
    Dim n As Long, i As Long, dotPos As Long
    Dim stem$, ext$, candidate$

    dotPos = 0
    For i = Len(baseName$) To 1 Step -1
        If Mid$(baseName$, i, 1) = "." Then dotPos = i: Exit For
    Next i

    If dotPos > 0 Then
        stem$ = Left$(baseName$, dotPos - 1)
        ext$ = Mid$(baseName$, dotPos)
    Else
        stem$ = baseName$
        ext$ = ""
    End If

    n = 1
    Do
        candidate$ = dirPath$ + stem$ + " (" + LTrim$(Str$(n)) + ")" + ext$
        If Not _FileExists(candidate$) Then
            MakeUniquePath$ = candidate$
            Exit Function
        End If
        n = n + 1
        If n > 10000 Then
            MakeUniquePath$ = dirPath$ + stem$ + "_dup" + ext$
            Exit Function
        End If
    Loop
End Function
