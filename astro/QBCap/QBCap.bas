'==================================================================
'  QBCap.bas  -  Linux capture program for ZWO ASI cameras
'  v0.12 -  QB64-PE 4.5.0  +  libqbcap.so + libqbgpu.so (remote control: QBCapRemote.bi/.bm)
'
'  Working now : camera connect, format/ROI/binning, exposure, gain,
'                offset, USB bandwidth, cooler, live video preview with
'                stretch + debayer + white balance, histogram, stats,
'                recording to SER or FITS (with frame/time limits),
'                snapshot to FITS, open captures folder, ZWO EFW filter wheel
'                with per-wheel filter names (QBCap_filters.txt).
'                master darks/flats (capture, save, load, applied to preview).
'                CUDA sharpness scoring (libqbgpu.so, CPU fallback),
'                lucky imaging, sharpness graph for focus / seeing,
'                live stacking (align + mean / sigma clip, GPU or CPU),
'                plate solving with astrometry.net (live frame, stack, or a
'                FITS / JPEG / PNG file; index files in the "index" folder),
'                polar alignment (two solves + RA turn, then live alt/az error;
'                site for the alt/az split in QBCap_site.txt), using a QHY
'                PoleMaster (libqhyccd.so, loaded when needed).
'                mount control (Sky-Watcher / SynScan motor protocol over WiFi
'                or USB; address in QBCap_mount.txt): hold-to-move buttons,
'                tracking, axis positions, stall + lost-link stops.
'                remote control (v0.12): commands in QBCap_cmd.txt, replies in
'                QBCap_reply.txt, status in QBCap_status.txt (QBCapRemote.bm).
'  Still stubs : settings dialog.
'
'  Files are saved in a "captures" folder next to the program;
'  master darks/flats go in "masters", saved stacks in "stacks",
'  solved images in "solves" (solve-field's work files in "solve").
'
'  Needs next to the compiled program:
'    libqbcap.so, libASICamera2.so, libEFWFilter.so  (ZWO Linux SDKs, x64)
'
'  Layout (1280 x 800):
'    menu bar  /  tool bar
'    image area (left)  |  control panel (right, collapsible groups)
'    status bar
'
'  Keys: Space = Live on/off   H = Histogram   R = Reticule
'        Esc   = close menu / quit
'==================================================================
Option _Explicit
_Title "QBCap - ZWO Capture"

'---------------- libqbcap.so  (C capture core; must sit next to this program) ----------------
' ZWO control numbers (from ASICamera2.h, ASI_CONTROL_TYPE)
Const ASI_GAIN = 0
Const ASI_EXPOSURE = 1
Const ASI_OFFSET = 5
Const ASI_BANDWIDTH = 6
Const ASI_TEMPERATURE = 8
Const ASI_HIGH_SPEED = 14
Const ASI_COOLER_POWER = 15
Const ASI_TARGET_TEMP = 16
Const ASI_COOLER_ON = 17

Const LIMIT_LIST = "None|100 frames|500 frames|1000 frames|5000 frames|30 sec|1 min|5 min"
Const CALN_LIST = "10|20|50|100"
Const EXP_MAX_MS = 600000 ' longest exposure: 10 minutes
Const EXP_STEPS = "1|2|5|10|20|50|100|200|500|1000|2000|3000|5000|10000|15000|20000|30000|45000|60000|90000|120000|180000|240000|300000|450000|600000"

Declare Dynamic Library "qbcap"
    Function qc_version& ()
    Function qc_sdk_version& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_last_error& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_camera_count& ()
    Function qc_camera_name& (ByVal idx As Long, ByVal buf As _Offset, ByVal blen As Long)
    Function qc_find_camera& (ByVal namePart As _Offset)
    Function qc_g3_count& ()
    Function qc_usbcam_count& ()
    Function qc_qhy_count& ()
    Function qc_qhy_blank& ()
    Function qc_open& (ByVal idx As Long)
    Sub qc_close ()
    Function qc_sensor_info& (w As Long, h As Long, isColor As Long, bayer As Long, bitDepth As Long, isCooled As Long, pixX100 As Long, usb3 As Long)
    Function qc_set_format& (ByVal binv As Long, ByVal bits16 As Long, ByVal roiW As Long, ByVal roiH As Long)
    Function qc_frame_size& (w As Long, h As Long, bpp As Long)
    Function qc_ctrl_range& (ByVal ctl As Long, mn As Long, mxv As Long, dflt As Long, canAuto As Long)
    Function qc_ctrl_set& (ByVal ctl As Long, ByVal v As Long, ByVal autoOn As Long)
    Function qc_ctrl_get& (ByVal ctl As Long, v As Long, autoOn As Long)
    Function qc_start_video& ()
    Sub qc_stop ()
    Function qc_set_stretch& (ByVal blk As Long, ByVal wht As Long, ByVal gamX100 As Long, ByVal debayer As Long)
    Function qc_get_preview& (ByVal bgra As _Offset, ByVal imgW As Long, ByVal imgH As Long, ByVal dx As Long, ByVal dy As Long, ByVal dw As Long, ByVal dh As Long, ByVal sx As Long, ByVal sy As Long, ByVal sw As Long, ByVal sh As Long, ByVal force As Long)
    Function qc_get_histogram& (ByVal bins As _Offset)
    Function qc_stats& (captured As Long, dropped As Long, fpsX10 As Long, tempX10 As Long)
    Function qc_set_wb& (ByVal redX100 As Long, ByVal blueX100 As Long)
    Function qc_set_meta& (ByVal telescope As _Offset, ByVal focalMm As Long, ByVal filter As _Offset)
    Function qc_record_start& (ByVal path As _Offset, ByVal fmt As Long, ByVal maxFrames As Long, ByVal maxSecs As Long)
    Sub qc_record_stop ()
    Function qc_record_status& (written As Long, bufPct As Long, dropped As Long, mbWritten As Long, active As Long)
    Function qc_snapshot& (ByVal path As _Offset)
    Function qc_efw_count& ()
    Function qc_efw_open& (ByVal idx As Long)
    Function qc_efw_info& (ByVal nameBuf As _Offset, ByVal blen As Long, slots As Long)
    Function qc_efw_set& (ByVal slot As Long)
    Function qc_efw_get& ()
    Function qc_efw_calibrate& ()
    Sub qc_efw_close ()
    Function qc_master_start& (ByVal mtype As Long, ByVal nframes As Long, ByVal path As _Offset)
    Sub qc_master_cancel ()
    Function qc_master_status& (done As Long, total As Long)
    Function qc_master_load& (ByVal mtype As Long, ByVal path As _Offset)
    Function qc_master_info& (ByVal mtype As Long, w As Long, h As Long, expUs As Long, gain As Long, tempX10 As Long, nframes As Long)
    Sub qc_master_clear (ByVal mtype As Long)
    Function qc_calib_set& (ByVal darkOn As Long, ByVal flatOn As Long)
    Function qc_master_fits& (ByVal mtype As Long)
    Function qc_gpu_init& (ByVal dev As Long)
    Function qc_gpu_info& (ByVal nameBuf As _Offset, ByVal blen As Long, memMB As Long, ccX10 As Long, devCount As Long)
    Function qc_gpu_selftest& (cpuX1000 As Long, gpuX1000 As Long, gpuUs As Long)
    Function qc_quality_enable& (ByVal onFlag As Long)
    Function qc_lucky_set& (ByVal onFlag As Long, ByVal keepPct As Long)
    Function qc_lucky_stats& (lastScore As Single, thresh As Single, kept As Long, rejected As Long, msPerFrame As Single)
    Function qc_score_history& (ByVal buf As _Offset, ByVal n As Long)
    Function qc_stack_start& (ByVal mode As Long)
    Sub qc_stack_stop ()
    Function qc_stack_reset& ()
    Function qc_stack_mode& (ByVal mode As Long)
    Function qc_stack_view& (ByVal onStack As Long)
    Function qc_stack_hotfix& (ByVal onFlag As Long)
    Function qc_stack_align& (ByVal onFlag As Long)
    Function qc_stack_stats& (stacked As Long, failed As Long, skipped As Long, stars As Long, matches As Long, dx As Single, dy As Single, rotDeg As Single, rms As Single, ms As Single, expSec As Single)
    Function qc_stack_message& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_stack_save& (ByVal path As _Offset)
    Function qc_auto_stretch& (blk As Long, wht As Long, gam As Long)
    Function qc_gpu_stack_selftest& (maxDiff As Single)
    Function qc_solve_start& (ByVal src As Long, ByVal srcFile As _Offset, ByVal workDir As _Offset, ByVal indexDir As _Offset, ByVal outPath As _Offset, ByVal scale As Single, ByVal timeLimit As Long)
    Function qc_solve_status& ()
    Sub qc_solve_cancel ()
    Function qc_solve_result& (ra As Double, dec As Double, fieldW As Single, fieldH As Single, rot As Single, pixScale As Single, secs As Single, stars As Long)
    Function qc_solve_message& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_solve_saved& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_solve_set_pixels& (ByVal bgra As _Offset, ByVal w As Long, ByVal h As Long)
    Function qc_solve_hint& (ByVal ra As Double, ByVal dec As Double, ByVal radiusDeg As Single)
    Function qc_pm_open& ()
    Sub qc_pm_close ()
    Function qc_pm_is_open& ()
    Function qc_pm_set& (ByVal expMs As Long, ByVal gain As Long)
    Function qc_pm_info& (ByVal nameBuf As _Offset, ByVal blen As Long, w As Long, h As Long, pixUmX100 As Long, frames As Long)
    Function qc_pm_preview& (ByVal bgra As _Offset, ByVal imgW As Long, ByVal imgH As Long, ByVal dx As Long, ByVal dy As Long, ByVal dw As Long, ByVal dh As Long, ByVal sx As Long, ByVal sy As Long, ByVal sw As Long, ByVal sh As Long, ByVal force As Long)
    Function qc_pa_reset& ()
    Function qc_pa_set_site& (ByVal latDeg As Double, ByVal lonDeg As Double)
    Function qc_pa_capture& (ByVal stp As Long)
    Function qc_pa_update& ()
    Function qc_pa_result& (errTot As Double, errAlt As Double, errAz As Double, rotDeg As Double, axX As Single, axY As Single, poX As Single, poY As Single, poOk As Long)
    Function qc_mount_open& (ByVal addr As _Offset)
    Sub qc_mount_close ()
    Function qc_mount_is_open& ()
    Function qc_mount_move& (ByVal axis As Long, ByVal speedIdx As Long, ByVal dir As Long)
    Function qc_mount_track& (ByVal onFlag As Long)
    Function qc_mount_stop& ()
    Function qc_mount_status& (raDeg As Double, decDeg As Double, raState As Long, decState As Long, tracking As Long)
    Function qc_mount_message& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_mount_info& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_mount_goto_axes& (ByVal dRA As Double, ByVal dDec As Double)
    Function qc_mount_lst# (ByVal lonDeg As Double)
    Function qc_mount_track_rate& (ByVal lunar As Long)
    Function qc_moon_radec& (ByVal latDeg As Double, ByVal lonDeg As Double, raDeg As Double, decDeg As Double)
    Function qc_guide_enable& (ByVal onFlag As Long)
    Function qc_guide_select& (ByVal x As Long, ByVal y As Long)
    Function qc_guide_calibrate& (ByVal stepMs As Long, ByVal distPx As Long)
    Function qc_guide_start& ()
    Function qc_guide_stop& ()
    Function qc_guide_pause& (ByVal onFlag As Long)
    Function qc_guide_dither& (ByVal px As Single)
    Function qc_guide_params& (ByVal aggRA As Single, ByVal aggDec As Single, ByVal minMovePx As Single, ByVal maxPulseMs As Long, ByVal settlePx As Single)
    Function qc_guide_status& (state As Long, paused As Long, haveStar As Long, x As Single, y As Single, snr As Single, lockX As Single, lockY As Single, eRA As Single, eDec As Single, rmsRA As Single, rmsDec As Single, settled As Long, calOk As Long, raMs As Long, decMs As Long)
    Function qc_guide_history& (ByVal buf As _Offset, ByVal n As Long)
    Function qc_guide_message& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_guide_cal_info& (raPxS As Single, decPxS As Single, angle As Single, ortho As Single)
    Function qc_guide_has_st4& ()
    Function qc_guide_logfile& (ByVal path As _Offset)
    Function qc_glink_listen& (ByVal port As Long)
    Function qc_glink_poll& (ByVal buf As _Offset, ByVal blen As Long)
    Function qc_glink_reply& (ByVal msg As _Offset)
    Function qc_glink_send& (ByVal port As Long, ByVal msg As _Offset, ByVal reply As _Offset, ByVal blen As Long, ByVal timeoutMs As Long)
End Declare

'---------------- layout ----------------
Const SCR_W = 1280
Const MENU_H = 22
Const STAT_H = 24
Const PANEL_W = 330
Const IMG_Y = 58
Const IMG_W = 950
Const PANEL_X = 950

'---------------- colours ----------------
Const C_BG = _RGB32(24, 24, 30)
Const C_BAR = _RGB32(40, 42, 52)
Const C_BAR2 = _RGB32(33, 35, 44)
Const C_PANEL = _RGB32(30, 32, 40)
Const C_GRP = _RGB32(50, 54, 70)
Const C_GRPHOT = _RGB32(62, 68, 88)
Const C_BTN = _RGB32(58, 62, 76)
Const C_BTNHOT = _RGB32(78, 84, 104)
Const C_BTNON = _RGB32(40, 110, 170)
Const C_BOX = _RGB32(18, 19, 24)
Const C_EDGE = _RGB32(16, 16, 20)
Const C_TXT = _RGB32(220, 222, 230)
Const C_DIM = _RGB32(140, 144, 160)
Const C_ACC = _RGB32(90, 170, 255)
Const C_ACCDIM = _RGB32(50, 95, 145)
Const C_REC = _RGB32(200, 50, 50)
Const C_OK = _RGB32(80, 210, 110)

'---------------- equipment tables ----------------
Const NCAM = 7
Const NSCOPE = 3
Const NFILT = 8
Const NGRP = 16
Const GLINK_PORT = 47123

Dim Shared camName$(1 To NCAM), camW(1 To NCAM) As Long, camH(1 To NCAM) As Long, camPix(1 To NCAM) As Single
Dim Shared scopeName$(1 To NSCOPE), scopeFL(1 To NSCOPE) As Single
Dim Shared filtName$(1 To NFILT)
Dim Shared grpName$(1 To NGRP), grpOpen(1 To NGRP) As Long

'---------------- menus ----------------
Const NMENU = 6
Dim Shared menuTitle$(1 To NMENU), menuItems$(1 To NMENU), menuX(1 To NMENU) As Long
Dim Shared menuOpen As Long

'---------------- mouse / ui ----------------
Dim Shared mx As Long, my As Long, mDown As Long, mPrev As Long, mClick As Long, mWheel As Long
Dim Shared lmx As Long, lmy As Long, uiInside As Long, activeSlider As Long, wheelUsed As Long

'---------------- program state ----------------
Dim Shared quitFlag As Long, statusMsg$
Dim Shared quitAsk As Long, quitAskT As Double
Dim Shared camSel As Long, camConn As Long, liveOn As Long, recOn As Long
Dim Shared fmtIdx As Long, binIdx As Long, roiIdx As Long, outIdx As Long
Dim Shared expMs As Long, gainV As Long, offsetV As Long, usbBW As Long, autoExp As Long, autoGain As Long
Dim Shared coolOn As Long, coolTarget As Long
Dim Shared expMaxMs As Long ' longest exposure of the connected camera
Dim Shared fwSlot As Long
Dim Shared blackV As Long, whiteV As Long, gammaV As Long, debayerOn As Long
Dim Shared scopeSel As Long
Dim Shared gpuDev As Long, gpuReady As Long, luckyOn As Long, luckyPct As Long, stackIdx As Long
Dim Shared showHist As Long, showRet As Long, zoomFit As Long, zoomPct As Long
Dim Shared panelScroll As Long, panelContentH As Long
Dim Shared viewImg As Long, panelImg As Long

'---------------- window height (fits small screens) + log ----------------
Dim Shared SCR_H As Long, IMG_H As Long
Dim Shared logFile$, lastLogged$

'---------------- live camera state ----------------
Dim Shared liveImg As Long, liveMem As _MEM, lastGeom$, forceDraw As Long
Dim Shared frW As Long, frH As Long, camIsColor As Long, camCooled As Long, camFull$
' camIsG3: the connected camera is an Orion G3 (16-bit, full frame, bin 1, no auto, no USB bandwidth)
Dim Shared camIsG3 As Long
' camIsUSB: the connected camera is a standard Linux USB camera (8-bit, full frame, no cooler, no temperature)
Dim Shared camIsUSB As Long
' camIsQHY: the connected camera is a QHY (e.g. Orion All-in-One = QHY5LII-C): 8/16-bit, full frame, bin 1, no auto, no temperature
Dim Shared camIsQHY As Long
Dim Shared gainLo As Long, gainHi As Long, offHi As Long
Dim Shared hist(0 To 255) As Long
Dim Shared statCap As Long, statDrop As Long, statFps As Long, statTemp As Long, statPower As Long
Dim Shared lastStatT As Double

'---------------- recording ----------------
Dim Shared exeDir$, limitIdx As Long, wbR As Long, wbB As Long

'---------------- filter wheel ----------------
Dim Shared efwOpen As Long, efwSlots As Long, efwPos As Long, efwTarget As Long, efwName$, lastEfwT As Double
Dim Shared defFilt$(1 To 8), fwKey$, fwEditMode As Long, editSlot As Long, editBuf$
Dim Shared manualSlots As Long

'---------------- calibration (index 0 = dark, 1 = flat) ----------------
Dim Shared calNIdx As Long, calActive As Long, calType As Long, calDone As Long, calTotal As Long, calPath$
Dim Shared calOn(0 To 1) As Long, mLoaded(0 To 1) As Long, mW(0 To 1) As Long, mH(0 To 1) As Long
Dim Shared mExp(0 To 1) As Long, mGain(0 To 1) As Long, mTemp(0 To 1) As Long, mN(0 To 1) As Long, mFile$(0 To 1)

'---------------- GPU / sharpness / lucky imaging ----------------
Dim Shared gpuActive As Long, gpuName$, gpuMem As Long, gpuCC As Long, gpuDevs As Long, gpuTest$
Dim Shared showQual As Long, qHist(0 To 255) As Single, qN As Long
Dim Shared qLast As Single, qThresh As Single, qKept As Long, qRej As Long, qMs As Single

'---------------- live stacking ----------------
Dim Shared solveNoSave As Long
Dim Shared mntOpen As Long, mntAddr$, mntSpeed As Long, mntRA As Double, mntDec As Double, mntRASt As Long, mntDecSt As Long
Dim Shared mntTrack As Long, mntOk As Long, mntInfo$, mntMsg$, mntMsgSeq As Long, mntMsgT As Double
Dim Shared mntWant(1 To 2) As Long, mntHeld(1 To 2) As Long
'---------------- pointing (sync from plate solves) + GoTo ----------------
Const NCATMAX = 12000
Const CAT_LISTS = "Moon|Messier|Caldwell|Stars|Double stars|NGC|IC"
Const CAT_KEYS = "moon|messier|caldwell|star|double|ngc|ic"
Dim Shared catN As Long, catName$(1 To NCATMAX), catDesc$(1 To NCATMAX), catType$(1 To NCATMAX)
Dim Shared catRA(1 To NCATMAX) As Double, catDec(1 To NCATMAX) As Double, catMag(1 To NCATMAX) As Single
Dim Shared tgtIdx As Long, tgtUpOnly As Long, gotoCentre As Long, mntLST As Double
' syncOk = a plate solve has measured the HOME error (raIdx/decIdx) - see AxHA#
Dim Shared syncOk As Long, raIdx As Double, decIdx As Double
Dim Shared svMnt As Long, svA As Double, svD As Double, svLST As Double
' gotoTgt = the object being slewed to / centred (the picker can change meanwhile)
Dim Shared gotoState As Long, gotoA As Double, gotoD As Double, gotoTry As Long, gotoTgt As Long
Dim Shared settleT As Double
Dim Shared findOn As Long, findBuf$, catFile As Long
' capture names: capDir$/Object/night date/Filter/Object_Filter_2min_00001.fits
' (capDir$ saved in QBCap_capture.txt; objName$ = last GoTo target or typed)
Dim Shared capDir$, objName$, objOn As Long, objBuf$
'---------------- autoguiding (QBCap --guide runs the guide camera; ST-4 port) ----------------
Dim Shared guideMode As Long, gdFL As Long, gdAggRA As Long, gdAggDec As Long, gdMinMove As Long, gdMaxPulse As Long
Dim Shared gdCalIdx As Long, gdDither As Long, gdState As Long, gdPaused As Long, gdHave As Long, gdCalOk As Long, gdSettled As Long
Dim Shared gdX As Single, gdY As Single, gdSnr As Single, gdLX As Single, gdLY As Single, gdERA As Single, gdEDec As Single
Dim Shared gdRmsRA As Single, gdRmsDec As Single, gdRAms As Long, gdDecms As Long, gdMsg$, gdMsgSeq As Long, gdHist(0 To 599) As Single, gdHN As Long
Dim Shared gdCal$, gdST4 As Long, gdLinkMsg$
Dim Shared glAlive As Long, glState$, glLastT As Double, glAutoStop As Long
Dim Shared mntLunar As Long, lrnStep As Long, paTurn As Long, mntGoWait As Long, mntGoSeen As Long, mntGoT As Double
Dim Shared pmSat As Long
Dim Shared paCam As Long, pmOpen As Long, pmName$, pmW As Long, pmH As Long, pmFrames As Long, pmExp As Long, pmGain As Long, pmTried As Long
Dim Shared paStep As Long, paPending As Long, paAuto As Long, paLastT As Double, paRes As Long
Dim Shared paTot As Double, paAlt As Double, paAz As Double, paRot As Double, paAX As Single, paAY As Single, paPX As Single, paPY As Single, paPOk As Long
Dim Shared siteLat As Double, siteLon As Double, siteFile As Long
Dim Shared idxDir$
Dim Shared solveOn As Long, solveSrc As Long, solveHint As Long, solveNear As Long, haveLastPos As Long, lastRA As Double, lastDec As Double, lastField As Single, solveState As Long, solveMsg$, solveFile$, solveSaved$
Dim Shared solRA As Double, solDec As Double, solFW As Single, solFH As Single, solRot As Single, solScale As Single, solSecs As Single, solStars As Long
Dim Shared stkOn As Long, stkView As Long, stkHot As Long, stkAlign As Long, stkAuto As Long, stkMode As Long, stkMsg$
Dim Shared stkB0 As Long, stkW0 As Long, stkG0 As Long ' live-view stretch saved while stacking
Dim Shared gdLogPath$ ' guide data CSV (kept alive for the C side)
Dim Shared logHeld$, logHeldKey$, logHeldT As Double ' slider changes: only the final value is logged
Dim Shared skN As Long, skFail As Long, skSkip As Long, skStars As Long, skMatch As Long
Dim Shared skDx As Single, skDy As Single, skRot As Single, skRms As Single, skMs As Single, skExp As Single
Dim Shared recWritten As Long, recBuf As Long, recDrop As Long, recMB As Long, recPath$
Dim Shared mntRel(1 To 2) As Long, mntFail As Long
'---------------- remote control (file bridge) ----------------
'$Include: 'QBCapRemote.bi'
'---------------- sequencer (autopilot) ----------------
'$Include: 'QBCapSeq.bi'
'==================================================================
'  MAIN
'==================================================================
'--- fit the window to the desktop (taskbar + title bar need ~90 px)
SCR_H = _DesktopHeight - 90
If SCR_H > 800 Then SCR_H = 800
If SCR_H < 560 Then SCR_H = 560
IMG_H = SCR_H - IMG_Y - STAT_H
exeDir$ = Command$(0)
If InStr(exeDir$, "/") > 0 Then exeDir$ = Left$(exeDir$, _InStrRev(exeDir$, "/")) Else exeDir$ = ""
If Left$(exeDir$, 2) = "./" Then exeDir$ = Mid$(exeDir$, 3)
If Left$(exeDir$, 1) <> "/" Then
    If Right$(_StartDir$, 1) = "/" Then exeDir$ = _StartDir$ + exeDir$ Else exeDir$ = _StartDir$ + "/" + exeDir$
End If
If InStr(LCase$(Command$), "--guide") Then guideMode = -1: _Title "QBCap Guider"
If guideMode Then logFile$ = exeDir$ + "QBCap_guide.log" Else logFile$ = exeDir$ + "QBCap.log"

Screen _NewImage(SCR_W, SCR_H, 32)
_FullScreen , _Smooth
_ScreenMove 0, 0
_PrintMode _KeepBackground
viewImg = _NewImage(IMG_W, IMG_H, 32)
panelImg = _NewImage(PANEL_W, IMG_H, 32)
_PrintMode _KeepBackground , viewImg
_PrintMode _KeepBackground , panelImg
liveImg = _NewImage(IMG_W, IMG_H, 32)
liveMem = _MemImage(liveImg)

InitData
LoadScope
StartupMessage
If guideMode = 0 Then EfwConnect
LoadSite
LoadMountAddr
LoadIndexDir
LoadCapDir
If guideMode Then GuideInit Else RemoteInit: SeqInit

Do
    _Limit 60
    UpdateStats
    PollEfw
    PollMouseInput
    HandleKeys
    HandleMenuInput
    RemotePoll ' commands from QBCap_cmd.txt, status to QBCap_status.txt

    DrawImageView
    _Dest 0
    Cls , C_BG
    _PutImage (0, IMG_Y), viewImg
    DrawToolbar
    DrawPanel
    DrawStatusBar
    DrawMenuBar
    _Display
    RemoteAfterDisplay ' SCREENSHOT command: save what is on screen now
    LogStatus

    If _Exit Then quitFlag = -1
Loop Until quitFlag

If logHeld$ <> "" Then LogLine logHeld$ ' last slider value
ShutDown
If guideMode = 0 Then RemoteWriteStatus ' last status: equipment closed
_MemFree liveMem
System

' GoTo list: Messier objects (OpenNGC; M102 = NGC 5866) + bright stars.
' name, common name, type, RA (hours, J2000), Dec (deg, J2000), magnitude
CatalogData:
Data "M1","Crab Nebula","supernova rem.",5.57555,22.0145,8.4
Data "M2","","glob. cluster",21.55750,-0.8233,6.2
Data "M3","","glob. cluster",13.70312,28.3754,6.4
Data "M4","","glob. cluster",16.39317,-26.5255,5.4
Data "M5","","glob. cluster",15.30938,2.0827,6.0
Data "M6","Butterfly Cluster","open cluster",17.67243,-32.2542,4.2
Data "M7","Ptolemy's Cluster","open cluster",17.89755,-34.7928,3.3
Data "M8","Lagoon Nebula","nebula",18.06146,-24.3802,5.8
Data "M9","","glob. cluster",17.31994,-18.5162,8.4
Data "M10","","glob. cluster",16.95250,-4.0993,5.0
Data "M11","Amas de l'Ecu de Sobieski","open cluster",18.85166,-6.2700,5.8
Data "M12","","glob. cluster",16.78737,-1.9478,6.1
Data "M13","Hercules Globular Cluster","glob. cluster",16.69490,36.4613,5.8
Data "M14","","glob. cluster",17.62671,-3.2459,5.7
Data "M15","","glob. cluster",21.49955,12.1668,6.3
Data "M16","Eagle Nebula","nebula",18.31338,-13.8072,6.0
Data "M17","Checkmark Nebula","nebula",18.34642,-16.1715,7.0
Data "M18","","open cluster",18.33291,-17.1020,6.9
Data "M19","","glob. cluster",17.04380,-26.2679,5.6
Data "M20","Trifid Nebula","nebula",18.04503,-22.9719,8.5
Data "M21","","open cluster",18.07040,-22.4901,5.9
Data "M22","","glob. cluster",18.60672,-23.9034,6.2
Data "M23","","open cluster",17.95133,-18.9853,5.5
Data "M24","Small Sgr Star Cloud","star cloud",18.28226,-18.5146,4.5
Data "M25","","open cluster",18.52966,-19.1149,4.6
Data "M26","","open cluster",18.75518,-9.3836,8.9
Data "M27","Dumbbell Nebula","planetary",19.99344,22.7210,7.4
Data "M28","","glob. cluster",18.40914,-24.8698,6.9
Data "M29","","open cluster",20.39938,38.5077,6.6
Data "M30","","glob. cluster",21.67278,-23.1791,7.1
Data "M31","Andromeda Galaxy","galaxy",0.71232,41.2691,3.4
Data "M32","","galaxy",0.71162,40.8653,8.1
Data "M33","Triangulum Galaxy","galaxy",1.56414,30.6602,5.8
Data "M34","","open cluster",2.70206,42.7461,5.2
Data "M35","","open cluster",6.15141,24.3386,5.1
Data "M36","","open cluster",5.60493,34.1407,6.0
Data "M37","","open cluster",5.87176,32.5530,5.6
Data "M38","","open cluster",5.47847,35.8549,6.4
Data "M39","","open cluster",21.53009,48.4382,4.6
Data "M40","","double star",12.37114,58.0844,8.0
Data "M41","","open cluster",6.76665,-20.7542,4.5
Data "M42","Great Orion Nebula","cluster+nebula",5.58791,-5.3897,4.0
Data "M43","Mairan's Nebula","nebula",5.59205,-5.2675,9.0
Data "M44","Beehive","open cluster",8.67283,19.6721,3.1
Data "M45","Pleiades","open cluster",3.79128,24.1053,1.2
Data "M46","","open cluster",7.69634,-14.8100,6.1
Data "M47","","open cluster",7.60973,-14.4826,4.4
Data "M48","","open cluster",8.22866,-5.7504,5.8
Data "M49","","galaxy",12.49632,8.0005,8.3
Data "M50","","open cluster",7.04458,-8.3640,5.9
Data "M51","Whirlpool Galaxy","galaxy",13.49797,47.1952,8.4
Data "M52","","open cluster",23.41344,61.5932,6.9
Data "M53","","glob. cluster",13.21534,18.1691,7.8
Data "M54","","glob. cluster",18.91758,-30.4785,7.7
Data "M55","","glob. cluster",19.66650,-30.9621,6.5
Data "M56","","glob. cluster",19.27653,30.1845,8.4
Data "M57","Ring Nebula","planetary",18.89306,33.0286,8.8
Data "M58","","galaxy",12.62876,11.8182,10.3
Data "M59","","galaxy",12.70062,11.6470,9.6
Data "M60","","galaxy",12.72777,11.5527,8.8
Data "M61","","galaxy",12.36525,4.4736,10.2
Data "M62","","glob. cluster",17.02017,-30.1124,7.4
Data "M63","Sunflower Galaxy","galaxy",13.26370,42.0293,8.6
Data "M64","Black Eye Galaxy","galaxy",12.94546,21.6830,8.5
Data "M65","","galaxy",11.31553,13.0924,9.3
Data "M66","","galaxy",11.33749,12.9915,8.9
Data "M67","","open cluster",8.85559,11.8119,6.9
Data "M68","","glob. cluster",12.65778,-26.7430,8.0
Data "M69","","glob. cluster",18.52312,-32.3480,8.3
Data "M70","","glob. cluster",18.72018,-32.2919,9.1
Data "M71","","glob. cluster",19.89614,18.7784,6.1
Data "M72","","glob. cluster",20.89109,-12.5371,9.0
Data "M73","","Other",20.98221,-12.6355,8.9
Data "M74","","galaxy",1.61160,15.7837,9.3
Data "M75","","glob. cluster",20.10134,-21.9222,8.3
Data "M76","Barbell Nebula","planetary",1.70547,51.5755,10.1
Data "M77","","galaxy",2.71131,-0.0133,9.3
Data "M78","","nebula",5.77939,0.0793,8.0
Data "M79","","glob. cluster",5.40294,-24.5242,8.2
Data "M80","","glob. cluster",16.28403,-22.9751,7.3
Data "M81","Bode's Galaxy","galaxy",9.92588,69.0653,6.9
Data "M82","Cigar Galaxy","galaxy",9.93131,69.6794,8.3
Data "M83","Southern Pinwheel Galaxy","galaxy",13.61693,-29.8654,7.2
Data "M84","","galaxy",12.41771,12.8870,9.8
Data "M85","","galaxy",12.42336,18.1915,9.1
Data "M86","","galaxy",12.43659,12.9462,8.9
Data "M87","Virgo Galaxy","galaxy",12.51373,12.3911,9.0
Data "M88","","galaxy",12.53310,14.4204,10.3
Data "M89","","galaxy",12.59439,12.5563,10.1
Data "M90","","galaxy",12.61383,13.1629,9.5
Data "M91","","galaxy",12.59068,14.4963,11.0
Data "M92","","glob. cluster",17.28535,43.1365,6.5
Data "M93","","open cluster",7.74145,-23.8531,6.2
Data "M94","","galaxy",12.84807,41.1204,8.2
Data "M95","","galaxy",10.73269,11.7038,9.8
Data "M96","","galaxy",10.77937,11.8199,9.2
Data "M97","Owl Nebula","planetary",11.24659,55.0190,9.9
Data "M98","","galaxy",12.23008,14.9003,10.8
Data "M99","Coma Pinwheel","galaxy",12.31378,14.4165,9.8
Data "M100","","galaxy",12.38190,15.8218,9.5
Data "M101","","galaxy",14.05348,54.3489,7.9
Data "M102","Spindle Galaxy","galaxy",15.10819,55.7632,9.9
Data "M103","","open cluster",1.55606,60.6580,7.4
Data "M104","Sombrero Galaxy","galaxy",12.66651,-11.6231,8.6
Data "M105","","galaxy",10.79711,12.5816,9.3
Data "M106","","galaxy",12.31597,47.3040,9.3
Data "M107","","glob. cluster",16.54220,-13.0536,8.8
Data "M108","","galaxy",11.19194,55.6741,10.1
Data "M109","","galaxy",11.95999,53.3745,9.9
Data "M110","","galaxy",0.67280,41.6853,8.2
Data "Sirius","","star",6.75220,-16.7249,-1.4
Data "Vega","","star",18.61577,38.7858,0.0
Data "Arcturus","","star",14.26046,19.1680,-0.1
Data "Capella","","star",5.27821,45.9949,0.1
Data "Rigel","","star",5.24230,-8.2016,0.2
Data "Procyon","","star",7.65469,5.2175,0.4
Data "Betelgeuse","","star",5.91954,7.4071,0.5
Data "Altair","","star",19.84665,8.8711,0.8
Data "Aldebaran","","star",4.59871,16.5079,0.9
Data "Antares","","star",16.49012,-26.4322,1.1
Data "Spica","","star",13.41986,-11.1616,1.0
Data "Pollux","","star",7.75492,28.0259,1.2
Data "Fomalhaut","","star",22.96103,-29.6234,1.2
Data "Deneb","","star",20.69053,45.2803,1.2
Data "Regulus","","star",10.13941,11.9672,1.4
Data "Castor","","star",7.57651,31.8872,1.6
Data "Bellatrix","","star",5.41885,6.3496,1.6
Data "Elnath","","star",5.43821,28.6062,1.6
Data "Alnilam","","star",5.60356,-1.2019,1.7
Data "Alnitak","","star",5.67932,-1.9426,1.7
Data "Mintaka","","star",5.53345,-0.2991,2.2
Data "Alioth","","star",12.90058,55.9598,1.8
Data "Dubhe","","star",11.06199,61.7508,1.8
Data "Mirfak","","star",3.40540,49.8610,1.8
Data "Alkaid","","star",13.79225,49.3132,1.9
Data "Alhena","","star",6.62853,16.3988,1.9
Data "Polaris","","star",2.53196,89.2640,2.0
Data "Alpheratz","","star",0.13987,29.0893,2.1
Data "Hamal","","star",2.11966,23.4614,2.0
Data "Mizar","","star",13.39886,54.9252,2.2
Data "Kochab","","star",14.84503,74.1556,2.1
Data "Rasalhague","","star",17.58230,12.5584,2.1
Data "Albireo","","star",19.51202,27.9596,3.0
Data "Algol","","star",3.13615,40.9556,2.1
Data "Denebola","","star",11.81741,14.5712,2.1
Data "Eltanin","","star",17.94343,51.4887,2.2
Data "Enif","","star",21.73645,9.8750,2.4
Data "Schedar","","star",0.67517,56.5371,2.2
Data "Caph","","star",0.15346,59.1485,2.3
Data "Markab","","star",23.07938,15.2050,2.5
Data "Alphard","","star",9.45978,-8.6584,2.0
Data "Alphecca","","star",15.57819,26.7140,2.2
Data "Menkar","","star",3.03799,4.0892,2.5
Data "Almach","","star",2.06502,42.3294,2.1
Data "Sadr","","star",20.37047,40.2567,2.2
Data "Shaula","","star",17.56014,-37.1040,1.6
Data "Nunki","","star",18.92110,-26.2971,2.0
Data "Kaus Australis","","star",18.40284,-34.3855,1.8
Data "Adhara","","star",6.97710,-28.9721,1.5
Data "Saiph","","star",5.79594,-9.6696,2.1
Data "Zubenelgenubi","","star",14.84792,-16.0423,2.8
Data "Unukalhai","","star",15.73786,6.4259,2.6
Data "Algieba","","star",10.33304,19.8404,2.0
Data "END","","",0,0,0

'==================================================================
'  SETUP
'==================================================================
Sub InitData
    Dim i As Long, x As Long

    camName$(1) = "ASI174": camW(1) = 1936: camH(1) = 1216: camPix(1) = 5.86
    camName$(2) = "ASI178": camW(2) = 3096: camH(2) = 2080: camPix(2) = 2.4
    camName$(3) = "ASI1600": camW(3) = 4656: camH(3) = 3520: camPix(3) = 3.8
    ' Orion StarShoot G3 (libssg3.so): 16-bit, full frame, bin 1 only
    camName$(4) = "G3Mono": camW(4) = 752: camH(4) = 582: camPix(4) = 8.6
    camName$(5) = "G3Color": camW(5) = 752: camH(5) = 582: camPix(5) = 8.6
    ' standard Linux USB camera (V4L2) with raw 8-bit output, e.g. the SN9C201 + MI1310 Moon camera
    camName$(6) = "USBCam": camW(6) = 1280: camH(6) = 1024: camPix(6) = 3.6
    ' QHY camera through libqhyccd.so, e.g. the Orion StarShoot All-in-One (QHY5LII-C inside)
    camName$(7) = "QHYCam": camW(7) = 1280: camH(7) = 960: camPix(7) = 3.75
    expMaxMs = EXP_MAX_MS

    scopeName$(1) = "203mm f/10 (2032mm)": scopeFL(1) = 2032
    scopeName$(2) = "10in (1200mm)": scopeFL(2) = 1200
    scopeName$(3) = "8in (1000mm)": scopeFL(3) = 1000

    ' defaults = Russell's 8-slot wheel; each wheel's own names load from QBCap_filters.txt
    defFilt$(1) = "IR": defFilt$(2) = "SII": defFilt$(3) = "HA": defFilt$(4) = "HB"
    defFilt$(5) = "Nebula": defFilt$(6) = "Neodymium": defFilt$(7) = "Nebula": defFilt$(8) = "Dark"
    For i = 1 To NFILT: filtName$(i) = defFilt$(i): Next
    fwKey$ = "manual"
    manualSlots = NFILT
    ' with no wheel on USB, label frames using the last wheel that was connected
    LoadLastWheel

    grpName$(1) = "Camera"
    grpName$(2) = "Capture Format & Area"
    grpName$(3) = "Camera Controls"
    grpName$(4) = "Thermal"
    grpName$(5) = "Filter Wheel (EFW)"
    grpName$(6) = "Display Stretch"
    grpName$(7) = "Telescope"
    grpName$(8) = "GPU / Processing"
    grpName$(9) = "Calibration (darks / flats)"
    grpName$(10) = "Live Stack"
    grpName$(11) = "Plate Solve"
    grpName$(12) = "Polar Align"
    grpName$(13) = "Mount"
    grpName$(14) = "Guider"
    grpName$(15) = "Remote control"
    grpName$(16) = "Sequencer (autopilot)"
    For i = 1 To NGRP: grpOpen(i) = -1: Next

    menuTitle$(1) = "File": menuItems$(1) = "Open Capture Folder|Capture Folder...|Index Folder...|Settings|Exit"
    menuTitle$(2) = "Cameras": menuItems$(2) = "ASI174|ASI178|ASI1600|G3Mono|G3Color|USBCam|QHYCam|Disconnect"
    menuTitle$(3) = "Capture": menuItems$(3) = "Start Live|Start Capture|Stop|Snapshot|Capture Dark|Capture Flat"
    menuTitle$(4) = "View": menuItems$(4) = "Histogram|Reticule|Zoom Fit|Zoom 100%"
    menuTitle$(5) = "Tools": menuItems$(5) = "Focus Assist|Lucky Imaging|Live Stack|Polar Align|Plate Solve|Seeing Monitor|Mount|Guider|Sequencer|Remote Control"
    menuTitle$(6) = "Help": menuItems$(6) = "About QBCap"
    x = 4
    For i = 1 To NMENU
        menuX(i) = x
        x = x + Len(menuTitle$(i)) * 8 + 16
    Next

    camSel = 1
    fmtIdx = 1: binIdx = 1: roiIdx = 1: outIdx = 1
    expMs = 10: gainV = 150: offsetV = 10: usbBW = 80
    gainLo = 0: gainHi = 600: offHi = 100
    coolTarget = -10
    blackV = 0: whiteV = 255: gammaV = 100
    stkB0 = 0: stkW0 = 255: stkG0 = 100
    scopeSel = 2 ' 10in 1200mm - the choice is remembered in QBCap_scope.txt (LoadScope)
    gpuDev = 1: luckyPct = 25: stackIdx = 1
    zoomFit = -1: zoomPct = 100
    limitIdx = 1: wbR = 100: wbB = 100
    calNIdx = 2
    stkHot = -1: stkView = -1: stkAlign = -1
    solveSrc = 1: solveHint = 1: solveNear = -1
    paCam = 2: pmExp = 1000: pmGain = 30 ' polar alignment = PoleMaster
    mntSpeed = 3: mntAddr$ = "192.168.4.1"
    gotoCentre = -1: tgtUpOnly = -1: tgtIdx = 43: gotoTgt = 43: glAutoStop = -1
    LoadCatalog
End Sub

'==================================================================
'  INPUT
'==================================================================
Sub PollMouseInput
    Dim pressSeen As Long
    mWheel = 0
    pressSeen = 0
    Do While _MouseInput
        mWheel = mWheel + _MouseWheel
        If _MouseButton(1) Then pressSeen = -1
    Loop
    mx = _MouseX: my = _MouseY
    mDown = _MouseButton(1)
    mClick = 0
    ' pressSeen catches a quick tap that was pressed AND released within one frame
    If pressSeen And (mPrev = 0) Then mClick = -1
    mPrev = mDown
    wheelUsed = 0
End Sub

Sub HandleKeys
    Dim k$
    k$ = InKey$
    If editSlot > 0 Then EditKey k$: Exit Sub
    ' Esc in filter edit mode leaves edit mode (it used to quit QBCap)
    If fwEditMode And k$ = Chr$(27) Then
        fwEditMode = 0
        statusMsg$ = "Filter names saved for wheel '" + fwKey$ + "'"
        Exit Sub
    End If
    If findOn Then FindKey k$: Exit Sub
    If objOn Then ObjKey k$: Exit Sub
    If sqEditOn Then SeqKey k$: Exit Sub
    k$ = UCase$(k$)
    Select Case k$
        Case Chr$(27)
            If menuOpen Then menuOpen = 0 Else QuitRequest
        Case " "
            DoAction "Live"
        Case "H"
            DoAction "Histogram"
        Case "R"
            DoAction "Reticule"
    End Select
End Sub

Sub HandleMenuInput
    Dim i As Long, t As Long, w As Long, n As Long, dw As Long, it As Long
    t = 0
    If my >= 0 And my < MENU_H Then
        For i = 1 To NMENU
            w = Len(menuTitle$(i)) * 8 + 16
            If mx >= menuX(i) And mx < menuX(i) + w Then t = i
        Next
    End If

    If mClick Then
        If t > 0 Then
            If menuOpen = t Then menuOpen = 0 Else menuOpen = t
            mClick = 0
        ElseIf menuOpen > 0 Then
            n = ItemCount&(menuItems$(menuOpen))
            dw = MenuDropW&(menuOpen)
            If mx >= menuX(menuOpen) And mx < menuX(menuOpen) + dw And my >= MENU_H And my < MENU_H + n * 20 Then
                it = (my - MENU_H) \ 20 + 1
                i = menuOpen
                menuOpen = 0
                DoAction ItemOf$(menuItems$(i), it)
            Else
                menuOpen = 0
            End If
            mClick = 0
        End If
    ElseIf menuOpen > 0 And t > 0 Then
        menuOpen = t
    End If
End Sub

'==================================================================
'  ACTION DISPATCHER  -  every button / menu item lands here
'==================================================================
Sub DoAction (act$)
    Dim m$, i As Long
    Select Case act$
        Case "Connect"
            If camConn Then qcClose: camConn = 0: liveOn = 0: recOn = 0
            If qcOpen&(camSel) = 0 Then camConn = camSel
        Case "ASI174"
            camSel = 1: DoAction "Connect"
        Case "ASI178"
            camSel = 2: DoAction "Connect"
        Case "ASI1600"
            camSel = 3: DoAction "Connect"
        Case "G3Mono"
            camSel = 4: DoAction "Connect"
        Case "G3Color"
            camSel = 5: DoAction "Connect"
        Case "USBCam"
            camSel = 6: DoAction "Connect"
        Case "QHYCam"
            camSel = 7: DoAction "Connect"
        Case "Disconnect"
            If camConn Then qcClose: camConn = 0: liveOn = 0: recOn = 0

        Case "Live", "Start Live"
            If camConn = 0 Then
                statusMsg$ = "No camera connected - pick one in the Camera panel or the Cameras menu."
            ElseIf liveOn Then
                If recOn Then qcRecordStop: recOn = 0
                qcStop: liveOn = 0
            Else
                If qcStartVideo& = 0 Then liveOn = -1
            End If
        Case "Capture", "Start Capture"
            If camConn = 0 Then
                statusMsg$ = "No camera connected."
            ElseIf recOn Then
                qcRecordStop: recOn = 0
            Else
                If liveOn = 0 Then DoAction "Live"
                If liveOn Then
                    If outIdx = 1 Then
                        recPath$ = CapBase$ + "_" + ClockTag$ + ".ser"
                    Else
                        recPath$ = CapBase$ ' FITS: the library adds _00001.fits, _00002.fits ...
                    End If
                    LogLine "  capture -> " + recPath$
                    If qcRecordStart&(recPath$, outIdx - 1) = 0 Then recOn = -1
                End If
            End If
        Case "Stop"
            m$ = ""
            If recOn Then qcRecordStop: m$ = statusMsg$
            If liveOn Then qcStop
            recOn = 0: liveOn = 0
            If Len(m$) Then statusMsg$ = m$
        Case "Snapshot"
            If camConn Then qcSnapshot CapBase$ + "_snap_" + ClockTag$ + ".fits" Else statusMsg$ = "No camera connected."
        Case "Dark", "Capture Dark"
            StartMaster 0
        Case "Flat", "Capture Flat"
            StartMaster 1

        Case "Histogram"
            showHist = Not showHist
        Case "Reticule"
            showRet = Not showRet
        Case "Fit", "Zoom Fit"
            zoomFit = -1
        Case "100%", "Zoom 100%"
            zoomFit = 0: zoomPct = 100
        Case "+"
            zoomFit = 0: zoomPct = zoomPct * 2: If zoomPct > 400 Then zoomPct = 400
        Case "-"
            zoomFit = 0: zoomPct = zoomPct \ 2: If zoomPct < 25 Then zoomPct = 25

        Case "Focus", "Focus Assist", "Seeing Monitor"
            showQual = Not showQual
            QualityOnOff
            If showQual Then statusMsg$ = "Sharpness graph on - higher = sharper (use it to focus or to watch the seeing)" Else statusMsg$ = "Sharpness graph off"
        Case "Lucky", "Lucky Imaging"
            luckyOn = Not luckyOn
            qcLuckyEnable luckyOn, luckyPct
        Case "Live Stack"
            If stkOn Then StopStack Else StartStack
        Case "Polar Align"
            grpOpen(12) = -1
            For i = 2 To 11: grpOpen(i) = 0: Next ' make room: polar align panel in view
            panelScroll = 0
            ' polar alignment uses the PoleMaster: connect it if it is plugged in
            If pmOpen = 0 Then
                If qc_pm_open& = 0 Then PmConnected Else statusMsg$ = "PoleMaster: " + LibErr$
            End If
            If paStep = 0 And pmOpen Then statusMsg$ = "Polar align with the " + pmName$ + ": stars visible? then Step 1."
        Case "Plate Solve"
            If solveOn Then qc_solve_cancel Else StartSolve
        Case "Guider"
            grpOpen(14) = -1: panelScroll = 0
            If guideMode = 0 And glAlive = 0 Then OpenGuiderWindow
        Case "Mount"
            grpOpen(13) = -1
            For i = 2 To 12: grpOpen(i) = 0: Next ' make room: mount panel in view
            panelScroll = 0
            If mntOpen = 0 Then MountConnect

        Case "Sequencer"
            For i = 1 To 15: grpOpen(i) = 0: Next ' make room: sequencer in view
            grpOpen(16) = -1
            panelScroll = 15 * 28 ' its header at the top
        Case "Remote Control"
            grpOpen(15) = -1
            For i = 2 To 14: grpOpen(i) = 0: Next ' make room: remote panel in view
            panelScroll = 0
        Case "Init GPU"
            GpuInit
        Case "Auto Stretch"
            AutoStretch
        Case "Calibrate"
            If efwOpen Then
                If qc_efw_calibrate& = 0 Then
                    efwTarget = 0: fwSlot = 0
                    statusMsg$ = "Calibrating filter wheel..."
                Else
                    statusMsg$ = LibErr$
                End If
            Else
                EfwConnect
            End If

        Case "Open Capture Folder"
            MkDir_Safe capDir$
            Shell _DontWait "xdg-open " + Chr$(34) + capDir$ + Chr$(34)
            statusMsg$ = "Opened " + capDir$
        Case "Capture Folder..."
            PickCapDir
        Case "Index Folder..."
            PickIndexDir
        Case "Settings"
            StubCall "settings dialog / INI"
        Case "Exit"
            quitFlag = -1
        Case "About QBCap"
            statusMsg$ = "QBCap v0.12 - QB64-PE + libqbcap.so + libqbgpu.so (capture, recording, EFW, darks/flats, lucky imaging, live stacking, plate solving, polar alignment, mount control, remote control)."
        Case Else
            statusMsg$ = "Unhandled action: " + act$
    End Select
End Sub

Function StampName$
    Dim d$, t$, c$
    d$ = Date$
    t$ = Time$
    If camConn > 0 Then c$ = camName$(camConn) Else c$ = "File" ' no camera: solving a file
    StampName$ = c$ + "_" + Right$(d$, 4) + "-" + Left$(d$, 2) + "-" + Mid$(d$, 4, 2) + "_" + Left$(t$, 2) + Mid$(t$, 4, 2) + Right$(t$, 2)
End Function

Function ShortName$ (p$)
    ' the part of a full path below the capture folder, for the status bar
    Dim k As Long
    If Left$(p$, Len(capDir$) + 1) = capDir$ + "/" Then
        ShortName$ = Mid$(p$, Len(capDir$) + 2)
    Else
        k = InStr(p$, "captures/")
        If k > 0 Then ShortName$ = Mid$(p$, k) Else ShortName$ = p$
    End If
End Function

'------------------------------------------------------------------
' capture file names:  capDir$/M57/2026-10-13/Red/M57_Red_2min_00001.fits
'------------------------------------------------------------------
' letters, digits, - and _ only ("NGC 7000" -> "NGC7000")
Function CleanName$ (s$)
    Dim i As Long, c$, o$
    For i = 1 To Len(s$)
        c$ = Mid$(s$, i, 1)
        Select Case Asc(c$)
            Case 48 To 57, 65 To 90, 97 To 122, 45, 95: o$ = o$ + c$
            Case 32
            Case Else: o$ = o$ + "-"
        End Select
    Next
    CleanName$ = o$
End Function

Function ObjTag$
    Dim s$
    s$ = CleanName$(objName$)
    If s$ = "" Then s$ = "Object"
    ObjTag$ = s$
End Function

' filter name from the wheel slot ("" = no wheel / no filter)
Function FiltTag$
    If fwSlot > 0 Then FiltTag$ = CleanName$(filtName$(fwSlot)) Else FiltTag$ = ""
End Function

' exposure: 2min, 90s, 1.5s, 500ms
Function ExpTag$
    If expMs >= 60000 And (expMs Mod 60000) = 0 Then
        ExpTag$ = I2S$(expMs \ 60000) + "min"
    ElseIf expMs >= 1000 And (expMs Mod 1000) = 0 Then
        ExpTag$ = I2S$(expMs \ 1000) + "s"
    ElseIf expMs >= 1000 Then
        ExpTag$ = Fmt1$(CSng(expMs / 1000)) + "s"
    Else
        ExpTag$ = I2S$(expMs) + "ms"
    End If
End Function

' time of day for SER / snapshot names: 213045
Function ClockTag$
    Dim t$
    t$ = Time$
    ClockTag$ = Left$(t$, 2) + Mid$(t$, 4, 2) + Right$(t$, 2)
End Function

' the night's date: after midnight (before noon) it still counts as the
' evening the session started, so one night stays in one folder
Function NightDate$
    Dim d$, mo As Long, dy As Long, yr As Long, dim1 As Long
    d$ = Date$ ' mm-dd-yyyy
    mo = Val(Left$(d$, 2)): dy = Val(Mid$(d$, 4, 2)): yr = Val(Right$(d$, 4))
    If Val(Left$(Time$, 2)) < 12 Then
        dy = dy - 1
        If dy < 1 Then
            mo = mo - 1
            If mo < 1 Then mo = 12: yr = yr - 1
            Select Case mo
                Case 4, 6, 9, 11: dim1 = 30
                Case 2
                    dim1 = 28
                    If (yr Mod 4 = 0 And yr Mod 100 <> 0) Or yr Mod 400 = 0 Then dim1 = 29
                Case Else: dim1 = 31
            End Select
            dy = dim1
        End If
    End If
    NightDate$ = I2S$(yr) + "-" + Right$("0" + I2S$(mo), 2) + "-" + Right$("0" + I2S$(dy), 2)
End Function

' folder for the next capture (created by the library when it writes)
Function CapFolder$
    Dim f$
    f$ = capDir$ + "/" + ObjTag$ + "/" + NightDate$
    If FiltTag$ <> "" Then f$ = f$ + "/" + FiltTag$
    CapFolder$ = f$
End Function

' path + name without the frame number; a second batch with the same
' object / filter / exposure gets _run2, _run3 ... so nothing is overwritten
Function CapBase$
    Dim b$, n As Long, nm$
    nm$ = ObjTag$
    If FiltTag$ <> "" Then nm$ = nm$ + "_" + FiltTag$
    nm$ = nm$ + "_" + ExpTag$
    b$ = CapFolder$ + "/" + nm$
    n = 1
    Do While _FileExists(b$ + "_00001.fits")
        n = n + 1
        b$ = CapFolder$ + "/" + nm$ + "_run" + I2S$(n)
    Loop
    CapBase$ = b$
End Function

Sub LoadCapDir
    ' QBCap_capture.txt: "folder = /path" - where captures go.
    ' Default: the "captures" folder next to QBCap. File > Capture Folder... sets it.
    Dim f$, ff As Long, l$, k As Long
    capDir$ = exeDir$ + "captures"
    f$ = exeDir$ + "QBCap_capture.txt"
    If _FileExists(f$) Then
        ff = FreeFile
        Open f$ For Input As #ff
        Do While Not EOF(ff)
            Line Input #ff, l$
            l$ = LTrim$(RTrim$(l$))
            k = InStr(l$, "=")
            If k > 0 And Left$(l$, 1) <> "#" Then
                If LCase$(RTrim$(Left$(l$, k - 1))) = "folder" Then capDir$ = LTrim$(Mid$(l$, k + 1))
            End If
        Loop
        Close #ff
    Else
        SaveCapDir
    End If
    If Len(capDir$) > 1 And Right$(capDir$, 1) = "/" Then capDir$ = Left$(capDir$, Len(capDir$) - 1)
    ' external drive not plugged in? fall back so nothing is lost
    If _DirExists(capDir$) = 0 Then
        MkDir_Safe exeDir$ + "captures"
        If _DirExists(capDir$) = 0 Then
            LogLine "  capture folder " + capDir$ + " not found - using " + exeDir$ + "captures this time"
            statusMsg$ = "Capture folder not found (drive unplugged?) - saving to the captures folder next to QBCap."
            capDir$ = exeDir$ + "captures"
        End If
    End If
End Sub

Sub SaveCapDir
    Dim ff As Long
    ff = FreeFile
    Open exeDir$ + "QBCap_capture.txt" For Output As #ff
    Print #ff, "# QBCap capture folder - files go in <folder>/<object>/<night date>/<filter>/"
    Print #ff, "# (spaces in the path are fine; set from File > Capture Folder...)"
    Print #ff, "folder = " + capDir$
    Close #ff
End Sub

Sub PickCapDir
    Dim d$
    If recOn Then statusMsg$ = "Stop the capture first.": Exit Sub
    d$ = _SelectFolderDialog$("Folder for captures", capDir$)
    If d$ = "" Then statusMsg$ = "Capture folder unchanged: " + capDir$: Exit Sub
    If Len(d$) > 1 And Right$(d$, 1) = "/" Then d$ = Left$(d$, Len(d$) - 1)
    capDir$ = d$
    SaveCapDir
    statusMsg$ = "Captures go to " + capDir$ + "  (saved in QBCap_capture.txt)"
End Sub

Sub ObjKey (k$)
    Select Case k$
        Case ""
        Case Chr$(13)
            objOn = 0
            objName$ = _Trim$(objBuf$)
            statusMsg$ = "Object name: " + ObjTag$
        Case Chr$(27)
            objOn = 0
            statusMsg$ = "Object name unchanged"
        Case Chr$(8)
            If Len(objBuf$) > 0 Then objBuf$ = Left$(objBuf$, Len(objBuf$) - 1)
        Case Else
            If Len(k$) = 1 And Asc(k$) >= 32 And Asc(k$) < 127 And Len(objBuf$) < 24 Then objBuf$ = objBuf$ + k$
    End Select
End Sub

Sub MkDir_Safe (d$)
    If _DirExists(d$) = 0 Then MkDir d$
End Sub

'==================================================================
'  DRAWING - image area
'==================================================================
Sub DrawImageView
    Dim sc As Single, dw As Long, dh As Long, dx As Long, dy As Long
    Dim sx As Long, sy As Long, sw As Long, sh As Long, cx As Long, cy As Long, r As Long, g$, s$

    _Dest viewImg
    Cls , _RGB32(8, 8, 10)
    cx = IMG_W \ 2: cy = IMG_H \ 2

    If PmView% And (pmW > 0) And (pmH > 0) Then
        '--- PoleMaster feed (polar alignment)
        sc = IMG_W / pmW
        If IMG_H / pmH < sc Then sc = IMG_H / pmH
        dw = pmW * sc: dh = pmH * sc: dx = (IMG_W - dw) \ 2: dy = (IMG_H - dh) \ 2
        sx = 0: sy = 0: sw = pmW: sh = pmH
        g$ = "PM" + I2S$(dw) + "," + I2S$(dh)
        If g$ <> lastGeom$ Then
            _Dest liveImg: Cls , _RGB32(8, 8, 10): _Dest viewImg
            lastGeom$ = g$: forceDraw = -1
        End If
        r = qc_pm_preview&(liveMem.OFFSET, IMG_W, IMG_H, dx, dy, dw, dh, sx, sy, sw, sh, -(forceDraw <> 0))
        forceDraw = 0
        _PutImage (0, 0), liveImg
        Color _RGB32(120, 200, 255): _PrintString (10, 8), "POLEMASTER  " + pmName$ + "   frame " + I2S$(pmFrames) + "   " + I2S$(pmExp) + " ms  gain " + I2S$(pmGain)
        If pmSat Then Color C_REC: _PrintString (10, 28), "SATURATED - lower the exposure / gain (night sky: about 1-2 s, gain 30-60)"
        DrawPolarOverlay dx, dy, dw, dh, sx, sy, sw, sh
        Exit Sub
    End If

    If camConn And (frW > 0) And (frH > 0) Then
        '--- work out which part of the frame is visible and where it goes
        If zoomFit Then
            sc = IMG_W / frW
            If IMG_H / frH < sc Then sc = IMG_H / frH
        Else
            sc = zoomPct / 100
        End If
        dw = frW * sc: dh = frH * sc
        If dw <= IMG_W Then
            dx = (IMG_W - dw) \ 2: sx = 0: sw = frW
        Else
            dx = 0: dw = IMG_W: sw = IMG_W / sc: sx = (frW - sw) \ 2
        End If
        If dh <= IMG_H Then
            dy = (IMG_H - dh) \ 2: sy = 0: sh = frH
        Else
            dy = 0: dh = IMG_H: sh = IMG_H / sc: sy = (frH - sh) \ 2
        End If

        '--- geometry changed (zoom / format)? clear and force a redraw
        g$ = I2S$(dx) + "," + I2S$(dy) + "," + I2S$(dw) + "," + I2S$(dh) + "," + I2S$(sx) + "," + I2S$(sy) + "," + I2S$(sw) + "," + I2S$(sh)
        If g$ <> lastGeom$ Then
            _Dest liveImg: Cls , _RGB32(8, 8, 10): _Dest viewImg
            lastGeom$ = g$: forceDraw = -1
        End If

        '--- C draws the newest frame straight into liveImg
        r = qc_get_preview&(liveMem.OFFSET, IMG_W, IMG_H, dx, dy, dw, dh, sx, sy, sw, sh, -(forceDraw <> 0))
        forceDraw = 0
        If r = 1 Then r = qc_get_histogram&(_Offset(hist(0)))
        _PutImage (0, 0), liveImg

        If liveOn Then
            Color C_OK: _PrintString (10, 8), "LIVE  " + Fmt1$(statFps / 10) + " fps   " + I2S$(frW) + " x " + I2S$(frH)
            If stkView And skN > 0 Then Color _RGB32(255, 200, 80): _PrintString (10, 28), "STACK  " + I2S$(skN) + " frames   " + HMS$(skExp)
            If statCap = 0 Then Color C_TXT: _PrintString (10, 28), "Waiting for first frame..."
        Else
            Color C_DIM: _PrintString (10, 8), "STOPPED  -  press Live (or Space)"
        End If
        If recOn Then
            Circle (IMG_W - 70, 16), 6, C_REC
            Paint (IMG_W - 70, 16), C_REC, C_REC
            Color C_REC: _PrintString (IMG_W - 58, 8), "REC"
        End If
        If zoomFit Then s$ = "Zoom: Fit" Else s$ = "Zoom: " + I2S$(zoomPct) + "%"
        Color C_DIM: _PrintString (IMG_W - Len(s$) * 8 - 10, IMG_H - 22), s$
    Else
        s$ = "No camera connected"
        Color C_TXT: _PrintString (cx - Len(s$) * 4, cy - 20), s$
        s$ = "Choose a camera in the Camera panel or the Cameras menu"
        Color C_DIM: _PrintString (cx - Len(s$) * 4, cy + 4), s$
    End If

    If showRet Then
        Line (cx, 0)-(cx, IMG_H - 1), _RGBA32(255, 80, 80, 150)
        Line (0, cy)-(IMG_W - 1, cy), _RGBA32(255, 80, 80, 150)
        Circle (cx, cy), 50, _RGBA32(255, 80, 80, 150)
        Circle (cx, cy), 120, _RGBA32(255, 80, 80, 150)
        Circle (cx, cy), 240, _RGBA32(255, 80, 80, 150)
    End If

    If showHist Then DrawHistogram
    If showQual Or (luckyOn And recOn) Then DrawQualityGraph
    If camConn And (frW > 0) And paCam = 1 Then DrawPolarOverlay dx, dy, dw, dh, sx, sy, sw, sh
    If guideMode And camConn <> 0 And frW > 0 Then DrawGuideOverlay dx, dy, dw, dh, sx, sy, sw, sh
End Sub

Sub DrawHistogram
    Dim hx As Long, hy As Long, hh As Long, i As Long, h As Long, maxV As Long
    hh = 120: hx = 14: hy = IMG_H - hh - 34
    Line (hx - 6, hy - 22)-(hx + 270, hy + hh + 6), _RGBA32(0, 0, 0, 200), BF
    Line (hx - 6, hy - 22)-(hx + 270, hy + hh + 6), C_ACCDIM, B
    Color C_TXT: _PrintString (hx, hy - 19), "Histogram  (raw, sqrt scale)"
    maxV = 0
    For i = 1 To 254
        If hist(i) > maxV Then maxV = hist(i)
    Next
    If maxV > 0 Then
        For i = 0 To 255
            h = Sqr(hist(i) / maxV) * (hh - 6)
            If h > hh - 6 Then h = hh - 6
            Line (hx + 6 + i, hy + hh)-(hx + 6 + i, hy + hh - h), _RGB32(160, 170, 200)
        Next
    End If
    If hist(255) > 0 Then Color C_REC: _PrintString (hx + 226, hy - 19), "CLIP"
    Line (hx + 6 + blackV, hy)-(hx + 6 + blackV, hy + hh), _RGB32(255, 90, 90)
    Line (hx + 6 + whiteV, hy)-(hx + 6 + whiteV, hy + hh), _RGB32(90, 255, 90)
End Sub

'==================================================================
'  DRAWING - bars
'==================================================================
Sub DrawMenuBar
    Dim i As Long, w As Long, n As Long, dw As Long, it As Long, yy As Long, x0 As Long, s$
    _Dest 0
    Line (0, 0)-(SCR_W - 1, MENU_H - 1), C_BAR, BF
    For i = 1 To NMENU
        w = Len(menuTitle$(i)) * 8 + 16
        If menuOpen = i Then Line (menuX(i), 0)-(menuX(i) + w - 1, MENU_H - 1), C_BTNON, BF
        Color C_TXT: _PrintString (menuX(i) + 8, 3), menuTitle$(i)
    Next
    s$ = "QBCap v0.12"
    Color C_DIM: _PrintString (SCR_W - Len(s$) * 8 - 8, 3), s$
    RemoteBadge SCR_W - Len(s$) * 8 - 32

    If menuOpen > 0 Then
        n = ItemCount&(menuItems$(menuOpen))
        dw = MenuDropW&(menuOpen)
        x0 = menuX(menuOpen)
        Line (x0, MENU_H)-(x0 + dw - 1, MENU_H + n * 20 - 1), C_GRP, BF
        Line (x0, MENU_H)-(x0 + dw - 1, MENU_H + n * 20 - 1), C_ACCDIM, B
        For it = 1 To n
            yy = MENU_H + (it - 1) * 20
            If mx >= x0 And mx < x0 + dw And my >= yy And my < yy + 20 Then Line (x0 + 1, yy)-(x0 + dw - 2, yy + 19), C_BTNHOT, BF
            Color C_TXT: _PrintString (x0 + 12, yy + 2), ItemOf$(menuItems$(menuOpen), it)
        Next
    End If
End Sub

Function MenuDropW& (m As Long)
    Dim i As Long, n As Long, w As Long
    n = ItemCount&(menuItems$(m))
    w = 140
    For i = 1 To n
        If Len(ItemOf$(menuItems$(m), i)) * 8 + 32 > w Then w = Len(ItemOf$(menuItems$(m), i)) * 8 + 32
    Next
    MenuDropW& = w
End Function

Sub DrawToolbar
    Dim x As Long, y As Long
    _Dest 0
    UiBegin 0, 0, SCR_W, SCR_H
    Line (0, MENU_H)-(SCR_W - 1, IMG_Y - 1), C_BAR2, BF
    y = MENU_H + 5: x = 6

    If guideMode Then
        If TB%(x, y, "Live", liveOn) Then DoAction "Live"
        If TB%(x, y, "Stop", 0) Then DoAction "Stop"
        TBSep x, y
        If TB%(x, y, "Histogram", showHist) Then DoAction "Histogram"
        If TB%(x, y, "Fit", zoomFit) Then DoAction "Fit"
        If TB%(x, y, "100%", 0) Then DoAction "100%"
        If TB%(x, y, "-", 0) Then DoAction "-"
        If TB%(x, y, "+", 0) Then DoAction "+"
        TBSep x, y
        If gdState = 2 Then
            If TB%(x, y, "Stop guiding", 2) Then GuideStopNow
        Else
            If TB%(x, y, "Guide", 0) Then GuideStartNow
        End If
        Color C_ACC: _PrintString (SCR_W - 200, y + 5), "GUIDER WINDOW"
        QuitButton y
        Exit Sub
    End If
    If TB%(x, y, "Live", liveOn) Then DoAction "Live"
    If TB%(x, y, "Capture", -2 * recOn) Then DoAction "Capture"
    If TB%(x, y, "Stop", 0) Then DoAction "Stop"
    If TB%(x, y, "Snapshot", 0) Then DoAction "Snapshot"
    If TB%(x, y, "Dark", 0) Then DoAction "Dark"
    If TB%(x, y, "Flat", 0) Then DoAction "Flat"
    TBSep x, y
    If TB%(x, y, "Histogram", showHist) Then DoAction "Histogram"
    If TB%(x, y, "Reticule", showRet) Then DoAction "Reticule"
    If TB%(x, y, "Fit", zoomFit) Then DoAction "Fit"
    If TB%(x, y, "100%", 0) Then DoAction "100%"
    If TB%(x, y, "-", 0) Then DoAction "-"
    If TB%(x, y, "+", 0) Then DoAction "+"
    TBSep x, y
    If TB%(x, y, "Focus", showQual) Then DoAction "Focus"
    If TB%(x, y, "Lucky", luckyOn) Then DoAction "Lucky"
    If TB%(x, y, "Live Stack", stkOn) Then DoAction "Live Stack"
    If TB%(x, y, "Polar Align", -(paStep > 0)) Then DoAction "Polar Align"
    If TB%(x, y, "Plate Solve", solveOn) Then DoAction "Plate Solve"
    TBSep x, y
    If TB%(x, y, "Mount", mntOpen) Then DoAction "Mount"
    QuitButton y
End Sub

' Quit button, right end of the toolbar. First click asks, second click
' (within 5 s) quits; the shutdown at the end of the program cleans up.
Sub QuitButton (y As Long)
    Dim qx As Long, t As Double
    t = Timer(.001)
    If quitAsk And (t - quitAskT > 5 Or t < quitAskT) Then quitAsk = 0
    If quitAsk Then
        qx = SCR_W - 6 - (Len("Sure") * 8 + 16)
        If TB%(qx, y, "Sure", 2) Then quitFlag = -1
    Else
        qx = SCR_W - 6 - (Len("Quit") * 8 + 16)
        If TB%(qx, y, "Quit", 0) Then QuitRequest
    End If
End Sub

Sub QuitRequest
    Dim t As Double
    t = Timer(.001)
    If quitAsk And t - quitAskT <= 5 And t >= quitAskT Then quitFlag = -1: Exit Sub
    quitAsk = -1: quitAskT = t
    statusMsg$ = "Quit? Click Sure (or Esc again) within 5 s - stops recording, solver, mount, camera."
End Sub

' Clean shutdown, in a safe order, with each step in QBCap.log.
Sub ShutDown
    Dim t As Double, i As Long
    _Dest 0
    Cls , C_BG
    Color C_TXT
    _PrintString (20, 20), "QBCap is shutting down - please wait..."
    _Display
    LogLine "Shutting down..."
    ' 1. plate solver: stop solve-field so it is not left running
    If solveOn Then
        qc_solve_cancel
        t = Timer(.001)
        Do While qc_solve_status& = 1 And Timer(.001) - t < 2 And Timer(.001) >= t
            _Limit 50
        Loop
        solveOn = 0
        LogLine "  plate solve cancelled"
    End If
    ' 2. recording: close the file properly (frame count in the header)
    If recOn Then
        qcRecordStop: recOn = 0
        LogLine "  recording stopped and saved"
    End If
    ' 3. guiding (guide window)
    If guideMode Then
        glAlive = qc_guide_enable&(0)
        LogLine "  guiding stopped"
    End If
    ' 4. mount: both axes and tracking stopped, link closed
    If mntOpen Then
        qc_mount_close: mntOpen = 0
        LogLine "  mount stopped and disconnected"
    End If
    ' 5. cooler off before the camera closes
    If camConn <> 0 And camCooled <> 0 And coolOn <> 0 Then
        qcCtrlSet ASI_COOLER_ON, 0, 0, "Cooler"
        coolOn = 0
        LogLine "  cooler switched off"
    End If
    ' 6. camera, filter wheel, PoleMaster
    If camConn Then
        qcClose: camConn = 0: liveOn = 0
        LogLine "  camera closed"
    End If
    If efwOpen Then
        qc_efw_close: efwOpen = 0
        LogLine "  filter wheel closed"
    End If
    If pmOpen Then
        qc_pm_close: pmOpen = 0
        LogLine "  PoleMaster closed"
    End If
    LogLine "Session ended - all equipment closed. Safe to unplug."
    Cls , C_BG
    _PrintString (20, 20), "All equipment closed - safe to unplug."
    _Display
    _Delay 0.7
End Sub

Function TB% (x As Long, y As Long, label$, isOn As Long)
    Dim w As Long, r As Long
    w = Len(label$) * 8 + 16
    r = Btn%(x, y, w, 26, label$, isOn)
    x = x + w + 4
    TB% = r
End Function

Sub TBSep (x As Long, y As Long)
    Line (x + 3, y + 2)-(x + 3, y + 23), C_BTN
    x = x + 10
End Sub

Sub DrawStatusBar
    Dim y As Long, s$, g$, room As Long
    _Dest 0
    y = SCR_H - STAT_H
    Line (0, y)-(SCR_W - 1, SCR_H - 1), C_BAR, BF
    If camConn Then s$ = camName$(camConn) Else s$ = "No camera"
    If camConn Then
        s$ = s$ + " | FPS " + Fmt1$(statFps / 10) + "  Frames " + I2S$(statCap) + "  Drop " + I2S$(statDrop) + "  "
        If camIsUSB = 0 And camIsQHY = 0 Then s$ = s$ + Fmt1$(statTemp / 10) + "C/" + TempF$(statTemp) + "F "
    Else
        s$ = s$ + " | FPS --  Drop --  Temp -- "
    End If
    If gpuActive Then g$ = "GPU " + ShortGpu$(gpuName$) Else g$ = "CPU scoring"
    If recOn Then g$ = "REC " + I2S$(recWritten) + " fr " + I2S$(recMB) + " MB buf " + I2S$(recBuf) + "%"
    s$ = s$ + "| " + g$ + " |"
    If recOn Then
        Color C_REC
    Else
        Color C_ACC
    End If
    _PrintString (8, y + 4), s$
    room = (SCR_W - 24) \ 8 - Len(s$) - 1
    Color C_TXT: _PrintString (16 + Len(s$) * 8, y + 4), Left$(statusMsg$, room)
End Sub

'==================================================================
'  DRAWING - control panel
'==================================================================
Sub DrawPanel
    Dim y As Long, v As Long, i As Long, n As Long, bw As Long, bx As Long, by As Long
    Dim rw As Long, rh As Long, mb As Single, scl As Single, fw As Single, fh As Single
    Dim maxS As Long, th As Long, ty As Long, s$, r As Long, enterKey$

    _Dest panelImg
    Cls , C_PANEL
    UiBegin PANEL_X, IMG_Y, PANEL_W, IMG_H
    y = 6 - panelScroll

    '--- 1 Camera
    If GroupHeader&(y, 1) Then
        If camConn Then camSel = camConn
        v = PCycler&(y, "Camera", "ASI174|ASI178|ASI1600|G3Mono|G3Color|USBCam|QHYCam", camSel)
        If v <> camSel Then
            If camConn Then
                statusMsg$ = "Disconnect " + camName$(camConn) + " first to switch cameras."
            Else
                camSel = v
            End If
        End If
        If camConn Then
            If PButton%(y, "Disconnect " + camName$(camConn), -1) Then DoAction "Disconnect"
        Else
            If PButton%(y, "Connect " + camName$(camSel), 0) Then DoAction "Connect"
        End If
        PInfo y, "Sensor " + I2S$(camW(camSel)) + " x " + I2S$(camH(camSel)) + "   " + Fmt2$(camPix(camSel)) + " um"
        y = y + 6
    End If

    '--- 2 Capture format & area
    If GroupHeader&(y, 2) Then
        v = PCycler&(y, "Format", "RAW8|RAW16", fmtIdx)
        If v <> fmtIdx Then fmtIdx = v: qcApplyFormat
        v = PCycler&(y, "Binning", "1x1|2x2|3x3|4x4", binIdx)
        If v <> binIdx Then binIdx = v: qcApplyFormat
        v = PCycler&(y, "ROI", "Full|Half|Quarter|640x480", roiIdx)
        If v <> roiIdx Then roiIdx = v: qcApplyFormat
        v = PCycler&(y, "Save as", "SER|FITS", outIdx)
        If v <> outIdx And recOn = 0 Then outIdx = v
        v = PCycler&(y, "Limit", LIMIT_LIST, limitIdx)
        If v <> limitIdx And recOn = 0 Then limitIdx = v
        ' file names: object (last GoTo or typed) + filter + exposure
        If objOn Then
            Line (10, y)-(PANEL_W - 21, y + 21), C_BOX, BF
            Line (10, y)-(PANEL_W - 21, y + 21), C_ACC, B
            s$ = "Object: " + objBuf$
            If (Int(Timer * 2) Mod 2) = 0 Then s$ = s$ + "_"
            Color C_TXT: _PrintString (16, y + 3), s$
            y = y + 26
            PInfo y, "Type the name, then Enter (Esc = cancel)"
        ElseIf PButton%(y, "Object: " + ObjTag$ + "  (change...)", 0) Then
            If recOn = 0 Then objOn = -1: objBuf$ = objName$: statusMsg$ = "Type the object name, then Enter (Esc = cancel)"
        End If
        If PButton%(y, "Capture folder...", 0) Then PickCapDir
        s$ = ObjTag$
        If FiltTag$ <> "" Then s$ = s$ + "_" + FiltTag$
        s$ = s$ + "_" + ExpTag$
        If outIdx = 1 Then s$ = s$ + "_" + "hhmmss.ser" Else s$ = s$ + "_00001.fits"
        PInfoWrap y, ShortName$(CapFolder$ + "/" + s$), C_DIM
        If camConn = camSel And frW > 0 Then
            rw = frW: rh = frH
        Else
            rw = camW(camSel) \ binIdx: rh = camH(camSel) \ binIdx
            Select Case roiIdx
                Case 2: rw = rw \ 2: rh = rh \ 2
                Case 3: rw = rw \ 4: rh = rh \ 4
                Case 4: rw = 640: rh = 480
            End Select
        End If
        mb = (rw * rh * fmtIdx) / 1048576
        PInfo y, "Frame " + I2S$(rw) + " x " + I2S$(rh) + "   " + Fmt2$(mb) + " MB"
        If recOn Then
            PInfo y, "REC " + I2S$(recWritten) + " frames  " + I2S$(recMB) + " MB"
            If luckyOn Then PInfo y, "Lucky: kept " + I2S$(qKept) + "  rejected " + I2S$(qRej)
            s$ = "Buffer " + I2S$(recBuf) + "%   dropped " + I2S$(recDrop)
            If recBuf > 75 Then s$ = s$ + "  DISK SLOW!"
            PInfo y, s$
        End If
        y = y + 6
    End If

    '--- 3 Camera controls
    If GroupHeader&(y, 3) Then
        v = PExpSlider&(1, y, "Exposure", expMs, 1, expMaxMs)
        If v <> expMs Then expMs = v: qcCtrlSet ASI_EXPOSURE, expMs * 1000, autoExp, "Exposure"
        v = PSlider&(2, y, "Gain", gainV, gainLo, gainHi, "")
        If v <> gainV Then gainV = v: qcCtrlSet ASI_GAIN, gainV, autoGain, "Gain"
        v = PSlider&(3, y, "Offset", offsetV, 0, offHi, "")
        If v <> offsetV Then offsetV = v: qcCtrlSet ASI_OFFSET, offsetV, 0, "Offset"
        v = PSlider&(4, y, "USB bandwidth", usbBW, 40, 100, " %")
        If v <> usbBW Then usbBW = v: qcCtrlSet ASI_BANDWIDTH, usbBW, 0, "USB bandwidth"
        v = PCheck&(y, "Auto exposure", autoExp)
        If v <> autoExp Then autoExp = v: qcCtrlSet ASI_EXPOSURE, expMs * 1000, autoExp, "Auto exposure"
        v = PCheck&(y, "Auto gain", autoGain)
        If v <> autoGain Then autoGain = v: qcCtrlSet ASI_GAIN, gainV, autoGain, "Auto gain"
        y = y + 6
    End If

    '--- 4 Thermal
    If GroupHeader&(y, 4) Then
        ' cooler settings only go to cooled cameras (others answer "invalid control type")
        v = PCheck&(y, "Cooler on", coolOn)
        If v <> coolOn Then
            coolOn = v
            If camConn = 0 Or camCooled Then qcCtrlSet ASI_COOLER_ON, -(coolOn <> 0), 0, "Cooler" Else statusMsg$ = "This camera has no cooler."
        End If
        v = PSlider&(5, y, "Target temp", coolTarget, -30, 20, " C (" + I2S$(CLng(coolTarget * 1.8 + 32)) + " F)")
        If v <> coolTarget Then
            coolTarget = v
            If camConn = 0 Or camCooled Then qcCtrlSet ASI_TARGET_TEMP, coolTarget, 0, "Target temp" Else statusMsg$ = "This camera has no cooler."
        End If
        If camConn Then
            ' two lines: C and F together don't fit beside the cooler power
            If camIsUSB Or camIsQHY Then
                PInfo y, "Sensor temp: -- (this camera has no sensor)"
            Else
                PInfo y, "Sensor temp: " + Fmt1$(statTemp / 10) + " C / " + TempF$(statTemp) + " F"
            End If
            If camCooled Then s$ = "Cooler power: " + I2S$(statPower) + "%" Else s$ = "(no cooler)"
        Else
            s$ = "Sensor temp: --      Cooler power: --"
        End If
        PInfo y, s$
        y = y + 6
    End If

    '--- 5 Filter wheel
    If GroupHeader&(y, 5) Then
        bw = (PANEL_W - 30 - 12) \ 4
        If efwOpen Then n = efwSlots Else n = manualSlots
        If n > NFILT Then n = NFILT
        For i = 1 To n
            bx = 10 + ((i - 1) Mod 4) * (bw + 4)
            by = y + ((i - 1) \ 4) * 28
            ' blue = filter in place, red = wheel moving to it (or slot being renamed)
            If efwTarget = i Or editSlot = i Then v = 2 Else v = (fwSlot = i)
            If Btn%(bx, by, bw, 24, filtName$(i), v) Then
                If fwEditMode Then
                    editSlot = i: editBuf$ = filtName$(i)
                    statusMsg$ = "Type a name for slot " + I2S$(i) + " (Enter = save, Esc = cancel)"
                Else
                    SelectFilter i
                End If
            End If
        Next
        y = y + ((n + 3) \ 4) * 28 + 4
        If fwEditMode Then
            If editSlot > 0 Then
                Line (10, y)-(PANEL_W - 21, y + 21), C_BOX, BF
                Line (10, y)-(PANEL_W - 21, y + 21), C_ACC, B
                s$ = "Slot " + I2S$(editSlot) + ": " + editBuf$
                If (Int(Timer * 2) Mod 2) = 0 Then s$ = s$ + "_"
                Color C_TXT: _PrintString (16, y + 3), s$
                y = y + 26
                PInfo y, "Enter = save   Esc = cancel"
            Else
                PInfo y, "Click a filter button to rename it"
            End If
        End If
        If fwEditMode Then s$ = "Done editing" Else s$ = "Edit names"
        If PButton%(y, s$, fwEditMode) Then
            ' keep a name that is still being typed instead of throwing it away
            If editSlot > 0 Then
                enterKey$ = Chr$(13)
                EditKey enterKey$
            End If
            fwEditMode = Not fwEditMode: editSlot = 0
            If fwEditMode Then statusMsg$ = "Edit mode: click a filter to rename it" Else statusMsg$ = "Filter names saved for wheel '" + fwKey$ + "'"
        End If
        If efwOpen Then
            PInfo y, efwName$ + "  (" + I2S$(efwSlots) + " slots)"
            If efwPos = -1 Then
                s$ = "Moving..."
            ElseIf fwSlot > 0 Then
                s$ = "Slot " + I2S$(fwSlot) + ": " + filtName$(fwSlot)
            Else
                s$ = "Position unknown"
            End If
            PInfo y, s$
            If PButton%(y, "Calibrate wheel", 0) Then DoAction "Calibrate"
        Else
            PInfo y, "No wheel - buttons only label the filter"
            If fwKey$ <> "manual" Then PInfo y, "Names from last wheel: " + fwKey$
            If fwSlot Then PInfo y, "Label: " + filtName$(fwSlot)
            If PButton%(y, "Connect wheel", 0) Then EfwConnect
        End If
        y = y + 6
    End If

    '--- 9 Calibration
    If GroupHeader&(y, 9) Then
        v = PCycler&(y, "Frames", CALN_LIST, calNIdx)
        If v <> calNIdx And calActive = 0 Then calNIdx = v
        bw = (PANEL_W - 34) \ 2
        If calActive Then
            PInfo y, "Building master " + ItemOf$("dark|flat", calType + 1) + ":  " + I2S$(calDone) + " / " + I2S$(calTotal)
            If PButton%(y, "Cancel", 2) Then
                qc_master_cancel
                calActive = 0
                statusMsg$ = "Master capture cancelled"
            End If
        Else
            If Btn%(10, y, bw, 24, "Capture dark", 0) Then StartMaster 0
            If Btn%(14 + bw, y, bw, 24, "Capture flat", 0) Then StartMaster 1
            y = y + 30
        End If
        For i = 0 To 1
            MasterPanel y, i
        Next
        y = y + 6
    End If

    '--- 6 Display stretch
    If GroupHeader&(y, 6) Then
        v = PSlider&(6, y, "Black point", blackV, 0, 255, "")
        If v <> blackV Then blackV = v: qcSetStretch
        v = PSlider&(7, y, "White point", whiteV, 0, 255, "")
        If v <> whiteV Then whiteV = v: qcSetStretch
        v = PSlider&(8, y, "Gamma x100", gammaV, 10, 300, "")
        If v <> gammaV Then gammaV = v: qcSetStretch
        v = PCheck&(y, "Debayer preview (colour)", debayerOn)
        If v <> debayerOn Then debayerOn = v: qcSetStretch
        If camIsColor Then
            v = PSlider&(10, y, "Red balance x100", wbR, 10, 400, "")
            If v <> wbR Then wbR = v: qcSetWB
            v = PSlider&(11, y, "Blue balance x100", wbB, 10, 400, "")
            If v <> wbB Then wbB = v: qcSetWB
        End If
        If PButton%(y, "Auto stretch", 0) Then DoAction "Auto Stretch"
        y = y + 6
    End If

    '--- 7 Telescope
    If GroupHeader&(y, 7) Then
        v = PCycler&(y, "Scope", "203mm f/10|10in 1200mm|8in 1000mm", scopeSel)
        If v <> scopeSel Then scopeSel = v: SendMeta: SaveScope
        scl = 206.265 * camPix(camSel) * binIdx / scopeFL(scopeSel)
        fw = 206.265 * camPix(camSel) * camW(camSel) / scopeFL(scopeSel) / 60
        fh = 206.265 * camPix(camSel) * camH(camSel) / scopeFL(scopeSel) / 60
        PInfo y, scopeName$(scopeSel) + " + " + camName$(camSel)
        PInfo y, "Image scale: " + Fmt2$(scl) + " arcsec/px"
        PInfo y, "Field: " + Fmt2$(fw) + " x " + Fmt2$(fh) + " arcmin"
        y = y + 6
    End If

    '--- 8 GPU / processing
    If GroupHeader&(y, 8) Then
        v = PCycler&(y, "CUDA device", "Device 0|Device 1|Device 2|Device 3", gpuDev)
        If v <> gpuDev Then gpuDev = v: gpuReady = 0
        If PButton%(y, "Initialise GPU", gpuReady) Then DoAction "Init GPU"
        If gpuReady Then
            If gpuActive Then
                PInfo y, ShortGpu$(gpuName$) + "  " + I2S$(gpuMem) + " MB  sm_" + I2S$(gpuCC)
            Else
                PInfoC y, "CPU mode (no CUDA)", C_DIM
            End If
            If Len(gpuTest$) Then PInfo y, gpuTest$
        End If
        If qMs > 0 Then PInfo y, "Scoring: " + Fmt2$(qMs) + " ms / frame"
        v = PCheck&(y, "Sharpness graph (focus / seeing)", showQual)
        If v <> showQual Then DoAction "Focus"
        v = PCheck&(y, "Lucky imaging (keep best %)", luckyOn)
        If v <> luckyOn Then DoAction "Lucky"
        v = PSlider&(9, y, "Keep best", luckyPct, 1, 100, " %")
        If v <> luckyPct Then luckyPct = v: If luckyOn Then qcLuckyEnable luckyOn, luckyPct
        y = y + 6
    End If

    '--- 10 Live stack
    If GroupHeader&(y, 10) Then
        v = PCycler&(y, "Method", "Mean|Sigma clip", stackIdx)
        If v <> stackIdx Then stackIdx = v: r = qc_stack_mode&(stackIdx - 1)
        v = PCheck&(y, "Remove hot pixels", stkHot)
        If v <> stkHot Then stkHot = v: r = qc_stack_hotfix&(-(stkHot <> 0))
        v = PCheck&(y, "Align on stars", stkAlign)
        If v <> stkAlign Then
            stkAlign = v: r = qc_stack_align&(-(stkAlign <> 0))
            If stkAlign Then statusMsg$ = "Star alignment on" Else statusMsg$ = "Star alignment off - frames are stacked where they land"
        End If
        bw = (PANEL_W - 34) \ 2
        If stkOn Then
            If Btn%(10, y, bw, 24, "Stop", 2) Then StopStack
        Else
            If Btn%(10, y, bw, 24, "Start", 0) Then StartStack
        End If
        If Btn%(14 + bw, y, bw, 24, "Reset", 0) Then
            r = qc_stack_reset&
            stkAuto = 0
            statusMsg$ = "Stack cleared - starting again with the next frame"
        End If
        y = y + 30
        v = PCycler&(y, "Show", "Stack|Live", 2 + stkView)
        If v <> 2 + stkView Then
            If v = 1 Then stkView = -1 Else stkView = 0
            r = qc_stack_view&(-(stkView <> 0))
            If stkView Then
                If skN > 0 Then AutoStretch ' the stack needs its own stretch to be visible
            Else
                blackV = stkB0: whiteV = stkW0: gammaV = stkG0: qcSetStretch ' back to the live stretch
            End If
            forceDraw = -1: lastGeom$ = ""
        End If
        If stkOn Or skN > 0 Then
            PInfo y, "Stacked " + I2S$(skN) + "   failed " + I2S$(skFail) + "   skipped " + I2S$(skSkip)
            If stkAlign Then
                PInfo y, "Stars " + I2S$(skStars) + "  matched " + I2S$(skMatch) + "  rms " + Fmt2$(skRms) + " px"
                PInfo y, "Drift " + Fmt1$(skDx) + ", " + Fmt1$(skDy) + " px   rot " + Fmt2$(skRot) + " deg"
            Else
                PInfo y, "Alignment off"
            End If
            s$ = "Total " + HMS$(skExp) + "   " + I2S$(CLng(skMs)) + " ms/frame"
            If stkMode = 2 Then s$ = s$ + " GPU" Else If stkMode = 1 Then s$ = s$ + " CPU"
            PInfo y, s$
            If Len(stkMsg$) And Left$(stkMsg$, 7) <> "stacked" Then PInfoC y, Left$(stkMsg$, 38), C_REC
        End If
        If Btn%(10, y, bw, 24, "Save stack", 0) Then SaveStack
        If Btn%(14 + bw, y, bw, 24, "Auto stretch", 0) Then AutoStretch
        y = y + 32
    End If

    '--- 11 Plate solve
    If GroupHeader&(y, 11) Then
        v = PCycler&(y, "Image", "Live frame|Live stack|Image file", solveSrc)
        If v <> solveSrc Then solveSrc = v
        If solveSrc = 3 Then
            PInfo y, "Image files are solved blind (no hints)"
        Else
            v = PCycler&(y, "Scale hint", "Telescope|Off (slow)", solveHint)
            If v <> solveHint Then solveHint = v
            If solveHint = 1 Then PInfo y, "Expect " + Fmt2$(TeleScale!) + " arcsec/px (+/-25%)"
            v = PCheck&(y, "Search near last solve first", solveNear)
            If v <> solveNear Then solveNear = v
        End If
        If _DirExists(idxDir$) Then
            PInfo y, "Index " + Right$(idxDir$, 32)
        Else
            PInfoC y, "Index folder missing - pick it below", C_REC
        End If
        If PButton%(y, "Index folder...", 0) Then PickIndexDir
        If solveOn Then
            If PButton%(y, "Cancel solve", 2) Then qc_solve_cancel
        Else
            If PButton%(y, "Solve", 0) Then StartSolve
        End If
        If solveOn Then
            PInfoC y, "Solving... " + Left$(solveMsg$, 30), C_TXT
        ElseIf solveState = 2 Then
            PInfo y, "RA   " + RAStr$(solRA) + "   Dec " + DecStr$(solDec)
            PInfo y, "Field " + Fmt1$(solFW) + " x " + Fmt1$(solFH) + " arcmin"
            PInfo y, "Rotation " + Fmt1$(solRot) + " deg   " + Fmt2$(solScale) + " arcsec/px"
            PInfo y, I2S$(solStars) + " stars   " + Fmt1$(solSecs) + " s"
        ElseIf solveState = 3 Then
            PInfoC y, Left$(solveMsg$, 38), C_REC
            If Len(solveMsg$) > 38 Then PInfoC y, Mid$(solveMsg$, 39, 38), C_REC
        End If
        y = y + 6
    End If

    '--- 12 Polar align
    If GroupHeader&(y, 12) Then
        If pmOpen = 0 Then
            PInfoC y, "PoleMaster not connected", C_REC
            If PButton%(y, "Connect PoleMaster", 0) Then
                If qc_pm_open& = 0 Then PmConnected Else statusMsg$ = "PoleMaster: " + LibErr$
            End If
        End If
        If pmOpen Then
            PInfo y, pmName$ + "  " + I2S$(pmW) + "x" + I2S$(pmH) + "  frame " + I2S$(pmFrames)
            v = PSlider&(13, y, "Exposure", pmExp, 100, 5000, " ms")
            If v <> pmExp Then pmExp = v: r = qc_pm_set&(pmExp, pmGain)
            v = PSlider&(14, y, "Gain", pmGain, 0, 100, "")
            If v <> pmGain Then pmGain = v: r = qc_pm_set&(pmExp, pmGain)
        End If
        Select Case paStep
            Case 0
                PInfo y, "1. Any RA position. Stars visible?"
                If PButton%(y, "Step 1: solve here", -(paPending = 1)) Then PolarStep 1
            Case 1
                PInfoC y, "Step 1 done.", C_OK
                PInfo y, "2. Turn the mount in RA 60-90 deg"
                PInfo y, "   (either way), then Step 2."
                If mntOpen Then
                    bw = (PANEL_W - 34) \ 2
                    If Btn%(10, y, bw, 24, "Turn RA 75 E", -(paTurn = 1)) Then PolarTurn -75
                    If Btn%(14 + bw, y, bw, 24, "Turn RA 75 W", -(paTurn = 1)) Then PolarTurn 75
                    y = y + 30
                    If paTurn Then PInfoC y, "Turning... Step 2 starts by itself.", C_TXT
                End If
                If PButton%(y, "Step 2: solve again", -(paPending = 2)) Then PolarStep 2
            Case 2
                PInfo y, "3. Turn the ALT / AZ knobs only."
                PInfo y, "   Error updates after each solve."
                PolarReadout y
                v = PCheck&(y, "Keep solving", paAuto)
                If v <> paAuto Then paAuto = v: paLastT = 0
        End Select
        If paPending Then PInfoC y, "Solving...", C_TXT
        If paStep > 0 Then
            If PButton%(y, "Start over", 0) Then PolarReset
        End If
        If siteFile Then
            PInfo y, "Site " + Fmt2$(CSng(siteLat)) + ", " + Fmt2$(CSng(siteLon)) + " (QBCap_site.txt)"
        Else
            PInfoC y, "Site: Kitt Peak default - edit", C_REC
            PInfoC y, "QBCap_site.txt for alt/az split", C_REC
        End If
        y = y + 6
    End If

    '--- 13 Mount
    mntWant(1) = 0: mntWant(2) = 0
    If GroupHeader&(y, 13) Then MountPanel y

    MountJog ' send held buttons (or their release) to the mount

    '--- 14 Guiding (guide window) / Guider link (main window)
    If GroupHeader&(y, 14) Then
        If guideMode Then GuidePanel y Else GuideLinkPanel y
    End If

    '--- 15 Remote control (main window only)
    If GroupHeader&(y, 15) Then RemotePanel y

    '--- 16 Sequencer (main window only)
    If GroupHeader&(y, 16) Then SeqPanel y

    '--- scrolling
    panelContentH = y + panelScroll + 10
    If uiInside And (mWheel <> 0) And (wheelUsed = 0) Then panelScroll = panelScroll + mWheel * 40
    maxS = panelContentH - IMG_H
    If maxS < 0 Then maxS = 0
    If panelScroll > maxS Then panelScroll = maxS
    If panelScroll < 0 Then panelScroll = 0
    If maxS > 0 Then
        th = (IMG_H * IMG_H) \ panelContentH
        ty = (panelScroll * (IMG_H - th)) \ maxS
        Line (PANEL_W - 5, 0)-(PANEL_W - 2, IMG_H - 1), C_BOX, BF
        Line (PANEL_W - 5, ty)-(PANEL_W - 2, ty + th - 1), C_ACCDIM, BF
    End If
    Line (0, 0)-(0, IMG_H - 1), C_EDGE

    _Dest 0
    _PutImage (PANEL_X, IMG_Y), panelImg
End Sub

'==================================================================
'  UI WIDGETS  (immediate mode)
'==================================================================
Sub UiBegin (ox As Long, oy As Long, cw As Long, ch As Long)
    lmx = mx - ox: lmy = my - oy
    uiInside = (lmx >= 0) And (lmx < cw) And (lmy >= 0) And (lmy < ch)
End Sub

Function InRect% (x As Long, y As Long, w As Long, h As Long)
    InRect% = uiInside And (lmx >= x) And (lmx < x + w) And (lmy >= y) And (lmy < y + h)
End Function

' isOn: 0 = normal, -1 (or any non-zero) = blue "on", 2 = red "recording"
Function Btn% (x As Long, y As Long, w As Long, h As Long, label$, isOn As Long)
    Dim hot As Long, r As Long, c As _Unsigned Long
    hot = InRect%(x, y, w, h)
    If isOn = 2 Then
        c = C_REC
    ElseIf isOn Then
        c = C_BTNON
    ElseIf hot Then
        c = C_BTNHOT
    Else
        c = C_BTN
    End If
    Line (x, y)-(x + w - 1, y + h - 1), c, BF
    Line (x, y)-(x + w - 1, y + h - 1), C_EDGE, B
    Color C_TXT
    _PrintString (x + (w - Len(label$) * 8) \ 2, y + (h - 16) \ 2), label$
    r = 0
    If hot And mClick Then r = -1: mClick = 0
    Btn% = r
End Function

Function GroupHeader& (y As Long, g As Long)
    Dim hot As Long, s$
    ' guide mode shows only what the guide camera needs
    If guideMode And InStr(",1,2,3,6,14,", "," + LTrim$(Str$(g)) + ",") = 0 Then GroupHeader& = 0: Exit Function
    hot = InRect%(4, y, PANEL_W - 14, 22)
    If hot Then
        Line (4, y)-(PANEL_W - 11, y + 21), C_GRPHOT, BF
    Else
        Line (4, y)-(PANEL_W - 11, y + 21), C_GRP, BF
    End If
    If grpOpen(g) Then s$ = "[-] " Else s$ = "[+] "
    Color C_ACC: _PrintString (10, y + 3), s$ + grpName$(g)
    If hot And mClick Then grpOpen(g) = Not grpOpen(g): mClick = 0
    y = y + 28
    GroupHeader& = grpOpen(g)
End Function

Function PButton% (y As Long, label$, isOn As Long)
    Dim r As Long
    r = Btn%(10, y, PANEL_W - 30, 24, label$, isOn)
    y = y + 30
    PButton% = r
End Function

Function PCycler& (y As Long, label$, lst$, idx As Long)
    Dim n As Long, r As Long, x As Long, w As Long, s$
    x = 10: w = PANEL_W - 30
    n = ItemCount&(lst$)
    r = idx
    Color C_DIM: _PrintString (x, y + 2), label$
    If Btn%(x + 110, y, 22, 20, "<", 0) Then
        r = r - 1
        If r < 1 Then r = n
    End If
    If Btn%(x + w - 22, y, 22, 20, ">", 0) Then
        r = r + 1
        If r > n Then r = 1
    End If
    Line (x + 136, y)-(x + w - 27, y + 19), C_BOX, BF
    s$ = ItemOf$(lst$, r)
    Color C_TXT: _PrintString (x + 136 + ((w - 163) - Len(s$) * 8) \ 2, y + 2), s$
    y = y + 26
    PCycler& = r
End Function

' exposure slider: log scale (1 ms .. 10 min) with - / + buttons stepping through usual values
Function PExpSlider& (id As Long, y As Long, label$, v As Long, lo As Long, hi As Long)
    Dim x As Long, w As Long, ty As Long, kx As Long, r As Long, s$, f As Double, i As Long, n As Long, st As Long
    x = 10: w = PANEL_W - 30
    r = v
    Color C_DIM: _PrintString (x, y), label$
    s$ = ExpStr$(v)
    Color C_TXT: _PrintString (x + w - 60 - Len(s$) * 8, y), s$
    n = ItemCount&(EXP_STEPS)
    If Btn%(x + w - 52, y - 2, 24, 18, "-", 0) Then
        For i = n To 1 Step -1
            st = Val(ItemOf$(EXP_STEPS, i))
            If st < v Then r = st: Exit For
        Next
    End If
    If Btn%(x + w - 24, y - 2, 24, 18, "+", 0) Then
        For i = 1 To n
            st = Val(ItemOf$(EXP_STEPS, i))
            If st > v Then r = st: Exit For
        Next
    End If
    ty = y + 20
    f = Log(v / lo) / Log(hi / lo)
    kx = x + Int(f * (w - 10))
    Line (x, ty + 4)-(x + w - 1, ty + 8), C_BTN, BF
    Line (x, ty + 4)-(kx, ty + 8), C_ACCDIM, BF
    Line (kx, ty)-(kx + 9, ty + 12), C_ACC, BF
    If mClick And InRect%(x, ty - 3, w, 18) Then activeSlider = id: mClick = 0
    If activeSlider = id Then
        If mDown Then
            f = (lmx - x - 5) / (w - 10)
            If f < 0 Then f = 0
            If f > 1 Then f = 1
            r = NiceExp&(lo * Exp(f * Log(hi / lo)))
        Else
            activeSlider = 0
        End If
    End If
    r = _Clamp(r, lo, hi)
    y = y + 40
    PExpSlider& = r
End Function

' round a dragged exposure to a tidy value
Function NiceExp& (ms As Double)
    If ms < 20 Then
        NiceExp& = CLng(ms)
    ElseIf ms < 200 Then
        NiceExp& = CLng(ms / 5) * 5
    ElseIf ms < 2000 Then
        NiceExp& = CLng(ms / 50) * 50
    ElseIf ms < 20000 Then
        NiceExp& = CLng(ms / 500) * 500
    ElseIf ms < 120000 Then
        NiceExp& = CLng(ms / 5000) * 5000
    Else
        NiceExp& = CLng(ms / 15000) * 15000
    End If
End Function

Function ExpStr$ (ms As Long)
    If ms < 1000 Then
        ExpStr$ = I2S$(ms) + " ms"
    ElseIf ms < 60000 Then
        ExpStr$ = Fmt1$(ms / 1000) + " s"
    ElseIf ms Mod 60000 = 0 Then
        ExpStr$ = I2S$(ms \ 60000) + " min"
    Else
        ExpStr$ = I2S$(ms \ 60000) + " min " + I2S$((ms Mod 60000) \ 1000) + " s"
    End If
End Function

Function PSlider& (id As Long, y As Long, label$, v As Long, lo As Long, hi As Long, unit$)
    Dim x As Long, w As Long, ty As Long, kx As Long, r As Long, s$
    x = 10: w = PANEL_W - 30
    r = v
    Color C_DIM: _PrintString (x, y), label$
    s$ = I2S$(v) + unit$
    Color C_TXT: _PrintString (x + w - Len(s$) * 8, y), s$
    ty = y + 20
    kx = x + ((v - lo) * (w - 10)) \ (hi - lo)
    Line (x, ty + 4)-(x + w - 1, ty + 8), C_BTN, BF
    Line (x, ty + 4)-(kx, ty + 8), C_ACCDIM, BF
    Line (kx, ty)-(kx + 9, ty + 12), C_ACC, BF

    If mClick And InRect%(x, ty - 3, w, 18) Then activeSlider = id: mClick = 0
    If activeSlider = id Then
        If mDown Then
            r = lo + ((lmx - x - 5) * (hi - lo)) \ (w - 10)
        Else
            activeSlider = 0
        End If
    End If
    ' NOTE: mouse wheel deliberately does NOT change sliders - it only scrolls
    ' the panel, so scrolling past the cooler/gain sliders can't nudge them.
    r = _Clamp(r, lo, hi)
    y = y + 40
    PSlider& = r
End Function

Function PCheck& (y As Long, label$, v As Long)
    Dim hot As Long, r As Long
    r = v
    hot = InRect%(10, y, PANEL_W - 30, 18)
    Line (10, y + 1)-(24, y + 15), C_BOX, BF
    Line (10, y + 1)-(24, y + 15), C_BTN, B
    If v Then Line (13, y + 4)-(21, y + 12), C_ACC, BF
    Color C_TXT: _PrintString (32, y + 1), label$
    If hot And mClick Then r = Not v: mClick = 0
    y = y + 24
    PCheck& = r
End Function

Sub PInfoC (y As Long, s$, c As _Unsigned Long)
    Color c: _PrintString (10, y), s$
    y = y + 20
End Sub

' word-wrapped info lines (38 characters fit the panel)
Sub PInfoWrap (y As Long, txt$, c As _Unsigned Long)
    Dim t$, k As Long
    t$ = LTrim$(txt$)
    Do While Len(t$) > 38
        k = _InStrRev(Left$(t$, 39), " ")
        If k < 10 Then k = 38
        PInfoC y, RTrim$(Left$(t$, k)), c
        t$ = LTrim$(Mid$(t$, k + 1))
    Loop
    If Len(t$) Then PInfoC y, t$, c
End Sub

Sub PInfo (y As Long, s$)
    Color C_DIM: _PrintString (10, y), s$
    y = y + 20
End Sub

'==================================================================
'  HELPERS
'==================================================================
Function ItemCount& (lst$)
    Dim i As Long, n As Long
    n = 1
    For i = 1 To Len(lst$)
        If Mid$(lst$, i, 1) = "|" Then n = n + 1
    Next
    ItemCount& = n
End Function

Function ItemOf$ (lst$, idx As Long)
    Dim n As Long, st As Long, p As Long, r$
    n = 1: st = 1: r$ = ""
    Do
        p = InStr(st, lst$, "|")
        If n = idx Then
            If p = 0 Then r$ = Mid$(lst$, st) Else r$ = Mid$(lst$, st, p - st)
            Exit Do
        End If
        If p = 0 Then Exit Do
        st = p + 1: n = n + 1
    Loop
    ItemOf$ = r$
End Function

Function I2S$ (n As Long)
    I2S$ = LTrim$(Str$(n))
End Function

Function Fmt2$ (v As Single)
    Dim n As Long, s$
    n = CLng(v * 100)
    s$ = ""
    If n < 0 Then s$ = "-": n = -n
    Fmt2$ = s$ + LTrim$(Str$(n \ 100)) + "." + Right$("0" + LTrim$(Str$(n Mod 100)), 2)
End Function

'==================================================================
'  CAMERA LAYER  -  real calls into libqbcap.so
'==================================================================
Sub StartupMessage
    Dim b$, r As Long, n As Long, i As Long, ff As Long
    ff = FreeFile
    Open logFile$ For Append As #ff
    Print #ff, ""
    Print #ff, "===== QBCap session  "; Date$; " "; Time$; " ====="
    Close #ff
    b$ = Space$(64)
    r = qc_sdk_version&(_Offset(b$), 64)
    n = qc_camera_count&
    statusMsg$ = "libqbcap v" + I2S$(qc_version&) + "   ZWO SDK " + ZStr$(b$) + "   " + I2S$(n) + " ZWO camera(s) on USB"
    LogLine statusMsg$
    r = qc_g3_count&
    If r < 0 Then
        LogLine "  Orion G3: libssg3.so not loaded (G3 not available)"
    Else
        LogLine "  " + I2S$(r) + " Orion G3 camera(s) on USB"
    End If
    If qc_usbcam_count& > 0 Then LogLine "  USB camera (V4L2, raw 8-bit) found" Else LogLine "  no USB camera (V4L2) found"
    r = qc_qhy_count&
    If r < 0 Then
        LogLine "  QHY camera: libqhyccd.so not loaded (QHYCam not available)"
    Else
        LogLine "  " + I2S$(r) + " QHY camera(s) on USB (not counting a PoleMaster)"
    End If
    If qc_qhy_blank& Then LogLine "  Orion All-in-One on USB without its firmware - QBCap loads it when you connect QHYCam"
    For i = 0 To n - 1
        b$ = Space$(64)
        r = qc_camera_name&(i, _Offset(b$), 64)
        LogLine "  camera " + I2S$(i) + ": " + ZStr$(b$)
    Next
    lastLogged$ = statusMsg$
End Sub

Sub LogLine (t$)
    Dim ff As Long, k As Long, u$
    ' the screen font's degree sign (code 248) is written as UTF-8 in the log
    ' (work on a copy - t$ is often statusMsg$ itself)
    u$ = t$
    k = InStr(u$, Chr$(248))
    Do While k > 0
        u$ = Left$(u$, k - 1) + Chr$(194) + Chr$(176) + Mid$(u$, k + 1)
        k = InStr(k + 2, u$, Chr$(248))
    Loop
    ff = FreeFile
    Open logFile$ For Append As #ff
    Print #ff, Time$; "  "; u$
    Close #ff
End Sub

Sub LogStatus
    Dim k As Long, key$
    If statusMsg$ <> lastLogged$ Then
        ' "Gain = 349", "Exposure = 1400000"... a slider drag makes hundreds of these;
        ' hold them and write only the value it ends on
        k = InStr(statusMsg$, " = ")
        If k > 0 And k < 30 Then key$ = Left$(statusMsg$, k) Else key$ = ""
        If key$ <> "" Then
            If key$ <> logHeldKey$ And logHeld$ <> "" Then LogLine logHeld$
            logHeld$ = statusMsg$: logHeldKey$ = key$: logHeldT = Timer(0.01)
        Else
            If logHeld$ <> "" Then LogLine logHeld$: logHeld$ = "": logHeldKey$ = ""
            LogLine statusMsg$
        End If
        lastLogged$ = statusMsg$
    ElseIf logHeld$ <> "" Then
        k = 0: If Timer(0.01) - logHeldT > 1.5 Or Timer(0.01) < logHeldT Then k = -1
        If k Then LogLine logHeld$: logHeld$ = "": logHeldKey$ = ""
    End If
End Sub

Function LibErr$
    Dim b$, r As Long
    b$ = Space$(256)
    r = qc_last_error&(_Offset(b$), 256)
    LibErr$ = "ERROR: " + ZStr$(b$)
End Function

Function ZStr$ (s$)
    Dim p As Long
    p = InStr(s$, Chr$(0))
    If p > 0 Then ZStr$ = Left$(s$, p - 1) Else ZStr$ = RTrim$(s$)
End Function

Function qcOpen& (idx As Long)
    Dim n As Long, r As Long, nm$, b$
    Dim w As Long, h As Long, isC As Long, bay As Long, bd As Long, cool As Long, px As Long, u3 As Long
    Dim lo As Long, hi As Long, df As Long, ca As Long, wasBlank As Long

    nm$ = camName$(idx) + Chr$(0)
    camIsG3 = (Left$(camName$(idx), 2) = "G3")
    camIsUSB = (camName$(idx) = "USBCam")
    camIsQHY = (camName$(idx) = "QHYCam")
    ' a blank Orion All-in-One gets its firmware inside qc_find_camera (a few seconds)
    If camIsQHY Then wasBlank = qc_qhy_blank&
    If wasBlank Then LogLine "Loading the All-in-One firmware (QHY5II.HEX)..."
    n = qc_find_camera&(_Offset(nm$))
    If n < 0 Then statusMsg$ = LibErr$: qcOpen& = -1: Exit Function
    r = qc_open&(n)
    If r < 0 Then statusMsg$ = LibErr$: qcOpen& = r: Exit Function

    b$ = Space$(64)
    r = qc_camera_name&(n, _Offset(b$), 64)
    camFull$ = ZStr$(b$)
    r = qc_sensor_info&(w, h, isC, bay, bd, cool, px, u3)
    camW(idx) = w: camH(idx) = h: camPix(idx) = px / 100
    camIsColor = isC: camCooled = cool
    If isC Then debayerOn = -1 Else debayerOn = 0

    If qc_ctrl_range&(ASI_GAIN, lo, hi, df, ca) = 0 Then gainLo = lo: gainHi = hi
    If qc_ctrl_range&(ASI_OFFSET, lo, hi, df, ca) = 0 Then offHi = hi
    gainV = _Clamp(gainV, gainLo, gainHi)
    offsetV = _Clamp(offsetV, 0, offHi)
    ' longest exposure this camera takes (capped at QBCap's 10 min)
    If qc_ctrl_range&(ASI_EXPOSURE, lo, hi, df, ca) = 0 And hi > 0 Then expMaxMs = _Clamp(hi \ 1000, 1, EXP_MAX_MS) Else expMaxMs = EXP_MAX_MS
    If expMs > expMaxMs Then expMs = expMaxMs

    ' push the panel's current settings to the camera
    camConn = idx
    qcApplyFormat
    qcApplyControls
    qcSetStretch
    qcSetWB
    SendMeta
    lastGeom$ = ""
    statCap = 0: statDrop = 0: statFps = 0

    b$ = camFull$ + "  " + I2S$(w) + "x" + I2S$(h) + "  " + I2S$(bd) + "-bit"
    If isC Then b$ = b$ + "  colour" Else b$ = b$ + "  mono"
    If expMaxMs < EXP_MAX_MS Then b$ = b$ + "  max exposure " + ExpStr$(expMaxMs)
    If camIsG3 Or camIsUSB Or camIsQHY Then
        b$ = b$ + "  USB2"
    ElseIf u3 Then
        b$ = b$ + "  USB3"
    Else
        b$ = b$ + "  USB2 (slow!)"
    End If
    If cool Then b$ = b$ + "  cooled"
    statusMsg$ = "Connected: " + b$
    If wasBlank Then statusMsg$ = "Firmware loaded.  " + statusMsg$
    qcOpen& = 0
End Function

Sub qcClose
    qc_close
    frW = 0: frH = 0
    statusMsg$ = "Camera closed."
End Sub

Sub qcApplyFormat
    Dim fullW As Long, fullH As Long, rw As Long, rh As Long, r As Long, w As Long, h As Long, bpp As Long
    Dim g3Note$
    If camConn = 0 Then Exit Sub
    ' the G3 only gives 16-bit full frames at bin 1
    If camIsG3 Then
        If fmtIdx <> 2 Or binIdx <> 1 Or roiIdx <> 1 Then g3Note$ = "The G3 runs 16-bit, full frame, bin 1 only." Else g3Note$ = ""
        fmtIdx = 2: binIdx = 1: roiIdx = 1
    ElseIf camIsUSB Then
        If fmtIdx <> 1 Or binIdx <> 1 Or roiIdx <> 1 Then g3Note$ = "The USB camera runs 8-bit, full frame, bin 1 only." Else g3Note$ = ""
        fmtIdx = 1: binIdx = 1: roiIdx = 1
    ElseIf camIsQHY Then
        ' QHY: RAW8 or RAW16 both fine, but full frame at bin 1 only (for now)
        If binIdx <> 1 Or roiIdx <> 1 Then g3Note$ = "The QHY camera runs full frame, bin 1 only." Else g3Note$ = ""
        binIdx = 1: roiIdx = 1
    Else
        g3Note$ = ""
    End If
    fullW = camW(camConn) \ binIdx: fullH = camH(camConn) \ binIdx
    Select Case roiIdx
        Case 2: rw = fullW \ 2: rh = fullH \ 2
        Case 3: rw = fullW \ 4: rh = fullH \ 4
        Case 4: rw = 640: rh = 480
        Case Else: rw = 0: rh = 0
    End Select
    r = qc_set_format&(binIdx, fmtIdx - 1, rw, rh)
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    r = qc_frame_size&(w, h, bpp)
    frW = w: frH = h
    lastGeom$ = ""
    If fmtIdx = 2 And bpp = 1 Then
        fmtIdx = 1
        statusMsg$ = "This camera gives 8-bit data only - Format set to RAW8.  " + I2S$(w) + " x " + I2S$(h)
        Exit Sub
    End If
    statusMsg$ = "Format: " + I2S$(w) + " x " + I2S$(h) + "  bin " + I2S$(binIdx) + "  " + ItemOf$("RAW8|RAW16", fmtIdx)
    If g3Note$ <> "" Then statusMsg$ = g3Note$ + "  " + statusMsg$
End Sub

Sub qcApplyControls
    qcCtrlSet ASI_EXPOSURE, expMs * 1000, autoExp, "Exposure"
    qcCtrlSet ASI_GAIN, gainV, autoGain, "Gain"
    qcCtrlSet ASI_OFFSET, offsetV, 0, "Offset"
    qcCtrlSet ASI_BANDWIDTH, usbBW, 0, "USB bandwidth"
    If camCooled Then
        qcCtrlSet ASI_TARGET_TEMP, coolTarget, 0, "Target temp"
        qcCtrlSet ASI_COOLER_ON, -(coolOn <> 0), 0, "Cooler"
    End If
End Sub

Sub qcCtrlSet (ctl As Long, v As Long, autoOn As Long, label$)
    Dim r As Long, a$
    If autoOn Then a$ = " (auto)" Else a$ = ""
    If camConn = 0 Then statusMsg$ = label$ + " = " + I2S$(v) + a$ + "   (not connected)": Exit Sub
    If camIsUSB Then
        If ctl = ASI_BANDWIDTH Or ctl = ASI_HIGH_SPEED Then statusMsg$ = label$ + ": not used by the USB camera": Exit Sub
    End If
    If camIsG3 Then
        ' the G3 has no auto modes and no USB bandwidth setting
        If ctl = ASI_BANDWIDTH Or ctl = ASI_HIGH_SPEED Then statusMsg$ = label$ + ": not used by the G3": Exit Sub
        If autoOn Then
            autoExp = 0: autoGain = 0
            statusMsg$ = "The G3 has no auto exposure / auto gain."
            r = qc_ctrl_set&(ctl, v, 0)
            Exit Sub
        End If
    End If
    If camIsQHY Then
        ' same as the G3: no auto modes, no USB bandwidth setting
        If ctl = ASI_BANDWIDTH Or ctl = ASI_HIGH_SPEED Then statusMsg$ = label$ + ": not used by the QHY camera": Exit Sub
        If autoOn Then
            autoExp = 0: autoGain = 0
            statusMsg$ = "The QHY camera has no auto exposure / auto gain."
            r = qc_ctrl_set&(ctl, v, 0)
            Exit Sub
        End If
    End If
    r = qc_ctrl_set&(ctl, v, -(autoOn <> 0))
    If r < 0 Then statusMsg$ = LibErr$ Else statusMsg$ = label$ + " = " + I2S$(v) + a$
End Sub

Function qcStartVideo&
    Dim r As Long
    r = qc_start_video&
    If r < 0 Then statusMsg$ = LibErr$ Else statusMsg$ = "Live video started."
    statCap = 0
    qcStartVideo& = r
End Function

Sub qcStop
    qc_stop
    statusMsg$ = "Live video stopped."
End Sub

Sub qcSetStretch
    Dim r As Long
    r = qc_set_stretch&(blackV, whiteV, gammaV, -(debayerOn <> 0))
    forceDraw = -1
End Sub

Sub UpdateStats
    Dim c As Long, d As Long, f As Long, t As Long, v As Long, a As Long, r As Long, tNow As Double
    Static lastSolveT As Double
    tNow = Timer(.001)
    ' plate solving can run with no camera (image files), so it is polled first
    If solveOn And (tNow < lastSolveT Or tNow - lastSolveT >= 0.25) Then lastSolveT = tNow: PollSolve
    If paStep = 2 And paAuto Then PollPolar
    If pmOpen Then PollPm
    If mntOpen Then PollMount
    If guideMode Then PollGuide Else PollGuideLink
    If camConn = 0 Then Exit Sub
    If tNow >= lastStatT And tNow - lastStatT < 0.5 Then Exit Sub
    lastStatT = tNow
    r = qc_stats&(c, d, f, t)
    statCap = c: statDrop = d: statFps = f: statTemp = t
    If recOn Then PollRecording
    If calActive Then PollMaster
    If showQual Or luckyOn Then PollQuality
    If stkOn Then PollStack
    If camCooled Then
        If qc_ctrl_get&(ASI_COOLER_POWER, v, a) = 0 Then statPower = v
    End If
    ' in auto mode the camera changes these itself - show its live values
    If autoExp Then
        If qc_ctrl_get&(ASI_EXPOSURE, v, a) = 0 Then expMs = _Clamp(v \ 1000, 1, expMaxMs)
    End If
    If autoGain Then
        If qc_ctrl_get&(ASI_GAIN, v, a) = 0 Then gainV = _Clamp(v, gainLo, gainHi)
    End If
End Sub

' sensor temperature (tenths of a degree C) shown in Fahrenheit, one decimal
Function TempF$ (tX10 As Long)
    TempF$ = Fmt1$(tX10 * 0.18 + 32)
End Function

Function Fmt1$ (v As Single)
    Dim n As Long, s$
    n = CLng(v * 10)
    s$ = ""
    If n < 0 Then s$ = "-": n = -n
    Fmt1$ = s$ + LTrim$(Str$(n \ 10)) + "." + LTrim$(Str$(n Mod 10))
End Function

Sub SendMeta
    Dim t$, f$, r As Long
    t$ = scopeName$(scopeSel) + Chr$(0)
    If fwSlot > 0 Then f$ = filtName$(fwSlot) + Chr$(0) Else f$ = Chr$(0)
    r = qc_set_meta&(_Offset(t$), scopeFL(scopeSel), _Offset(f$))
End Sub

Sub qcSetWB
    Dim r As Long
    r = qc_set_wb&(wbR, wbB)
    forceDraw = -1
End Sub

Function qcRecordStart& (path$, fmt As Long)
    Dim p$, r As Long, mf As Long, ms As Long
    Select Case limitIdx
        Case 2: mf = 100
        Case 3: mf = 500
        Case 4: mf = 1000
        Case 5: mf = 5000
        Case 6: ms = 30
        Case 7: ms = 60
        Case 8: ms = 300
    End Select
    If rmCapN > 0 Then mf = rmCapN: ms = 0 ' remote CAPTURE n: exactly n frames
    SendMeta
    p$ = path$ + Chr$(0)
    r = qc_record_start&(_Offset(p$), fmt, mf, ms)
    If r < 0 Then
        statusMsg$ = LibErr$
    Else
        recWritten = 0: recBuf = 0: recDrop = 0: recMB = 0
        statusMsg$ = "Recording -> " + ShortName$(path$)
    End If
    qcRecordStart& = r
End Function

Sub qcRecordStop
    qc_record_stop
    PollRecording
    recOn = 0
End Sub

Sub PollRecording
    Dim w As Long, b As Long, d As Long, m As Long, a As Long, r As Long, s$
    r = qc_record_status&(w, b, d, m, a)
    recWritten = w: recBuf = b: recDrop = d: recMB = m
    If a = 0 Then
        If r < 0 Then
            statusMsg$ = LibErr$
        Else
            s$ = "Saved " + I2S$(w) + " frames (" + I2S$(m) + " MB)"
            If d > 0 Then s$ = s$ + ", " + I2S$(d) + " dropped"
            statusMsg$ = s$ + " -> " + ShortName$(recPath$)
        End If
        recOn = 0
    End If
End Sub

Sub qcSnapshot (path$)
    Dim p$, r As Long
    p$ = path$ + Chr$(0)
    r = qc_snapshot&(_Offset(p$))
    If r < 0 Then statusMsg$ = LibErr$ Else statusMsg$ = "Snapshot saved -> " + ShortName$(path$)
End Sub

Sub EfwConnect
    Dim n As Long, r As Long, b$, sl As Long
    If efwOpen Then Exit Sub
    n = qc_efw_count&
    If n = 0 Then
        LogLine "No ZWO filter wheel on USB"
        Exit Sub
    End If
    r = qc_efw_open&(0)
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    b$ = Space$(64)
    r = qc_efw_info&(_Offset(b$), 64, sl)
    efwName$ = ZStr$(b$): efwSlots = sl
    efwOpen = -1: efwPos = -2: efwTarget = 0
    fwKey$ = WheelKey$(efwName$, sl)
    LoadFilterNames
    manualSlots = sl
    SaveLastWheel
    statusMsg$ = "Filter wheel: " + efwName$ + "  " + I2S$(sl) + " slots"
    PollEfwNow
End Sub

Sub SelectFilter (i As Long)
    Dim r As Long
    If efwOpen = 0 Then
        fwSlot = i
        SendMeta
        statusMsg$ = "Filter label: " + filtName$(i) + "   (no wheel connected)"
        Exit Sub
    End If
    If i > efwSlots Then statusMsg$ = "This wheel has only " + I2S$(efwSlots) + " slots.": Exit Sub
    If efwPos = -1 Or efwTarget > 0 Then statusMsg$ = "Wheel is still moving - wait for it to stop.": Exit Sub
    If i = fwSlot And efwPos >= 0 Then statusMsg$ = filtName$(i) + " is already in place.": Exit Sub
    r = qc_efw_set&(i - 1)
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    efwTarget = i
    fwSlot = 0
    SendMeta
    statusMsg$ = "Moving to slot " + I2S$(i) + ": " + filtName$(i)
End Sub

Sub PollEfw
    Dim tNow As Double
    If efwOpen = 0 Then Exit Sub
    tNow = Timer(.001)
    If tNow >= lastEfwT And tNow - lastEfwT < 0.25 Then Exit Sub
    lastEfwT = tNow
    PollEfwNow
End Sub

Sub PollEfwNow
    Dim p As Long, oldSlot As Long
    p = qc_efw_get&
    If p = -2 Then Exit Sub
    efwPos = p
    oldSlot = fwSlot
    If p >= 0 Then fwSlot = p + 1 Else fwSlot = 0
    If p >= 0 And efwTarget > 0 Then
        If fwSlot = efwTarget Then
            statusMsg$ = "Filter in place: slot " + I2S$(fwSlot) + " " + filtName$(fwSlot)
        Else
            statusMsg$ = "Wheel stopped at slot " + I2S$(fwSlot) + ", not " + I2S$(efwTarget)
        End If
        efwTarget = 0
    End If
    If fwSlot <> oldSlot Then SendMeta
End Sub

Function WheelKey$ (nm$, slots As Long)
    ' e.g. "EFW_8" - one set of names per wheel model/size
    Dim i As Long, c$, r$
    For i = 1 To Len(nm$)
        c$ = Mid$(nm$, i, 1)
        If c$ = " " Or c$ = "|" Then c$ = "_"
        r$ = r$ + c$
    Next
    WheelKey$ = r$ + "_" + I2S$(slots)
End Function

Function FilterFile$
    FilterFile$ = exeDir$ + "QBCap_filters.txt"
End Function

Function LastWheelFile$
    LastWheelFile$ = exeDir$ + "QBCap_lastwheel.txt"
End Function

' remember which wheel was last connected (line looks like:  EFW_5|5)
Sub SaveLastWheel
    Dim ff As Long
    ff = FreeFile
    Open LastWheelFile$ For Output As #ff
    Print #ff, fwKey$ + "|" + I2S$(manualSlots)
    Close #ff
End Sub

Sub LoadLastWheel
    Dim ff As Long, l$, p As Long, sl As Long
    If _FileExists(LastWheelFile$) = 0 Then Exit Sub
    ff = FreeFile
    Open LastWheelFile$ For Input As #ff
    If Not EOF(ff) Then Line Input #ff, l$
    Close #ff
    p = InStr(l$, "|")
    If p < 2 Then Exit Sub
    sl = Val(Mid$(l$, p + 1))
    If sl < 1 Or sl > NFILT Then Exit Sub
    fwKey$ = Left$(l$, p - 1)
    manualSlots = sl
    LoadFilterNames
End Sub

Sub LoadFilterNames
    ' file lines look like:  EFW_8|3|HA
    Dim ff As Long, l$, k$, p As Long, sl As Long, i As Long
    For i = 1 To NFILT
        If fwKey$ = "EFW_8" Or fwKey$ = "manual" Then filtName$(i) = defFilt$(i) Else filtName$(i) = "Slot " + I2S$(i)
    Next
    If _FileExists(FilterFile$) = 0 Then Exit Sub
    ff = FreeFile
    Open FilterFile$ For Input As #ff
    Do While Not EOF(ff)
        Line Input #ff, l$
        p = InStr(l$, "|")
        If p > 0 Then
            k$ = Left$(l$, p - 1): l$ = Mid$(l$, p + 1)
            p = InStr(l$, "|")
            If k$ = fwKey$ And p > 0 Then
                sl = Val(Left$(l$, p - 1))
                If sl >= 1 And sl <= NFILT Then filtName$(sl) = Mid$(l$, p + 1)
            End If
        End If
    Loop
    Close #ff
End Sub

Sub SaveFilterNames
    ' rewrite the file: keep other wheels' lines, replace this wheel's
    Dim ff As Long, l$, n As Long, i As Long, p As Long, cnt As Long
    ReDim keep$(0)
    If _FileExists(FilterFile$) Then
        ff = FreeFile
        Open FilterFile$ For Input As #ff
        Do While Not EOF(ff)
            Line Input #ff, l$
            p = InStr(l$, "|")
            If p > 0 Then
                If Left$(l$, p - 1) <> fwKey$ Then
                    n = n + 1
                    ReDim _Preserve keep$(n)
                    keep$(n) = l$
                End If
            End If
        Loop
        Close #ff
    End If
    If efwOpen Then cnt = efwSlots Else cnt = manualSlots
    If cnt > NFILT Then cnt = NFILT
    ff = FreeFile
    Open FilterFile$ For Output As #ff
    For i = 1 To n: Print #ff, keep$(i): Next
    For i = 1 To cnt: Print #ff, fwKey$ + "|" + I2S$(i) + "|" + filtName$(i): Next
    Close #ff
End Sub

Sub EditKey (k$)
    Select Case k$
        Case ""
        Case Chr$(13)
            If Len(_Trim$(editBuf$)) > 0 Then
                filtName$(editSlot) = _Trim$(editBuf$)
                SaveFilterNames
                SendMeta
                statusMsg$ = "Slot " + I2S$(editSlot) + " is now '" + filtName$(editSlot) + "'"
            End If
            editSlot = 0
        Case Chr$(27)
            editSlot = 0
            statusMsg$ = "Rename cancelled"
        Case Chr$(8)
            If Len(editBuf$) > 0 Then editBuf$ = Left$(editBuf$, Len(editBuf$) - 1)
        Case Else
            ' printable characters only, no "|", max 9 so it fits on the button
            If Len(k$) = 1 And Asc(k$) >= 32 And Asc(k$) < 127 And k$ <> "|" And Len(editBuf$) < 9 Then editBuf$ = editBuf$ + k$
    End Select
End Sub

Sub StartMaster (t As Long)
    Dim n As Long, r As Long, p$, nm$
    If camConn = 0 Then statusMsg$ = "Connect a camera first.": Exit Sub
    If calActive Then statusMsg$ = "A master is already being built.": Exit Sub
    If liveOn = 0 Then DoAction "Live"
    If liveOn = 0 Then Exit Sub
    n = Val(ItemOf$(CALN_LIST, calNIdx))
    If t = 0 Then nm$ = "Dark_" Else nm$ = "Flat_"
    nm$ = nm$ + camName$(camConn) + "_" + I2S$(expMs) + "ms_g" + I2S$(gainV)
    If camCooled Then nm$ = nm$ + "_" + I2S$(statTemp \ 10) + "C"
    nm$ = nm$ + "_bin" + I2S$(binIdx) + Mid$(StampName$, Len(camName$(camConn)) + 1)
    calPath$ = exeDir$ + "masters/" + nm$ + ".fits"
    p$ = calPath$ + Chr$(0)
    r = qc_master_start&(t, n, _Offset(p$))
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    calActive = -1: calType = t: calDone = 0: calTotal = n
    If t = 0 Then
        statusMsg$ = "Building master dark from " + I2S$(n) + " frames - keep the scope covered"
    Else
        statusMsg$ = "Building master flat from " + I2S$(n) + " frames - keep the light source steady"
    End If
End Sub

Sub PollMaster
    Dim d As Long, t As Long, r As Long
    r = qc_master_status&(d, t)
    calDone = d: calTotal = t
    If r = 1 Then Exit Sub
    calActive = 0
    If r = 2 Or r = -2 Then
        calOn(calType) = -1
        mFile$(calType) = ShortMasterName$(calPath$)
        ApplyCalib
        RefreshMasters
        If r = 2 Then
            statusMsg$ = "Master " + ItemOf$("dark|flat", calType + 1) + " saved -> masters/" + mFile$(calType) + " (now applied)"
        Else
            statusMsg$ = "Master built and applied, but NOT saved: " + LibErr$
        End If
    ElseIf r < 0 Then
        statusMsg$ = LibErr$
    End If
End Sub

Function ShortMasterName$ (p$)
    Dim k As Long
    k = _InStrRev(p$, "/")
    If k > 0 Then ShortMasterName$ = Mid$(p$, k + 1) Else ShortMasterName$ = p$
End Function

Sub ApplyCalib
    Dim r As Long
    r = qc_calib_set&(calOn(0), calOn(1))
    forceDraw = -1
End Sub

Sub RefreshMasters
    Dim i As Long, w As Long, h As Long, e As Long, g As Long, tp As Long, n As Long
    For i = 0 To 1
        mLoaded(i) = qc_master_info&(i, w, h, e, g, tp, n)
        mW(i) = w: mH(i) = h: mExp(i) = e: mGain(i) = g: mTemp(i) = tp: mN(i) = n
    Next
End Sub

Sub LoadMasterDialog (t As Long)
    Dim f$, p$, r As Long, ttl$
    If t = 0 Then ttl$ = "Load master dark" Else ttl$ = "Load master flat"
    MkDir_Safe exeDir$ + "masters"
    f$ = _OpenFileDialog$(ttl$, exeDir$ + "masters/", "*.fits|*.fit|*.FITS|*.FIT", "FITS files")
    If f$ = "" Then Exit Sub
    p$ = f$ + Chr$(0)
    r = qc_master_load&(t, _Offset(p$))
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    calOn(t) = -1
    mFile$(t) = ShortMasterName$(f$)
    ApplyCalib
    RefreshMasters
    statusMsg$ = "Loaded " + ItemOf$("dark|flat", t + 1) + ": " + mFile$(t)
End Sub

Sub MasterPanel (y As Long, t As Long)
    ' one block for the dark (t=0) or the flat (t=1): status, checkbox, load/clear
    Dim s$, v As Long, bw As Long, warn$
    bw = (PANEL_W - 34) \ 2
    If t = 0 Then s$ = "Dark: " Else s$ = "Flat: "
    If mLoaded(t) Then
        s$ = s$ + I2S$(mN(t)) + " fr  " + I2S$(mExp(t) \ 1000) + "ms  g" + I2S$(mGain(t))
        If mTemp(t) <> 0 Then s$ = s$ + "  " + Fmt1$(mTemp(t) / 10) + "C"
        PInfo y, s$
        ' warnings: size first (then it is not applied at all), then settings
        warn$ = ""
        If camConn Then
            If qc_master_fits&(t) = 0 Then
                warn$ = "size " + I2S$(mW(t)) + "x" + I2S$(mH(t)) + " <> frame - not applied"
            ElseIf t = 0 Then
                If Abs(mExp(t) - expMs * 1000) > 1000 Or mGain(t) <> gainV Then warn$ = "exposure/gain differ from now"
                If camCooled And mTemp(t) <> 0 And Abs(mTemp(t) - statTemp) > 30 Then warn$ = "temperature differs by >3C"
            ElseIf mGain(t) <> gainV Then
                warn$ = "gain differs from now"
            End If
        End If
        If Len(warn$) Then PInfoC y, "! " + warn$, C_REC
    Else
        PInfo y, s$ + "none"
    End If
    If t = 0 Then v = PCheck&(y, "Subtract dark (preview)", calOn(0)) Else v = PCheck&(y, "Divide by flat (preview)", calOn(1))
    If v <> calOn(t) Then
        calOn(t) = v
        ApplyCalib
        If v And mLoaded(t) = 0 Then statusMsg$ = "No master " + ItemOf$("dark|flat", t + 1) + " yet - capture or load one."
    End If
    If Btn%(10, y, bw, 24, "Load " + ItemOf$("dark|flat", t + 1) + "...", 0) Then LoadMasterDialog t
    If Btn%(14 + bw, y, bw, 24, "Clear", 0) Then
        qc_master_clear t
        calOn(t) = 0
        mFile$(t) = ""
        ApplyCalib
        RefreshMasters
        statusMsg$ = "Master " + ItemOf$("dark|flat", t + 1) + " cleared"
    End If
    y = y + 32
End Sub

Sub GpuInit
    Dim r As Long, b$, m As Long, cc As Long, n As Long, c As Long, gs As Long, us As Long, t As Long, md As Single
    r = qc_gpu_init&(gpuDev - 1)
    b$ = Space$(128)
    gpuActive = qc_gpu_info&(_Offset(b$), 128, m, cc, n)
    gpuName$ = ZStr$(b$): gpuMem = m: gpuCC = cc: gpuDevs = n
    gpuReady = -1
    If gpuActive Then
        t = qc_gpu_selftest&(c, gs, us)
        If t = 1 Then
            t = qc_gpu_stack_selftest&(md)
            If t = 1 Then
                gpuTest$ = "Self-test OK: score + stack"
                statusMsg$ = "GPU ready: " + gpuName$ + "  " + I2S$(gpuMem) + " MB - self-test OK (scoring + stacking)"
            ElseIf t = -2 Then
                gpuTest$ = "Self-test OK (stack busy)"
                statusMsg$ = "GPU ready: " + gpuName$ + " - stack test skipped while stacking"
            Else
                gpuTest$ = "Score OK, stack test FAILED"
                statusMsg$ = "GPU scoring OK, but stacking stays on CPU: " + LibErr$
            End If
        Else
            gpuTest$ = "Self-test FAILED - using CPU"
            statusMsg$ = LibErr$
            gpuActive = 0
        End If
    Else
        gpuTest$ = ""
        b$ = LibErr$
        If Left$(b$, 7) = "ERROR: " Then b$ = Mid$(b$, 8)
        statusMsg$ = "CPU mode - " + b$
    End If
End Sub

Function ShortGpu$ (n$)
    ' "NVIDIA GeForce GTX 745" -> "GTX 745"
    Dim s$
    s$ = n$
    If Left$(s$, 7) = "NVIDIA " Then s$ = Mid$(s$, 8)
    If Left$(s$, 8) = "GeForce " Then s$ = Mid$(s$, 9)
    ShortGpu$ = s$
End Function

Sub QualityOnOff
    Dim r As Long
    r = qc_quality_enable&(-(showQual <> 0))
End Sub

Sub PollQuality
    Dim r As Long, a As Single, b As Single, k As Long, j As Long, m As Single
    r = qc_lucky_stats&(a, b, k, j, m)
    qLast = a: qThresh = b: qKept = k: qRej = j: qMs = m
    qN = qc_score_history&(_Offset(qHist(0)), 256)
End Sub

Sub DrawQualityGraph
    ' sharpness history, top right of the image; red line = lucky keep threshold
    Dim gx As Long, gy As Long, gw As Long, gh As Long, i As Long, mx2 As Single, x1 As Long, y1 As Long, x2 As Long, y2 As Long, s$
    PollQuality ' every frame, so focusing feels live
    gw = 300: gh = 110: gx = IMG_W - gw - 14: gy = 60
    Line (gx - 6, gy - 22)-(gx + gw + 6, gy + gh + 22), _RGBA32(0, 0, 0, 200), BF
    Line (gx - 6, gy - 22)-(gx + gw + 6, gy + gh + 22), C_ACCDIM, B
    Color C_TXT: _PrintString (gx, gy - 19), "Sharpness  " + Fmt1$(qLast)
    If qN < 2 Then
        Color C_DIM: _PrintString (gx, gy + 40), "waiting for frames..."
        Exit Sub
    End If
    mx2 = 0
    For i = 0 To qN - 1
        If qHist(i) > mx2 Then mx2 = qHist(i)
    Next
    If mx2 <= 0 Then mx2 = 1
    For i = 1 To qN - 1
        x1 = gx + ((i - 1) * gw) \ 255: x2 = gx + (i * gw) \ 255
        y1 = gy + gh - CLng(qHist(i - 1) / mx2 * gh): y2 = gy + gh - CLng(qHist(i) / mx2 * gh)
        Line (x1, y1)-(x2, y2), C_OK
    Next
    If luckyOn And qThresh > 0 Then
        y1 = gy + gh - CLng(qThresh / mx2 * gh)
        Line (gx, y1)-(gx + gw, y1), C_REC
    End If
    If luckyOn And recOn Then
        s$ = "kept " + I2S$(qKept) + "  rejected " + I2S$(qRej)
    Else
        s$ = "peak " + Fmt1$(mx2)
    End If
    Color C_DIM: _PrintString (gx, gy + gh + 4), s$
End Sub

Sub StartStack
    Dim r As Long, onGpu As Long
    If camConn = 0 Then statusMsg$ = "Connect a camera first.": Exit Sub
    If liveOn = 0 Then DoAction "Live"
    If liveOn = 0 Then Exit Sub
    r = qc_stack_hotfix&(-(stkHot <> 0))
    r = qc_stack_align&(-(stkAlign <> 0))
    stkB0 = blackV: stkW0 = whiteV: stkG0 = gammaV ' keep the live stretch for when stacking stops
    r = qc_stack_start&(stackIdx - 1)
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    stkOn = -1: stkView = -1: stkAuto = 0: skN = 0: stkMsg$ = ""
    onGpu = (r = 1)
    r = qc_stack_view&(1)
    forceDraw = -1: lastGeom$ = ""
    If onGpu Then
        statusMsg$ = "Live stacking (" + ItemOf$("mean|sigma clip", stackIdx) + ") on the " + ShortGpu$(gpuName$)
    Else
        statusMsg$ = "Live stacking (" + ItemOf$("mean|sigma clip", stackIdx) + ") on the CPU"
    End If
End Sub

Sub StopStack
    Dim r As Long
    qc_stack_stop
    stkOn = 0
    PollStackNow
    ' go back to the live picture - the stack is kept (Save stack / Show: Stack still work)
    stkView = 0: r = qc_stack_view&(0)
    blackV = stkB0: whiteV = stkW0: gammaV = stkG0: qcSetStretch
    forceDraw = -1: lastGeom$ = ""
    statusMsg$ = "Stacking stopped at " + I2S$(skN) + " frames (" + HMS$(skExp) + ") - back to live view. Save stack to keep it, or Show: Stack to look at it."
End Sub

Sub PollStack
    PollStackNow
    ' once a few frames are in, stretch the faint stack so it is visible
    If stkAuto = 0 And skN >= 3 And stkView Then AutoStretch: stkAuto = -1
End Sub

Sub PollStackNow
    Dim b$, r As Long
    stkMode = qc_stack_stats&(skN, skFail, skSkip, skStars, skMatch, skDx, skDy, skRot, skRms, skMs, skExp)
    b$ = Space$(160)
    r = qc_stack_message&(_Offset(b$), 160)
    stkMsg$ = ZStr$(b$)
End Sub

Sub SaveStack
    Dim p$, f$, r As Long
    If skN = 0 Then statusMsg$ = "Nothing stacked yet.": Exit Sub
    f$ = exeDir$ + "stacks/Stack_" + StampName$ + "_" + I2S$(skN) + "x.fits"
    p$ = f$ + Chr$(0)
    r = qc_stack_save&(_Offset(p$))
    If r < 0 Then statusMsg$ = LibErr$ Else statusMsg$ = "Stack saved -> stacks/" + ShortMasterName$(f$) + "  (32-bit FITS)"
End Sub

Function TeleScale! ()
    TeleScale! = 206.265 * camPix(camSel) * binIdx / scopeFL(scopeSel)
End Function

Sub StartSolve
    Dim src$, wk$, ix$, op$, r As Long, sc As Single, f$, srcN As Long, img&, m As _MEM, tl As Long
    If solveOn Then Exit Sub
    If solveSrc = 3 Then
        f$ = _OpenFileDialog$("Image to plate solve", exeDir$, "*.fits|*.fit|*.jpg|*.jpeg|*.png", "FITS / JPEG / PNG images")
        If f$ = "" Then statusMsg$ = "Plate solve: no file chosen": Exit Sub
        solveFile$ = f$
    ElseIf solveSrc = 4 Then
        ' PoleMaster frame (polar alignment): no camera checks
    Else
        If camConn = 0 Then statusMsg$ = "Connect a camera first (or choose Image: Image file).": Exit Sub
        If solveSrc = 1 And liveOn = 0 Then statusMsg$ = "Start Live first - the solver uses the newest frame.": Exit Sub
        If solveSrc = 2 And skN = 0 Then statusMsg$ = "Nothing stacked yet - start Live Stack or pick Live frame.": Exit Sub
    End If
    If _DirExists(idxDir$) = 0 Then statusMsg$ = "Index folder not found: " + idxDir$ + " - set it with Index folder (Plate Solve panel)": Exit Sub
    ' camera images: telescope scale + last position; image files: blind (any scale, whole sky)
    ' (PoleMaster: its lens is not in the telescope list - solve without a scale hint;
    '  its 11 degree field only needs the small index files, so that is still quick)
    If solveHint = 1 And solveSrc < 3 Then sc = TeleScale! Else sc = 0
    If solveNear And haveLastPos And solveSrc <> 3 Then
        r = qc_solve_hint&(lastRA, lastDec, _Max(3, lastField * 3 / 60))
    Else
        r = qc_solve_hint&(0, 0, 0)
    End If
    If sc > 0 Then tl = 60 Else tl = 180
    src$ = solveFile$ + Chr$(0)
    wk$ = exeDir$ + "solve" + Chr$(0)
    ix$ = idxDir$ + Chr$(0)
    ' polar alignment solves are throw-away: no solved image saved
    If solveNoSave Then op$ = Chr$(0) Else op$ = exeDir$ + "solves/Solve_" + StampName$ + ".fits" + Chr$(0)
    srcN = solveSrc - 1
    If solveSrc = 4 Then srcN = 4 ' library source 4 = PoleMaster
    If solveSrc = 3 And IsFitsName%(solveFile$) = 0 Then
        ' JPEG / PNG etc: QB64 decodes it, the library gets the pixels
        img& = _LoadImage(solveFile$, 32)
        If img& >= -1 Then statusMsg$ = "Could not open image " + ShortMasterName$(solveFile$): Exit Sub
        m = _MemImage(img&)
        r = qc_solve_set_pixels&(m.OFFSET, _Width(img&), _Height(img&))
        _MemFree m
        _FreeImage img&
        If r < 0 Then statusMsg$ = "Plate solve: " + LibErr$: Exit Sub
        srcN = 3
    End If
    ' camera frames taken through the scope can sync the mount (not files, not the PoleMaster)
    svMnt = mntOpen And (srcN = 0 Or srcN = 1)
    If svMnt Then svA = mntRA: svD = mntDec: svLST = qc_mount_lst#(siteLon)
    r = qc_solve_start&(srcN, _Offset(src$), _Offset(wk$), _Offset(ix$), _Offset(op$), sc, tl)
    If r < 0 Then statusMsg$ = "Plate solve: " + LibErr$: svMnt = 0: Exit Sub
    solveOn = -1: solveState = 1: solveMsg$ = ""
    Select Case solveSrc
        Case 1: statusMsg$ = "Plate solving the live frame..."
        Case 2: statusMsg$ = "Plate solving the stack (" + I2S$(skN) + " frames)..."
        Case 4: statusMsg$ = "Plate solving the PoleMaster frame..."
        Case Else: statusMsg$ = "Plate solving " + ShortMasterName$(solveFile$) + "..."
    End Select
    If sc = 0 Then statusMsg$ = statusMsg$ + " (blind solve - up to 3 minutes)"
End Sub

Sub LoadSite
    ' QBCap_site.txt holds the observing site (only used to split the polar
    ' alignment error into altitude and azimuth). Created with a default
    ' (Kitt Peak, AZ) the first time; edit it with your own numbers.
    Dim f$, ff As Long, l$, k As Long, key$, v$, r As Long
    siteLat = 31.958: siteLon = -111.6: siteFile = 0
    f$ = exeDir$ + "QBCap_site.txt"
    If _FileExists(f$) = 0 Then
        ff = FreeFile
        Open f$ For Output As #ff
        Print #ff, "# QBCap observing site - only used to split the polar alignment error"
        Print #ff, "# into altitude and azimuth. Replace the default (Kitt Peak, AZ) with"
        Print #ff, "# your own site: decimal degrees, latitude north +, longitude east + / west -"
        Print #ff, "# then change default = yes to default = no"
        Print #ff, "latitude = 31.958"
        Print #ff, "longitude = -111.600"
        Print #ff, "default = yes"
        Close #ff
    End If
    ff = FreeFile
    Open f$ For Input As #ff
    siteFile = -1
    Do While Not EOF(ff)
        Line Input #ff, l$
        l$ = LTrim$(RTrim$(l$))
        k = InStr(l$, "=")
        If k > 0 And Left$(l$, 1) <> "#" Then
            key$ = LCase$(RTrim$(Left$(l$, k - 1))): v$ = LTrim$(Mid$(l$, k + 1))
            Select Case key$
                Case "latitude": siteLat = Val(v$)
                Case "longitude": siteLon = Val(v$)
                Case "default": If LCase$(Left$(v$, 1)) = "y" Then siteFile = 0
            End Select
        End If
    Loop
    Close #ff
    r = qc_pa_set_site&(siteLat, siteLon)
End Sub

Sub PmConnected
    Dim b$, r As Long, w As Long, h As Long, pu As Long, fr As Long
    pmOpen = -1
    r = qc_pm_set&(pmExp, pmGain)
    b$ = Space$(64)
    r = qc_pm_info&(_Offset(b$), 64, w, h, pu, fr)
    pmName$ = ZStr$(b$): pmW = w: pmH = h: pmFrames = fr
    statusMsg$ = "PoleMaster connected: " + pmName$ + "  " + I2S$(w) + " x " + I2S$(h)
End Sub

Sub PollPm
    Dim b$, r As Long, w As Long, h As Long, pu As Long, fr As Long
    b$ = Space$(64)
    r = qc_pm_info&(_Offset(b$), 64, w, h, pu, fr)
    pmW = w: pmH = h: pmFrames = fr: pmSat = (pu < 0)
End Sub

' the image view shows the PoleMaster while it is the polar align camera and the panel is open
Function PmView%
    PmView% = (paCam = 2 And pmOpen <> 0 And grpOpen(12) <> 0)
End Function

Sub PolarReset
    Dim r As Long
    r = qc_pa_reset&
    paStep = 0: paPending = 0: paAuto = 0: paRes = 0
    If solveOn Then qc_solve_cancel
    statusMsg$ = "Polar align: start again - aim near the pole, Step 1."
End Sub

' ask for a live-frame solve; PolarSolved runs when it finishes
Sub PolarStep (stp As Long)
    Dim keep As Long
    If paCam = 2 Then
        If pmOpen = 0 Then statusMsg$ = "PoleMaster not connected - pick it again under Camera.": Exit Sub
        If pmFrames < 1 Then statusMsg$ = "Waiting for the first PoleMaster frame...": Exit Sub
    Else
        If camConn = 0 Then statusMsg$ = "Connect a camera first.": Exit Sub
        If liveOn = 0 Then DoAction "Live"
        If liveOn = 0 Then Exit Sub
    End If
    If solveOn Then Exit Sub
    keep = solveSrc: solveSrc = 1
    If paCam = 2 Then solveSrc = 4
    solveNoSave = -1
    If stp = 3 Then
        ' repeat solves while adjusting: keep the status bar (and the log) quiet
        Dim keepMsg$
        keepMsg$ = statusMsg$
        StartSolve
        If solveOn Then statusMsg$ = keepMsg$
    Else
        StartSolve
    End If
    solveSrc = keep
    solveNoSave = 0
    If solveOn Then paPending = stp
End Sub

Sub PolarSolved
    Dim r As Long, stp As Long
    stp = paPending: paPending = 0
    Select Case stp
        Case 1
            r = qc_pa_capture&(1)
            If r < 0 Then statusMsg$ = "Polar align: " + LibErr$: Exit Sub
            paStep = 1
            statusMsg$ = "Polar align step 1 done - turn the mount 60-90 deg in RA, then Step 2."
        Case 2
            r = qc_pa_capture&(2)
            If r < 0 Then statusMsg$ = "Polar align: " + LibErr$: Exit Sub
            paStep = 2: paAuto = -1: paLastT = Timer(.001)
            PolarFetch
            statusMsg$ = "Polar error " + Fmt1$(CSng(paTot)) + " arcmin (RA turned " + Fmt1$(CSng(paRot)) + " deg) - now adjust ALT / AZ"
        Case 3
            r = qc_pa_update&
            If r < 0 Then statusMsg$ = "Polar align: " + LibErr$: Exit Sub
            PolarFetch
    End Select
End Sub

Sub PolarFetch
    paRes = qc_pa_result&(paTot, paAlt, paAz, paRot, paAX, paAY, paPX, paPY, paPOk)
End Sub

' adjusting: start the next solve shortly after the last one finished
Sub PollPolar
    Dim t As Double
    If solveOn Or paPending Then Exit Sub
    t = Timer(.001)
    If paLastT > 0 And t >= paLastT And t - paLastT < 0.5 Then Exit Sub
    paLastT = t
    PolarStep 3
End Sub

Function PolarArc$ (m As Double)
    ' arcmin -> "12.3'" or "45"" under one arcminute
    If Abs(m) < 1 Then PolarArc$ = I2S$(CLng(Abs(m) * 60)) + Chr$(34) Else PolarArc$ = Fmt1$(CSng(Abs(m))) + "'"
End Function

Function AltWord$
    ' axis too high (+) -> lower the mount
    If paAlt > 0 Then AltWord$ = "Alt: LOWER " + PolarArc$(paAlt) Else AltWord$ = "Alt: RAISE " + PolarArc$(paAlt)
End Function

Function AzWord$
    ' axis too far east (+) -> turn it west
    If paAz > 0 Then AzWord$ = "Az: move WEST " + PolarArc$(paAz) Else AzWord$ = "Az: move EAST " + PolarArc$(paAz)
End Function

Sub PolarReadout (y As Long)
    Dim c As _Unsigned Long
    If paRes < 2 Then Exit Sub
    If paTot < 1 Then c = C_OK Else If paTot < 5 Then c = _RGB32(255, 200, 80) Else c = C_REC
    PInfoC y, "Polar error: " + PolarArc$(paTot), c
    PInfo y, AltWord$
    PInfo y, AzWord$
    PInfo y, "(RA turn was " + Fmt1$(CSng(paRot)) + " deg)"
End Sub

' image overlay: yellow ring = where the mount axis points, red cross = true pole
Sub DrawPolarOverlay (dx As Long, dy As Long, dw As Long, dh As Long, sx As Long, sy As Long, sw As Long, sh As Long)
    Dim k As Single, ax As Single, ay As Single, px As Single, py As Single, s$
    If paStep <> 2 Or paRes < 2 Then Exit Sub
    k = dw / sw
    ax = dx + (paAX - sx) * k: ay = dy + (paAY - sy) * k
    px = dx + (paPX - sx) * k: py = dy + (paPY - sy) * k
    If paPOk Then Line (ax, ay)-(px, py), _RGBA32(255, 255, 255, 140)
    Circle (ax, ay), 14, _RGB32(255, 220, 60)
    Circle (ax, ay), 15, _RGB32(255, 220, 60)
    If paPOk Then
        Line (px - 10, py)-(px + 10, py), _RGB32(255, 70, 70)
        Line (px, py - 10)-(px, py + 10), _RGB32(255, 70, 70)
    End If
    Line (8, IMG_H - 70)-(390, IMG_H - 30), _RGBA32(0, 0, 0, 190), BF
    Color _RGB32(255, 220, 60): _PrintString (14, IMG_H - 66), "POLAR " + PolarArc$(paTot) + "   " + AltWord$
    Color C_TXT: _PrintString (14, IMG_H - 48), "ring = mount axis  + = pole   " + AzWord$
    If (ax < 0 Or ay < 0 Or ax >= IMG_W Or ay >= IMG_H) Then
        s$ = "(mount axis is off the screen)"
        Color C_DIM: _PrintString (IMG_W - Len(s$) * 8 - 10, IMG_H - 44), s$
    End If
End Sub

Function IsFitsName% (f$)
    Dim e$
    e$ = LCase$(Mid$(f$, _InStrRev(f$, ".") + 1))
    IsFitsName% = (e$ = "fits" Or e$ = "fit" Or e$ = "fts")
End Function

Sub PollSolve
    Dim b$, r As Long
    solveState = qc_solve_result&(solRA, solDec, solFW, solFH, solRot, solScale, solSecs, solStars)
    b$ = Space$(200)
    r = qc_solve_message&(_Offset(b$), 200)
    solveMsg$ = ZStr$(b$)
    If solveState = 1 Then Exit Sub
    solveOn = 0
    If solveState = 2 Then
        If solveSrc <> 3 Then haveLastPos = -1: lastRA = solRA: lastDec = solDec: lastField = _Max(solFW, solFH)
        b$ = Space$(1000)
        r = qc_solve_saved&(_Offset(b$), 1000)
        solveSaved$ = ZStr$(b$)
        ' (quiet while polar alignment re-solves every second - the panel shows the result)
        If paPending <> 3 Then statusMsg$ = "Solved: RA " + RAStr$(solRA) + "  Dec " + DecStr$(solDec) + "  rot " + Fmt1$(solRot) + " deg  " + Fmt2$(solScale) + " arcsec/px  (" + Fmt1$(solSecs) + " s)"
        If Len(solveSaved$) And paPending <> 3 Then LogLine "  solved image -> solves/" + ShortMasterName$(solveSaved$)
        If paPending Then PolarSolved
        If svMnt Then svMnt = 0: MountSolved
    Else
        If paPending <> 3 Then statusMsg$ = "Plate solve: " + solveMsg$
        If svMnt Then
            svMnt = 0
            If lrnStep Or gotoState Then
                lrnStep = 0: gotoState = 0
                statusMsg$ = "Plate solve failed (" + solveMsg$ + ") - mount stays where it is."
            End If
        End If
        If paPending Then paPending = 0: If paStep = 2 Then paLastT = Timer(.001)
    End If
End Sub

' RA degrees -> "05h 35m 14.3s"
Function RAStr$ (raDeg As Double)
    Dim t As Double, h As Long, m As Long, sc As Double, s$
    t = raDeg / 15#
    If t < 0 Then t = t + 24#
    h = Int(t): t = (t - h) * 60#: m = Int(t): sc = (t - m) * 60#
    If sc >= 59.95 Then sc = 0: m = m + 1
    If m >= 60 Then m = 0: h = (h + 1) Mod 24
    s$ = LTrim$(Str$(Int(sc * 10 + 0.5) / 10))
    If InStr(s$, ".") = 0 Then s$ = s$ + ".0"
    If Left$(s$, 1) = "." Then s$ = "0" + s$
    If sc < 10 Then s$ = "0" + s$
    RAStr$ = Right$("0" + I2S$(h), 2) + "h " + Right$("0" + I2S$(m), 2) + "m " + s$ + "s"
End Function

' Dec degrees -> "-05d 24' 09""
Function DecStr$ (decDeg As Double)
    Dim t As Double, d As Long, m As Long, sc As Long, sg$
    If decDeg < 0 Then sg$ = "-" Else sg$ = "+"
    t = Abs(decDeg)
    d = Int(t): t = (t - d) * 60#: m = Int(t): sc = CLng((t - m) * 60#)
    If sc >= 60 Then sc = 0: m = m + 1
    If m >= 60 Then m = 0: d = d + 1
    DecStr$ = sg$ + Right$("0" + I2S$(d), 2) + Chr$(248) + " " + Right$("0" + I2S$(m), 2) + "' " + Right$("0" + I2S$(sc), 2) + Chr$(34)
End Function

Sub AutoStretch
    Dim b As Long, w As Long, gm As Long, r As Long
    r = qc_auto_stretch&(b, w, gm)
    If r < 0 Then statusMsg$ = LibErr$: Exit Sub
    blackV = b: whiteV = w: gammaV = gm
    qcSetStretch
    statusMsg$ = "Auto stretch: black " + I2S$(b) + "  white " + I2S$(w) + "  gamma " + Fmt2$(gm / 100)
End Sub

Function HMS$ (secs As Single)
    Dim t As Long, h As Long, m As Long, sc As Long
    t = CLng(secs): h = t \ 3600: m = (t \ 60) Mod 60: sc = t Mod 60
    If h > 0 Then
        HMS$ = I2S$(h) + "h " + Right$("0" + I2S$(m), 2) + "m " + Right$("0" + I2S$(sc), 2) + "s"
    Else
        HMS$ = I2S$(m) + "m " + Right$("0" + I2S$(sc), 2) + "s"
    End If
End Function

'==================================================================
'  STUBS  -  not written yet (next steps)
'==================================================================
Sub StubCall (fn$)
    statusMsg$ = "STUB  " + fn$ + "   (not in libqbcap.so yet)"
End Sub

Sub qcLuckyEnable (onFlag As Long, pct As Long)
    Dim r As Long
    r = qc_lucky_set&(-(onFlag <> 0), pct)
    QualityOnOff
    If onFlag Then
        statusMsg$ = "Lucky imaging ON - recordings keep the sharpest " + I2S$(pct) + "% of frames"
    Else
        statusMsg$ = "Lucky imaging off - recordings keep every frame"
    End If
End Sub



'==================================================================
'  MOUNT  (step 10 - Sky-Watcher / Orion SynScan motor protocol)
'==================================================================
Sub LoadMountAddr
    ' QBCap_mount.txt: "address = 192.168.4.1" (mount WiFi) or "address = /dev/ttyUSB0" (USB)
    Dim f$, ff As Long, l$, k As Long
    f$ = exeDir$ + "QBCap_mount.txt"
    If _FileExists(f$) = 0 Then
        ff = FreeFile
        Open f$ For Output As #ff
        Print #ff, "# QBCap mount connection"
        Print #ff, "#   WiFi (computer joined to the mount's WiFi): address = 192.168.4.1"
        Print #ff, "#   USB cable:                                 address = /dev/ttyUSB0"
        Print #ff, "#   (EQDIR cable at 9600 baud:                 address = /dev/ttyUSB0,9600)"
        Print #ff, "address = 192.168.4.1"
        Close #ff
    End If
    ff = FreeFile
    Open f$ For Input As #ff
    Do While Not EOF(ff)
        Line Input #ff, l$
        l$ = LTrim$(RTrim$(l$))
        k = InStr(l$, "=")
        If k > 0 And Left$(l$, 1) <> "#" Then
            If LCase$(RTrim$(Left$(l$, k - 1))) = "address" Then mntAddr$ = LTrim$(Mid$(l$, k + 1))
        End If
    Loop
    Close #ff
End Sub

Sub LoadIndexDir
    ' QBCap_index.txt: "folder = /path/to/index files" (the index-*.fits files
    ' astrometry.net solves with). Default: the "index" folder next to QBCap.
    ' Set it from the Plate Solve panel (Index folder...) or edit the file.
    Dim f$, ff As Long, l$, k As Long
    idxDir$ = exeDir$ + "index"
    f$ = exeDir$ + "QBCap_index.txt"
    If _FileExists(f$) = 0 Then SaveIndexDir: Exit Sub
    ff = FreeFile
    Open f$ For Input As #ff
    Do While Not EOF(ff)
        Line Input #ff, l$
        l$ = LTrim$(RTrim$(l$))
        k = InStr(l$, "=")
        If k > 0 And Left$(l$, 1) <> "#" Then
            If LCase$(RTrim$(Left$(l$, k - 1))) = "folder" Then idxDir$ = LTrim$(Mid$(l$, k + 1))
        End If
    Loop
    Close #ff
    If Len(idxDir$) > 1 And Right$(idxDir$, 1) = "/" Then idxDir$ = Left$(idxDir$, Len(idxDir$) - 1)
End Sub

Sub SaveIndexDir
    Dim ff As Long
    ff = FreeFile
    Open exeDir$ + "QBCap_index.txt" For Output As #ff
    Print #ff, "# QBCap plate solve index folder - the folder holding the"
    Print #ff, "# astrometry.net index-*.fits files (spaces in the path are fine)"
    Print #ff, "folder = " + idxDir$
    Close #ff
End Sub

Sub LoadScope
    ' QBCap_scope.txt: "scope = 2" - which Telescope entry is selected
    ' (1 = 203mm f/10, 2 = 10in 1200mm, 3 = 8in 1000mm). Sets the FITS
    ' TELESCOP/FOCALLEN cards and the plate solve scale hint.
    Dim f$, ff As Long, l$, k As Long, v As Long
    f$ = exeDir$ + "QBCap_scope.txt"
    If _FileExists(f$) = 0 Then SaveScope: Exit Sub
    ff = FreeFile
    Open f$ For Input As #ff
    Do While Not EOF(ff)
        Line Input #ff, l$
        l$ = LTrim$(RTrim$(l$))
        k = InStr(l$, "=")
        If k > 0 And Left$(l$, 1) <> "#" Then
            If LCase$(RTrim$(Left$(l$, k - 1))) = "scope" Then
                v = Val(Mid$(l$, k + 1))
                If v >= 1 And v <= NSCOPE Then scopeSel = v
            End If
        End If
    Loop
    Close #ff
End Sub

Sub SaveScope
    Dim ff As Long
    ff = FreeFile
    Open exeDir$ + "QBCap_scope.txt" For Output As #ff
    Print #ff, "# QBCap telescope - 1 = 203mm f/10 (2032mm), 2 = 10in (1200mm), 3 = 8in (1000mm)"
    Print #ff, "# (set from the Telescope panel)"
    Print #ff, "scope ="; scopeSel
    Close #ff
End Sub

Sub PickIndexDir
    Dim d$
    If solveOn Then statusMsg$ = "Wait for the plate solve to finish (or cancel it) first.": Exit Sub
    d$ = _SelectFolderDialog$("Folder with the index-*.fits files", idxDir$)
    If d$ = "" Then statusMsg$ = "Index folder unchanged: " + idxDir$: Exit Sub
    If Len(d$) > 1 And Right$(d$, 1) = "/" Then d$ = Left$(d$, Len(d$) - 1)
    idxDir$ = d$
    SaveIndexDir
    statusMsg$ = "Plate solve index folder: " + idxDir$ + "  (saved in QBCap_index.txt)"
End Sub

Sub MountConnect
    Dim a$, b$, r As Long, tries As Long
    a$ = mntAddr$ + Chr$(0)
    For tries = 1 To 6
        If qc_mount_open&(_Offset(a$)) = 0 Then Exit For
        qc_mount_close
        _Delay 0.25
    Next
    If tries > 6 Then statusMsg$ = "Mount: no answer after 6 tries (weak WiFi?) " + LibErr$: Exit Sub
    mntOpen = -1: mntTrack = 0: mntOk = 1: mntMsg$ = "": mntFail = 0
    b$ = Space$(128): r = qc_mount_info&(_Offset(b$), 128): mntInfo$ = ZStr$(b$)
    r = qc_mount_message&(_Offset(b$), 128): mntMsgSeq = r
    statusMsg$ = "Mount connected: " + mntInfo$
    If tries > 1 Then statusMsg$ = statusMsg$ + " (took " + I2S$(tries) + " tries - weak link)"
End Sub

Sub MountDisconnect
    qc_mount_close
    mntOpen = 0: mntTrack = 0: mntHeld(1) = 0: mntHeld(2) = 0
    statusMsg$ = "Mount disconnected (both axes stopped)."
End Sub

Sub PollMount
    Static lastT As Double
    Dim tNow As Double, r As Long, sq As Long, b$, ra As Double, de As Double, s1 As Long, s2 As Long, tr As Long
    tNow = Timer(.001)
    If tNow >= lastT And tNow - lastT < 0.2 Then Exit Sub
    lastT = tNow
    r = qc_mount_status&(ra, de, s1, s2, tr)
    mntOk = r
    If r <> 0 Then mntRA = ra: mntDec = de: mntRASt = s1: mntDecSt = s2: mntTrack = tr
    mntLST = qc_mount_lst#(siteLon)
    UpdateMoon
    b$ = Space$(200)
    sq = qc_mount_message&(_Offset(b$), 200)
    If sq <> mntMsgSeq Then
        mntMsgSeq = sq
        mntMsg$ = ZStr$(b$): mntMsgT = tNow
        statusMsg$ = "MOUNT: " + mntMsg$
        ' a stop of any kind ends the automatic sequences
        If InStr(mntMsg$, "STALL") Or InStr(mntMsg$, "LOST") Or InStr(mntMsg$, "cancel") Or InStr(mntMsg$, "too long") Or InStr(mntMsg$, "refused") Then
            gotoState = 0: lrnStep = 0: paTurn = 0: mntGoWait = 0
        End If
    End If
    MountGotoEvents ' after the message, so its own status line is the one shown
End Sub

' press-and-hold button: returns -1 while the mouse button is held on it
Function HoldBtn% (x As Long, y As Long, w As Long, h As Long, label$)
    Dim hot As Long, held As Long, c As _Unsigned Long
    hot = InRect%(x, y, w, h)
    held = hot And mDown
    If held Then
        c = C_BTNON
    ElseIf hot Then
        c = C_BTNHOT
    Else
        c = C_BTN
    End If
    Line (x, y)-(x + w - 1, y + h - 1), c, BF
    Line (x, y)-(x + w - 1, y + h - 1), C_EDGE, B
    Color C_TXT
    _PrintString (x + (w - Len(label$) * 8) \ 2, y + (h - 16) \ 2), label$
    If hot And mClick Then mClick = 0
    HoldBtn% = held
End Function

Sub MountPanel (y As Long)
    Dim v As Long, bw As Long, x1 As Long, x2 As Long, x3 As Long, r As Long, s$, c As _Unsigned Long
    If mntOpen = 0 Then
        PInfo y, "Address " + mntAddr$ + "  (QBCap_mount.txt)"
        If PButton%(y, "Connect mount", 0) Then MountConnect
        PInfo y, "WiFi: join the mount's WiFi, close"
        PInfo y, "SynScan. Weak signal = retries."
        Exit Sub
    End If
    PInfo y, mntInfo$ + "   " + mntAddr$
    If mntFail >= 3 Then PInfoC y, "NO ANSWER FROM THE MOUNT", C_REC
    PInfo y, "RA axis " + Fmt2$(CSng(mntRA)) + " deg   Dec axis " + Fmt2$(CSng(mntDec)) + " deg"
    s$ = "RA: " + ItemOf$("stopped|moving|tracking", mntRASt + 1) + "   Dec: " + ItemOf$("stopped|moving", mntDecSt + 1)
    PInfoC y, s$, C_TXT
    v = PCycler&(y, "Speed", "1x sidereal|8x sidereal|32x sidereal|0.5 deg/s|1 deg/s|2 deg/s", mntSpeed)
    If v <> mntSpeed Then mntSpeed = v
    ' direction pad: hold to move, let go to stop (east on the left, as when facing south)
    bw = (PANEL_W - 38) \ 3
    x1 = 10: x2 = x1 + bw + 4: x3 = x2 + bw + 4
    If HoldBtn%(x2, y, bw, 26, "Dec +") Then mntWant(2) = 1
    y = y + 30
    If HoldBtn%(x1, y, bw, 26, "East") Then mntWant(1) = -1
    If Btn%(x2, y, bw, 26, "STOP", 2) Then
        r = qc_mount_stop&: mntTrack = 0
        gotoState = 0: lrnStep = 0: paTurn = 0: mntGoWait = 0
        statusMsg$ = "Mount stopped (tracking off)."
    End If
    If HoldBtn%(x3, y, bw, 26, "West") Then mntWant(1) = 1
    y = y + 30
    If HoldBtn%(x2, y, bw, 26, "Dec -") Then mntWant(2) = -1
    y = y + 32
    PInfo y, "Hold a button to move, let go to stop."
    v = PCheck&(y, "Tracking (" + ItemOf$("sidereal|lunar", 1 - (mntLunar <> 0)) + " rate)", mntTrack)
    If v <> mntTrack Then
        mntTrack = v: r = qc_mount_track&(-(mntTrack <> 0))
        If mntTrack Then statusMsg$ = "Tracking on" Else statusMsg$ = "Tracking off"
    End If
    GotoPanel y
    If Len(mntMsg$) And Timer(.001) - mntMsgT < 60 And Timer(.001) >= mntMsgT Then
        If InStr(mntMsg$, "STALL") Or InStr(mntMsg$, "LOST") Or InStr(mntMsg$, "refused") Or InStr(mntMsg$, "too long") Then c = C_REC Else c = C_OK
        PInfoWrap y, mntMsg$, c
    End If
    If PButton%(y, "Disconnect mount", 0) Then MountDisconnect
    y = y + 6
End Sub

Sub MountJog
    Dim a As Long, r As Long
    If mntOpen = 0 Then Exit Sub
    For a = 1 To 2
        If mntWant(a) <> 0 Then
            r = qc_mount_move&(a, mntSpeed, mntWant(a))
        ElseIf mntHeld(a) <> 0 Then
            r = qc_mount_move&(a, mntSpeed, 0)
        End If
        mntHeld(a) = mntWant(a)
    Next
End Sub

Function MountStopRetry&
    Dim i As Long, r As Long
    For i = 1 To 5
        r = qc_mount_stop&
        If r = 0 Then Exit For
    Next
    MountStopRetry& = r
End Function

Function MountTrackRetry& (onFlag As Long)
    Dim i As Long, r As Long
    For i = 1 To 5
        r = qc_mount_track&(onFlag)
        If r = 0 Then Exit For
    Next
    MountTrackRetry& = r
End Function

'==================================================================
'  POINTING + GOTO  (mount sync from plate solves, Messier / star list)
'==================================================================
Sub LoadCatalog
    ' QBCap_objects.txt (made from the SynScan sky object database - Messier, Caldwell,
    ' named stars, double stars, NGC, IC) if it is there, else the built-in list.
    ' catType$ holds the list key: moon / messier / caldwell / star / double / ngc / ic
    Dim n$, c$, t$, ra As Double, de As Double, mg As Single, f$, ff As Long, l$, fld$(1 To 6), k As Long, p As Long
    catN = 1
    catName$(1) = "Moon": catDesc$(1) = "": catType$(1) = "moon": catMag(1) = -12
    UpdateMoon
    catFile = 0
    f$ = exeDir$ + "QBCap_objects.txt"
    If _FileExists(f$) Then
        ff = FreeFile
        Open f$ For Input As #ff
        Do While Not EOF(ff) And catN < NCATMAX
            Line Input #ff, l$
            If Len(l$) > 0 And Left$(l$, 1) <> "#" Then
                For k = 1 To 6
                    p = InStr(l$, "|")
                    If p = 0 Then fld$(k) = l$: l$ = "" Else fld$(k) = Left$(l$, p - 1): l$ = Mid$(l$, p + 1)
                Next
                catN = catN + 1
                catName$(catN) = fld$(1): catDesc$(catN) = fld$(2): catType$(catN) = fld$(3)
                catRA(catN) = Val(fld$(4)): catDec(catN) = Val(fld$(5)): catMag(catN) = Val(fld$(6))
            End If
        Loop
        Close #ff
        catFile = -1
        LogLine "GoTo list: " + I2S$(catN - 1) + " objects from QBCap_objects.txt"
        Exit Sub
    End If
    Restore CatalogData
    Do
        Read n$, c$, t$, ra, de, mg
        If n$ = "END" Then Exit Do
        If catN < NCATMAX Then
            catN = catN + 1
            catName$(catN) = n$: catRA(catN) = ra: catDec(catN) = de: catMag(catN) = mg
            If t$ = "star" Then
                catType$(catN) = "star": catDesc$(catN) = c$
            Else
                catType$(catN) = "messier"
                If Len(c$) Then catDesc$(catN) = c$ + ", " + t$ Else catDesc$(catN) = t$
            End If
        End If
    Loop
End Sub

' first entry of a list (key from CAT_KEYS), 0 if the list is empty
Function FirstOf& (key$)
    Dim i As Long
    For i = 1 To catN
        If catType$(i) = key$ Then FirstOf& = i: Exit Function
    Next
    FirstOf& = 0
End Function

Function ListIdx& (key$)
    Dim i As Long
    For i = 1 To ItemCount&(CAT_KEYS)
        If ItemOf$(CAT_KEYS, i) = key$ Then ListIdx& = i: Exit Function
    Next
    ListIdx& = 1
End Function

Function NormName$ (s$)
    Dim i As Long, c$, r$
    For i = 1 To Len(s$)
        c$ = UCase$(Mid$(s$, i, 1))
        If c$ <> " " Then r$ = r$ + c$
    Next
    NormName$ = r$
End Function

' Find: "M31", "ngc7000", "C14", "Vega", "2392" (number in the list shown now), or part of a name
Sub FindTarget (q$)
    Dim i As Long, w$, key$, hit As Long, pre$
    w$ = NormName$(q$)
    If w$ = "" Then Exit Sub
    key$ = catType$(tgtIdx)
    ' a bare number: that number in the list on show (NGC 7000 when NGC is showing)
    If w$ = LTrim$(Str$(Val(w$))) And (key$ = "messier" Or key$ = "caldwell" Or key$ = "ngc" Or key$ = "ic") Then
        Select Case key$
            Case "messier": pre$ = "M"
            Case "caldwell": pre$ = "C"
            Case "ngc": pre$ = "NGC"
            Case Else: pre$ = "IC"
        End Select
        For i = 1 To catN
            If catType$(i) = key$ Then
                If NormName$(catName$(i)) = pre$ + w$ Or NormName$(catName$(i)) = pre$ + w$ + "A" Then hit = i: Exit For
            End If
        Next
    End If
    If hit = 0 Then
        For i = 1 To catN
            If NormName$(catName$(i)) = w$ Then hit = i: Exit For
        Next
    End If
    If hit = 0 Then
        For i = 1 To catN
            If InStr(NormName$(catName$(i)), w$) = 1 Then hit = i: Exit For
        Next
    End If
    If hit = 0 Then
        For i = 1 To catN
            If InStr(NormName$(catDesc$(i)), w$) > 0 Then hit = i: Exit For
        Next
    End If
    If hit Then
        tgtIdx = hit: gotoState = 0
        statusMsg$ = "Found " + catName$(hit) + "  " + catDesc$(hit)
    Else
        statusMsg$ = "Nothing called '" + q$ + "' in the GoTo list."
    End If
End Sub

Sub FindKey (k$)
    Select Case k$
        Case ""
        Case Chr$(13)
            findOn = 0
            FindTarget findBuf$
        Case Chr$(27)
            findOn = 0
            statusMsg$ = "Find cancelled"
        Case Chr$(8)
            If Len(findBuf$) > 0 Then findBuf$ = Left$(findBuf$, Len(findBuf$) - 1)
        Case Else
            If Len(k$) = 1 And Asc(k$) >= 32 And Asc(k$) < 127 And Len(findBuf$) < 24 Then findBuf$ = findBuf$ + k$
    End Select
End Sub

Function Wrap180# (x As Double)
    Dim v As Double
    v = x - 360# * Int((x + 180#) / 360#)
    Wrap180# = v
End Function

Function Sgn1# (x As Double)
    If x < 0 Then Sgn1# = -1# Else Sgn1# = 1#
End Function

' altitude (deg) of hour angle / dec (deg) at the site
Function AltOf# (haDeg As Double, decDeg As Double)
    Dim d2r As Double, sa As Double
    d2r = _Pi / 180#
    sa = Sin(siteLat * d2r) * Sin(decDeg * d2r) + Cos(siteLat * d2r) * Cos(decDeg * d2r) * Cos(haDeg * d2r)
    If sa > 1 Then sa = 1
    If sa < -1 Then sa = -1
    AltOf# = _Asin(sa) / d2r
End Function

' angle between two RA/Dec points (deg in, arcmin out)
Function SepArcmin# (ra1 As Double, de1 As Double, ra2 As Double, de2 As Double)
    Dim d2r As Double, c As Double
    d2r = _Pi / 180#
    c = Sin(de1 * d2r) * Sin(de2 * d2r) + Cos(de1 * d2r) * Cos(de2 * d2r) * Cos((ra1 - ra2) * d2r)
    If c > 1 Then c = 1
    If c < -1 Then c = -1
    SepArcmin# = _Acos(c) / d2r * 60#
End Function

'------------------------------------------------------------------
' German equatorial pointing model - nothing to learn.
' The SynScan axes count from where the mount was at power-up = HOME
' (counterweight down, scope at the pole). + = the West / Dec + buttons.
' Dec axis on the + side:  HA = RA axis + raIdx + 90,  Dec = 90 - (Dec axis + decIdx)
' Dec axis on the - side:  HA = RA axis + raIdx - 90,  Dec = 90 + (Dec axis + decIdx)
' (that mirror is why "Dec up" seemed to change direction between nights).
' raIdx / decIdx = how far HOME was from perfect; every plate solve measures them.
'------------------------------------------------------------------
Function AxSide& (axD As Double)
    If axD + decIdx >= 0 Then AxSide& = 1 Else AxSide& = -1
End Function

Function AxHA# (axR As Double, axD As Double)
    AxHA# = Wrap180#(axR + raIdx + 90# * AxSide&(axD))
End Function

Function AxDec# (axD As Double)
    AxDec# = 90# - Abs(axD + decIdx)
End Function

' where the scope points now
Function CurHA#
    CurHA# = AxHA#(mntRA, mntDec)
End Function
Function CurDec#
    CurDec# = AxDec#(mntDec)
End Function

Function TgtHA# (i As Long)
    TgtHA# = Wrap180#(mntLST - catRA(i) * 15#)
End Function

' a camera plate solve finished while the mount was connected: sync.
' The solve says where the scope really points; that gives the HOME error
' (raIdx, decIdx). Either side of the Dec axis could explain the solve -
' near the pole both look alike - so take the one with the smaller error.
Sub MountSolved
    Dim ha As Double, s As Long, rP As Double, dP As Double, rM As Double, dM As Double
    ha = Wrap180#(svLST - solRA)
    rP = Wrap180#(ha - 90# - svA): dP = (90# - solDec) - svD
    rM = Wrap180#(ha + 90# - svA): dM = -(90# - solDec) - svD
    If solDec > 88 Then
        ' within ~2 deg of the pole the solve cannot tell which way the scope
        ' is off, so the RA error would be a guess: keep what we have (or use
        ' HOME as it is) - the GoTo + solve passes walk it in
        If syncOk = 0 Then raIdx = 0: decIdx = 0
        LogLine "  mount sync: too close to the pole to measure the HOME error - using HOME as is"
    Else
        If Abs(rP) + Abs(dP) <= Abs(rM) + Abs(dM) Then
            raIdx = rP: decIdx = dP: s = 1
        Else
            raIdx = rM: decIdx = dM: s = -1
        End If
        LogLine "  mount sync: HOME error RA " + Fmt2$(CSng(raIdx)) + " deg, Dec " + Fmt2$(CSng(decIdx)) + " deg  (Dec axis " + ItemOf$("+|-", (s > 0) + 2) + " side)"
        If Abs(raIdx) > 20 Or Abs(decIdx) > 20 Then LogLine "  mount: big HOME error - was the mount at HOME (counterweight down, scope at the pole) when it was switched on?"
    End If
    syncOk = -1

    If gotoState = 3 Then
        GotoCheck
    Else
        statusMsg$ = statusMsg$ + "  [mount synced]"
    End If
End Sub

Function MountGoto% (dA As Double, dD As Double)
    ' the guide star leaves the guide camera during a slew: stop guiding first
    If glAlive And glAutoStop Then
        If GuideLinkSend$("STOP") <> "" Then LogLine "  guider told to stop (GoTo)"
    End If
    If qc_mount_goto_axes&(dA, dD) <> 0 Then
        statusMsg$ = "GoTo: " + LibErr$: MountGoto% = 0: Exit Function
    End If
    mntGoWait = -1: mntGoSeen = 0: mntGoT = Timer(.001)
    MountGoto% = -1
End Function

' solve the live frame for the mount (quietly, nothing saved)
Function MountSolveNow%
    Dim keep As Long
    MountSolveNow% = 0
    If camConn = 0 Then statusMsg$ = "Connect the camera (through the scope) first.": Exit Function
    If liveOn = 0 Then DoAction "Live"
    If liveOn = 0 Or solveOn Then Exit Function
    keep = solveSrc: solveSrc = 1: solveNoSave = -1
    StartSolve
    solveSrc = keep: solveNoSave = 0
    MountSolveNow% = solveOn
End Function

' called every mount poll: notice when a GoTo has finished
Sub MountGotoEvents
    Dim t As Double
    t = Timer(.001)
    ' gotoState 4: the slew is over - wait for a frame exposed after it
    ' stopped (the frame in progress during the slew has trailed stars)
    If gotoState = 4 Then
        If t >= settleT Or t < settleT - 86000 Then
            If MountSolveNow% Then
                gotoState = 3: statusMsg$ = "GoTo " + catName$(gotoTgt) + ": checking with a plate solve..."
            Else
                gotoState = 0
            End If
        End If
        Exit Sub
    End If
    If mntGoWait = 0 Then Exit Sub
    If mntRASt = 3 Then mntGoSeen = -1
    If (mntGoSeen <> 0 And mntRASt <> 3) Or (mntGoSeen = 0 And (t - mntGoT > 2 Or t < mntGoT)) Then
        mntGoWait = 0
        If gotoState = 2 And catType$(gotoTgt) = "moon" Then
            gotoState = 0
            statusMsg$ = "GoTo Moon done - tracking at the lunar rate. (No stars to plate solve on the Moon: centre it with the buttons.)"
        ElseIf gotoState = 2 Then
            If gotoCentre And camConn <> 0 Then
                ' settle 1 s, then a full new exposure (2 x exposure covers the
                ' frame in progress plus one clean one)
                settleT = t + 1 + 2 * expMs / 1000
                gotoState = 4
                statusMsg$ = "GoTo " + catName$(gotoTgt) + ": waiting " + I2S$(CLng(settleT - t)) + " s for a clean frame, then plate solving..."
            Else
                gotoState = 0: statusMsg$ = "GoTo " + catName$(gotoTgt) + " done."
            End If
        ElseIf paTurn Then
            paTurn = 0
            PolarStep 2
        End If
    End If
End Sub

Sub PolarTurn (deg As Long)
    If paTurn Or mntGoWait Then Exit Sub
    If MountGoto%(CDbl(deg), 0#) Then
        paTurn = 1
        statusMsg$ = "Polar align: turning RA " + I2S$(Abs(deg)) + " deg - Step 2 starts by itself when it stops."
    End If
End Sub

' axis positions that point at (ha, de), counterweight-down side (RA axis
' within about 90 deg of HOME) - sets gotoA/gotoD = the moves from here
Sub AimAxes (ha As Double, de As Double)
    Dim rP As Double, dP As Double, rM As Double, dM As Double, cP As Double, cM As Double
    rP = Wrap180#(ha - 90# - raIdx): dP = (90# - de) - decIdx
    rM = Wrap180#(ha + 90# - raIdx): dM = -(90# - de) - decIdx
    ' prefer the counterweight-down solution; on the meridian, the shorter move
    cP = Abs(rP) + 0.1 * Abs(rP - mntRA)
    cM = Abs(rM) + 0.1 * Abs(rM - mntRA)
    If cP <= cM Then
        gotoA = rP - mntRA: gotoD = dP - mntDec
    Else
        gotoA = rM - mntRA: gotoD = dM - mntDec
    End If
End Sub

' plan the axis moves from where we point now to target i
Function PlanGoto% (i As Long)
    Dim ha As Double
    PlanGoto% = 0
    If syncOk = 0 Then statusMsg$ = "GoTo needs a plate solve first (sync): at HOME, Plate Solve a live frame.": Exit Function
    If AltOf#(TgtHA#(i), catDec(i)) < 10 Then statusMsg$ = catName$(i) + " is below 10 deg altitude now.": Exit Function
    ha = TgtHA#(i)
    AimAxes ha, catDec(i)
    ' the sky keeps turning while we slew (tracking pauses): aim ahead by the slew time
    ha = Wrap180#(ha + (_Max(Abs(gotoA), Abs(gotoD)) / 1.6 + 3) * 360# / 86164.1)
    AimAxes ha, catDec(i)
    If Abs(gotoA) > 150 Or Abs(gotoD) > 150 Then statusMsg$ = "GoTo " + catName$(i) + " would turn RA " + I2S$(CLng(gotoA)) + " / Dec " + I2S$(CLng(gotoD)) + " deg - too far in one go. GoTo HOME first, or move closer by hand.": Exit Function
    PlanGoto% = -1
End Function

' after the slew: solve, compare with the target, correct (up to 3 times)
Sub GotoCheck
    Dim e As Double
    e = SepArcmin#(solRA, solDec, catRA(gotoTgt) * 15#, catDec(gotoTgt))
    If e < 2 Then
        gotoState = 0
        statusMsg$ = catName$(gotoTgt) + " centred - " + Fmt1$(CSng(e)) + " arcmin off."
    ElseIf gotoTry >= 3 Then
        gotoState = 0
        statusMsg$ = catName$(gotoTgt) + ": still " + Fmt1$(CSng(e)) + " arcmin off after 3 tries - centre it by hand."
    ElseIf PlanGoto%(gotoTgt) Then
        gotoTry = gotoTry + 1
        If MountGoto%(gotoA, gotoD) Then
            gotoState = 2
            statusMsg$ = catName$(gotoTgt) + " " + Fmt1$(CSng(e)) + " arcmin off - correcting (try " + I2S$(gotoTry) + ")..."
        Else
            gotoState = 0
        End If
    Else
        gotoState = 0
    End If
End Sub

Sub StepTarget (d As Long)
    Dim n As Long, i As Long
    UpdateMoon
    i = tgtIdx
    For n = 1 To catN
        i = i + d
        If i > catN Then i = 1
        If i < 1 Then i = catN
        If tgtUpOnly = 0 Then Exit For
        If AltOf#(TgtHA#(i), catDec(i)) >= 15 Then Exit For
    Next
    tgtIdx = i
    If gotoState = 1 Then gotoState = 0
End Sub

Sub GotoPanel (y As Long)
    Dim bw As Long, s$, v As Long, al As Double, c As _Unsigned Long, i As Long
    y = y + 4
    Color C_ACC: _PrintString (10, y), "Pointing": y = y + 20
    If syncOk Then
        s$ = "RA " + RAStr$(Wrap360#(mntLST - CurHA#)) + "  Dec " + DecStr$(CurDec#)
        PInfoC y, s$, C_TXT
        PInfo y, "HOME error RA " + Fmt1$(CSng(raIdx)) + "  Dec " + Fmt1$(CSng(decIdx)) + " deg"
    Else
        PInfo y, "Not synced - at HOME, Solve & Sync"
    End If
    ' align: solve at HOME, GoTo, Solve & Sync, GoTo again (or let
    ' "Centre with a plate solve after" do the solve/correct passes)
    If solveOn Then
        v = PButton%(y, "Solving...", -1)
    ElseIf PButton%(y, "Solve & Sync", 0) Then
        If mntGoWait = 0 And gotoState = 0 Then
            If MountSolveNow% Then statusMsg$ = "Solve & Sync: solving the live frame..."
        End If
    End If

    Color C_ACC: _PrintString (10, y), "GoTo": y = y + 20
    ' which list, and Find
    v = PCycler&(y, "List", CAT_LISTS, ListIdx&(catType$(tgtIdx)))
    If v <> ListIdx&(catType$(tgtIdx)) Then
        i = FirstOf&(ItemOf$(CAT_KEYS, v))
        If i Then tgtIdx = i: gotoState = 0: UpdateMoon Else statusMsg$ = "That list is empty - is QBCap_objects.txt next to the program?"
    End If
    If findOn Then
        Line (10, y)-(PANEL_W - 21, y + 21), C_BOX, BF
        Line (10, y)-(PANEL_W - 21, y + 21), C_ACC, B
        s$ = "Find: " + findBuf$
        If (Int(Timer * 2) Mod 2) = 0 Then s$ = s$ + "_"
        Color C_TXT: _PrintString (16, y + 3), s$
        y = y + 26
        PInfo y, "e.g. M31, NGC 7000, C14, Vega - Enter"
    ElseIf PButton%(y, "Find... (M31, NGC 7000, Vega)", 0) Then
        findOn = -1: findBuf$ = ""
        statusMsg$ = "Type a name or number, then Enter (Esc = cancel)"
    End If
    ' target picker:  <<  <  name  >  >>
    i = tgtIdx
    If Btn%(10, y, 28, 24, "<<", 0) Then StepTarget -10
    If Btn%(40, y, 24, 24, "<", 0) Then StepTarget -1
    If Btn%(PANEL_W - 82, y, 24, 24, ">", 0) Then StepTarget 1
    If Btn%(PANEL_W - 56, y, 28, 24, ">>", 0) Then StepTarget 10
    If uiInside And InRect%(66, y, PANEL_W - 150, 24) And mWheel <> 0 Then StepTarget Sgn(mWheel): wheelUsed = -1
    Line (66, y)-(PANEL_W - 86, y + 23), C_BOX, BF
    s$ = catName$(tgtIdx)
    Color C_TXT: _PrintString (66 + (PANEL_W - 152 - Len(s$) * 8) \ 2, y + 4), s$
    y = y + 30
    i = tgtIdx
    s$ = catDesc$(i)
    If catType$(i) = "moon" Then s$ = "the Moon (position for now, from your site)"
    If catMag(i) <> 0 And catType$(i) <> "moon" Then s$ = s$ + "  mag " + Fmt1$(catMag(i))
    If Len(s$) Then PInfoWrap y, s$, C_DIM
    al = AltOf#(TgtHA#(i), catDec(i))
    If al < 15 Then c = C_REC Else c = C_DIM
    PInfoC y, "RA " + RAStr$(catRA(i) * 15#) + "  Dec " + DecStr$(catDec(i)), C_DIM
    PInfoC y, "Altitude " + I2S$(CLng(al)) + " deg" + ItemOf$("|  (low)", -(al < 15) + 1), c
    v = PCheck&(y, "List only objects above 15 deg", tgtUpOnly)
    If v <> tgtUpOnly Then tgtUpOnly = v
    v = PCheck&(y, "Centre with a plate solve after", gotoCentre)
    If v <> gotoCentre Then gotoCentre = v

    Select Case gotoState
        Case 0
            If PButton%(y, "GoTo " + catName$(i), 0) Then
                If mntGoWait = 0 And paTurn = 0 Then
                    If PlanGoto%(i) Then
                        gotoState = 1
                        statusMsg$ = "GoTo " + catName$(i) + ": RA axis " + Fmt1$(CSng(gotoA)) + " deg, Dec axis " + Fmt1$(CSng(gotoD)) + " deg - press Confirm (watch the scope and cables)."
                    End If
                End If
            End If
        Case 1
            If PButton%(y, "Confirm: RA " + Fmt1$(CSng(gotoA)) + "  Dec " + Fmt1$(CSng(gotoD)), 2) Then GotoConfirm i
            If PButton%(y, "Cancel", 0) Then gotoState = 0: statusMsg$ = "GoTo cancelled."
        Case 2
            v = PButton%(y, "Slewing to " + catName$(gotoTgt) + "...", -1)
        Case 3
            v = PButton%(y, "Plate solving to centre...", -1)
        Case 4
            v = PButton%(y, "Waiting for a clean frame...", -1)
    End Select
End Sub

' start the slew planned by PlanGoto% (Confirm button, or the remote GOTO command)
Sub GotoConfirm (i As Long)
    Dim v As Long
    gotoTry = 0: gotoTgt = i
    objName$ = catName$(i) ' captures are named after the GoTo target
    ' like the hand controller: track once the target is reached
    v = qc_mount_track&(-1): mntTrack = -1
    v = qc_mount_track_rate&(-(catType$(i) = "moon")): mntLunar = (catType$(i) = "moon")
    If MountGoto%(gotoA, gotoD) Then gotoState = 2: statusMsg$ = "Slewing to " + catName$(i) + " - STOP button stops it." Else gotoState = 0
End Sub

Function Wrap360# (x As Double)
    Wrap360# = x - 360# * Int(x / 360#)
End Function

Sub UpdateMoon
    Dim ra As Double, de As Double, r As Long
    r = qc_moon_radec&(siteLat, siteLon, ra, de)
    catRA(1) = ra / 15#: catDec(1) = de
End Sub

Function FirstStar&
    Dim i As Long
    For i = 1 To catN
        If catType$(i) = "star" Then FirstStar& = i: Exit Function
    Next
    FirstStar& = 1
End Function

'==================================================================
'  AUTOGUIDING  (step 11)
'  The guide window is a second copy:  ./QBCap --guide
'  It opens the guide camera and sends corrections out of the camera's
'  ST-4 port. The main window talks to it over a local UDP port
'  (STATUS / STOP / PAUSE / RESUME / DITHER).
'==================================================================
Sub GuideInit
    Dim r As Long, f$, ff As Long, l$, k As Long, key$, v$
    gdFL = 200: gdAggRA = 70: gdAggDec = 70: gdMinMove = 15: gdMaxPulse = 2000: gdCalIdx = 3: gdDither = 5
    f$ = exeDir$ + "QBCap_guide.txt"
    If _FileExists(f$) Then
        ff = FreeFile
        Open f$ For Input As #ff
        Do While Not EOF(ff)
            Line Input #ff, l$
            k = InStr(l$, "=")
            If k > 0 And Left$(LTrim$(l$), 1) <> "#" Then
                key$ = LCase$(_Trim$(Left$(l$, k - 1))): v$ = _Trim$(Mid$(l$, k + 1))
                Select Case key$
                    Case "focal_length_mm": gdFL = _Clamp(Val(v$), 50, 3000)
                    Case "ra_aggressiveness": gdAggRA = _Clamp(Val(v$), 10, 100)
                    Case "dec_aggressiveness": gdAggDec = _Clamp(Val(v$), 10, 100)
                    Case "min_move_px100": gdMinMove = _Clamp(Val(v$), 5, 100)
                    Case "max_pulse_ms": gdMaxPulse = _Clamp(Val(v$), 200, 5000)
                    Case "cal_step": gdCalIdx = _Clamp(Val(v$), 1, 5)
                    Case "dither_px": gdDither = _Clamp(Val(v$), 1, 20)
                End Select
            End If
        Loop
        Close #ff
    End If
    expMs = 1000: gainV = 200 ' typical guide exposure
    fmtIdx = 2 ' RAW16: finer star centres
    whiteV = 60 ' brighter view of faint guide stars
    grpOpen(14) = -1: grpOpen(2) = 0: grpOpen(6) = 0
    r = qc_guide_enable&(-1)
    gdLogPath$ = exeDir$ + "QBCap_guidedata.csv" + Chr$(0)
    r = qc_guide_logfile&(_Offset(gdLogPath$))
    GuideSendParams
    If qc_glink_listen&(GLINK_PORT) <> 0 Then statusMsg$ = "Guider: " + LibErr$ Else statusMsg$ = "Guide window: connect the guide camera, Live, then Calibrate."
End Sub

Sub GuideSave
    Dim ff As Long
    ff = FreeFile
    Open exeDir$ + "QBCap_guide.txt" For Output As #ff
    Print #ff, "# QBCap guide settings (written by the guide window)"
    Print #ff, "focal_length_mm = "; gdFL
    Print #ff, "ra_aggressiveness = "; gdAggRA
    Print #ff, "dec_aggressiveness = "; gdAggDec
    Print #ff, "min_move_px100 = "; gdMinMove
    Print #ff, "max_pulse_ms = "; gdMaxPulse
    Print #ff, "cal_step = "; gdCalIdx
    Print #ff, "dither_px = "; gdDither
    Close #ff
End Sub

Sub GuideSendParams
    Dim r As Long
    r = qc_guide_params&(gdAggRA / 100, gdAggDec / 100, gdMinMove / 100, gdMaxPulse, 1.5)
End Sub

' arcsec per guide-camera pixel
Function GuideScale!
    If camConn = 0 Then GuideScale! = 0: Exit Function
    GuideScale! = 206.265 * camPix(camConn) * binIdx / gdFL
End Function

Sub PollGuide
    Static lastT As Double
    Dim tNow As Double, r As Long, b$, st As Long, pa As Long, hv As Long, x As Single, y As Single, sn As Single
    Dim lx As Single, ly As Single, er As Single, ed As Single, rr As Single, rd As Single, se As Long, co As Long, rm As Long, dm As Long
    Dim m$, a As Single, c As Single, an As Single, ot As Single
    ' messages from the main window
    b$ = Space$(200)
    If qc_glink_poll&(_Offset(b$), 200) > 0 Then GuideLinkCommand ZStr$(b$)
    tNow = Timer(.001)
    If tNow >= lastT And tNow - lastT < 0.2 Then Exit Sub
    lastT = tNow
    r = qc_guide_status&(st, pa, hv, x, y, sn, lx, ly, er, ed, rr, rd, se, co, rm, dm)
    gdState = st: gdPaused = pa: gdHave = hv: gdX = x: gdY = y: gdSnr = sn: gdLX = lx: gdLY = ly
    gdERA = er: gdEDec = ed: gdRmsRA = rr: gdRmsDec = rd: gdSettled = se: gdCalOk = co: gdRAms = rm: gdDecms = dm
    gdHN = qc_guide_history&(_Offset(gdHist(0)), 300)
    If camConn Then gdST4 = qc_guide_has_st4&
    If gdCalOk Then
        r = qc_guide_cal_info&(a, c, an, ot)
        gdCal$ = "RA " + Fmt2$(a) + " Dec " + Fmt2$(c) + " px/s, " + I2S$(CLng(an)) + " deg"
    End If
    b$ = Space$(200)
    r = qc_guide_message&(_Offset(b$), 200)
    If r <> gdMsgSeq Then gdMsgSeq = r: gdMsg$ = ZStr$(b$): statusMsg$ = "GUIDER: " + gdMsg$
End Sub

' a message from the main window
Sub GuideLinkCommand (c$)
    Dim r As Long, rep$, w$
    w$ = UCase$(_Trim$(c$))
    rep$ = "OK"
    Select Case Left$(w$, 6)
        Case "STATUS"
            rep$ = "STATE " + I2S$(gdState) + " PAUSED " + I2S$(-(gdPaused <> 0)) + " STAR " + I2S$(-(gdHave <> 0)) + " SETTLED " + I2S$(-(gdSettled <> 0)) + " RMS " + Fmt2$(GuideRmsArc!) + " CAL " + I2S$(-(gdCalOk <> 0))
        Case "STOP"
            r = qc_guide_stop&: gdLinkMsg$ = "Main window stopped guiding (GoTo)"
            statusMsg$ = "GUIDER: stopped by the main window (GoTo) - press Guide again when the new target is centred."
        Case "PAUSE"
            r = qc_guide_pause&(-1): statusMsg$ = "GUIDER: paused by the main window"
        Case "RESUME"
            r = qc_guide_pause&(0): statusMsg$ = "GUIDER: resumed"
        Case "DITHER"
            If qc_guide_dither&(gdDither) <> 0 Then rep$ = "ERR not guiding" Else statusMsg$ = "GUIDER: dither"
        Case Else
            rep$ = "ERR unknown"
    End Select
    rep$ = rep$ + Chr$(0)
    r = qc_glink_reply&(_Offset(rep$))
End Sub

Function GuideRmsArc!
    GuideRmsArc! = Sqr(gdRmsRA * gdRmsRA + gdRmsDec * gdRmsDec) * GuideScale!
End Function

Sub GuideStartNow
    Dim r As Long
    If camConn = 0 Or liveOn = 0 Then statusMsg$ = "Connect the guide camera and press Live first.": Exit Sub
    GuideSendParams
    If qc_guide_start& <> 0 Then statusMsg$ = "Guide: " + LibErr$ Else statusMsg$ = "Guiding started."
    r = 0
End Sub

Sub GuideStopNow
    Dim r As Long
    r = qc_guide_stop&
    statusMsg$ = "Guiding stopped."
End Sub

Sub GuidePanel (y As Long)
    Dim v As Long, bw As Long, s$, c As _Unsigned Long, r As Long, sc As Single
    If camConn = 0 Then
        PInfoC y, "Connect the guide camera (Camera above)", C_REC
        y = y + 4
        Exit Sub
    End If
    If gdST4 = 0 Then PInfoC y, "This camera has no ST-4 port!", C_REC
    v = PSlider&(15, y, "Guide scope focal length", gdFL, 50, 2000, " mm")
    If v <> gdFL Then gdFL = v: GuideSave
    sc = GuideScale!
    PInfo y, "Scale " + Fmt2$(sc) + " arcsec/px"
    If liveOn = 0 Then PInfoC y, "Press Live (guide exposure ~1-2 s)", C_TXT
    If gdHave Then
        PInfoC y, "Star " + I2S$(CLng(gdX)) + ", " + I2S$(CLng(gdY)) + "   SNR " + I2S$(CLng(gdSnr)), C_OK
    Else
        PInfoC y, "Looking for a star...", C_REC
    End If
    PInfo y, "Click a star in the image to choose it"
    bw = (PANEL_W - 34) \ 2
    If Btn%(10, y, bw, 24, "Brightest star", 0) Then
        If qc_guide_select&(-1, -1) <> 0 Then statusMsg$ = "Guide: " + LibErr$
    End If
    v = gdCalIdx
    If gdState = 1 Then
        r = Btn%(14 + bw, y, bw, 24, "Calibrating...", -1)
    ElseIf Btn%(14 + bw, y, bw, 24, "Calibrate", 0) Then
        If qc_guide_calibrate&(Val(ItemOf$("250|500|750|1000|1500", gdCalIdx)), 20) <> 0 Then statusMsg$ = "Guide: " + LibErr$
    End If
    y = y + 30
    v = PCycler&(y, "Cal. step", "250 ms|500 ms|750 ms|1000 ms|1500 ms", gdCalIdx)
    If v <> gdCalIdx Then gdCalIdx = v: GuideSave
    If gdCalOk Then PInfoC y, "Cal: " + gdCal$, C_DIM Else PInfoC y, "Not calibrated", C_DIM
    Select Case gdState
        Case 2
            If PButton%(y, "STOP GUIDING", 2) Then GuideStopNow
        Case 1
            v = PButton%(y, "Calibrating...", -1)
        Case Else
            If PButton%(y, "Guide", 0) Then GuideStartNow
    End Select
    If gdState = 2 Then
        If gdPaused Then PInfoC y, "PAUSED", _RGB32(255, 200, 80)
        If GuideRmsArc! < 1.5 Then c = C_OK Else If GuideRmsArc! < 3 Then c = _RGB32(255, 200, 80) Else c = C_REC
        PInfoC y, "RMS " + Fmt2$(GuideRmsArc!) + Chr$(34) + "  (RA " + Fmt2$(gdRmsRA * sc) + "  Dec " + Fmt2$(gdRmsDec * sc) + ")", c
        PInfo y, "Error RA " + Fmt2$(gdERA * sc) + Chr$(34) + "  Dec " + Fmt2$(gdEDec * sc) + Chr$(34)
        PInfo y, "Pulse RA " + I2S$(gdRAms) + " ms  Dec " + I2S$(gdDecms) + " ms"
        If gdSettled Then PInfoC y, "Settled", C_OK Else PInfoC y, "Settling...", C_TXT
        bw = (PANEL_W - 34) \ 2
        If gdPaused Then
            If Btn%(10, y, bw, 24, "Resume", -1) Then r = qc_guide_pause&(0)
        Else
            If Btn%(10, y, bw, 24, "Pause", 0) Then r = qc_guide_pause&(-1)
        End If
        If Btn%(14 + bw, y, bw, 24, "Dither", 0) Then r = qc_guide_dither&(gdDither)
        y = y + 30
    End If
    v = PSlider&(16, y, "RA aggressiveness", gdAggRA, 10, 100, " %")
    If v <> gdAggRA Then gdAggRA = v: GuideSendParams: GuideSave
    v = PSlider&(17, y, "Dec aggressiveness", gdAggDec, 10, 100, " %")
    If v <> gdAggDec Then gdAggDec = v: GuideSendParams: GuideSave
    v = PSlider&(18, y, "Min move (px x100)", gdMinMove, 5, 100, "")
    If v <> gdMinMove Then gdMinMove = v: GuideSendParams: GuideSave
    v = PSlider&(19, y, "Max pulse", gdMaxPulse, 200, 5000, " ms")
    If v <> gdMaxPulse Then gdMaxPulse = v: GuideSendParams: GuideSave
    v = PSlider&(20, y, "Dither amount", gdDither, 1, 20, " px")
    If v <> gdDither Then gdDither = v: GuideSave
    If Len(gdMsg$) Then
        If InStr(gdMsg$, "LOST") Or InStr(gdMsg$, "failed") Or InStr(gdMsg$, "lost") Then c = C_REC Else c = C_DIM
        PInfoWrap y, gdMsg$, c
    End If
    y = y + 6
End Sub

' star box, lock cross, click to choose a star, error graph
Sub DrawGuideOverlay (dx As Long, dy As Long, dw As Long, dh As Long, sx As Long, sy As Long, sw As Long, sh As Long)
    Dim k As Single, px As Single, py As Single, lx As Single, ly As Single, fx As Long, fy As Long, r As Long
    Dim gx As Long, gy As Long, gw As Long, gh As Long, i As Long, sc As Single, yv As Single, x1 As Single, y1 As Single, x2 As Single, gmid As Long, s$
    k = dw / sw
    ' click in the picture = choose that star (not while guiding)
    If mClick And mx < IMG_W And my >= IMG_Y And my < IMG_Y + IMG_H And gdState = 0 Then
        fx = sx + (mx - dx) / k: fy = sy + (my - IMG_Y - dy) / k
        If fx >= 0 And fy >= 0 And fx < frW And fy < frH Then
            If qc_guide_select&(fx, fy) = 0 Then statusMsg$ = "Guide star: looking near " + I2S$(fx) + ", " + I2S$(fy)
            mClick = 0
        End If
    End If
    If gdHave Then
        px = dx + (gdX - sx) * k: py = dy + (gdY - sy) * k
        Line (px - 14, py - 14)-(px + 14, py + 14), _RGB32(80, 230, 110), B
    End If
    If gdState = 2 Then
        lx = dx + (gdLX - sx) * k: ly = dy + (gdLY - sy) * k
        Line (lx - 22, ly)-(lx - 8, ly), _RGB32(255, 220, 60): Line (lx + 8, ly)-(lx + 22, ly), _RGB32(255, 220, 60)
        Line (lx, ly - 22)-(lx, ly - 8), _RGB32(255, 220, 60): Line (lx, ly + 8)-(lx, ly + 22), _RGB32(255, 220, 60)
    End If
    ' graph: RA blue, Dec red; scale +/- 4" or more when the guide scale is coarse
    If gdHN > 1 Then
        Dim rng As Single
        sc = GuideScale!
        rng = 4: If sc * 1.5 > rng Then rng = Int(sc * 1.5 + 0.999)
        gw = IMG_W - 40: gh = 120: gx = 20: gy = IMG_H - gh - 30
        Line (gx, gy - 20)-(gx + gw, gy + gh), _RGBA32(0, 0, 0, 180), BF
        gmid = gy + gh \ 2
        Line (gx, gmid)-(gx + gw, gmid), _RGBA32(255, 255, 255, 90)
        Line (gx, gy)-(gx + gw, gy), _RGBA32(255, 255, 255, 30)
        Line (gx, gy + gh)-(gx + gw, gy + gh), _RGBA32(255, 255, 255, 30)
        For i = 1 To gdHN - 1
            x1 = gx + (i - 1) * gw / 299: x2 = gx + i * gw / 299
            y1 = gmid - _Clamp(gdHist(2 * (i - 1)) * sc, -rng, rng) * (gh / 2) / rng: yv = gmid - _Clamp(gdHist(2 * i) * sc, -rng, rng) * (gh / 2) / rng
            Line (x1, y1)-(x2, yv), _RGB32(90, 170, 255)
            y1 = gmid - _Clamp(gdHist(2 * (i - 1) + 1) * sc, -rng, rng) * (gh / 2) / rng: yv = gmid - _Clamp(gdHist(2 * i + 1) * sc, -rng, rng) * (gh / 2) / rng
            Line (x1, y1)-(x2, yv), _RGB32(255, 90, 90)
        Next
        Color _RGB32(90, 170, 255): _PrintString (gx + 6, gy - 18), "RA"
        Color _RGB32(255, 90, 90): _PrintString (gx + 30, gy - 18), "Dec"
        s$ = "RMS " + Fmt2$(GuideRmsArc!) + Chr$(34) + "   top / bottom = +/-" + I2S$(CLng(rng)) + Chr$(34) + "   (" + Fmt2$(sc) + Chr$(34) + "/px)"
        Color C_TXT: _PrintString (gx + 70, gy - 18), s$
    End If
    r = 0
End Sub

'---------------- main window side ----------------
Function GuideLinkSend$ (msg$)
    Dim m$, b$, r As Long
    m$ = msg$ + Chr$(0): b$ = Space$(200)
    r = qc_glink_send&(GLINK_PORT, _Offset(m$), _Offset(b$), 200, 40)
    If r = 1 Then GuideLinkSend$ = ZStr$(b$) Else GuideLinkSend$ = ""
End Function

Sub PollGuideLink
    Dim t As Double, a$
    t = Timer(.001)
    If t >= glLastT And t - glLastT < 1 Then Exit Sub
    glLastT = t
    a$ = GuideLinkSend$("STATUS")
    glAlive = (a$ <> "")
    glState$ = a$
End Sub

Function GlField$ (key$)
    Dim p As Long, q As Long
    p = InStr(glState$, key$ + " ")
    If p = 0 Then GlField$ = "": Exit Function
    p = p + Len(key$) + 1
    q = InStr(p, glState$, " ")
    If q = 0 Then q = Len(glState$) + 1
    GlField$ = Mid$(glState$, p, q - p)
End Function

Sub OpenGuiderWindow
    Dim e$
    e$ = Command$(0)
    Shell _DontWait Chr$(34) + e$ + Chr$(34) + " --guide"
    statusMsg$ = "Opening the guide window (second QBCap)..."
End Sub

Sub GuideLinkPanel (y As Long)
    Dim bw As Long, a$, st As Long, v As Long
    If glAlive = 0 Then
        PInfo y, "Guide window not running"
        If PButton%(y, "Open guide window", 0) Then OpenGuiderWindow
        y = y + 4
        Exit Sub
    End If
    st = Val(GlField$("STATE"))
    Select Case st
        Case 2
            If Val(GlField$("PAUSED")) Then a$ = "Guiding - PAUSED" Else a$ = "Guiding   RMS " + GlField$("RMS") + Chr$(34)
            PInfoC y, a$, C_OK
            If Val(GlField$("SETTLED")) Then PInfo y, "Settled" Else PInfo y, "Settling..."
        Case 1
            PInfoC y, "Calibrating...", C_TXT
        Case Else
            PInfoC y, "Guide window open - not guiding", C_TXT
    End Select
    bw = (PANEL_W - 38) \ 3
    If Btn%(10, y, bw, 24, "Pause", 0) Then a$ = GuideLinkSend$("PAUSE")
    If Btn%(14 + bw, y, bw, 24, "Resume", 0) Then a$ = GuideLinkSend$("RESUME")
    If Btn%(18 + 2 * bw, y, bw, 24, "Dither", 0) Then a$ = GuideLinkSend$("DITHER"): statusMsg$ = "Dither: " + a$
    y = y + 30
    v = PCheck&(y, "Stop guiding before a GoTo", glAutoStop)
    If v <> glAutoStop Then glAutoStop = v
End Sub

'==================================================================
'  REMOTE CONTROL  (QBCap_cmd.txt / QBCap_reply.txt / QBCap_status.txt)
'==================================================================
'$Include: 'QBCapRemote.bm'
'$Include: 'QBCapSeq.bm'
