# c64ux
Unix-inspired shell with RAM filesystem, built-in editor, and disk bridging  
for the Commodore 64 (6502 assembly)

**C64UX** is a Unix-inspired shell written entirely in **6502 assembly** for the **Commodore 64**.  
It combines a RAM-resident filesystem, a nano-style text editor, and real Commodore DOS interaction to create a minimalist yet surprisingly capable retro system environment.

**Current version:** v0.5  
**Author:** Anthony Scarola

C64UX provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (including modern implementations) or emulators.  
It requires **no ROM patching**, relies exclusively on **standard KERNAL routines**, and supports **true disk access on device 8** when a drive is present.

This project is both a learning exercise and a functional retro shell that bridges **in-memory workflows**, **interactive editing**, and **real disk storage**.

**Downloads:** Versioned binaries and source snapshots are available on the **Releases** page.

---

## Features

- Interactive Unix-style shell
- RAM-resident filesystem
- Built-in nano-style multi-line text editor
- File metadata (name, size, address, date, time)
- Session username, date, and time
- Auto-advancing clock based on the KERNAL jiffy timer
- Accurate uptime tracking across midnight rollovers
- Unix-like prompt with username
- Integrated Commodore DOS command interface
- RAM ↔ disk file bridging (SAVE / LOAD)
- Unix-style file operations (CP, MV)
- Paged HELP display for full on-screen documentation
- Clean separation of subsystems (console, filesystem, editor, time, commands, DOS, disk I/O)

---

## Commands

| Command   | Description |
|-----------|-------------|
| `HELP`    | Show available commands (paged output) |
| `LS`      | List RAM filesystem files |
| `STAT`    | Show detailed file metadata |
| `CAT`     | Display file contents |
| `WRITE`   | Create a new RAM-resident text file |
| `NANO`    | Edit or create a RAM file (multi-line editor) |
| `RM`      | Delete a RAM file |
| `CP`      | Copy a RAM file to a new RAM file |
| `MV`      | Rename a RAM file |
| `SAVE`    | Save a RAM file to disk (device 8) |
| `LOAD`    | Load a disk file into the RAM filesystem |
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

## Nano-Style Editor (v0.4+)

C64UX includes a built-in **nano-style text editor** for RAM files.

### NANO Command
`NANO <filename>`

- Opens an existing RAM file for editing, or creates it if it does not exist
- Displays existing file contents before editing
- Accepts multi-line text input
- Editing ends when the user enters a single `.` on its own line
- Lines are stored using CR (`$0D`) separators
- Changes are saved back into the RAM filesystem

This enables real interactive editing instead of write-once file creation.

---

## RAM ↔ Disk Bridging (v0.5)

C64UX v0.5 introduces the first **direct bridge between the RAM filesystem and disk storage**.

### SAVE
`SAVE <filename>`

- Writes a RAM file to disk on **device 8**
- Files are saved as **SEQ** files using streamed KERNAL I/O
- Gracefully handles missing drives, channel errors, and disk failures

### LOAD
`LOAD <filename>`

- Loads a disk file from **device 8** into the RAM filesystem
- Creates or updates a RAM directory entry
- Streams file data directly into the RAM heap

These commands allow RAM-based workflows to persist beyond the current session.

---

## Commodore DOS Integration (v0.3+)

C64UX includes **direct Commodore DOS access** using standard KERNAL disk routines.

### DOS Command
Send raw DOS commands to device 8:
- `DOS I0`
- `DOS S:FILE`
- `DOS R:NEW=OLD`

### Directory Shortcut
- `DOS @$`

Displays a standard Commodore directory listing (blocks, filenames, types, and free blocks), equivalent to loading `$` in BASIC.

### Status Reporting
After each DOS command, C64UX automatically reads and prints the drive status line:
- `STATUS: 00, OK,00,00`

(actual status depends on command and drive state)

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

`username@C64UX:%`

System identity and version information are centralized and reused across:
- Startup banner
- `UNAME`
- `VERSION`

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
