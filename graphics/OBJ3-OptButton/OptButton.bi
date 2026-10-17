'=======================================================================
' OptButton.bi  -  Option (toggle) & Radio button helper (declarations)
'
' A small companion to ButtonUI.  Same immediate-mode style, same
' theme colors, same gMouse state -- one call per widget, per frame.
'
' INCLUDE ORDER (metacommands written as words on purpose):
'   TOP of your .bas, AFTER ButtonUI.bi:
'       Include ButtonUI.bi
'       Include OptButton.bi        <-- this file
'       Include OBJ3.bi
'   BOTTOM of your .bas, AFTER ButtonUI.bm:
'       Include ButtonUI.bm
'       Include OptButton.bm
'       Include OBJ3.bm
'
' Depends on ButtonUI for: gMouse, PtInRect%, DrawBevel, and the
' uiXXXX theme colors.  Requires a 32-bit graphics Screen.
'
'   OptionButton% (x, y, w, h, caption$, state)
'        An on/off toggle.  Pass in the current state, draw + return
'        the (possibly flipped) state:
'            flip = OptionButton%(324, 726, 92, 32, "Flip wind", flip)
'
'   RadioButton%  (x, y, w, h, caption$, myVal, curVal)
'        One choice in a group.  Draws engaged when curVal = myVal,
'        and returns myVal on the frame it is clicked (else curVal):
'            sel = RadioButton%(x, y, w, h, "Back", 1, sel)
'=======================================================================

Declare Function OptionButton% (x As Integer, y As Integer, w As Integer, h As Integer, caption As String, state As Integer)
Declare Function RadioButton% (x As Integer, y As Integer, w As Integer, h As Integer, caption As String, myVal As Integer, curVal As Integer)
