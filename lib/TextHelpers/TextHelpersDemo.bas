'=========================================================
' TextHelpersDemo.bas - QB64Starter Text Helpers demo
'
' Self-contained: the library lives in TextHelpers.bm and
' is pulled in by the $Include at the bottom, so this pair
' can be posted/shared as-is. Keep both files in the same
' folder and run this one.
'
' What it shows:
'   CenterText / CenterTextRow / CenterTextMid
'   RightText, ShadowText, CenterShadow, OutlineText
'   PrintWrapped& (font-aware word wrap with return cursor)
'
' All helpers measure with _PrintWidth/_FontHeight, so they
' keep working if you _LoadFont a TTF - even variable-width.
'=========================================================
Option _Explicit

Screen _NewImage(800, 600, 32)
_Title "QB64Starter Text Helpers"

_PrintMode _KeepBackground
Dim i As Long, nextY As Long

' Gradient background so the transparent _KeepBackground
' printing in the effect helpers is visible.
For i = 0 To 599
    Line (0, i)-(799, i), _RGB32(14 + i \ 12, 12, 46 - i \ 16)
Next

Color _RGB32(255, 200, 80)
CenterShadow 16, "Q B 6 4 S T A R T E R   T E X T   H E L P E R S", _RGB32(255, 200, 80), _RGB32(0, 0, 0)

Color _RGB32(200, 220, 255)
CenterText 64, "CenterText: horizontally centered at any pixel row"
CenterTextRow 6, "CenterTextRow: centered on text row 6 (rows, not pixels)"

Color _RGB32(255, 255, 255)
RightText _Width - 12, 128, "RightText: right-aligned, ends 12px from the edge"

ShadowText 48, 168, "ShadowText: drop shadow, offset scales with font size", _RGB32(255, 255, 255), _RGB32(0, 0, 0)

OutlineText 48, 200, "OutlineText: 8-direction outline, readable anywhere", _RGB32(255, 240, 120), _RGB32(110, 30, 0)

Color _RGB32(160, 255, 170)
CenterTextMid "CenterTextMid: dead center, both axes"

Color _RGB32(220, 220, 220)
_PrintString (48, 380), "PrintWrapped& - font-aware word wrap into a 340px column:"
Color _RGB32(255, 255, 255)
nextY = PrintWrapped&(48, 404, 340, "This paragraph is wrapped by measuring each candidate line with _PrintWidth, so it stays correct with proportional TTF fonts where Len(s$) * 8 falls apart." + Chr$(10) + "Embedded line feeds force a break, like this one did, and the function returns the y of the next free line so paragraphs chain cleanly.")
Color _RGB32(140, 200, 140)
_PrintString (48, nextY + 4), "(returned cursor y:" + Str$(nextY) + " - this line was placed with it)"

Color _RGB32(150, 150, 170)
CenterText 560, "Press any key to exit"

_Display
Do
    _Limit 30
Loop Until _KeyHit > 0
System

'$Include:'TextHelpers.bm'
