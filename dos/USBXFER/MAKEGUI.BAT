@echo off
rem Build USBXGUI.EXE (mouse file manager) with QuickC 2.5, small model
rem USBXGUI.C #includes USBXFER.C, so both must be in this folder.
rem If the link says "segment exceeds 64K", keep the supplied USBXGUI.EXE
rem (built with Open Watcom) - QuickC makes slightly bigger code.
qcl /c /AS /Ox /W2 USBXGUI.C
qcl /c /AS /Ox /W3 USBDRV.C
qcl /AS USBXGUI.OBJ USBDRV.OBJ IO32.OBJ /link /ST:10240
