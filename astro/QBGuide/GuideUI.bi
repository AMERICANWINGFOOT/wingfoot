'=====================================================================
' GuideUI.bi - QBGuide small immediate-mode UI + settings file
'=====================================================================

Dim Shared MX As Long, MY As Long, MDown As Long, MClick As Long, MPrev As Long
Dim Shared UIKey As String
Dim Shared IniCount As Long
ReDim Shared IniK(1 To 100) As String
ReDim Shared IniV(1 To 100) As String

Const C_BG = &HFF101418
Const C_PANEL = &HFF1A2028
Const C_BTN = &HFF2C3440
Const C_BTNHI = &HFF3C4858
Const C_BTNON = &HFF1F6F3F
Const C_TEXT = &HFFD8DEE6
Const C_DIM = &HFF8090A0
Const C_RA = &HFF4FA3FF
Const C_DEC = &HFFFF5A5A
Const C_GOOD = &HFF40D070
Const C_WARN = &HFFFFC040
Const C_GRID = &HFF303844
