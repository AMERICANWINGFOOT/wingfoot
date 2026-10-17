'=======================================================================
'  PngToIcoSettings.bi  --  Settings persistence for PngToIco.bas
'  Requires MemHelpers + IniHelpers. Operates on the shared sizeList()
'  and sizeOn() arrays declared in PngToIco.bas.
'=======================================================================

Dim Shared icoCfg As Long '        INI buffer handle
Dim Shared lastInPath As String '  last source image picked
Dim Shared lastOutPath As String ' last .ico written

Declare Sub IcoSettingsLoad ()
Declare Sub IcoSettingsSave ()
