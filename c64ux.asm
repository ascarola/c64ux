; ============================================================
;  C64UX — Unix-inspired shell for the Commodore 64
;
;  Version:    v0.1
;  Author:     Anthony Scarola <a@scarolas.com>
;  Date:       2026-01-26
;
;  Description:
;    A small UNIX-like command shell and RAM-resident filesystem
;    written entirely in 6502 assembly for the Commodore 64.
;
;    Features include a command parser, in-memory filesystem,
;    file metadata (size/date/time), session user/date/time,
;    and an auto-advancing clock based on the KERNAL jiffy timer.
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

; ------------------------------------------------------------
; 3) KERNAL entry points
; ------------------------------------------------------------
CHROUT = $FFD2
CHRIN  = $FFCF

RDTIM  = $FFDE     ; Read jiffy clock -> A=lo, X=mid, Y=hi
SETTIM = $FFDB     ; Set jiffy clock  <- A=lo, X=mid, Y=hi

TICKS_PER_SEC = 60 ; NTSC=60, PAL=50

; ------------------------------------------------------------
; 4) Memory map / buffers
; ------------------------------------------------------------
LINEBUF = $0200
MAXLEN  = 40

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
; 7) Main entry / init
; ------------------------------------------------------------
start:
    sei
    jsr cls
    jsr banner
    jsr fs_init
    jsr setup
    cli

main_loop:
    jsr prompt
    jsr read_line
;    jsr dump_linebuf     ; <<< DEBUG: show raw bytes
    jsr exec_cmd
    jmp main_loop

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
    rts


; ------------------------------------------------------------
; prompt - print newline + prompt string (prompt_txt)
; ------------------------------------------------------------
prompt:
    lda #13
    jsr CHROUT
    ldx #0
@loop:
    lda prompt_txt,x
    beq @exit
    jsr CHROUT
    inx
    bne @loop
@exit:
    rts


; ------------------------------------------------------------
; cls - clear screen (SHIFT+CLR/HOME = PETSCII 147)
; ------------------------------------------------------------
cls:
    lda #147
    jsr CHROUT
    rts

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

    cmp #20            ; DEL (backspace) in many setups
    beq @bksp
    cmp #157           ; cursor-left (some keymaps send this)
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
    jsr setup_username
    jsr setup_date
    jsr setup_time
    jsr set_clock_from_time_str
    jsr read_clock_to_jiffies
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
    lda #13
    jsr CHROUT

    ldx #0
@p:
    lda setup_user_txt,x
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
; - Then calls inc_date_str to bump DATE_STR by 1 day
; - Updates LAST_J* to current jiffies
;
; Uses: A
; Clobbers: jlo/jmid/jhi (your existing scratch)
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
    jsr inc_date_str             ; you’ll add this next

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
    bcc @try_echo
    jsr cmd_help
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
    bcc @try_exit
    jsr cmd_uname
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
    bcc @try_clear
    jsr cmd_time
    rts

@try_clear:
    ; CLEAR?
    jsr is_clear
    bcc @unknown
    jsr cls
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

; ============================================================
; COMMAND HANDLERS (cmd_*)
; ============================================================

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
    ldy #0
rm_copy:
    lda LINEBUF,x
    beq rm_search
    cmp #$20
    beq rm_search
    sta NAMEBUF,y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne rm_copy

    ; if token >8, skip remainder of token
rm_skip_long:
    lda LINEBUF,x
    beq rm_search
    cmp #$20
    beq rm_search
    inx
    bne rm_skip_long

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

rm_notfound:
    ldx #0
rm_nf:
    lda notfound_txt,x
    beq rm_done
    jsr CHROUT
    inx
    bne rm_nf

rm_usage:
    ldx #0
rm_us:
    lda rm_usage_txt,x
    beq rm_done
    jsr CHROUT
    inx
    bne rm_us

; --- RM scratch/state ---
rm_after_count: !byte 0
rm_tmp:         !byte 0
rm_move_lo:     !byte 0
rm_move_hi:     !byte 0

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
;   - Free Memory
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
    jsr print_free_mem_line
    rts

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

    ; write NAME into entry (8 bytes, pad with spaces)
    ldy #0

cw_name_loop:
    lda LINEBUF,x
    beq cw_name_pad
    cmp #$20
    beq cw_name_pad
    sta (DPTR_LO),y
    iny
    inx
    cpy #DIR_NAME_LEN
    bne cw_name_loop


; if name >8 chars, skip rest of token
cw_skip_long:
    lda LINEBUF,x
    beq cw_after_name
    cmp #$20
    beq cw_after_name
    inx
    bne cw_skip_long

cw_name_pad:
    lda #' '

cw_pad_loop:
    cpy #DIR_NAME_LEN
    beq cw_after_name
    sta (DPTR_LO),y
    iny
    bne cw_pad_loop

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

is_clear:
    lda LINEBUF,x
    cmp #'C'
    bne @no
    lda LINEBUF+1,x
    cmp #'L'
    bne @no
    lda LINEBUF+2,x
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
    cmp #$20      ; space
    bne @no
@yes:
    sec
    rts
@no:
    clc
    rts

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

    lda #<help_txt
    sta ZPTR_LO
    lda #>help_txt
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

    jsr update_day_rollover      ; <-- ADD THIS

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

    jsr update_day_rollover      ; <-- ADD THIS

    ; You can reuse the jlo/jmid/jhi that update_day_rollover already read,
    ; but keeping your existing calls is fine.
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
; (Used by MEM and can be reused by UNAME, etc.)
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
DATE_STR: !fill DATE_MAX, 0
TIME_STR: !fill TIME_MAX, 0

; --- filesystem directory ---
DIR_COUNT:   !byte 0
DIR_TABLE:   !fill (DIR_MAX*DIR_ENTRY_SIZE), 0    ; 240 bytes when DIR_ENTRY_SIZE=30

; --- scratch / temp ---
tmp_len_lo:  !byte 0
tmp_len_hi:  !byte 0

; --- heap pointer (next free byte in FS heap area) ---
fs_heap_lo: !byte <FS_HEAP_BASE
fs_heap_hi: !byte >FS_HEAP_BASE

; --- reusable 8-char name buffer (padded with spaces) ---
NAMEBUF: !fill DIR_NAME_LEN, ' '

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
; TEXT CONSTANTS (PETSCII / SCREEN OUTPUT)
; ============================================================

; -------------------------
; Text (UPPERCASE only)
; -------------------------

; --- Banners / prompts ---
banner_txt:
!text 13,"  **** C64UX V0.1 BY A. SCAROLA ****",13,"      TYPE 'HELP' FOR ASSISTANCE",13,0

setup_user_txt:
!text "--------------",13,"INITIAL SETUP:",13,"--------------",13,"USERNAME (MAX 15): ",0

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

prompt_txt:
!text "C64UX % ",0

help_txt:
!text "COMMANDS:",13
!text "  CAT    - PRINT FILE",13
!text "  CLEAR  - CLEAR SCREEN",13
!text "  DATE   - SHOW CURRENT DATE",13
!text "  ECHO   - PRINT TEXT",13
!text "  EXIT   - RETURN TO BASIC",13
!text "  HELP   - THIS HELP",13
!text "  LS     - LIST FILES",13
!text "  MEM    - SHOW FREE MEMORY",13
!text "  RM     - DELETE FILE",13
!text "  STAT   - FILE INFO",13
!text "  TIME   - SHOW CURRENT TIME",13
!text "  UNAME  - SYSTEM INFO",13
!text "  WHOAMI - SHOW USERNAME",13
!text "  WRITE  - CREATE FILE",13,0

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

; --- Errors / usage ---
notfound_txt:
!text "FILE NOT FOUND",0

cat_usage_txt:
!text "USAGE: CAT FILENAME",0

rm_usage_txt:
!text "USAGE: RM FILENAME",0

stat_usage_txt:
!text "USAGE: STAT FILENAME",0

usage_txt:
!text "USAGE: WRITE FILENAME TEXT",0

; --- Misc ---
uname_txt:
!text "C64UX 0.1 6502 C64",0

whoami_txt:
!text "USERNAME: ",0

ok_txt:
!text "OK",0

full_txt:
!text "DIRECTORY IS FULL",0

unk_txt:
!text "UNKNOWN COMMAND - TYPE 'HELP'",13,0

; Month lengths for non-leap years (Jan..Dec)
month_len:
    !byte 31,28,31,30,31,30,31,31,30,31,30,31

mem_free_txt:
!text "MEM FREE: ",0

dbg_txt:
!text "BUF:",0
