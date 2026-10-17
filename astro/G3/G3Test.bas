'==================================================================
'  G3Test.bas  -  does this computer talk to the Orion StarShoot G3?
'  QB64-PE 4.6  +  libssg3.so (build it with build_g3.sh)
'
'  Put the cap on, plug in the G3, close Ekos/indiserver, then run.
'  It scans USB, opens the camera, reads the sensor temperature,
'  takes one exposure, downloads it and shows min/max/mean.
'  A believable range (not all 0, not all 65535) = the chain works.
'
'  Saves G3_test.raw (752x582 16-bit, host order) and G3_test.png
'  (auto-stretched view) next to the program.
'==================================================================
Option _Explicit

Declare Dynamic Library "ssg3"
    Function ssg3_version& ()
    Function ssg3_last_error& (ByVal buf As _Offset, ByVal blen As Long)
    Function ssg3_count& ()
    Function ssg3_usb_pid& (ByVal idx As Long)
    Function ssg3_driver_says_color& (ByVal idx As Long)
    Function ssg3_open& (ByVal idx As Long)
    Sub ssg3_close ()
    Function ssg3_width& ()
    Function ssg3_height& ()
    Function ssg3_frame_bytes& ()
    Function ssg3_set_gain& (ByVal g As Long)
    Function ssg3_set_offset& (ByVal o As Long)
    Function ssg3_start_exposure& (ByVal ms As Long)
    Function ssg3_exposure_done& ()
    Function ssg3_download& (ByVal buf As _Offset, ByVal blen As Long)
    Function ssg3_temp_x10& (tx10 As Long)
    Function ssg3_cooler& (ByVal onFlag As Long, ByVal tx10 As Long)
    Function ssg3_cooler_power& (pct As Long)
End Declare

Const EXPOSURE_MS = 1000

Dim n As Long, r As Long, i As Long
Dim w As Long, h As Long, nb As Long, np As Long
Dim tx As Long, pw As Long
Dim t0 As Double
Dim exeDir As String

Screen _NewImage(800, 640, 32)
_Title "G3 Test"
exeDir = _StartDir$
If Right$(exeDir, 1) <> "/" Then exeDir = exeDir + "/"

Print "libssg3 version"; ssg3_version&
Print

'---- 1. find the camera
n = ssg3_count&
If n < 0 Then
    Print "USB scan failed: "; LastErr$
    Done
ElseIf n = 0 Then
    Print "No G3 found on USB."
    Print
    Print "Check:  lsusb | grep -i 07ee   (should show 07ee:0502)"
    Print "        camera power / cable, try a rear USB port"
    Print "        udev rule installed, camera unplugged + replugged"
    Done
End If

For i = 0 To n - 1
    Print "Camera"; i; " USB id 07ee:"; LCase$(Right$("000" + Hex$(ssg3_usb_pid&(i)), 4));
    If ssg3_driver_says_color&(i) Then Print "  (driver guesses COLOR)" Else Print "  (driver guesses MONO)"
Next i
Print "  (the color/mono guess is not reliable - both G3s may report 0502)"
Print

'---- 2. open it
r = ssg3_open&(0)
If r <> 0 Then
    Print "Open failed: "; LastErr$
    If r = -13 Or r = -1 Then
        Print "Permission problem - udev rule missing? (see README)"
    ElseIf r = -16 Then
        Print "Camera busy - close Ekos / indiserver first."
    End If
    Done
End If

w = ssg3_width&: h = ssg3_height&: nb = ssg3_frame_bytes&
np = w * h
Print "Opened.  Frame"; w; "x"; h; " ("; nb; "bytes)"

If ssg3_temp_x10&(tx) = 0 Then
    Print "Sensor temperature:"; tx / 10; "C"
Else
    Print "Temperature read failed: "; LastErr$
End If
If ssg3_cooler_power&(pw) = 0 Then Print "Cooler power:"; pw; "%"
Print

'---- 3. one exposure
Dim px(0 To np - 1) As _Unsigned Integer

r = ssg3_set_gain&(185)
r = ssg3_set_offset&(127)

Print "Exposing"; EXPOSURE_MS; "ms ..."
r = ssg3_start_exposure&(EXPOSURE_MS)
If r <> 0 Then
    Print "Start exposure failed: "; LastErr$
    ssg3_close
    Done
End If

t0 = Timer(.001)
Do
    _Limit 20
Loop Until ssg3_exposure_done&

Print "Downloading ..."
r = ssg3_download&(_Offset(px(0)), nb)
If r <> 0 Then
    Print "Download failed: "; LastErr$
    ssg3_close
    Done
End If
Print "Got frame in"; Int((Timer(.001) - t0) * 1000); "ms"

ssg3_close

'---- 4. stats
Dim mn As Long, mx As Long, v As Long
Dim sum As Double
mn = 65535: mx = 0
For i = 0 To np - 1
    v = px(i)
    If v < mn Then mn = v
    If v > mx Then mx = v
    sum = sum + v
Next i
Print
Print "Pixel min:"; mn; "  max:"; mx; "  mean:"; Int(sum / np)
If mx = 0 Then
    Print "All zeros - camera answered but sent no image data."
ElseIf mn = 65535 Then
    Print "All 65535 - saturated or bad readout."
Else
    Print "Looks like a real frame - this computer works with the G3."
End If

'---- 5. save raw + show stretched view
Dim ff As Long
ff = FreeFile
Open exeDir + "G3_test.raw" For Binary As #ff
Put #ff, 1, px()
Close #ff

Dim img As Long, m As _MEM, g As Long, rng As Long
img = _NewImage(w, h, 32)
m = _MemImage(img)
rng = mx - mn: If rng < 1 Then rng = 1
For i = 0 To np - 1
    g = ((px(i) - mn) * 255&) \ rng
    _MemPut m, m.OFFSET + i * 4, _RGB32(g, g, g) As _UNSIGNED LONG
Next i
_MemFree m
_SaveImage exeDir + "G3_test.png", img

Print "Saved G3_test.raw and G3_test.png"
Print
Print "Press any key to view the frame."
Sleep

Cls
Print "G3 frame"; w; "x"; h; "  min"; mn; " max"; mx; " mean"; Int(sum / np); "  (auto-stretched)"
_PutImage (24, 32), img
_FreeImage img
Done

'------------------------------------------------------------------
Sub Done
    Print
    Print "Press any key to exit."
    Sleep
    System
End Sub

Function LastErr$
    Dim b As String, z As Long, rr As Long
    b = Space$(256)
    rr = ssg3_last_error&(_Offset(b), 256)
    z = InStr(b, Chr$(0))
    If z > 0 Then b = Left$(b, z - 1)
    LastErr$ = RTrim$(b)
End Function
