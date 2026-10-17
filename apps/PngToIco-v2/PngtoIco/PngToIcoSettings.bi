'=============================================================
'  PngToIcoSettings.bi  --  Persistence for PngToIco.bas
'  Requires MemHelpers + IniHelpers.
'=============================================================

Const ICO_SIZECOUNT = 6

Declare Function IcoSizeAt% (idx As Integer)
Declare Sub IcoSettingsLoad (h As Long, sizeFlag() As Integer, lastIn As String, lastOut As String)
Declare Sub IcoSettingsSave (h As Long, sizeFlag() As Integer, lastIn As String, lastOut As String)
