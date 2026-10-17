' ============================================================
' BookReader.bi
' Generic multi-book text loader/indexer for the bitmap-font
' text reader engine (originally built for "The Book of Matthew").
' Handles: book manifest, per-book text loading, chapter/verse
' (or chapter/paragraph, act/scene, etc.) indexing.
' Include with:  '$Include:'BookReader.bi'
' ============================================================

Type BRBookInfo
    Title As String * 64
    Author As String * 64
    FileName As String * 64
    UnitLabel As String * 16   ' e.g. "Chapter", "Act", "Canto"
    SubLabel As String * 16    ' e.g. "Verse", "Scene", "" if unused
    UnitCount As Integer       ' number of chapters/acts/etc
End Type

Type BRChapterBounds
    StartLine As Long
    EndLine As Long
    MaxSub As Integer          ' highest verse/subsection number in this unit
End Type

Dim Shared BRBookCount As Integer
Dim Shared BRBook(1 To 200) As BRBookInfo

Dim Shared BRLineCount As Long
Dim Shared BRSect(1 To 20000) As Integer      ' chapter/act number per line
Dim Shared BRSubSect(1 To 20000) As Integer   ' verse/scene number per line (0 if none)
Dim Shared BRLineText(1 To 20000) As String   ' raw text for the line, markup intact

Dim Shared BRUnitCount As Integer
Dim Shared BRIndex(1 To 500) As BRChapterBounds

Dim Shared BRCurrentTitle As String
Dim Shared BRCurrentUnitLabel As String
Dim Shared BRCurrentSubLabel As String

Declare Sub BRLoadManifest (path As String)
Declare Sub BRLoadBook (fileName As String)
Declare Function BRFindUnit% (sect As Integer)
Declare Sub BRGetBounds (sect As Integer, startLine As Long, endLine As Long)
Declare Function BRMaxSubOf% (sect As Integer)
