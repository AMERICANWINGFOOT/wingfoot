NET - TCP/IP networking for the P4 (mTCP, built from source)
============================================================

WHAT'S HERE
  DHCP.EXE     get an IP address from your router
  PING.EXE     PING 8.8.8.8
  SNTP.EXE     set the DOS clock from the internet (see SETTIME.BAT)
  FTP.EXE      FTP client:  FTP 192.168.1.50
  FTPSRV.EXE   FTP server: the P4 shares its disk with your other PCs
  TELNET.EXE   telnet / BBS client
  HTGET.EXE    download a web page or file over http:
                 HTGET -o FILE.ZIP http://host/path/file.zip
  NC.EXE       netcat (send/receive a file over TCP)
  IRC.EXE      IRC chat client (IRCjr)
  SPDTEST.EXE  network speed test       DNSTEST.EXE  DNS lookup test
  DOCS\        manuals for every program  COPYING.TXT  GPL licence

STILL NEEDED: FETPKT.COM
  The P4's onboard network chip is a VIA Rhine (PCI 1106:3065). DOS
  talks to it through a "packet driver" from VIA: FETPKT.COM, in the
  file fetpkt.zip (https://www.infania.net/misc/pktdrv/fetpkt.zip).
  Unzip it and copy FETPKT.COM into C:\NET on the P4.

SETUP ON THE P4
  1. MD C:\NET   then   USBXFER GET \NET C:\NET
     (and MD C:\NET\DOCS  and  USBXFER GET \NET\DOCS C:\NET\DOCS  if you want the manuals)
  2. Plug the network cable into the P4 and the router.
  3. NET          loads the driver and gets an address
  4. PING 8.8.8.8
  Add  CALL C:\NET\NET.BAT  to AUTOEXEC.BAT once it works.

FTP SERVER (copy files without a USB stick)
  On the P4:  FTPSRV     (user name and password: see FTPPASS.TXT)
  On the Linux PC:  open  ftp://<P4 address>  in the file manager,
  or run  ftp <P4 address>.  DHCP prints the P4's address.
  Press Alt-X on the P4 to stop the server.
