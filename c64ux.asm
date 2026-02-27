; ============================================================
;  C64UX — Unix-inspired shell for the Commodore 64
;
;  Version:    v0.7
;  Author:     A. Scarola
;  Date:       2026-02-02
;
;  Description:
;    A small UNIX-like command shell and RAM-resident filesystem
;    written entirely in 6502 assembly for the Commodore 64.
;
;    Features include a command parser, in-memory filesystem,
;    file metadata (size/date/time), session user/date/time, a
;    nano-style editor, an auto-advancing clock based on
;    the KERNAL jiffy timer, and SAVE/LOAD commands for
;    bridging RAM filesystem with disk storage (device 8). In
;    addition, if an REU is present, commands exist to
;    support saving to, loading from, and wiping the
;    REU. A credentialing process and color themes have
;    also been added.
;
;  License:    MIT (see LICENSE file)
;  Assembler:  ACME
; ============================================================


; ------------------------------------------------------------
; 1) BASIC loader stub (SYS 2064 -> $0810)
; ------------------------------------------------------------
* = $0801
!word next
!word 10
!byte $9e
!text "2064"
!byte 0
next:
!word 0

; ------------------------------------------------------------
; 2) Program entry address
; ------------------------------------------------------------
* = $0810
    jmp start

; ------------------------------------------------------------
; 3) KERNAL entry points
; ------------------------------------------------------------
CHRIN  = $FFCF
CHROUT = $FFD2

RDTIM  = $FFDE     ; Read jiffy clock -> A=lo, X=mid, Y=hi
SETTIM = $FFDB     ; Set jiffy clock  <- A=lo, X=mid, Y=hi

TICKS_PER_SEC = 60 ; NTSC=60, PAL=50

; added these for the DOS command
SETNAM = $FFBD
SETLFS = $FFBA
OPEN   = $FFC0
CLOSE  = $FFC3
CHKIN  = $FFC6
CHKOUT = $FFC9
CLRCHN = $FFCC
READST = $FFB7

; ------------------------------------------------------------
; 4) Memory map / buffers
; ------------------------------------------------------------
LINEBUF = $0200
MAXLEN  = 200

CUR_TIME: !fill 8, '0'   ; HH:MM:SS (no zero terminator)

; ------------------------------------------------------------
; 5) RAM filesystem layout
; ------------------------------------------------------------
DIR_MAX        = 8
DIR_NAME_LEN   = 8

; Directory entry layout (fixed width)
DIR_OFF_NAME   = 0      ; 8 bytes (padded with spaces)
DIR_OFF_START  = 8      ; 2 bytes (lo/hi)
DIR_OFF_LEN    = 10     ; 2 bytes (lo/hi)

DIR_OFF_DATE   = 12     ; 10 bytes "YYYY-MM-DD"
DIR_DATE_LEN   = 10

DIR_OFF_TIME   = 22     ; 8 bytes  "HH:MM:SS"
DIR_TIME_LEN   = 8

DIR_ENTRY_SIZE = 30     ; total bytes per entry

FS_HEAP_BASE   = $6000  ; heap base for file contents (VICE-safe-ish)

; ------------------------------------------------------------
; 6) Zero-page pointer aliases (do not allocate; just aliases)
; ------------------------------------------------------------
ZPTR_LO = $F9
ZPTR_HI = $FA

PTR_LO  = $FB
PTR_HI  = $FC
DPTR_LO = $FD
DPTR_HI = $FE

; ------------------------------------------------------------
; 8) REU
; ------------------------------------------------------------
REU_STATUS  = $DF00
REU_COMMAND = $DF01

REU_C64_LO  = $DF02
REU_C64_HI  = $DF03

REU_REU_LO  = $DF04
REU_REU_MID = $DF05
REU_REU_HI  = $DF06

REU_LEN_LO  = $DF07
REU_LEN_HI  = $DF08

REU_IMASK   = $DF09
REU_ADDRCTL = $DF0A

; ------------------------------------------------------------
; 8) Misc.
; ------------------------------------------------------------

C64UX_VERSION = "V0.7"
C64UX_BUILD_DATE = "08 FEB 2026"

; ------------------------------------------------------------
; 8) Main entry / init
; ------------------------------------------------------------
start:
    sei
    lda #0
    sta theme_mode       ; reset to NORMAL on every RUN
    jsr cls
    jsr boot_sequence
    jsr banner
    jsr setup
    jsr apply_theme      ; re-apply after banner's white PETSCII override
    cli

main_loop:
    jsr prompt
    jsr read_line
;    jsr dump_linebuf     ; <<< DEBUG: show raw bytes
    jsr exec_cmd
    jmp main_loop

; ============================================================
; BOOT SEQUENCE
; ============================================================

; ------------------------------------------------------------
; boot_delay — busy-wait ~0.3s (18 jiffies @ 60 Hz NTSC)
; Uses KERNAL RDTIM; clobbers A, X, Y
; ------------------------------------------------------------
boot_delay:
    jsr RDTIM            ; A=lo, X=mid, Y=hi
    clc
    adc #18              ; target = now + 18 jiffies
    sta boot_delay_tgt
@wait:
    jsr RDTIM
    cmp boot_delay_tgt
    bcc @wait
    rts

boot_delay_tgt: !byte 0

; ------------------------------------------------------------
; boot_print_line — print "[  OK  ] " prefix + message + CR
;   Message address must be in ZPTR_LO/ZPTR_HI before call.
;   Calls boot_delay after printing.
; ------------------------------------------------------------
boot_print_line:
    lda #<boot_ok_txt
    sta PTR_LO
    lda #>boot_ok_txt
    sta PTR_HI
    ldy #0
@pfx:
    lda (PTR_LO),y
    beq @msg
    jsr CHROUT
    iny
    bne @pfx
@msg:
    jsr print_z
    lda #13
    jsr CHROUT
    jsr boot_delay
    rts

; ------------------------------------------------------------
; boot_sequence — systemd-style boot scroll
;   Calls fs_init and reu_detect at the appropriate points.
;   Clears screen when done so banner appears fresh.
; ------------------------------------------------------------
boot_sequence:
    ; Line 1: STARTING C64UX KERNEL V0.7
    lda #<boot_kern_txt
    sta ZPTR_LO
    lda #>boot_kern_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Line 2: MEMORY CHECK: 64K RAM SYSTEM
    lda #<boot_mem_txt
    sta ZPTR_LO
    lda #>boot_mem_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Line 3: INITIALIZING FILESYSTEM (real: call fs_init)
    lda #<boot_fs_txt
    sta ZPTR_LO
    lda #>boot_fs_txt
    sta ZPTR_HI
    jsr boot_print_line
    jsr fs_init

    ; Line 4: HEAP ALLOCATED AT $6000
    lda #<boot_heap_txt
    sta ZPTR_LO
    lda #>boot_heap_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Line 5: DETECTING HARDWARE
    lda #<boot_hw_txt
    sta ZPTR_LO
    lda #>boot_hw_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Line 6: REU result (conditional on reu_detect carry)
    jsr reu_detect
    bcc @no_reu
    lda #<boot_reu_yes_txt
    sta ZPTR_LO
    lda #>boot_reu_yes_txt
    sta ZPTR_HI
    jsr boot_print_line
    jmp @reu_done
@no_reu:
    lda #<boot_reu_no_txt
    sta ZPTR_LO
    lda #>boot_reu_no_txt
    sta ZPTR_HI
    jsr boot_print_line
@reu_done:

    ; Line 7: LOADING DEVICE DRIVERS
    lda #<boot_drv_txt
    sta ZPTR_LO
    lda #>boot_drv_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Line 8: MOUNTING /DEV/DISK (DEVICE 8)
    lda #<boot_mnt_txt
    sta ZPTR_LO
    lda #>boot_mnt_txt
    sta ZPTR_HI
    jsr boot_print_line

    ; Final pause, then apply theme and clear screen for banner
    jsr boot_delay
    jsr apply_theme
    jsr cls
    rts

; ------------------------------------------------------------
; reu_exec_dma
; A = command ($90 = C64->REU, $91 = REU->C64) with EXEC+FF00
; Refuses LEN=$0000 (because 0 == 64K on real REU)
; ------------------------------------------------------------
reu_exec_dma:
    pha                     ; Save command first!

    lda REU_LEN_LO
    ora REU_LEN_HI
    bne reu_dma_exec

    ; Length is zero, skip DMA
    pla                     ; Clean up stack
    rts

reu_dma_exec:
    ; Set "unused bits" the way REUs expect
    lda #$1F
    sta REU_IMASK
    lda #$3F
    sta REU_ADDRCTL

    ; Clear status flags by reading STATUS before command (esp compare/fault)
    lda REU_STATUS

    pla                     ; Restore command
    sta REU_COMMAND
    rts

reu_c64_to_reu:
    lda #$90
    jmp reu_exec_dma

reu_reu_to_c64:
    lda #$91
    jmp reu_exec_dma

; ------------------------------------------------------------
; reu_detect
; C=1 if present and working, C=0 if absent or not working
; Tests DMA at safe address $000FF (between dir and heap)
; ------------------------------------------------------------
reu_detect:
    lda REU_STATUS
    cmp #$FF
    beq reu_not_found

    ; Write test pattern to safe REU address $000FF
    lda #$A5
    sta reu_test_byte
    lda #<reu_test_byte
    sta REU_C64_LO
    lda #>reu_test_byte
    sta REU_C64_HI
    lda #$FF
    sta REU_REU_LO
    lda #0
    sta REU_REU_MID
    sta REU_REU_HI
    lda #1
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI
    jsr reu_c64_to_reu

    ; Read it back
    lda #0
    sta reu_test_byte
    lda #<reu_test_byte
    sta REU_C64_LO
    lda #>reu_test_byte
    sta REU_C64_HI
    lda #$FF
    sta REU_REU_LO
    lda #0
    sta REU_REU_MID
    sta REU_REU_HI
    lda #1
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI
    jsr reu_reu_to_c64

    ; Check if we got test pattern back
    lda reu_test_byte
    cmp #$A5
    bne reu_not_found
    sec
    rts

reu_not_found:
    clc
    rts

reu_test_byte:
    !byte 0

reu_metadata:
    !byte 0,0,0,0   ; magic, dir_count, heap_lo, heap_hi

reu_metadata_chk:
    !byte 0,0,0,0

; ============================================================
; CONSOLE / UI ROUTINES
; ============================================================

; ------------------------------------------------------------
; banner - print startup banner text (banner_txt)
; ------------------------------------------------------------
banner:
    ldx #0
@loop:
    lda banner_txt,x
    beq @exit
    jsr CHROUT
    inx
    bne @loop
@exit:
    ; Check for REU and print status if present
    jsr reu_detect
    bcc @no_reu
    lda #<reu_banner_txt
    sta ZPTR_LO
    lda #>reu_banner_txt
    sta ZPTR_HI
    jsr print_z
@no_reu:
    ; Print help message
    lda #<banner_help_txt
    sta ZPTR_LO
    lda #>banner_help_txt
    sta ZPTR_HI
    jsr print_z
    rts


; ------------------------------------------------------------
; prompt - print newline + @username>@prompt string (prompt_tail_txt)
; ------------------------------------------------------------
prompt:
    lda #13
    jsr CHROUT

    ; print USERNAME
    lda #<USERNAME
    sta ZPTR_LO
    lda #>USERNAME
    sta ZPTR_HI
    jsr print_z

    ; print prompt string
    ldx #0
@p2:
    lda prompt_tail_txt,x
    beq @done
    jsr CHROUT
    inx
    bne @p2

@done:
    rts

; ------------------------------------------------------------
; cls - clear screen (SHIFT+CLR/HOME = PETSCII 147)
; ------------------------------------------------------------
cls:
    lda #147
    jsr CHROUT
    rts

; ------------------------------------------------------------
; apply_theme — set border, background and text colour from
;               theme_mode (0=NORMAL, 1=DARK, 2=GREEN)
; ------------------------------------------------------------
apply_theme:
    ldx theme_mode
    lda theme_border,x
    sta $D020
    lda theme_bg,x
    sta $D021
    lda theme_fg,x
    sta $0286
    rts

theme_border: !byte 14, 0, 0    ; NORMAL, DARK, GREEN
theme_bg:     !byte  6, 0, 0
theme_fg:     !byte  1,15, 5

; -------------------------
; Read a line (blocking)
; supports Backspace and Enter
; -------------------------
read_line:
    ldx #0
@wait:
    jsr CHRIN
    cmp #13            ; RETURN ends the line
    beq @end

    cmp #20            ; DEL (backspace)
    beq @bksp
    cmp #157           ; cursor-left
    beq @bksp

    cpx #MAXLEN
    bcs @wait          ; ignore extra chars beyond MAXLEN

    sta LINEBUF,x
    inx
    bne @wait

@bksp:
    cpx #0
    beq @wait
    dex
    jmp @wait

@end:
    lda #0
    sta LINEBUF,x
    rts

; ============================================================
; LINE INPUT NORMALIZATION
; ============================================================
; normalize_buf
; Converts LINEBUF to uppercase ASCII A–Z
;
; Handles PETSCII variants:
;   $61–$7A  ('a'–'z')  → subtract $20
;   $C1–$DA  (shifted)  → subtract $80
; Stops at zero terminator.
; ------------------------------------------------------------

normalize_buf:
    ldx #0

@lp:
    lda LINEBUF,x
    beq @done

    ; if 'a'..'z' ($61-$7A), make uppercase by -$20
    cmp #$61
    bcc @chk_c1
    cmp #$7B
    bcs @chk_c1
    sec
    sbc #$20
    sta LINEBUF,x
    jmp @next

@chk_c1:
    ; if $C1..$DA, map to $41..$5A by -$80
    cmp #$C1
    bcc @next
    cmp #$DB
    bcs @next
    sec
    sbc #$80
    sta LINEBUF,x

@next:
    inx
    bne @lp

@done:
    rts

; ============================================================
; FIRST-RUN SETUP (USERNAME / DATE / TIME)
; ============================================================

USER_MAX = 16      ; includes null terminator
DATE_MAX = 11      ; "YYYY-MM-DD" + 0
TIME_MAX = 9       ; "HH:MM:SS" + 0

setup:
    jsr load_config          ; try to load CONFIG from disk
    bcc @full_setup          ; carry clear = not found -> full setup

    ; Config loaded successfully
    lda #1
    sta config_loaded
    lda #<setup_header_txt
    sta ZPTR_LO
    lda #>setup_header_txt
    sta ZPTR_HI
    jsr print_z
    jsr setup_date
    jsr setup_time
    jsr init_clock
    jsr login_prompt         ; authenticate user
    rts

@full_setup:
    lda #0
    sta config_loaded
    lda #<setup_header_txt
    sta ZPTR_LO
    lda #>setup_header_txt
    sta ZPTR_HI
    jsr print_z
    jsr setup_username
    jsr setup_password
    jsr setup_date
    jsr setup_time
    jsr init_clock
    jsr save_config          ; persist credentials to disk
    rts

; ------------------------------------------------------------
; init_clock
; Initialize clock, uptime baseline, and day-rollover tracking
; ------------------------------------------------------------
init_clock:
    jsr set_clock_from_time_str

    ; Initialize rollover tracker + uptime baseline
    jsr read_clock_to_jiffies
    jsr jiffies_to_seconds16        ; -> sec_lo/sec_hi (my routine's outputs)

    lda sec_lo
    sta BOOT_SEC_LO
    lda sec_hi
    sta BOOT_SEC_HI

    lda #0
    sta UP_DAYS_LO
    sta UP_DAYS_HI

    ; Initialize day-rollover detection
    lda jlo
    sta LAST_JLO
    lda jmid
    sta LAST_JMID
    lda jhi
    sta LAST_JHI
    rts

; ------------------------------------------------------------
; setup_username
; ------------------------------------------------------------
setup_username:
    lda #<setup_user_txt
    sta ZPTR_LO
    lda #>setup_user_txt
    sta ZPTR_HI
    jsr print_z

@read:
    jsr read_line

    lda LINEBUF
    bne @copy
    ; empty -> default
    ldx #0
@def:
    lda default_user_txt,x
    sta USERNAME,x
    beq @done
    inx
    bne @def

@copy:
    ldx #0
@c:
    lda LINEBUF,x
    sta USERNAME,x
    beq @done
    inx
    cpx #USER_MAX-1
    bcc @c
    lda #0
    sta USERNAME+USER_MAX-1
@done:
    rts

; ------------------------------------------------------------
; setup_password
; Asks for password with confirmation, stores in PASSWORD
; ------------------------------------------------------------
setup_password:
@again:
    lda #13
    jsr CHROUT
    lda #<setup_pass_txt
    sta ZPTR_LO
    lda #>setup_pass_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Copy LINEBUF to PASSWORD
    ldx #0
@cp:
    lda LINEBUF,x
    sta PASSWORD,x
    beq @copied
    inx
    cpx #USER_MAX-1
    bcc @cp
    lda #0
    sta PASSWORD+USER_MAX-1
@copied:

    ; Ask for confirmation
    lda #13
    jsr CHROUT
    lda #<setup_confirm_txt
    sta ZPTR_LO
    lda #>setup_confirm_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Compare LINEBUF against PASSWORD
    ldx #0
@cmp:
    lda PASSWORD,x
    beq @chk_end
    cmp LINEBUF,x
    bne @mismatch
    inx
    cpx #USER_MAX
    bne @cmp
    beq @match
@chk_end:
    lda LINEBUF,x
    bne @mismatch
@match:
    lda #13
    jsr CHROUT
    rts
@mismatch:
    lda #13
    jsr CHROUT
    lda #<pass_mismatch_txt
    sta ZPTR_LO
    lda #>pass_mismatch_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp @again

; ------------------------------------------------------------
; login_prompt
; Authenticate user (3 attempts, then exit to BASIC)
; ------------------------------------------------------------
login_prompt:
    lda #0
    sta login_attempts

@retry:
    lda #13
    jsr CHROUT
    lda #<login_user_txt
    sta ZPTR_LO
    lda #>login_user_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Compare LINEBUF with USERNAME
    lda #0
    sta login_user_ok
    ldx #0
@cmp_u:
    lda USERNAME,x
    beq @chk_u_end
    cmp LINEBUF,x
    bne @u_no
    inx
    cpx #USER_MAX
    bne @cmp_u
    beq @u_yes
@chk_u_end:
    lda LINEBUF,x
    bne @u_no
@u_yes:
    lda #1
    sta login_user_ok
@u_no:

    lda #13
    jsr CHROUT
    lda #<login_pass_txt
    sta ZPTR_LO
    lda #>login_pass_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Compare LINEBUF with PASSWORD
    ldx #0
@cmp_p:
    lda PASSWORD,x
    beq @chk_p_end
    cmp LINEBUF,x
    bne @p_fail
    inx
    cpx #USER_MAX
    bne @cmp_p
    beq @p_ok
@chk_p_end:
    lda LINEBUF,x
    bne @p_fail
@p_ok:
    ; Password matched, check username too
    lda login_user_ok
    bne @success

@p_fail:
    lda #13
    jsr CHROUT
    lda #<login_fail_txt
    sta ZPTR_LO
    lda #>login_fail_txt
    sta ZPTR_HI
    jsr print_z

    inc login_attempts
    lda login_attempts
    cmp #3
    bcc @retry

    ; 3 failed attempts -> exit to BASIC
    lda #13
    jsr CHROUT
    lda #<login_locked_txt
    sta ZPTR_LO
    lda #>login_locked_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp $A474          ; BASIC warm start

@success:
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; load_config
; Try to load CONFIG,S,R from default_drive
; On success: USERNAME and PASSWORD populated, carry set
; On failure: carry clear
; ------------------------------------------------------------
load_config:
    ; Build filename "CONFIG,S,R" using config_fname_r
    ldx #0
@copy_r:
    lda config_fname_r,x
    beq @copy_r_done
    sta DOSFNAME,x
    inx
    bne @copy_r
@copy_r_done:
    ; X = length of "CONFIG,S,R" = 10
    txa
    ldx #<DOSFNAME
    ldy #>DOSFNAME
    jsr SETNAM

    lda #2
    ldx default_drive
    ldy #0               ; SA=0 = SEQ read
    jsr SETLFS

    jsr OPEN
    jsr READST
    bne @fail

    ldx #2
    jsr CHKIN
    jsr READST
    bne @fail_close

    ; Read USERNAME until CR ($0D)
    ldx #0
@read_user:
    jsr CHRIN
    cmp #$0D
    beq @user_done
    cpx #USER_MAX-1
    bcs @read_user       ; skip extra chars
    sta USERNAME,x
    inx
    jmp @read_user
@user_done:
    lda #0
    sta USERNAME,x

    ; Check for read error
    jsr READST
    and #$BF             ; mask out EOI
    bne @fail_close

    ; Read PASSWORD until CR ($0D)
    ldx #0
@read_pass:
    jsr CHRIN
    cmp #$0D
    beq @pass_done
    cpx #USER_MAX-1
    bcs @read_pass       ; skip extra chars
    sta PASSWORD,x
    inx
    jmp @read_pass
@pass_done:
    lda #0
    sta PASSWORD,x

    ; Close and clean up
    jsr CLRCHN
    lda #2
    jsr CLOSE

    ; Print success
    lda #13
    jsr CHROUT
    lda #<config_loaded_txt
    sta ZPTR_LO
    lda #>config_loaded_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT

    sec                  ; success
    rts

@fail_close:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    clc                  ; failure
    rts

@fail:
    jsr CLRCHN
    clc                  ; failure
    rts

; ------------------------------------------------------------
; save_config
; Save USERNAME and PASSWORD to CONFIG,S,W on default_drive
; ------------------------------------------------------------
save_config:
    ; Build filename "CONFIG,S,W" using config_fname_w
    ldx #0
@copy_w:
    lda config_fname_w,x
    beq @copy_w_done
    sta DOSFNAME,x
    inx
    bne @copy_w
@copy_w_done:
    ; X = length of "CONFIG,S,W" = 10
    txa
    ldx #<DOSFNAME
    ldy #>DOSFNAME
    jsr SETNAM

    lda #2
    ldx default_drive
    ldy #1               ; SA=1 = SEQ write
    jsr SETLFS

    jsr OPEN
    jsr READST
    beq @open_ok
    jmp @write_fail

@open_ok:
    ldx #2
    jsr CHKOUT
    jsr READST
    beq @chkout_ok
    jmp @chkout_fail

@chkout_ok:
    ; Write USERNAME bytes until null, then CR
    ldx #0
@wu:
    lda USERNAME,x
    beq @wu_done
    jsr CHROUT
    inx
    cpx #USER_MAX
    bne @wu
@wu_done:
    lda #$0D
    jsr CHROUT

    ; Write PASSWORD bytes until null, then CR
    ldx #0
@wp:
    lda PASSWORD,x
    beq @wp_done
    jsr CHROUT
    inx
    cpx #USER_MAX
    bne @wp
@wp_done:
    lda #$0D
    jsr CHROUT

    ; Close and clean up
    jsr CLRCHN
    lda #2
    jsr CLOSE

    ; Print success
    lda #13
    jsr CHROUT
    lda #<config_saved_txt
    sta ZPTR_LO
    lda #>config_saved_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

@chkout_fail:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    rts

@write_fail:
    jsr CLRCHN
    rts

; ------------------------------------------------------------
; setup_date  (stores "YYYY-MM-DD")
; ------------------------------------------------------------
setup_date:
    lda #13
    jsr CHROUT

    ldx #0
@p:
    lda setup_date_txt,x
    beq @read
    jsr CHROUT
    inx
    bne @p

@read:
    jsr read_line

    lda LINEBUF
    bne @copy
    ; empty -> default
    ldx #0
@def:
    lda default_date_txt,x
    sta DATE_STR,x
    beq @done
    inx
    bne @def

@copy:
    ldx #0
@c:
    lda LINEBUF,x
    sta DATE_STR,x
    beq @done
    inx
    cpx #DATE_MAX-1
    bcc @c
    lda #0
    sta DATE_STR+DATE_MAX-1
@done:
    rts


; ------------------------------------------------------------
; setup_time (stores "HH:MM:SS")
; ------------------------------------------------------------
setup_time:
    lda #13
    jsr CHROUT

    ldx #0
@p:
    lda setup_time_txt,x
    beq @read
    jsr CHROUT
    inx
    bne @p

@read:
    jsr read_line

    lda LINEBUF
    bne @copy
    ; empty -> default
    ldx #0
@def:
    lda default_time_txt,x
    sta TIME_STR,x
    beq @done
    inx
    bne @def

@copy:
    ldx #0
@c:
    lda LINEBUF,x
    sta TIME_STR,x
    beq @done
    inx
    cpx #TIME_MAX-1
    bcc @c
    lda #0
    sta TIME_STR+TIME_MAX-1
@done:
    rts

; ------------------------------------------------------------
; set_clock_from_time_str
; Reads TIME_STR "HH:MM:SS", converts to jiffies, calls SETTIM.
; Uses TICKS_PER_SEC (60 NTSC, 50 PAL).
; ------------------------------------------------------------
set_clock_from_time_str:
    ; hours = (TIME_STR[0..1])
    lda TIME_STR
    jsr digit_to_n
    sta tmp8a              ; tens
    lda TIME_STR+1
    jsr digit_to_n
    sta tmp8b              ; ones
    lda tmp8a
    asl                    ; *2
    asl                    ; *4
    asl                    ; *8
    asl                    ; *16
    asl                    ; *32   (not good) -> do 10*tens:
    ; We'll do tens*10 = tens*8 + tens*2
    lda tmp8a
    asl                    ; *2
    sta tmp8c
    lda tmp8a
    asl
    asl
    asl                    ; *8
    clc
    adc tmp8c              ; *10
    clc
    adc tmp8b              ; + ones
    sta hours              ; 0..23

    ; mins = TIME_STR[3..4]
    lda TIME_STR+3
    jsr digit_to_n
    sta tmp8a
    lda TIME_STR+4
    jsr digit_to_n
    sta tmp8b
    lda tmp8a
    asl
    sta tmp8c              ; *2
    lda tmp8a
    asl
    asl
    asl                    ; *8
    clc
    adc tmp8c              ; *10
    clc
    adc tmp8b
    sta mins               ; 0..59

    ; secs = TIME_STR[6..7]
    lda TIME_STR+6
    jsr digit_to_n
    sta tmp8a
    lda TIME_STR+7
    jsr digit_to_n
    sta tmp8b
    lda tmp8a
    asl
    sta tmp8c              ; *2
    lda tmp8a
    asl
    asl
    asl                    ; *8
    clc
    adc tmp8c              ; *10
    clc
    adc tmp8b
    sta secs               ; 0..59

    ; total_seconds = hours*3600 + mins*60 + secs  (16-bit)
    jsr calc_total_seconds

    ; jiffies = total_seconds * TICKS_PER_SEC (24-bit)
    jsr seconds_to_jiffies_24

    ; set KERNAL clock
    lda jlo
    ldx jmid
    ldy jhi
    jsr SETTIM
    rts

; ============================================================
; TIME / CLOCK ROUTINES (KERNAL JIFFY CLOCK)
; ============================================================
; Uses:
;   RDTIM  ($FFDE)  -> A=low, X=mid, Y=high
;   SETTIM ($FFDB)  <- A=low, X=mid, Y=high
;
; NOTE: Set TICKS_PER_SEC to 60 (NTSC) or 50 (PAL).
; ============================================================

; ---------------------------
; digit_to_n
; Convert PETSCII/ASCII digit '0'..'9' -> 0..9
; In:  A = '0'..'9'
; Out: A = 0..9
; ---------------------------
digit_to_n:
    sec
    sbc #'0'
    rts

; ---------------------------
; calc_total_seconds (16-bit)
; total = hours*3600 + mins*60 + secs
; result -> tot_lo/tot_hi
; Preserves: hours/mins/secs (uses h_work/m_work)
; ---------------------------
calc_total_seconds:
    lda #0
    sta tot_lo
    sta tot_hi

    lda hours
    sta h_work
    lda mins
    sta m_work

; add hours * 3600
@hloop:
    lda h_work
    beq @mins_part
    dec h_work

    clc
    lda tot_lo
    adc #<3600
    sta tot_lo
    lda tot_hi
    adc #>3600
    sta tot_hi
    jmp @hloop

@mins_part:
; add mins * 60
@mloop:
    lda m_work
    beq @secs_part
    dec m_work

    clc
    lda tot_lo
    adc #<60
    sta tot_lo
    lda tot_hi
    adc #>60
    sta tot_hi
    jmp @mloop

@secs_part:
    clc
    lda tot_lo
    adc secs
    sta tot_lo
    lda tot_hi
    adc #0
    sta tot_hi
    rts

; ------------------------------------------------------------
; seconds_to_jiffies_24
; jiffies = total_seconds * TICKS_PER_SEC
; input : tot_lo/tot_hi (16-bit)
; output: jlo/jmid/jhi  (24-bit)
; ------------------------------------------------------------
seconds_to_jiffies_24:
    lda #0
    sta jlo
    sta jmid
    sta jhi

    ldx #0
@mult_loop:
    cpx #TICKS_PER_SEC
    beq @done

    clc
    lda jlo
    adc tot_lo
    sta jlo
    lda jmid
    adc tot_hi
    sta jmid
    lda jhi
    adc #0
    sta jhi

    inx
    jmp @mult_loop
@done:
    rts

; ------------------------------------------------------------
; read_clock_to_jiffies
; Reads current jiffy clock via RDTIM into jlo/jmid/jhi
; ------------------------------------------------------------
read_clock_to_jiffies:
    jsr RDTIM
    sta jlo
    stx jmid
    sty jhi
    rts

; ------------------------------------------------------------
; jiffies_to_seconds16
; seconds = jiffies / TICKS_PER_SEC
; input : jlo/jmid/jhi
; output: sec_lo/sec_hi
; ------------------------------------------------------------
jiffies_to_seconds16:
    lda jlo
    sta nlo
    lda jmid
    sta nmid
    lda jhi
    sta nhi

    lda #0
    sta quo0
    sta quo1
    sta quo2
    sta rem8

    ldx #24
@divloop:
    asl nlo
    rol nmid
    rol nhi
    rol rem8

    lda rem8
    cmp #TICKS_PER_SEC
    bcc @qbit0
    sec
    sbc #TICKS_PER_SEC
    sta rem8
    sec
    bcs @rolq
@qbit0:
    clc
@rolq:
    rol quo0
    rol quo1
    rol quo2

    dex
    bne @divloop

    lda quo0
    sta sec_lo
    lda quo1
    sta sec_hi
    rts

; ------------------------------------------------------------
; seconds16_to_hms
; Converts sec_lo/sec_hi (0..86399) -> h_out/m_out/s_out
; ------------------------------------------------------------
seconds16_to_hms:
    lda sec_lo
    sta work_lo
    lda sec_hi
    sta work_hi

    lda #0
    sta h_out

@h:
    lda work_hi
    cmp #>3600
    bcc @m
    bne @hsub
    lda work_lo
    cmp #<3600
    bcc @m
@hsub:
    sec
    lda work_lo
    sbc #<3600
    sta work_lo
    lda work_hi
    sbc #>3600
    sta work_hi
    inc h_out
    jmp @h

@m:
    lda #0
    sta m_out

@mloop:
    lda work_hi
    bne @msub
    lda work_lo
    cmp #60
    bcc @s
@msub:
    sec
    lda work_lo
    sbc #60
    sta work_lo
    lda work_hi
    sbc #0
    sta work_hi
    inc m_out
    jmp @mloop

@s:
    lda work_lo
    sta s_out
    rts

; ------------------------------------------------------------
; update_day_rollover
; - Detects midnight rollover by comparing current jiffies to LAST_J*
; - If current jiffies < last jiffies => clock wrapped => new day
; - On rollover:
;     * increments DATE_STR by 1 day (inc_date_str)
;     * increments UPTIME day counter (UP_DAYS)
; - Always updates LAST_J* to current jiffies
;
; Uses: A
; Clobbers: jlo/jmid/jhi (via read_clock_to_jiffies)
; ------------------------------------------------------------
update_day_rollover:
    jsr read_clock_to_jiffies     ; sets jlo/jmid/jhi

    ; if (jhi < LAST_JHI) => wrapped
    lda jhi
    cmp LAST_JHI
    bcc @wrapped
    bne @save

    ; if (jmid < LAST_JMID) => wrapped
    lda jmid
    cmp LAST_JMID
    bcc @wrapped
    bne @save

    ; if (jlo < LAST_JLO) => wrapped
    lda jlo
    cmp LAST_JLO
    bcc @wrapped
    ; else not wrapped
    jmp @save

@wrapped:
    jsr inc_date_str              ; DATE_STR = DATE_STR + 1 day

    ; UPTIME days++ (counts midnights passed since boot)
    inc UP_DAYS_LO
    bne @save
    inc UP_DAYS_HI                ; carry into high byte if low wrapped

@save:
    lda jlo
    sta LAST_JLO
    lda jmid
    sta LAST_JMID
    lda jhi
    sta LAST_JHI
    rts

; ------------------------------------------------------------
; store_2d_at_date
; Stores A (0..99) into DATE_STR+Y as two ASCII digits.
; In:  A = value (0..99)
;      Y = offset into DATE_STR (5 for month, 8 for day)
; Clobbers: A, X
; ------------------------------------------------------------
store_2d_at_date:
    ldx #'0'
@tens:
    cmp #10
    bcc @ones
    sec
    sbc #10
    inx
    bne @tens
@ones:
    pha              ; save ones (0..9)
    txa
    sta DATE_STR,y   ; tens
    iny
    pla
    clc
    adc #'0'
    sta DATE_STR,y   ; ones
    rts

; ------------------------------------------------------------
; inc_year_in_str
; Increments YYYY in DATE_STR (positions 0..3) with carry.
; Example: 2026 -> 2027, 2099 -> 2100, 9999 -> 0000
; Clobbers: A
; ------------------------------------------------------------
inc_year_in_str:
    ldy #3
@carry_loop:
    lda DATE_STR,y
    cmp #'9'
    bne @inc
    lda #'0'
    sta DATE_STR,y
    dey
    bpl @carry_loop
    rts               ; overflow past 0000..9999 wraps to 0000
@inc:
    clc
    adc #1
    sta DATE_STR,y
    rts

; ------------------------------------------------------------
; inc_date_str
; Increments DATE_STR ("YYYY-MM-DD") by 1 day.
; Leap year rule (2000–2099): year % 4 == 0
;
; DATE_STR layout:
;   0 1 2 3 4 5 6 7 8 9
;   Y Y Y Y - M M - D D
;
; Clobbers: A, X, Y
; Uses: d_day, d_month, d_max, d_tmp
; ------------------------------------------------------------
inc_date_str:
    ; ---- parse month (MM) ----
    lda DATE_STR+5
    jsr digit_to_n
    sta d_tmp              ; tens
    lda #0
    sta d_month
@mm_tens_loop:
    lda d_tmp
    beq @mm_ones
    dec d_tmp
    clc
    lda d_month
    adc #10
    sta d_month
    jmp @mm_tens_loop
@mm_ones:
    lda DATE_STR+6
    jsr digit_to_n
    clc
    adc d_month
    sta d_month            ; month now 1..12

    ; ---- parse day (DD) ----
    lda DATE_STR+8
    jsr digit_to_n
    sta d_tmp              ; tens
    lda #0
    sta d_day
@dd_tens_loop:
    lda d_tmp
    beq @dd_ones
    dec d_tmp
    clc
    lda d_day
    adc #10
    sta d_day
    jmp @dd_tens_loop
@dd_ones:
    lda DATE_STR+9
    jsr digit_to_n
    clc
    adc d_day
    sta d_day              ; day now 1..31

    ; ---- day++ ----
    inc d_day

    ; ---- lookup max days in month ----
    ldx d_month
    dex                    ; 1..12 -> 0..11
    lda month_len,x
    sta d_max

    ; ---- leap year adjustment if month == 2 ----
    lda d_month
    cmp #2
    bne @check_day

    ; leap if (last two digits of year) % 4 == 0
    ; last two digits are DATE_STR+2 and DATE_STR+3
    lda DATE_STR+2
    jsr digit_to_n         ; tens
    asl                    ; *2  (since 10 mod 4 = 2)
    sta d_tmp              ; tens*2
    lda DATE_STR+3
    jsr digit_to_n         ; ones
    clc
    adc d_tmp              ; (tens*2 + ones)
    and #$03               ; mod 4
    bne @check_day         ; not leap

    ; leap year => Feb max = 29
    lda #29
    sta d_max

@check_day:
    lda d_day
    cmp d_max
    bcc @store_day_ok      ; day < max
    beq @store_day_ok      ; day == max

    ; ---- overflow day -> set day=1 and month++ ----
    lda #1
    sta d_day
    inc d_month
    lda d_month
    cmp #13
    bne @store_month_day   ; month still 1..12

    ; ---- overflow month -> month=1 and year++ ----
    lda #1
    sta d_month
    jsr inc_year_in_str

@store_month_day:
    ; store month (MM) at offset 5
    lda d_month
    ldy #5
    jsr store_2d_at_date

@store_day_ok:
    ; store day (DD) at offset 8
    lda d_day
    ldy #DIR_OFF_START
    jsr store_2d_at_date
    rts

; ------------------------------------------------------------
; build_cur_time
; Builds CUR_TIME (8 bytes) from current jiffy clock
; Output: CUR_TIME = "HH:MM:SS" (no terminator)
; Clobbers: A,X,Y
; ------------------------------------------------------------
build_cur_time:
    jsr read_clock_to_jiffies
    jsr jiffies_to_seconds16
    jsr seconds16_to_hms

    lda h_out
    ldy #0
    jsr store_2d
    lda #':'
    sta CUR_TIME+2

    lda m_out
    ldy #3
    jsr store_2d
    lda #':'
    sta CUR_TIME+5

    lda s_out
    ldy #6
    jsr store_2d
    rts

; ------------------------------------------------------------
; store_2d
; Stores A (0..99) as 2 digits into CUR_TIME at offset Y
; Input:  A = 0..99, Y = destination offset
; Output: CUR_TIME[Y]   = tens ASCII
;         CUR_TIME[Y+1] = ones ASCII
; Clobbers: A, X
; ------------------------------------------------------------
store_2d:
    ldx #0
@tens:
    cmp #10
    bcc @ones
    sec
    sbc #10
    inx
    bne @tens
@ones:
    pha                 ; save ones (0..9) in A
    txa                 ; tens (0..9)
    clc
    adc #'0'
    sta CUR_TIME,y      ; store tens
    iny
    pla                 ; ones back into A
    clc
    adc #'0'
    sta CUR_TIME,y      ; store ones
    rts

; ------------------------------------------------------------
; print_2d
; Prints A as 2 decimal digits (00..99) with leading zero.
; Input:  A = 0..99
; Clobbers: A, X
; ------------------------------------------------------------
print_2d:
    ldx #0
@tens:
    cmp #10
    bcc @ones
    sec
    sbc #10
    inx
    bne @tens
@ones:
    pha                 ; save ones (0..9)
    txa                 ; tens (0..9)
    clc
    adc #'0'
    jsr CHROUT
    pla                 ; ones
    clc
    adc #'0'
    jsr CHROUT
    rts

; ------------------------------------------------------------
; print_drive_status
; Opens device 8, channel 15, and prints the full status line.
; Reads until CR ($0D). Always restores channels.
; ------------------------------------------------------------
print_drive_status:
    ; SETNAM length=0 (empty name)
    lda #0
    ldx #0
    ldy #0
    jsr SETNAM

    ; SETLFS(LA=15, DEV=default, SA=15)
    lda #15
    ldx default_drive
    ldy #15
    jsr SETLFS

    jsr OPEN
    jsr READST
    bne pds_open_fail

    ; Redirect input to logical file 15
    ldx #15
    jsr CHKIN
    jsr READST
    bne pds_chkin_fail

pds_loop:
    jsr CHRIN          ; read from drive channel 15
    cmp #$0D           ; CR ends the status line
    beq pds_done

    jsr CHROUT
    jmp pds_loop

pds_done:
    lda #13
    jsr CHROUT
    jmp pds_cleanup

pds_open_fail:
    lda #<dos_openfail_txt
    sta ZPTR_LO
    lda #>dos_openfail_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp pds_cleanup

pds_chkin_fail:
    lda #<dos_nochan_txt
    sta ZPTR_LO
    lda #>dos_nochan_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp pds_cleanup

pds_cleanup:
    jsr CLRCHN
    lda #15
    jsr CLOSE
    rts

; ============================================================
; COMMAND DISPATCH
; ============================================================
; exec_cmd
; - Skips leading spaces
; - Dispatches based on command keyword
; - Commands MUST be uppercase (normalize_buf handles this)
; ------------------------------------------------------------

exec_cmd:
    ldx #0

; ------------------------------------------------------------
; Skip leading spaces
; ------------------------------------------------------------
@skip:
    lda LINEBUF,x
    cmp #' '
    bne @check_empty
    inx
    bne @skip

@check_empty:
    lda LINEBUF,x
    bne @not_empty
    jmp @done

@not_empty:

; ------------------------------------------------------------
; Dispatch chain (in order)
; ------------------------------------------------------------

    ; HELP?
    jsr is_help
    bcc @try_dos
    jsr cmd_help
    rts

@try_dos:
    ; DOS?
    jsr is_dos
    bcc @try_echo
    jsr cmd_dos
    rts

@try_echo:
    ; ECHO?
    jsr is_echo
    bcc @try_ls
    jsr cmd_echo
    rts

@try_ls:
    ; LS?
    jsr is_ls
    bcc @try_cat
    jsr cmd_ls
    rts

@try_cat:
    ; CAT?
    jsr is_cat
    bcc @try_stat
    jsr cmd_cat
    rts

@try_stat:
    ; STAT?
    jsr is_stat
    bcc @try_rm
    jsr cmd_stat
    rts

@try_rm:
    jsr is_rm
    bcc @try_mem
    jsr cmd_rm
    rts

@try_mem:
    ; MEM?
    jsr is_mem
    bcc @try_uname
    jsr cmd_mem
    rts

@try_uname:
    ; UNAME?
    jsr is_uname
    bcc @try_version
    jsr cmd_uname
    rts

@try_version:
    ; VERSION?
    jsr is_version
    bcc @try_exit
    jsr cmd_version
    rts

@try_exit:
    ; EXIT?
    jsr is_exit
    bcc @try_write
    jsr cmd_exit
    rts

@try_write:
    ; WRITE?
    jsr is_write
    bcc @try_whoami
    jsr cmd_write
    rts

@try_whoami:
    ; WHOAMI?
    jsr is_whoami
    bcc @try_date
    jsr cmd_whoami
    rts

@try_date:
    jsr is_date
    bcc @try_time
    jsr cmd_date
    rts

@try_time:
    jsr is_time
    bcc @try_uptime
    jsr cmd_time
    rts

@try_uptime:
    jsr is_uptime
    bcc @try_pwd
    jsr cmd_uptime
    rts

@try_pwd:
    jsr is_pwd
    bcc @try_nano
    jsr cmd_pwd
    rts

@try_nano
    jsr is_nano
    bcc @try_clear
    jsr cmd_nano
    rts

@try_clear:
    ; CLEAR?
    jsr is_clear
    bcc @try_drive
    jsr cls
    rts

@try_drive:
    ; DRIVE?
    jsr is_drive
    bcc @try_save
    jsr cmd_drive
    rts

@try_save:
    ; SAVE?
    jsr is_save
    bcc @try_load
    jsr cmd_save
    rts

@try_load:
    ; LOAD?
    jsr is_load
    bcc @try_loadreu
    jsr cmd_load
    rts

@try_loadreu:
    ; LOADREU?
    jsr is_loadreu
    bcc @try_savereu
    jsr cmd_loadreu
    rts

@try_savereu:
    ; SAVEREU?
    jsr is_savereu
    bcc @try_wipereu
    jsr cmd_savereu
    rts

@try_wipereu:
    ; WIPEREU?
    jsr is_wipereu
    bcc @try_cp
    jsr cmd_wipereu
    rts

@try_cp:
    ; CP?
    jsr is_cp
    bcc @try_mv
    jsr cmd_cp
    rts

@try_mv:
    ; MV?
    jsr is_mv
    bcc @try_passwd
    jsr cmd_mv
    rts

@try_passwd:
    ; PASSWD?
    jsr is_passwd
    bcc @try_theme
    jsr cmd_passwd
    rts

@try_theme:
    ; THEME?
    jsr is_theme
    bcc @unknown
    jsr cmd_theme
    rts

; ------------------------------------------------------------
; Fallback
; ------------------------------------------------------------
@unknown:
    jsr msg_unknown

@done:
    rts

; ============================================================
; COMMAND MATCHERS (is_*)
; - Return SEC if LINEBUF matches command keyword
; - Return CLC otherwise
; - Accept either end-of-line or a space after the keyword
; ============================================================

; ------------------------------------------------------------
; is_help
; Matches command: HELP
;
; Input:
;   X = index into LINEBUF (start of command)
;
; Output:
;   C = 1 if LINEBUF matches "HELP"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "HELP" or "HELP <args>"
;   - Command must already be uppercased
; ------------------------------------------------------------
is_help:
    lda LINEBUF,x
    cmp #'H'
    bne @no
    lda LINEBUF+1,x
    cmp #'E'
    bne @no
    lda LINEBUF+2,x
    cmp #'L'
    bne @no
    lda LINEBUF+3,x
    cmp #'P'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20      ; space
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_stat
; Matches command: STAT
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "STAT"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "STAT" or "STAT <filename>"
; ------------------------------------------------------------
is_stat:
    lda LINEBUF,x
    cmp #'S'
    bne @no
    lda LINEBUF+1,x
    cmp #'T'
    bne @no
    lda LINEBUF+2,x
    cmp #'A'
    bne @no
    lda LINEBUF+3,x
    cmp #'T'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_rm
; Matches command: RM
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "RM"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "RM" or "RM <filename>"
; ------------------------------------------------------------
is_rm:
    lda LINEBUF,x
    cmp #'R'
    bne @no
    lda LINEBUF+1,x
    cmp #'M'
    bne @no
    lda LINEBUF+2,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_echo
; Matches command: ECHO
;
; Input:
;   X = index into LINEBUF (start of command)
;
; Output:
;   C = 1 if LINEBUF matches "ECHO"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "ECHO" or "ECHO <text...>"
;   - Text following the command is not parsed here
;   - Command must already be uppercased
; ------------------------------------------------------------
is_echo:
    lda LINEBUF,x
    cmp #'E'
    bne @no
    lda LINEBUF+1,x
    cmp #'C'
    bne @no
    lda LINEBUF+2,x
    cmp #'H'
    bne @no
    lda LINEBUF+3,x
    cmp #'O'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20          ; space
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ============================================================
; is_ls
; ------------------------------------------------------------
; Command matcher for:
;   LS
;
; Matches:
;   "LS"
;   "LS " (LS followed by arguments, which are ignored)
;
; Behavior:
;   - Compares LINEBUF at offset X against 'L','S'
;   - Accepts end-of-line or space after keyword
;
; Input:
;   LINEBUF = normalized command buffer
;   X       = index of first non-space character
;
; Output:
;   Carry set   = command matches LS
;   Carry clear = no match
;
; Clobbers:
;   A
; ============================================================
is_ls:
    lda LINEBUF,x
    cmp #'L'
    bne @no
    lda LINEBUF+1,x
    cmp #'S'
    bne @no
    lda LINEBUF+2,x
    beq @yes
    cmp #$20          ; space
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_cat
; ------------------------------------------------------------
; Checks whether the current command token is "CAT"
;
; Input:
;   X = index into LINEBUF (first non-space character)
;
; Match rules:
;   - Matches "CAT" exactly
;   - Allows either:
;       • End of line after CAT
;       • A space following CAT (for arguments)
;
; Output:
;   C = 1 (SEC) if match
;   C = 0 (CLC) if not a match
;
; Clobbers:
;   A
; ------------------------------------------------------------
is_cat:
    lda LINEBUF,x
    cmp #'C'
    bne @no
    lda LINEBUF+1,x
    cmp #'A'
    bne @no
    lda LINEBUF+2,x
    cmp #'T'
    bne @no
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_mem
; ------------------------------------------------------------
; Checks whether the current command token is "MEM"
;
; Input:
;   X = index into LINEBUF (first non-space character)
;
; Match rules:
;   - Matches "MEM" exactly
;   - Allows either:
;       • End of line after MEM
;       • A space following MEM
;
; Output:
;   C = 1 (SEC) if match
;   C = 0 (CLC) if not a match
;
; Clobbers:
;   A
; ------------------------------------------------------------
is_mem:
    lda LINEBUF,x
    cmp #'M'
    bne @no
    lda LINEBUF+1,x
    cmp #'E'
    bne @no
    lda LINEBUF+2,x
    cmp #'M'
    bne @no
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_loadreu
; Matches "LOADREU"
; ------------------------------------------------------------
is_loadreu:
    lda LINEBUF,x
    cmp #'L'
    bne is_loadreu_no
    lda LINEBUF+1,x
    cmp #'O'
    bne is_loadreu_no
    lda LINEBUF+2,x
    cmp #'A'
    bne is_loadreu_no
    lda LINEBUF+3,x
    cmp #'D'
    bne is_loadreu_no
    lda LINEBUF+4,x
    cmp #'R'
    bne is_loadreu_no
    lda LINEBUF+5,x
    cmp #'E'
    bne is_loadreu_no
    lda LINEBUF+6,x
    cmp #'U'
    bne is_loadreu_no

    ; Next char must be EOL or space
    lda LINEBUF+7,x
    beq is_loadreu_yes
    cmp #$20
    beq is_loadreu_yes

is_loadreu_no:
    clc
    rts

is_loadreu_yes:
    sec
    rts

; ------------------------------------------------------------
; is_savereu
; Matches "SAVEREU"
; ------------------------------------------------------------
is_savereu:
    lda LINEBUF,x
    cmp #'S'
    bne is_savereu_no
    lda LINEBUF+1,x
    cmp #'A'
    bne is_savereu_no
    lda LINEBUF+2,x
    cmp #'V'
    bne is_savereu_no
    lda LINEBUF+3,x
    cmp #'E'
    bne is_savereu_no
    lda LINEBUF+4,x
    cmp #'R'
    bne is_savereu_no
    lda LINEBUF+5,x
    cmp #'E'
    bne is_savereu_no
    lda LINEBUF+6,x
    cmp #'U'
    bne is_savereu_no

    ; Next char must be EOL or space
    lda LINEBUF+7,x
    beq is_savereu_yes
    cmp #$20
    beq is_savereu_yes

is_savereu_no:
    clc
    rts

is_savereu_yes:
    sec
    rts

; ------------------------------------------------------------
; is_wipereu
; Matches "WIPEREU"
; ------------------------------------------------------------
is_wipereu:
    lda LINEBUF,x
    cmp #'W'
    bne is_wipereu_no
    lda LINEBUF+1,x
    cmp #'I'
    bne is_wipereu_no
    lda LINEBUF+2,x
    cmp #'P'
    bne is_wipereu_no
    lda LINEBUF+3,x
    cmp #'E'
    bne is_wipereu_no
    lda LINEBUF+4,x
    cmp #'R'
    bne is_wipereu_no
    lda LINEBUF+5,x
    cmp #'E'
    bne is_wipereu_no
    lda LINEBUF+6,x
    cmp #'U'
    bne is_wipereu_no

    ; Next char must be EOL or space
    lda LINEBUF+7,x
    beq is_wipereu_yes
    cmp #$20
    beq is_wipereu_yes

is_wipereu_no:
    clc
    rts

is_wipereu_yes:
    sec
    rts

; ------------------------------------------------------------
; is_uname
; ------------------------------------------------------------
; Command matcher for "UNAME"
;
; Matches:
;   UNAME
;   UNAME <args>   (arguments are ignored)
;
; Behavior:
;   - Compares LINEBUF starting at X against the literal string "UNAME"
;   - Accepts either end-of-line (0) or a space after the command
;
; Returns:
;   SEC set  -> match
;   CLC clear -> no match
;
; Notes:
;   - Case must already be normalized to uppercase
;   - Does not validate or consume arguments
; ------------------------------------------------------------
is_uname:
    lda LINEBUF,x
    cmp #'U'
    bne @no
    lda LINEBUF+1,x
    cmp #'N'
    bne @no
    lda LINEBUF+2,x
    cmp #'A'
    bne @no
    lda LINEBUF+3,x
    cmp #'M'
    bne @no
    lda LINEBUF+4,x
    cmp #'E'
    bne @no
    lda LINEBUF+5,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_clear
; ------------------------------------------------------------
; Command matcher: CLEAR or CLS
;
; Accepts:
;   "CLEAR"
;   "CLS"
; followed by end-of-line (0) or space ($20)
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if match
;   C = 0 if not match
;
; Clobbers:
;   A
; ------------------------------------------------------------
is_clear:
    lda LINEBUF,x
    cmp #'C'
    bne @no

    lda LINEBUF+1,x
    cmp #'L'
    bne @no

    lda LINEBUF+2,x
    cmp #'S'
    beq @cls_tail

    ; otherwise must be CLEAR
    cmp #'E'
    bne @no

    lda LINEBUF+3,x
    cmp #'A'
    bne @no

    lda LINEBUF+4,x
    cmp #'R'
    bne @no

    lda LINEBUF+5,x
    beq @yes
    cmp #$20          ; space
    beq @yes
    bne @no

@cls_tail:
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    beq @yes

@yes:
    sec
    rts

@no:
    clc
    rts

; ------------------------------------------------------------
; is_dos
; ------------------------------------------------------------
; Matches:
;   "DOS" + end-of-line
;   "DOS " + args
; ------------------------------------------------------------
is_dos:
    lda LINEBUF,x
    cmp #'D'
    bne @no
    lda LINEBUF+1,x
    cmp #'O'
    bne @no
    lda LINEBUF+2,x
    cmp #'S'
    bne @no
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    beq @yes
@no:
    clc
    rts
@yes:
    sec
    rts

; ------------------------------------------------------------
; is_version
; ------------------------------------------------------------
; Command matcher: VERSION (alias: VER)
;
; Accepts:
;   "VERSION" or "VER"
; followed by end-of-line (0) or space ($20)
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if match
;   C = 0 if not match
;
; Clobbers:
;   A
; ------------------------------------------------------------
is_version:
    lda LINEBUF,x
    cmp #'V'
    bne @no
    lda LINEBUF+1,x
    cmp #'E'
    bne @no
    lda LINEBUF+2,x
    cmp #'R'
    bne @no

    ; If end/space here -> "VER"
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    beq @yes

    ; Otherwise must be "VERSION"
    cmp #'S'
    bne @no
    lda LINEBUF+4,x
    cmp #'I'
    bne @no
    lda LINEBUF+5,x
    cmp #'O'
    bne @no
    lda LINEBUF+6,x
    cmp #'N'
    bne @no

    lda LINEBUF+7,x
    beq @yes
    cmp #$20
    bne @no

@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_whoami
; C=1 if LINEBUF[x..] begins with "WHOAMI" and ends or space
; ------------------------------------------------------------
is_whoami:
    lda LINEBUF,x
    cmp #'W'
    bne @no
    lda LINEBUF+1,x
    cmp #'H'
    bne @no
    lda LINEBUF+2,x
    cmp #'O'
    bne @no
    lda LINEBUF+3,x
    cmp #'A'
    bne @no
    lda LINEBUF+4,x
    cmp #'M'
    bne @no
    lda LINEBUF+5,x
    cmp #'I'
    bne @no
    lda LINEBUF+6,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_exit
; ------------------------------------------------------------
; Command matcher for EXIT
;
; Matches:
;   EXIT
;   EXIT <args>
;
; Behavior:
;   - Compares LINEBUF at offset X against "EXIT"
;   - Allows either end-of-line or space after keyword
;
; Returns:
;   C = 1  → command matches
;   C = 0  → no match
; ------------------------------------------------------------
is_exit:
    lda LINEBUF,x
    cmp #'E'
    bne @no
    lda LINEBUF+1,x
    cmp #'X'
    bne @no
    lda LINEBUF+2,x
    cmp #'I'
    bne @no
    lda LINEBUF+3,x
    cmp #'T'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20          ; space
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_write
; ------------------------------------------------------------
; Command matcher for WRITE
;
; Matches:
;   WRITE <name> <text...>
;
; Behavior:
;   - Compares LINEBUF at offset X against "WRITE"
;   - Allows either end-of-line or space after keyword
;
; Notes:
;   - Argument parsing is handled by cmd_write
;
; Returns:
;   C = 1  → command matches
;   C = 0  → no match
; ------------------------------------------------------------
is_write:
    lda LINEBUF,x
    cmp #'W'
    bne @no
    lda LINEBUF+1,x
    cmp #'R'
    bne @no
    lda LINEBUF+2,x
    cmp #'I'
    bne @no
    lda LINEBUF+3,x
    cmp #'T'
    bne @no
    lda LINEBUF+4,x
    cmp #'E'
    bne @no
    lda LINEBUF+5,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_date
; - Returns C=1 if command at LINEBUF,X is "DATE" followed by
;   end-of-line or a space.
; - Returns C=0 otherwise.
; ------------------------------------------------------------
is_date:
    lda LINEBUF,x
    cmp #'D'
    bne @no
    lda LINEBUF+1,x
    cmp #'A'
    bne @no
    lda LINEBUF+2,x
    cmp #'T'
    bne @no
    lda LINEBUF+3,x
    cmp #'E'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_time
; ------------------------------------------------------------
; Matcher for TIME command.
; Accepts:
;   "TIME" (end of line)  or  "TIME " (space after keyword)
;
; In:
;   X = index into LINEBUF (start of command)
;
; Out:
;   C = 1 if match
;   C = 0 if not match
; ------------------------------------------------------------
is_time:
    lda LINEBUF,x
    cmp #'T'
    bne @no
    lda LINEBUF+1,x
    cmp #'I'
    bne @no
    lda LINEBUF+2,x
    cmp #'M'
    bne @no
    lda LINEBUF+3,x
    cmp #'E'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_uptime
; ------------------------------------------------------------
; Command matcher: UPTIME
;
; Accepts:
;   "UPTIME" followed by end-of-line (0)
;   "UPTIME" followed by a space ($20) and arguments
;
; Input:
;   X = index into LINEBUF (start position to test)
;
; Output:
;   C = 1 if match
;   C = 0 if not a match
;
; Clobbers:
;   A
; ------------------------------------------------------------
is_uptime:
    lda LINEBUF,x
    cmp #'U'
    bne @no
    lda LINEBUF+1,x
    cmp #'P'
    bne @no
    lda LINEBUF+2,x
    cmp #'T'
    bne @no
    lda LINEBUF+3,x
    cmp #'I'
    bne @no
    lda LINEBUF+4,x
    cmp #'M'
    bne @no
    lda LINEBUF+5,x
    cmp #'E'
    bne @no
    lda LINEBUF+6,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_pwd
; ------------------------------------------------------------
; Matcher for PWD command.
; Accepts:
;   "PWD" (end of line) or "PWD " (space after keyword)
;
; In:
;   X = index into LINEBUF (start of command)
; Out:
;   C = 1 if match, C = 0 otherwise
; ------------------------------------------------------------
is_pwd:
    lda LINEBUF,x
    cmp #'P'
    bne @no
    lda LINEBUF+1,x
    cmp #'W'
    bne @no
    lda LINEBUF+2,x
    cmp #'D'
    bne @no
    lda LINEBUF+3,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_nano
; Matches:
;   "NANO" + EOL
;   "NANO " + args
; ------------------------------------------------------------
is_nano:
    lda LINEBUF,x
    cmp #'N'
    bne @no
    lda LINEBUF+1,x
    cmp #'A'
    bne @no
    lda LINEBUF+2,x
    cmp #'N'
    bne @no
    lda LINEBUF+3,x
    cmp #'O'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    beq @yes
@no:
    clc
    rts
@yes:
    sec
    rts

; ------------------------------------------------------------
; is_drive
; Matches command: DRIVE
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "DRIVE"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "DRIVE" or "DRIVE <number>"
; ------------------------------------------------------------
is_drive:
    lda LINEBUF,x
    cmp #'D'
    bne @no

    lda LINEBUF+1,x
    cmp #'R'
    bne @no

    lda LINEBUF+2,x
    cmp #'I'
    bne @no

    lda LINEBUF+3,x
    cmp #'V'
    bne @no

    lda LINEBUF+4,x
    cmp #'E'
    bne @no

    lda LINEBUF+5,x
    beq @yes
    cmp #$20
    beq @yes

@no:
    clc
    rts

@yes:
    sec
    rts

; ------------------------------------------------------------
; is_save
; Matches command: SAVE
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "SAVE"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "SAVE" or "SAVE <filename>"
; ------------------------------------------------------------
is_save:
    lda LINEBUF,x
    cmp #'S'
    bne @no
    lda LINEBUF+1,x
    cmp #'A'
    bne @no
    lda LINEBUF+2,x
    cmp #'V'
    bne @no
    lda LINEBUF+3,x
    cmp #'E'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_load
; Matches command: LOAD
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "LOAD"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "LOAD" or "LOAD <filename>"
; ------------------------------------------------------------
is_load:
    lda LINEBUF,x
    cmp #'L'
    bne @no
    lda LINEBUF+1,x
    cmp #'O'
    bne @no
    lda LINEBUF+2,x
    cmp #'A'
    bne @no
    lda LINEBUF+3,x
    cmp #'D'
    bne @no
    lda LINEBUF+4,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_cp
; Matches command: CP
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "CP"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "CP" or "CP <source> <dest>"
; ------------------------------------------------------------
is_cp:
    lda LINEBUF,x
    cmp #'C'
    bne @no
    lda LINEBUF+1,x
    cmp #'P'
    bne @no
    lda LINEBUF+2,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_mv
; Matches command: MV
;
; Input:
;   X = index into LINEBUF
;
; Output:
;   C = 1 if LINEBUF matches "MV"
;   C = 0 otherwise
;
; Notes:
;   - Accepts "MV" or "MV <source> <dest>"
; ------------------------------------------------------------
is_mv:
    lda LINEBUF,x
    cmp #'M'
    bne @no
    lda LINEBUF+1,x
    cmp #'V'
    bne @no
    lda LINEBUF+2,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_passwd
; Matches command: PASSWD
; ------------------------------------------------------------
is_passwd:
    lda LINEBUF,x
    cmp #'P'
    bne @no
    lda LINEBUF+1,x
    cmp #'A'
    bne @no
    lda LINEBUF+2,x
    cmp #'S'
    bne @no
    lda LINEBUF+3,x
    cmp #'S'
    bne @no
    lda LINEBUF+4,x
    cmp #'W'
    bne @no
    lda LINEBUF+5,x
    cmp #'D'
    bne @no
    lda LINEBUF+6,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ------------------------------------------------------------
; is_theme
; Matches command: THEME
; ------------------------------------------------------------
is_theme:
    lda LINEBUF,x
    cmp #'T'
    bne @no
    lda LINEBUF+1,x
    cmp #'H'
    bne @no
    lda LINEBUF+2,x
    cmp #'E'
    bne @no
    lda LINEBUF+3,x
    cmp #'M'
    bne @no
    lda LINEBUF+4,x
    cmp #'E'
    bne @no
    lda LINEBUF+5,x
    beq @yes
    cmp #$20
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

; ============================================================
; COMMAND HANDLERS (cmd_*)
; ============================================================

; ------------------------------------------------------------
; cmd_theme
; THEME [NORMAL|DARK|GREEN]
;
; No argument  → print current theme + usage
; Valid name    → set theme_mode, call apply_theme, confirm
; Invalid name → print usage
; ------------------------------------------------------------
cmd_theme:
    lda #13
    jsr CHROUT

    ; skip past "THEME" (5 chars)
    txa
    clc
    adc #5
    tax

    ; skip spaces
@skip_sp:
    lda LINEBUF,x
    bne @chk_sp
    jmp @show_current       ; no argument — show current theme
@chk_sp:
    cmp #$20
    bne @got_arg
    inx
    bne @skip_sp

@got_arg:
    ; --- check for "NORMAL" ---
    lda LINEBUF,x
    cmp #'N'
    bne @try_dark
    lda LINEBUF+1,x
    cmp #'O'
    bne @bad
    lda LINEBUF+2,x
    cmp #'R'
    bne @bad
    lda LINEBUF+3,x
    cmp #'M'
    bne @bad
    lda LINEBUF+4,x
    cmp #'A'
    bne @bad
    lda LINEBUF+5,x
    cmp #'L'
    bne @bad
    lda #0
    sta theme_mode
    jsr apply_theme
    jmp @confirm

@try_dark:
    cmp #'D'
    bne @try_green
    lda LINEBUF+1,x
    cmp #'A'
    bne @bad
    lda LINEBUF+2,x
    cmp #'R'
    bne @bad
    lda LINEBUF+3,x
    cmp #'K'
    bne @bad
    lda #1
    sta theme_mode
    jsr apply_theme
    jmp @confirm

@try_green:
    cmp #'G'
    bne @bad
    lda LINEBUF+1,x
    cmp #'R'
    bne @bad
    lda LINEBUF+2,x
    cmp #'E'
    bne @bad
    lda LINEBUF+3,x
    cmp #'E'
    bne @bad
    lda LINEBUF+4,x
    cmp #'N'
    bne @bad
    lda #2
    sta theme_mode
    jsr apply_theme
    jmp @confirm

@bad:
    ; unknown argument — show usage
    jmp @usage

@show_current:
    ; print "CURRENT THEME: "
    lda #<theme_cur_txt
    sta ZPTR_LO
    lda #>theme_cur_txt
    sta ZPTR_HI
    jsr print_z
    ; print name for current mode
    jsr theme_print_name
    lda #13
    jsr CHROUT
@usage:
    lda #<theme_usage_txt
    sta ZPTR_LO
    lda #>theme_usage_txt
    sta ZPTR_HI
    jsr print_z
    rts

@confirm:
    ; print "THEME SET TO: "
    lda #<theme_set_txt
    sta ZPTR_LO
    lda #>theme_set_txt
    sta ZPTR_HI
    jsr print_z
    jsr theme_print_name
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; theme_print_name — print name for current theme_mode
; ------------------------------------------------------------
theme_print_name:
    lda theme_mode
    cmp #1
    beq @dark
    cmp #2
    beq @green
    ; default NORMAL
    lda #<theme_name_normal
    sta ZPTR_LO
    lda #>theme_name_normal
    sta ZPTR_HI
    jmp print_z
@dark:
    lda #<theme_name_dark
    sta ZPTR_LO
    lda #>theme_name_dark
    sta ZPTR_HI
    jmp print_z
@green:
    lda #<theme_name_green
    sta ZPTR_LO
    lda #>theme_name_green
    sta ZPTR_HI
    jmp print_z

; ----------------------------
; cmd_loadreu
; ----------------------------
cmd_loadreu:
    jsr reu_detect
    bcs loadreu_have_reu
    jmp loadreu_no_reu
loadreu_have_reu:

    ; --- load metadata ---
    ; Clear metadata buffer first so stale data doesn't fool the check
    lda #0
    sta reu_metadata+0
    sta reu_metadata+1
    sta reu_metadata+2
    sta reu_metadata+3

    lda #<reu_metadata
    sta REU_C64_LO
    lda #>reu_metadata
    sta REU_C64_HI
    lda #0
    sta REU_REU_LO
    sta REU_REU_MID
    sta REU_REU_HI
    lda #4
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI
    jsr reu_reu_to_c64

    lda reu_metadata
    cmp #$C6
    beq @meta_ok
    jmp loadreu_bad
@meta_ok:

    lda reu_metadata+1
    cmp #DIR_MAX
    bcc loadreu_dir_ok
    lda #DIR_MAX
loadreu_dir_ok:
    sta DIR_COUNT

    lda reu_metadata+2
    sta fs_heap_lo
    lda reu_metadata+3
    sta fs_heap_hi

    ; --- load directory ---
    lda #<DIR_TABLE
    sta REU_C64_LO
    lda #>DIR_TABLE
    sta REU_C64_HI
    lda #$04
    sta REU_REU_LO
    lda #0
    sta REU_REU_MID
    sta REU_REU_HI
    lda #<(DIR_MAX*DIR_ENTRY_SIZE)
    sta REU_LEN_LO
    lda #>(DIR_MAX*DIR_ENTRY_SIZE)
    sta REU_LEN_HI
    jsr reu_reu_to_c64

    ; --- heap size ---
    sec
    lda fs_heap_lo
    sbc #<FS_HEAP_BASE
    sta REU_LEN_LO
    lda fs_heap_hi
    sbc #>FS_HEAP_BASE
    sta REU_LEN_HI
    bcs @heap_size_ok
    jmp loadreu_bad
@heap_size_ok:

    lda REU_LEN_LO
    ora REU_LEN_HI
    bne @load_heap
    jmp loadreu_ok
@load_heap:

    ; --- load heap ---
    lda #<FS_HEAP_BASE
    sta REU_C64_LO
    lda #>FS_HEAP_BASE
    sta REU_C64_HI
    lda #0
    sta REU_REU_LO
    lda #1
    sta REU_REU_MID
    lda #0
    sta REU_REU_HI
    jsr reu_reu_to_c64

loadreu_ok:
    lda #<loadreu_ok_txt
    sta ZPTR_LO
    lda #>loadreu_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

loadreu_bad:
    lda #<loadreu_bad_txt
    sta ZPTR_LO
    lda #>loadreu_bad_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

loadreu_no_reu:
    lda #<reu_notfound_txt
    sta ZPTR_LO
    lda #>reu_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ----------------------------
; cmd_savereu
; Saves metadata + directory + heap to REU
; Layout in REU:
;   $0000..$0003  metadata (4 bytes)
;   $0004..       DIR_TABLE (DIR_MAX*DIR_ENTRY_SIZE bytes)
;   $0100..       heap contents (fs_heap - FS_HEAP_BASE bytes)
; ----------------------------
cmd_savereu:
    jsr reu_detect
    bcs savereu_have_reu
    jmp savereu_no_reu

savereu_have_reu:

    ; ----------------------------
    ; Build metadata
    ; ----------------------------
    lda #$C6
    sta reu_metadata+0

    lda DIR_COUNT
    sta reu_metadata+1

    lda fs_heap_lo
    sta reu_metadata+2

    lda fs_heap_hi
    sta reu_metadata+3


    ; =========================================================
    ; 1) WRITE METADATA to REU $0000 (4 bytes)
    ; =========================================================
    lda #$1F
    sta REU_IMASK
    lda #$3F
    sta REU_ADDRCTL
    lda REU_STATUS          ; clear/ack status flags

    lda #<reu_metadata
    sta REU_C64_LO
    lda #>reu_metadata
    sta REU_C64_HI

    lda #$00
    sta REU_REU_LO
    sta REU_REU_MID
    sta REU_REU_HI

    lda #4
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI

    jsr reu_c64_to_reu


    ; ----------------------------
    ; VERIFY: read back metadata
    ; ----------------------------
    lda #$1F
    sta REU_IMASK
    lda #$3F
    sta REU_ADDRCTL
    lda REU_STATUS

    lda #<reu_metadata_chk
    sta REU_C64_LO
    lda #>reu_metadata_chk
    sta REU_C64_HI

    lda #$00
    sta REU_REU_LO
    sta REU_REU_MID
    sta REU_REU_HI

    lda #4
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI

    jsr reu_reu_to_c64

    ; If magic didn't come back, treat as failure (save didn't stick)
    lda reu_metadata_chk+0
    cmp #$C6
    beq @verify_ok
    jmp savereu_failed
@verify_ok:


    ; =========================================================
    ; 2) WRITE DIRECTORY TABLE to REU $0004
    ; =========================================================
    lda #$1F
    sta REU_IMASK
    lda #$3F
    sta REU_ADDRCTL
    lda REU_STATUS

    lda #<DIR_TABLE
    sta REU_C64_LO
    lda #>DIR_TABLE
    sta REU_C64_HI

    lda #$04
    sta REU_REU_LO
    lda #$00
    sta REU_REU_MID
    sta REU_REU_HI

    lda #<(DIR_MAX*DIR_ENTRY_SIZE)
    sta REU_LEN_LO
    lda #>(DIR_MAX*DIR_ENTRY_SIZE)
    sta REU_LEN_HI

    ; SAFETY: never allow LEN=$0000 (would mean 64K on real REU)
    lda REU_LEN_LO
    ora REU_LEN_HI
    beq savereu_dir_done

    jsr reu_c64_to_reu

savereu_dir_done:


    ; =========================================================
    ; 3) WRITE HEAP to REU $0100
    ; heap_len = fs_heap - FS_HEAP_BASE
    ; =========================================================
    sec
    lda fs_heap_lo
    sbc #<FS_HEAP_BASE
    sta REU_LEN_LO
    lda fs_heap_hi
    sbc #>FS_HEAP_BASE
    sta REU_LEN_HI

    ; If underflow, metadata/fs_heap is bad → fail safe
    bcs @heap_calc_ok
    jmp savereu_failed
@heap_calc_ok:

    ; If heap len == 0, nothing to write (still a successful save)
    lda REU_LEN_LO
    ora REU_LEN_HI
    bne @write_heap
    jmp savereu_ok
@write_heap:

    lda #$1F
    sta REU_IMASK
    lda #$3F
    sta REU_ADDRCTL
    lda REU_STATUS

    lda #<FS_HEAP_BASE
    sta REU_C64_LO
    lda #>FS_HEAP_BASE
    sta REU_C64_HI

    lda #$00
    sta REU_REU_LO
    lda #$01
    sta REU_REU_MID
    lda #$00
    sta REU_REU_HI

    jsr reu_c64_to_reu


    ; =========================================================
    ; SUCCESS MESSAGE
    ; =========================================================
savereu_ok:
    lda #<savereu_ok_txt
    sta ZPTR_LO
    lda #>savereu_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts


    ; =========================================================
    ; FAILURE MESSAGE
    ; =========================================================
savereu_failed:
    lda #<savereu_fail_txt
    sta ZPTR_LO
    lda #>savereu_fail_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts


    ; =========================================================
    ; NO REU MESSAGE
    ; =========================================================
savereu_no_reu:
    lda #<reu_notfound_txt
    sta ZPTR_LO
    lda #>reu_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ----------------------------
; cmd_wipereu
; Wipes REU by clearing metadata (invalidates REU image)
; ----------------------------
cmd_wipereu:
    jsr reu_detect
    bcs wipereu_have_reu
    jmp wipereu_no_reu
wipereu_have_reu:

    ; Clear metadata (4 bytes at $00000)
    lda #0
    sta reu_metadata+0
    sta reu_metadata+1
    sta reu_metadata+2
    sta reu_metadata+3

    lda #<reu_metadata
    sta REU_C64_LO
    lda #>reu_metadata
    sta REU_C64_HI
    lda #0
    sta REU_REU_LO
    sta REU_REU_MID
    sta REU_REU_HI
    lda #4
    sta REU_LEN_LO
    lda #0
    sta REU_LEN_HI
    jsr reu_c64_to_reu

    ; Print success message
    lda #<wipereu_ok_txt
    sta ZPTR_LO
    lda #>wipereu_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

wipereu_no_reu:
    lda #<reu_notfound_txt
    sta ZPTR_LO
    lda #>reu_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ----------------------------------------
; STAT <NAME>
; Prints: NAME / SIZE / ADDR
; ----------------------------------------
cmd_stat:
    lda #13
    jsr CHROUT

    ; move X past "STAT" (4 chars)
    txa
    clc
    adc #4
    tax

    ; skip spaces
st_skip1:
    lda LINEBUF,x
    bne st_chksp
    jmp st_usage
st_chksp:
    cmp #$20
    bne st_name_start
    inx
    bne st_skip1

st_name_start:
    ; NAMEBUF = 8 spaces
    ldy #0
st_fill:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne st_fill

    ; copy token into NAMEBUF (up to 8 chars)
    ldy #0
st_copy:
    lda LINEBUF,x
    beq st_search
    cmp #$20
    beq st_search
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne st_copy

    ; if token >8, skip remainder of token
st_skip_long:
    lda LINEBUF,x
    beq st_search
    cmp #$20
    beq st_search
    inx
    bne st_skip_long

st_search:
    lda DIR_COUNT
    bne st_has
    jmp st_notfound

st_has:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

st_entry:
    ; compare 8 bytes of name
    ldy #0
st_cmp:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    beq st_cmp_ok
    jmp st_next
st_cmp_ok:
    iny
    cpy #DIR_NAME_LEN
    bne st_cmp

    ; MATCH! read start (8/9) and len (10/11)
    ldy #DIR_OFF_START
    lda (DPTR_LO),y
    sta PTR_LO
    iny
    lda (DPTR_LO),y
    sta PTR_HI

    ldy #DIR_OFF_LEN
    lda (DPTR_LO),y
    sta tmp_len_lo
    iny
    lda (DPTR_LO),y
    sta tmp_len_hi

    ; ---- print NAME ----
    ldx #0
st_pn:
    lda stat_name_txt,x
    beq st_pn_done
    jsr CHROUT
    inx
    bne st_pn
st_pn_done:

    ; print NAMEBUF (until space)
    ldy #0
st_name_out:
    lda NAMEBUF,y
    cmp #' '
    beq st_name_end
    jsr CHROUT
    iny
    cpy #DIR_NAME_LEN
    bne st_name_out
st_name_end:
    lda #13
    jsr CHROUT

    ; ---- print SIZE ----
    ldx #0
st_ps:
    lda stat_size_txt,x
    beq st_ps_done
    jsr CHROUT
    inx
    bne st_ps
st_ps_done:
    lda tmp_len_hi
    ldx tmp_len_lo
    jsr print_u16_dec
    lda #13
    jsr CHROUT

    ; ---- print ADDR ----
    ldx #0
st_pa:
    lda stat_addr_txt,x
    beq st_pa_done
    jsr CHROUT
    inx
    bne st_pa
st_pa_done:
    lda PTR_HI
    ldx PTR_LO
    jsr print_hex16
    lda #13
    jsr CHROUT

    ; ---- print DATE ----
    ldx #0
st_pd:
    lda stat_date_txt,x
    beq st_pd_done
    jsr CHROUT
    inx
    bne st_pd
st_pd_done:
    ldy #DIR_OFF_DATE
    ldx #DIR_DATE_LEN
    jsr print_dptr_bytes
    lda #13
    jsr CHROUT

    ; ---- print TIME ----
    ldx #0
st_pt:
    lda stat_time_txt,x
    beq st_pt_done
    jsr CHROUT
    inx
    bne st_pt
st_pt_done:
    ldy #DIR_OFF_TIME
    ldx #DIR_TIME_LEN
    jsr print_dptr_bytes
    lda #13
    jsr CHROUT
    rts

st_next:
    ; advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc st_nc
    inc DPTR_HI
st_nc:
    dex
    beq st_notfound
    jmp st_entry

st_notfound:
    ldx #0
st_nf_loop:
    lda notfound_txt,x
    beq st_done
    jsr CHROUT
    inx
    bne st_nf_loop
st_done:
    lda #13
    jsr CHROUT
    rts

st_usage:
    ldx #0
st_us_loop:
    lda stat_usage_txt,x
    beq st_done
    jsr CHROUT
    inx
    bne st_us_loop

; ============================================================
; cmd_rm
; ------------------------------------------------------------
; RM <NAME>
;
; Deletes a file entry from the in-memory directory table.
;
; Behavior:
;   - Searches DIR_TABLE for an entry matching <NAME>
;   - If found:
;       * Removes the directory entry
;       * Compacts DIR_TABLE to close the gap
;       * Decrements DIR_COUNT
;   - If not found:
;       * Prints "FILE NOT FOUND"
;
; Notes:
;   - File data in the heap is NOT reclaimed (leak by design)
;   - Heap compaction is intentionally deferred for simplicity
;   - NAME is compared as an 8-byte, space-padded token
;   - Matching is case-insensitive via normalize_buf
;
; Input:
;   LINEBUF = command line (normalized)
;   X       = index of command start
;
; Output:
;   Prints status message and newline
;
; Clobbers:
;   A, X, Y, PTR_*, DPTR_*
; ============================================================
cmd_rm:
    lda #13
    jsr CHROUT

    ; move X past "RM" (2 chars)
    txa
    clc
    adc #2
    tax

    ; skip spaces
rm_skip1:
    lda LINEBUF,x
    bne rm_chksp
    jmp rm_usage
rm_chksp:
    cmp #$20
    bne rm_name_start
    inx
    bne rm_skip1

rm_name_start:
    ; NAMEBUF = 8 spaces
    ldy #0
rm_fill:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne rm_fill

    ; copy token into NAMEBUF (up to 8 chars)
    ; also check for wildcard '*'
    ldy #0
    sty rm_wildcard_len     ; will store prefix length if wildcard found
rm_copy:
    lda LINEBUF,x
    beq rm_check_wildcard
    cmp #$20
    beq rm_check_wildcard
    cmp #'*'                ; wildcard?
    beq rm_found_wildcard
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne rm_copy
    jmp rm_skip_long

rm_found_wildcard:
    ; Y holds the prefix length
    sty rm_wildcard_len
    ; pad rest of NAMEBUF with spaces
    cpy #DIR_NAME_LEN
    beq rm_check_wildcard
rm_pad_wildcard:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne rm_pad_wildcard
    jmp rm_check_wildcard

    ; if token >8, skip remainder of token
rm_skip_long:
    lda LINEBUF,x
    beq rm_check_wildcard
    cmp #$20
    beq rm_check_wildcard
    cmp #'*'
    beq rm_found_wildcard
    inx
    bne rm_skip_long

rm_check_wildcard:
    lda rm_wildcard_len
    beq rm_search           ; no wildcard, do normal search
    jmp rm_wildcard_delete  ; wildcard mode

rm_search:
    lda DIR_COUNT
    bne rm_has
    jmp rm_notfound

rm_has:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT           ; remaining entries (includes current)

rm_entry:
    ; compare 8 name bytes
    ldy #0
rm_cmp:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    beq rm_cmp_ok
    jmp rm_next
rm_cmp_ok:
    iny
    cpy #DIR_NAME_LEN
    bne rm_cmp

    ; MATCH FOUND at DPTR
    ; entries_after = X-1
    dex                     ; X = entries_after
    stx rm_after_count

    ; if no entries after, just shrink and clear last slot
    lda rm_after_count
    beq rm_shrink_only

    ; move_count = entries_after * DIR_ENTRY_SIZE (12)
    lda #0
    sta rm_move_lo
    sta rm_move_hi
    lda rm_after_count
    sta rm_tmp

rm_mul_entrysize:
    ; rm_move += DIR_ENTRY_SIZE
    clc
    lda rm_move_lo
    adc #DIR_ENTRY_SIZE
    sta rm_move_lo
    bcc rm_mul_entrysize_nc
    inc rm_move_hi
rm_mul_entrysize_nc:
    dec rm_tmp
    bne rm_mul_entrysize

    ; DST is already DPTR (match entry)
    ; SRC = DPTR + 12 -> put in PTR
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta PTR_LO
    lda DPTR_HI
    adc #0
    sta PTR_HI

    ; copy move_count bytes from SRC(PTR) -> DST(DPTR)
rm_copy_loop:
    ldy #0
    lda (PTR_LO),y
    sta (DPTR_LO),y

    ; SRC++
    inc PTR_LO
    bne rm_src_ok
    inc PTR_HI
rm_src_ok:

    ; DST++
    inc DPTR_LO
    bne rm_dst_ok
    inc DPTR_HI
rm_dst_ok:

    ; move_count--
    lda rm_move_lo
    bne rm_dec_lo
    dec rm_move_hi
rm_dec_lo:
    dec rm_move_lo

    lda rm_move_lo
    ora rm_move_hi
    bne rm_copy_loop

rm_shrink_only:
    ; DIR_COUNT--
    dec DIR_COUNT

    ; clear the free slot at index DIR_COUNT (first free)
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldy DIR_COUNT
rm_adv_free:
    cpy #0
    beq rm_clear_slot
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc rm_adv_free_nc
    inc DPTR_HI
rm_adv_free_nc:
    dey
    jmp rm_adv_free

rm_clear_slot:
    ldy #0
rm_clr_entry:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne rm_clr_entry

    ; print OK
    ldx #0
rm_ok:
    lda ok_txt,x
    beq rm_done
    jsr CHROUT
    inx
    bne rm_ok

rm_done:
    lda #13
    jsr CHROUT
    rts

rm_next:
    ; advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc rm_nc
    inc DPTR_HI
rm_nc:
    dex
    beq rm_no_more
    jmp rm_entry

rm_no_more:
    jmp rm_notfound

; Wildcard delete - delete all files matching prefix in NAMEBUF
rm_wildcard_delete:
    lda #0
    sta rm_deleted_count

rm_wild_restart:
    ; Check if any files left
    lda DIR_COUNT
    bne @has_files
    jmp rm_wild_done
@has_files:

    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

rm_wild_entry:
    ; Compare prefix (rm_wildcard_len bytes)
    ldy #0
rm_wild_cmp:
    cpy rm_wildcard_len
    beq rm_wild_match       ; matched all prefix chars
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    beq @cmp_ok
    jmp rm_wild_next
@cmp_ok:
    iny
    jmp rm_wild_cmp

rm_wild_match:
    ; Found a match! Delete this entry
    ; entries_after = X-1
    dex
    stx rm_after_count

    ; if no entries after, just shrink
    lda rm_after_count
    beq rm_wild_shrink_only

    ; Calculate move_count
    lda #0
    sta rm_move_lo
    sta rm_move_hi
    lda rm_after_count
    sta rm_tmp

rm_wild_mul:
    clc
    lda rm_move_lo
    adc #DIR_ENTRY_SIZE
    sta rm_move_lo
    bcc rm_wild_mul_nc
    inc rm_move_hi
rm_wild_mul_nc:
    dec rm_tmp
    bne rm_wild_mul

    ; SRC = DPTR + DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta PTR_LO
    lda DPTR_HI
    adc #0
    sta PTR_HI

    ; Copy move_count bytes
rm_wild_copy:
    ldy #0
    lda (PTR_LO),y
    sta (DPTR_LO),y
    inc PTR_LO
    bne rm_wild_src_ok
    inc PTR_HI
rm_wild_src_ok:
    inc DPTR_LO
    bne rm_wild_dst_ok
    inc DPTR_HI
rm_wild_dst_ok:
    lda rm_move_lo
    bne rm_wild_dec_lo
    dec rm_move_hi
rm_wild_dec_lo:
    dec rm_move_lo
    lda rm_move_lo
    ora rm_move_hi
    bne rm_wild_copy

rm_wild_shrink_only:
    ; DIR_COUNT--
    dec DIR_COUNT

    ; Clear last slot
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI
    ldy DIR_COUNT
rm_wild_adv:
    cpy #0
    beq rm_wild_clear
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc rm_wild_adv_nc
    inc DPTR_HI
rm_wild_adv_nc:
    dey
    jmp rm_wild_adv

rm_wild_clear:
    ldy #0
rm_wild_clr:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne rm_wild_clr

    ; Increment deleted count
    inc rm_deleted_count

    ; Restart search from beginning
    jmp rm_wild_restart

rm_wild_next:
    ; Advance to next entry
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc rm_wild_nc
    inc DPTR_HI
rm_wild_nc:
    dex
    beq rm_wild_done
    jmp rm_wild_entry

rm_wild_done:
    ; Print result
    lda rm_deleted_count
    beq rm_wild_none
    ; Print "X FILES DELETED"
    lda rm_deleted_count
    jsr print_hex
    lda #' '
    jsr CHROUT
    ldx #0
rm_wild_msg:
    lda rm_wild_ok_txt,x
    beq rm_wild_exit
    jsr CHROUT
    inx
    bne rm_wild_msg
rm_wild_exit:
    lda #13
    jsr CHROUT
    rts

rm_wild_none:
    jmp rm_notfound

rm_notfound:
    ldx #0
rm_nf:
    lda notfound_txt,x
    bne @cont1
    jmp rm_done
@cont1:
    jsr CHROUT
    inx
    bne rm_nf

rm_usage:
    ldx #0
rm_us:
    lda rm_usage_txt,x
    bne @cont2
    jmp rm_done
@cont2:
    jsr CHROUT
    inx
    bne rm_us

; --- RM scratch/state ---
rm_after_count:   !byte 0
rm_tmp:           !byte 0
rm_move_lo:       !byte 0
rm_move_hi:       !byte 0
rm_wildcard_len:  !byte 0
rm_deleted_count: !byte 0

; ============================================================
; cmd_echo
; ------------------------------------------------------------
; ECHO <TEXT...>
;
; Prints the remainder of the command line exactly as entered
; (after the ECHO keyword).
;
; Behavior:
;   - Skips the "ECHO" keyword
;   - Skips any following spaces
;   - Prints all remaining characters until end-of-line
;   - Always prints a leading and trailing newline
;
; Notes:
;   - Does NOT interpret escape sequences
;   - Output is printed verbatim from LINEBUF
;   - Case has already been normalized by normalize_buf
;
; Input:
;   LINEBUF = command line (null-terminated)
;   X       = index of command start
;
; Output:
;   Prints text to screen via CHROUT
;
; Clobbers:
;   A, X
; ============================================================
cmd_echo:
    ; Print newline first (Unix-like)
    lda #13
    jsr CHROUT

    ; Print everything after "ECHO"
    ; X at entry is start of command
    txa
    pha

    ; move X to first char after ECHO (X += 4)
    txa
    clc
    adc #4
    tax

    ; skip spaces
@skip:
    lda LINEBUF,x
    beq @done_line
    cmp #$20
    bne @loop
    inx
    bne @skip

@loop:
    lda LINEBUF,x
    beq @done_line
    jsr CHROUT
    inx
    bne @loop

@done_line:
    lda #13
    jsr CHROUT

    pla
    tax
    rts

; ------------------------------------------------------------
; cmd_cat
; ------------------------------------------------------------
; CAT <NAME>
;
; Prints the contents of a file stored in the RAM filesystem.
;
; Operation:
;   - Parses the filename token following the CAT command
;   - Searches DIR_TABLE for a matching 8-character filename
;   - If found:
;       - Reads file start address and length from directory entry
;       - Outputs file contents byte-by-byte to CHROUT
;   - If file length is zero, prints a blank line
;
; Errors:
;   - Prints "FILE NOT FOUND" if no directory entry matches NAME
;   - Prints usage text if NAME is missing
;
; Notes:
;   - File data is treated as raw bytes (no text conversion)
;   - Does not modify filesystem state
;
; Clobbers:
;   A, X, Y, PTR_LO/PTR_HI, DPTR_LO/DPTR_HI, tmp_len_lo/tmp_len_hi
; ------------------------------------------------------------
cmd_cat:
    lda #13
    jsr CHROUT

    ; move X past "CAT" (3 chars)
    txa
    clc
    adc #3
    tax

    ; skip spaces
cc_skip1:
    lda LINEBUF,x
    bne cc_chksp
    jmp cc_usage
cc_chksp:
    cmp #$20
    bne cc_name_start
    inx
    bne cc_skip1

cc_name_start:
    ; build NAMEBUF (8 chars padded with spaces)
    ldy #0
cc_fill:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne cc_fill

    ldy #0
cc_copy:
    lda LINEBUF,x
    beq cc_search
    cmp #$20
    beq cc_search
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cc_copy

    ; if token >8, skip remainder
cc_skip_long:
    lda LINEBUF,x
    beq cc_search
    cmp #$20
    beq cc_search
    inx
    bne cc_skip_long

cc_search:
    lda DIR_COUNT
    bne cc_has
    jmp cc_notfound

cc_has:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

cc_entry:
    ; compare 8 bytes of name
    ldy #0
cc_cmp_loop:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    bne cc_next_entry
    iny
    cpy #DIR_NAME_LEN
    bne cc_cmp_loop

    ; MATCH! read start (8/9) and len (10/11)
    ldy #DIR_OFF_START
    lda (DPTR_LO),y
    sta PTR_LO
    iny
    lda (DPTR_LO),y
    sta PTR_HI

    ldy #DIR_OFF_LEN
    lda (DPTR_LO),y
    sta tmp_len_lo
    iny
    lda (DPTR_LO),y
    sta tmp_len_hi

    ; if len == 0, just newline
    lda tmp_len_lo
    ora tmp_len_hi
    beq cc_done

cc_print:
    ; print one byte
    ldy #0
    lda (PTR_LO),y
    jsr CHROUT

    ; PTR++
    inc PTR_LO
    bne cc_ptr_ok
    inc PTR_HI
cc_ptr_ok:

    ; len--
    lda tmp_len_lo
    bne cc_dec_lo
    dec tmp_len_hi
cc_dec_lo:
    dec tmp_len_lo

    ; continue until len==0
    lda tmp_len_lo
    ora tmp_len_hi
    bne cc_print

cc_done:
    lda #13
    jsr CHROUT
    rts

cc_next_entry:
    ; advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cc_nc
    inc DPTR_HI
cc_nc:
    dex
    bne cc_entry
    jmp cc_notfound

cc_notfound:
    ldx #0
cc_nf_loop:
    lda notfound_txt,x
    beq cc_done
    jsr CHROUT
    inx
    bne cc_nf_loop

cc_usage:
    ldx #0
cc_us_loop:
    lda cat_usage_txt,x
    beq cc_done
    jsr CHROUT
    inx
    bne cc_us_loop

; ------------------------------------------------------------
; cmd_mem
; ------------------------------------------------------------
; MEM
;
; Displays the amount of free BASIC memory currently available.
;
; Operation:
;   - Reads BASIC system pointers:
;       - MEMSIZ  ($37/$38) – top of BASIC memory
;       - VARTAB  ($2D/$2E) – start of BASIC variables
;   - Calculates:
;       FREE = MEMSIZ - VARTAB
;   - Prints the result as a decimal value
;
; Output format:
;   FREE <bytes>
;
; Notes:
;   - This reflects BASIC-managed RAM, not total free system RAM
;   - Does not account for RAM used by C64uX heap or zero-page
;   - Useful for sanity checks and diagnostics
;
; Clobbers:
;   A, X, Y, free_lo/free_hi
; ------------------------------------------------------------
cmd_mem:
    lda #13
    jsr CHROUT
    jsr print_free_mem_line
    rts
@t1:
    lda mem_free_txt,x
    beq @calc
    jsr CHROUT
    inx
    bne @t1

@calc:
    ; FREE = MEMSIZ ($37/$38) - VARTAB ($2D/$2E)
    sec
    lda $37
    sbc $2D
    sta free_lo
    lda $38
    sbc $2E
    sta free_hi

    ; Print 16-bit number in decimal
    lda free_hi
    ldx free_lo
    jsr print_u16_dec

    lda #13
    jsr CHROUT
    rts

free_lo: !byte 0
free_hi: !byte 0

; ------------------------------------------------------------
; cmd_ls
; ------------------------------------------------------------
; LS
;
; Lists files in the in-memory RAM filesystem directory table.
;
; Output format:
;   <NAME>  <SIZE>
;
; Behavior:
;   - If DIR_COUNT == 0, prints "0" and returns
;   - Otherwise iterates through DIR_TABLE entries
;   - Prints each filename (up to 8 chars, trimmed at spaces)
;   - Prints file size in bytes (decimal)
;   - One entry per line
;
; Notes:
;   - Does not sort entries (insertion order)
;   - Does not display file addresses or metadata
;   - Heap contents are not inspected
; ------------------------------------------------------------
cmd_ls:
    lda #13
    jsr CHROUT

    lda DIR_COUNT
    bne ls_has_files

    ; no files --> print "0"
    lda #'0'
    jsr CHROUT
    lda #13
    jsr CHROUT
    rts

ls_has_files:
    ; ptr = DIR_TABLE
    lda #<DIR_TABLE
    sta PTR_LO
    lda #>DIR_TABLE
    sta PTR_HI

    ldx DIR_COUNT        ; files remaining

ls_entry:
    ; print name (up to 8 chars, stop at space or 0)
    ldy #0
ls_name_loop:
    lda (PTR_LO),y
    beq ls_name_done
    cmp #' '
    beq ls_name_done
    jsr CHROUT
    iny
    cpy #DIR_NAME_LEN
    bne ls_name_loop
ls_name_done:
    ; two spaces
    lda #' '
    jsr CHROUT
    lda #' '
    jsr CHROUT

    ; read len (offset 10/11) and print decimal
    ldy #DIR_OFF_LEN
    lda (PTR_LO),y       ; len lo
    sta tmp_len_lo
    iny
    lda (PTR_LO),y       ; len hi
    sta tmp_len_hi

    txa
    pha                  ; save file-count X  <<< MOVE HERE

    lda tmp_len_hi
    ldx tmp_len_lo
    jsr print_u16_dec

    ; two spaces
    lda #' '
    jsr CHROUT
    lda #' '
    jsr CHROUT

    ; print DATE (10 bytes) from entry
    ldy #DIR_OFF_DATE
    ldx #DIR_DATE_LEN
    jsr print_entry_bytes

    lda #' '
    jsr CHROUT

    ; print TIME (8 bytes) from entry
    ldy #DIR_OFF_TIME
    ldx #DIR_TIME_LEN
    jsr print_entry_bytes

    pla
    tax                  ; restore file-count X  <<< restore at end

    lda #13
    jsr CHROUT

    ; advance ptr += DIR_ENTRY_SIZE (30)
    clc
    lda PTR_LO
    adc #DIR_ENTRY_SIZE
    sta PTR_LO
    bcc ls_no_carry
    inc PTR_HI
ls_no_carry:

    dex
    bne ls_entry
    rts

; ------------------------------------------------------------
; cmd_uname
; ------------------------------------------------------------
; UNAME
;
; Prints basic system identification information.
;
; Output:
;   - OS / shell name
;   - Version
;   - CPU / platform
;
; Notes:
;   - Static, compile-time string (no runtime detection)
;   - Modeled after Unix `uname`
;   - Intended for identification and debugging
; ------------------------------------------------------------
cmd_uname:
    lda #13
    jsr CHROUT
    ldx #0
@u:
    lda uname_txt,x
    beq @done
    jsr CHROUT
    inx
    bne @u
@done:
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_version
; ------------------------------------------------------------
; VERSION (alias: VER)
; Reuses UNAME output so there is only one "version string".
; ------------------------------------------------------------
cmd_version:
    jmp cmd_uname

; ------------------------------------------------------------
; cmd_whoami
; Prints the configured USERNAME from setup
; ------------------------------------------------------------
cmd_whoami:
    lda #13
    jsr CHROUT

    ; print "USER "
    ldx #0
@p:
    lda whoami_txt,x
    beq @name
    jsr CHROUT
    inx
    bne @p

@name:
    ldx #0
@loop:
    lda USERNAME,x
    beq @done
    jsr CHROUT
    inx
    bne @loop

@done:
    lda #13
    jsr CHROUT
    rts

; ----------------------------------------
; WRITE <NAME> <TEXT...>
; - NAME: up to 8 chars (token after WRITE)
; - TEXT: remainder of line after filename + spaces
; creates a new directory entry and stores TEXT in heap
; ----------------------------------------
cmd_write:
    lda #13
    jsr CHROUT

    ; Move X past "WRITE" (5 chars)
    txa
    clc
    adc #5
    tax

    ; skip spaces before name

cw_skip1:
    lda LINEBUF,x
    bne cw_chksp
    jmp cw_usage        ; was: beq cw_usage (too far)

cw_chksp:
    cmp #$20
    bne cw_name_start
    inx
    bne cw_skip1

cw_name_start:
    ; First, parse the filename into NAMEBUF (8 chars, space-padded)
    ldy #0
cw_fill_namebuf:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne cw_fill_namebuf

    ; Copy token into NAMEBUF (up to 8 chars)
    ldy #0
cw_copy_name:
    lda LINEBUF,x
    beq cw_save_x
    cmp #$20
    beq cw_save_x
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cw_copy_name

    ; if name >8 chars, skip rest of token
cw_skip_name_tail:
    lda LINEBUF,x
    beq cw_save_x
    cmp #$20
    beq cw_save_x
    inx
    bne cw_skip_name_tail

cw_save_x:
    ; Save X position AFTER advancing past filename
    stx cw_tmp_x

    ; Check for wildcard in filename
    ldy #0
cw_check_wildcard:
    lda NAMEBUF,y
    cmp #'*'
    bne @not_wildcard
    jmp cw_invalid_name
@not_wildcard:
    iny
    cpy #DIR_NAME_LEN
    bne cw_check_wildcard

cw_check_exists:
    ; Now check if this filename already exists
    lda DIR_COUNT
    beq cw_no_duplicate  ; no files, can't be duplicate

    ; Search existing files
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI
    ldx DIR_COUNT

cw_search_loop:
    ; Compare 8 bytes of name
    ldy #0
cw_search_cmp:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    bne cw_search_next
    iny
    cpy #DIR_NAME_LEN
    bne cw_search_cmp

    ; MATCH! File already exists - reject
    jmp cw_exists

cw_search_next:
    ; Advance to next entry
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cw_search_nc
    inc DPTR_HI
cw_search_nc:
    dex
    bne cw_search_loop

cw_no_duplicate:
    ; File doesn't exist, proceed with creation
    ; Restore X to continue parsing
    ldx cw_tmp_x

    ; if no room in directory
    lda DIR_COUNT
    cmp #DIR_MAX
    bcc cw_room
    jmp cw_full         ; was: bcs cw_full (too far)

cw_room:

    ; DPTR = DIR_TABLE + (DIR_COUNT * DIR_ENTRY_SIZE)
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI
    ldy DIR_COUNT

cw_adv:
    cpy #0
    beq cw_entry_ready
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cw_adv_nc
    inc DPTR_HI

cw_adv_nc:
    dey
    jmp cw_adv

cw_entry_ready:
    ; clear entire entry (DIR_ENTRY_SIZE bytes) to avoid stale metadata
    ldy #0
cw_clr_entry:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne cw_clr_entry

    ; write NAMEBUF into entry (already parsed)
    ldy #0
cw_write_name:
    lda NAMEBUF,y
    sta (DPTR_LO),y
    iny
    cpy #DIR_NAME_LEN
    bne cw_write_name

    ; Now skip to the text part of the command
    ; X still points past the filename
cw_skip_to_text:
    lda LINEBUF,x
    beq cw_after_name
    cmp #$20
    bne cw_after_name
    inx
    bne cw_skip_to_text

cw_after_name:

; skip spaces before text
cw_skip2:
    lda LINEBUF,x
    beq cw_set_empty
    cmp #$20
    bne cw_text_start
    inx
    bne cw_skip2

cw_text_start:
    ; store start = fs_heap into entry offsets 8/9
    ldy #DIR_OFF_START
    lda fs_heap_lo
    sta (DPTR_LO),y
    iny
    lda fs_heap_hi
    sta (DPTR_LO),y

    ; PTR = fs_heap (heap write pointer)
    lda fs_heap_lo
    sta PTR_LO
    lda fs_heap_hi
    sta PTR_HI

    ; len = 0
    lda #0
    sta tmp_len_lo
    sta tmp_len_hi

cw_copy:
    lda LINEBUF,x
    beq cw_done_copy

    ldy #0
    sta (PTR_LO),y

    ; PTR++
    inc PTR_LO
    bne cw_ptr_ok
    inc PTR_HI
cw_ptr_ok:

    ; len++
    inc tmp_len_lo
    bne cw_len_ok
    inc tmp_len_hi
cw_len_ok:

    inx
    bne cw_copy

cw_done_copy:
    ; store len into entry offsets 10/11
    ldy #DIR_OFF_LEN
    lda tmp_len_lo
    sta (DPTR_LO),y
    iny
    lda tmp_len_hi
    sta (DPTR_LO),y

    jsr fs_stamp_entry_datetime

    ; commit heap pointer = PTR
    lda PTR_LO
    sta fs_heap_lo
    lda PTR_HI
    sta fs_heap_hi

    ; DIR_COUNT++
    inc DIR_COUNT

    ; print OK
    ldx #0

cw_ok_loop:
    lda ok_txt,x
    beq cw_ok_end
    jsr CHROUT
    inx
    bne cw_ok_loop
    jmp cw_done        ; safety (shouldn't hit)

cw_ok_end:
    jmp cw_done

cw_done:
    lda #13
    jsr CHROUT
    rts

cw_set_empty:
    ; store start = fs_heap
    ldy #DIR_OFF_START
    lda fs_heap_lo
    sta (DPTR_LO),y
    iny
    lda fs_heap_hi
    sta (DPTR_LO),y

    ; store len = 0
    ldy #DIR_OFF_LEN
    lda #0
    sta (DPTR_LO),y
    iny
    sta (DPTR_LO),y

    ; stamp date/time into entry
    jsr fs_stamp_entry_datetime

    inc DIR_COUNT
    ldx #0
    jmp cw_ok_loop

cw_full:
    ldx #0

cw_full_loop:
    lda full_txt,x
    beq cw_full_end
    jsr CHROUT
    inx
    bne cw_full_loop

cw_full_end:
    jmp cw_done

cw_exists:
    ldx #0
cw_exists_loop:
    lda file_exists_txt,x
    beq cw_exists_end
    jsr CHROUT
    inx
    bne cw_exists_loop
cw_exists_end:
    jmp cw_done

cw_invalid_name:
    ldx #0
cw_invalid_loop:
    lda invalid_filename_txt,x
    beq cw_invalid_end
    jsr CHROUT
    inx
    bne cw_invalid_loop
cw_invalid_end:
    jmp cw_done

cw_usage:
    ldx #0

cw_usage_loop:
    lda usage_txt,x
    beq cw_usage_end
    jsr CHROUT
    inx
    bne cw_usage_loop

cw_usage_end:
    jmp cw_done

; ------------------------------------------------------------
; cmd_help
; ------------------------------------------------------------
; HELP
;
; Prints the built-in command reference.
;
; Behavior:
;   - Outputs a newline
;   - Prints the contents of help_txt
;   - Does not modify system state
;
; Notes:
;   - Uses print_z (ZPTR) so help_txt can be >255 bytes
;   - help_txt should remain UPPERCASE (PETSCII-safe)
; ------------------------------------------------------------
cmd_help:
    lda #13
    jsr CHROUT

    ; Print first part of help
    lda #<help_txt_part1
    sta ZPTR_LO
    lda #>help_txt_part1
    sta ZPTR_HI
    jsr print_z

    ; Print "press space" message
    lda #<help_more_txt
    sta ZPTR_LO
    lda #>help_more_txt
    sta ZPTR_HI
    jsr print_z

    ; Wait for any key
@wait:
    jsr CHRIN
    cmp #0
    beq @wait

    ; Print second part of help
    lda #<help_txt_part2
    sta ZPTR_LO
    lda #>help_txt_part2
    sta ZPTR_HI
    jsr print_z

    rts

; ------------------------------------------------------------
; cmd_date
; DATE
; - Prints the current session date string (YYYY-MM-DD)
; - If TIME has rolled over past midnight since last check,
;   DATE_STR is incremented first.
; ------------------------------------------------------------
cmd_date:
    lda #13
    jsr CHROUT

    jsr update_day_rollover

    lda #<DATE_STR
    sta ZPTR_LO
    lda #>DATE_STR
    sta ZPTR_HI
    jsr print_z

    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_time
; TIME
; Prints current time from KERNAL jiffy clock (auto-advancing)
; Also updates DATE_STR if midnight passed since last check.
; ------------------------------------------------------------
cmd_time:
    lda #13
    jsr CHROUT

    jsr update_day_rollover

    jsr read_clock_to_jiffies
    jsr jiffies_to_seconds16
    jsr seconds16_to_hms

    lda h_out
    jsr print_2d
    lda #':'
    jsr CHROUT
    lda m_out
    jsr print_2d
    lda #':'
    jsr CHROUT
    lda s_out
    jsr print_2d

    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_uptime
; UPTIME
; Prints time since boot: [<DAYS> DAYS ]HH:MM:SS
; ------------------------------------------------------------
cmd_uptime:
    lda #13
    jsr CHROUT

    ; Update rollover tracking (also increments DATE + UP_DAYS)
    jsr update_day_rollover

    ; Get current seconds since midnight -> sec_lo/sec_hi
    jsr read_clock_to_jiffies
    jsr jiffies_to_seconds16

    ; delta = current_sec - boot_sec  (16-bit)
    sec
    lda sec_lo
    sbc BOOT_SEC_LO
    sta work_lo
    lda sec_hi
    sbc BOOT_SEC_HI
    sta work_hi

    ; If borrow happened, then we crossed midnight relative to boot baseline.
    ; In that case: delta += 86400 and days-- (because UP_DAYS counted midnight rollovers,
    ; but boot baseline is not midnight).
    bcs @delta_ok

    ; delta += 86400 (0x15180) => add $80 to lo, $51 to hi, plus carry
    clc
    lda work_lo
    adc #$80
    sta work_lo
    lda work_hi
    adc #$51
    sta work_hi

    ; days--
    lda UP_DAYS_LO
    bne @dec_lo
    dec UP_DAYS_HI
@dec_lo:
    dec UP_DAYS_LO

@delta_ok:
    ; If days != 0, print "<days> DAYS "
    lda UP_DAYS_LO
    ora UP_DAYS_HI
    beq @print_hms

    lda UP_DAYS_HI
    ldx UP_DAYS_LO
    jsr print_u16_dec

    lda #' '
    jsr CHROUT
    lda #'D'
    jsr CHROUT
    lda #'A'
    jsr CHROUT
    lda #'Y'
    jsr CHROUT
    lda #'S'
    jsr CHROUT
    lda #' '
    jsr CHROUT

@print_hms:
    ; Convert delta seconds (work_lo/work_hi) to HMS
    lda work_lo
    sta sec_lo
    lda work_hi
    sta sec_hi
    jsr seconds16_to_hms

    lda h_out
    jsr print_2d
    lda #':'
    jsr CHROUT
    lda m_out
    jsr print_2d
    lda #':'
    jsr CHROUT
    lda s_out
    jsr print_2d

    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_pwd
; ------------------------------------------------------------
; PWD
; Prints a Unix-like "current directory" path:
;   /home/<username>
;
; Notes:
;   - Uses USERNAME (0-terminated)
;   - No real directory support yet; this is a friendly convention
; Clobbers: A, X
; ------------------------------------------------------------
cmd_pwd:
    lda #13
    jsr CHROUT

    ldx #0
@p:
    lda pwd_prefix_txt,x
    beq @after_prefix
    jsr CHROUT
    inx
    bne @p

@after_prefix:
    lda #<USERNAME
    sta ZPTR_LO
    lda #>USERNAME
    sta ZPTR_HI
    jsr print_z

    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_exit
; ------------------------------------------------------------
; EXIT
;
; Exits C64uX and returns control to BASIC.
;
; Behavior:
;   - Prints a newline
;   - Performs a BASIC warm start
;
; Notes:
;   - Jumps directly to BASIC ROM entry point ($A474)
;   - Does not return
; ------------------------------------------------------------
cmd_exit:
    ; Return to BASIC READY prompt (warm start)
    lda #13
    jsr CHROUT
    jmp $A474         ; BASIC warm start

; ------------------------------------------------------------
; DOS <cmd...>
; Sends <cmd...> to device 8 command channel (15)
; Then prints the DOS status line returned by the drive.
;
; Special shortcut:
;   DOS @$      -> directory listing (calls cmd_dir)
;
; Examples:
;   DOS I0
;   DOS S:FILE
;   DOS R:NEW=OLD
;   DOS @$
; ------------------------------------------------------------
cmd_dos:
    lda #13
    jsr CHROUT

    ; advance X past "DOS"
    txa
    clc
    adc #3
    tax

@skip:
    lda LINEBUF,x
    beq @usage_jmp
    cmp #$20
    bne @cmd_start
    inx
    bne @skip

@usage_jmp:
    jmp @usage

@cmd_start:
    ; --------------------------------------------------------
    ; DOS @$ shortcut (directory)
    ; Accept "@$" followed by EOL or space
    ; --------------------------------------------------------
    lda LINEBUF,x
    cmp #'@'
    bne @normal_dos
    lda LINEBUF+1,x
    cmp #'$'
    bne @normal_dos
    lda LINEBUF+2,x
    beq @do_dir
    cmp #$20
    beq @do_dir
    ; "@$something" -> treat as normal DOS cmd
    jmp @normal_dos

@do_dir:
    jsr cmd_dir
    jsr CLRCHN
    rts

@normal_dos:
    stx dos_idx

    ; ZPTR = LINEBUF + dos_idx
    lda #<LINEBUF
    clc
    adc dos_idx
    sta ZPTR_LO
    lda #>LINEBUF
    adc #0
    sta ZPTR_HI

    ; compute length into Y (scan until 0)
    ldx dos_idx
    ldy #0
@len:
    lda LINEBUF,x
    beq @have_len
    inx
    iny
    bne @len

@have_len:
    tya
    beq @usage
    sta dos_len

    ; SETNAM(len=A, ptr in X/Y)
    lda dos_len
    ldx ZPTR_LO
    ldy ZPTR_HI
    jsr SETNAM

    ; SETLFS(LA=15, DEV=default, SA=15)
    lda #15
    ldx default_drive
    ldy #15
    jsr SETLFS

    ; Send command to drive (OPEN command channel)
    jsr OPEN
    jsr READST
    bne @open_fail

    ; Close command channel and restore I/O
    lda #15
    jsr CLOSE
    jsr CLRCHN

    ; Print prefix then read/print status line
    lda #<dos_status_txt
    sta ZPTR_LO
    lda #>dos_status_txt
    sta ZPTR_HI
    jsr print_z

    jsr print_drive_status
    rts

@open_fail:
    jsr CLRCHN
    lda #<dos_openfail_txt
    sta ZPTR_LO
    lda #>dos_openfail_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

@usage:
    lda #<dos_usage_txt
    sta ZPTR_LO
    lda #>dos_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

dos_idx: !byte 0
dos_len: !byte 0

; ------------------------------------------------------------
; cmd_dir
; DIR (via DOS @$)
; Opens "$" on device 8 and prints directory entries.
; Safe: breaks on link=0 OR EOI.
; ------------------------------------------------------------
cmd_dir:
    lda #13
    jsr CHROUT

    jsr CLRCHN            ; IMPORTANT: reset any prior CHKIN/CHKOUT

    ; SETNAM "$" (length=1)
    lda #1
    ldx #<dir_name_txt
    ldy #>dir_name_txt
    jsr SETNAM

    ; SETLFS(LA=2, DEV=default, SA=0)  SA=0 = directory stream
    lda #2
    ldx default_drive
    ldy #0
    jsr SETLFS

    jsr OPEN
    jsr READST
    bne dir_open_fail

    ; CHKIN expects logical file # in X
    ldx #2
    jsr CHKIN
    jsr READST
    bne dir_chkin_fail

    ; Directory is a BASIC-style PRG stream
    ; First two bytes = load address -> discard
    jsr CHRIN
    jsr CHRIN

dir_nextline:
    ; If drive says EOI, we're done
    jsr READST
    and #$40              ; EOI
    bne dir_done

    ; Read link pointer (2 bytes). If 0,0 then done.
    jsr CHRIN
    sta work_lo
    jsr CHRIN
    sta work_hi
    lda work_lo
    ora work_hi
    beq dir_done

    ; Read "line number" (2 bytes) which is actually blocks
    jsr CHRIN
    sta blk_lo
    jsr CHRIN
    sta blk_hi

    ; Print blocks as decimal + space
    lda blk_hi
    ldx blk_lo
    jsr print_u16_dec
    lda #' '
    jsr CHROUT

dir_text:
    ; If EOI mid-line, stop cleanly
    jsr READST
    and #$40
    bne dir_done

    jsr CHRIN
    beq dir_eol            ; $00 ends the line text

    ; Convert $A0 (shift-space padding) to normal space
    cmp #$A0
    bne dir_print
    lda #$20
dir_print:
    jsr CHROUT
    jmp dir_text

dir_eol:
    lda #13
    jsr CHROUT
    jmp dir_nextline

dir_done:
    lda #13
    jsr CHROUT
    jmp dir_cleanup

dir_open_fail:
    lda #<dos_openfail_txt
    sta ZPTR_LO
    lda #>dos_openfail_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp dir_cleanup

dir_chkin_fail:
    lda #<dos_nochan_txt
    sta ZPTR_LO
    lda #>dos_nochan_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp dir_cleanup

dir_cleanup:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    rts

; temps (use existing scratch vars if you already have them)
blk_lo:  !byte 0
blk_hi:  !byte 0

; ------------------------------------------------------------
; cmd_nano
; NANO <name>
; Multi-line text entry. Ends when user types a single '.' line.
;
; Creates a RAM file in the existing FS heap.
; Stores CR ($0D) between lines.
; ------------------------------------------------------------
cmd_nano:
    lda #13
    jsr CHROUT

    ; Move X past "NANO" (4 chars)
    txa
    clc
    adc #4
    tax

; --- skip spaces before name ---
cn_skip1:
    lda LINEBUF,x
    bne cn_chksp
    jmp cn_usage

cn_chksp:
    cmp #$20
    bne cn_name_start
    inx
    bne cn_skip1

cn_name_start:
    ; First, copy filename into NANONAME buffer (8 chars, space-padded)
    ldy #0
cn_fill_nanoname:
    lda #' '
    sta NANONAME,y
    iny
    cpy #DIR_NAME_LEN
    bne cn_fill_nanoname

    ; Copy token into NANONAME (up to 8 chars)
    stx nano_tmp_x       ; save X for later
    ldy #0
cn_copy_nanoname:
    lda LINEBUF,x
    beq cn_search_existing
    cmp #$20
    beq cn_search_existing
    sta NANONAME,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cn_copy_nanoname

    ; if name >8 chars, skip rest of token
cn_skip_long_name:
    lda LINEBUF,x
    beq cn_search_existing
    cmp #$20
    beq cn_search_existing
    inx
    bne cn_skip_long_name

cn_search_existing:
    ; Now search DIR_TABLE for NANONAME
    lda DIR_COUNT
    beq cn_create_new    ; no files, must create new

    ; Search loop
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI
    ldx DIR_COUNT

cn_search_loop:
    ; Compare 8 bytes of name
    ldy #0
cn_search_cmp:
    lda (DPTR_LO),y
    cmp NANONAME,y
    bne cn_search_next
    iny
    cpy #DIR_NAME_LEN
    bne cn_search_cmp

    ; MATCH! File exists - set flag and use this entry
    lda #1
    sta nano_existing
    jmp cn_found_entry

cn_search_next:
    ; Advance DPTR to next entry
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cn_search_nc
    inc DPTR_HI
cn_search_nc:
    dex
    bne cn_search_loop

cn_create_new:
    ; File doesn't exist - create new entry
    lda #0
    sta nano_existing

    ; Check if room in directory
    lda DIR_COUNT
    cmp #DIR_MAX
    bcc cn_room
    jmp cn_full

cn_room:
    ; DPTR = DIR_TABLE + (DIR_COUNT * DIR_ENTRY_SIZE)
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI
    ldy DIR_COUNT

cn_adv:
    cpy #0
    beq cn_entry_ready
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cn_adv_nc
    inc DPTR_HI

cn_adv_nc:
    dey
    jmp cn_adv

cn_entry_ready:
    ; Clear entry for new file
    ldy #0
cn_clr_entry:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne cn_clr_entry

    ; Write NANONAME into entry
    ldy #0
cn_write_name:
    lda NANONAME,y
    sta (DPTR_LO),y
    iny
    cpy #DIR_NAME_LEN
    bne cn_write_name
    jmp cn_after_name

cn_found_entry:
    ; File exists - DPTR already points to it
    ; Read the existing file's start address and length
    ldy #DIR_OFF_START
    lda (DPTR_LO),y
    sta nano_old_start_lo
    iny
    lda (DPTR_LO),y
    sta nano_old_start_hi

    ldy #DIR_OFF_LEN
    lda (DPTR_LO),y
    sta nano_old_len_lo
    iny
    lda (DPTR_LO),y
    sta nano_old_len_hi

    ; Display existing content
    lda #13
    jsr CHROUT
    ldx #0
@show_existing:
    lda nano_existing_txt,x
    beq @done_msg
    jsr CHROUT
    inx
    bne @show_existing
@done_msg:
    lda #13
    jsr CHROUT

    ; Display the file content
    lda nano_old_start_lo
    sta PTR_LO
    lda nano_old_start_hi
    sta PTR_HI

    lda nano_old_len_lo
    sta tmp_len_lo
    lda nano_old_len_hi
    sta tmp_len_hi

    ; Print file content byte by byte
@print_loop:
    lda tmp_len_lo
    ora tmp_len_hi
    beq @print_done

    ldy #0
    lda (PTR_LO),y
    jsr CHROUT

    inc PTR_LO
    bne @no_carry
    inc PTR_HI
@no_carry:

    lda tmp_len_lo
    bne @dec_lo
    dec tmp_len_hi
@dec_lo:
    dec tmp_len_lo
    jmp @print_loop

@print_done:
    lda #13
    jsr CHROUT

    ; For editing, we'll rewrite at the same location
    lda nano_old_start_lo
    sta PTR_LO
    lda nano_old_start_hi
    sta PTR_HI

    ; Reset length counter for new content
    lda #0
    sta tmp_len_lo
    sta tmp_len_hi

    jmp cn_editor_start

cn_after_name:
    ; New file - allocate at heap
    ; store start = fs_heap into entry offsets 8/9
    ldy #DIR_OFF_START
    lda fs_heap_lo
    sta (DPTR_LO),y
    iny
    lda fs_heap_hi
    sta (DPTR_LO),y

    ; PTR = fs_heap
    lda fs_heap_lo
    sta PTR_LO
    lda fs_heap_hi
    sta PTR_HI

    ; len = 0
    lda #0
    sta tmp_len_lo
    sta tmp_len_hi

cn_editor_start:

    ; print a tiny instruction line
    lda #<nano_hdr_txt
    sta ZPTR_LO
    lda #>nano_hdr_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT

; ------------------------------------------------------------
; input loop: read lines until "." alone
; ------------------------------------------------------------
cn_line_loop:
    ; show prompt for editor lines (optional)
    lda #<nano_prompt_txt
    sta ZPTR_LO
    lda #>nano_prompt_txt
    sta ZPTR_HI
    jsr print_z

    jsr read_line          ; fills LINEBUF, 0-terminated

    lda #$0D
    jsr CHROUT

    ; if LINEBUF == "." and next == 0 => done
    lda LINEBUF
    cmp #'.'
    bne cn_copy_line
    lda LINEBUF+1
    beq cn_finish

cn_copy_line:
    ; copy LINEBUF bytes into heap until 0
    ldx #0

cn_copy_ch:
    lda LINEBUF,x
    beq cn_end_line
    ldy #0
    sta (PTR_LO),y

    ; PTR++
    inc PTR_LO
    bne cn_ptr_ok
    inc PTR_HI

cn_ptr_ok:
    ; len++
    inc tmp_len_lo
    bne cn_len_ok
    inc tmp_len_hi

cn_len_ok:
    inx
    bne cn_copy_ch

cn_end_line:
    ; append CR ($0D) to separate lines
    lda #$0D
    ldy #0
    sta (PTR_LO),y
    inc PTR_LO
    bne cn_ptr_ok2
    inc PTR_HI

cn_ptr_ok2:
    inc tmp_len_lo
    bne cn_len_ok2
    inc tmp_len_hi

cn_len_ok2:
    jmp cn_line_loop

cn_finish:
    ; store len into entry offsets 10/11
    ldy #DIR_OFF_LEN
    lda tmp_len_lo
    sta (DPTR_LO),y
    iny
    lda tmp_len_hi
    sta (DPTR_LO),y

    jsr fs_stamp_entry_datetime

    ; Update heap pointer
    ; For new files: always update heap to PTR
    ; For existing files: only update if PTR > old_end
    lda nano_existing
    beq cn_update_heap      ; new file, always update

    ; Existing file: calculate old_end = old_start + old_len
    clc
    lda nano_old_start_lo
    adc nano_old_len_lo
    sta nano_tmp_lo
    lda nano_old_start_hi
    adc nano_old_len_hi
    sta nano_tmp_hi

    ; Compare PTR with old_end
    ; If PTR > old_end, update heap to PTR
    ; If PTR <= old_end, keep heap as is (we wrote within old space)
    lda PTR_HI
    cmp nano_tmp_hi
    bcc cn_skip_heap_update   ; PTR_HI < old_end_hi
    bne cn_update_heap        ; PTR_HI > old_end_hi
    lda PTR_LO
    cmp nano_tmp_lo
    bcc cn_skip_heap_update   ; PTR_LO < old_end_lo
    beq cn_skip_heap_update   ; PTR_LO == old_end_lo

cn_update_heap:
    ; commit heap pointer = PTR
    lda PTR_LO
    sta fs_heap_lo
    lda PTR_HI
    sta fs_heap_hi

cn_skip_heap_update:
    ; Only increment DIR_COUNT if this was a new file
    lda nano_existing
    bne cn_skip_count_inc
    inc DIR_COUNT

cn_skip_count_inc:
    lda #<nano_done_txt
    sta ZPTR_LO
    lda #>nano_done_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cn_usage:
    lda #<nano_usage_txt
    sta ZPTR_LO
    lda #>nano_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cn_full:
    lda #<full_txt
    sta ZPTR_LO
    lda #>full_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ============================================================
; SAVE / LOAD COMMANDS (DISK BRIDGE)
; ============================================================

; ------------------------------------------------------------
; cmd_drive
; DRIVE [8|9|10|11]
;
; Sets or displays the default drive number.
; If no argument, shows current drive.
; If argument, sets default drive (8, 9, 10, or 11).
; ------------------------------------------------------------
cmd_drive:
    lda #13
    jsr CHROUT

    ; Move X past "DRIVE" (5 chars)
    txa
    clc
    adc #5
    tax

    ; Skip spaces
drive_skip_sp:
    lda LINEBUF,x
    bne @not_empty
    jmp drive_show       ; no argument, just show current
@not_empty:
    cmp #$20
    bne drive_check_num
    inx
    jmp drive_skip_sp

drive_check_num:
    ; Check for '8', '9', or '1' (for 10/11)
    cmp #'8'
    beq drive_set_8
    cmp #'9'
    beq drive_set_9
    cmp #'1'
    beq drive_try_10_11
    jmp drive_usage

drive_set_8:
    ; Make sure next char is space or EOL
    lda LINEBUF+1,x
    beq drive_do_8
    cmp #$20
    beq drive_do_8
    jmp drive_usage
drive_do_8:
    lda #8
    sta default_drive
    jmp drive_confirm

drive_set_9:
    ; Make sure next char is space or EOL
    lda LINEBUF+1,x
    beq drive_do_9
    cmp #$20
    beq drive_do_9
    jmp drive_usage
drive_do_9:
    lda #9
    sta default_drive
    jmp drive_confirm

drive_try_10_11:
    ; Could be '10' or '11'
    lda LINEBUF+1,x
    cmp #'0'
    beq drive_set_10
    cmp #'1'
    beq drive_set_11
    jmp drive_usage

drive_set_10:
    ; Make sure next char is space or EOL
    lda LINEBUF+2,x
    beq drive_do_10
    cmp #$20
    beq drive_do_10
    jmp drive_usage
drive_do_10:
    lda #10
    sta default_drive
    jmp drive_confirm

drive_set_11:
    ; Make sure next char is space or EOL
    lda LINEBUF+2,x
    beq drive_do_11
    cmp #$20
    beq drive_do_11
    jmp drive_usage
drive_do_11:
    lda #11
    sta default_drive
    jmp drive_confirm

drive_confirm:
    ; Print confirmation
    lda #<drive_set_txt
    sta ZPTR_LO
    lda #>drive_set_txt
    sta ZPTR_HI
    jsr print_z
    lda default_drive
    jsr print_drive_num
    lda #13
    jsr CHROUT
    rts

drive_show:
    ; Show current default drive
    lda #<drive_current_txt
    sta ZPTR_LO
    lda #>drive_current_txt
    sta ZPTR_HI
    jsr print_z
    lda default_drive
    jsr print_drive_num
    lda #13
    jsr CHROUT
    rts

; Helper to print drive number (8, 9, 10, or 11)
print_drive_num:
    cmp #10
    bcs @two_digit
    ; Single digit (8 or 9)
    clc
    adc #'0'
    jsr CHROUT
    rts
@two_digit:
    ; Print '1' then the second digit
    lda #'1'
    jsr CHROUT
    lda default_drive
    sec
    sbc #10
    clc
    adc #'0'
    jsr CHROUT
    rts

drive_usage:
    lda #<drive_usage_txt
    sta ZPTR_LO
    lda #>drive_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_save
; SAVE <filename>
;
; Saves a file from RAM filesystem to disk (device 8) as SEQ.
;
; Operation:
;   1. Parse filename from LINEBUF
;   2. Find file in RAM filesystem
;   3. Open SEQ file for write on device 8 (SA=1)
;   4. Stream bytes from RAM heap to disk
;   5. Close file and check status
;
; Error handling:
;   - File not found in RAM
;   - Disk error (no drive, disk full, etc.)
; ------------------------------------------------------------
cmd_save:
    lda #13
    jsr CHROUT

    ; Move X past "SAVE" (4 chars)
    txa
    clc
    adc #4
    tax

; --- Skip spaces before filename ---
save_skip1:
    lda LINEBUF,x
    bne save_chksp
    jmp save_usage

save_chksp:
    cmp #$20
    bne save_check_drive
    inx
    bne save_skip1

; --- Check for drive number (8:, 9:, 10:, 11:) ---
save_check_drive:
    ; Use global default drive
    lda default_drive
    sta save_drive_num

    ; Check if digit
    lda LINEBUF,x
    cmp #'8'
    beq save_try_8
    cmp #'9'
    beq save_try_9
    cmp #'1'
    beq save_try_10_11
    jmp save_name_start    ; Not a drive spec

save_try_8:
    ; Check for '8:'
    lda LINEBUF+1,x
    cmp #':'
    bne save_name_start
    lda #8
    sta save_drive_num
    inx
    inx
    jmp save_name_start

save_try_9:
    ; Check for '9:'
    lda LINEBUF+1,x
    cmp #':'
    bne save_name_start
    lda #9
    sta save_drive_num
    inx
    inx
    jmp save_name_start

save_try_10_11:
    ; Could be '10:' or '11:'
    lda LINEBUF+1,x
    cmp #'0'
    beq save_try_10
    cmp #'1'
    beq save_try_11
    jmp save_name_start

save_try_10:
    ; Check for '10:'
    lda LINEBUF+2,x
    cmp #':'
    bne save_name_start
    lda #10
    sta save_drive_num
    inx
    inx
    inx
    jmp save_name_start

save_try_11:
    ; Check for '11:'
    lda LINEBUF+2,x
    cmp #':'
    bne save_name_start
    lda #11
    sta save_drive_num
    inx
    inx
    inx
    jmp save_name_start

save_name_start:
    ; Build NAMEBUF (8 chars padded with spaces)
    ldy #0
save_fill:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne save_fill

    ; Copy filename token into NAMEBUF
    stx save_tmp_x       ; save X for disk filename
    ldy #0
save_copy:
    lda LINEBUF,x
    beq save_search
    cmp #$20
    beq save_search
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne save_copy

    ; If token >8, skip remainder
save_skip_long:
    lda LINEBUF,x
    beq save_search
    cmp #$20
    beq save_search
    inx
    bne save_skip_long

save_search:
    ; Search for file in RAM filesystem
    lda DIR_COUNT
    bne save_has_files
    jmp save_notfound

save_has_files:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

save_entry:
    ; Compare 8 bytes of name
    ldy #0
save_cmp_loop:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    beq @match
    jmp save_next_entry
@match:
    iny
    cpy #DIR_NAME_LEN
    bne save_cmp_loop

    ; MATCH! Read start address and length
    ldy #DIR_OFF_START
    lda (DPTR_LO),y
    sta PTR_LO
    iny
    lda (DPTR_LO),y
    sta PTR_HI

    ldy #DIR_OFF_LEN
    lda (DPTR_LO),y
    sta tmp_len_lo
    iny
    lda (DPTR_LO),y
    sta tmp_len_hi

    ; If length == 0, just save empty file
    lda tmp_len_lo
    ora tmp_len_hi
    beq save_open_file   ; still write empty file

save_open_file:
    ; Calculate filename length (scan from save_tmp_x until space or 0)
    ldx save_tmp_x
    ldy #0
save_flen:
    lda LINEBUF,x
    beq save_have_flen
    cmp #$20
    beq save_have_flen
    inx
    iny
    cpy #16              ; max filename length for C64 DOS
    bne save_flen

save_have_flen:
    tya
    bne @ok
    jmp save_usage       ; no filename (shouldn't happen)
@ok:
    ; Copy filename from LINEBUF to DOSFNAME and append ",S,W"
    sty save_flen_tmp    ; save filename length
    ldx save_tmp_x       ; X = start of filename in LINEBUF
    ldy #0               ; Y = index into DOSFNAME
save_copy_fname:
    lda LINEBUF,x
    sta DOSFNAME,y
    inx
    iny
    cpy save_flen_tmp
    bne save_copy_fname

    ; Append ",S,W" to DOSFNAME
    lda #','
    sta DOSFNAME,y
    iny
    lda #'S'
    sta DOSFNAME,y
    iny
    lda #','
    sta DOSFNAME,y
    iny
    lda #'W'
    sta DOSFNAME,y
    iny

    ; Y now has total length (filename + 4)
    ; SETNAM(len=Y, ptr in X/Y for DOSFNAME)
    tya                  ; A = total length
    ldx #<DOSFNAME
    ldy #>DOSFNAME
    jsr SETNAM

    ; SETLFS(LA=2, DEV=drive, SA=1)  SA=1 = SEQ write
    lda #2
    ldx save_drive_num
    ldy #1
    jsr SETLFS

    ; Open file for write
    jsr OPEN
    jsr READST
    beq @open_ok
    jmp save_open_fail
@open_ok:
    ; Set output to logical file 2
    ldx #2
    jsr CHKOUT
    jsr READST
    beq @chkout_ok
    jmp save_chkout_fail
@chkout_ok:
    ; Write bytes from RAM to disk
save_write_loop:
    lda tmp_len_lo
    ora tmp_len_hi
    beq save_write_done

    ldy #0
    lda (PTR_LO),y
    jsr CHROUT

    ; PTR++
    inc PTR_LO
    bne save_ptr_ok
    inc PTR_HI
save_ptr_ok:

    ; len--
    lda tmp_len_lo
    bne save_dec_lo
    dec tmp_len_hi
save_dec_lo:
    dec tmp_len_lo

    ; Check for disk errors
    jsr READST
    and #$BF             ; mask out EOI bit
    beq save_write_loop

    ; Write error occurred
    jmp save_write_error

save_write_done:
    ; Close file and restore I/O
    jsr CLRCHN
    lda #2
    jsr CLOSE

    ; Print success message
    lda #<save_ok_txt
    sta ZPTR_LO
    lda #>save_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT

    ; Print drive status
    jsr print_drive_status
    rts

save_next_entry:
    ; Advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc save_nc
    inc DPTR_HI
save_nc:
    dex
    beq save_notfound
    jmp save_entry

save_notfound:
    lda #<notfound_txt
    sta ZPTR_LO
    lda #>notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

save_usage:
    lda #<save_usage_txt
    sta ZPTR_LO
    lda #>save_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

save_open_fail:
    jsr CLRCHN
    lda #<dos_openfail_txt
    sta ZPTR_LO
    lda #>dos_openfail_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jsr print_drive_status
    rts

save_chkout_fail:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #<dos_nochan_txt
    sta ZPTR_LO
    lda #>dos_nochan_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

save_write_error:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #<save_write_err_txt
    sta ZPTR_LO
    lda #>save_write_err_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jsr print_drive_status
    rts

; ------------------------------------------------------------
; cmd_load
; LOAD <filename>
;
; Loads a file from disk (device 8) into RAM filesystem.
;
; Operation:
;   1. Parse filename from LINEBUF
;   2. Open SEQ file for read on device 8 (SA=0)
;   3. Check available heap space
;   4. Stream bytes from disk to RAM heap
;   5. Create or update RAM filesystem entry
;   6. Close file and check status
;
; Error handling:
;   - File not found on disk
;   - Out of RAM heap space
;   - Directory full
;   - Disk error
; ------------------------------------------------------------
cmd_load:
    lda #13
    jsr CHROUT

    ; Move X past "LOAD" (4 chars)
    txa
    clc
    adc #4
    tax

; --- Skip spaces before filename ---
load_skip1:
    lda LINEBUF,x
    bne load_chksp
    jmp load_usage

load_chksp:
    cmp #$20
    bne load_check_drive
    inx
    bne load_skip1

; --- Check for drive number (8:, 9:, 10:, 11:) ---
load_check_drive:
    ; Use global default drive
    lda default_drive
    sta load_drive_num

    ; Check if digit
    lda LINEBUF,x
    cmp #'8'
    beq load_try_8
    cmp #'9'
    beq load_try_9
    cmp #'1'
    beq load_try_10_11
    jmp load_name_start    ; Not a drive spec

load_try_8:
    ; Check for '8:'
    lda LINEBUF+1,x
    cmp #':'
    bne load_name_start
    lda #8
    sta load_drive_num
    inx
    inx
    jmp load_name_start

load_try_9:
    ; Check for '9:'
    lda LINEBUF+1,x
    cmp #':'
    bne load_name_start
    lda #9
    sta load_drive_num
    inx
    inx
    jmp load_name_start

load_try_10_11:
    ; Could be '10:' or '11:'
    lda LINEBUF+1,x
    cmp #'0'
    beq load_try_10
    cmp #'1'
    beq load_try_11
    jmp load_name_start

load_try_10:
    ; Check for '10:'
    lda LINEBUF+2,x
    cmp #':'
    bne load_name_start
    lda #10
    sta load_drive_num
    inx
    inx
    inx
    jmp load_name_start

load_try_11:
    ; Check for '11:'
    lda LINEBUF+2,x
    cmp #':'
    bne load_name_start
    lda #11
    sta load_drive_num
    inx
    inx
    inx
    jmp load_name_start

load_name_start:
    ; Build NAMEBUF (8 chars padded with spaces)
    ldy #0
load_fill:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne load_fill

    ; Copy first 8 chars of filename into NAMEBUF
    stx load_tmp_x       ; save X for disk filename
    ldy #0
load_copy:
    lda LINEBUF,x
    beq load_open_file
    cmp #$20
    beq load_open_file
    cpy #DIR_NAME_LEN
    beq load_skip_rest   ; already got 8 chars
    sta NAMEBUF,y
    iny
load_skip_rest:
    inx
    jmp load_copy

load_open_file:
    ; Calculate filename length for disk
    ldx load_tmp_x
    ldy #0
load_flen:
    lda LINEBUF,x
    beq load_have_flen
    cmp #$20
    beq load_have_flen
    inx
    iny
    cpy #16              ; max filename length
    bne load_flen

load_have_flen:
    tya
    bne @ok
    jmp load_usage
@ok:
    ; Copy filename from LINEBUF to DOSFNAME and append ",S,R"
    sty load_flen_tmp    ; save filename length
    ldx load_tmp_x       ; X = start of filename in LINEBUF
    ldy #0               ; Y = index into DOSFNAME
load_copy_fname:
    lda LINEBUF,x
    sta DOSFNAME,y
    inx
    iny
    cpy load_flen_tmp
    bne load_copy_fname

    ; Append ",S,R" to DOSFNAME
    lda #','
    sta DOSFNAME,y
    iny
    lda #'S'
    sta DOSFNAME,y
    iny
    lda #','
    sta DOSFNAME,y
    iny
    lda #'R'
    sta DOSFNAME,y
    iny

    ; Y now has total length (filename + 4)
    ; SETNAM(len=Y, ptr in X/Y for DOSFNAME)
    tya                  ; A = total length
    ldx #<DOSFNAME
    ldy #>DOSFNAME
    jsr SETNAM

    ; SETLFS(LA=2, DEV=drive, SA=0)  SA=0 = SEQ read
    lda #2
    ldx load_drive_num
    ldy #0
    jsr SETLFS

    ; Open file for read
    jsr OPEN
    jsr READST
    beq @open_ok
    jmp load_open_fail
@open_ok:
    ; Set input from logical file 2
    ldx #2
    jsr CHKIN
    jsr READST
    beq @chkin_ok
    jmp load_chkin_fail
@chkin_ok:

    ; PTR = current heap position (where we'll write)
    lda fs_heap_lo
    sta PTR_LO
    lda fs_heap_hi
    sta PTR_HI

    ; tmp_len = 0 (will count bytes read)
    lda #0
    sta tmp_len_lo
    sta tmp_len_hi

    ; Read bytes from disk to RAM
load_read_loop:
    jsr READST
    and #$40             ; check EOI bit
    bne load_read_done

    jsr CHRIN

    ; Check for errors (except EOI)
    pha
    jsr READST
    and #$BF             ; mask out EOI
    beq load_read_ok
    pla
    jmp load_read_error

load_read_ok:
    pla

    ; Store byte at PTR
    ldy #0
    sta (PTR_LO),y

    ; PTR++
    inc PTR_LO
    bne load_ptr_ok
    inc PTR_HI
load_ptr_ok:

    ; len++
    inc tmp_len_lo
    bne load_len_ok
    inc tmp_len_hi
load_len_ok:

    ; Check heap limit (simple check: don't exceed $9FFF)
    lda PTR_HI
    cmp #$A0
    bcc @heap_ok
    jmp load_heap_full
@heap_ok:
    jmp load_read_loop

load_read_done:
    ; Close file and restore I/O
    jsr CLRCHN
    lda #2
    jsr CLOSE

    ; Now create or update RAM filesystem entry
    ; First check if file already exists
    lda DIR_COUNT
    beq load_create_new  ; no files, create new

    ; Search for existing file
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

load_search_loop:
    ; Compare 8 bytes of name
    ldy #0
load_search_cmp:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    bne load_search_next
    iny
    cpy #DIR_NAME_LEN
    bne load_search_cmp

    ; MATCH! Update existing entry
    jmp load_update_entry

load_search_next:
    ; Advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc load_snc
    inc DPTR_HI
load_snc:
    dex
    beq load_create_new
    jmp load_search_loop

load_create_new:
    ; Check if directory is full
    lda DIR_COUNT
    cmp #DIR_MAX
    bcc load_room
    jmp load_dir_full

load_room:
    ; DPTR = DIR_TABLE + (DIR_COUNT * DIR_ENTRY_SIZE)
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldy DIR_COUNT
load_adv:
    cpy #0
    beq load_entry_ready
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc load_adv_nc
    inc DPTR_HI
load_adv_nc:
    dey
    jmp load_adv

load_entry_ready:
    ; Clear entry
    ldy #0
load_clr_entry:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne load_clr_entry

    ; Write NAMEBUF into entry
    ldy #0
load_write_name:
    lda NAMEBUF,y
    sta (DPTR_LO),y
    iny
    cpy #DIR_NAME_LEN
    bne load_write_name

    ; Increment DIR_COUNT
    inc DIR_COUNT

load_update_entry:
    ; Write start address (fs_heap_lo/hi before we read)
    ldy #DIR_OFF_START
    lda fs_heap_lo
    sta (DPTR_LO),y
    iny
    lda fs_heap_hi
    sta (DPTR_LO),y

    ; Write length
    ldy #DIR_OFF_LEN
    lda tmp_len_lo
    sta (DPTR_LO),y
    iny
    lda tmp_len_hi
    sta (DPTR_LO),y

    ; Stamp date/time
    jsr fs_stamp_entry_datetime

    ; Update heap pointer
    lda PTR_LO
    sta fs_heap_lo
    lda PTR_HI
    sta fs_heap_hi

    ; Print success message
    lda #<load_ok_txt
    sta ZPTR_LO
    lda #>load_ok_txt
    sta ZPTR_HI
    jsr print_z

    ; Print size
    lda tmp_len_hi
    ldx tmp_len_lo
    jsr print_u16_dec

    lda #<load_bytes_txt
    sta ZPTR_LO
    lda #>load_bytes_txt
    sta ZPTR_HI
    jsr print_z

    lda #13
    jsr CHROUT
    rts

load_usage:
    lda #<load_usage_txt
    sta ZPTR_LO
    lda #>load_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

load_open_fail:
    jsr CLRCHN
    lda #<load_notfound_txt
    sta ZPTR_LO
    lda #>load_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jsr print_drive_status
    rts

load_chkin_fail:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #<dos_nochan_txt
    sta ZPTR_LO
    lda #>dos_nochan_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

load_read_error:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #<load_read_err_txt
    sta ZPTR_LO
    lda #>load_read_err_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jsr print_drive_status
    rts

load_heap_full:
    jsr CLRCHN
    lda #2
    jsr CLOSE
    lda #<load_heap_full_txt
    sta ZPTR_LO
    lda #>load_heap_full_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

load_dir_full:
    lda #<full_txt
    sta ZPTR_LO
    lda #>full_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_cp
; CP <source> <dest>
;
; Copies a file within the RAM filesystem.
;
; Operation:
;   1. Parse source and dest filenames from LINEBUF
;   2. Find source file in RAM filesystem
;   3. Check directory has room for new file
;   4. Allocate heap space for copy
;   5. Copy bytes from source to new location
;   6. Create new directory entry with dest name
;   7. Stamp with current date/time
;
; Error handling:
;   - Source file not found
;   - Directory full (8 files max)
;   - Out of heap space
;   - Missing arguments
; ------------------------------------------------------------
cmd_cp:
    lda #13
    jsr CHROUT

    ; Move X past "CP" (2 chars)
    txa
    clc
    adc #2
    tax

; --- Skip spaces before source filename ---
cp_skip1:
    lda LINEBUF,x
    bne cp_chksp1
    jmp cp_usage

cp_chksp1:
    cmp #$20
    bne cp_src_start
    inx
    bne cp_skip1

cp_src_start:
    ; Build source NAMEBUF (8 chars padded with spaces)
    ldy #0
cp_fill_src:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne cp_fill_src

    ; Copy source filename into NAMEBUF
    ldy #0
cp_copy_src:
    lda LINEBUF,x
    bne @not_eol
    jmp cp_usage         ; no space after source = missing dest
@not_eol:
    cmp #$20
    beq cp_src_done
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cp_copy_src

    ; If source >8 chars, skip remainder until space
cp_skip_long_src:
    lda LINEBUF,x
    bne @not_eol2
    jmp cp_usage
@not_eol2:
    cmp #$20
    beq cp_src_done
    inx
    bne cp_skip_long_src

cp_src_done:
    ; X points to space after source, skip spaces before dest
cp_skip2:
    lda LINEBUF,x
    bne @not_eol3
    jmp cp_usage         ; EOL = missing dest
@not_eol3:
    cmp #$20
    bne cp_dest_start
    inx
    bne cp_skip2

cp_dest_start:
    ; Save source name to cp_srcname buffer
    ldy #0
cp_save_src:
    lda NAMEBUF,y
    sta cp_srcname,y
    iny
    cpy #DIR_NAME_LEN
    bne cp_save_src

    ; Now build dest NAMEBUF
    ldy #0
cp_fill_dest:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne cp_fill_dest

    ; Copy dest filename into NAMEBUF
    ldy #0
cp_copy_dest:
    lda LINEBUF,x
    beq cp_search_src    ; EOL = done
    cmp #$20
    beq cp_search_src    ; space = done
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cp_copy_dest

    ; If dest >8 chars, skip remainder
cp_skip_long_dest:
    lda LINEBUF,x
    beq cp_search_src
    cmp #$20
    beq cp_search_src
    inx
    bne cp_skip_long_dest

cp_search_src:
    ; Check for wildcard in dest filename
    ldy #0
cp_check_wildcard:
    lda NAMEBUF,y
    cmp #'*'
    bne @not_wildcard
    jmp cp_invalid_name
@not_wildcard:
    iny
    cpy #DIR_NAME_LEN
    bne cp_check_wildcard

    ; Search for source file in RAM filesystem
    lda DIR_COUNT
    bne cp_has_files
    jmp cp_src_notfound

cp_has_files:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

cp_src_entry:
    ; Compare 8 bytes of source name
    ldy #0
cp_src_cmp:
    lda (DPTR_LO),y
    cmp cp_srcname,y
    beq @match
    jmp cp_src_next
@match:
    iny
    cpy #DIR_NAME_LEN
    bne cp_src_cmp

    ; FOUND! Read source start address and length
    ldy #DIR_OFF_START
    lda (DPTR_LO),y
    sta cp_src_start_lo
    iny
    lda (DPTR_LO),y
    sta cp_src_start_hi

    ldy #DIR_OFF_LEN
    lda (DPTR_LO),y
    sta cp_src_len_lo
    iny
    lda (DPTR_LO),y
    sta cp_src_len_hi

    jmp cp_check_dir

cp_src_next:
    ; Advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cp_src_nc
    inc DPTR_HI
cp_src_nc:
    dex
    beq cp_src_notfound
    jmp cp_src_entry

cp_src_notfound:
    lda #<cp_src_notfound_txt
    sta ZPTR_LO
    lda #>cp_src_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cp_check_dir:
    ; Check if directory is full
    lda DIR_COUNT
    cmp #DIR_MAX
    bcc cp_dir_ok
    jmp cp_dir_full

cp_dir_ok:
    ; Check if dest already exists (optional - we'll allow overwrite by creating new)
    ; For simplicity, we'll just create a new entry

    ; Check heap space available
    ; Calculate required space = cp_src_len
    ; Check if fs_heap + len would exceed $A000
    clc
    lda fs_heap_lo
    adc cp_src_len_lo
    sta cp_new_end_lo
    lda fs_heap_hi
    adc cp_src_len_hi
    sta cp_new_end_hi

    ; Check if new_end >= $A000
    cmp #$A0
    bcc cp_heap_ok
    jmp cp_heap_full

cp_heap_ok:
    ; Allocate new directory entry
    ; DPTR = DIR_TABLE + (DIR_COUNT * DIR_ENTRY_SIZE)
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldy DIR_COUNT
cp_adv_dir:
    cpy #0
    beq cp_entry_ready
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc cp_adv_nc
    inc DPTR_HI
cp_adv_nc:
    dey
    jmp cp_adv_dir

cp_entry_ready:
    ; Clear new entry
    ldy #0
cp_clr_entry:
    lda #0
    sta (DPTR_LO),y
    iny
    cpy #DIR_ENTRY_SIZE
    bne cp_clr_entry

    ; Write dest name into entry
    ldy #0
cp_write_name:
    lda NAMEBUF,y
    sta (DPTR_LO),y
    iny
    cpy #DIR_NAME_LEN
    bne cp_write_name

    ; Write start address (current heap pointer)
    ldy #DIR_OFF_START
    lda fs_heap_lo
    sta (DPTR_LO),y
    iny
    lda fs_heap_hi
    sta (DPTR_LO),y

    ; Write length
    ldy #DIR_OFF_LEN
    lda cp_src_len_lo
    sta (DPTR_LO),y
    iny
    lda cp_src_len_hi
    sta (DPTR_LO),y

    ; Stamp date/time
    jsr fs_stamp_entry_datetime

    ; Increment DIR_COUNT
    inc DIR_COUNT

    ; Now copy the actual file data
    ; PTR = source address
    lda cp_src_start_lo
    sta PTR_LO
    lda cp_src_start_hi
    sta PTR_HI

    ; ZPTR = dest address (current heap)
    lda fs_heap_lo
    sta ZPTR_LO
    lda fs_heap_hi
    sta ZPTR_HI

    ; Copy length to working vars
    lda cp_src_len_lo
    sta tmp_len_lo
    lda cp_src_len_hi
    sta tmp_len_hi

cp_copy_loop:
    ; Check if done
    lda tmp_len_lo
    ora tmp_len_hi
    beq cp_copy_done

    ; Copy one byte
    ldy #0
    lda (PTR_LO),y
    sta (ZPTR_LO),y

    ; PTR++
    inc PTR_LO
    bne cp_ptr_ok
    inc PTR_HI
cp_ptr_ok:

    ; ZPTR++
    inc ZPTR_LO
    bne cp_zptr_ok
    inc ZPTR_HI
cp_zptr_ok:

    ; len--
    lda tmp_len_lo
    bne cp_dec_lo
    dec tmp_len_hi
cp_dec_lo:
    dec tmp_len_lo

    jmp cp_copy_loop

cp_copy_done:
    ; Update heap pointer
    lda cp_new_end_lo
    sta fs_heap_lo
    lda cp_new_end_hi
    sta fs_heap_hi

    ; Print success message
    lda #<cp_ok_txt
    sta ZPTR_LO
    lda #>cp_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cp_invalid_name:
    lda #<invalid_filename_txt
    sta ZPTR_LO
    lda #>invalid_filename_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cp_usage:
    lda #<cp_usage_txt
    sta ZPTR_LO
    lda #>cp_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cp_dir_full:
    lda #<full_txt
    sta ZPTR_LO
    lda #>full_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

cp_heap_full:
    lda #<cp_heap_full_txt
    sta ZPTR_LO
    lda #>cp_heap_full_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; Variables for CP command
cp_srcname:       !fill DIR_NAME_LEN, ' '
cp_src_start_lo:  !byte 0
cp_src_start_hi:  !byte 0
cp_src_len_lo:    !byte 0
cp_src_len_hi:    !byte 0
cp_new_end_lo:    !byte 0
cp_new_end_hi:    !byte 0

; ------------------------------------------------------------
; cmd_mv
; MV <source> <dest>
;
; Renames (moves) a file within the RAM filesystem.
;
; Operation:
;   1. Parse source and dest filenames from LINEBUF
;   2. Find source file in RAM filesystem
;   3. Check if dest already exists (warn if it does)
;   4. Update directory entry name field
;   5. No data copying needed - just rename!
;
; Error handling:
;   - Source file not found
;   - Dest file already exists
;   - Missing arguments
; ------------------------------------------------------------
cmd_mv:
    lda #13
    jsr CHROUT

    ; Move X past "MV" (2 chars)
    txa
    clc
    adc #2
    tax

; --- Skip spaces before source filename ---
mv_skip1:
    lda LINEBUF,x
    bne mv_chksp1
    jmp mv_usage

mv_chksp1:
    cmp #$20
    bne mv_src_start
    inx
    bne mv_skip1

mv_src_start:
    ; Build source NAMEBUF (8 chars padded with spaces)
    ldy #0
mv_fill_src:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne mv_fill_src

    ; Copy source filename into NAMEBUF
    ldy #0
mv_copy_src:
    lda LINEBUF,x
    bne @not_eol
    jmp mv_usage         ; no space after source = missing dest
@not_eol:
    cmp #$20
    beq mv_src_done
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne mv_copy_src

    ; If source >8 chars, skip remainder until space
mv_skip_long_src:
    lda LINEBUF,x
    bne @not_eol2
    jmp mv_usage
@not_eol2:
    cmp #$20
    beq mv_src_done
    inx
    bne mv_skip_long_src

mv_src_done:
    ; X points to space after source, skip spaces before dest
mv_skip2:
    lda LINEBUF,x
    bne @not_eol3
    jmp mv_usage         ; EOL = missing dest
@not_eol3:
    cmp #$20
    bne mv_dest_start
    inx
    bne mv_skip2

mv_dest_start:
    ; Save source name to mv_srcname buffer
    ldy #0
mv_save_src:
    lda NAMEBUF,y
    sta mv_srcname,y
    iny
    cpy #DIR_NAME_LEN
    bne mv_save_src

    ; Now build dest NAMEBUF
    ldy #0
mv_fill_dest:
    lda #' '
    sta NAMEBUF,y
    iny
    cpy #DIR_NAME_LEN
    bne mv_fill_dest

    ; Copy dest filename into NAMEBUF
    ldy #0
mv_copy_dest:
    lda LINEBUF,x
    beq mv_check_dest    ; EOL = done
    cmp #$20
    beq mv_check_dest    ; space = done
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne mv_copy_dest

    ; If dest >8 chars, skip remainder
mv_skip_long_dest:
    lda LINEBUF,x
    beq mv_check_dest
    cmp #$20
    beq mv_check_dest
    inx
    bne mv_skip_long_dest

mv_check_dest:
    ; Check for wildcard in dest filename
    ldy #0
mv_check_wildcard:
    lda NAMEBUF,y
    cmp #'*'
    bne @not_wildcard
    jmp mv_invalid_name
@not_wildcard:
    iny
    cpy #DIR_NAME_LEN
    bne mv_check_wildcard

    ; Check if dest file already exists
    lda DIR_COUNT
    beq mv_search_src    ; no files, can't exist

    ; Search for dest in directory
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

mv_dest_check_loop:
    ; Compare 8 bytes of dest name
    ldy #0
mv_dest_cmp:
    lda (DPTR_LO),y
    cmp NAMEBUF,y
    beq @match
    jmp mv_dest_check_next
@match:
    iny
    cpy #DIR_NAME_LEN
    bne mv_dest_cmp

    ; Dest exists! Error.
    jmp mv_dest_exists

mv_dest_check_next:
    ; Advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc mv_dest_nc
    inc DPTR_HI
mv_dest_nc:
    dex
    beq mv_search_src
    jmp mv_dest_check_loop

mv_search_src:
    ; Search for source file in RAM filesystem
    lda DIR_COUNT
    bne mv_has_files
    jmp mv_src_notfound

mv_has_files:
    ; DPTR = DIR_TABLE
    lda #<DIR_TABLE
    sta DPTR_LO
    lda #>DIR_TABLE
    sta DPTR_HI

    ldx DIR_COUNT

mv_src_entry:
    ; Compare 8 bytes of source name
    ldy #0
mv_src_cmp:
    lda (DPTR_LO),y
    cmp mv_srcname,y
    beq @match
    jmp mv_src_next
@match:
    iny
    cpy #DIR_NAME_LEN
    bne mv_src_cmp

    ; FOUND! Now update the name in place
    ldy #0
mv_rename:
    lda NAMEBUF,y
    sta (DPTR_LO),y
    iny
    cpy #DIR_NAME_LEN
    bne mv_rename

    ; Print success message
    lda #<mv_ok_txt
    sta ZPTR_LO
    lda #>mv_ok_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

mv_src_next:
    ; Advance DPTR += DIR_ENTRY_SIZE
    clc
    lda DPTR_LO
    adc #DIR_ENTRY_SIZE
    sta DPTR_LO
    bcc mv_src_nc
    inc DPTR_HI
mv_src_nc:
    dex
    beq mv_src_notfound
    jmp mv_src_entry

mv_src_notfound:
    lda #<mv_src_notfound_txt
    sta ZPTR_LO
    lda #>mv_src_notfound_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

mv_dest_exists:
    lda #<mv_dest_exists_txt
    sta ZPTR_LO
    lda #>mv_dest_exists_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

mv_invalid_name:
    lda #<invalid_filename_txt
    sta ZPTR_LO
    lda #>invalid_filename_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

mv_usage:
    lda #<mv_usage_txt
    sta ZPTR_LO
    lda #>mv_usage_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; cmd_passwd
; Change password with confirmation, then save to disk
; ------------------------------------------------------------
cmd_passwd:
    lda #13
    jsr CHROUT

@again:
    lda #<setup_pass_txt
    sta ZPTR_LO
    lda #>setup_pass_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Copy LINEBUF to PASSWORD
    ldx #0
@cp:
    lda LINEBUF,x
    sta PASSWORD,x
    beq @copied
    inx
    cpx #USER_MAX-1
    bcc @cp
    lda #0
    sta PASSWORD+USER_MAX-1
@copied:

    ; Ask for confirmation
    lda #13
    jsr CHROUT
    lda #<setup_confirm_txt
    sta ZPTR_LO
    lda #>setup_confirm_txt
    sta ZPTR_HI
    jsr print_z
    jsr read_line

    ; Compare LINEBUF against PASSWORD
    ldx #0
@cmp:
    lda PASSWORD,x
    beq @chk_end
    cmp LINEBUF,x
    bne @mismatch
    inx
    cpx #USER_MAX
    bne @cmp
    beq @match
@chk_end:
    lda LINEBUF,x
    bne @mismatch
@match:
    ; Save to disk
    jsr save_config
    lda #<passwd_ok_txt
    sta ZPTR_LO
    lda #>passwd_ok_txt
    sta ZPTR_HI
    jsr print_z
    rts
@mismatch:
    lda #13
    jsr CHROUT
    lda #<pass_mismatch_txt
    sta ZPTR_LO
    lda #>pass_mismatch_txt
    sta ZPTR_HI
    jsr print_z
    lda #13
    jsr CHROUT
    jmp @again

; Variables for MV command
mv_srcname: !fill DIR_NAME_LEN, ' '

; Variables for SAVE/LOAD commands
save_tmp_x:     !byte 0
load_tmp_x:     !byte 0
save_flen_tmp:  !byte 0
load_flen_tmp:  !byte 0
save_drive_num: !byte 8
load_drive_num: !byte 8
default_drive:  !byte 8    ; Global default drive (8-11)

; ------------------------------------------------------------
; msg_unknown
; ------------------------------------------------------------
; Prints the "UNKNOWN COMMAND" error message.
;
; Behavior:
;   - Outputs a newline
;   - Prints unk_txt
;
; Called when:
;   - No command matcher succeeds in exec_cmd
; ------------------------------------------------------------
msg_unknown:
    lda #13
    jsr CHROUT
    ldx #0
@u:
    lda unk_txt,x
    beq @done
    jsr CHROUT
    inx
    bne @u
@done:
    rts

; ============================================================
; FILESYSTEM SUBSYSTEM
; ============================================================

; ------------------------------------------------------------
; fs_init
; ------------------------------------------------------------
; Initializes in-RAM filesystem state
; - Clears directory table
; - Resets heap pointer
; - Sets DIR_COUNT = 0
; ------------------------------------------------------------
fs_init:
    ; reset heap pointer
    lda #<FS_HEAP_BASE
    sta fs_heap_lo
    lda #>FS_HEAP_BASE
    sta fs_heap_hi

    ; DIR_COUNT = 0
    lda #0
    sta DIR_COUNT

    ; Clear DIR_TABLE (DIR_MAX * DIR_ENTRY_SIZE bytes)
    ldx #0
@clr:
    lda #0
    sta DIR_TABLE,x
    inx
    cpx #(DIR_MAX*DIR_ENTRY_SIZE)   ; 240 bytes when DIR_ENTRY_SIZE=30
    bne @clr

    rts

; ------------------------------------------------------------
; fs_stamp_entry_datetime
; Copies DATE_STR and current time (built from jiffy clock)
; into the directory entry pointed to by DPTR.
;
; In:
;   DPTR -> directory entry
; Out:
;   entry[DIR_OFF_DATE..] = DATE_STR (10 bytes)
;   entry[DIR_OFF_TIME..] = CUR_TIME (8 bytes)
; Clobbers: A,X,Y
; ------------------------------------------------------------
fs_stamp_entry_datetime:
    jsr build_cur_time

    ; copy DATE_STR -> entry
    ldy #DIR_OFF_DATE
    ldx #0
@date_lp:
    lda DATE_STR,x
    sta (DPTR_LO),y
    inx
    iny
    cpx #DIR_DATE_LEN
    bne @date_lp

    ; copy CUR_TIME -> entry
    ldy #DIR_OFF_TIME
    ldx #0
@time_lp:
    lda CUR_TIME,x
    sta (DPTR_LO),y
    inx
    iny
    cpx #DIR_TIME_LEN
    bne @time_lp

    rts

; ============================================================
; OUTPUT / FORMATTING ROUTINES
; ============================================================

; ------------------------------------------------------------
; print_hex16
; ------------------------------------------------------------
; Prints a 16-bit value in hexadecimal as: $HHLL
;
; Input:
;   A = high byte
;   X = low byte
;
; Output:
;   Writes '$' then two hex dec_digits for A, then two for X
;
; Clobbers:
;   A (via print_hex), uses stack (PHA/PLA)
; ------------------------------------------------------------
; A = hi, X = lo  (prints like $6000)
print_hex16:
    pha
    lda #'$'
    jsr CHROUT
    pla
    jsr print_hex      ; prints hi byte in A
    txa
    jsr print_hex      ; prints lo byte
    rts

; ----------------------------------------
; print_u16_dec
; Prints unsigned 16-bit value as decimal
; Input: A = hi byte, X = lo byte
; Uses: dec_tmp_hi/dec_tmp_lo
; ----------------------------------------
print_u16_dec:
    sta dec_tmp_hi
    stx dec_tmp_lo

    ; If zero -> print '0'
    lda dec_tmp_hi
    ora dec_tmp_lo
    bne @start
    lda #'0'
    jsr CHROUT
    rts

@start:
    ; Print 10000s, 1000s, 100s, 10s, 1s
    ldy #0
    jsr print_place_10000
    jsr print_place_1000
    jsr print_place_100
    jsr print_place_10
    jsr print_place_1
    rts

; Y = "have printed a non-zero dec_digit yet" flag (0=no, 1=yes)

print_place_10000:
    lda #>10000
    ldx #<10000
    jmp print_place

print_place_1000:
    lda #>1000
    ldx #<1000
    jmp print_place

print_place_100:
    lda #>100
    ldx #<100
    jmp print_place

print_place_10:
    lda #>10
    ldx #<10
    jmp print_place

print_place_1:
    lda #0
    ldx #1
    jmp print_place

; ----------------------------------------
; print_place
; subtracts place value (A=hi, X=lo) repeatedly
; prints dec_digit, suppressing leading zeros
; uses Y as started flag
; ----------------------------------------
print_place:
    sta dec_pv_hi
    stx dec_pv_lo

    lda #'0'
    sta dec_digit

@subloop:
    ; if tmp < pv then done
    lda dec_tmp_hi
    cmp dec_pv_hi
    bcc @done
    bne @do_sub
    lda dec_tmp_lo
    cmp dec_pv_lo
    bcc @done

@do_sub:
    ; tmp -= pv
    sec
    lda dec_tmp_lo
    sbc dec_pv_lo
    sta dec_tmp_lo
    lda dec_tmp_hi
    sbc dec_pv_hi
    sta dec_tmp_hi

    inc dec_digit
    jmp @subloop

@done:
    ; print dec_digit if non-leading or last place
    lda dec_digit
    cmp #'0'
    bne @print_it

    ; dec_digit is '0'
    cpy #0
    beq @maybe_skip
@print_it:
    jsr CHROUT
    ldy #1
    rts

@maybe_skip:
    ; If this is the 1s place, we must print 0
    ; Detect 1s place by pv == 1
    lda dec_pv_hi
    bne @skip
    lda dec_pv_lo
    cmp #1
    bne @skip
    lda #'0'
    jsr CHROUT
    ldy #1
@skip:
    rts

; ------------------------------------------------------------
; print_free_mem_line
; Prints: " FREE <bytes>" then CR
; (Used by MEM)
;
; Notes:
;   FREE = MEMSIZ ($37/$38) - VARTAB ($2D/$2E)
; Clobbers: A,X,Y, free_lo/free_hi
; ------------------------------------------------------------
print_free_mem_line:
    ; leading space so it looks nice after UNAME
    lda #' '
    jsr CHROUT

    ; Print "FREE "
    ldx #0
@t1:
    lda mem_free_txt,x
    beq @calc
    jsr CHROUT
    inx
    bne @t1

@calc:
    sec
    lda $37
    sbc $2D
    sta free_lo
    lda $38
    sbc $2E
    sta free_hi

    lda free_hi
    ldx free_lo
    jsr print_u16_dec

    lda #13
    jsr CHROUT
    rts

; ------------------------------------------------------------
; print_dptr_bytes
; Prints X bytes from (DPTR) + Y
;
; Inputs:
;   DPTR_LO/DPTR_HI = base pointer (directory entry)
;   Y = offset into entry
;   X = number of bytes to print
;
; Clobbers: A, X, Y
; ------------------------------------------------------------
print_dptr_bytes:
@loop:
    lda (DPTR_LO),y
    jsr CHROUT
    iny
    dex
    bne @loop
    rts

; ------------------------------------------------------------
; print_z
; ------------------------------------------------------------
; Prints a 0-terminated string from memory using (ZPTR).
;
; Input:
;   ZPTR_LO/ZPTR_HI = address of string
;
; Output:
;   Prints until a 0 byte is encountered
;
; Clobbers:
;   A
; ------------------------------------------------------------
print_z:
@loop:
    ldy #0
    lda (ZPTR_LO),y
    beq @done
    jsr CHROUT
    inc ZPTR_LO
    bne @loop
    inc ZPTR_HI
    bne @loop
@done:
    rts

; ------------------------------------------------------------
; print_entry_bytes
; Prints X bytes from (PTR) starting at offset Y
; Clobbers: A, X, Y
; ------------------------------------------------------------
print_entry_bytes:
@lp:
    lda (PTR_LO),y
    jsr CHROUT
    iny
    dex
    bne @lp
    rts

; ============================================================
; DEBUG ROUTINES
; ============================================================

; dump_linebuf
; - Prints first 8 bytes of LINEBUF as hex for troubleshooting
; - Output format: "BUF: XX XX XX XX XX XX XX XX"
dump_linebuf:
    lda #13
    jsr CHROUT

    ldx #0
@hdr:
    lda dbg_txt,x
    beq @go
    jsr CHROUT
    inx
    bne @hdr

@go:
    ldx #0
@loop:
    lda #' '
    jsr CHROUT
    lda LINEBUF,x
    jsr print_hex
    inx
    cpx #8
    bne @loop

    lda #13
    jsr CHROUT
    rts

; print_hex
; - Prints A as two hex dec_digits using CHROUT
; - Uses nibble_to_petscii
print_hex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr nibble_to_petscii
    jsr CHROUT
    pla
    and #$0F
    jsr nibble_to_petscii
    jsr CHROUT
    rts

; nibble_to_petscii
; - Converts nibble (0..15) to printable '0'..'9','A'..'F'
; - Returns PETSCII/ASCII codes suitable for CHROUT output
nibble_to_petscii:
    cmp #10
    bcc @is_digit
    ; 10..15 -> 'A'..'F' ($41..$46)
    clc
    adc #$37        ; 10+$37=$41 ('A'), 15+$37=$46 ('F')
    rts
@is_digit:
    clc
    adc #$30        ; '0' ($30..$39)
    rts

; ============================================================
; GLOBAL STATE / VARIABLES
; ============================================================
; (Zero-page pointers are constants above; these are RAM variables)

; ============================================================
; SETUP / SESSION STATE
; ============================================================

USERNAME: !fill USER_MAX, 0
PASSWORD: !fill USER_MAX, 0
config_loaded:  !byte 0   ; 1 if CONFIG was loaded from disk
login_user_ok:  !byte 0   ; scratch flag for login comparison
login_attempts: !byte 0   ; login attempt counter
DATE_STR: !fill DATE_MAX, 0
TIME_STR: !fill TIME_MAX, 0

; --- filesystem directory ---
DIR_COUNT:   !byte 0
DIR_TABLE:   !fill (DIR_MAX*DIR_ENTRY_SIZE), 0    ; 240 bytes when DIR_ENTRY_SIZE=30

; --- scratch / temp ---
tmp_len_lo:  !byte 0
tmp_len_hi:  !byte 0
cw_tmp_x:    !byte 0   ; temporary X storage for WRITE command

; --- heap pointer (next free byte in FS heap area) ---
fs_heap_lo: !byte <FS_HEAP_BASE
fs_heap_hi: !byte >FS_HEAP_BASE

; --- reusable 8-char name buffer (padded with spaces) ---
NAMEBUF: !fill DIR_NAME_LEN, ' '

; --- DOS filename buffer (for appending ,S,W or ,S,R) ---
DOSFNAME: !fill 20, 0

; --- nano editor state ---
nano_existing:     !byte 0   ; 0=new file, 1=editing existing
nano_tmp_x:        !byte 0   ; temporary storage for X register
nano_old_start_lo: !byte 0   ; existing file start address (lo)
nano_old_start_hi: !byte 0   ; existing file start address (hi)
nano_old_len_lo:   !byte 0   ; existing file length (lo)
nano_old_len_hi:   !byte 0   ; existing file length (hi)
nano_tmp_lo:       !byte 0   ; temp for calculations
nano_tmp_hi:       !byte 0   ; temp for calculations
NANONAME:          !fill 8, ' '

; --- decimal print scratch (used by print_u16_dec/print_place) ---
dec_tmp_lo: !byte 0
dec_tmp_hi: !byte 0
dec_pv_lo:  !byte 0
dec_pv_hi:  !byte 0
dec_digit:  !byte 0

; ============================================================
; TIME / CLOCK STATE (KERNAL JIFFY CLOCK)
; ============================================================

; parse scratch
tmp8a:  !byte 0
tmp8b:  !byte 0
tmp8c:  !byte 0

hours:  !byte 0
mins:   !byte 0
secs:   !byte 0

; total seconds since midnight (16-bit, 0..86399)
tot_lo: !byte 0
tot_hi: !byte 0

; 24-bit jiffy counter
jlo:    !byte 0
jmid:   !byte 0
jhi:    !byte 0

; division scratch for jiffies_to_seconds16
nlo:    !byte 0
nmid:   !byte 0
nhi:    !byte 0
quo0:   !byte 0
quo1:   !byte 0
quo2:   !byte 0
rem8:   !byte 0

; seconds (16-bit) and HMS output
sec_lo: !byte 0
sec_hi: !byte 0

work_lo: !byte 0
work_hi: !byte 0

h_out:  !byte 0
m_out:  !byte 0
s_out:  !byte 0

h_work: !byte 0
m_work: !byte 0

; state variables to get date to advance
LAST_JLO: !byte 0
LAST_JMID: !byte 0
LAST_JHI: !byte 0

; --- date increment scratch ---
d_day:      !byte 0
d_month:    !byte 0
d_max:      !byte 0
d_tmp:      !byte 0

; ============================================================
; UPTIME STATE
; ============================================================
BOOT_SEC_LO:   !byte 0   ; seconds since midnight at boot (low)
BOOT_SEC_HI:   !byte 0   ; seconds since midnight at boot (high)

UP_DAYS_LO:    !byte 0   ; number of midnight rollovers since boot (low)
UP_DAYS_HI:    !byte 0   ; number of midnight rollovers since boot (high)

; ============================================================
; TEXT CONSTANTS (PETSCII / SCREEN OUTPUT)
; ============================================================

; -------------------------
; Text (UPPERCASE only)
; -------------------------

; --- Boot sequence text ---
boot_ok_txt:      !text "[  OK  ] ",0
boot_kern_txt:    !text "STARTING C64UX KERNEL ", C64UX_VERSION,0
boot_mem_txt:     !text "MEMORY CHECK: 64K RAM SYSTEM",0
boot_fs_txt:      !text "INITIALIZING FILESYSTEM",0
boot_heap_txt:    !text "HEAP ALLOCATED AT $6000",0
boot_hw_txt:      !text "DETECTING HARDWARE",0
boot_reu_yes_txt: !text "REU: DETECTED",0
boot_reu_no_txt:  !text "REU: NOT FOUND",0
boot_drv_txt:     !text "LOADING DEVICE DRIVERS",0
boot_mnt_txt:     !text "MOUNTING /DEV/DISK (DEVICE 8)",0

; --- Banners / prompts ---
banner_txt:
!byte 13,5    ; newline + white color
!text "  **** C64UX ", C64UX_VERSION, " BY A. SCAROLA ****",13,0

banner_help_txt:
!byte 5       ; white color
!text "      TYPE 'HELP' FOR ASSISTANCE",13,0

setup_header_txt:
!text "--------------",13,"INITIAL SETUP:",13,"--------------",13,0

setup_user_txt:
!text "USERNAME (MAX 15): ",0

setup_date_txt:
!text "DATE (YYYY-MM-DD): ",0

setup_time_txt:
!text "TIME (HH:MM:SS): ",0

default_user_txt:
!text "USER",0

default_date_txt:
!text "0000-00-00",0

default_time_txt:
!text "00:00:00",0

prompt_tail_txt:
!text "@C64UX:% ",0

help_txt_part1:
!text "COMMANDS:",13
!text "  CAT     - PRINT FILE",13
!text "  CLEAR   - CLEAR SCREEN (ALIAS: CLS)",13
!text "  CP      - COPY FILE (RAM TO RAM)",13
!text "  DATE    - CURRENT DATE",13
!text "  DOS     - DISK DOS (DEV 8)",13
!text "             DOS @$ = DIR; I0, S:, R:",13
!text "  DRIVE   - SET/SHOW DEFAULT DRIVE 8-11",13
!text "             DRIVE, DRIVE 9, DRIVE 10",13
!text "  ECHO    - PRINT TEXT",13
!text "  EXIT    - RETURN TO BASIC",13
!text "  HELP    - SHOW THIS HELP",13
!text "  LOAD    - LOAD FILE FROM DISK TO RAM",13
!text "             LOAD 9:FILE, LOAD 10:FILE",13
!text "  LOADREU - LOAD RAM FS FROM REU",13
!text "  LS      - LIST FILES",13,0

help_more_txt:
!text 13,"-- PRESS ANY KEY TO CONTINUE --",13,0

help_txt_part2:
!text 13,"  MEM     - FREE MEMORY",13
!text "  MV      - MOVE/RENAME FILE",13
!text "  NANO    - EDIT FILE",13
!text "  PASSWD  - CHANGE PASSWORD",13
!text "  PWD     - SHOW CURRENT PATH",13
!text "  RM      - DELETE FILE",13
!text "  SAVE    - SAVE FILE FROM RAM TO DISK",13
!text "             SAVE 9:FILE, SAVE 10:FILE",13
!text "  SAVEREU - SAVE RAM FS TO REU",13
!text "  STAT    - FILE INFO",13
!text "  THEME   - SET COLOR THEME",13
!text "             NORMAL, DARK, GREEN",13
!text "  TIME    - CURRENT TIME",13
!text "  UNAME   - SYSTEM INFO",13
!text "  UPTIME  - SYSTEM UPTIME",13
!text "  VERSION - SYSTEM VERSION (ALIAS: VER)",13
!text "  WHOAMI  - SHOW USERNAME",13
!text "  WIPEREU - WIPE REU (CLEAR FS)",13
!text "  WRITE   - CREATE FILE",13,0

; --- Status labels ---
stat_name_txt:
!text "NAME: ",0

stat_size_txt:
!text "SIZE: ",0

stat_addr_txt:
!text "ADDR: ",0

stat_date_txt:
!text "DATE: ",0

stat_time_txt:
!text "TIME: ",0

; --- Nano text ---
nano_usage_txt:
!text "USAGE: NANO <NAME>",0

nano_hdr_txt:
!text "ENTER TEXT. END WITH A SINGLE '.' LINE.",0

nano_existing_txt:
!text "--- EXISTING CONTENT ---",0

nano_prompt_txt:
!text "> ",0

nano_done_txt:
!text "SAVED.",0

; --- Errors / usage ---
notfound_txt:
!text "FILE NOT FOUND",0

cat_usage_txt:
!text "USAGE: CAT FILENAME",0

rm_usage_txt:
!text "USAGE: RM FILENAME",0

rm_wild_ok_txt:
!text "FILES DELETED",0

stat_usage_txt:
!text "USAGE: STAT FILENAME",0

usage_txt:
!text "USAGE: WRITE FILENAME TEXT",0

; --- Misc ---
uname_txt:
!text "C64UX ", C64UX_VERSION, " ", C64UX_BUILD_DATE, " (6502 C64)", 0

whoami_txt:
!text "USERNAME: ",0

ok_txt:
!text "OK",0

full_txt:
!text "DIRECTORY IS FULL",0

file_exists_txt:
!text "FILE ALREADY EXISTS",0

invalid_filename_txt:
!text "INVALID FILENAME (* NOT ALLOWED)",0

unk_txt:
!text "UNKNOWN COMMAND - TYPE 'HELP'",13,0

; Month lengths for non-leap years (Jan..Dec)
month_len:
    !byte 31,28,31,30,31,30,31,31,30,31,30,31

mem_free_txt:
!text "MEM FREE: ",0

dbg_txt:
!text "BUF:",0

pwd_prefix_txt:
!text "/HOME/",0

dos_usage_txt:
!text "USAGE: DOS <CMD>",0

dos_status_txt:
!text "STATUS: ",0

dos_nochan_txt:
!text "CHANNEL ERROR (NO DRIVE?)",0

dos_openfail_txt:
!text "OPEN FAILED (NO DRIVE?)",0

dir_name_txt:
!text "$",0

; --- REU text ---
reu_banner_txt:
!byte 5       ; white color
!text "             REU DETECTED",13,0

reu_notfound_txt:
!byte 13,5    ; newline + white color
!text "NO REU DETECTED",0

savereu_ok_txt:
!text 13,"FILESYSTEM SAVED TO REU",0

loadreu_ok_txt:
!text 13,"FILESYSTEM LOADED FROM REU",0

loadreu_bad_txt:
!text 13,"REU IMAGE INVALID",0

savereu_fail_txt:
!text 13,"FILESYSTEM SAVE FAILED",0

wipereu_ok_txt:
!text 13,"REU WIPED",0

; --- SAVE/LOAD command text ---
save_usage_txt:
!text "USAGE: SAVE <FILENAME>",0

save_ok_txt:
!text "SAVED TO DISK. ",0

save_write_err_txt:
!text "DISK WRITE ERROR. ",0

load_usage_txt:
!text "USAGE: LOAD <FILENAME>",0

load_ok_txt:
!text "LOADED ",0

load_bytes_txt:
!text " BYTES FROM DISK.",0

load_notfound_txt:
!text "FILE NOT FOUND ON DISK. ",0

load_read_err_txt:
!text "DISK READ ERROR. ",0

; --- DRIVE command text ---
drive_usage_txt:
!text "USAGE: DRIVE [8|9|10|11]",0

drive_current_txt:
!text "DEFAULT DRIVE: ",0

drive_set_txt:
!text "DEFAULT DRIVE SET TO: ",0

load_heap_full_txt:
!text "OUT OF RAM HEAP SPACE.",0

; --- CP command text ---
cp_usage_txt:
!text "USAGE: CP <SOURCE> <DEST>",0

cp_ok_txt:
!text "FILE COPIED.",0

cp_src_notfound_txt:
!text "SOURCE FILE NOT FOUND.",0

cp_heap_full_txt:
!text "OUT OF RAM HEAP SPACE.",0

; --- MV command text ---
mv_usage_txt:
!text "USAGE: MV <SOURCE> <DEST>",0

mv_ok_txt:
!text "FILE RENAMED.",0

mv_src_notfound_txt:
!text "SOURCE FILE NOT FOUND.",0

mv_dest_exists_txt:
!text "DESTINATION FILE ALREADY EXISTS.",0

; --- Credentials / login text ---
setup_pass_txt:
!text "PASSWORD (MAX 15): ",0

setup_confirm_txt:
!text "CONFIRM PASSWORD: ",0

pass_mismatch_txt:
!text "PASSWORDS DO NOT MATCH.",0

login_user_txt:
!text "USERNAME: ",0

login_pass_txt:
!text "PASSWORD: ",0

login_fail_txt:
!text "LOGIN INCORRECT.",0

login_locked_txt:
!text "TOO MANY ATTEMPTS.",0

config_saved_txt:
!text "CREDENTIALS SAVED.",0

config_loaded_txt:
!text "CREDENTIALS LOADED.",0

passwd_ok_txt:
!text "PASSWORD CHANGED.",0

config_fname_r:
!text "CONFIG,S,R",0

config_fname_w:
!text "@:CONFIG,S,W",0

; --- THEME text ---
theme_usage_txt:
!text "USAGE: THEME <NORMAL, DARK, GREEN>",13,0

theme_cur_txt:
!text "CURRENT THEME: ",0

theme_set_txt:
!text "THEME SET TO: ",0

theme_name_normal:
!text "NORMAL",0

theme_name_dark:
!text "DARK",0

theme_name_green:
!text "GREEN",0

; --- THEME state ---
theme_mode: !byte 0    ; 0=NORMAL, 1=DARK, 2=GREEN