' ============================================================================
' ButtonUI.bi  -  Tiny immediate-mode button + mouse toolkit (declarations)
'
' Include near the TOP of any program that wants buttons:
'     '$INCLUDE:'ButtonUI.bi'
' and the matching implementation at the BOTTOM:
'     '$INCLUDE:'ButtonUI.bm'
'
' "Immediate mode" means there's no button objects to manage: you call
' Button%(x, y, w, h, "Caption") every frame, and it returns -1 on the frame
' it's clicked. Draw + hit-test happen in that one call. Needs a 32-bit Screen.
' ============================================================================

Type MouseState
    x As Long
    y As Long
    down As Integer       ' left button currently held
    prevDown As Integer   ' held on the previous frame
    clicked As Integer    ' -1 on the frame the button is RELEASED (a click)
End Type

Dim Shared gMouse As MouseState

' --- Theme colours (set by MouseInit, override afterwards if you like) ---
Dim Shared uiFace As _Unsigned Long      ' button face, idle
Dim Shared uiFaceHi As _Unsigned Long    ' button face, hovered
Dim Shared uiText As _Unsigned Long      ' caption + label colour
Dim Shared uiEdge As _Unsigned Long      ' button border
