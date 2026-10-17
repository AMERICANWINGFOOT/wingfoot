'=====================================================================
' ZWOCam.bi - QBGuide camera helper (header part)
' Binds libzwoguide.so (zwoguide.c + ZWO's libASICamera2.a) and adds a
' built-in star-field simulator so the guider can be tested indoors.
' Include this near the top of the program, and ZWOCam.bm at the end.
'=====================================================================

Declare Library "./zwoguide"
    Function zg_count& ()
    Function zg_name& (ByVal idx As Long, buf As String, ByVal blen As Long)
    Function zg_open& (ByVal idx As Long)
    Sub zg_close ()
    Function zg_is_open& ()
    Function zg_max_w& ()
    Function zg_max_h& ()
    Function zg_pixel_um# ()
    Function zg_is_color& ()
    Function zg_has_st4& ()
    Function zg_bit_depth& ()
    Function zg_max_bin& ()
    Function zg_gain_min& ()
    Function zg_gain_max& ()
    Function zg_gain_best& ()
    Function zg_temp_c# ()
    Function zg_set_format& (ByVal bin As Long)
    Function zg_frame_w& ()
    Function zg_frame_h& ()
    Function zg_set_gain& (ByVal gain As Long)
    Function zg_set_exposure_ms& (ByVal ms As Long)
    Function zg_start_exposure& ()
    Function zg_exp_status& ()
    Sub zg_stop_exposure ()
    Function zg_read_frame& (ByVal dest As _Offset)
    Function zg_guide& (ByVal raDir As Long, ByVal raMs As Long, ByVal decDir As Long, ByVal decMs As Long)
    Function zg_guide_busy& ()
    Sub zg_guide_stop ()
End Declare

' Orion StarShoot Autoguider through libssagguide.so (openssag driver)
Declare Library "./ssagguide"
    Function sg_count& ()
    Function sg_open& ()
    Sub sg_close ()
    Function sg_is_open& ()
    Function sg_frame_w& ()
    Function sg_frame_h& ()
    Function sg_set_gain& (ByVal gain As Long)
    Function sg_start_exposure& (ByVal ms As Long)
    Function sg_exp_status& ()
    Sub sg_stop_exposure ()
    Function sg_read_frame& (ByVal dest As _Offset)
    Function sg_guide& (ByVal raDir As Long, ByVal raMs As Long, ByVal decDir As Long, ByVal decMs As Long)
    Function sg_guide_busy& ()
    Sub sg_guide_stop ()
End Declare

' original QHY5 guide camera (16c0:296d) through libqhy5guide.so
Declare Library "./qhy5guide"
    Function q5_count& ()
    Function q5_open& ()
    Sub q5_close ()
    Function q5_frame_w& ()
    Function q5_frame_h& ()
    Function q5_set_gain& (ByVal gain As Long)
    Function q5_start_exposure& (ByVal ms As Long)
    Function q5_exp_status& ()
    Sub q5_stop_exposure ()
    Function q5_read_frame& (ByVal dest As _Offset)
    Function q5_guide& (ByVal raDir As Long, ByVal raMs As Long, ByVal decDir As Long, ByVal decMs As Long)
    Function q5_guide_busy& ()
    Sub q5_guide_stop ()
End Declare

' ST-4 directions (same numbers as the ZWO SDK)
Const DIR_NONE = -1
Const DIR_NORTH = 0
Const DIR_SOUTH = 1
Const DIR_EAST = 2
Const DIR_WEST = 3

' exposure status
Const EXP_IDLE = 0
Const EXP_WORKING = 1
Const EXP_DONE = 2
Const EXP_FAILED = 3

' camera index used for the simulator, and for the Orion SSAG
Const CAM_SIM = -1
Const CAM_SSAG = 1000
Const CAM_QHY5 = 1001

Type CamInfoT
    isOpen As Long
    isSim As Long
    isSSAG As Long
    isQHY5 As Long
    camName As String * 64
    maxW As Long
    maxH As Long
    frameW As Long
    frameH As Long
    pixelUm As Double
    bin As Long
    maxBin As Long
    hasST4 As Long
    gainMin As Long
    gainMax As Long
    gainBest As Long
    expMs As Long
    gain As Long
End Type

' simulator state
Type SimT
    raPx As Double
    decPx As Double
    angle As Double
    raRate As Double
    decRate As Double
    t As Double
    expStart As Double
    exposing As Long
    pulseEnd As Double
    peAmpPx As Double
    pePeriod As Double
    decDriftPx As Double
    seeingPx As Double
    decBacklashMs As Double
    decLastDir As Long
    decBLLeft As Double
    nStars As Long
End Type

Dim Shared Cam As CamInfoT
Dim Shared Sim As SimT
ReDim Shared Frame(0) As _Unsigned Integer
ReDim Shared SimStarX(0) As Double
ReDim Shared SimStarY(0) As Double
ReDim Shared SimStarF(0) As Double
