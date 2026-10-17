#!/usr/bin/env python3
"""
fx2dis.py - annotated disassembler for Cypress EZ-USB FX2 (8051) firmware.

Usage:  python3 fx2dis.py FIRMWARE.HEX [NAMES.txt] > listing.asm

NAMES.txt (optional): one "ADDR name  ; comment" per line, e.g.
    022C  cmd_BD_start_exposure   ; 32-bit exposure from EP0BUF
gives that address a readable label (and the comment above it). Add to it
as you work out what each routine does, then run fx2dis.py again.

- reads an Intel HEX file (as loaded by fxload into the FX2's internal RAM)
- follows the code from the reset vector, the interrupt vectors, the USB
  autovector jump table and Keil switch tables, so data stays data
- names the FX2 SFRs, bits and XDATA registers (E600h-E7FFh), and tracks
  DPTR so every MOVX shows which register it reads or writes
- decodes USB descriptors and strings it finds in the data
- ends with a summary: vendor request numbers, registers used, I2C sites

Written for Russell's Orion StarShoot All-in-One (QHY5II.HEX), but works on
any FX2/FX2LP image that fits in the internal 16 KB.
"""
import sys

# --------------------------------------------------------------------------
# 8051 instruction set: opcode -> (mnemonic, operand pattern, length)
# patterns: d=direct  b=bit  i=#imm8  I=#imm16  r=rel  a=addr11  L=addr16
# --------------------------------------------------------------------------
OPS = {}

def op(code, mn, pat, ln):
    OPS[code] = (mn, pat, ln)

op(0x00, "nop", "", 1)
for hi in range(8):
    op((hi << 5) | 0x01, "ajmp", "a", 2)
    op((hi << 5) | 0x11, "acall", "a", 2)
op(0x02, "ljmp", "L", 3); op(0x12, "lcall", "L", 3)
op(0x03, "rr", "A", 1); op(0x13, "rrc", "A", 1); op(0x23, "rl", "A", 1); op(0x33, "rlc", "A", 1)
op(0x04, "inc", "A", 1); op(0x05, "inc", "d", 2); op(0x14, "dec", "A", 1); op(0x15, "dec", "d", 2)
op(0x10, "jbc", "b,r", 3); op(0x20, "jb", "b,r", 3); op(0x30, "jnb", "b,r", 3)
op(0x22, "ret", "", 1); op(0x32, "reti", "", 1)
op(0x40, "jc", "r", 2); op(0x50, "jnc", "r", 2); op(0x60, "jz", "r", 2); op(0x70, "jnz", "r", 2)
op(0x80, "sjmp", "r", 2); op(0x73, "jmp", "@A+DPTR", 1)
for base, mn in ((0x24, "add"), (0x34, "addc"), (0x44, "orl"), (0x54, "anl"), (0x64, "xrl"), (0x94, "subb")):
    op(base, mn, "A,i", 2); op(base + 1, mn, "A,d", 2)
    op(base + 2, mn, "A,@R0", 1); op(base + 3, mn, "A,@R1", 1)
    for n in range(8):
        op(base + 4 + n, mn, "A,R%d" % n, 1)
for base, mn in ((0x42, "orl"), (0x52, "anl"), (0x62, "xrl")):
    op(base, mn, "d,A", 2); op(base + 1, mn, "d,i", 3)
op(0x72, "orl", "C,b", 2); op(0x82, "anl", "C,b", 2); op(0xA0, "orl", "C,/b", 2); op(0xB0, "anl", "C,/b", 2)
op(0x74, "mov", "A,i", 2); op(0x75, "mov", "d,i", 3)
op(0x76, "mov", "@R0,i", 2); op(0x77, "mov", "@R1,i", 2)
for n in range(8):
    op(0x78 + n, "mov", "R%d,i" % n, 2)
op(0x83, "movc", "A,@A+PC", 1); op(0x93, "movc", "A,@A+DPTR", 1)
op(0x84, "div", "AB", 1); op(0xA4, "mul", "AB", 1)
op(0x85, "mov", "D,d", 3)              # special: mov dst,src (encoded src first)
op(0x86, "mov", "d,@R0", 2); op(0x87, "mov", "d,@R1", 2)
for n in range(8):
    op(0x88 + n, "mov", "d,R%d" % n, 2)
op(0x90, "mov", "DPTR,I", 3)
op(0x92, "mov", "b,C", 2); op(0xA2, "mov", "C,b", 2)
op(0xA3, "inc", "DPTR", 1)
op(0xA5, "db", "?", 1)
op(0xA6, "mov", "@R0,d", 2); op(0xA7, "mov", "@R1,d", 2)
for n in range(8):
    op(0xA8 + n, "mov", "R%d,d" % n, 2)
op(0xB2, "cpl", "b", 2); op(0xB3, "cpl", "C", 1)
op(0xB4, "cjne", "A,i,r", 3); op(0xB5, "cjne", "A,d,r", 3)
op(0xB6, "cjne", "@R0,i,r", 3); op(0xB7, "cjne", "@R1,i,r", 3)
for n in range(8):
    op(0xB8 + n, "cjne", "R%d,i,r" % n, 3)
op(0xC0, "push", "d", 2); op(0xD0, "pop", "d", 2)
op(0xC2, "clr", "b", 2); op(0xC3, "clr", "C", 1); op(0xD2, "setb", "b", 2); op(0xD3, "setb", "C", 1)
op(0xC4, "swap", "A", 1); op(0xD4, "da", "A", 1)
op(0xC5, "xch", "A,d", 2); op(0xC6, "xch", "A,@R0", 1); op(0xC7, "xch", "A,@R1", 1)
for n in range(8):
    op(0xC8 + n, "xch", "A,R%d" % n, 1)
op(0xD5, "djnz", "d,r", 3); op(0xD6, "xchd", "A,@R0", 1); op(0xD7, "xchd", "A,@R1", 1)
for n in range(8):
    op(0xD8 + n, "djnz", "R%d,r" % n, 2)
op(0xE0, "movx", "A,@DPTR", 1); op(0xE2, "movx", "A,@R0", 1); op(0xE3, "movx", "A,@R1", 1)
op(0xF0, "movx", "@DPTR,A", 1); op(0xF2, "movx", "@R0,A", 1); op(0xF3, "movx", "@R1,A", 1)
op(0xE4, "clr", "A", 1); op(0xF4, "cpl", "A", 1)
op(0xE5, "mov", "A,d", 2); op(0xE6, "mov", "A,@R0", 1); op(0xE7, "mov", "A,@R1", 1)
for n in range(8):
    op(0xE8 + n, "mov", "A,R%d" % n, 1)
op(0xF5, "mov", "d,A", 2); op(0xF6, "mov", "@R0,A", 1); op(0xF7, "mov", "@R1,A", 1)
for n in range(8):
    op(0xF8 + n, "mov", "R%d,A" % n, 1)
for n in range(2):
    op(0x06 + n, "inc", "@R%d" % n, 1); op(0x16 + n, "dec", "@R%d" % n, 1)
for n in range(8):
    op(0x08 + n, "inc", "R%d" % n, 1); op(0x18 + n, "dec", "R%d" % n, 1)
assert len(OPS) == 256, len(OPS)

# --------------------------------------------------------------------------
# FX2 names (Cypress EZ-USB FX2 Technical Reference Manual)
# --------------------------------------------------------------------------
SFR = {
    0x80: "IOA", 0x81: "SP", 0x82: "DPL", 0x83: "DPH", 0x84: "DPL1", 0x85: "DPH1", 0x86: "DPS",
    0x87: "PCON", 0x88: "TCON", 0x89: "TMOD", 0x8A: "TL0", 0x8B: "TL1", 0x8C: "TH0", 0x8D: "TH1",
    0x8E: "CKCON", 0x90: "IOB", 0x91: "EXIF", 0x92: "MPAGE", 0x98: "SCON0", 0x99: "SBUF0",
    0x9A: "AUTOPTRH1", 0x9B: "AUTOPTRL1", 0x9D: "AUTOPTRH2", 0x9E: "AUTOPTRL2",
    0xA0: "IOC", 0xA1: "INT2CLR", 0xA2: "INT4CLR", 0xA8: "IE", 0xAA: "EP2468STAT",
    0xAB: "EP24FIFOFLGS", 0xAC: "EP68FIFOFLGS", 0xAF: "AUTOPTRSETUP", 0xB0: "IOD", 0xB1: "IOE",
    0xB2: "OEA", 0xB3: "OEB", 0xB4: "OEC", 0xB5: "OED", 0xB6: "OEE", 0xB8: "IP", 0xBA: "EP01STAT",
    0xBB: "GPIFTRIG", 0xBD: "GPIFSGLDATH", 0xBE: "GPIFSGLDATLX", 0xBF: "GPIFSGLDATLNOX",
    0xC0: "SCON1", 0xC1: "SBUF1", 0xC8: "T2CON", 0xCA: "RCAP2L", 0xCB: "RCAP2H", 0xCC: "TL2",
    0xCD: "TH2", 0xD0: "PSW", 0xD8: "EICON", 0xE0: "ACC", 0xE8: "EIE", 0xF0: "B", 0xF8: "EIP",
}
BITNAMES = {
    0x88: ["IT0", "IE0", "IT1", "IE1", "TR0", "TF0", "TR1", "TF1"],
    0x98: ["RI", "TI", "RB8", "TB8", "REN", "SM2", "SM1", "SM0"],
    0xA8: ["EX0", "ET0", "EX1", "ET1", "ES0", "ET2", "ES1", "EA"],
    0xB8: ["PX0", "PT0", "PX1", "PT1", "PS0", "PT2", "PS1", "IP.7"],
    0xC8: ["CP_RL2", "C_T2", "TR2", "EXEN2", "TCLK", "RCLK", "EXF2", "TF2"],
    0xD0: ["P", "PSW.1", "OV", "RS0", "RS1", "F0", "AC", "CY"],
    0xD8: ["EICON.0", "EICON.1", "EICON.2", "INT6", "RESI", "ERESI", "EICON.6", "SMOD1"],
    0xE8: ["EUSB", "EI2C", "EIEX4", "EIEX5", "EIEX6", "EIE.5", "EIE.6", "EIE.7"],
    0xF8: ["PUSB", "PI2C", "EIPX4", "EIPX5", "EIPX6", "EIP.5", "EIP.6", "EIP.7"],
}

XREG = {
    0xE600: "CPUCS", 0xE601: "IFCONFIG", 0xE602: "PINFLAGSAB", 0xE603: "PINFLAGSCD",
    0xE604: "FIFORESET", 0xE605: "BREAKPT", 0xE606: "BPADDRH", 0xE607: "BPADDRL",
    0xE608: "UART230", 0xE609: "FIFOPINPOLAR", 0xE60A: "REVID", 0xE60B: "REVCTL",
    0xE60C: "GPIFHOLDAMOUNT",
    0xE610: "EP1OUTCFG", 0xE611: "EP1INCFG", 0xE612: "EP2CFG", 0xE613: "EP4CFG",
    0xE614: "EP6CFG", 0xE615: "EP8CFG", 0xE618: "EP2FIFOCFG", 0xE619: "EP4FIFOCFG",
    0xE61A: "EP6FIFOCFG", 0xE61B: "EP8FIFOCFG",
    0xE620: "EP2AUTOINLENH", 0xE621: "EP2AUTOINLENL", 0xE622: "EP4AUTOINLENH", 0xE623: "EP4AUTOINLENL",
    0xE624: "EP6AUTOINLENH", 0xE625: "EP6AUTOINLENL", 0xE626: "EP8AUTOINLENH", 0xE627: "EP8AUTOINLENL",
    0xE630: "EP2FIFOPFH", 0xE631: "EP2FIFOPFL", 0xE632: "EP4FIFOPFH", 0xE633: "EP4FIFOPFL",
    0xE634: "EP6FIFOPFH", 0xE635: "EP6FIFOPFL", 0xE636: "EP8FIFOPFH", 0xE637: "EP8FIFOPFL",
    0xE640: "EP2ISOINPKTS", 0xE641: "EP4ISOINPKTS", 0xE642: "EP6ISOINPKTS", 0xE643: "EP8ISOINPKTS",
    0xE648: "INPKTEND", 0xE649: "OUTPKTEND",
    0xE650: "EP2FIFOIE", 0xE651: "EP2FIFOIRQ", 0xE652: "EP4FIFOIE", 0xE653: "EP4FIFOIRQ",
    0xE654: "EP6FIFOIE", 0xE655: "EP6FIFOIRQ", 0xE656: "EP8FIFOIE", 0xE657: "EP8FIFOIRQ",
    0xE658: "IBNIE", 0xE659: "IBNIRQ", 0xE65A: "NAKIE", 0xE65B: "NAKIRQ",
    0xE65C: "USBIE", 0xE65D: "USBIRQ", 0xE65E: "EPIE", 0xE65F: "EPIRQ",
    0xE660: "GPIFIE", 0xE661: "GPIFIRQ", 0xE662: "USBERRIE", 0xE663: "USBERRIRQ",
    0xE664: "ERRCNTLIM", 0xE665: "CLRERRCNT", 0xE666: "INT2IVEC", 0xE667: "INT4IVEC",
    0xE668: "INTSETUP",
    0xE670: "PORTACFG", 0xE671: "PORTCCFG", 0xE672: "PORTECFG",
    0xE678: "I2CS", 0xE679: "I2DAT", 0xE67A: "I2CTL", 0xE67B: "XAUTODAT1", 0xE67C: "XAUTODAT2",
    0xE680: "USBCS", 0xE681: "SUSPEND", 0xE682: "WAKEUPCS", 0xE683: "TOGCTL",
    0xE684: "USBFRAMEH", 0xE685: "USBFRAMEL", 0xE686: "MICROFRAME", 0xE687: "FNADDR",
    0xE68A: "EP0BCH", 0xE68B: "EP0BCL", 0xE68D: "EP1OUTBC", 0xE68F: "EP1INBC",
    0xE690: "EP2BCH", 0xE691: "EP2BCL", 0xE694: "EP4BCH", 0xE695: "EP4BCL",
    0xE698: "EP6BCH", 0xE699: "EP6BCL", 0xE69C: "EP8BCH", 0xE69D: "EP8BCL",
    0xE6A0: "EP0CS", 0xE6A1: "EP1OUTCS", 0xE6A2: "EP1INCS", 0xE6A3: "EP2CS", 0xE6A4: "EP4CS",
    0xE6A5: "EP6CS", 0xE6A6: "EP8CS", 0xE6A7: "EP2FIFOFLGS", 0xE6A8: "EP4FIFOFLGS",
    0xE6A9: "EP6FIFOFLGS", 0xE6AA: "EP8FIFOFLGS", 0xE6AB: "EP2FIFOBCH", 0xE6AC: "EP2FIFOBCL",
    0xE6AD: "EP4FIFOBCH", 0xE6AE: "EP4FIFOBCL", 0xE6AF: "EP6FIFOBCH", 0xE6B0: "EP6FIFOBCL",
    0xE6B1: "EP8FIFOBCH", 0xE6B2: "EP8FIFOBCL", 0xE6B3: "SUDPTRH", 0xE6B4: "SUDPTRL",
    0xE6B5: "SUDPTRCTL",
    0xE6B8: "SETUPDAT0 (bmRequestType)", 0xE6B9: "SETUPDAT1 (bRequest)",
    0xE6BA: "SETUPDAT2 (wValueL)", 0xE6BB: "SETUPDAT3 (wValueH)",
    0xE6BC: "SETUPDAT4 (wIndexL)", 0xE6BD: "SETUPDAT5 (wIndexH)",
    0xE6BE: "SETUPDAT6 (wLengthL)", 0xE6BF: "SETUPDAT7 (wLengthH)",
    0xE6C0: "GPIFWFSELECT", 0xE6C1: "GPIFIDLECS", 0xE6C2: "GPIFIDLECTL", 0xE6C3: "GPIFCTLCFG",
    0xE6C4: "GPIFADRH", 0xE6C5: "GPIFADRL",
    0xE6CE: "GPIFTCB3", 0xE6CF: "GPIFTCB2", 0xE6D0: "GPIFTCB1", 0xE6D1: "GPIFTCB0",
    0xE6D2: "EP2GPIFFLGSEL", 0xE6D3: "EP2GPIFPFSTOP", 0xE6D4: "EP2GPIFTRIG",
    0xE6F0: "XGPIFSGLDATH", 0xE6F1: "XGPIFSGLDATLX", 0xE6F2: "XGPIFSGLDATLNOX",
    0xE6F3: "GPIFREADYCFG", 0xE6F4: "GPIFREADYSTAT", 0xE6F5: "GPIFABORT",
}

def xname(a):
    if a in XREG:
        return XREG[a]
    if 0xE400 <= a < 0xE480: return "GPIF waveform[%d]" % (a - 0xE400)
    if 0xE740 <= a < 0xE780: return "EP0BUF[%d]" % (a - 0xE740)
    if 0xE780 <= a < 0xE7C0: return "EP1OUTBUF[%d]" % (a - 0xE780)
    if 0xE7C0 <= a < 0xE800: return "EP1INBUF[%d]" % (a - 0xE7C0)
    if 0xF000 <= a < 0xF400: return "EP2FIFOBUF[%d]" % (a - 0xF000)
    if 0xF400 <= a < 0xF800: return "EP4FIFOBUF[%d]" % (a - 0xF400)
    if 0xF800 <= a < 0xFC00: return "EP6FIFOBUF[%d]" % (a - 0xF800)
    if 0xFC00 <= a <= 0xFFFF: return "EP8FIFOBUF[%d]" % (a - 0xFC00)
    if a < 0x4000: return "RAM %04Xh" % a
    if 0xE000 <= a < 0xE200: return "scratch RAM %04Xh" % a
    return None

def dname(d):
    if d >= 0x80:
        return SFR.get(d, "%02Xh" % d)
    if 0x00 <= d <= 0x07: return "%02Xh(R%d)" % (d, d)
    return "%02Xh" % d

def bname(b):
    if b >= 0x80:
        base = b & 0xF8
        if base in BITNAMES:
            return BITNAMES[base][b & 7]
        return "%s.%d" % (SFR.get(base, "%02Xh" % base), b & 7)
    return "%02Xh.%d" % (0x20 + (b >> 3), b & 7)

PORTBIT = {0x80: "IOA", 0x90: "IOB", 0xA0: "IOC", 0xB0: "IOD"}

# --------------------------------------------------------------------------
def load_hex(path):
    mem = bytearray(0x4000)
    used = bytearray(0x4000)
    top = 0
    for line in open(path):
        line = line.strip()
        if not line.startswith(":"):
            continue
        n = int(line[1:3], 16); a = int(line[3:7], 16); t = int(line[7:9], 16)
        if t != 0:
            continue
        data = bytes.fromhex(line[9:9 + 2 * n])
        if a + n > len(mem):
            continue                     # scratch RAM E000h+ is not kept here
        mem[a:a + n] = data
        for k in range(n):
            used[a + k] = 1
        top = max(top, a + n)
    return mem, used, top

def decode(mem, pc):
    opc = mem[pc]
    mn, pat, ln = OPS[opc]
    b1 = mem[pc + 1] if pc + 1 < len(mem) else 0
    b2 = mem[pc + 2] if pc + 2 < len(mem) else 0
    targets, flow = [], "next"           # flow: next / jump / ret / call / indirect
    parts = []
    k = 1
    def rel(off):
        return (pc + ln + (off - 256 if off > 127 else off)) & 0xFFFF
    if pat == "D,d":                      # mov dst,src (encoded src,dst)
        parts = [dname(b2), dname(b1)]
    else:
        for p in pat.split(",") if pat else []:
            if p == "d":
                parts.append(dname(mem[pc + k])); k += 1
            elif p == "b":
                parts.append(bname(mem[pc + k])); k += 1
            elif p == "/b":
                parts.append("/" + bname(mem[pc + k])); k += 1
            elif p == "i":
                parts.append("#%02Xh" % mem[pc + k]); k += 1
            elif p == "I":
                parts.append("#%04Xh" % ((mem[pc + k] << 8) | mem[pc + k + 1])); k += 2
            elif p == "r":
                t = rel(mem[pc + k]); k += 1
                parts.append("L%04X" % t); targets.append(t)
            elif p == "a":
                t = ((pc + 2) & 0xF800) | ((opc & 0xE0) << 3) | mem[pc + k]; k += 1
                parts.append("L%04X" % t); targets.append(t)
            elif p == "L":
                t = (mem[pc + k] << 8) | mem[pc + k + 1]; k += 2
                parts.append("L%04X" % t); targets.append(t)
            else:
                parts.append(p)
    if mn in ("ljmp", "ajmp", "sjmp"):
        flow = "jump"
    elif mn in ("ret", "reti"):
        flow = "ret"
    elif mn in ("lcall", "acall"):
        flow = "call"
    elif mn == "jmp":
        flow = "indirect"
    text = mn + (" " + ", ".join(parts) if parts else "")
    return text, ln, targets, flow

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    mem, used, top = load_hex(sys.argv[1])
    code = {}                 # addr -> (text, len, targets, flow)
    labels = {}               # addr -> name
    xref = {}                 # addr -> set of callers
    notes = {}                # addr -> extra comment line(s) above
    switch_tables = []

    entry = {0x0000: "RESET", 0x0003: "INT0", 0x000B: "TIMER0", 0x0013: "INT1",
             0x001B: "TIMER1", 0x0023: "UART0", 0x002B: "TIMER2", 0x0033: "WAKEUP",
             0x003B: "UART1", 0x0043: "INT2_USB", 0x004B: "I2C_INT", 0x0053: "INT4_FIFO_GPIF",
             0x005B: "INT5", 0x0063: "INT6"}
    work = []
    for a, n in entry.items():
        if used[a] and mem[a] in (0x02, 0x32) or (used[a] and mem[a] & 0x1F == 0x01):
            labels[a] = "vec_" + n
            work.append(a)

    def add(t, frm):
        if t >= top or not used[t]:
            return
        xref.setdefault(t, set()).add(frm)
        if t not in code:
            work.append(t)

    def keil_case_table(routine):
        # Keil ?C?CCASE: pop dph / pop dpl, then walk table after the call
        return mem[routine:routine + 4] == bytes([0xD0, 0x83, 0xD0, 0x82])

    while work:
        pc = work.pop()
        while pc < top and pc not in code and used[pc]:
            text, ln, targets, flow = decode(mem, pc)
            code[pc] = (text, ln, targets, flow)
            for t in targets:
                add(t, pc)
                if flow == "call":
                    labels.setdefault(t, "sub_%04X" % t)
                elif t not in labels:
                    labels[t] = "L%04X" % t
            if flow == "call" and targets and keil_case_table(targets[0]):
                # switch table follows the call: (hi, lo, value) ... 00 00 hi lo
                q = pc + ln
                cases = []
                while q + 3 <= top:
                    hi, lo = mem[q], mem[q + 1]
                    if hi == 0 and lo == 0:
                        dflt = (mem[q + 2] << 8) | mem[q + 3]
                        cases.append(("default", dflt)); q += 4
                        break
                    cases.append((mem[q + 2], (hi << 8) | lo)); q += 3
                for v, t in cases:
                    labels.setdefault(t, "case_%04X" % t); add(t, pc)
                switch_tables.append((pc, pc + ln, q, cases))
                labels[targets[0]] = "keil_CCASE"
                break
            if flow == "indirect":
                # jmp @A+DPTR: look back for mov DPTR,#tbl and treat it as a jump table
                for back in range(1, 12):
                    p = pc - back
                    if p in code and code[p][0].startswith("mov DPTR, #"):
                        tbl = int(code[p][0][11:15], 16)
                        q = tbl
                        while q < top and (mem[q] == 0x02 or mem[q] & 0x1F == 0x01):
                            if q not in code:
                                work.append(q)
                            q += 3 if mem[q] == 0x02 else 2
                        notes[pc] = "jump table at %04Xh" % tbl
                        break
                break
            if flow in ("jump", "ret"):
                break
            pc += ln

    # ---------------- user names (optional second argument) ----------------
    if len(sys.argv) > 2:
        for line in open(sys.argv[2]):
            body = line.split(";", 1)
            f = body[0].split()
            if len(f) >= 2:
                a = int(f[0], 16)
                labels[a] = f[1]
                if len(body) > 1 and body[1].strip():
                    notes[a] = body[1].strip()

    # ---------------- second pass: DPTR tracking, comments ----------------
    xuse = {}                  # xdata reg -> list of (pc, 'R'/'W')
    vendor = []                # (pc, value) compares against bRequest
    comments = {}
    dptr = None
    accsrc = None
    for pc in sorted(code):
        text, ln, targets, flow = code[pc]
        if pc in labels and not labels[pc].startswith("L") or pc in xref:
            dptr = None        # entry point: unknown DPTR
        c = ""
        if text.startswith("mov DPTR, #"):
            dptr = int(text[11:15], 16)
            nm = xname(dptr)
            if nm: c = "-> " + nm
        elif text == "inc DPTR" and dptr is not None:
            dptr = (dptr + 1) & 0xFFFF
            nm = xname(dptr)
            if nm: c = "-> " + nm
        elif text.startswith("movx") and "@DPTR" in text and dptr is not None:
            nm = xname(dptr) or "%04Xh" % dptr
            rw = "W" if text.startswith("movx @DPTR") else "R"
            c = ("write " if rw == "W" else "read ") + nm
            xuse.setdefault(dptr, []).append((pc, rw))
            accsrc = dptr if rw == "R" else accsrc
        elif text.startswith(("mov DPL", "mov DPH", "pop DPL", "pop DPH", "movc", "xch")) or flow in ("call",):
            if flow == "call" or "DP" in text:
                dptr = None
        if text.startswith(("cjne A, #", "xrl A, #", "add A, #", "subb A, #")) and accsrc == 0xE6B9:
            v = int(text.split("#")[1][:2], 16)
            vendor.append((pc, v, text.split()[0]))
            c = (c + "  " if c else "") + "bRequest compare %02Xh" % v
        if text.startswith(("mov A,", "clr A", "movx A,@R", "movc")) or flow == "call":
            if not text.startswith("movx A,@DPTR"):
                accsrc = None
        for t in targets:
            if t in labels and labels[t] != "L%04X" % t:
                text = text.replace("L%04X" % t, labels[t])
        for pb, pn in PORTBIT.items():
            for bit in range(8):
                if "%s.%d" % (pn, bit) in text:
                    c = (c + "  " if c else "") + "port pin %s.%d" % (pn[2], bit)
        comments[pc] = c
        code[pc] = (text, ln, targets, flow)
        if flow in ("jump", "ret", "indirect"):
            dptr = None

    # ---------------- data: descriptors and strings ----------------
    data_notes = {}
    q = 0
    while q < top:
        if q in code:
            q += code[q][1]; continue
        before = len(data_notes)
        if mem[q] == 0x12 and mem[q + 1] == 0x01:
            d = mem[q:q + 18]
            data_notes[q] = ("USB DEVICE descriptor: USB %x.%02x  class %02X  maxpkt %d  VID %04X  PID %04X  "
                             "rel %04X  strings mfr=%d prod=%d ser=%d  configs %d" %
                             (d[3], d[2], d[4], d[7], d[8] | d[9] << 8, d[10] | d[11] << 8,
                              d[12] | d[13] << 8, d[14], d[15], d[16], d[17]))
        elif mem[q] == 0x0A and mem[q + 1] == 0x06:
            data_notes[q] = "USB DEVICE QUALIFIER descriptor"
        elif mem[q] == 0x09 and mem[q + 1] in (0x02, 0x07):
            tl = mem[q + 2] | mem[q + 3] << 8
            data_notes[q] = "USB %sCONFIGURATION descriptor: total %d bytes, %d interface(s), %d mA" % (
                "OTHER-SPEED " if mem[q + 1] == 7 else "", tl, mem[q + 4], mem[q + 8] * 2)
        elif mem[q] == 0x09 and mem[q + 1] == 0x04:
            data_notes[q] = "  INTERFACE %d alt %d: %d endpoint(s) class %02X" % (mem[q + 2], mem[q + 3], mem[q + 4], mem[q + 5])
        elif mem[q] == 0x07 and mem[q + 1] == 0x05:
            ep = mem[q + 2]; at = mem[q + 3] & 3
            data_notes[q] = "    ENDPOINT %d %s  %s  maxpkt %d" % (ep & 0x0F, "IN" if ep & 0x80 else "OUT",
                            ["control", "iso", "bulk", "interrupt"][at], mem[q + 4] | mem[q + 5] << 8)
        elif mem[q + 1] == 0x03 and 4 <= mem[q] <= 64 and q + mem[q] <= top:
            s = mem[q + 2:q + mem[q]]
            try:
                txt = s.decode("utf-16le")
                if all(32 <= ord(ch) < 127 for ch in txt):
                    data_notes[q] = 'USB STRING descriptor: "%s"' % txt
            except UnicodeDecodeError:
                pass
            if mem[q] == 4 and s == b"\x09\x04":
                data_notes[q] = "USB STRING descriptor 0: language 0409 (US English)"
        if len(data_notes) > before and mem[q] >= 2:
            q += mem[q]           # skip the whole descriptor (its bytes can look like others)
        else:
            q += 1

    # ---------------- print ----------------
    out = []
    w = out.append
    w("; %s  -  FX2 (8051) firmware, %d bytes (0000h-%04Xh)" % (sys.argv[1], top, top - 1))
    w("; disassembled by fx2dis.py: code followed from the vectors; data shown as db")
    w(";")
    q = 0
    while q < top:
        if q in code:
            text, ln, targets, flow = code[q]
            if q in labels:
                callers = xref.get(q, set())
                w("")
                if q in notes: w("; " + notes[q])
                w("%s:%s" % (labels[q], ("    ; from " + " ".join("%04X" % x for x in sorted(callers)[:8]) +
                                         (" ..." if len(callers) > 8 else "")) if callers else ""))
            hexb = " ".join("%02X" % b for b in mem[q:q + ln])
            line = "    %04X  %-9s  %-30s" % (q, hexb, text)
            if comments.get(q): line += " ; " + comments[q]
            if q in notes and q not in labels: line += " ; " + notes[q]
            w(line.rstrip())
            for st in switch_tables:
                if st[1] == q + ln:
                    w("    ; ---- switch table %04X-%04X (Keil CCASE) ----" % (st[1], st[2] - 1))
                    for v, t in st[3]:
                        w("    ;   %s -> %s" % ("default" if v == "default" else "case %02Xh" % v, labels.get(t, "%04X" % t)))
                    q2 = st[2]
                    w("    %04X  db %s" % (st[1], " ".join("%02X" % b for b in mem[st[1]:st[2]])))
                    q = q2 - ln
            q += ln
        else:
            start = q
            while q < top and q not in code:
                q += 1
            # data run
            w("")
            w("; ---- data %04X-%04X (%d bytes) ----" % (start, q - 1, q - start))
            a = start
            while a < q:
                if a in data_notes:
                    w("; " + data_notes[a])
                end = min(a + 16, q)
                for n in range(a + 1, end):
                    if n in data_notes:
                        end = n; break
                chunk = mem[a:end]
                asc = "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)
                w("    %04X  db %-48s ; %s" % (a, " ".join("%02X" % b for b in chunk), asc))
                a = end

    # ---------------- summary ----------------
    w("")
    w(";" + "=" * 76)
    w("; SUMMARY")
    w(";" + "=" * 76)
    w("; code bytes reached: %d of %d" % (sum(v[1] for v in code.values()), top))
    w("; subroutines: %d" % sum(1 for v in labels.values() if v.startswith("sub_")))
    if vendor:
        w("; other compares against bRequest (SETUPDAT1) - add/cjne chains, e.g. the standard USB requests:")
        for pc, v, how in vendor:
            w(";   %02Xh  at %04X (%s)" % (v, pc, how))
    if switch_tables:
        for st in switch_tables:
            w("; switch at %04X: %s" % (st[0], ", ".join(
                ("default" if v == "default" else "%02Xh" % v) + "->%04X" % t for v, t in st[3])))
    w("; FX2 registers used (R = read, W = write, count):")
    for a in sorted(xuse):
        nm = xname(a) or ""
        r = sum(1 for _, x in xuse[a] if x == "R"); wr = sum(1 for _, x in xuse[a] if x == "W")
        w(";   %04X  %-28s R%-3d W%-3d first at %04X" % (a, nm, r, wr, xuse[a][0][0]))
    print("\n".join(out))

if __name__ == "__main__":
    main()
