'=======================================================================
'  XyzView.bas  --  XYZ point-cloud viewer built on W3
'  QB64-PE 4.5.0
'
'  Loads a whitespace-delimited XYZ file, recentres and scales it to fit
'  the view, then orbits a camera around it.
'
'  Arrows orbit    W/S dolly    D depth cue    +/- point size
'  L load another file    ESC quit
'
'  Writes sample.xyz on first run so it has something to show.
'=======================================================================
Option _Explicit

'$Include:'W3.bi'

Const SCRW = 900, SCRH = 640
Const FITSIZE = 4 '   longest dimension of the cloud after W3Fit

Dim Shared cBg As _Unsigned Long
Dim cloud As Long, axes As Long
Dim orbit As Single, elev As Single, dist As Single
Dim nPts As Integer, k As Long
Dim curFile As String, pick As String

Screen _NewImage(SCRW, SCRH, 32)
_Title "XYZ point cloud viewer"
cBg = _RGB32(14, 16, 22)

W3Init
W3SetViewport SCRW, SCRH
W3SetLens 60, 0.05, 200
W3SetDepthCue -1, cBg
W3SetCueAmount 0.8
W3SetPointSize 2

MakeSample '                       only if sample.xyz is missing
curFile = "liberty.xyz"

cloud = W3New&
nPts = W3LoadXyz%(cloud, curFile, 1)
W3Fit cloud, FITSIZE

axes = W3New&
W3Axes axes, FITSIZE * 0.6

orbit = 0.5: elev = 2: dist = 9

Do
    _Limit 60
    k = _KeyHit

    If _KeyDown(19200) Then orbit = orbit - 0.02
    If _KeyDown(19712) Then orbit = orbit + 0.02
    If _KeyDown(18432) Then elev = elev + 0.05
    If _KeyDown(20480) Then elev = elev - 0.05
    If _KeyDown(119) Or _KeyDown(87) Then dist = dist - 0.05
    If _KeyDown(115) Or _KeyDown(83) Then dist = dist + 0.05

    If k = 100 Or k = 68 Then w3cue = Not w3cue
    If k = 43 Or k = 61 Then W3SetPointSize w3psize + 1
    If k = 45 Then W3SetPointSize w3psize - 1
    If k = 108 Or k = 76 Then
        pick = _OpenFileDialog$("Open an XYZ file", "", "*.xyz|*.txt", "Point data", 0)
        If pick <> "" Then
            nPts = W3LoadXyz%(cloud, pick, 1)
            If nPts > 0 Then
                W3Fit cloud, FITSIZE
                curFile = pick
            End If
        End If
    End If
    If k = 27 Then Exit Do

    If dist < 0.5 Then dist = 0.5
    If dist > 60 Then dist = 60

    W3LookAt Sin(orbit) * dist, elev, Cos(orbit) * dist, 0, 0, 0

    Cls , cBg
    W3Draw axes, _RGB32(90, 80, 60)
    W3DrawPoints cloud, _RGB32(140, 230, 255)

    Color _RGB32(150, 160, 180)
    _PrintString (16, 16), "arrows orbit   W/S dolly   D cue   +/- size   L load   ESC quit"
    Color _RGB32(200, 210, 225)
    _PrintString (16, 38), BaseName$(curFile) + "   " + _Trim$(Str$(nPts)) + " points   size" + Str$(w3psize)
    If nPts = 0 Then
        Color _RGB32(226, 170, 110)
        _PrintString (16, 60), "Nothing loaded - press L to pick a file."
    End If

    _Display
Loop

W3FreeAll
System


'--- Write the sample rows out once so the demo runs standalone.
Sub MakeSample
    Dim f As Integer

    If _FileExists("sample.xyz") Then Exit Sub

    f = FreeFile
    Open "sample.xyz" For Output As #f
    Print #f, "45.249802 -4.072477 249.938019"
    Print #f, "46.167801 -4.690477 251.622009"
    Print #f, "45.709801 -5.458477 250.244019"
    Print #f, "44.631798 -5.042478 244.962006"
    Print #f, "44.783794 -7.342478 245.269989"
    Print #f, "43.861801 -6.578478 234.522018"
    Print #f, "43.709797 -4.426477 234.673996"
    Print #f, "43.247795 -2.580477 245.269989"
    Print #f, "42.785797 -1.814478 234.673996"
    Print #f, "41.869797 -1.814478 245.730011"
    Print #f, "40.175797 -0.584478 236.058014"
    Close #f
End Sub


Function BaseName$ (p As String)
    Dim i As Integer, ch As String
    For i = Len(p) To 1 Step -1
        ch = Mid$(p, i, 1)
        If ch = "\" Or ch = "/" Then BaseName$ = Mid$(p, i + 1): Exit Function
    Next i
    BaseName$ = p
End Function

'$Include:'W3.bm'
