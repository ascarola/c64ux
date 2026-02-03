# c64ux
Unix-inspired shell with RAM filesystem, built-in editor, disk bridging, and REU persistence  
for the Commodore 64 (6502 assembly)

**C64UX** is a Unix-inspired shell written entirely in **6502 assembly** for the **Commodore 64**.  
It combines a RAM-resident filesystem, a nano-style text editor, Commodore DOS integration, disk bridging, and optional RAM Expansion Unit (REU) support to create a minimalist yet surprisingly capable retro system environment.

**Current version:** v0.6.1  
**Author:** Anthony Scarola

C64UX provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (including modern implementations such as the Ultimate 64) or emulators.  
It requires **no ROM patching**, relies exclusively on **standard KERNAL routines**, and supports **true disk access across multiple devices** when drives are present.

This project is both a learning exercise and a functional retro shell that bridges **in-memory workflows**, **interactive editing**, **disk storage**, and **REU-backed persistence**.

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
- True **SEQ file support** for text files (v0.6.1)
- Configurable default disk device (v0.6.1)
- Optional RAM ↔ REU filesystem persistence (v0.6)
- Unix-style file operations (CP, MV, RM with wildcards)
- Paged HELP display for full on-screen documentation
- Clean separation of subsystems (console, filesystem, editor, time, disk I/O, REU)

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
| `RM`      | Delete RAM files (supports prefix wildcards) |
| `CP`      | Copy a RAM file to a new RAM file |
| `MV`      | Rename a RAM file |
| `SAVE`    | Save a RAM file to disk (SEQ format) |
| `LOAD`    | Load a disk file into the RAM filesystem |
| `DRIVE`   | Show or set the default disk device (8–11) |
| `SAVEREU` | Save the entire RAM filesystem to REU |
| `LOADREU` | Restore the RAM filesystem from REU |
| `WIPEREU` | Clear the REU-stored filesystem image |
| `MEM`     | Show free BASIC memory |
| `DATE`    | Show current session date |
| `TIME`    | Show current session time |
| `UPTIME`  | Show system uptime (DAYS HH:MM:SS) |
| `PWD`     | Show current working path (`/HOME/<username>`) |
| `UNAME`   | Show system and version information |
| `VERSION` | Show version/build info (alias: `VER`) |
| `WHOAMI`  | Show current username |
| `CLEAR`   | Clear screen (alias: `CLS`) |
| `DOS`     | Send Commodore DOS command to the active drive |
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

## RAM ↔ Disk Bridging (v0.5+)

C64UX supports direct bridging between the RAM filesystem and disk storage using **SEQ files**.

### SAVE
`SAVE <filename>`  
`SAVE <device>:<filename>`

- Writes a RAM file to disk as a **SEQ** file
- Uses streamed KERNAL I/O
- Honors the currently selected default drive
- Optional per-command device override

### LOAD
`LOAD <filename>`  
`LOAD <device>:<filename>`

- Loads a SEQ file from disk into the RAM filesystem
- Creates or updates a RAM directory entry
- Streams file data directly into the RAM heap

These commands allow RAM-based workflows to persist beyond the current session.

---

## Default Drive Selection (v0.6.1)

C64UX v0.6.1 introduces a configurable default disk device.

### DRIVE Command
`DRIVE`  
`DRIVE <8–11>`

- Displays the current default drive
- Sets a new default drive for SAVE, LOAD, DOS, and directory operations
- Eliminates hard-coded reliance on device 8

---

## REU Filesystem Persistence (v0.6)

C64UX includes optional **RAM Expansion Unit (REU) support**, allowing the entire RAM filesystem to be preserved across program exits or restarts without disk I/O.

### REU Commands

- `SAVEREU` — Saves the current RAM filesystem to the REU
- `LOADREU` — Restores the RAM filesystem from the REU
- `WIPEREU` — Clears the REU-stored filesystem image

### How It Works

- The directory table and heap are copied to REU memory using DMA
- A small metadata header is stored to validate filesystem integrity
- On load, the filesystem is restored exactly as it was
- If no REU is present, commands fail gracefully with clear messages

This feature is fully optional and does not affect systems without an REU.

---

## Commodore DOS Integration (v0.3+)

C64UX includes **direct Commodore DOS access** using standard KERNAL disk routines.

### DOS Command
Send raw DOS commands to the active drive:
- `DOS I0`
- `DOS S:FILE`
- `DOS R:NEW=OLD`

### Directory Shortcut
- `DOS @$`

Displays a standard Commodore directory listing (blocks, filenames, types, and free blocks), equivalent to loading `$` in BASIC.

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

RAM filesystem data is volatile by default, but can be preserved using REU support.

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
