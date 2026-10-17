'=============================================================
'  IniDemo.bas  --  Exercises MemHelpers + IniHelpers
'  QB64-PE 4.5.0
'=============================================================
Option _Explicit

'$Include:'MemHelpers.bi'
'$Include:'IniHelpers.bi'

Dim h As Long
Dim h2 As Long
Dim seed As String
Dim fileNum As Integer

_Title "INI / MemBuf Helper Demo"
Width 100, 40

'--- Build a starter file whose LAST section is not the one we
'--- will be writing into. The old SetIniVal appended new keys to
'--- the end of the file, which landed them under [Audio].
seed = "[Display]" + Chr$(13) + Chr$(10)
seed = seed + "Width=1280" + Chr$(13) + Chr$(10)
seed = seed + "; a comment with an = sign in it" + Chr$(13) + Chr$(10)
seed = seed + Chr$(13) + Chr$(10)
seed = seed + "[Audio]" + Chr$(13) + Chr$(10)
seed = seed + "Volume=80" + Chr$(13) + Chr$(10)

fileNum = FreeFile
Open "demo.ini" For Output As #fileNum
Print #fileNum, seed;
Close #fileNum

h = IniOpen&("demo.ini")
If h < 0 Then
    Print "Could not open demo.ini"
    End
End If

Print "--- loaded ("; MemBufLength&(h); "bytes, capacity"; MemBufCapacity&(h); ") ---"
Print IniText$(h)

'--- 1. Update an existing key.
IniSet h, "Display", "Width", "1920"

'--- 2. Add a NEW key to an EXISTING, non-final section.
IniSet h, "Display", "Height", "1080"
IniSetLong h, "Display", "Refresh", 144

'--- 3. Add a key to a section that does not exist yet.
IniSet h, "Input", "MouseSpeed", "2.5"

'--- 4. Delete a key, then a whole section.
IniSet h, "Audio", "Muted", "0"
IniDeleteKey h, "Audio", "Volume"

Print "--- after edits ---"
Print IniText$(h)

Print "Width      = "; IniGet$(h, "Display", "Width", "?")
Print "Height     = "; IniGet$(h, "Display", "Height", "?")
Print "Refresh    ="; IniGetLong&(h, "Display", "Refresh", -1)
Print "MouseSpeed = "; IniGet$(h, "Input", "MouseSpeed", "?")
Print "Missing    = "; IniGet$(h, "Display", "Nope", "<default used>")
Print "Has Volume ="; IniHas%(h, "Audio", "Volume")
Print "Has Muted  ="; IniHas%(h, "Audio", "Muted")

'--- The comment line containing '=' must not register as a key.
Print "Comment leaked as key ="; IniHas%(h, "Display", "; a comment with an ")

'--- 5. Re-opening the same path returns the same handle.
h2 = IniOpen&("demo.ini")
Print "Same handle on reopen ="; (h2 = h)

'--- 6. Save. No UpdateRegisteredIni call needed anywhere: the
'---    handle survived every reallocation above.
If IniSave%(h) Then Print "Saved to "; IniPathOf$(h) Else Print "Save failed"

IniDeleteSection h, "Input"
Print "--- after section delete (buffer only, not saved) ---"
Print IniText$(h)

IniClose h
MemBufFreeAll

Print
Print "Done. Press any key."
Sleep

'$Include:'MemHelpers.bm'
'$INCLUDE:'IniHelpers.bm'
