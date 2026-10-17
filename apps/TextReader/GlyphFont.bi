' ============================================================
' GlyphFont.bi
' Custom alpha-blended bitmap font renderer (11x18 cell glyphs,
' 255-character set). Fully independent of book/text content.
' Include with:  '$Include:'GlyphFont.bi'
' ============================================================

Const GFLW = 11
Const GFLH = 18

Dim Shared GFLetter(255, GFLW, GFLH) As Integer

Declare Sub GFLoadFont ()
Declare Sub GFPrintText (txt As String, tleft As Integer, ttop As Integer, tmode As Integer)
