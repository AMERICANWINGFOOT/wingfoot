'=====================================================================
' Guide.bi - QBGuide guiding helper (header part)
' Star centroid, auto star select, calibration and guide algorithms,
' ported from PHD2 (star.cpp, scope.cpp, guide_algorithm_*.cpp).
' Needs ZWOCam.bi first (uses Frame(), Cam and the CamPulse calls).
'=====================================================================

' star find results (STAR_OK and STAR_SATURATED both count as found)
Const STAR_OK = 0
Const STAR_SATURATED = 1
Const STAR_LOWSNR = 2
Const STAR_LOWMASS = 3
Const STAR_LOWHFD = 4
Const STAR_HIHFD = 5
Const STAR_ERROR = 6

' calibration results
Const CAL_CONTINUE = 0
Const CAL_DONE = 1
Const CAL_FAIL = -1

' calibration states
Const CS_WEST = 1
Const CS_EAST = 2
Const CS_BACKLASH = 3
Const CS_NORTH = 4
Const CS_SOUTH = 5

' Dec guide modes
Const DEC_OFF = 0
Const DEC_AUTO = 1
Const DEC_NORTH = 2
Const DEC_SOUTH = 3

Type StarT
    x As Double
    y As Double
    snr As Double
    hfd As Double
    mass As Double
    bg As Double
    peak As Long
    status As Long
End Type

' calibration result (angles in radians, rates in pixels per ms)
Type CalT
    valid As Long
    decValid As Long
    xAngle As Double
    xRate As Double
    yAngle As Double
    yRate As Double
    calDec As Double
    calBin As Long
    stepMs As Long
    raSteps As Long
    decSteps As Long
End Type

' calibration in progress
Type CalRunT
    state As Long
    steps As Long
    startX As Double
    startY As Double
    remaining As Long
    blMarkX As Double
    blMarkY As Double
    blLastCum As Double
    blAccepted As Long
    blMax As Long
    blExpected As Double
    stepMs As Long
    distance As Double
    useDec As Long
End Type

' guide settings (PHD2 defaults in brackets)
Type GuideParamT
    raAggr As Double
    raHyst As Double
    raMinMove As Double
    decAggr As Double
    decMinMove As Double
    decMode As Long
    maxRaMs As Long
    maxDecMs As Long
    calDistance As Long
    searchR As Long
    minHFD As Double
    maxHFD As Double
    decNow As Double
End Type

' result of the last guide step (for the graph and log)
Type GuideStepT
    dx As Double
    dy As Double
    raErr As Double
    decErr As Double
    raDir As Long
    raMs As Long
    decDir As Long
    decMs As Long
End Type

Dim Shared Cal As CalT
Dim Shared CalRun As CalRunT
Dim Shared GP As GuideParamT
Dim Shared GStep As GuideStepT
Dim Shared CalMsg As String
Dim Shared RaLastMove As Double
Dim Shared DecHist(0 To 9) As Double
Dim Shared DecSide As Long
