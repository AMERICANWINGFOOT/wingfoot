' ============================================================
' Alu128.bi - 128-bit signed arithmetic built only from gates
' (declarations). Builds on Gate.bi.
'
' QB64 has no 128-bit integer, so a 128-bit register is a
' Word128: two 64-bit halves, lo (bits 0-63) and hi (bits
' 64-127). Values are 128-bit two's complement; bit 127 (the top
' bit of hi) is the sign. The routines only look at the bits,
' never at the sign of either half.
'
' Every add, subtract, multiply, divide and decimal conversion
' goes through GateEval% and GateFullAdd: one chain of 128 full
' adders. Native And, Or and shifts are used only as wiring:
' picking bits out, moving them, and masking. Flags are 0 or -1.
'
' Word128 results come back through output parameters (QB64
' functions cannot return a Type). Use separate variables for
' inputs and outputs.
'
' Include order: Gate.bi, Alu128.bi at the top; Gate.bm,
' Alu128.bm at the bottom.
' ============================================================

' A 128-bit register: lo holds bits 0-63, hi holds bits 64-127.
Type Word128
    lo As _Integer64
    hi As _Integer64
End Type

' --- wiring (no gates) ---
' -1 if bit i (0 to 127) of v is set, else 0.
Declare Function Alu128Bit% (v As Word128, i As Integer)
' Set bit i of v to 1.
Declare Sub Alu128SetBit (v As Word128, i As Integer)
' Shift v left one place; bit 63 of lo moves into bit 0 of hi.
Declare Sub Alu128Shl1 (v As Word128)
' Load a small value (0 to 2^63 - 1) into the low half.
Declare Sub Alu128Load (v As Word128, n As _Integer64)

' --- adder chain ---
' sumOut = a + b + cin over nBits (1 to 128). coutOut = carry out
' of the top bit; ovfOut = signed overflow.
Declare Sub Alu128Add (a As Word128, b As Word128, cin As Integer, nBits As Integer, sumOut As Word128, coutOut As Integer, ovfOut As Integer)
' a - b as a + NOT b + 1. borrowOut = -1 if a < b unsigned.
Declare Sub Alu128Sub (a As Word128, b As Word128, nBits As Integer, diffOut As Word128, borrowOut As Integer, ovfOut As Integer)
' rOut = 0 - a.
Declare Sub Alu128Negate (a As Word128, rOut As Word128)

' --- tests ---
' -1 if all 128 bits are zero (an OR chain, then NOT).
Declare Function Alu128IsZero% (v As Word128)
' rOut = magnitude of v.
Declare Sub Alu128Mag (v As Word128, rOut As Word128)

' --- multiply / divide ---
' Unsigned 128 x 128 -> 256 bit shift-and-add multiply.
Declare Sub Alu128MulU (a As Word128, b As Word128, hiOut As Word128, loOut As Word128)
' Unsigned 128-bit restoring divide. d must not be 0.
Declare Sub Alu128DivU (n As Word128, d As Word128, qOut As Word128, rOut As Word128)
' Signed multiply; resOut is the low 128 bits, ovfOut = -1 if
' the true product does not fit in 128 signed bits.
Declare Sub Alu128MulS (a As Word128, b As Word128, resOut As Word128, ovfOut As Integer)
' Signed divide, truncating toward zero; remainder takes the
' sign of the dividend. divZero = -1 if b = 0 (outputs then 0).
' ovfOut = -1 for the most negative value / -1.
Declare Sub Alu128DivS (a As Word128, b As Word128, qOut As Word128, rOut As Word128, divZero As Integer, ovfOut As Integer)

' --- decimal ---
' Signed decimal string, by double dabble into forty BCD digits.
Declare Function Alu128Fmt$ (v As Word128)
' rOut = v * 10 + digit through the gate multiplier and adder.
' okOut = -1 if the result still fits in 127 bits.
Declare Sub Alu128DigitAppend (v As Word128, digit As Integer, rOut As Word128, okOut As Integer)
