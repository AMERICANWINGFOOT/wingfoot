@echo off
rem Build USBXFER.EXE and USBDIAG.EXE with QuickC 2.5 (small model, 8K stack)
rem IO32.OBJ is pre-built; to rebuild it with MASM 6.11:  ml /c IO32.ASM
qcl /c /AS /Ox /W3 USBXFER.C
qcl /c /AS /Ox /W3 USBDRV.C
qcl /AS USBXFER.OBJ USBDRV.OBJ IO32.OBJ /link /ST:8192
qcl /AS /Ox /W3 USBDIAG.C /link /ST:8192
