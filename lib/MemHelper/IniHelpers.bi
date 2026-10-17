'=============================================================
'  IniHelpers.bi  --  INI parsing on top of MemHelpers
'  Part of the QB64Starter toolkit.
'
'  Requires MemHelpers.bi / MemHelpers.bm.
'
'  A buffer handle doubles as the registry index, so the old
'  manager block (path + offset + size records) is replaced by
'  a single parallel string array.
'=============================================================

Dim Shared iniPath(0 To MEMBUF_MAX - 1) As String

Declare Function IniOpen& (filePath As String)
Declare Function IniFind& (filePath As String)
Declare Function IniSave% (h As Long)
Declare Function IniSaveAs% (h As Long, filePath As String)
Declare Function IniPathOf$ (h As Long)
Declare Function IniGet$ (h As Long, sect As String, kname As String, defaultVal As String)
Declare Function IniGetLong& (h As Long, sect As String, kname As String, defaultVal As Long)
Declare Function IniHas% (h As Long, sect As String, kname As String)
Declare Function IniText$ (h As Long)

Declare Sub IniClose (h As Long)
Declare Sub IniSet (h As Long, sect As String, kname As String, vvalue As String)
Declare Sub IniSetLong (h As Long, sect As String, kname As String, vvalue As Long)
Declare Sub IniDeleteKey (h As Long, sect As String, kname As String)
Declare Sub IniDeleteSection (h As Long, sect As String)

' internal
Declare Function IniIsComment% (s As String)
Declare Function IniNeedsEol% (h As Long)
Declare Function IniIsHeaderFor% (clean As String, sect As String)
