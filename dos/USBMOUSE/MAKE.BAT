@echo off
rem Build USBMOUSE.EXE and MTEST.EXE with QuickC 2.5
rem MOUSEASM.OBJ and IO32.OBJ are pre-built (MASM 6.11: ml /c MOUSEASM.ASM IO32.ASM)
qcl /c /AS /Ox /Gs /W3 USBMOUSE.C
qcl /AS USBMOUSE.OBJ MOUSEASM.OBJ IO32.OBJ /link /ST:2048
qcl /AS /Ox /W3 MTEST.C
