' ============================================================================
' SERCommon.bi  -  The one structure that IS the SER format
'
' Include near the TOP of both the writer and the player:
'     '$INCLUDE:'SERCommon.bi'
'
' SER is the antidote to AVI's psychiatry problem: no RIFF tree, no chunk
' walking, no idx1, no padding rules. Just this 178-byte header, then every
' frame concatenated back to back. Frame N lives at a position you can compute
' with a multiply -- no index array needed.
'
' Header layout is fixed and packed (QB64 writes Types field-by-field with no
' alignment padding, so this Type is exactly 178 bytes on disk):
'   14 + 7*4 + 3*40 + 2*8 = 178
' ============================================================================

Type SERHeader
    FileID As String * 14      ' Always "LUCAM-RECORDER"
    LuID As Long               ' Camera series ID (0 is fine)
    ColorID As Long            ' Pixel layout - see SER_* constants below
    LittleEndian As Long       ' Byte order of 16-bit pixels (ignored for 8-bit)
    ImageWidth As Long         ' Frame width in pixels
    ImageHeight As Long        ' Frame height in pixels
    PixelDepth As Long         ' Bits per plane: 8 or 16
    FrameCount As Long         ' Number of frames that follow the header
    Observer As String * 40    ' Free-text metadata (space padded)
    Instrument As String * 40
    Telescope As String * 40
    DateTime As _Integer64     ' .NET ticks, or 0 when unset
    DateTimeUTC As _Integer64  ' .NET ticks, or 0 when unset
End Type

' --- ColorID values (the ones that matter here) ---
Const SER_MONO = 0     ' 1 byte (or 2 at 16-bit) per pixel
Const SER_RGB = 100    ' 3 bytes per pixel, stored R,G,B
Const SER_BGR = 101    ' 3 bytes per pixel, stored B,G,R (matches QB64 memory)
' Bayer patterns (8..19) also exist; this pair treats them as MONO grey,
' since demosaicing is a whole separate rabbit hole.

Const SER_HEADER_SIZE = 178  ' Bytes before the first frame; data starts at 179

' --- Centering target types (used by the Center tool's strategy switch) ---
' These pick a CENTERING STRATEGY and are independent of the pixel format,
' so adding RGB later needs no change here.
Const TGT_PLANET = 0   ' bright compact blob -> broad brightness centroid
Const TGT_DSO = 1      ' bright core on faint halo -> tighter threshold
Const TGT_OFF = 2      ' no centering (pass through / fixed centre crop)
Const TGT_STARS = 3    ' align on 3 user-picked stars (translation only)
Const TGT_SURFACE = 4  ' track a picked surface feature / crater (block match)
