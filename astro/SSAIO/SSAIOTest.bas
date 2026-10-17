' SSAIOTest.bas - QB64-PE test for the Orion StarShoot All-in-One
' (QHY5L-II underneath) through libssaio.so, the QHY SDK shim.
' Needs libssaio.so and libssaio.h in the same folder as this .bas.
'
' Keys: G = grab frame   + / - = exposure   [ / ] = gain
'       S = save PNG     Esc = quit
' Frames are raw bayer shown as grey, so a fine checker pattern is normal.

Option _Explicit

Declare Library "./libssaio"
    Function ssaio_init& ()
    Function ssaio_open& (ByVal index As Long)
    Function ssaio_model& (ByVal buf As _Offset, ByVal buflen As Long)
    Function ssaio_width& ()
    Function ssaio_height& ()
    Function ssaio_pixel_um# ()
    Function ssaio_is_color& ()
    Function ssaio_set_exposure_ms& (ByVal ms As Double)
    Function ssaio_set_gain& (ByVal gain As Double)
    Function ssaio_grab& (ByVal buf As _Offset, ByVal buflen As Long)
    Sub ssaio_close ()
End Declare

Const SW = 640
Const SH = 560

Dim n As Long, rc As Long, w As Long, h As Long
Dim bufLen As Long, got As Long, bpp As Long
Dim model As String, k As String, msg As String
Dim expoMs As Double, gainVal As Double
Dim img As Long, i As Long, v As Long, zp As Long
Dim m As _MEM

Screen _NewImage(SW, SH, 32)
_Title "SSAIO Test"

n = ssaio_init
Print "Cameras found:"; n
If n < 1 Then
    Print "No QHY camera found. Check lsusb shows 1618:0921."
    ssaio_close
    Sleep
    System
End If

rc = ssaio_open(0)
If rc <> 0 Then
    Print "Open failed, code"; rc
    ssaio_close
    Sleep
    System
End If

model = Space$(64)
rc = ssaio_model(_Offset(model), Len(model))
zp = InStr(model, Chr$(0))
If zp > 0 Then model = Left$(model, zp - 1)
model = _Trim$(model)

w = ssaio_width
h = ssaio_height
Print "Model:"; model
Print "Size :"; w; "x"; h; "  pixel"; ssaio_pixel_um; "um  colour id"; ssaio_is_color

' room for 16-bit in case the SDK ignores 8-bit mode
bufLen = w * h * 2
Dim buf(0 To bufLen - 1) As _Unsigned _Byte

img = _NewImage(w, h, 32)
expoMs = 50
gainVal = 20
rc = ssaio_set_exposure_ms(expoMs)
rc = ssaio_set_gain(gainVal)
msg = "Press G to grab"

Do
    k = InKey$
    Select Case UCase$(k)
        Case "G"
            got = ssaio_grab(_Offset(buf(0)), bufLen)
            If got < 0 Then
                msg = "Grab failed, code" + Str$(got)
            Else
                bpp = got \ (w * h)
                If bpp < 1 Then bpp = 1
                m = _MemImage(img)
                For i = 0 To w * h - 1
                    ' little-endian: high byte is last
                    v = buf(i * bpp + bpp - 1)
                    _MemPut m, m.OFFSET + i * 4, _RGB32(v, v, v) As _UNSIGNED LONG
                Next i
                _MemFree m
                msg = "Got" + Str$(got) + " bytes," + Str$(bpp) + " byte/pixel"
            End If
        Case "+", "="
            expoMs = expoMs * 2
            If expoMs > 10000 Then expoMs = 10000
            rc = ssaio_set_exposure_ms(expoMs)
            msg = "Exposure" + Str$(expoMs) + " ms"
        Case "-", "_"
            expoMs = expoMs / 2
            If expoMs < 0.1 Then expoMs = 0.1
            rc = ssaio_set_exposure_ms(expoMs)
            msg = "Exposure" + Str$(expoMs) + " ms"
        Case "]"
            gainVal = gainVal + 5
            If gainVal > 100 Then gainVal = 100
            rc = ssaio_set_gain(gainVal)
            msg = "Gain" + Str$(gainVal)
        Case "["
            gainVal = gainVal - 5
            If gainVal < 0 Then gainVal = 0
            rc = ssaio_set_gain(gainVal)
            msg = "Gain" + Str$(gainVal)
        Case "S"
            _SaveImage "ssaio_frame.png", img
            msg = "Saved ssaio_frame.png"
        Case Chr$(27)
            Exit Do
    End Select

    Cls
    _PutImage (0, 0)-(SW - 1, 479), img
    _PrintString (8, 488), model + "  " + LTrim$(Str$(w)) + "x" + LTrim$(Str$(h))
    _PrintString (8, 506), "Exp" + Str$(expoMs) + " ms   Gain" + Str$(gainVal)
    _PrintString (8, 524), msg
    _PrintString (8, 542), "G grab  +/- exp  [/] gain  S save  Esc quit"
    _Display
    _Limit 30
Loop

ssaio_close
_FreeImage img
System
