'=======================================================================
' ButtonUI.bi  -  QB64Starter Button & Mouse Helper (declarations)
'
' Add an Include metacommand for ButtonUI.bi at the TOP of your
' program, and one for ButtonUI.bm at the BOTTOM. (Written as words
' on purpose -- the real metacommand is comment-formatted, so QB64
' would act on it even from inside these remarks.)
'
' Immediate-mode buttons: one call per button, each frame, draws itself
' and returns -1 the frame it is clicked. No button IDs or arrays to
' manage. Requires a 32-bit graphics Screen.
'=======================================================================

Type MouseState
    mx As Integer '     current pointer X (pixels)
    my As Integer '     current pointer Y (pixels)
    held As Integer '   left button currently down   (-1/0)
    prevHeld As Integer ' left button state last frame (-1/0)
    clicked As Integer ' -1 on the frame the button is released (a click)
    pressX As Integer ' pointer X captured when the button went down
    pressY As Integer ' pointer Y captured when the button went down
    wheel As Integer '  net wheel movement this frame (+down / -up)
End Type

Dim Shared gMouse As MouseState

' --- Button theme (set by MouseInit, override any time) ---
Dim Shared uiFace As _Unsigned Long '     button face, normal
Dim Shared uiFaceHover As _Unsigned Long ' button face, pointer over it
Dim Shared uiFaceDown As _Unsigned Long '  button face, pressed
Dim Shared uiText As _Unsigned Long '     caption color
Dim Shared uiLight As _Unsigned Long '     top/left bevel highlight
Dim Shared uiDark As _Unsigned Long '      bottom/right bevel shadow
Dim Shared uiDisFace As _Unsigned Long '   disabled face
Dim Shared uiDisText As _Unsigned Long '   disabled caption
