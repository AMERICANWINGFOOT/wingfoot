' TychoConv.bas - Tycho-2 text catalog to StarCat binary (.cat)
' QB64-PE 4.5.0, console app
'
' Usage:  ./TychoConv [tyc2.dat] [suppl_1.dat] [tycho2.cat]
'   Defaults are those three names in the current folder.
'   suppl_1.dat is optional (adds ~17,600 bright Hipparcos stars,
'   including Sirius, Vega, etc., that the main catalog leaves out).
'
' Input columns follow the CDS I/259 ReadMe (fixed 206-char records,
' fields separated by "|"). Main catalog uses the J2000 mean position;
' stars flagged "X" (no mean position) fall back to the observed position.
' Supplement positions are J1991.25 and are moved to J2000 by proper motion.
' Magnitude: V = VT - 0.090 * (BT - VT) when both exist, else VT, else BT.
'
' Output layout is described in StarCat.bi. Stars are sorted brightest first
' with a counting sort on 0.01-mag bins, which is O(n) and stable.

$Console:Only
Option _Explicit

'$Include:'StarCat.bi'

Const MAG_LO = -2
Const BIN_W = 0.01
Const NBINS = 2001
Const GROW_BY = 500000

ReDim Shared sRA(1 To GROW_BY) As Double
ReDim Shared sDE(1 To GROW_BY) As Double
ReDim Shared sMag(1 To GROW_BY) As Single
Dim Shared nStars As Long
Dim Shared capStars As Long
capStars = GROW_BY

Dim mainFile$, supFile$, outFile$
mainFile$ = "tyc2.dat"
supFile$ = "suppl_1.dat"
outFile$ = "tycho2.cat"
If _CommandCount >= 1 Then mainFile$ = Command$(1)
If _CommandCount >= 2 Then supFile$ = Command$(2)
If _CommandCount >= 3 Then outFile$ = Command$(3)

Dim t0#, nMain&, nSup&, nObs&, nSkip&
t0# = Timer

' ---------------- main catalog ----------------
If Not _FileExists(mainFile$) Then
    Print "Main catalog not found: "; mainFile$
    Print "Build it with:  zcat tyc2.dat.*.gz > tyc2.dat"
    System
End If

Print "Reading "; mainFile$
ReadMain mainFile$, nMain&, nObs&, nSkip&
Print Using "  ########, stars  (########, observed-position fallback, ######, skipped)"; nMain&; nObs&; nSkip&

' ---------------- supplement 1 ----------------
If _FileExists(supFile$) Then
    Print "Reading "; supFile$
    ReadSupplement supFile$, nSup&, nSkip&
    Print Using "  ########, stars  (######, skipped)"; nSup&; nSkip&
Else
    Print "No supplement ("; supFile$; ") - very bright stars will be missing"
End If

If nStars = 0 Then
    Print "No stars read - check the input file."
    System
End If

' ---------------- sort and write ----------------
Print "Sorting"; nStars; "stars by magnitude"
WriteCatalog outFile$
Print Using "Done in ####.# s"; Timer - t0#

' ---------------- read back and verify ----------------
VerifyCatalog outFile$
System


' Reads tyc2.dat (main catalog) line by line.
Sub ReadMain (fileName$, nRead&, nObs&, nSkip&)
    Dim fh&, lt$, raDeg#, deDeg#, m!
    nRead& = 0: nObs& = 0: nSkip& = 0
    fh& = FreeFile
    Open fileName$ For Input As #fh&
    Do Until EOF(fh&)
        Line Input #fh&, lt$
        If Len(lt$) >= 187 Then
            If Mid$(lt$, 14, 1) = "X" Then
                raDeg# = Val(Mid$(lt$, 153, 12))
                deDeg# = Val(Mid$(lt$, 166, 12))
                nObs& = nObs& + 1
            Else
                raDeg# = Val(Mid$(lt$, 16, 12))
                deDeg# = Val(Mid$(lt$, 29, 12))
            End If
            m! = TycMag!(Mid$(lt$, 111, 6), Mid$(lt$, 124, 6))
            If m! < 90 Then
                AddStar raDeg#, deDeg#, m!
                nRead& = nRead& + 1
                If nRead& Mod 250000 = 0 Then Print Using "  ########,"; nRead&
            Else
                nSkip& = nSkip& + 1
            End If
        ElseIf Len(lt$) > 0 Then
            nSkip& = nSkip& + 1
        End If
    Loop
    Close #fh&
End Sub


' Reads suppl_1.dat (positions at J1991.25, moved to J2000 when PM exists).
Sub ReadSupplement (fileName$, nRead&, nSkip&)
    Dim fh&, lt$, raDeg#, deDeg#, m!, pmR$, pmD$, dt#, cosd#
    nRead& = 0: nSkip& = 0
    dt# = 2000# - 1991.25#
    fh& = FreeFile
    Open fileName$ For Input As #fh&
    Do Until EOF(fh&)
        Line Input #fh&, lt$
        If Len(lt$) >= 109 Then
            raDeg# = Val(Mid$(lt$, 16, 12))
            deDeg# = Val(Mid$(lt$, 29, 12))
            pmR$ = _Trim$(Mid$(lt$, 42, 7))
            pmD$ = _Trim$(Mid$(lt$, 50, 7))
            If Len(pmR$) > 0 And Len(pmD$) > 0 Then
                cosd# = Cos(deDeg# * _Pi / 180#)
                deDeg# = deDeg# + Val(pmD$) * dt# / 3600000#
                If cosd# > 0.000001 Then raDeg# = raDeg# + Val(pmR$) * dt# / 3600000# / cosd#
            End If
            m! = TycMag!(Mid$(lt$, 84, 6), Mid$(lt$, 97, 6))
            If m! < 90 Then
                AddStar raDeg#, deDeg#, m!
                nRead& = nRead& + 1
            Else
                nSkip& = nSkip& + 1
            End If
        ElseIf Len(lt$) > 0 Then
            nSkip& = nSkip& + 1
        End If
    Loop
    Close #fh&
End Sub


' Approximate Johnson V from Tycho BT/VT text fields; 99 when both blank.
Function TycMag! (btText As String, vtText As String)
    Dim bt$, vt$, b!, v!
    bt$ = _Trim$(btText)
    vt$ = _Trim$(vtText)
    If Len(bt$) > 0 And Len(vt$) > 0 Then
        b! = Val(bt$)
        v! = Val(vt$)
        TycMag! = v! - 0.09 * (b! - v!)
    ElseIf Len(vt$) > 0 Then
        TycMag! = Val(vt$)
    ElseIf Len(bt$) > 0 Then
        TycMag! = Val(bt$)
    Else
        TycMag! = 99
    End If
End Function


' Appends one star, growing the arrays in GROW_BY chunks.
Sub AddStar (raIn#, deIn#, magIn!)
    Dim raDeg#, deDeg#
    If nStars = capStars Then
        capStars = capStars + GROW_BY
        ReDim _Preserve sRA(1 To capStars) As Double
        ReDim _Preserve sDE(1 To capStars) As Double
        ReDim _Preserve sMag(1 To capStars) As Single
    End If
    raDeg# = raIn#
    Do While raDeg# < 0#: raDeg# = raDeg# + 360#: Loop
    Do While raDeg# >= 360#: raDeg# = raDeg# - 360#: Loop
    deDeg# = deIn#
    If deDeg# > 90# Then deDeg# = 90#
    If deDeg# < -90# Then deDeg# = -90#
    nStars = nStars + 1
    sRA(nStars) = raDeg#
    sDE(nStars) = deDeg#
    sMag(nStars) = magIn!
End Sub


' Magnitude to sort bin, clamped to 0..NBINS-1.
Function MagBin& (m!)
    Dim b&
    b& = Int((m! - MAG_LO) / BIN_W)
    If b& < 0 Then b& = 0
    If b& > NBINS - 1 Then b& = NBINS - 1
    MagBin& = b&
End Function


' Counting sort by magnitude bin, then one array PUT.
Sub WriteCatalog (fileName$)
    Dim cnt(0 To NBINS - 1) As Long
    Dim nextPos(0 To NBINS - 1) As Long
    Dim i&, b&, p&, oh&, mn!, mx!
    Dim hdr As StarCatHeader

    For i& = 1 To nStars
        b& = MagBin&(sMag(i&))
        cnt(b&) = cnt(b&) + 1
    Next i&
    p& = 1
    For b& = 0 To NBINS - 1
        nextPos(b&) = p&
        p& = p& + cnt(b&)
    Next b&

    ReDim outRec(1 To nStars) As StarRec
    mn! = 999: mx! = -999
    For i& = 1 To nStars
        b& = MagBin&(sMag(i&))
        p& = nextPos(b&)
        nextPos(b&) = p& + 1
        outRec(p&).ra = sRA(i&)
        outRec(p&).dec = sDE(i&)
        outRec(p&).mag = sMag(i&)
        If sMag(i&) < mn! Then mn! = sMag(i&)
        If sMag(i&) > mx! Then mx! = sMag(i&)
    Next i&

    hdr.magic = STARCAT_MAGIC
    hdr.version = STARCAT_VERSION
    hdr.count = nStars
    hdr.epoch = 2000#
    hdr.magMin = mn!
    hdr.magMax = mx!
    hdr.reserved = String$(32, 0)

    If _FileExists(fileName$) Then Kill fileName$
    oh& = FreeFile
    Open fileName$ For Binary As #oh&
    Put #oh&, 1, hdr
    Put #oh&, , outRec()
    Close #oh&
    Print "Wrote "; fileName$; " ("; _Trim$(Str$(64 + 20 * nStars)); " bytes)"
End Sub


' Re-opens the file, checks the header and size, prints a short summary.
Sub VerifyCatalog (fileName$)
    Dim hdr As StarCatHeader
    Dim rec As StarRec
    Dim fh&, i&, k&, expectLen&&, bandMag!(1 To 6), bandCnt&(1 To 6)
    bandMag!(1) = 6: bandMag!(2) = 8: bandMag!(3) = 9
    bandMag!(4) = 10: bandMag!(5) = 11: bandMag!(6) = 12

    fh& = FreeFile
    Open fileName$ For Binary As #fh&
    Get #fh&, 1, hdr
    Print
    Print "Verify "; fileName$
    If hdr.magic <> STARCAT_MAGIC Then
        Print "  BAD MAGIC - file is not a StarCat file"
        Close #fh&
        Exit Sub
    End If
    expectLen&& = 64 + 20 * CLng(hdr.count)
    Print "  version"; hdr.version; "  stars"; hdr.count; "  epoch"; hdr.epoch
    Print Using "  magnitude range ##.## to ##.##"; hdr.magMin; hdr.magMax
    If LOF(fh&) = expectLen&& Then
        Print "  file size OK"
    Else
        Print "  FILE SIZE MISMATCH: "; LOF(fh&); " vs expected "; expectLen&&
    End If

    Print "  brightest 10:"
    Print "      RA (deg)     Dec (deg)    V"
    For i& = 1 To hdr.count
        Get #fh&, , rec
        If i& <= 10 Then Print Using "    ###.######  ###.######  ##.##"; rec.ra; rec.dec; rec.mag
        For k& = 1 To 6
            If rec.mag <= bandMag!(k&) Then bandCnt&(k&) = bandCnt&(k&) + 1
        Next k&
    Next i&
    Print "  stars at or brighter than:"
    For k& = 1 To 6
        Print Using "    V ##   ########,"; bandMag!(k&); bandCnt&(k&)
    Next k&
    Close #fh&
End Sub
