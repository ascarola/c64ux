# c64ux
Unix-inspired shell and RAM filesystem for the Commodore 64 (6502 assembly)

**C64UX** is a small Unix-inspired shell and in-memory filesystem written entirely in **6502 assembly** for the **Commodore 64**.

**Current version:** v0.2  
**Author:** Anthony Scarola

C64UX provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (or emulators) with **no disk I/O, no ROM patching, and no external dependencies**.

This project is both a learning exercise and a functional retro system environment.

---

## Features

- Interactive Unix-style shell
- RAM-resident filesystem
- File metadata (name, size, address, date, time)
- Session username, date, and time
- Auto-advancing clock based on the KERNAL jiffy timer
- Accurate uptime tracking across midnight rollovers
- Unix-like prompt with username
- Clean separation of subsystems (console, filesystem, time, commands)

---

## Commands

| Command   | Description |
|-----------|-------------|
| `HELP`    | Show available commands |
| `LS`      | List files (name, size, date, time) |
| `STAT`    | Show detailed file metadata |
| `CAT`     | Display file contents |
| `WRITE`   | Create a new file |
| `RM`      | Delete a file |
| `MEM`     | Show free BASIC memory |
| `DATE`    | Show current session date |
| `TIME`    | Show current session time |
| `UPTIME`  | Show system uptime (DAYS HH:MM:SS) |
| `PWD`     | Show current working path (`/HOME/<username>`) |
| `UNAME`   | Show system and version information |
| `WHOAMI`  | Show current username |
| `CLEAR`   | Clear screen (alias: `CLS`) |
| `EXIT`    | Return to BASIC |

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

All data is intentionally **volatile** and lost on reset or power-off.

---

## Time, Date & Uptime

- Time is driven by the C64 KERNAL jiffy clock
- Date is initialized during setup and auto-increments correctly
- Leap years supported (2000–2099)
- Uptime is calculated using a boot-time baseline and jiffy rollover detection
- Day transitions are handled correctly across midnight

---

## Prompt & Identity

The shell prompt follows a Unix-inspired format: username@C64UX:%

System identity and version information are centralized and reused across:
- Startup banner
- `UNAME`
- `VERSION` (alias)

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
