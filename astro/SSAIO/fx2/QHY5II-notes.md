# QHY5II.HEX — what the All-in-One's firmware does

First pass at the Orion StarShoot All-in-One firmware (QHY5LII-C inside).
The FX2 8051 runs this after `fxload` / QBCap uploads it into RAM.
The disassembly decodes 2,369 instructions and every one matches radare2.

## Files

| File | What it is |
|---|---|
| `QHY5II.HEX` | the firmware, Intel HEX (copy from `QBCap/qhy`) |
| `qhy5ii.bin` | the same as a plain 5,652-byte RAM image (from `objcopy`) |
| `fx2dis.py` | FX2-aware disassembler: follows code from the vectors, names every FX2 register, tracks DPTR, decodes the Keil switch table and the USB descriptors |
| `qhy5ii.names` | readable names for routines found so far — add to it as you work things out |
| `qhy5ii_annotated.asm` | the listing (3,166 lines) |

Re-make the listing after editing `qhy5ii.names`:

```
cd ~/Desktop/astro/SSAIO/fx2
python3 fx2dis.py QHY5II.HEX qhy5ii.names > qhy5ii_annotated.asm
```

Plain radare2 listing, for comparison (`-e scr.color=0` stops the colour codes):

```
r2 -a 8051 -e scr.color=0 -q -c 'pD 0x1614 @ 0' qhy5ii.bin > raw.asm
```

## How the camera is built (from the code)

- **Pixels never pass through the 8051.** `IFCONFIG = 43h`: slave-FIFO mode with
  an *external* interface clock, i.e. the sensor's pixel clock writes pixels straight
  into the EP2 FIFO. `EP2AUTOINLEN = 0200h` makes the FX2 send them by itself as
  512-byte USB bulk packets. No GPIF is used.
- **The FX2 makes the sensor's master clock.** The MT9M034 runs from the FX2's
  CLKOUT pin, switched by `CPUCS` bit 1. The exposure code turns it **off** during a
  long exposure (`isr_timer0`, `long_exposure`) — QHY was already quieting the sensor
  while it integrates. (Earlier I suggested that as a possible improvement; it is
  already in here, at least for the long-exposure mode.)
- **The 8051 clock is switchable** 12 / 24 / 48 MHz (command C8/C9).
- **The sensor is reached over I²C**, at the address held in RAM `2Fh`, with 8- or
  16-bit register addresses (flag bit `20h.6`). The PC sets almost all sensor
  registers itself (commands B7/B9/BB) — the firmware is mostly a pass-through.
- **Pins:** `IOA.1` = sensor reset (pulsed low at start-up and by CF),
  `IOA.3` = pulsed by the exposure timer (probably the sensor's trigger),
  `IOA.0`/INT0 = signal back from the sensor, `IOD.4–7` = the **ST-4 guide port**.
  The red LED is not pinned down yet.
- **The boot EEPROM** (I²C A0h) holds the `16c0:29a0` ID; the firmware also reads a
  config byte from it at start-up (shown in the C2 status reply).

## The vendor commands (bRequest), switch at 0084h

| Cmd | Name in listing | What it does |
|---|---|---|
| B3 | `cmd_B3_stop_capture` | interface back to ports mode, reset FIFOs (abort) |
| B7 | `cmd_B7_i2c_read_sensor` | read sensor register(s): wIndex = register, wLength bytes |
| B8 | `cmd_B8_set_capture` | 19-byte settings block → XDATA 2000h; byte 0 = mode 0/1/2 |
| B9 | `cmd_B9_i2c_write_3` | 3 bytes from the PC straight to the sensor |
| BB | `cmd_BB_i2c_write_sensor` | write sensor register: wIndex = register, data = payload |
| BD | `cmd_BD_start_exposure` | 32-bit exposure value, clock on, start |
| BF | `cmd_BF_clock_on` | sensor clock on, then does C0 |
| C0 | `cmd_C0_guide_pins` | **ST-4 guiding**: IOD.4–7, wValue = axis, wIndex = pins |
| C1 | `cmd_C1_start_exposure_b` | as BD |
| C2 | `cmd_C2_status` | 10-byte status / version block |
| C8, C9 | `cmd_C8_set_speed` | 8051 at 12 / 24 / 48 MHz |
| CA | `cmd_CA_eeprom_read` | read the boot EEPROM |
| CB | `cmd_CB_eeprom_write` | **writes the boot EEPROM** (refuses offsets 0–7, the USB ID) |
| CD | `cmd_CD_bus_width_8_16` | **8 / 16-bit switch**: data byte 0 = 8-bit pixel bus, not 0 = 16-bit (sets the WORDWIDE bit in EP2FIFOCFG, 08h / 09h) |
| CF | `cmd_CF_sensor_reset` | pulse the sensor's reset line |

**Never send CB.** It is the only command that changes anything permanent.
Everything else lives in RAM and is gone at the next unplug.

## Switching 8-bit / 16-bit without unplugging

The firmware can change bit depth while running: command CD only flips the FX2's
WORDWIDE bit (EP2FIFOCFG 08h = 8-bit, 09h = 16-bit). It does not reset the FIFOs and
needs no power cycle. The "turn the camera off first" rule comes from QHY's library,
which only sets bit depth when the camera is opened.

A live switch from our own driver would be:

1. **B3**: stop capture, reset the FIFOs (drops any half frame)
2. **BB**: set the sensor's output format registers to 8 or 12 bits
3. **CD**: 0 = 8-bit, 1 = 16-bit
4. start the next exposure (BD)

Not tested on the camera yet. Step 2's exact sensor registers still need to be
taken from a USB capture of libqhyccd opening the camera in each mode.

## Next steps

1. Watch which of these commands libqhyccd actually sends while QBCap runs
   (`sudo modprobe usbmon` + Wireshark, or a libusb log) — that ties each command to
   a QBCap action (exposure, gain, start frame).
2. Name the remaining subroutines (`sub_xxxx`) in `qhy5ii.names`: B8's three modes,
   the INT0 handler. (CD is done: the 8/16-bit switch.)
3. Find the LED pin (try each of IOA.1 / IOA.3 / port E in a test build).
4. Then a first firmware of your own (SDCC + fx2lib): blink the LED.
