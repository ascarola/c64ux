# c64ux
Unix-inspired shell and RAM filesystem for the Commodore 64 (6502 assembly)

**C64UX** is a small Unix-inspired shell and in-memory filesystem written entirely in **6502 assembly** for the **Commodore 64**.

**Version:** v0.1  
**Author:** A. Scarola

It provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (or emulators) with no disk I/O, no ROM patching, and no external dependencies.

This project is both a learning exercise and a functional retro system environment.

---

## Features

- Interactive shell with command parsing
- RAM-resident filesystem
- File metadata (name, size, address, date, time)
- Session username, date, and time
- Auto-advancing clock based on the KERNAL jiffy timer
- Clean separation of subsystems (console, filesystem, time, commands)

---

## Commands

| Command  | Description |
|----------|-------------|
| `HELP`   | Show available commands |
| `LS`     | List files (name, size, date, time) |
| `STAT`   | Show detailed file metadata |
| `CAT`    | Display file contents |
| `WRITE`  | Create a new file |
| `RM`     | Delete a file |
| `MEM`    | Show free BASIC memory |
| `DATE`   | Show current session date |
| `TIME`   | Show current session time |
| `UNAME`  | Show system info |
| `WHOAMI` | Show current username |
| `CLEAR`  | Clear screen |
| `EXIT`   | Return to BASIC |

---

## Filesystem Design

- **Directory size:** fixed (`DIR_MAX`)
- **Filename length:** 8 characters (space-padded)
- **Storage:** contiguous heap in RAM
- **Directory entry includes:**
  - Name
  - Start address
  - Length
  - Creation date (`YYYY-MM-DD`)
  - Creation time (`HH:MM:SS`)

All data is lost on reset or power-off by design.

---

## Time & Date

- Time is driven by the C64 KERNAL jiffy clock
- Date is initialized during setup and incremented correctly
- Leap years supported (2000–2099)

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
