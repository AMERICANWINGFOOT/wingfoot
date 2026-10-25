@ECHO OFF
REM Build the VESA programs with QuickC 2.5 (small model).
REM VXASM.OBJ is supplied pre-assembled. To rebuild it with MASM 6.11:
REM     ML /c /Cx VXASM.ASM
QCL /AS /Ox VESAMODE.C
QCL /AS /Ox VXDEMO.C VXASM.OBJ
