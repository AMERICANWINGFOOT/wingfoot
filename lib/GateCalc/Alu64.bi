' ============================================================
' Alu64.bi - 64-bit signed arithmetic built only from gates
' (declarations). Builds on Gate.bi.
'
' Values are 64-bit two's complement held in an _Integer64
' (bit 63 is the sign). Magnitudes and unsigned operands use the
' same 64 bits, so 9223372036854775808 shows up as
' -9223372036854775808 - the routines only ever look at the
' bits, never at the variable's sign.
'
' Adder.bm works on Long words (32 bits max), so this module has
' its own adder: a chain of up to 64 GateFullAdd stages. Every
' add, subtract, multiply, divide and decimal conversion goes
' through GateEval% and GateFullAdd. Native And, Or and shifts
' are used only as wiring: picking bits out, moving them, and
' masking. Flags are 0 or -1. Pass variables of the exact
' declared types.
'
' Include order: Gate.bi, Alu64.bi at the top; Gate.bm,
' Alu64.bm at the bottom. Adder and Alu/Alu32 are not needed,
' but can be included alongside.
' ============================================================

' -1 if bit i (0 to 63) of v is set, else 0.
Declare Function Alu64Bit% (v As _Integer64, i As Integer)

' Ripple-carry adder, nBits wide (1 to 64). coutOut = carry out
' of the top bit; ovfOut = signed overflow.
Declare Sub Alu64Add (a As _Integer64, b As _Integer64, cin As Integer, nBits As Integer, sumOut As _Integer64, coutOut As Integer, ovfOut As Integer)

' a - b as a + NOT b + 1. borrowOut = -1 if a < b unsigned.
Declare Sub Alu64Sub (a As _Integer64, b As _Integer64, nBits As Integer, diffOut As _Integer64, borrowOut As Integer, ovfOut As Integer)

' Two's complement negate (0 - a), 64 bits.
Declare Function Alu64Negate&& (a As _Integer64)

' -1 if all 64 bits of v are zero (an OR chain, then NOT).
Declare Function Alu64IsZero% (v As _Integer64)

' Magnitude of a 64-bit two's complement value.
Declare Function Alu64Mag&& (v As _Integer64)

' Unsigned 64 x 64 -> 128 bit shift-and-add multiply. The product
' comes back as a high word and a low word.
Declare Sub Alu64MulU (a As _Integer64, b As _Integer64, hiOut As _Integer64, loOut As _Integer64)

' Unsigned 64-bit restoring divide. d must not be 0.
Declare Sub Alu64DivU (n As _Integer64, d As _Integer64, qOut As _Integer64, rOut As _Integer64)

' Signed multiply. resOut is the low 64 bits; ovfOut = -1 if the
' true product does not fit in 64 signed bits.
Declare Sub Alu64MulS (a As _Integer64, b As _Integer64, resOut As _Integer64, ovfOut As Integer)

' Signed divide, truncating toward zero; remainder takes the sign
' of the dividend. divZero = -1 if b = 0 (outputs then 0).
' ovfOut = -1 for -9223372036854775808 / -1.
Declare Sub Alu64DivS (a As _Integer64, b As _Integer64, qOut As _Integer64, rOut As _Integer64, divZero As Integer, ovfOut As Integer)

' Signed decimal string, by double dabble into twenty BCD digits.
Declare Function Alu64Fmt$ (v As _Integer64)

' v * 10 + digit through the gate multiplier and adder (keypad
' entry). okOut = -1 if the result still fits in 63 bits.
Declare Function Alu64DigitAppend&& (v As _Integer64, digit As Integer, okOut As Integer)
