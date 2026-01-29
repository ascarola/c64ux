# c64ux
Unix-inspired shell with RAM filesystem and Commodore DOS integration  
for the Commodore 64 (6502 assembly)

**C64UX** is a small Unix-inspired shell written entirely in **6502 assembly** for the **Commodore 64**.  
It combines a RAM-resident filesystem with real Commodore DOS interaction, creating a minimalist but powerful retro system environment.

**Current version:** v0.3  
**Author:** Anthony Scarola

C64UX provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (or emulators).  
It requires **no ROM patching**, uses only **standard KERNAL routines**, and supports **true disk access via Commodore DOS** when a drive is present.

This project is both a learning exercise and a functional retro shell environment that bridges memory-only workflows with real disk operations.

Downloads: Versioned binaries are available on the Releases page.

---

## Features

- Interactive Unix-style shell
- RAM-resident filesystem
- File metadata (name, size, address, date, time)
- Session username, date, and time
- Auto-advancing clock based on the KERNAL jiffy timer
- Accurate uptime tracking across midnight rollovers
- Unix-like prompt with username
- Integrated Commodore DOS command interface
- Clean separation of subsystems (console, filesystem, time, commands, DOS)

---

## Commands

| Command   | Description |
|-----------|-------------|
| `HELP`    | Show available commands |
| `LS`      | List RAM filesystem files |
| `STAT`    | Show detailed file metadata |
| `CAT`     | Display file contents |
| `WRITE`   | Create a new RAM-resident text file |
| `RM`      | Delete a RAM file |
| `MEM`     | Show free BASIC memory |
| `DATE`    | Show current session date |
| `TIME`    | Show current session time |
| `UPTIME`  | Show system uptime (DAYS HH:MM:SS) |
| `PWD`     | Show current working path (`/HOME/<username>`) |
| `UNAME`   | Show system and version information |
| `VERSION` | Show version/build info (alias: `VER`) |
| `WHOAMI`  | Show current username |
| `CLEAR`   | Clear screen (alias: `CLS`) |
| `DOS`     | Send Commodore DOS command to drive 8 |
| `EXIT`    | Return to BASIC |

---

## Commodore DOS Integration (v0.3)

C64UX v0.3 adds **direct Commodore DOS access** using standard KERNAL disk routines.

### DOS Command
Send raw DOS commands to device 8:
- DOS I0
- DOS S:FILE
- DOS R:NEW=OLD

### Directory Shortcut
- DOS @$

Displays a standard Commodore directory listing (blocks and filenames), equivalent to loading `$` in BASIC.

### Status Reporting
After each DOS command, C64UX automatically reads and prints the drive status line:
- STATUS: 00, OK,00,00
(example; actual status depends on command and drive state)

This implementation:
- Uses `SETNAM`, `SETLFS`, `OPEN`, `CHKIN`, `CHRIN`, `READST`, `CLRCHN`
- Requires **true drive emulation** (recommended in VICE)
- Works with standard **1541-compatible `.d64` images**
- Does **not** require JiffyDOS or DolphinDOS

---

## Filesystem Design (RAM)

- **Directory size:** fixed (`DIR_MAX`)
- **Filename length:** 8 characters (space-padded)
- **Storage:** contiguous heap in RAM
- **Directory entry includes:**
  - Name
  - Start address
  - Length
  - Creation date (`YYYY-MM-DD`)
  - Creation time (`HH:MM:SS`)

All RAM filesystem data is intentionally **volatile** and lost on reset or power-off.

---

## Time, Date & Uptime

- Time is driven by the C64 KERNAL jiffy clock
- Date is initialized during setup and auto-increments correctly
- Leap years supported (2000–2099)
- Uptime is calculated using a boot-time baseline and jiffy rollover detection
- Day transitions are handled correctly across midnight

---

## Prompt & Identity

The shell prompt follows a Unix-inspired format:
- username@C64UX:%

System identity and version information are centralized and reused across:
- Startup banner
- `UNAME`
- `VERSION`

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
```

---

## Emulator Notes

For full disk functionality:
	•	Enable True Drive Emulation in VICE
	•	Attach a .d64 image to device 8
	•	Virtual drive traps should be disabled
