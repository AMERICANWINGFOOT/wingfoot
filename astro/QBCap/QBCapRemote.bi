'==================================================================
'  QBCapRemote.bi  -  shared state for the remote interface
'  (included by QBCap.bas after its own Dim Shared block)
'
'  Files in the QBCap folder:
'    QBCap_cmd.txt     commands in, one per line (QBCap reads it, then deletes it)
'    QBCap_reply.txt   one line per command run: OK / ERR / WAIT + message
'    QBCap_status.txt  rewritten every 2 s: key = value lines
'    QBCap_screen.png  written by the SCREENSHOT command
'  Command list: send HELP, or see QBCap-remote.md
'==================================================================
Const RM_QMAX = 1000
Dim Shared rmOn As Long ' remote control on (QBCap_cmd.txt is read)
Dim Shared rmMount As Long ' remote may move the mount (off at every start - set it by hand)
Dim Shared rmQ$(1 To RM_QMAX), rmQN As Long ' commands waiting to run
Dim Shared rmPaused As Long ' queue paused from the Remote panel
Dim Shared rmWait$, rmWaitUntil As Double, rmWaitStart As Double, rmWaitLimit As Double, rmWaitCmd$
Dim Shared rmFiltWant As Long ' slot asked for by the last FILTER command
Dim Shared rmCapN As Long ' frame count for CAPTURE n (0 = use the panel's Limit)
Dim Shared rmSize As Long, rmSizeT As Double ' cmd file size seen at the last check
Dim Shared rmPollT As Double, rmStatT As Double
Dim Shared rmShot$, rmShotCmd$ ' screenshot to save after the next _Display (and its command line)
Dim Shared rmCount As Long, rmLast$, rmLastRes$, rmLastErr$
Dim Shared rmDayOff As Double, rmLastTimer As Double ' clock that keeps counting past midnight
Dim Shared rmRunFile$ ' script loaded with RUN
