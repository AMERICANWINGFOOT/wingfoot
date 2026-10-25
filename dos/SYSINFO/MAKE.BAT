@ECHO OFF
REM Build SYSINFO.EXE with QuickC 2.5 (small model).
REM SYSASM.OBJ and IO32.OBJ are supplied pre-assembled. To rebuild with MASM 6.11:
REM     ML /c /Cx SYSASM.ASM
REM     ML /c IO32.ASM
QCL /AS /Ox SYSINFO.C SYSASM.OBJ IO32.OBJ
