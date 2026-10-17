Rem FANCY ZWO EFW FILTER WHEEL CONTROLLER
Rem Requires EFW_filter.dll from ZWO - place in same folder as .exe
Rem Setup files saved/loaded automatically using the wheel model name.
Rem   e.g.  EFW_ZWO_EFW_8x125.cfg  is created next to the .exe on first run.
_Title "ZWO EFW Filter Wheel Controller"
$ExeIcon:'./Icon\Icon.ico'
Declare Dynamic Library "EFW_filter"
    Function EFWGetNum& ()
    Function EFWGetID& (ByVal index As Integer, ByVal ID As _Offset)
    Function EFWGetProperty& (ByVal ID As Integer, ByVal pInfo As _Offset)
    Function EFWOpen& (ByVal ID As Integer)
    Function EFWGetPosition& (ByVal ID As Integer, ByVal pPosi As _Offset)
    Function EFWSetPosition& (ByVal ID As Integer, ByVal Position As Integer)
    Function EFWClose& (ByVal ID As Integer)
End Declare

Type EFWINFO
    ID As Long
    Name As String * 64
    slotNum As Long
End Type

Type clocate
    x As Integer
    y As Integer
End Type

Dim Shared filtername$(10)
Dim Shared flocation As Integer
Dim Shared circlel(10) As clocate
Dim Shared info As EFWINFO
Dim Shared screenhandle&
Dim Shared fsize As Integer
Dim Shared WheelCX As Integer
Dim Shared WheelCY As Integer
Dim Shared WheelR As Integer
Dim Shared SW As Integer, SH As Integer
Dim Shared StatusMsg As String
Dim Shared wheelkey As String
Dim Shared cfgfile As String

Rem --- Color palette (deep space astronomy theme) ---
Dim Shared col_bg&, col_wheel&, col_hub&, col_rim&
Dim Shared col_text&, col_dim&, col_accent&, col_close&
Dim Shared filtercolor&(10)

col_bg& = _RGB32(8, 10, 18)
col_wheel& = _RGB32(22, 28, 42)
col_hub& = _RGB32(42, 50, 68)
col_rim& = _RGB32(55, 72, 110)
col_text& = _RGB32(210, 225, 255)
col_dim& = _RGB32(85, 98, 128)
col_accent& = _RGB32(0, 190, 255)
col_close& = _RGB32(170, 38, 38)

Rem --- Default per-filter colors (used only when no .cfg file exists yet) ---
filtercolor&(1) = _RGB32(220, 220, 220) ' Lum   white/grey
filtercolor&(2) = _RGB32(220, 40, 40) ' Red
filtercolor&(3) = _RGB32(40, 200, 60) ' Green
filtercolor&(4) = _RGB32(40, 100, 235) ' Blue
filtercolor&(5) = _RGB32(210, 38, 38) ' Ha    deep red
filtercolor&(6) = _RGB32(28, 195, 185) ' OIII  teal
filtercolor&(7) = _RGB32(165, 38, 205) ' SII   violet
filtercolor&(8) = _RGB32(55, 55, 60) ' Dark  near-black

Rem --- Default filter names (used only when no .cfg file exists yet) ---
Data "Lum","Red","Grn","Blu","Ha","OIII","SII","Dark"

Dim xi As Integer
For xi = 1 To 8
    Read filtername$(xi)
Next xi

Rem --- Boot sequence ---
openwheel ' open device, get properties, load .cfg
initscreen ' create window and compute wheel geometry
showconfig ' config page: review names, optionally edit, then launch
getfilter ' query current wheel position from hardware
StatusMsg = "Ready - " + RTrim$(info.Name) + " - click a slot or ESC to exit"
drawUI ' render main wheel screen
main ' event loop
closefilter

Rem ================================================================
Sub main ()
    Do
        Do While _MouseInput
            If _MouseButton(1) < 0 Then checklocation _MouseX, _MouseY
        Loop
        _Limit 60
    Loop Until InKey$ = Chr$(27)
End Sub

Rem ================================================================
Sub checklocation (mx As Integer, my As Integer)
    Dim l As Integer, a As Integer, b As Integer
    For l = 1 To info.slotNum
        a = circlel(l).x - mx
        b = circlel(l).y - my
        If (a * a + b * b) < (fsize * fsize) Then
            If l <> flocation Then setfilter l
            Exit Sub
        End If
    Next l
    a = circlel(9).x - mx
    b = circlel(9).y - my
    If (a * a + b * b) < (fsize * fsize) Then closefilter
End Sub

Rem ================================================================
Sub setfilter (f As Integer)
    Dim oldloc As Integer
    oldloc = flocation

    drawslot oldloc, 0
    StatusMsg = "Moving to " + filtername$(f) + "  (Slot " + LTrim$(Str$(f)) + ")..."
    drawstatus

    errortrap EFWSetPosition(info.ID, f - 1)
    Do
        Sleep 1
    Loop While EFWSetPosition(info.ID, f - 1)

    getfilter

    drawslot flocation, 1
    StatusMsg = "Active:  " + filtername$(flocation) + "   [Slot " + LTrim$(Str$(flocation)) + " of " + LTrim$(Str$(info.slotNum)) + "]"
    drawstatus
End Sub

Rem ================================================================
Sub getfilter ()
    Do
        Sleep 1
    Loop While EFWGetPosition(info.ID, _Offset(flocation))
    flocation = flocation + 1 ' SDK returns 0-based; convert to 1-based
End Sub

Rem ================================================================
Rem  Builds a filename-safe key from the wheel model name.
Rem  Example:  "ZWO EFW 8x1.25"  ->  "ZWO_EFW_8x1_25"
Function makeWheelKey$ ()
    Dim raw As String, result As String
    Dim i As Integer, c As String
    raw = RTrim$(info.Name)
    result = ""
    For i = 1 To Len(raw)
        c = Mid$(raw, i, 1)
        If (c >= "A" And c <= "Z") Or (c >= "a" And c <= "z") Or (c >= "0" And c <= "9") Then
            result = result + c
        Else
            If Right$(result, 1) <> "_" Then result = result + "_"
        End If
    Next i
    If Right$(result, 1) = "_" Then result = Left$(result, Len(result) - 1)
    makeWheelKey = result
End Function

Rem ================================================================
Sub buildCfgPath ()
    cfgfile = _StartDir$ + "/EFW_" + wheelkey + ".cfg"
End Sub

Rem ================================================================
Sub saveSetup ()
    Dim f As Integer, slot As Integer
    Dim r&, g&, b&
    f = FreeFile
    Open cfgfile For Output As #f
    Print #f, "# ZWO EFW setup for: " + RTrim$(info.Name) + "  (key: " + wheelkey + ")"
    Print #f, "# Slots: " + LTrim$(Str$(info.slotNum))
    For slot = 1 To info.slotNum
        r& = _Red32(filtercolor&(slot))
        g& = _Green32(filtercolor&(slot))
        b& = _Blue32(filtercolor&(slot))
        Print #f, filtername$(slot) + " " + LTrim$(Str$(r&)) + " " + LTrim$(Str$(g&)) + " " + LTrim$(Str$(b&))
    Next slot
    Close #f
End Sub

Rem ================================================================
Function loadSetup& ()
    Dim f As Integer, slot As Integer
    Dim lline As String, tok(4) As String, ti As Integer, p As Integer

    If Not _FileExists(cfgfile) Then loadSetup = 0: Exit Function

    f = FreeFile
    Open cfgfile For Input As #f
    slot = 0
    Do While Not EOF(f) And slot < info.slotNum
        Line Input #f, lline
        lline = LTrim$(RTrim$(lline))
        If Left$(lline, 1) = "#" Or Len(lline) = 0 Then GoTo NextLine

        slot = slot + 1
        For ti = 1 To 4: tok(ti) = "": Next ti
        ti = 1
        For p = 1 To Len(lline)
            If Mid$(lline, p, 1) = " " Then
                ti = ti + 1
                If ti > 4 Then Exit For
            Else
                tok(ti) = tok(ti) + Mid$(lline, p, 1)
            End If
        Next p

        filtername$(slot) = tok(1)
        If Val(tok(2)) > 0 Or Val(tok(3)) > 0 Or Val(tok(4)) > 0 Then
            filtercolor&(slot) = _RGB32(Val(tok(2)), Val(tok(3)), Val(tok(4)))
        End If
        NextLine:
    Loop
    Close #f
    loadSetup = 1
End Function

Rem ================================================================
Sub openwheel ()
    Dim index As Integer
    index = EFWGetNum - 1
    If index < 0 Then
        Print "NO EFW DEVICE FOUND - Check USB connection"
        Sleep 3: End
    End If
    errortrap EFWGetID(index, _Offset(info.ID))
    errortrap EFWOpen(info.ID)
    errortrap EFWGetProperty(info.ID, _Offset(info))

    wheelkey = makeWheelKey$
    buildCfgPath

    If loadSetup Then
        ' .cfg found and loaded — names and colors ready
    Else
        ' First run — save defaults loaded from Data statement
        saveSetup
    End If
    Rem getfilter and drawUI are called AFTER the config screen
End Sub

Rem ================================================================
Rem  Creates the screen and computes wheel geometry.
Rem  Called once before showconfig so the config page can draw on it.
Sub initscreen ()
    Dim f As Integer, angle As Double, pi As Double, slotR As Integer
    SW = 520: SH = 460
    pi = 3.14159265358979#

    screenhandle& = _NewImage(SW, SH, 32)
    Screen screenhandle&

    WheelCX = SW \ 2
    WheelCY = (SH + 34) \ 2
    WheelR = 155
    fsize = 25

    slotR = WheelR - fsize - 8
    For f = 1 To info.slotNum
        angle = (2.0# * pi * (f - 1) / info.slotNum) - pi / 2.0#
        circlel(f).x = WheelCX + CInt(slotR * Cos(angle))
        circlel(f).y = WheelCY + CInt(slotR * Sin(angle))
    Next f

    circlel(9).x = SW - 38
    circlel(9).y = SH - 58
End Sub

Rem ================================================================
Rem  Config screen shown on every boot before the wheel UI.
Rem  View mode  : LAUNCH goes straight to the wheel (no save).
Rem              Click any slot or EDIT to enter edit mode.
Rem  Edit mode  : type to rename selected slot, Enter moves to next.
Rem              CANCEL returns to view, SAVE + LAUNCH saves and continues.
Sub showconfig ()
    Dim editing As Integer, selslot As Integer, done As Integer
    Dim k As String, sy As Integer, l As Integer, mx As Integer, my As Integer

    editing = 0
    selslot = 1
    done = 0

    drawconfig editing, selslot

    Do
        ' --- Mouse ---
        Do While _MouseInput
            If _MouseButton(1) < 0 Then
                mx = _MouseX: my = _MouseY

                ' Slot rows  (y = 65 + (slot-1)*40, height 38)
                For l = 1 To info.slotNum
                    sy = 65 + (l - 1) * 40
                    If mx >= 0 And mx <= SW And my >= sy And my < sy + 38 Then
                        selslot = l
                        editing = 1
                        drawconfig editing, selslot
                    End If
                Next l

                ' EDIT button (view mode)  x 80-190, y 393-425
                If Not editing Then
                    If mx >= 80 And mx <= 190 And my >= 393 And my <= 425 Then
                        editing = 1
                        drawconfig editing, selslot
                    End If
                End If

                ' CANCEL button (edit mode)  x 80-190, y 393-425
                If editing Then
                    If mx >= 80 And mx <= 190 And my >= 393 And my <= 425 Then
                        editing = 0
                        drawconfig editing, selslot
                    End If
                End If

                ' LAUNCH / SAVE + LAUNCH  x 280-440, y 393-425
                If mx >= 280 And mx <= 440 And my >= 393 And my <= 425 Then
                    If editing Then saveSetup
                    done = 1
                End If
            End If
        Loop

        ' --- Keyboard (edit mode only) ---
        If editing Then
            k = InKey$
            If Len(k) = 1 Then
                Select Case Asc(k)
                    Case 8 ' Backspace
                        If Len(filtername$(selslot)) > 0 Then
                            filtername$(selslot) = Left$(filtername$(selslot), Len(filtername$(selslot)) - 1)
                        End If
                    Case 13 ' Enter - move to next slot
                        selslot = (selslot Mod info.slotNum) + 1
                    Case 27 ' Escape - exit edit mode
                        editing = 0
                    Case 32 To 126 ' Printable ASCII, max 8 chars
                        If Len(filtername$(selslot)) < 8 Then
                            filtername$(selslot) = filtername$(selslot) + UCase$(k)
                        End If
                End Select
                drawconfig editing, selslot
            End If
        Else
            If InKey$ = Chr$(27) Then done = 1 ' ESC in view mode = launch
        End If

        _Limit 60
    Loop Until done
End Sub

Rem ================================================================
Sub drawconfig (editing As Integer, selslot As Integer)
    Dim slot As Integer, sy As Integer, r As Integer
    Dim fc&

    ' Background and stars
    Line (0, 0)-(SW - 1, SH - 1), col_bg&, BF
    drawstars

    ' Title bar (reuse existing sub)
    drawtitlebar

    ' Header bar
    Line (0, 35)-(SW - 1, 63), _RGB32(12, 15, 26), BF
    Line (0, 63)-(SW - 1, 63), col_rim&
    If editing Then
        Color col_accent&
        _PrintString (12, 44), "Click slot, type to rename, Enter = next, ESC = cancel"
    Else
        Color col_text&
        _PrintString (12, 44), "Filter Setup - " + RTrim$(info.Name) + " (" + LTrim$(Str$(info.slotNum)) + " slots)"
    End If

    ' Slot rows
    For slot = 1 To info.slotNum
        sy = 65 + (slot - 1) * 40
        fc& = filtercolor&(slot)

        ' Highlight selected row in edit mode
        If editing And slot = selslot Then
            Line (0, sy)-(SW - 1, sy + 37), _RGB32(18, 25, 42), BF
            Line (0, sy)-(SW - 1, sy), col_accent&
            Line (0, sy + 37)-(SW - 1, sy + 37), col_dim&
        End If

        ' Color swatch
        For r = 13 To 0 Step -1
            Circle (30, sy + 19), r, fc&
        Next r
        Circle (30, sy + 19), 13, col_rim&

        ' Slot number
        Color col_dim&
        _PrintString (52, sy + 13), LTrim$(Str$(slot))

        ' Filter name
        If editing And slot = selslot Then
            Line (70, sy + 8)-(280, sy + 30), _RGB32(20, 28, 50), BF
            Line (70, sy + 8)-(280, sy + 30), col_accent&, B
            Color col_accent&
            _PrintString (75, sy + 13), filtername$(slot) + Chr$(219) ' block cursor
        ElseIf editing Then
            Color col_dim&
            _PrintString (75, sy + 13), filtername$(slot)
        Else
            Color col_text&
            _PrintString (75, sy + 13), filtername$(slot)
        End If
    Next slot

    ' Separator above buttons
    Line (0, 388)-(SW - 1, 388), col_rim&

    ' Left button: EDIT (view mode) or CANCEL (edit mode)
    If editing Then
        Line (80, 395)-(190, 425), _RGB32(100, 28, 28), BF
        Line (80, 395)-(190, 425), _RGB32(170, 50, 50), B
        Color _RGB32(255, 190, 190)
        _PrintString (100, 403), "CANCEL"
    Else
        Line (80, 395)-(190, 425), _RGB32(30, 50, 90), BF
        Line (80, 395)-(190, 425), col_rim&, B
        Color col_text&
        _PrintString (112, 403), "EDIT"
    End If

    ' Right button: LAUNCH (view mode) or SAVE + LAUNCH (edit mode)
    If editing Then
        Line (280, 395)-(440, 425), _RGB32(22, 88, 38), BF
        Line (280, 395)-(440, 425), _RGB32(40, 160, 65), B
        Color _RGB32(180, 255, 190)
        _PrintString (296, 403), "SAVE + LAUNCH"
    Else
        Line (280, 395)-(440, 425), _RGB32(22, 70, 130), BF
        Line (280, 395)-(440, 425), _RGB32(40, 130, 210), B
        Color _RGB32(180, 220, 255)
        _PrintString (320, 403), "LAUNCH"
    End If

    ' Status bar - show cfg file path instead of slot info
    Dim statusy As Integer
    statusy = SH - 26
    Line (0, statusy - 1)-(SW - 1, SH - 1), _RGB32(12, 15, 26), BF
    Line (0, statusy - 1)-(SW - 1, statusy - 1), col_rim&
    Color col_dim&
    _PrintString (12, statusy + 5), cfgfile
End Sub

Rem ================================================================
Sub drawUI ()
    Dim f As Integer
    Line (0, 0)-(SW - 1, SH - 1), col_bg&, BF
    drawstars
    drawtitlebar
    drawwheel
    For f = 1 To info.slotNum
        If f = flocation Then drawslot f, 1 Else drawslot f, 0
    Next f
    drawcenter
    drawclosebutton
    drawstatus
End Sub

Rem ================================================================
Sub drawtitlebar ()
    Dim dname As String
    Line (0, 0)-(SW - 1, 34), _RGB32(12, 15, 26), BF
    Line (0, 34)-(SW - 1, 34), col_rim&
    Color col_accent&
    _PrintString (12, 9), "ZWO EFW Filter Wheel Controller"
    dname = RTrim$(info.Name)
    Color col_dim&

End Sub

Rem ================================================================
Sub drawwheel ()
    Dim r As Integer, f As Integer, angle As Double, pi As Double
    Dim sx As Integer, sy As Integer, gv As Integer
    pi = 3.14159265358979#

    For r = WheelR + 14 To WheelR + 1 Step -1
        gv = (WheelR + 14 - r) * 4
        If gv > 80 Then gv = 80
        Circle (WheelCX, WheelCY), r, _RGB32(gv \ 3, gv, gv * 2)
    Next r

    For r = WheelR To 0 Step -1
        Circle (WheelCX, WheelCY), r, col_wheel&
    Next r

    Circle (WheelCX, WheelCY), WheelR, col_rim&
    Circle (WheelCX, WheelCY), WheelR - 1, _RGB32(32, 42, 65)
    Circle (WheelCX, WheelCY), WheelR - 2, _RGB32(25, 32, 50)

    For f = 1 To info.slotNum
        angle = (2.0# * pi * (f - 1) / info.slotNum) - pi / 2.0#
        sx = WheelCX + CInt((WheelR - fsize * 2 - 14) * Cos(angle))
        sy = WheelCY + CInt((WheelR - fsize * 2 - 14) * Sin(angle))
        Line (WheelCX, WheelCY)-(sx, sy), _RGB32(30, 38, 56)
    Next f
End Sub

Rem ================================================================
Sub drawcenter ()
    Dim r As Integer
    For r = 24 To 0 Step -1
        Circle (WheelCX, WheelCY), r, col_hub&
    Next r
    Circle (WheelCX, WheelCY), 24, col_rim&
    For r = 11 To 0 Step -1
        Circle (WheelCX, WheelCY), r, _RGB32(58, 68, 96)
    Next r
    Circle (WheelCX, WheelCY), 11, _RGB32(82, 102, 142)
    For r = 4 To 0 Step -1
        Circle (WheelCX, WheelCY), r, col_accent&
    Next r
End Sub

Rem ================================================================
Sub drawslot (slotnum As Integer, isactive As Integer)
    Dim x As Integer, y As Integer, r As Integer
    Dim fc&, dc&
    Dim rv As Long, gv As Long, bv As Long, gfact As Integer

    x = circlel(slotnum).x
    y = circlel(slotnum).y
    fc& = filtercolor&(slotnum)

    For r = fsize + 16 To 0 Step -1
        Circle (x, y), r, col_wheel&
    Next r

    If isactive Then
        rv = _Red32(fc&) \ 2
        gv = _Green32(fc&) \ 2
        bv = _Blue32(fc&) \ 2
        For r = fsize + 10 To fsize + 1 Step -1
            gfact = (fsize + 10 - r) + 1
            Circle (x, y), r, _RGB32(rv * gfact \ 5, gv * gfact \ 5, bv * gfact \ 5)
        Next r
        For r = fsize To 0 Step -1
            Circle (x, y), r, fc&
        Next r
        Circle (x, y), fsize, _RGB32(210, 230, 255)
        For r = fsize \ 3 To 0 Step -1
            Circle (x, y), r, _RGB32(255, 255, 255)
        Next r
    Else
        rv = _Red32(fc&) \ 5
        gv = _Green32(fc&) \ 5
        bv = _Blue32(fc&) \ 5
        dc& = _RGB32(rv, gv, bv)
        For r = fsize To 0 Step -1
            Circle (x, y), r, dc&
        Next r
        Circle (x, y), fsize, _RGB32(42, 50, 70)
    End If

    drawslotlabel slotnum, isactive
End Sub

Rem ================================================================
Sub drawslotlabel (slotnum As Integer, isactive As Integer)
    Dim angle As Double, pi As Double, lx As Integer, ly As Integer
    Dim fname As String
    pi = 3.14159265358979#
    fname = filtername$(slotnum)
    angle = myATan2(circlel(slotnum).y - WheelCY, circlel(slotnum).x - WheelCX)
    lx = WheelCX + CInt((WheelR + 20) * Cos(angle)) - Len(fname) * 4
    ly = WheelCY + CInt((WheelR + 20) * Sin(angle)) - 7
    If isactive Then Color col_accent& Else Color col_dim&
    _PrintString (lx, ly), fname
End Sub

Rem ================================================================
Sub drawclosebutton ()
    Dim r As Integer
    Dim cx As Integer, cy As Integer
    cx = circlel(9).x: cy = circlel(9).y
    For r = 21 To 0 Step -1
        Circle (cx, cy), r, col_close&
    Next r
    Circle (cx, cy), 21, _RGB32(215, 65, 65)
    Circle (cx, cy), 22, _RGB32(120, 22, 22)
    Color _RGB32(255, 215, 215)
    _PrintString (cx - 16, cy - 7), "CLOSE"
End Sub

Rem ================================================================
Sub drawstatus ()

    If SW <= 0 Or SH <= 0 Then Exit Sub
    If _Dest = 0 Then Exit Sub

    Dim sy As Integer, slotstr As String

    sy = SH - 26

    Line (0, sy - 1)-(SW - 1, SH - 1), _RGB32(12, 15, 26), BF
    Line (0, sy - 1)-(SW - 1, sy - 1), col_rim&

    Color col_text&
    _PrintString (12, sy + 5), StatusMsg

    slotstr = "Slot " + LTrim$(Str$(flocation)) + _
              " / " + LTrim$(Str$(info.slotNum))

    Color col_accent&
    _PrintString (SW - 14 - Len(slotstr) * 8, sy + 5), slotstr

End Sub

Rem ================================================================
Sub drawstars ()
    Dim i As Integer, sx As Integer, sy As Integer, bv As Integer
    For i = 1 To 120
        sx = (i * 139 + i * i * 7) Mod (SW - 2) + 1
        sy = (i * 101 + i * 59 + 150) Mod (SH - 65) + 36
        bv = 55 + (i * 57) Mod 185
        PSet (sx, sy), _RGB32(bv, bv, CInt(bv * 1.08))
    Next i
End Sub

Rem ================================================================
Function myATan2# (y As Double, x As Double)
    Dim pi As Double
    pi = 3.14159265358979#
    If x > 0# Then
        myATan2 = Atn(y / x)
    ElseIf x < 0# And y >= 0# Then
        myATan2 = Atn(y / x) + pi
    ElseIf x < 0# And y < 0# Then
        myATan2 = Atn(y / x) - pi
    ElseIf x = 0# And y > 0# Then
        myATan2 = pi / 2.0#
    ElseIf x = 0# And y < 0# Then
        myATan2 = -pi / 2.0#
    Else
        myATan2 = 0#
    End If
End Function

Rem ================================================================
Sub closefilter ()
    StatusMsg = "Closing - parking at last slot..."
    drawstatus
    setfilter info.slotNum
    errortrap EFWClose(info.ID)
    System
End Sub

Rem ================================================================
Sub errortrap (e As Long)
    If e = 0 Then Exit Sub
    Select Case e
        Case 1: StatusMsg = "ERROR: Invalid Index"
        Case 2: StatusMsg = "ERROR: Invalid ID"
        Case 3: StatusMsg = "ERROR: Invalid Value"
        Case 4: StatusMsg = "ERROR: Device Not Opened"
        Case 5: StatusMsg = "ERROR: Device Removed!"
        Case 6: StatusMsg = "ERROR: Filter Is Moving"
        Case 7: StatusMsg = "ERROR: General Error"
        Case 8: StatusMsg = "ERROR: Device Closed"
        Case Else: StatusMsg = "ERROR: Code " + LTrim$(Str$(e))
    End Select
    drawstatus
End Sub

