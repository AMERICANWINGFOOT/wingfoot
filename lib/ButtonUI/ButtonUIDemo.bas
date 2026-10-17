Option _Explicit
'$Include:'ButtonUI.bi'
'=======================================================================
' ButtonUIDemo.bas - showcase for the QB64Starter Button & Mouse helper.
' Keep ButtonUI.bi, ButtonUI.bm and this file in the same folder.
'=======================================================================

Screen _NewImage(640, 400, 32)
_Title "QB64Starter Button & Mouse Helper"

MouseInit ' load default theme

Dim counter As Integer
counter = 0

Do
    _Limit 60
    PollMouse

    Cls , _RGB32(28, 30, 36)

    Color _RGB32(230, 232, 240)
    _PrintString (200, 40), "Counter demo   value =" + Str$(counter)
    _PrintString (150, 330), "Hover, press, and click the buttons."

    If Button%(200, 90, 100, 40, "- 1") Then counter = counter - 1
    If Button%(340, 90, 100, 40, "+ 1") Then counter = counter + 1

    If Button%(200, 150, 240, 40, "Reset to zero") Then counter = 0

    ' Disabled unless the counter is non-zero, to show the disabled state.
    If ButtonEx%(200, 210, 240, 40, "Clear (needs value)", counter <> 0) Then counter = 0

    If Button%(200, 270, 240, 40, "Quit") Then Exit Do

    _Display
Loop

System

'$Include:'ButtonUI.bm'
