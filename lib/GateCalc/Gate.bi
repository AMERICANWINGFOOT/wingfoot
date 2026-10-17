' ============================================================
' Gate.bi - logic gate helper for QB64-PE (declarations)
'
' Truth values: 0 = false, -1 = true. Any nonzero INPUT is
' treated as true, and every gate RETURNS exactly 0 or -1 so
' results are safe to test with If Not.
'
' Tri-state / bus values (used only by GateTri% and
' GateBusResolve%): GATE_Z = high impedance (not driving),
' GATE_X = bus contention (two drivers disagree).
'
' Include this file at the top of the program and Gate.bm at
' the bottom.
' ============================================================

Const GATE_BUF = 0
Const GATE_NOT = 1
Const GATE_AND = 2
Const GATE_OR = 3
Const GATE_NAND = 4
Const GATE_NOR = 5
Const GATE_XOR = 6
Const GATE_XNOR = 7
Const GATE_COUNT = 8

Const GATE_Z = 2
Const GATE_X = 3

' Running count of GateEval% calls. Reset it to 0 before an
' operation and read it afterwards to see how many gate
' evaluations that operation took.
Dim Shared GateEvalCount As _Integer64

' --- core gates ---
Declare Function GateEval% (gateType As Integer, a As Integer, b As Integer)
Declare Function GateInputs% (gateType As Integer)
Declare Function GateName$ (gateType As Integer)
Declare Function GateExpr$ (gateType As Integer)
Declare Function GateBit$ (v As Integer)
Declare Function GateRow$ (gateType As Integer)
Declare Sub GateTable (gateType As Integer)

' --- NAND universality ---
Declare Function GateNand% (a As Integer, b As Integer)
Declare Function GateFromNand% (gateType As Integer, a As Integer, b As Integer)

' --- adders ---
Declare Sub GateHalfAdd (a As Integer, b As Integer, sumOut As Integer, carryOut As Integer)
Declare Sub GateFullAdd (a As Integer, b As Integer, cin As Integer, sumOut As Integer, carryOut As Integer)

' --- analog-side buffers ---
Declare Function GateTri% (a As Integer, en As Integer)
Declare Function GateBusResolve% (v1 As Integer, v2 As Integer)
Declare Function GateSchmitt% (vin As Single, state As Integer, loThr As Single, hiThr As Single)
