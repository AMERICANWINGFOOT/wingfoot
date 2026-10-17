' StarCat.bi - record layout for Russell's binary star catalog (.cat) files
'
' A .cat file is one StarCatHeader (64 bytes) followed by header.count
' StarRec records (20 bytes each), little-endian, sorted brightest first.
' RA and Dec are ICRS degrees at epoch J2000.0; mag is approximate Johnson V.
' Any catalog converter (Tycho-2 now, Gaia later) writes this same layout,
' so the index builder never needs to know where the stars came from.

Type StarCatHeader
    magic As String * 8
    version As Long
    count As Long
    epoch As Double
    magMin As Single
    magMax As Single
    reserved As String * 32
End Type

Type StarRec
    ra As Double
    dec As Double
    mag As Single
End Type

Const STARCAT_MAGIC = "STARCAT1"
Const STARCAT_VERSION = 1
