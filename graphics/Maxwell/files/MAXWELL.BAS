'============================================================
'  MAXWELL'S EQUATIONS  --  Electromagnetic Plane Wave
'  A QB64 graphics demonstration  (+ ButtonUI control bar)
'
'  A linearly-polarized plane wave travelling along +x:
'      E field (red)   oscillates in  y
'      B field (blue)  oscillates in  z   (perpendicular to E)
'  Both are in phase, both ~ sin(kx - wt), so the whole
'  pattern sails to the right at the wave speed
'      c = 1 / sqrt(mu0 * eps0)   =  the speed of light.
'
'  Requires ButtonUI.bi / ButtonUI.bm in the same folder.
'  Controls: on-screen buttons, OR  ESC quit / P pause /
'            +/- wavelengths / <-/-> speed
'============================================================

OPTION _EXPLICIT

'$INCLUDE:'ButtonUI.bi'

CONST SW = 1000, SH = 660

SCREEN _NEWIMAGE(SW, SH, 32)
_TITLE "Maxwell's Equations - EM Plane Wave   (ESC quits)"
_PRINTMODE _KEEPBACKGROUND       ' clean glyphs, no stamped text box
MouseInit                        ' load the slate-blue button theme

'---- projection & geometry (shared with the drawing SUBs) ----
DIM SHARED AX0 AS SINGLE, AY0 AS SINGLE      ' axis origin on screen
DIM SHARED AXLEN AS SINGLE                   ' axis length in pixels
DIM SHARED AMP AS SINGLE                     ' field amplitude in pixels
DIM SHARED DZX AS SINGLE, DZY AS SINGLE      ' depth-projection factors

AX0 = 150: AY0 = 380
AXLEN = 720
AMP = 120
DZX = 0.55: DZY = 0.33

'---- colours ----
DIM SHARED CBG AS _UNSIGNED LONG, CAXIS AS _UNSIGNED LONG
DIM SHARED CE AS _UNSIGNED LONG, CB AS _UNSIGNED LONG
DIM SHARED CTXT AS _UNSIGNED LONG, CACC AS _UNSIGNED LONG

CBG = _RGB32(10, 12, 26)
CAXIS = _RGB32(120, 130, 155)
CE = _RGB32(255, 90, 90)
CB = _RGB32(90, 160, 255)
CTXT = _RGB32(230, 235, 245)
CACC = _RGB32(255, 210, 90)

'---- animation state ----
DIM t AS SINGLE, speed AS SINGLE, cycles AS SINGLE
DIM paused AS INTEGER
DIM k$, capPause$

t = 0: speed = 0.06: cycles = 2.5: paused = 0

'=========================== MAIN LOOP ============================
DO
    PollMouse                                 ' refresh mouse once per frame

    '---- keyboard shortcuts (still available) ----
    k$ = INKEY$
    IF k$ = CHR$(27) THEN EXIT DO
    IF k$ = "p" OR k$ = "P" THEN paused = NOT paused
    IF k$ = "+" OR k$ = "=" THEN cycles = cycles + 0.5: IF cycles > 6 THEN cycles = 6
    IF k$ = "-" OR k$ = "_" THEN cycles = cycles - 0.5: IF cycles < 1 THEN cycles = 1
    IF _KEYDOWN(19200) THEN speed = speed - 0.004: IF speed < 0 THEN speed = 0
    IF _KEYDOWN(19712) THEN speed = speed + 0.004: IF speed > 0.25 THEN speed = 0.25

    IF NOT paused THEN t = t + speed

    '---- render ----
    LINE (0, 0)-(SW, SH), CBG, BF
    DrawScene t, cycles
    DrawHUD cycles, speed

    '---- on-screen control bar (immediate-mode buttons) ----
    IF paused THEN capPause$ = "Play" ELSE capPause$ = "Pause"
    IF Button%(20, 60, 150, 30, capPause$) THEN paused = NOT paused
    IF Button%(178, 60, 150, 30, "Waves -") THEN cycles = cycles - 0.5: IF cycles < 1 THEN cycles = 1
    IF Button%(336, 60, 150, 30, "Waves +") THEN cycles = cycles + 0.5: IF cycles > 6 THEN cycles = 6
    IF Button%(494, 60, 150, 30, "Slower") THEN speed = speed - 0.01: IF speed < 0 THEN speed = 0
    IF Button%(652, 60, 150, 30, "Faster") THEN speed = speed + 0.01: IF speed > 0.25 THEN speed = 0.25
    IF Button%(810, 60, 150, 30, "Quit") THEN EXIT DO

    _DISPLAY
    _LIMIT 60
LOOP

SYSTEM

'--------------------------------------------------------------
'  Oblique 3-D projection: field-space (x,y,z) -> screen (sx,sy)
'     x = distance along the propagation axis (pixels)
'     y = electric-field displacement (up is +)
'     z = magnetic-field displacement (into page, up-right)
'--------------------------------------------------------------
SUB Project (xpix AS SINGLE, wy AS SINGLE, wz AS SINGLE, sx AS SINGLE, sy AS SINGLE)
    sx = AX0 + xpix + wz * DZX
    sy = AY0 - wy - wz * DZY
END SUB

'--------------------------------------------------------------
'  Draw a line with a small arrowhead at (x1,y1)
'--------------------------------------------------------------
SUB Arrow (x0 AS SINGLE, y0 AS SINGLE, x1 AS SINGLE, y1 AS SINGLE, clr AS _UNSIGNED LONG, hs AS SINGLE)
    DIM ang AS SINGLE
    LINE (x0, y0)-(x1, y1), clr
    ang = _ATAN2(y1 - y0, x1 - x0)
    LINE (x1, y1)-(x1 + hs * COS(ang + 2.6), y1 + hs * SIN(ang + 2.6)), clr
    LINE (x1, y1)-(x1 + hs * COS(ang - 2.6), y1 + hs * SIN(ang - 2.6)), clr
END SUB

'--------------------------------------------------------------
'  Draw the propagation axis, the two field combs, and the
'  smooth E and B envelope curves, for the current time t.
'--------------------------------------------------------------
SUB DrawScene (t AS SINGLE, cycles AS SINGLE)
    DIM N AS INTEGER, i AS INTEGER
    DIM u AS SINGLE, xpix AS SINGLE, phase AS SINGLE, E AS SINGLE, B AS SINGLE
    DIM px0 AS SINGLE, py0 AS SINGLE, pex AS SINGLE, pey AS SINGLE, pbx AS SINGLE, pby AS SINGLE
    DIM ox0 AS SINGLE, oy0 AS SINGLE, oex AS SINGLE, oey AS SINGLE, obx AS SINGLE, oby AS SINGLE
    DIM first AS INTEGER
    DIM ex AS SINGLE, ey AS SINGLE

    N = 160: first = 1

    FOR i = 0 TO N
        u = i / N
        xpix = u * AXLEN
        phase = 2 * _PI * cycles * u - t
        E = AMP * SIN(phase)
        B = AMP * SIN(phase)

        Project xpix, 0, 0, px0, py0
        Project xpix, E, 0, pex, pey
        Project xpix, 0, B, pbx, pby

        IF NOT first THEN
            LINE (ox0, oy0)-(px0, py0), CAXIS    ' propagation axis
            LINE (obx, oby)-(pbx, pby), CB        ' B envelope
            LINE (oex, oey)-(pex, pey), CE        ' E envelope
        END IF

        IF i MOD 8 = 0 THEN                       ' field "comb" of vectors
            Arrow px0, py0, pbx, pby, CB, 7
            Arrow px0, py0, pex, pey, CE, 7
        END IF

        ox0 = px0: oy0 = py0
        oex = pex: oey = pey
        obx = pbx: oby = pby
        first = 0
    NEXT i

    ' propagation-direction arrow, labelled c
    Project AXLEN, 0, 0, ex, ey
    Arrow ex, ey, ex + 70, ey, CACC, 12
    COLOR CACC: _PRINTSTRING (ex + 34, ey - 24), "c"

    ' field labels
    COLOR CE: _PRINTSTRING (AX0 + 20, AY0 - AMP - 26), "E  (electric)"
    COLOR CB: _PRINTSTRING (AX0 + 330, AY0 + 70), "B  (magnetic)"
    COLOR CAXIS: _PRINTSTRING (AX0 - 34, AY0 - 6), "O"
END SUB

'--------------------------------------------------------------
'  Title, the four equations, and the speed-of-light note
'--------------------------------------------------------------
SUB DrawHUD (cycles AS SINGLE, speed AS SINGLE)
    DIM ex AS INTEGER, ey AS INTEGER

    COLOR CTXT
    _PRINTSTRING (20, 16), "MAXWELL'S EQUATIONS  --  Electromagnetic Plane Wave"
    COLOR CAXIS
    _PRINTSTRING (20, 40), "A transverse wave: E _|_ B _|_ direction of travel, all in phase."

    ex = 20: ey = SH - 128
    COLOR CTXT
    _PRINTSTRING (ex, ey), "div E  = rho / eps0               (Gauss)"
    _PRINTSTRING (ex, ey + 18), "div B  = 0                        (no monopoles)"
    _PRINTSTRING (ex, ey + 36), "curl E = - dB/dt                  (Faraday)"
    _PRINTSTRING (ex, ey + 54), "curl B = mu0 J + mu0 eps0 dE/dt   (Ampere-Maxwell)"
    COLOR CACC
    _PRINTSTRING (ex, ey + 80), "wave speed  c = 1 / sqrt(mu0 * eps0)  =  speed of light"
END SUB

'$INCLUDE:'ButtonUI.bm'
