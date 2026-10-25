/* USBDRV.H - direct UHCI USB mass-storage driver for DOS (real mode) */
#ifndef USBDRV_H
#define USBDRV_H

int  usb_open(int ctl, int verbose, int flags);
     /* ctl: 0 = auto, n = n-th UHCI controller
        flags: 1 = use USB 2.0 if the BIOS already routes ports to it
               2 = switch ports to USB 2.0 (/2), 4 = test mode */
int  usb_rw(int wr, unsigned long lba, unsigned n, unsigned char *buf);
unsigned long usb_sectors(void);
void usb_close(void);

extern char usb_name[48];              /* "VENDOR PRODUCT" from INQUIRY */
extern char usb_where[40];             /* "controller 00:10.0 port 2"   */
extern char usb_err[80];               /* last error text               */

#endif
