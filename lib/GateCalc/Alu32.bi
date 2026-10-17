' ============================================================
' Alu32.bi - 32-bit signed arithmetic built only from gates
' (declarations). Builds on Gate.bi and Adder.bi.
'
' Values are 32-bit two's complement held in a Long (bit 31 is
' the sign). Magnitudes and unsigned operands use the same 32
' bits, so 2147483648 shows up in a Long as -2147483648 - the
' routines only ever look at the bits, never at the Long's sign.
'
' Every add, subtract, multiply, divide and decimal conversion
' goes through GateEval%, AddRipple and AddSubtract. Native And,
' Or and shifts are used only as wiring: picking bits out,
' moving them, and masking. Flags are 0 or -1. Pass variables
' of the exact declared types.
'
' Alu32 does not need Alu.bi/Alu.bm; the 16-bit and 32-bit ALUs
' can be used together or separately.
'
' Include order: Gate.bi, Adder.bi, Alu32.bi at the top;
' Gate.bm, Adder.bm, Alu32.bm at the bottom.
' ============================================================

' -1 if all 32 bits of v are zero (an OR chain, then NOT).
Declare Function Alu32IsZero% (v As Long)

' Magnitude of a 32-bit two's complement value (0 to 2147483648,
' the top one reading back as -2147483648 in a Long).
Declare Function Alu32Mag& (v As Long)

' Unsigned 32 x 32 -> 64 bit shift-and-add multiply. The product
' comes back as a high word and a low word.
Declare Sub Alu32MulU (a As Long, b As Long, hiOut As Long, loOut As Long)

' Unsigned 32-bit restoring divide. d must not be 0.
Declare Sub Alu32DivU (n As Long, d As Long, qOut As Long, rOut As Long)

' Signed multiply. resOut is the low 32 bits; ovfOut = -1 if the
' true product does not fit in 32 signed bits.
Declare Sub Alu32MulS (a As Long, b As Long, resOut As Long, ovfOut As Integer)

' Signed divide, truncating toward zero; remainder takes the sign
' of the dividend. divZero = -1 if b = 0 (outputs then 0).
' ovfOut = -1 for -2147483648 / -1.
Declare Sub Alu32DivS (a As Long, b As Long, qOut As Long, rOut As Long, divZero As Integer, ovfOut As Integer)

' Signed decimal string of a 32-bit two's complement value, by
' double dabble into ten BCD digits.
Declare Function Alu32Fmt$ (v As Long)

' v * 10 + digit through the gate multiplier and adder (keypad
' entry). okOut = -1 if the result still fits in 31 bits.
Declare Function Alu32DigitAppend& (v As Long, digit As Integer, okOut As Integer)
