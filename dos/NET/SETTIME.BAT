@ECHO OFF
REM Set the clock from the internet (CMOS battery is dead).
REM TZ: your time zone, e.g. EST5EDT, CST6CDT, MST7, PST8PDT.
SET MTCPCFG=C:\NET\MTCP.CFG
SET TZ=MST7
C:\NET\SNTP.EXE -set pool.ntp.org
