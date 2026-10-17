'=================================================================================================
' SPR - 2D Sprite Helper for QB64-PE 4.5.0
'
' Companion to W3 (wireframe) and OBJ3 (model display) in the QB64Starter toolkit.
'
' Design notes vs. Terry Ritchie's 2011 Sprite Library (the reference this grew from):
'   - Frame-redraw model. No background save/restore, no dirty rectangles. CLS, draw, _DISPLAY.
'   - Cell sub-images are cut ONCE at sheet load and cached. Nothing is allocated per frame.
'   - Cells are ZERO based (0 .. count-1). The 2011 library was 1 based.
'   - Errors never halt the program. Functions return 0, subs no-op, and SPRError$ explains.
'   - Handles carry a generation counter, so a stale handle fails instead of silently
'     addressing a recycled sprite.
'   - Pixel-accurate collision reads image memory through _MEM and inverse-transforms screen
'     points into cell space, so rotation and scaling work with no temporary images.
'   - All public names are prefixed SPR to keep the global namespace clean.
'
' Usage: include this file at the TOP of your program and SPR.bm at the BOTTOM, using the
'        include metacommand. Call SPRInit once after setting up your screen.
'
' Angles are DEGREES, 0 = up (north), increasing CLOCKWISE.
'=================================================================================================

'-- pool sizes -----------------------------------------------------------------------------------
Const SPR_MAXSHEET = 32 '            maximum sprite sheets loaded at once
Const SPR_MAXSPRITE = 1023 '         maximum live sprites (must stay <= 1023, see handle encoding)
Const SPR_MAXCELL = 8192 '           total cached cell images across all sheets

'-- flip modes, for SPRSetFlip -------------------------------------------------------------------
Const SPR_NOFLIP = 0
Const SPR_FLIPH = 1
Const SPR_FLIPV = 2
Const SPR_FLIPHV = 3

'-- animation styles, for SPRAnimSet -------------------------------------------------------------
Const SPR_FORWARD = 0 '              start -> end, wrap to start
Const SPR_BACKWARD = 1 '             end -> start, wrap to end
Const SPR_PINGPONG = 2 '             start -> end -> start, bouncing
Const SPR_ONCE = 3 '                 start -> end, then stop (SPRAnimDone% reports -1)

'-- collision modes, for SPRSetDetect ------------------------------------------------------------
Const SPR_NODETECT = 0
Const SPR_BOXDETECT = 1 '            axis aligned bounding box only
Const SPR_PIXELDETECT = 2 '          box first, then per pixel alpha test

'-- misc -----------------------------------------------------------------------------------------
Const SPR_NOHANDLE = 0 '             returned by any function that failed
Const SPR_HANDLEMASK = 1023 '        low bits of a handle are the pool index
Const SPR_MAXLAYER = 63 '            layers are 0..63, drawn low to high

'-- comments must live OUTSIDE a TYPE block in QB64-PE 4.5.0, an inline comment on an element
'-- line silently kills the TYPE and misreports the error somewhere else entirely.

Type SPRSheet
    inuse As Integer
    gen As Integer
    img As Long
    owns As Integer
    sheetW As Integer
    sheetH As Integer
    cellW As Integer
    cellH As Integer
    cols As Integer
    rows As Integer
    cellCount As Integer
    firstCell As Integer
End Type

Type SPRSprite
    inuse As Integer
    gen As Integer
    sheet As Long
    sheetIdx As Integer
    cell As Integer
    x As Single
    y As Single
    vx As Single
    vy As Single
    visible As Integer
    layer As Integer
    flip As Integer
    scaleX As Single
    scaleY As Single
    angle As Single
    originX As Single
    originY As Single
    animOn As Integer
    animStyle As Integer
    animStart As Integer
    animEnd As Integer
    animDir As Integer
    animRate As Single
    animAccum As Single
    animDone As Integer
    detect As Integer
    boxX1 As Integer
    boxY1 As Integer
    boxX2 As Integer
    boxY2 As Integer
    userVal As Single
    userVal2 As Single
End Type

Dim Shared sprSheets(1 To SPR_MAXSHEET) As SPRSheet
Dim Shared sprItems(1 To SPR_MAXSPRITE) As SPRSprite
Dim Shared sprCells(1 To SPR_MAXCELL) As Long
Dim Shared sprCellTop As Integer
Dim Shared sprLastError As String
Dim Shared sprReady As Integer
Dim Shared sprLiveCount As Integer

'-- declarations. These are REQUIRED for cross module calls, without them QB64-PE parses
'-- calls like  ok = SPRHit%(a, b)  as an array reference and reports a bogus type error.

Declare Sub SPRInit ()
Declare Sub SPRReset ()
Declare Function SPRError$ ()
Declare Function SPRCount% ()

Declare Function SPRSheetLoad& (fileName$, cellW%, cellH%)
Declare Function SPRSheetFromImage& (img&, cellW%, cellH%, adopt%)
Declare Sub SPRSheetFree (sheet&)
Declare Function SPRSheetCells% (sheet&)
Declare Function SPRSheetCellW% (sheet&)
Declare Function SPRSheetCellH% (sheet&)
Declare Function SPRSheetCols% (sheet&)
Declare Function SPRSheetImage& (sheet&)

Declare Function SPRNew& (sheet&, cell%)
Declare Function SPRClone& (handle&)
Declare Sub SPRFree (handle&)
Declare Function SPRValid% (handle&)

Declare Sub SPRMove (handle&, x!, y!)
Declare Sub SPRMoveBy (handle&, dx!, dy!)
Declare Sub SPRSetVel (handle&, vx!, vy!)
Declare Sub SPRSetOrigin (handle&, ox!, oy!)
Declare Function SPRX! (handle&)
Declare Function SPRY! (handle&)
Declare Function SPRVX! (handle&)
Declare Function SPRVY! (handle&)

Declare Sub SPRSetCell (handle&, cell%)
Declare Sub SPRSetAngle (handle&, degrees!)
Declare Sub SPRTurn (handle&, degrees!)
Declare Sub SPRSetZoom (handle&, percent!)
Declare Sub SPRSetScale (handle&, sx!, sy!)
Declare Sub SPRSetFlip (handle&, mode%)
Declare Sub SPRSetLayer (handle&, layer%)
Declare Sub SPRShow (handle&)
Declare Sub SPRHide (handle&)
Declare Function SPRCellOf% (handle&)
Declare Function SPRAngleOf! (handle&)
Declare Function SPRVisible% (handle&)
Declare Function SPRLayerOf% (handle&)

Declare Sub SPRAnimSet (handle&, startCell%, endCell%, cellsPerSec!, style%)
Declare Sub SPRAnimOn (handle&)
Declare Sub SPRAnimOff (handle&)
Declare Function SPRAnimDone% (handle&)
Declare Sub SPRAnimNext (handle&)
Declare Sub SPRAnimPrev (handle&)

Declare Sub SPRUpdate (dt!)
Declare Sub SPRDraw (handle&)
Declare Sub SPRDrawAll ()
Declare Sub SPRStamp (handle&, x!, y!)
Declare Sub SPRPut (handle&, x!, y!)

Declare Function SPRLeft% (handle&)
Declare Function SPRTop% (handle&)
Declare Function SPRRight% (handle&)
Declare Function SPRBottom% (handle&)
Declare Function SPRWidth% (handle&)
Declare Function SPRHeight% (handle&)

Declare Sub SPRSetDetect (handle&, mode%)
Declare Function SPRHit% (handleA&, handleB&)
Declare Function SPRHitAny& (handle&)
Declare Function SPRHitList% (handle&, result&())
Declare Function SPRDistance! (handleA&, handleB&)
Declare Function SPRAngleTo! (handleA&, handleB&)
Declare Function SPRMouseOver% (handle&)

Declare Sub SPRSetVal (handle&, value!)
Declare Sub SPRSetVal2 (handle&, value!)
Declare Function SPRVal! (handle&)
Declare Function SPRVal2! (handle&)

'-- private helpers, not intended for direct use
Declare Function SPRIdx% (handle&)
Declare Function SPRSheetIdx% (sheet&)
Declare Sub SPRFail (msg$)
Declare Sub SPRBox (idx%)
Declare Sub SPRCorners (idx%, px!(), py!())
Declare Function SPRCellImg& (idx%)
Declare Function SPRAlphaAt% (idx%, m As _MEM, imgW%, imgH%, px%, py%)
Declare Sub SPRRender (idx%, atX!, atY!)
Declare Sub SPRStepAnim (idx%, adv%)
