@ECHO OFF
REM NET.BAT - start networking on the P4 (VIA Rhine onboard LAN)
REM   1. load the VIA packet driver on software interrupt 60h
REM   2. get an address from the router (DHCP writes it into MTCP.CFG)
SET MTCPCFG=C:\NET\MTCP.CFG
IF NOT EXIST C:\NET\FETPKT.COM GOTO NODRV
C:\NET\FETPKT.COM 0x60
C:\NET\DHCP.EXE
IF ERRORLEVEL 1 GOTO NODHCP
ECHO.
ECHO Network is up.  Try:  PING 8.8.8.8   or   SNTP pool.ntp.org
GOTO END
:NODRV
ECHO FETPKT.COM (VIA Rhine packet driver) is not in C:\NET yet.
GOTO END
:NODHCP
ECHO DHCP failed - check the network cable and the router.
:END
