' ============================================================
' Alu.bi - 16-bit signed arithmetic built only from gates
' (declarations). Builds on Gate.bi and Adder.bi.
'
' Values are 16-bit two's complement held in a Long (0 to
' 65535; bit 15 is the sign). Every add, subtract, multiply,
' divide and decimal conversion goes through GateEval%,
' AddRipple and AddSubtract. Native And, Or and shifts are used
' only as wiring: picking bits out, moving them, and masking.
' Flags are 0 or -1. Pass variables of the exact declared types.
'
' Include order: Gate.bi, Adder.bi, Alu.bi at the top;
' Gate.bm, Adder.bm, Alu.bm at the bottom.
' ============================================================

' -1 if the low nBits bits of v are all zero (an OR chain, then NOT).
Declare Function AluIsZero% (v As Long, nBits As Integer)

' Magnitude of a 16-bit two's complement value (0 to 32768).
Declare Function AluMag& (v As Long)

' Unsigned 16 x 16 -> 32 bit shift-and-add multiply.
Declare Function AluMulU& (a As Long, b As Long)

' Unsigned 16-bit restoring divide. d must not be 0.
Declare Sub AluDivU (n As Long, d As Long, qOut As Long, rOut As Long)

' Signed multiply. resOut is the low 16 bits; ovfOut = -1 if the
' true product does not fit in 16 signed bits.
Declare Sub AluMulS (a As Long, b As Long, resOut As Long, ovfOut As Integer)

' Signed divide, truncating toward zero; remainder takes the sign of
' the dividend. divZero = -1 if b = 0 (outputs then 0). ovfOut = -1
' for -32768 / -1.
Declare Sub AluDivS (a As Long, b As Long, qOut As Long, rOut As Long, divZero As Integer, ovfOut As Integer)

' Unsigned 16-bit value to packed BCD (5 nibbles) with double dabble.
Declare Function AluToBcd& (mag As Long)

' Signed decimal string of a 16-bit two's complement value.
Declare Function AluFmt$ (v As Long)

' v * 10 + digit using shifts and the adder (for keypad entry).
Declare Function AluDigitAppend& (v As Long, digit As Integer)
