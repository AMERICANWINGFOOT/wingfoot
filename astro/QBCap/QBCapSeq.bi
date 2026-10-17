'==================================================================
'  QBCapSeq.bi  -  shared state for the sequencer (autopilot)
'  (included by QBCap.bas after QBCapRemote.bi)
'  One row = target | goto | filter | exposure | gain | count | bin
'  The sequencer turns the rows into remote commands (QBCapRemote.bm)
'  and runs them through the same queue.
'==================================================================
Const SEQMAX = 30
Dim Shared sqN As Long, sqSel As Long
Dim Shared sqTgt$(1 To SEQMAX), sqGoto(1 To SEQMAX) As Long, sqFilt$(1 To SEQMAX)
Dim Shared sqExp(1 To SEQMAX) As Long, sqGain(1 To SEQMAX) As Long, sqCount(1 To SEQMAX) As Long, sqBin(1 To SEQMAX) As Long
Dim Shared sqDone(1 To SEQMAX) As Long ' frames saved per row this run
Dim Shared sqCool As Long, sqEnd As Long ' cool first (on/off); at the end: 1 stop tracking, 2 leave mount, 3 shut down
Dim Shared sqFile$, sqDirty As Long
Dim Shared sqRun As Long, sqLocal As Long, sqRow As Long, sqMsg$, sqStartT As Double, sqRowT As Double
Dim Shared sqEditOn As Long, sqBuf$
