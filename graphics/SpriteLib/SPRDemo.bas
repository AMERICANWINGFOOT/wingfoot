'$Include:'SPR.bi'

'=================================================================================================
' SPRDemo - exercise for the SPR sprite helper
'
' Everything you see is generated at run time, there are no image files to find. The two sheets
' are built with _NewImage and ordinary drawing commands, then handed to SPRSheetFromImage.
'
' Controls:
'   arrow up / down   add or remove orbs
'   P                 toggle box vs pixel accurate collision
'   L                 toggle layer separation on the orbs
'   SPACE             re-scatter everything
'   ESC               quit
'=================================================================================================

Const SCRW = 900
Const SCRH = 640
Const MAXORB = 200

Dim orb&(1 To MAXORB) '                                the bouncing orbs
Dim orbCount% '                                        how many are live right now
Dim orbSheet& '                                        8 cell pulsing orb sheet
Dim shipSheet& '                                       single cell arrow sheet
Dim ship& '                                            the arrow that chases the mouse
Dim marker& '                                          invisible sprite parked on the mouse
Dim hud& '                                             orb used as a HUD stamp, never drawn by SPRDrawAll
Dim pixelMode% '                                       -1 when pixel accurate detection is on
Dim layerMode% '                                       -1 when orbs are split across layers
Dim i%, n%, hits%
Dim kk$
Dim tNow#, tLast#, dt!
Dim fps%, frames%, fpsClock#
Dim msg$
Dim tmpImg&

Declare Sub AddOrb (list&(), count%, sheet&, layerMode%)
Declare Sub BounceOrb (handle&)
Declare Function BuildOrbSheet& ()
Declare Function BuildShipSheet& ()

Screen _NewImage(SCRW, SCRH, 32)
_Title "SPR sprite helper demo"
_ScreenMove _Middle
Randomize Timer

SPRInit

tmpImg& = BuildOrbSheet&
orbSheet& = SPRSheetFromImage&(tmpImg&, 40, 40, -1)
If orbSheet& = SPR_NOHANDLE Then Print SPRError$: End

tmpImg& = BuildShipSheet&
shipSheet& = SPRSheetFromImage&(tmpImg&, 40, 40, -1)
If shipSheet& = SPR_NOHANDLE Then Print SPRError$: End

'-- the arrow that follows the pointer
ship& = SPRNew&(shipSheet&, 0)
SPRMove ship&, SCRW / 2, SCRH / 2
SPRSetLayer ship&, 2
SPRSetDetect ship&, SPR_NODETECT

'-- an invisible sprite pinned to the mouse, used only as a target for SPRAngleTo
marker& = SPRNew&(shipSheet&, 0)
SPRHide marker&
SPRSetDetect marker&, SPR_NODETECT

'-- one spare orb used purely as a rubber stamp for the HUD
hud& = SPRNew&(orbSheet&, 4)
SPRHide hud&
SPRSetDetect hud&, SPR_NODETECT
SPRSetZoom hud&, 45

orbCount% = 0
pixelMode% = -1
layerMode% = 0
For i% = 1 To 40
    AddOrb orb&(), orbCount%, orbSheet&, layerMode%
Next i%

tLast# = Timer(.001)
fpsClock# = tLast#
frames% = 0

Do

    '-- elapsed seconds, clamped so a hitch cannot teleport anything across the screen
    tNow# = Timer(.001)
    dt! = tNow# - tLast#
    If dt! < 0 Then dt! = 0
    If dt! > .1 Then dt! = .1
    tLast# = tNow#

    '-- input ------------------------------------------------------------------------------------
    kk$ = InKey$
    Select Case kk$
        Case Chr$(27)
            Exit Do
        Case Chr$(0) + Chr$(72) '                      up arrow
            For i% = 1 To 10
                AddOrb orb&(), orbCount%, orbSheet&, layerMode%
            Next i%
        Case Chr$(0) + Chr$(80) '                      down arrow
            For i% = 1 To 10
                If orbCount% > 0 Then
                    SPRFree orb&(orbCount%)
                    orbCount% = orbCount% - 1
                End If
            Next i%
        Case "p", "P"
            pixelMode% = Not pixelMode%
            For i% = 1 To orbCount%
                If pixelMode% Then SPRSetDetect orb&(i%), SPR_PIXELDETECT Else SPRSetDetect orb&(i%), SPR_BOXDETECT
            Next i%
        Case "l", "L"
            layerMode% = Not layerMode%
            For i% = 1 To orbCount%
                If layerMode% Then SPRSetLayer orb&(i%), i% Mod 3 Else SPRSetLayer orb&(i%), 0
            Next i%
        Case " "
            For i% = 1 To orbCount%
                SPRMove orb&(i%), Rnd * SCRW, Rnd * SCRH
                SPRSetVel orb&(i%), (Rnd * 240) - 120, (Rnd * 240) - 120
            Next i%
    End Select

    '-- simulation -------------------------------------------------------------------------------
    While _MouseInput: Wend
    SPRMove marker&, _MouseX, _MouseY

    SPRUpdate dt!

    '-- point the arrow at the pointer and glide toward it
    SPRSetAngle ship&, SPRAngleTo!(ship&, marker&)
    SPRMoveBy ship&, (_MouseX - SPRX!(ship&)) * dt! * 3, (_MouseY - SPRY!(ship&)) * dt! * 3

    '-- bounce the orbs off the window edges and spin them
    For i% = 1 To orbCount%
        BounceOrb orb&(i%)
        SPRTurn orb&(i%), 90 * dt!
    Next i%

    '-- count collisions among the orbs. Only the first half is tested against everything so
    '-- the demo stays responsive when the orb count is cranked up.
    hits% = 0
    n% = orbCount% \ 2
    If n% > 30 Then n% = 30
    For i% = 1 To n%
        If SPRHitAny&(orb&(i%)) <> SPR_NOHANDLE Then
            hits% = hits% + 1
            SPRSetVal orb&(i%), .25 '                  flash timer, counted down below
        End If
    Next i%
    For i% = 1 To orbCount%
        If SPRVal!(orb&(i%)) > 0 Then
            SPRSetVal orb&(i%), SPRVal!(orb&(i%)) - dt!
            SPRSetZoom orb&(i%), 145
        Else
            SPRSetZoom orb&(i%), 100
        End If
    Next i%

    '-- draw -------------------------------------------------------------------------------------
    Cls , _RGB32(12, 14, 26)
    SPRDrawAll

    '-- SPRStamp draws a sprite anywhere without touching its own position
    For i% = 1 To 5
        SPRStamp hud&, 780 + i% * 22, 26
    Next i%

    Color _RGB32(230, 230, 240)
    _PrintString (12, 12), "orbs:" + Str$(orbCount%) + "   live sprites:" + Str$(SPRCount%) + "   fps:" + Str$(fps%)
    If pixelMode% Then msg$ = "pixel accurate" Else msg$ = "bounding box"
    _PrintString (12, 28), "detection: " + msg$ + "   colliding: " + LTrim$(Str$(hits%))
    If layerMode% Then msg$ = "three layers" Else msg$ = "single layer"
    _PrintString (12, 44), "layers: " + msg$
    Color _RGB32(150, 155, 175)
    _PrintString (12, SCRH - 24), "up/down orbs    P detection    L layers    SPACE scatter    ESC quit"

    _Display

    frames% = frames% + 1
    If tNow# - fpsClock# >= 1 Then
        fps% = frames%
        frames% = 0
        fpsClock# = tNow#
    End If

    _Limit 60

Loop

SPRReset
System

'=================================================================================================

Sub AddOrb (llist&(), count%, sheet&, layerMode%)

    Dim h&

    If count% >= UBound(llist&) Then Exit Sub
    h& = SPRNew&(sheet&, 0)
    If h& = SPR_NOHANDLE Then Exit Sub
    count% = count% + 1
    llist&(count%) = h&
    SPRMove h&, 40 + Rnd * (900 - 80), 60 + Rnd * (640 - 120)
    SPRSetVel h&, (Rnd * 240) - 120, (Rnd * 240) - 120
    SPRAnimSet h&, 0, 7, 12 + Rnd * 10, SPR_PINGPONG
    SPRAnimOn h&
    SPRSetDetect h&, SPR_PIXELDETECT
    If layerMode% Then SPRSetLayer h&, count% Mod 3 Else SPRSetLayer h&, 0

End Sub

'=================================================================================================

Sub BounceOrb (handle&)

    Dim vx!, vy!, x!, y!

    x! = SPRX!(handle&)
    y! = SPRY!(handle&)
    vx! = SPRVX!(handle&)
    vy! = SPRVY!(handle&)
    If x! < 24 And vx! < 0 Then vx! = -vx!
    If x! > 900 - 24 And vx! > 0 Then vx! = -vx!
    If y! < 70 And vy! < 0 Then vy! = -vy!
    If y! > 640 - 40 And vy! > 0 Then vy! = -vy!
    SPRSetVel handle&, vx!, vy!

End Sub

'=================================================================================================
' Builds an eight cell sheet, 40x40 per cell, of a filled circle that grows from small to large.
' Drawn row by row so the alpha edge stays clean and PAINT is never needed.
'=================================================================================================

Function BuildOrbSheet& ()

    Dim img&, prevDest&
    Dim f%, r%, yy%, halfw!, cx%, cy%
    Dim c~&

    img& = _NewImage(40 * 8, 40, 32)
    prevDest& = _Dest
    _Dest img&
    Cls , _RGBA32(0, 0, 0, 0)

    For f% = 0 To 7
        cx% = f% * 40 + 20
        cy% = 20
        r% = 7 + f% * 2
        c~& = _RGBA32(90 + f% * 20, 200 - f% * 12, 255 - f% * 10, 255)
        For yy% = -r% To r%
            halfw! = Sqr(r% * r% - yy% * yy%)
            Line (cx% - halfw!, cy% + yy%)-(cx% + halfw!, cy% + yy%), c~&
        Next yy%
        '-- a highlight so rotation is visible
        Line (cx% - 2, cy% - r%)-(cx% + 2, cy% - r% + 5), _RGBA32(255, 255, 255, 220), BF
    Next f%

    _Dest prevDest&
    BuildOrbSheet& = img&

End Function

'=================================================================================================
' Builds a single cell 40x40 arrow pointing up, so sprite rotation has an obvious direction.
'=================================================================================================

Function BuildShipSheet& ()

    Dim img&, prevDest&
    Dim yy%, halfw!

    img& = _NewImage(40, 40, 32)
    prevDest& = _Dest
    _Dest img&
    Cls , _RGBA32(0, 0, 0, 0)

    For yy% = 0 To 30
        halfw! = yy% * .45
        Line (20 - halfw!, yy% + 4)-(20 + halfw!, yy% + 4), _RGBA32(255, 210, 90, 255)
    Next yy%
    Line (12, 30)-(28, 34), _RGBA32(200, 120, 40, 255), BF

    _Dest prevDest&
    BuildShipSheet& = img&

End Function

'$Include:'SPR.bm'
