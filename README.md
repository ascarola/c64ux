# c64ux
Unix-inspired shell with RAM filesystem, built-in editor, disk bridging, REU persistence,  
login support, and theming — for the Commodore 64 (6502 assembly)

**C64UX** is a Unix-inspired shell written entirely in **6502 assembly** for the **Commodore 64**.  
It combines a RAM-resident filesystem, a nano-style text editor, Commodore DOS integration, disk bridging, optional RAM Expansion Unit (REU) support, and now **user authentication and theming** to create a minimalist yet surprisingly capable retro system environment.

**Current version:** v0.7  
**Author:** Anthony Scarola

C64UX provides a command-driven interface reminiscent of early Unix systems, running on real C64 hardware (including modern implementations such as the Ultimate 64) or emulators.  
It requires **no ROM patching**, relies exclusively on **standard KERNAL routines**, and supports **true disk access across multiple devices** when drives are present.

This project is both a learning exercise and a functional retro shell that bridges **in-memory workflows**, **interactive editing**, **disk storage**, **REU-backed persistence**, and now **system identity and personalization**.

**Downloads:** Versioned binaries and source snapshots are available on the **Releases** page.

---

## Features

- Interactive Unix-style shell
- RAM-resident filesystem
- Built-in nano-style multi-line text editor
- File metadata (name, size, address, date, time)
- User login with username and password (v0.7)
- Persistent credentials stored on disk (v0.7)
- Auto-advancing clock based on the KERNAL jiffy timer
- Accurate uptime tracking across midnight rollovers
- Unix-like prompt with username
- Integrated Commodore DOS command interface
- RAM ↔ disk file bridging (SAVE / LOAD)
- True **SEQ file support** for text files (v0.6.1)
- Configurable default disk device (v0.6.1)
- Optional RAM ↔ REU filesystem persistence (v0.6)
- System color themes (v0.7)
- Unix-style file operations (CP, MV, RM with wildcards)
- Paged HELP display for full on-screen documentation
- Structured boot sequence with system-style startup messages (v0.7)
- Clean separation of subsystems (boot, console, filesystem, editor, auth, time, disk I/O, REU)

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
| `ECHO`    | Print text to the screen |
| `RM`      | Delete RAM files (supports prefix wildcards) |
| `CP`      | Copy a RAM file to a new RAM file |
| `MV`      | Rename a RAM file |
| `SAVE`    | Save a RAM file to disk (SEQ format) |
| `LOAD`    | Load a disk file into the RAM filesystem |
| `DRIVE`   | Show or set the default disk device (8–11) |
| `SAVEREU` | Save the entire RAM filesystem to REU |
| `LOADREU` | Restore the RAM filesystem from REU |
| `WIPEREU` | Clear the REU-stored filesystem image |
| `PASSWD`  | Change the current user password |
| `THEME`   | View or change the system color theme |
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

## Boot Sequence & Login (v0.7)

C64UX now features a structured, system-style boot process followed by user authentication.

### Boot Sequence
- Displays staged `[  OK  ]` initialization messages:
  - `STARTING C64UX KERNEL V0.7`
  - `MEMORY CHECK: 64K RAM SYSTEM`
  - `INITIALIZING FILESYSTEM`
  - `HEAP ALLOCATED AT $6000`
  - `DETECTING HARDWARE`
  - `REU: DETECTED` or `REU: NOT FOUND`
  - `LOADING DEVICE DRIVERS`
  - `MOUNTING /DEV/DISK (DEVICE 8)`
- Screen is cleared after boot for a clean banner display

### Login System
- On first run, the user is prompted to create a **username and password**, then enter the **session date and time**
- Credentials are stored in a disk-based **SEQ configuration file** (`CONFIG`) in plain text
- On subsequent runs, credentials are automatically loaded and the user is prompted for the session date and time
- User must authenticate before entering the shell
- Three failed login attempts return control to BASIC

---

## Themes (v0.7)

C64UX supports simple system-wide color themes.

### THEME Command
`THEME`  
`THEME <name>`

Available themes:
- `NORMAL`
- `DARK`
- `GREEN`

Themes control:
- Border color
- Background color
- Text color

Themes are reset to `NORMAL` on each program launch and applied after the banner to avoid PETSCII color conflicts.

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

---

## Default Drive Selection (v0.6.1)

### DRIVE Command
`DRIVE`  
`DRIVE <8–11>`

- Displays the current default drive
- Sets a new default drive for SAVE, LOAD, DOS, and directory operations

---

## REU Filesystem Persistence (v0.6)

C64UX includes optional **RAM Expansion Unit (REU) support**, allowing the entire RAM filesystem to be preserved across program exits or restarts without disk I/O.

### REU Commands
- `SAVEREU`
- `LOADREU`
- `WIPEREU`

The directory table and heap are copied via DMA and restored exactly as saved.  
Systems without an REU continue to function normally.

---

## Filesystem Design (RAM)

- **Directory size:** fixed (`DIR_MAX` = 8 entries)
- **Filename length:** 8 characters (space-padded)
- **Storage:** contiguous heap in RAM starting at `$6000`
- **Directory entry** (30 bytes each) **includes:**
  - Name (8 bytes)
  - Start address (2 bytes)
  - Length (2 bytes)
  - Creation date — 10 bytes (`YYYY-MM-DD`)
  - Creation time — 8 bytes (`HH:MM:SS`)

RAM filesystem data is volatile by default but can be preserved using REU support or saved to disk individually via `SAVE`.

---

## Build

Assemble using **ACME**:

```sh
acme -f cbm -o c64ux.prg c64ux.asm
```
