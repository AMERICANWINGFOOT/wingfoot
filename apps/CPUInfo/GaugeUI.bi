'=======================================================================
' GaugeUI.bi  -  QB64Starter Gauge & Info Display Helper (declarations)
'
' Add an Include metacommand for GaugeUI.bi at the TOP of your
' program, and one for GaugeUI.bm at the BOTTOM. (Written as words
' on purpose -- the real metacommand is comment-formatted, so QB64
' would act on it even from inside these remarks.)
'
' Immediate-mode display widgets: one call per widget, each frame,
' draws itself fresh - no handles or state to manage between frames.
' Requires a 32-bit graphics Screen.
'
' WIDGETS (see GaugeUI.bm for full signatures):
'   HBar / VBar   - linear progress bar, horizontal or vertical
'   RingGauge     - donut-style percentage gauge
'   DialGauge     - needle dial gauge over a value/min/max range
'   Sparkline     - mini history line graph
'=======================================================================

' --- Theme (set by GaugeInit, override any time) ---
Dim Shared gTrackColor As _Unsigned Long '  unfilled track / background
Dim Shared gLowColor As _Unsigned Long '    fill color below gLowThreshold
Dim Shared gMidColor As _Unsigned Long '    fill color between thresholds
Dim Shared gHighColor As _Unsigned Long '   fill color above gHighThreshold
Dim Shared gBorderColor As _Unsigned Long ' outline around bars/gauges
Dim Shared gTextColor As _Unsigned Long '   labels and readouts
Dim Shared gTickColor As _Unsigned Long '   dial tick marks / sparkline trace
Dim Shared gLowThreshold As Single '        percent below this uses gLowColor
Dim Shared gHighThreshold As Single '       percent above this uses gHighColor
