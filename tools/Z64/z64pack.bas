' z64pack.bas -- standalone archive packer for QB64-PE 4.5.0
'
' Reads a picks file (from z64picker or z64chunker), packs the listed
' files into a .z64 archive.  Optional deflate compression.  Optional
' embedded chunk manifest for reassembly by z64unchunker.
'
' This build:
'   * Streams entries one at a time -- peak RAM is a single chunk,
'     not the sum of the whole archive.
'   * Uses z64io.dll for zero-copy uncompressed payload writes.
'     z64io.dll must sit alongside z64pack.exe (or on the PATH).
'   * PNG container mode removed.
'
' Usage:
'   z64pack.exe <picks-file> <output-archive> [/compress]
'                                             [/manifest <manifest-file>]
'
' Picks file format:
'   Blank lines and lines starting with # are skipped.
'
'   Passthrough entry (whole file):
'     C:\path\to\file.ext
'
'   Chunk entry (partial file read):
'     C:\path\to\source | stored_name | byte_offset | length
'
' Exit codes:
'   0  Archive written successfully
'   1  Picks file didn't exist or was empty
'   2  One or more input files couldn't be read (partial archive still written)
'   3  Internal error (DLL failure, short write, etc.)
'
' Archive format (unchanged from v9):
'   Long  magic       = &H50503635
'   Long  modeFlags     bit0 = compressed  (bit1 = PNG, no longer produced)
'   Long  count
'   For each entry:
'     Long  nameLen
'     Bytes name
'     Long  rawLen
'     Long  dataLen
'     Bytes data

Option _Explicit
'$Dynamic
_Title "Z64 Packer (DLL)"

Const ARCHIVE_MAGIC = &H50503635
Const MANIFEST_STORED_NAME = ".z64manifest"

Const EXIT_OK = 0
Const EXIT_NOPICKS = 1
Const EXIT_PARTIAL = 2
Const EXIT_ERROR = 3

'--- Byte position where the entry count sits in the archive header.
'--- magic (4) + modeFlags (4) = 8 bytes, so count is at position 9.
Const COUNT_HDR_POS = 9

' =====================================================================
' z64io.dll linkage
' =====================================================================
Declare Library "z64io"
    Function z64_copy_range&& (src As String, _
                                ByVal offset As _Integer64, _
                                ByVal length As _Integer64, _
                                dst As String, _
                                ByVal doAppend As Long)
    Function z64_file_size&& (path As String)
End Declare

' =====================================================================
' Main
' =====================================================================
Dim picksFile$
Dim outputArchive$
Dim manifestFile$
Dim useCompress As Integer: useCompress = 0
Dim usePNG As Integer:      usePNG = 0
Dim i As Long

'--- Parse CLI ---
If _CommandCount < 2 Then
    Print "z64pack -- standalone archive packer (DLL build)"
    Print
    Print "Usage: z64pack <picks-file> <output-archive> [/compress]"
    Print "                                              [/manifest <manifest-file>]"
    Print
    Print "Exit codes: 0=ok, 1=no picks, 2=partial, 3=error"
    System EXIT_ERROR
End If

picksFile$ = Command$(1)
outputArchive$ = Command$(2)
manifestFile$ = ""

i = 3
Do While i <= _CommandCount
    Select Case LCase$(Command$(i))
        Case "/compress", "-compress", "--compress"
            useCompress = -1
        Case "/png", "-png", "--png"
            usePNG = -1
        Case "/manifest", "-manifest", "--manifest"
            If i + 1 <= _CommandCount Then
                manifestFile$ = Command$(i + 1)
                i = i + 1
            End If
    End Select
    i = i + 1
Loop

'--- Normalize output extension ---
If usePNG Then
    If LCase$(Right$(outputArchive$, 4)) = ".z64" Then
        outputArchive$ = Left$(outputArchive$, Len(outputArchive$) - 4)
    End If
    If LCase$(Right$(outputArchive$, 4)) <> ".png" Then
        outputArchive$ = outputArchive$ + ".png"
    End If
Else
    If LCase$(Right$(outputArchive$, 4)) = ".png" Then
        outputArchive$ = Left$(outputArchive$, Len(outputArchive$) - 4)
    End If
    If LCase$(Right$(outputArchive$, 4)) <> ".z64" Then
        outputArchive$ = outputArchive$ + ".z64"
    End If
End If

'--- Read picks file metadata (paths + offsets only, no payload) ---
Dim srcPaths$(0)
Dim storedNames$(0)
Dim offsets(0) As _Integer64
Dim lengths(0) As _Integer64
Dim entryCount As Long: entryCount = -1

Dim line$
Dim fh As Long

If Not _FileExists(picksFile$) Then
    Print "z64pack: picks file not found: "; picksFile$
    System EXIT_NOPICKS
End If

fh = FreeFile
Open picksFile$ For Input As #fh
Do While Not EOF(fh)
    Line Input #fh, line$
    line$ = _Trim$(line$)
    If Len(line$) = 0 Then _Continue
    If Left$(line$, 1) = "#" Then _Continue

    entryCount = entryCount + 1
    ReDim _Preserve srcPaths$(entryCount)
    ReDim _Preserve storedNames$(entryCount)
    ReDim _Preserve offsets(entryCount) As _Integer64
    ReDim _Preserve lengths(entryCount) As _Integer64

    If InStr(line$, "|") > 0 Then
        ParseChunkLine line$, srcPaths$(entryCount), storedNames$(entryCount), _
                       offsets(entryCount), lengths(entryCount)
    Else
        srcPaths$(entryCount) = line$
        storedNames$(entryCount) = ""
        offsets(entryCount) = -1
        lengths(entryCount) = -1
    End If
Loop
Close #fh

If entryCount < 0 Then
    Print "z64pack: picks file was empty: "; picksFile$
    System EXIT_NOPICKS
End If

Print "z64pack: streaming"; entryCount + 1; "entry(ies) from"; picksFile$
If Len(manifestFile$) > 0 Then
    Print "z64pack: embedding manifest: "; manifestFile$
End If
If useCompress Then Print "z64pack: /compress enabled"
If usePNG Then Print "z64pack: /png container mode enabled"
Print

'--- The streaming pack always writes to a real .z64 first.
'--- In PNG mode that file is a temp, embedded into the PNG at the end. ---
Dim streamTarget$
Dim tempZ64$: tempZ64$ = "_z64pack_tmp.z64"
If usePNG Then
    streamTarget$ = tempZ64$
Else
    streamTarget$ = outputArchive$
End If

'--- Open stream target, write header stub with placeholder count ---
Dim fhArch As Long
Dim archMagic As Long: archMagic = ARCHIVE_MAGIC
Dim modeFlags As Long: modeFlags = 0
Dim placeholderCount As Long: placeholderCount = 0

If useCompress Then modeFlags = modeFlags Or 1
If usePNG Then modeFlags = modeFlags Or 2

fhArch = FreeFile: Open streamTarget$ For Output As #fhArch: Close #fhArch
fhArch = FreeFile
Open streamTarget$ For Binary As #fhArch
Put #fhArch, , archMagic
Put #fhArch, , modeFlags
Put #fhArch, , placeholderCount

'--- Track unique stored names ---
Dim usedNames$(entryCount + 2)   ' room for entries + manifest
Dim usedCount As Long: usedCount = 0

'--- Per-entry state ---
Dim srcPath$, bareName$, uuniqueName$
Dim srcOffset As _Integer64, srcLength As _Integer64
Dim buf$, payload$
Dim nameLen As Long
Dim rawLen As Long, dataLen As Long
Dim writtenBytes As _Integer64
Dim fhSrc As Long

'--- Accounting ---
Dim nFailed As Long: nFailed = 0
Dim nRenamed As Long: nRenamed = 0
Dim finalCount As Long: finalCount = 0
Dim totalRawBytes As _Integer64: totalRawBytes = 0

' =====================================================================
' Single-pass entry loop -- read, compress (optional), write, free.
' =====================================================================
For i = 0 To entryCount
    Print "  ["; LTrim$(Str$(i + 1)); "/"; LTrim$(Str$(entryCount + 1)); "] ";

    srcPath$ = srcPaths$(i)

    If offsets(i) < 0 Then
        Print srcPath$;
        srcOffset = 0
        srcLength = z64_file_size(srcPath$ + Chr$(0))
        bareName$ = BareFilename$(srcPath$)
    Else
        Print storedNames$(i); "  <-  "; srcPath$; _
              " ["; LTrim$(Str$(offsets(i))); " +"; LTrim$(Str$(lengths(i))); "]";
        srcOffset = offsets(i)
        srcLength = lengths(i)
        bareName$ = storedNames$(i)
    End If

    If srcLength < 0 Then
        Print "  -- NOT FOUND (skipped)"
        nFailed = nFailed + 1
        _Continue
    End If

    '--- Unique stored name ---
    uuniqueName$ = UniqueName$(bareName$, usedNames$(), usedCount)
    If uuniqueName$ <> bareName$ Then nRenamed = nRenamed + 1
    usedNames$(usedCount) = uuniqueName$
    usedCount = usedCount + 1

    '--- Write name header ---
    nameLen = Len(uuniqueName$)
    rawLen = srcLength

    Put #fhArch, , nameLen
    Put #fhArch, , uuniqueName$
    Put #fhArch, , rawLen

    If useCompress And rawLen > 0 Then
        '--- Compressed path: load, deflate, write, free ---
        fhSrc = FreeFile
        Open srcPath$ For Binary As #fhSrc
        buf$ = Space$(srcLength)
        Get #fhSrc, srcOffset + 1, buf$
        Close #fhSrc

        payload$ = _Deflate$(buf$)
        buf$ = ""                          ' free raw immediately
        dataLen = Len(payload$)
        Put #fhArch, , dataLen
        If dataLen > 0 Then Put #fhArch, , payload$
        payload$ = ""                      ' free compressed immediately

        Print "  OK ("; LTrim$(Str$(rawLen)); " -> "; LTrim$(Str$(dataLen)); " bytes)"
    Else
        '--- Uncompressed streaming path via DLL ---
        dataLen = rawLen
        Put #fhArch, , dataLen
        Close #fhArch

        If dataLen > 0 Then
            writtenBytes = z64_copy_range(srcPath$ + Chr$(0), srcOffset, _
                                          dataLen, streamTarget$ + Chr$(0), -1)
            If writtenBytes <> dataLen Then
                Print "  -- FAIL: DLL short write ("; _
                      LTrim$(Str$(writtenBytes)); "/"; LTrim$(Str$(dataLen)); ")"
                Print "z64pack: archive corrupted, aborting"
                System EXIT_ERROR
            End If
        End If

        '--- Reopen archive and seek to EOF for next header ---
        fhArch = FreeFile
        Open streamTarget$ For Binary As #fhArch
        Seek #fhArch, LOF(fhArch) + 1

        Print "  OK ("; LTrim$(Str$(rawLen)); " bytes streamed)"
    End If

    totalRawBytes = totalRawBytes + rawLen
    finalCount = finalCount + 1
Next i

' =====================================================================
' Manifest embedding (as one more entry after the loop)
' =====================================================================
If Len(manifestFile$) > 0 Then
    Print
    Print "  [manifest] "; manifestFile$;

    If Not _FileExists(manifestFile$) Then
        Print "  -- NOT FOUND (skipped)"
        nFailed = nFailed + 1
    Else
        srcLength = z64_file_size(manifestFile$ + Chr$(0))
        srcOffset = 0
        srcPath$ = manifestFile$
        bareName$ = MANIFEST_STORED_NAME

        uuniqueName$ = UniqueName$(bareName$, usedNames$(), usedCount)
        usedNames$(usedCount) = uuniqueName$
        usedCount = usedCount + 1

        nameLen = Len(uuniqueName$)
        rawLen = srcLength
        Put #fhArch, , nameLen
        Put #fhArch, , uuniqueName$
        Put #fhArch, , rawLen

        If useCompress And rawLen > 0 Then
            fhSrc = FreeFile
            Open srcPath$ For Binary As #fhSrc
            buf$ = Space$(srcLength)
            Get #fhSrc, 1, buf$
            Close #fhSrc

            payload$ = _Deflate$(buf$)
            buf$ = ""
            dataLen = Len(payload$)
            Put #fhArch, , dataLen
            If dataLen > 0 Then Put #fhArch, , payload$
            payload$ = ""
        Else
            dataLen = rawLen
            Put #fhArch, , dataLen
            Close #fhArch

            If dataLen > 0 Then
                writtenBytes = z64_copy_range(srcPath$ + Chr$(0), 0, _
                                              dataLen, streamTarget$ + Chr$(0), -1)
                If writtenBytes <> dataLen Then
                    Print "  -- FAIL: DLL short write on manifest"
                    System EXIT_ERROR
                End If
            End If

            fhArch = FreeFile
            Open streamTarget$ For Binary As #fhArch
            Seek #fhArch, LOF(fhArch) + 1
        End If

        totalRawBytes = totalRawBytes + rawLen
        finalCount = finalCount + 1
        Print "  OK ("; LTrim$(Str$(rawLen)); " bytes)"
    End If
End If

' =====================================================================
' Patch entry count into header, close, embed to PNG if requested
' =====================================================================
Put #fhArch, COUNT_HDR_POS, finalCount
Close #fhArch

If usePNG Then
    Print
    Print "z64pack: embedding "; streamTarget$; " into "; outputArchive$
    EmbedZ64IntoPNG streamTarget$, outputArchive$
    Kill streamTarget$
End If

Dim archBytes As _Integer64
archBytes = z64_file_size(outputArchive$ + Chr$(0))

Print
Print "z64pack: wrote"; finalCount; "entries,"; nFailed; "failed,"; nRenamed; "renamed"
Print "z64pack: raw total ="; totalRawBytes; "bytes"
Print "z64pack: archive =  "; archBytes; "bytes"

If useCompress And totalRawBytes > 0 Then
    Dim pct As Double
    pct = 100# * archBytes / totalRawBytes
    Print "z64pack: compression ratio "; LTrim$(Str$(Int(pct * 10) / 10)); "% of raw"
End If

If nFailed > 0 Then System EXIT_PARTIAL
System EXIT_OK


' =====================================================================
' Helpers
' =====================================================================

Sub ParseChunkLine (line$, srcPath$, storedName$, offset As _Integer64, length As _Integer64)
    '--- Parse "source_path | stored_name | offset | length"
    Dim p1 As Long, p2 As Long, p3 As Long

    p1 = InStr(line$, "|")
    p2 = InStr(p1 + 1, line$, "|")
    p3 = InStr(p2 + 1, line$, "|")

    If p1 = 0 Or p2 = 0 Or p3 = 0 Then
        srcPath$ = _Trim$(line$)
        storedName$ = ""
        offset = -1
        length = -1
        Exit Sub
    End If

    srcPath$ = _Trim$(Left$(line$, p1 - 1))
    storedName$ = _Trim$(Mid$(line$, p1 + 1, p2 - p1 - 1))
    offset = Val(_Trim$(Mid$(line$, p2 + 1, p3 - p2 - 1)))
    length = Val(_Trim$(Mid$(line$, p3 + 1)))
End Sub


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


Function UniqueName$ (baseName$, existing$(), existCount As Long)
    Dim n As Long, i As Long, dotPos As Long
    Dim stem$, ext$, candidate$

    If Not NameInList%(baseName$, existing$(), existCount) Then
        UniqueName$ = baseName$
        Exit Function
    End If

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
        candidate$ = stem$ + " (" + LTrim$(Str$(n)) + ")" + ext$
        If Not NameInList%(candidate$, existing$(), existCount) Then
            UniqueName$ = candidate$
            Exit Function
        End If
        n = n + 1
        If n > 10000 Then
            UniqueName$ = stem$ + "_dup" + ext$
            Exit Function
        End If
    Loop
End Function


Function NameInList% (nname$, existing$(), existCount As Long)
    Dim i As Long
    For i = 0 To existCount - 1
        If LCase$(existing$(i)) = LCase$(nname$) Then
            NameInList% = -1
            Exit Function
        End If
    Next i
End Function


Sub EmbedZ64IntoPNG (z64Path$, pngPath$)
    '--- Load the whole .z64 stream into memory, allocate a 32-bit image
    '--- big enough to hold it, write "Z64P" + 4-byte little-endian length
    '--- + payload into pixel memory, save the image as PNG.
    '--- Peak RAM in this sub = one full copy of z64Path$.
    Dim fh As Long
    Dim archBytes$
    Dim byteCount As _Integer64
    Dim totalNeeded As _Integer64
    Dim pixelsNeeded As _Integer64
    Dim side As Long
    Dim img As Long
    Dim m As _MEM
    Dim header$

    byteCount = z64_file_size(z64Path$ + Chr$(0))
    If byteCount < 0 Then
        Print "  ERROR: cannot measure "; z64Path$
        Exit Sub
    End If

    fh = FreeFile
    Open z64Path$ For Binary As #fh
    archBytes$ = Space$(byteCount)
    If byteCount > 0 Then Get #fh, 1, archBytes$
    Close #fh

    '--- 8 bytes for the Z64P + length header, then the archive stream ---
    totalNeeded = 8 + byteCount
    pixelsNeeded = (totalNeeded + 3) \ 4       ' 4 bytes per 32-bit pixel
    side = Int(Sqr(pixelsNeeded)) + 1
    If side < 4 Then side = 4

    img = _NewImage(side, side, 32)
    m = _MemImage(img)

    header$ = "Z64P" + _
              Chr$(byteCount And &HFF) + _
              Chr$((byteCount \ 256&) And &HFF) + _
              Chr$((byteCount \ 65536&) And &HFF) + _
              Chr$((byteCount \ 16777216&) And &HFF)

    _MemPut m, m.OFFSET, header$
    If byteCount > 0 Then _MemPut m, m.OFFSET + 8, archBytes$

    _MemFree m
    _SaveImage pngPath$, img
    _FreeImage img
End Sub
