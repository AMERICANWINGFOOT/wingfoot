' ============================================================
' Adder.bi - adder, carry and subtract helper for QB64-PE
' (declarations). Builds on Gate.bi / Gate.bm.
'
' Words are Long values, bit 0 = least significant. nBits is
' 1 to 32. Flags are 0 or -1. Pass variables of the EXACT
' declared types (Long for words, Integer for flags/counts) so
' the output parameters are written back correctly.
'
' Include order: Gate.bi then Adder.bi at the top of the
' program; Gate.bm then Adder.bm at the bottom.
' ============================================================

' --- bit and gate shorthands ---
Declare Function AddBit% (v As Long, i As Integer)
Declare Function AddAnd% (x As Integer, y As Integer)
Declare Function AddOr% (x As Integer, y As Integer)
Declare Function AddXor% (x As Integer, y As Integer)
Declare Function AddBin$ (v As Long, nBits As Integer)

' --- ripple-carry adder ---
' sumOut = a + b + cin (nBits wide). coutOut = carry out of the
' top bit (unsigned overflow). ovfOut = signed overflow (carry
' into the top bit XOR carry out of it).
Declare Sub AddRipple (a As Long, b As Long, cin As Integer, nBits As Integer, sumOut As Long, coutOut As Integer, ovfOut As Integer)

' Bit i of the result is the carry OUT of stage i - shows the
' carry chain rippling.
Declare Function AddCarries& (a As Long, b As Long, cin As Integer, nBits As Integer)

' --- carry lookahead ---
' 4-bit group: generate (g = a AND b) and propagate (p = a XOR b)
' feed carry equations that need no rippling inside the group.
Declare Sub AddCla4 (a4 As Long, b4 As Long, cin As Integer, sumOut As Long, coutOut As Integer)

' Groups of 4 chained like a 74283 string. nBits is rounded up to
' a multiple of 4.
Declare Sub AddCla (a As Long, b As Long, cin As Integer, nBits As Integer, sumOut As Long, coutOut As Integer)

' --- subtract, negate, increment ---
' diffOut = a - b as a + NOT b + 1. borrowOut = -1 if a < b
' unsigned. ovfOut = signed overflow.
Declare Sub AddSubtract (a As Long, b As Long, nBits As Integer, diffOut As Long, borrowOut As Integer, ovfOut As Integer)
Declare Function AddNegate& (a As Long, nBits As Integer)
Declare Function AddIncrement& (a As Long, nBits As Integer)
