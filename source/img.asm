
;  img.asm
;
;  Copyright (C) 2026 Samuel Peciar
;
;  This program is free software: you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, either version 3 of the License, or
;  any later version.



; ------
; MACROS
; ------

bits 32
org 0 ; not actually loaded at 0x00000000, but this gives us simple relative label offsets

; NULL is usually defined as 0, but in our case that'd be a bad idea
; since it'd make a lot of section-relative pointers look invalid despite being valid
; for instance a dictionary entry's link pointer being 0 shouldn't mean "invalid",
; but rather simply "the first entry" (ie. offset of 0), on the other hand 0xffffffff
; is actually always an invalid address on a 32-bit machine.
%define NULL 0xffffffff

; align to logical block
%define ALIGN_LBLK align 512, db 0

; the start of the image header
%define IMG_START_LBA 64

; bootloader gives us our boot information here
%define RUNTIME_HEADER 0x7c00

; size of a word descriptor struct
%define WDDESC_SIZE 12

; generate image header from sections
%macro HEADER 1-*
    ALIGN_LBLK

    ; IHeaderDesc
    dq 0x20474d4920464946 ; "FIF IMG "
    dd 1 ; revision 1
    dd 0 ; crc32sum, this gets added by a postprocessing script
         ; since NASM's preprocessor can't really do that

    times 240 db 0 ; IHeaderDesc is 16 bytes

    ; IHeader

    dd %1 ; entry point word descriptor index
    dd %0 - 1 ; number of section descriptors

    %rotate 1 ; discard wd idx arg

    ; loop through sections and emit the descriptors
    %rep %0 -1
        SECTION_DESC %1
        %rotate 1
    %endrep
%endmacro

; generate the PData struct from a section
%macro SECTION_DESC 1
    %define section_start ((%1 %+ _START) - $$)
    %define section_end ((%1 %+ _END) - $$)
    dd IMG_START_LBA + (section_start / 512)
    dd (section_end - section_start) / 512
%endmacro

; start an image section
%macro START_SECTION 1
    ALIGN_LBLK
    %define section_name %1 ; not context-local since DICT_ENTRY needs to reference it
    section_name %+ _START:
%endmacro

; end an image section
%macro END_SECTION 0
    ALIGN_LBLK
    section_name %+ _END:
%endmacro

; emit a WordImpl struct for a primitive word,
; args are the name of the word's code label, and initial refcount
%macro IMPL_PRIM 2
    %push impl_ctx
    %$impl_start:

    dd %2
    dd (%$impl_end - $$) - (%$impl_start - $$)
    dd 0 ; no IR for primitive/anonymous words
    %1 %+ _IMPL: ; make this word's impl available to other macros
%endmacro

%macro END_IMPL 0
    %$impl_end:
    %pop
%endmacro

; emit a WordDesc struct for a chosen impl
%macro WORD_DESC 2
    %1 %+ _WD:
    dd (%1 %+ _IMPL) - IMPL_TABLE_START ; target
    dd 0 ; new words start with generation 0
    dd %2 ; flags
%endmacro

; latest dict entry in assembler, NOT A RUNTIME VARIABLE!
%push dict_ctx
%define %$LATEST NULL

; emit a dictionary entry,
; args are word label and external name
%macro DICT_ENTRY 2
    %define %%wd_offset ((%1 %+ _WD - $$) - (WD_TABLE_START - $$))
    %ifdef DEBUG
        %warning Index of %1 %+ _WD is: %eval(%%wd_offset / WDDESC_SIZE)
    %endif
    %strlen len %2

    %%entry:

    dd %$LATEST
    dd %%wd_offset / WDDESC_SIZE ; wd_idx field
    dd 0
    dd len
    db %2

    %define %$LATEST (%%entry - DICT_START)
    %ifdef DEBUG
        %warning Setting LATEST to %eval(%$LATEST)
    %endif
%endmacro

; call a word descriptor
%macro FCALL 1
    %define %%wd_offset ((%1 %+ _WD - $$) - (WD_TABLE_START - $$))
    call dword [edi + %%wd_offset]
%endmacro

; get the word descriptor index of a label
%define WDIDX(x) (((x %+ _WD - $$) - (WD_TABLE_START - $$)) / 12)

%define TRUE -1
%define FALSE 0

; push a value to the data stack
%macro DPUSH 1
    mov dword [ebp], esi
    mov esi, %1
    add ebp, 4
%endmacro

; pop a value from the data stack
%macro DPOP 0
    sub ebp, 4
    mov esi, dword [ebp]
%endmacro

; swap TOS and NOS
%macro DSWAP 0
    xchg esi, [ebp - 4]
%endmacro

; duplicate the TOS
%macro DDUP 0
    mov dword [ebp], esi
    add ebp, 4
%endmacro

; pop a value from the data stack into a specific register
%macro DPOPR 1
    mov %1, esi
    sub ebp, 4
    mov esi, dword [ebp]
%endmacro

; wait for approximately 1 microsecond by writing 0 to port 0x80
%macro IO_WAIT 0
    DPUSH eax
    xor al, al
    out 0x80, al
    DPOPR eax
%endmacro

; pic io ports
%define mPICc 0x20
%define mPICd 0x21

%define sPICc 0xa0
%define sPICd 0xa1

; where we'll map the PICs
%define mPIC_offset 0x20
%define sPIC_offset 0x28

; shamelessly copied from osdev.org, i have no idea what an ICW is
%define ICW1_ICW4 0x01 ; Indicates that ICW4 will be present
%define ICW1_SINGLE	0x02 ; Single (cascade) mode
%define ICW1_INTERVAL4 0x04 ; Call address interval 4 (8)
%define ICW1_LEVEL 0x08 ; Level triggered (edge) mode
%define ICW1_INIT 0x10 ; Initialization - required!

%define ICW4_8086 0x01 ; 8086/88 (MCS-80/85) mode
%define ICW4_AUTO 0x02 ; Auto (normal) EOI
%define ICW4_BUF_SLAVE 0x08 ; Buffered mode/slave
%define ICW4_BUF_MASTER 0x0C ; Buffered mode/master
%define ICW4_SFNM 0x10 ; Special fully nested (not)

%define CASCADE_IRQ 2

; note, remember to always send EOI to master PIC when handling slave PIC interrupt,
; even if it's a spurious IRQ
%define PIC_EOI 0x20

; ps/2 controller stuff

; ports
%define PS2_DATA 0x60
%define PS2_STATUS 0x64
%define PS2_COMMAND 0x64

; responses
%define PS2_SELFTEST_PASSED 0x55
%define PS2_KBD_SELFTEST_PASSED 0xaa
%define PS2_KBD_ECHO 0xee
%define PS2_KBD_ACK 0xfa
%define PS2_KBD_RESEND 0xfe
%define PS2_KBD_SET 0xf0

; commands
%define PS2_TEST 0xaa
%define PS2_KBD_RESET 0xff
%define PS2_KBD_SCANOFF 0xf5
%define PS2_KBD_SCANON 0xf4

%define PS2_READ_CFG 0x20
%define PS2_WRITE_CFG 0x60

%define PS2_TEST_A 0xab
%define PS2_ENABLE_A 0xae
%define PS2_DISABLE_A 0xad

%define PS2_TEST_B 0xa9
%define PS2_ENABLE_B 0xa8
%define PS2_DISABLE_B 0xa7

; maximum amount of allowed 0xfe (RESEND) responses
; before we assume a command is unsupported/failed
%define PS2_KBD_MAX_RETRIES 10

; maximum amount of times we perform a port read while waiting for a response
; before concluding the ps/2 controller is bricked
%define PS2_TIMEOUT 1000

%macro PS2_WAIT_IBF 0 ; wait until a command is processed
    %%wait:
        in al, PS2_STATUS
        test al, 1 << 1
        jnz %%wait
%endmacro

%macro PS2_WAIT_OBF 0 ; wait until a response byte is available
    %%wait:
        in al, PS2_STATUS
        test al, 1 << 0
        jz %%wait
%endmacro

; send a byte to ps/2 keyboard and wait for ACK, resending if it is not received
%macro PS2_KBD_COMMAND 1
    mov edx, PS2_KBD_MAX_RETRIES
    %%reset:
    cmp edx, 0
    je .fail
    PS2_WAIT_IBF
    mov al, %1
    out PS2_DATA, al
    %%response:
    PS2_WAIT_OBF
    in al, PS2_DATA
    cmp al, PS2_KBD_ACK
    je %%done
    cmp al, PS2_KBD_RESEND
    je %%resend
        jmp %%response
    %%resend:
        dec edx
        jmp %%reset
    %%done:
%endmacro

; flush the output buffer
%macro PS2_FLUSH_BUF 0
    %%flush:
        in al, PS2_STATUS
        test al, 1 << 0
        jz %%flushed

        in al, PS2_DATA ; read and discard
        jmp %%flush
    %%flushed:
%endmacro

; macros for making sparse constant arrays, used for mapping scancodes to keycodes
; start mapping indices in a sparse array to values
%macro START_MAPPING 1
    %push map_ctx
    %$map:
    %assign %$map_len %1
%endmacro

; stop mapping indices to values
%macro STOP_MAPPING 0
    times ((%$map + %$map_len) - $) db 0
    %pop
%endmacro

; map a specific index in the current map to a value
%macro MAP_IDX 2
    times (%1 - ($ - %$map)) db 0
    db %2
%endmacro

%macro ISR_STACK_PIVOT 0
    xchg eax, [0x7c20]
    xchg esp, [eax + (isr_return_stack - GVCT_START)]
    xchg ebp, [eax + (isr_data_stack - GVCT_START)]
    xchg eax, [0x7c20]
%endmacro

; keyboard driver states
%define KBD_DRVR_NEUTRAL 0x00 ; default state, can move to EXT, BRK, or PAUSE1 from here depending on input
%define KBD_DRVR_EXT 0x01 ; after receiving 0xe0 in NEUTRAL state, can move to EXT_BRK or back to NEUTRAL, emitting a key event
%define KBD_DRVR_BRK 0x02 ; after receiving 0xf0 in NEUTRAL state, moves back to NEUTRAL and emits a key event
%define KBD_DRVR_EXT_BRK 0x03 ; after receiving 0xf0 in EXT state, moves back to NEUTRAL and emits a key event
                              ; note, if the received scancode is 0x12 or 0x59 we don't emit
                              ; a key event

; after receiving 0xe1, each of these states is another byte to skip,
%define KBD_DRVR_PAUSE1 0x04
%define KBD_DRVR_PAUSE2 0x05
%define KBD_DRVR_PAUSE3 0x06
%define KBD_DRVR_PAUSE4 0x07
%define KBD_DRVR_PAUSE5 0x08
%define KBD_DRVR_PAUSE6 0x09
%define KBD_DRVR_PAUSE7 0x0a ; skip one last byte and emit the pause keycode

%define KBD_DRVR_ERR 0x0b ; error state, we get here if either:
                          ; a) a keycode is about to be emitted for key 0 (unmapped key)
                          ; b) an unexpected byte is received during one of the PAUSE states
                          ; in this state all received bytes are discarded, key event consumers
                          ; should check the driver state whenever the ring buffer is empty to decide
                          ; whether to crash or to wait for more input, alternatively you can clear
                          ; the scancode buffer and set this variable back to NEUTRAL to try to restart
                          ; the driver

; ----
; CODE
; ----

HEADER 0, WD_TABLE, IMPL_TABLE, DICT, GVCT

; word implementation table
START_SECTION IMPL_TABLE
    IMPL_PRIM INIT, 1
        mov eax, [0x7c20]

        ; set tick counter to 0 since we just booted
        mov dword [eax + (tkc_low - GVCT_START)], 0
        mov dword [eax + (tkc_high - GVCT_START)], 0

        ; load GDT (technically we know the bootloader gives us a valid one since we are
        ; executing in protected mode, but we don't want to rely on the bootloader environment)
        add dword [eax + (gdtr - GVCT_START) + 2], eax
        lgdt [eax + (gdtr - GVCT_START)]
        sub dword [eax + (gdtr - GVCT_START) + 2], eax

        ; reload CS
        mov ebx, [0x7c10] ; impl table start
        add [eax + (init_jmpptr - GVCT_START)], ebx
        jmp far [eax + (init_jmpptr - GVCT_START)]
        init_reload_cs:
        sub [eax + (init_jmpptr - GVCT_START)], ebx

        ; and the other segment registers
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov fs, ax
        mov gs, ax

        ; attempt to initialize kernel arena, if
        ; we fail here then we just print "OOM",
        ; wait for a bit so the user can see it, and then crash
        DPUSH 64 * 1024
        FCALL KARENA_INIT
        DPOPR ebx
        mov eax, [0x7c20]
        test ebx, ebx
        jnz .fail

        ; initialize the core runtime stacks
        DPUSH 32 * 1024
        FCALL KRESERVE
        DPOPR ebx
        cmp ebx, -1
        je .fail

        ; core runtime's data and return stacks
        mov eax, [0x7c20]

        mov ebp, ebx
        mov [eax + (data_stack_base - GVCT_START)], ebx
        add ebx, 16 * 1024
        mov [eax + (return_stack_base - GVCT_START)], ebx
        mov esp, ebx

        ; interrupt execution context's stacks
        mov [eax + (isr_data_stack - GVCT_START)], ebx
        add ebx, 16 * 1024
        mov [eax + (isr_return_stack - GVCT_START)], ebx


        ; initialize terminal
        DPUSH 40 - ((greeting_len - greeting) / 2) ; our greeting message should appear in the top-middle
        DPUSH 0x17 ; cursor attr
        DPUSH 0x07 ; attribute byte
        FCALL CONSOLE_INIT
        DPOPR ebx
        test ebx, ebx
        jnz .fail

        ; print greeting message
        mov eax, [0x7c20]
        mov ebx, [eax + (greeting_len - GVCT_START)]
        lea eax, [eax + (greeting - GVCT_START)]
        DPUSH eax
        DPUSH ebx
        FCALL PUTS

        ; print out kernel arena memory
        mov eax, [0x7c20]
        mov ebx, [eax + (karena_entry - GVCT_START)]

        DPUSH 10
        DPUSH 13
        DPUSH [ebx + 8]
        add esi, [ebx]
        DPUSH [ebx + 12]
        add esi, [ebx + 4]
        DPUSH '-'
        DPUSH [ebx]
        DPUSH [ebx + 4]
        DPUSH 'x'
        DPUSH '0'
        FCALL PUTC
        FCALL PUTC
        FCALL PUTH
        FCALL PUTH
        FCALL PUTC
        FCALL PUTH
        FCALL PUTH
        FCALL PUTC
        FCALL PUTC

        ; initialize keyboard controller and driver
        FCALL KEYBOARD_INIT
        DPOPR ebx
        test ebx, ebx
        jnz .fail

        ; initialize interrupt subsystem so we can bind service routines
        FCALL INT_INIT

        ; start binding ISRs

        ; panic on double faults and NMIs since those are generally unrecoverable
        ; (NMIs usually get sent for RAM errors and double faults when we made a fuckup somewhere and didn't handle it)
        DPUSH WDIDX(PANIC)
        DPUSH 0
        DPUSH 0x02 ; #NMI
        FCALL SET_INT

        DPUSH WDIDX(PANIC)
        DPUSH 0
        DPUSH 0x08 ; #DF
        FCALL SET_INT

        ; bind timer handler
        DPUSH WDIDX(TIMER_INT)
        DPUSH 0
        DPUSH 0x20 ; IRQ 0
        FCALL SET_INT

        ; bind keyboard handler
        DPUSH WDIDX(KEYBOARD_INT)
        DPUSH 0
        DPUSH 0x21 ; IRQ 1
        FCALL SET_INT

        ; unmask IRQ 0 and 1 in the PIC since those are the only ones we handle
        in al, mPICd
        and al, ~((1 << 0) | (1 << 1))
        out mPICd, al

        mov eax, [0x7c20]
        mov ebx, [eax + (initmsg_len - GVCT_START)]
        lea eax, [eax + (initmsg - GVCT_START)]
        DPUSH eax
        DPUSH ebx
        FCALL PUTS

        ; finally, enter the main loop
        FCALL KMAIN

        ; go here if any of the initial driver init routines
        ; or core runtime allocations fail
        .fail:
            FCALL PANIC
    END_IMPL

    ; main loop
    IMPL_PRIM KMAIN, 1
        ; a simple superloop that calls all of the work handlers which have pending work

        mov eax, [0x7c20]
        .main_loop:
            test dword [eax + (pending_work - GVCT_START)], 1 << 0
            jz .skip_0

            DPUSH eax
            DPUSH ebx
            DPUSH ecx
            DPUSH edx
            FCALL TIMER_HOOK
            DPOPR edx
            DPOPR ecx
            DPOPR ebx
            DPOPR eax
            .skip_0:

            test dword [eax + (pending_work - GVCT_START)], 1 << 1
            jz .skip_1

            DPUSH eax
            DPUSH ebx
            DPUSH ecx
            DPUSH edx
            FCALL KEYBOARD_DRIVER
            DPOPR edx
            DPOPR ecx
            DPOPR ebx
            DPOPR eax
            .skip_1:

            test dword [eax + (pending_work - GVCT_START)], 1 << 2
            jz .skip_2

            DPUSH eax
            DPUSH ebx
            DPUSH ecx
            DPUSH edx
            FCALL TERMINAL_DRIVER
            DPOPR edx
            DPOPR ecx
            DPOPR ebx
            DPOPR eax
            .skip_2:

            .end:
            cli
            cmp dword [eax + (pending_work - GVCT_START)], 0
            jne .work

            .no_work:
            sti
            hlt
            jmp .main_loop

            .work:
            sti
            jmp .main_loop
    END_IMPL

    ; timer hook, this function really just exists to reserve the wd idx,
    ; so that users can replace it interactively to temporarily make something happen
    ; on every timer tick, this implementation just increments the top-right of the screen,
    ; serving as a kind of OS "heartbeat" so you know if it actually stalled or is just waiting
    IMPL_PRIM TIMER_HOOK, 1
        mov eax, [0x7c20]
        .loop:
            cli
                test dword [eax + (pending_work - GVCT_START)], 1 << 0
                jz .end
            sti

            inc word [0xb8000 + 79*2]
            and dword [eax + (pending_work - GVCT_START)], ~(1 << 0)
            jmp .loop
        .end:
        sti
        ret
    END_IMPL

    ; process scan code into key events and put them into the main keyboard consumer's ring buffer,
    ; a key event in this system is an 8-bit integer consisting of a 7-bit keycode from 1 to 127 (0 is reserved),
    ; and a top flag bit that is clear for key *presses* and set for key *releases*.
    IMPL_PRIM KEYBOARD_DRIVER, 1
        .dequeue:
            mov eax, [0x7c20]

            ; try dequeueing a scancode into edx,
            ; if it fails then we re-initialize the buffer in the hopes the problem fixes itself
            ; (i mean what am i supposed to do, stop the driver? i need the driver.)
            cli
                DPUSH [eax + (kbd_driver_scan_buf - GVCT_START)]
                DDUP

                FCALL RING_TRY_DEQUEUE

                DPOPR eax
                test eax, eax
                jz .buf_good
                cmp eax, 2
                je .buf_empty

                .buf_error:
                    DPOP
                    FCALL RING_REINIT
                    mov eax, [0x7c20]
                    jmp .end_dequeue

                .buf_empty:
                    DPOP
                    DPOP
                    jmp .end_dequeue

                .buf_good:
                    DPOPR edx
                    DPOP
            sti

            mov eax, [0x7c20]

            ; dispatch to one of the cases based on the state
            movzx ebx, byte [eax + (kbd_driver_state - GVCT_START)]

            ; if invalid state, treat it as the error state
            cmp ebx, 0x0b
            ja .case_err

            ; do a lil' switch statement here
            call .get_eip
            .get_eip:
            pop ecx

            add ecx, [ecx + (.jmp_table - .get_eip) + ebx*4] ; finally, add the offset of the case we branch to
            jmp ecx

            align 4
            .jmp_table:
                dd .case_neutral - .get_eip
                dd .case_ext - .get_eip
                dd .case_brk - .get_eip
                dd .case_extbrk - .get_eip
                dd .case_pause1 - .get_eip
                dd .case_pause2 - .get_eip
                dd .case_pause3 - .get_eip
                dd .case_pause4 - .get_eip
                dd .case_pause5 - .get_eip
                dd .case_pause6 - .get_eip
                dd .case_pause7 - .get_eip
                dd .case_err  - .get_eip

            .case_neutral:
                cmp edx, 0x00
                je .dequeue
                cmp edx, 0xe1
                je .case_neutral_pause
                cmp edx, 0xe0
                je .case_neutral_ext
                cmp edx, 0xf0
                je .case_neutral_brk

                .case_neutral_emit:
                    movzx edx, byte [eax + (keycode_map - GVCT_START) + edx]
                    test edx, edx
                    jz .case_err

                    ; alter keyboard state
                    mov ebx, [eax + (kbd_driver_kbd_state - GVCT_START)]
                    bts dword [ebx], edx

                    call near .emit_keycode
                    jmp .dequeue

                .case_neutral_ext:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_EXT
                    jmp .dequeue

                .case_neutral_brk:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_BRK
                    jmp .dequeue

                .case_neutral_pause:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE1
                    jmp .dequeue
            .case_ext:
                cmp edx, 0xf0
                je .case_ext_brk
                cmp edx, 0x12 ; fake left-shift
                je .case_ext_discard
                cmp edx, 0x59 ; fake right-shift
                je .case_ext_discard

                .case_ext_emit:
                    ; edx = keycode, if we get 0 (meaning the key is unmapped) then we error
                    movzx edx, byte [eax + (keycode_map - GVCT_START) + edx + 256]
                    test edx, edx
                    jz .case_err

                    ; alter keyboard state
                    mov ebx, [eax + (kbd_driver_kbd_state - GVCT_START)]
                    bts dword [ebx], edx

                    call near .emit_keycode
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                    jmp .dequeue

                ; discard key
                .case_ext_discard:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                    jmp .dequeue

                .case_ext_brk:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_EXT_BRK
                    jmp .dequeue
            .case_brk:
                ; edx = keycode, if we get 0 (meaning the key is unmapped) then we error
                movzx edx, byte [eax + (keycode_map - GVCT_START) + edx]
                test edx, edx
                jz .case_err

                ; alter keyboard state
                mov ebx, [eax + (kbd_driver_kbd_state - GVCT_START)]
                btr dword [ebx], edx

                or edx, 1 << 7 ; mark as key release
                call near .emit_keycode
                mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                jmp .dequeue
            .case_extbrk:
                cmp edx, 0x12 ; fake left shift
                je .case_extbrk_discard
                cmp edx, 0x59 ; fake right shift
                je .case_extbrk_discard

                .case_extbrk_emit:
                    ; edx = keycode, if we get 0 (meaning the key is unmapped) then we error
                    movzx edx, byte [eax + (keycode_map - GVCT_START) + edx + 256]
                    test edx, edx
                    jz .case_err

                    ; alter keyboard state
                    mov ebx, [eax + (kbd_driver_kbd_state - GVCT_START)]
                    btr dword [ebx], edx

                    or edx, 1 << 7 ; mark as key release
                    call near .emit_keycode
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                    jmp .dequeue

                .case_extbrk_discard:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                    jmp .dequeue
            .case_pause1:
                cmp edx, 0x14
                jne .case_err

                .case_pause1_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE2
                    jmp .dequeue
            .case_pause2:
                cmp edx, 0x77
                jne .case_err

                .case_pause2_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE3
                    jmp .dequeue
            .case_pause3:
                cmp edx, 0xe1
                jne .case_err

                .case_pause3_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE4
                    jmp .dequeue
            .case_pause4:
                cmp edx, 0xf0
                jne .case_err

                .case_pause4_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE5
                    jmp .dequeue
            .case_pause5:
                cmp edx, 0x14
                jne .case_err

                .case_pause5_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE6
                    jmp .dequeue
            .case_pause6:
                cmp edx, 0xf0
                jne .case_err

                .case_pause6_good:
                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_PAUSE7
                    jmp .dequeue
            .case_pause7:
                cmp edx, 0x77
                jne .case_err

                .case_pause7_good:
                    ; emit pause press and release event
                    mov edx, 0x7d
                    call near .emit_keycode
                    mov edx, 0x7d | (1 << 7)
                    call near .emit_keycode

                    mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL
                    jmp .dequeue
            .case_err:
                ; we set the state here since this branch doubles as both the error state,
                ; and as the way of *entering* the error state
                mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_ERR

                inc word [0xb8000]

                ; the keyboard consumer should be aware that the driver has crashed,
                ; so we make it runnable
                movzx ebx, byte [eax + (kbd_driver_consumer_task - GVCT_START)]
                bts dword [eax + (pending_work - GVCT_START)], ebx
                jmp .dequeue

        .end_dequeue:
        and dword [eax + (pending_work - GVCT_START)], ~(1 << 1) ; clear pending work bit for IRQ 1
        sti
        ret

        ; small helper for emitting a keycode, assumes edx = keycode and eax = GVCT_START
        .emit_keycode:
            ; set pending work for keycode consumer
            movzx ebx, byte [eax + (kbd_driver_consumer_task - GVCT_START)]
            bts dword [eax + (pending_work - GVCT_START)], ebx

            ; try to enqueue the scancode
            DPUSH edx
            DPUSH dword [eax + (kbd_driver_key_buf - GVCT_START)]
            FCALL RING_TRY_ENQUEUE
            DPOPR ecx
            ; restore eax since we made a function call
            mov eax, [0x7c20]

            test ecx, ecx
            jz .emit_keycode_end
            cmp ecx, 1
            jne .emit_keycode_err

            .emit_keycode_overflow:
                mov edx, [eax + (kbd_driver_key_buf - GVCT_START)]
                mov word [edx + 6], 1

            .emit_keycode_err:
                mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_ERR

            .emit_keycode_end:
                ret
    END_IMPL

    ; consume keycodes from the keyboard driver,
    ; decode into ascii characters, and echo them
    ; (temporary, in the future this should also fill up a line buffer,
    ; and the echo functionality should be optional)
    IMPL_PRIM TERMINAL_DRIVER, 1
        .loop:
            mov eax, [0x7c20]
            DPUSH dword [eax + (kbd_driver_key_buf - GVCT_START)]

            ; the only error for this is overflow, and we're fine with dropping
            ; characters if we get called too infrequently, so we'll just clear
            ; the error field and continue
            mov word [esi + 6], 0

            FCALL RING_TRY_DEQUEUE
            mov eax, [0x7c20] ; restore eax after function call
            DPOPR ecx
            DPOPR ebx

            test ecx, ecx
            jz .dequeued

            ; if the buffer is empty, check if the driver is running
            .buf_empty:
            cmp byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_ERR
            jne .end
                ; reset driver state on error
                mov byte [eax + (kbd_driver_state - GVCT_START)], KBD_DRVR_NEUTRAL

                ; clear scancode buf
                cli
                    DPUSH eax
                    DPUSH ebx

                    DPUSH dword [eax + (kbd_driver_scan_buf - GVCT_START)]
                    FCALL RING_REINIT

                    DPOPR ebx
                    DPOPR eax
                sti

                ; reset keyboard state
                mov ebx, [eax + (kbd_driver_kbd_state - GVCT_START)]
                mov dword [ebx], 0
                mov dword [ebx + 4], 0
                mov dword [ebx + 8], 0
                mov dword [ebx + 12], 0
                jmp .end

            .dequeued:

            ; ignore key release events
            test ebx, (1 << 7)
            jnz .loop

            mov edx, [eax + (kbd_driver_kbd_state - GVCT_START)]
            ; check if shift and/or altgr are pressed
            test dword [edx + (0x0e / 32 * 4)], 1 << (0x0e % 32) ; left shift
            setnz cl
            test dword [edx + (0x57 / 32 * 4)], 1 << (0x57 % 32) ; right alt
            setnz ch

            cmp cx, (1 << 0 | 1 << 8)
            je .shift_alt
            cmp cx, (1 << 8)
            je .alt
            cmp cx, (1 << 0)
            je .shift

            ; depending on modifier keys, index table differently
            .normal:
                movzx ebx, byte [eax + (char_map - GVCT_START) + ebx*4]
                jmp .handle_key

            .shift_alt:
                movzx ebx, byte [eax + (char_map - GVCT_START) + ebx*4 + 3]
                jmp .handle_key

            .alt:
                movzx ebx, byte [eax + (char_map - GVCT_START) + ebx*4 + 2]
                jmp .handle_key

            .shift:
                movzx ebx, byte [eax + (char_map - GVCT_START) + ebx*4 + 1]
                jmp .handle_key

            .handle_key:
                test ebx, ebx
                jz .unmapped
                cmp ebx, 1 ; keycodes mapped to SOH are deliberately meant to be ignored
                je .loop

                cmp ebx, 8 ; keycodes mapped to backspace produce "\b \b" instead
                je .backspace
                cmp ebx, 10 ; keycoes mapped to newline produce crlf instead
                je .newline

                ; echo key
                DPUSH ebx
                FCALL PUTC

                ; todo: actually add the key to some form of line buffer
                jmp .loop

            ; handle unmapped key, for this we just print '^?' to the screen
            .unmapped:
                DPUSH '?'
                DPUSH '^'
                FCALL PUTC
                FCALL PUTC

                ; todo: add these fake characters to the line buffer
                jmp .loop

            .newline:
                FCALL TERM_CR
                FCALL TERM_LN

                ; todo: add these fake characters to the line buffer
                jmp .loop

            .backspace:
                FCALL TERM_BACKSPACE
                DPUSH 32
                FCALL PUTC
                FCALL TERM_BACKSPACE

                ; todo, once line buffering exists this should also remove a character from the buffer
                jmp .loop
        .end:
        and dword [eax + (pending_work - GVCT_START)], ~(1 << 2) ; clear pending work for terminal
        ret
    END_IMPL

    ; to be used in case of unrecoverable errors, this function will:
        ; disable interrupts (so that nothing can stop it)
        ; fill the screen with the repeating strings "PANIC" and "!!!!!"
        ; hang for a short time (so the user can notice what happened
        ; finally, induce a triple-fault to reboot
    IMPL_PRIM PANIC, 1
        cli

        ; make it *very* noticeable that the kernel crashed
        xor ecx, ecx
        .loop:
            cmp ecx, 2000
            je .end_loop

            mov word [0xb8000 + ecx*2 + 0*2], 'P' | (0x47 << 8)
            mov word [0xb8000 + ecx*2 + 1*2], 'A' | (0x17 << 8)
            mov word [0xb8000 + ecx*2 + 2*2], 'N' | (0x47 << 8)
            mov word [0xb8000 + ecx*2 + 3*2], 'I' | (0x17 << 8)
            mov word [0xb8000 + ecx*2 + 4*2], 'C' | (0x47 << 8)

            mov word [0xb8000 + ecx*2 + 5*2], '!' | (0x17 << 8)
            mov word [0xb8000 + ecx*2 + 6*2], '!' | (0x47 << 8)
            mov word [0xb8000 + ecx*2 + 7*2], '!' | (0x17 << 8)
            mov word [0xb8000 + ecx*2 + 8*2], '!' | (0x47 << 8)
            mov word [0xb8000 + ecx*2 + 9*2], '!' | (0x17 << 8)

            add ecx, 10
            jmp .loop
        .end_loop:

        ; hang for a short time
        mov ecx, 0xfffff
        .hang:
            IO_WAIT
            loop .hang

        ; triple-fault
        int 0xff

        ; in case somehow we didn't triple-fault
        .hang_but_for_real:
            hlt
            jmp .hang_but_for_real
    END_IMPL

    ; initialize IDT, IDeT, PICs, and switch floating point errors to native mode,
    ; essentially handles everything except for binding the final ISRs, note that this
    ; does not enable interrupts, since you still need to bind your ISRs to the important
    ; IRQs and exceptions first for safety. Also, you will still need to unmask the IRQs
    ; that you want to receive.
    IMPL_PRIM INT_INIT, 1
        ; load IDT
        mov eax, [0x7c20]
        add dword [eax + (idtr - GVCT_START) + 2], eax
        lidt [eax + (idtr - GVCT_START)]
        sub dword [eax + (idtr - GVCT_START) + 2], eax

        ; initialize IDT to point to IDeT entries
        xor edx, edx
        mov ecx, 256
        .loop:
            mov ebx, eax
            add ebx, idet_start - GVCT_START
            add ebx, edx

            ; offset 0..15
            mov word [eax + (idt_start - GVCT_START) + edx], bx
            shr ebx, 16
            ; offset 16..31
            mov word [eax + (idt_start - GVCT_START) + edx + 6], bx

            ; segment selector
            mov word [eax + (idt_start - GVCT_START) + edx + 2], 0x08

            ; zero field
            mov byte [eax + (idt_start - GVCT_START) + edx + 4], 0

            ; leave gate type, DPL, and P unset

            add edx, 8
            dec ecx
            jnz .loop

        ; initialize master and slave 8259 PICs
        mov al, ICW1_INIT | ICW1_ICW4
        out mPICc, al
        IO_WAIT
        out sPICc, al
        IO_WAIT

        ; vector offsets
        mov al, mPIC_offset
        out mPICd, al
        IO_WAIT
        mov al, sPIC_offset
        out sPICd, al
        IO_WAIT

        ; tell the PICs how to cascade IRQs
        mov al, 1 << CASCADE_IRQ
        out mPICd, al
        IO_WAIT
        mov al, CASCADE_IRQ
        out sPICd, al
        IO_WAIT

        ; make them use the 8086 mode (and not 8080)
        mov al, ICW4_8086
        out mPICd, al
        IO_WAIT
        out sPICd, al

        ; mask PICs
        or al, 0xff
        out mPICd, al
        out sPICd, al

        ; make the fpu deliver errors on interrupt vector 16
        mov eax, cr0
        or eax, 0x20
        mov cr0, eax
        ret
    END_IMPL

    ; given an interrupt vector, gate type, and word descriptor index
    ; set that word idx as the interrupt handler, and set the type of the
    ; IDT entry at <interrupt_vector> to <gate_type> (0 = interrupt, -1 = trap)

    ; like calling words with FCALL, ISRs set by SET_INT can have their impl change,
    ; but mismatched generation counters are not checked (only EXECUTE checks that)
    IMPL_PRIM SET_INT, 1
        ; set eax to the GVCT base
        mov eax, [0x7c20]

        ; ebx gets the idx into the IDT and IDeT
        DPOPR ebx

        DSWAP ; swap idx and gate type

        ; set ecx to the offset of the word in the word descriptor table
        DPOPR ecx
        mov edx, ecx
        shl ecx, 3
        shl edx, 2
        add ecx, edx

        ; get gate type
        DPOPR edx
        test edx, edx
        jnz .trap
        .int:
            mov dl, 0x8e
            jmp .gate_type_known
        .trap:
            mov dl, 0x8f
        .gate_type_known:

        ; set the gate type and DPL/P of the IDT entry
        mov byte [eax + (idt_start - GVCT_START) + ebx * 8 + 5], dl
        ; set the disp32 field of the IDeT entry
        mov dword [eax + (idet_start - GVCT_START) + ebx * 8 + 2], ecx

        ret
    END_IMPL

    ; note, for now ISRs operate inside the same stack as the normal runtime,
    ; just with a large offset, this is a temporary measure, once I have a physical
    ; memory allocator I will use that at boot-time to reserve memory for separate runtime
    ; and interrupt stacks

    ; irq 0 handler, increments a tick counter
    IMPL_PRIM TIMER_INT, 1
        ; switch to interrupt execution context
        ISR_STACK_PIVOT
        pushad

        mov eax, [0x7c20]

        ; increment 64-bit tick counter
        or dword [eax + (pending_work - GVCT_START)], 1 << 0 ; set IRQ 0 pending work

        add dword [eax + (tkc_low - GVCT_START)], 1
        adc dword [eax + (tkc_high - GVCT_START)], 0

        ; end of interrupt
        mov al, PIC_EOI
        out mPICc, al

        popad
        ISR_STACK_PIVOT
        iret
    END_IMPL

    ; irq 1 handler, currently just reads the scan code, the plan is to enqueue it into a ring buffer
    IMPL_PRIM KEYBOARD_INT, 1
        ISR_STACK_PIVOT
        pushad

        ; read scan code into ebx
        in al, 0x60
        movzx ebx, al

        ; set pending work bit for keyboard driver
        mov eax, [0x7c20]
        or dword [eax + (pending_work - GVCT_START)], 1 << 1

        ; try to enqueue the scancode
        mov ecx, [eax + (kbd_driver_scan_buf - GVCT_START)]
        DPUSH ecx
        DPUSH ebx
        DPUSH ecx
        FCALL RING_TRY_ENQUEUE
        DPOPR eax
        cmp eax, 1
        jne .end

        ; mark overflow
        .overflow:
            mov word [esi + 6], 1

        ; send EOI and return
        .end:
            DPOP
            mov al, PIC_EOI
            out mPICc, al

            popad
            ISR_STACK_PIVOT
            iret
    END_IMPL

    ; initialize or reinitialize the console, args are the attribute byte to use,
    ; attribute byte to use for the cursor, and initial software cursor position
    IMPL_PRIM CONSOLE_INIT, 1
        ; disable hardware cursor since we don't use it
        mov dx, 0x3d4
        mov al, 0xa
        out dx, al

        inc dx
        mov al, 0x20
        out dx, al

        mov eax, [0x7c20]

        ; set attribute byte
        DPOPR ebx
        mov byte [eax + (console_attr - GVCT_START)], bl

        ; set cursor attr byte to normal one temporarily so CLS effectively doesn't use it
        mov byte [eax + (console_cursorattr - GVCT_START)], bl

        ; clear the screen with the new attribute byte
        FCALL CLS

        mov eax, [0x7c20] ; reload GVCT

        ; set cursor pos and display the cursor
        DPOPR ecx
        mov byte [eax + (console_cursorattr - GVCT_START)], cl
        DPOPR ebx
        mov word [eax + (console_cursor - GVCT_START)], bx
        mov byte [0xb8001 + ebx * 2], cl ; display cursor

        ; mark the terminal as the keycode consumer and initialize key buf
        DPUSH 1
        DPUSH 256
        DPUSH 256 + 20
        FCALL KRESERVE
        cmp esi, -1
        je .fail

        mov dword [eax + (kbd_driver_key_buf - GVCT_START)], esi
        mov byte [eax + (kbd_driver_consumer_task - GVCT_START)], 2

        FCALL RING_INIT
        DPUSH 0
        ret

        .fail:
            DPOP
            DPOP
            DPOP

            DPUSH -1
            ret
    END_IMPL

    IMPL_PRIM RENDER_GLYPH, 1
        ret
    END_IMPL

    IMPL_PRIM TERMINAL_INIT, 1
        ret
    END_IMPL

    ; clear the screen
    IMPL_PRIM CLS, 1
        mov eax, [0x7c20]
        mov word [eax + (console_cursor - GVCT_START)], 0 ; reset cursor

        ; copy the console's default attribute byte, and ascii whitespace into all 2000 tiles
        mov bl, byte [eax + (console_attr - GVCT_START)]
        mov edx, 0xb8000
        xor ecx, ecx
        .loop:
            cmp ecx, 4000
            je .end

            mov byte [edx + ecx], 32
            mov byte [edx + ecx + 1], bl

            add ecx, 2
            jmp .loop
        .end:

        ; set the displayed cursor
        mov bl, byte [eax + (console_cursorattr - GVCT_START)]
        mov byte [0xb8001], bl

        ret
    END_IMPL

    ; scroll the terminal back one line
    IMPL_PRIM SCROLL, 1
        ; load gvct
        mov eax, [0x7c20]

        ; set cursor to max(cursor - 80, 0), and stop displaying it on the previous location
        movzx edx, word [eax + (console_cursor - GVCT_START)]
        mov bl, byte [eax + (console_attr - GVCT_START)]
        mov byte [0xb8001 + edx * 2], bl

        cmp dx, 80
        jnb .move_cursor
            xor edx, edx
            jmp .normal
        .move_cursor:
            sub edx, 80
        .normal:
        mov word [eax + (console_cursor - GVCT_START)], dx

        ; loop over the first 24 of 25 lines and copy backwards
        xor ebx, ebx
        .copy:
            cmp ebx, 1920
            je .endcopy

            mov cx, word [0xb8000 + 80*2 + ebx*2]
            mov word [0xb8000 + ebx*2], cx

            inc ebx
            jmp .copy
        .endcopy:

        xor ebx, ebx
        .fill:
            cmp ebx, 80
            je .endfill

            mov ch, byte [eax + (console_attr - GVCT_START)]
            mov cl, 32
            mov [0xb8000 + 1920*2 + ebx*2], cx

            inc ebx
            jmp .fill
        .endfill:

        ; display cursor at new position
        movzx edx, word [eax + (console_cursor - GVCT_START)]
        mov bl, byte [eax + (console_cursorattr - GVCT_START)]
        mov byte [0xb8001 + edx * 2], bl
        ret
    END_IMPL

    ; move the cursor back one position
    IMPL_PRIM TERM_BACKSPACE, 1
        mov eax, [0x7c20]
        movzx ecx, word [eax + console_cursor - GVCT_START]
        mov bl, byte [eax + (console_attr - GVCT_START)]
        mov dl, byte [eax + (console_cursorattr - GVCT_START)]

        ; make sure that we can go backwards
        test ecx, ecx
        jnz .good
        ret

        .good:
            mov byte [0xb8001 + ecx*2], bl
            mov byte [0xb8001 + ecx*2 - 1*2], dl
            dec word [eax + (console_cursor - GVCT_START)]
            ret
    END_IMPL

    ; move the cursor back to the start of the line
    IMPL_PRIM TERM_CR, 1
        mov ebx, [0x7c20]

        ; TOS = eax / 80 * 80, eax = cursor
        movzx eax, word [ebx + (console_cursor - GVCT_START)]
        DPUSH eax
        mov ecx, 80
        xor edx, edx
        div ecx
        mul ecx

        ; move the cursor
        mov cl, byte [ebx + (console_attr - GVCT_START)]
        mov dl, byte [ebx + (console_cursorattr - GVCT_START)]
        mov byte [0xb8001 + esi*2], cl
        mov byte [0xb8001 + eax*2], dl
        mov word [ebx + (console_cursor - GVCT_START)], ax
        DPOP
        ret
    END_IMPL

    ; move the cursor down one line
    IMPL_PRIM TERM_LN, 1
        mov eax, [0x7c20]

        ; scroll if needed
        cmp word [eax + (console_cursor - GVCT_START)], 1920
        jb .after_scroll
            FCALL SCROLL
        .after_scroll:

        ; update displayed cursor
        movzx ecx, word [eax + (console_cursor - GVCT_START)]
        mov bl, byte [eax + (console_attr - GVCT_START)]
        mov dl, byte [eax + (console_cursorattr - GVCT_START)]
        mov byte [0xb8001 + ecx*2], bl
        mov byte [0xb8001 + ecx*2 + 80*2], dl

        ; update saved cursor
        add word [eax + (console_cursor - GVCT_START)], 80
        ret
    END_IMPL

    ; print a character to the console
    IMPL_PRIM PUTC, 1
        mov eax, [0x7c20]

        cmp esi, 8 ; \b
        je .backspace
        cmp esi, 13 ; \r
        je .cr
        cmp esi, 10 ; \n
        je .ln

        ; scroll first if needed
        cmp word [eax + (console_cursor - GVCT_START)], 1999 ; since the cursor is one ahead of the text we do 1999 instead of 2000
        jb .after_scroll
        FCALL SCROLL
        .after_scroll:

        ; print char
        .char:
            mov eax, [0x7c20]

            ; load values
            movzx ecx, word [eax + (console_cursor - GVCT_START)]
            xor ebx, ebx
            mov bh, byte [eax + (console_attr - GVCT_START)] 
            mov dl, byte [eax + (console_cursorattr - GVCT_START)]
            or esi, ebx

            ; display character and new cursor
            mov word [0xb8000 + ecx*2], si
            mov byte [0xb8001 + ecx*2 + 1*2], dl

            inc word [eax + (console_cursor - GVCT_START)]
            DPOP
            ret

        ; escape sequences
        .ln:
            FCALL TERM_LN
            DPOP
            ret

        .cr:
            FCALL TERM_CR
            DPOP
            ret

        .backspace:
            FCALL TERM_BACKSPACE
            DPOP
            ret
    END_IMPL

    ; print a string to the console, arguments are length and strptr
    IMPL_PRIM PUTS, 1
        .loop:
            cmp esi, 0
            je .end

            ; push and print char
            mov eax, [ebp - 4]
            movzx eax, byte [eax]
            DPUSH eax
            FCALL PUTC

            ; move cursors
            inc dword [ebp - 4]
            dec esi
            jmp .loop
        .end:
        DPOP
        DPOP
        ret
    END_IMPL

    ; print a 32-bit unsigned hex integer, does not print the leading '0x' or a trailing '\n'
    IMPL_PRIM PUTH, 1
        mov ecx, 8
        .loop:
            rol esi, 4
            mov eax, esi
            and eax, 0xf

            cmp eax, 10
            jb .decimal

            .hex:
                lea eax, [eax + 'a' - 10]
                jmp .tail

            .decimal:
                lea eax, [eax + '0']

            .tail:
            DPUSH ecx
            DPUSH eax
            FCALL PUTC
            DPOPR ecx

            dec ecx
            jnz .loop
        DPOP
        ret
    END_IMPL

    ; initialize the ps/2 controller and make sure the keyboard is using scan code set 2,
    ; note that this assumes the second ps/2 device does not exist, and ignores it,

    ; TODO: should slightly rework this so it executes with IF = 1 and IRQ 0 unmasked, and
    ; actually has timeouts (based on that 18.2Hz timer) so it won't hang forever,
    ; also should push a success or error code instead of calling PANIC

    ; TODO: should also split this into a separate keyboard and PS/2 driver
    IMPL_PRIM KEYBOARD_INIT, 1
        ; disable scanning on keyboard first just in case, because
        ; in testing sometimes disabling the port itself is not enough,
        ; and we still get scan codes interfering with the controller self-test
        ; we don't check for an ACK/RESEND since we don't even know if the keyboard
        ; is enabled right now, the output buffer flushing should catch anything that arrives later
        PS2_WAIT_IBF
        mov al, PS2_KBD_SCANOFF
        out PS2_DATA, al

        ; disable devices so they don't interfere with initialization
        PS2_WAIT_IBF
        mov al, PS2_DISABLE_B
        out PS2_COMMAND, al

        PS2_WAIT_IBF
        mov al, PS2_DISABLE_A
        out PS2_COMMAND, al

        PS2_FLUSH_BUF

        ; configure ps/2 controller without translation

        ; get config byte
        PS2_WAIT_IBF
        mov al, PS2_READ_CFG
        out PS2_COMMAND, al
        PS2_WAIT_OBF
        in al, PS2_DATA

        ; disable translation for port 1,
        ; and disable the clock (keeping it enabled causes a race condition in the self-test)
        and al, ~(1 << 6)
        or al, 1 << 4
        mov bl, al

        ; set config byte
        PS2_WAIT_IBF
        mov al, PS2_WRITE_CFG
        out PS2_COMMAND, al
        PS2_WAIT_IBF
        mov al, bl
        out PS2_DATA, al

        ; perform controller self-test
        PS2_WAIT_IBF
        mov al, PS2_TEST
        out PS2_COMMAND, al
        PS2_WAIT_OBF
        in al, PS2_DATA
        cmp al, PS2_SELFTEST_PASSED
        jne .fail

        ; restore config since the self-test may reset it
        ; this time enable the clock so that devices work
        and bl, ~(1 << 4)

        PS2_WAIT_IBF
        mov al, PS2_WRITE_CFG
        out PS2_COMMAND, al
        PS2_WAIT_IBF
        mov al, bl ; we didn't touch bl so it still holds the saved config byte
        out PS2_DATA, al

        PS2_WAIT_IBF
        mov al, PS2_TEST_A
        out PS2_COMMAND, al
        PS2_WAIT_OBF
        in al, PS2_DATA
        test al, al
        jnz .fail

        ; enable IRQs now that we're finishing up initialization
        ; (you may think, but you never disabled them, surely they'd still be enabled?
        ; but the issue there is we don't know if they were ever enabled in the first place)

        ; get config byte
        PS2_WAIT_IBF
        mov al, PS2_READ_CFG
        out PS2_COMMAND, al
        PS2_WAIT_OBF
        in al, PS2_DATA

        or al, 1 << 0 ; enable IRQs for device A
        mov bl, al

        ; set config byte
        PS2_WAIT_IBF
        mov al, PS2_WRITE_CFG
        out PS2_COMMAND, al
        PS2_WAIT_IBF
        mov al, bl
        out PS2_DATA, al

        ; enable keyboard
        PS2_WAIT_IBF
        mov al, PS2_ENABLE_A
        out PS2_COMMAND, al

        ; reset the keyboard
        PS2_KBD_COMMAND PS2_KBD_RESET
        PS2_WAIT_OBF
        in al, PS2_DATA
        cmp al, PS2_KBD_SELFTEST_PASSED
        jne .fail

        ; why do we not explicitly set scancode set 2?
        ; because doing so would actually *decrease*
        ; hardware compatibility for more modern 32-bit
        ; computers as most of the time the keyboards
        ; don't even implement this command
        ; since almost every keyboard starts with scancode set 2
        ; there's no issue with just assuming it already has the correct one

        ; since we disabled scanning all the way at the start,
        ; we need to reenable it here
        PS2_KBD_COMMAND PS2_KBD_SCANON

        PS2_WAIT_IBF ; don't return before the final command has been processed

        ; initialize the actual keyboard driver

        ; ring buffer init
        DPUSH 1
        DPUSH 256
        DPUSH 256 + 20
        FCALL KRESERVE
        cmp esi, -1
        jne .success_ring_alloc
            DPOP
            DPOP
            DPOP
            jmp .fail
        .success_ring_alloc:
        mov eax, [0x7c20]
        mov [eax + (kbd_driver_scan_buf - GVCT_START)], esi
        FCALL RING_INIT

        ; keyboard state init
        DPUSH (128 / 32) * 4
        FCALL KRESERVE
        DPOPR ebx
        cmp ebx, -1
        je .fail

        mov eax, [0x7c20]
        mov [eax + (kbd_driver_kbd_state - GVCT_START)], ebx

        mov dword [ebx], 0
        mov dword [ebx + 4], 0
        mov dword [ebx + 8], 0
        mov dword [ebx + 12], 0

        DPUSH 0
        ret

        .fail:
            DPUSH -1
            ret
    END_IMPL

    ; ring buffer helper functions,
    ; note that these do not manipulate IF,
    ; if you're using these on a ring buffer that can
    ; be modified by ISRs then it's your job to make sure
    ; interrupts are disabled before calling them

    ; our standardized ring buffer is basically:

    ; typedef ring_buffer_t struct {
    ;    uint32 capacity; //  must be a power of two, size of ring buffer in bytes
    ;    uint16 el_size; // 1, 2, or 4
    ;    uint16 error; // 0 = good, 1 = overflow, 2 = underflow, others are reserved but unused
    ;    uint32 head;
    ;    uint32 tail;
    ;    char[capacity]
    ; }

    ; initialize a ring buffer, takes the pointer to the ring buffer struct (must have at least 20 + capacity bytes of space)
    ; the requested size in bytes, and the requested element size (1, 2, or 4) in bytes
    IMPL_PRIM RING_INIT, 1
        DPOPR eax
        DPOPR ebx
        DPOPR ecx

        mov [eax], ebx ; capacity
        mov word [eax + 4], cx ; el_size
        mov word [eax + 6], 0 ; err
        mov [eax + 8], 0 ; head
        mov [eax + 12], 0 ; tail
        ret
    END_IMPL

    ; reinitialize a ring buffer with its existing operand size and capacity, takes the ring buffer
    IMPL_PRIM RING_REINIT, 1
        DPOPR eax

        mov word [eax + 6], 0
        mov [eax + 8], 0 ; head
        mov [eax + 12], 0 ; tail
        ret
    END_IMPL

    ; check if a ring buffer is empty (returns zero for not empty and nonzero for empty), takes the pointer to the ring buffer struct
    IMPL_PRIM RING_ISEMPTY, 1
        DPOPR eax
        mov ebx, [eax + 8]
        cmp ebx, [eax + 12]
        sete al
        movzx eax, al
        DPUSH eax
        ret
    END_IMPL

    ; check if a ring buffer is full (returns zero for not full and nonzero for full), takes the pointer to the ring buffer struct
    IMPL_PRIM RING_ISFULL, 1
        DPOPR eax
        mov ebx, [eax]
        mov ecx, [eax + 8]
        sub ecx, [eax + 12]
        cmp ecx, ebx
        sete al
        movzx eax, al
        DPUSH eax
        ret
    END_IMPL

    ; enqueue an item into a ring buffer (use only if you know the buffer has space and didn't error!)
    ; takes the ring buffer and item
    IMPL_PRIM RING_ENQUEUE, 1
        DPOPR eax
        DPOPR ebx

        ; load and mask idx
        mov ecx, [eax + 8]
        mov edx, [eax]
        dec edx
        and ecx, edx

        ; select operand size
        mov dx, word [eax + 4]
        cmp dx, 1
        je .byte
        cmp dx, 2
        je .word

        ; enqueue
        .dword:
            mov dword [eax + 20 + ecx*4], ebx
            inc dword [eax + 8]
            ret

        .word:
            mov word [eax + 20 + ecx*2], bx
            inc dword [eax + 8]
            ret

        .byte:
            mov byte [eax + 20 + ecx], bl
            inc dword [eax + 8]
            ret
    END_IMPL

    ; dequeue an item from a ring buffer (use only if you know the buffer is nonempty and didn't error!)
    ; takes the ring buffer
    IMPL_PRIM RING_DEQUEUE, 1
        DPOPR eax

        ; load and mask idx
        mov ecx, [eax + 12]
        mov edx, [eax]
        dec edx
        and ecx, edx

        ; select operand size
        mov dx, word [eax + 4]
        cmp dx, 1
        je .byte
        cmp dx, 2
        je .word

        ; enqueue
        .dword:
            mov edx, dword [eax + 20 + ecx*4]
            DPUSH edx
            inc dword [eax + 12]
            ret

        .word:
            movzx edx, word [eax + 20 + ecx*2]
            DPUSH edx
            inc dword [eax + 12]
            ret

        .byte:
            movzx edx, byte [eax + 20 + ecx]
            DPUSH edx
            inc dword [eax + 12]
            ret
    END_IMPL

    ; safe versions of RING_ENQUEUE and RING_DEQUEUE,
    ; note that while these functions may *report* errors,
    ; they do not *set* the error field in a buffer struct,
    ; this is on purpose so that failing to enqueue something doesn't
    ; make other tasks think the buffer overflowed or smth

    ; attempt to enqueue an item into a ring buffer, takes the ring buffer and item,
    ; and returns an error code (0 = good, 1 = overflow, other values are buffer-specific errors)
    IMPL_PRIM RING_TRY_ENQUEUE, 1
        ; check for prior errors
        movzx eax, word [esi + 6]
        test eax, eax
        jnz .err

        ; check if it's full
        DDUP
        FCALL RING_ISFULL
        DPOPR eax
        test eax, eax
        jnz .full
        ; if not full and no prior errors, enqueue
        FCALL RING_ENQUEUE
        DPUSH 0
        ret

        .full:
            DPOP
            DPOP
            DPUSH 1
            ret
        .err:
            DPOP
            DPOP
            DPUSH eax
            ret
    END_IMPL

    ; attempt to dequeue an item from a ring buffer, takes the ring buffer,
    ; returns an error code (0 = good, 2 = underflow, other values are buffer-specific errors)
    ; and the item, the "item" is -1 if there was an error
    IMPL_PRIM RING_TRY_DEQUEUE, 1
        ; check for prior errors
        movzx eax, word [esi + 6]
        test eax, eax
        jnz .err

        ; check if it's full
        DDUP
        FCALL RING_ISEMPTY
        DPOPR eax
        test eax, eax
        jnz .empty
        ; if not empty and no prior errors, dequeue
        FCALL RING_DEQUEUE
        DPUSH 0
        ret

        .empty:
            DPOP
            DPUSH -1
            DPUSH 2
            ret
        .err:
            DPOP
            DPUSH -1
            DPUSH eax
            ret
    END_IMPL

    ; allocate from kernel arena, note that allocations made with this can never be freed
    ; we return -1 for allocation failure, otherwise a pointer to the allocated memory
    IMPL_PRIM KRESERVE, 1
        DPOPR ebx ; amount to alloc

        mov eax, [0x7c20]
        mov edx, [eax + (karena_entry - GVCT_START)] ; e820 entry
        mov ecx, [eax + (karena_here - GVCT_START)] ; arena allocation index

        ; if the new index'd be out of bounds, fail
        add ebx, ecx
        cmp ebx, dword [edx + 8]
        ja .fail

        ; save updated idx, and return the previous idx + base,
        ; if the address overflows, abort and fail
        .success:
        add ecx, [edx]
        jc .fail
        mov [eax + (karena_here - GVCT_START)], ebx

        DPUSH ecx
        ret

        .fail:
        DPUSH -1
        ret
    END_IMPL

    ; initialize kernel arena, takes requested minimum size
    ; finds the smallest e820 entry of type 1 in the memory map of at least that size,
    ; and overwrites its type with 129 (KARENA) as well as captures a pointer
    ; to it, returns 0 on success and -1 on failure
    IMPL_PRIM KARENA_INIT, 1
        DPOPR ecx ; length
        mov eax, [0x7c20]

        mov ebx, [0x7c00] ; start of smap
        .loop:
            cmp ebx, [0x7c04] ; end of smap
            je .end

            ; must be usable ram
            cmp dword [ebx + 16], 1
            jne .skip

            ; must be in 4GB address space
            cmp [ebx + 4], 0
            jne .skip
            cmp [ebx + 12], 0
            jne .skip
            mov edx, [ebx]
            add edx, [ebx + 8]
            jc .skip

            ; must be of at least the requested length
            cmp dword [ebx + 8], ecx
            jb .skip

            .success:
                mov [ebx + 16], 129
                mov dword [eax + (karena_entry - GVCT_START)], ebx
                mov dword [eax + (karena_here - GVCT_START)], 0
                DPUSH 0
                ret

            .skip:
            add ebx, 20
            jmp .loop

        .end:
            DPUSH -1
            ret
    END_IMPL

    ; reset kernel arena, takes no arguments and has no return value,
    ; after the call to this function all memory previously allocated
    ; with KRESERVE is rendered *invalid*, and the arena allocation pointer
    ; is reset to 0, making KRESERVE calls once more capable of succeeding
    IMPL_PRIM KARENA_REINIT, 1
        ; tiny impl, but it's worth it to make this a function
        ; just because it makes the intent clearer
        mov eax, [0x7c20]
        mov [eax + (karena_here - GVCT_START)], 0
        ret
    END_IMPL
END_SECTION

; word descriptor table
START_SECTION WD_TABLE
    ; main
    WORD_DESC INIT, 0
    WORD_DESC KMAIN, 0

    ; drivers/tasks
    WORD_DESC TIMER_HOOK, 0
    WORD_DESC KEYBOARD_DRIVER, 0
    WORD_DESC TERMINAL_DRIVER, 0

    ; error handling
    WORD_DESC PANIC, 0

    ; interrupts
    WORD_DESC INT_INIT, 0
    WORD_DESC SET_INT, 0
    WORD_DESC TIMER_INT, 0
    WORD_DESC KEYBOARD_INT, 0

    ; console
    WORD_DESC CONSOLE_INIT, 0
    WORD_DESC RENDER_GLYPH, 0

    ; terminal
    WORD_DESC TERMINAL_INIT, 0
    WORD_DESC CLS, 0
    WORD_DESC SCROLL, 0
    WORD_DESC TERM_BACKSPACE, 0
    WORD_DESC TERM_CR, 0
    WORD_DESC TERM_LN, 0

    WORD_DESC PUTC, 0
    WORD_DESC PUTS, 0
    WORD_DESC PUTH, 0

    ; keyboard
    WORD_DESC KEYBOARD_INIT, 0

    ; ring buffers
    WORD_DESC RING_INIT, 0
    WORD_DESC RING_REINIT, 0
    WORD_DESC RING_ISEMPTY, 0
    WORD_DESC RING_ISFULL, 0
    WORD_DESC RING_ENQUEUE, 0
    WORD_DESC RING_DEQUEUE, 0
    WORD_DESC RING_TRY_ENQUEUE, 0
    WORD_DESC RING_TRY_DEQUEUE, 0

    ; kernel arena
    WORD_DESC KRESERVE, 0
    WORD_DESC KARENA_INIT, 0
    WORD_DESC KARENA_REINIT, 0
END_SECTION

; dictionary
START_SECTION DICT
    DICT_ENTRY INIT, "INIT"
    DICT_ENTRY KMAIN, "KMAIN"
    DICT_ENTRY TIMER_HOOK, "TIMER_HOOK"
    DICT_ENTRY KEYBOARD_DRIVER, "KEYBOARD_DRIVER"
    DICT_ENTRY TERMINAL_DRIVER, "TERMINAL_DRIVER"
    DICT_ENTRY PANIC, "PANIC"
    DICT_ENTRY INT_INIT, "INT_INIT"
    DICT_ENTRY SET_INT, "SET_INT"
    DICT_ENTRY TIMER_INT, "TIMER_INT"
    DICT_ENTRY KEYBOARD_INT, "KEYBOARD_INT"
    DICT_ENTRY CONSOLE_INIT, "CONSOLE_INIT"
    DICT_ENTRY RENDER_GLYPH, "RENDER_GLYPH"
    DICT_ENTRY TERMINAL_INIT, "TERMINAL_INIT"
    DICT_ENTRY CLS, "CLS"
    DICT_ENTRY SCROLL, "SCROLL"
    DICT_ENTRY TERM_BACKSPACE, "TERM_BACKSPACE"
    DICT_ENTRY TERM_CR, "TERM_CR"
    DICT_ENTRY TERM_LN, "TERM_LN"
    DICT_ENTRY PUTC, "PUTC"
    DICT_ENTRY PUTS, "PUTS"
    DICT_ENTRY PUTH, "PUTH"
    DICT_ENTRY KEYBOARD_INIT, "KEYBOARD_INIT"
    DICT_ENTRY RING_INIT, "RING_INIT"
    DICT_ENTRY RING_REINIT, "RING_REINIT"
    DICT_ENTRY RING_ISEMPTY, "RING_ISEMPTY"
    DICT_ENTRY RING_ISFULL, "RING_ISFULL"
    DICT_ENTRY RING_ENQUEUE, "RING_ENQUEUE"
    DICT_ENTRY RING_DEQUEUE, "RING_DEQUEUE"
    DICT_ENTRY RING_TRY_ENQUEUE, "RING_TRY_ENQUEUE"
    DICT_ENTRY RING_TRY_DEQUEUE, "RING_TRY_DEQUEUE"
    DICT_ENTRY KRESERVE, "KRESERVE"
    DICT_ENTRY KARENA_INIT, "KARENA_INIT"
    DICT_ENTRY KARENA_REINIT, "KARENA_REINIT"
END_SECTION

; global-variable & constant table
START_SECTION GVCT
    karena_entry dd 0 ; address of memory-map entry containing kernel arena
    karena_here dd 0 ; offset from start of arena that new allocations start at

    ; main runtime stacks
    return_stack_base dd 0
    data_stack_base dd 0
    ; ISR stacks
    isr_return_stack dd 0
    isr_data_stack dd 0

    ; tick counter, tells us the number of times IRQ 0 fired
    tkc_low dd 0
    tkc_high dd 0

    here dd HERE_START - GVCT_START ; cursor in the constant table
    latest dd %$LATEST ; latest defined dictionary entry

    kbd_driver_scan_buf dd 0 ; addr of ring buf to get scancodes from
    kbd_driver_key_buf dd 0 ; addr of ring buf to send keycodes to
    kbd_driver_kbd_state dd 0 ; addr of bitmap containing keyboard state
    kbd_driver_consumer_task db 0 ; bit index in pending_work of the task to make runnable
    kbd_driver_state db 0

    ; bitmap that represents runnable tasks,
    ; the superloop in KMAIN invokes the respective handlers
    pending_work dd 0

    ; terminal variables
    console_cursor dw 0 ; current position in VGA text buffer
    console_attr db 0 ; attribute byte to use for characters
    console_cursorattr db 0 ; attribute byte to use for the cell the cursor is on

    ; kernel messages
    greeting db "FIF IMG REVISION 1", 13, 10
    greeting_len dd $ - greeting
    initmsg db "Initialization complete. Entering main loop.", 13, 10
    initmsg_len dd $ - initmsg

    ; struct used by the jmp far in INIT to reload CS
    init_jmpptr:
        dd init_reload_cs - IMPL_TABLE_START
        dw 0x8 ; flat code segment

    align 8, db 0
    gdt_start:
        dq 0 ; must be null

        ; code, base = 0, limit = 4GB
        dw 0xffff ; limit 15:0
        dw 0 ; base 15:0
        db 0 ; base 23:16
        db 0b10011010 ; readable code segment, nonconforming
        db 0b11001111 ; last 4 bits in the limit, 4KB granularity and 32-bit size
        db 0 ; base 31:24

        ; data, base = 0, limit = 4GB
        dw 0xffff
        dw 0
        db 0
        db 0b10010010
        db 0b11001111
        db 0

    gdt_end:

    gdtr:
    dw gdt_end - gdt_start - 1 ; limit
    dd gdt_start - GVCT_START ; base

    align 8, db 0
    idt_start:
        times 256 dq 0 ; fake entries, we'll set these at runtime
    idt_end:
    idtr:
        dw idt_end - idt_start - 1
        dd idt_start - GVCT_START

    ; interrupt descriptor extension table, this lets us make ISRs respect late binding
    align 8, db 0
    idet_start:
    %rep 256
        ; jmp [edi + disp32]
        db 0xff, 0xa7
        dd 0 ; disp32, set this to WD_IDX * 12 whenever you want to set a new interrupt handler
        dw 0 ; padding so that each entry becomes 8 bytes
    %endrep
    idet_end:

    ; maps scancode set 2 values to our internal 7-bit keycodes, mostly auto-generated with GNU AWK (by taking an existing key table,
    ; extracting the scancodes out of it, sorting them, and mapping them to consecutive keycode indices starting at 1 and ending at 127)
    keycode_map:
    START_MAPPING 256
        MAP_IDX 0x01, 0x01 ; F9
        MAP_IDX 0x02, 0x55 ; alias for F7 since some dipshit at intel decided to make their scancodes 7-bit only meaning I can't get 0x83
        MAP_IDX 0x03, 0x02 ; F5
        MAP_IDX 0x04, 0x03 ; F3
        MAP_IDX 0x05, 0x04 ; F1
        MAP_IDX 0x06, 0x05 ; F2
        MAP_IDX 0x07, 0x06 ; F12
        MAP_IDX 0x09, 0x07 ; F10
        MAP_IDX 0x0A, 0x08 ; F8
        MAP_IDX 0x0B, 0x09 ; F6
        MAP_IDX 0x0C, 0x0a ; F4
        MAP_IDX 0x0D, 0x0b ; tab
        MAP_IDX 0x0E, 0x0c ; ` (back tick)
        MAP_IDX 0x11, 0x0d ; left alt
        MAP_IDX 0x12, 0x0e ; left shift
        MAP_IDX 0x14, 0x0f ; left control
        MAP_IDX 0x15, 0x10 ; Q
        MAP_IDX 0x16, 0x11 ; 1
        MAP_IDX 0x1A, 0x12 ; Z
        MAP_IDX 0x1B, 0x13 ; S
        MAP_IDX 0x1C, 0x14 ; A
        MAP_IDX 0x1D, 0x15 ; W
        MAP_IDX 0x1E, 0x16 ; 2
        MAP_IDX 0x21, 0x17 ; C
        MAP_IDX 0x22, 0x18 ; X
        MAP_IDX 0x23, 0x19 ; D
        MAP_IDX 0x24, 0x1a ; E
        MAP_IDX 0x25, 0x1b ; 4
        MAP_IDX 0x26, 0x1c ; 3
        MAP_IDX 0x29, 0x1d ; space
        MAP_IDX 0x2A, 0x1e ; V
        MAP_IDX 0x2B, 0x1f ; F
        MAP_IDX 0x2C, 0x20 ; T
        MAP_IDX 0x2D, 0x21 ; R
        MAP_IDX 0x2E, 0x22 ; 5
        MAP_IDX 0x31, 0x23 ; N
        MAP_IDX 0x32, 0x24 ; B
        MAP_IDX 0x33, 0x25 ; H
        MAP_IDX 0x34, 0x26 ; G
        MAP_IDX 0x35, 0x27 ; Y
        MAP_IDX 0x36, 0x28 ; 6
        MAP_IDX 0x3A, 0x29 ; M
        MAP_IDX 0x3B, 0x2a ; J
        MAP_IDX 0x3C, 0x2b ; U
        MAP_IDX 0x3D, 0x2c ; 7
        MAP_IDX 0x3E, 0x2d ; 8
        MAP_IDX 0x41, 0x2e ; ,
        MAP_IDX 0x42, 0x2f ; K
        MAP_IDX 0x43, 0x30 ; I
        MAP_IDX 0x44, 0x31 ; O
        MAP_IDX 0x45, 0x32 ; 0 (zero)
        MAP_IDX 0x46, 0x33 ; 9
        MAP_IDX 0x49, 0x34 ; .
        MAP_IDX 0x4A, 0x35 ; /
        MAP_IDX 0x4B, 0x36 ; L
        MAP_IDX 0x4C, 0x37 ; ;
        MAP_IDX 0x4D, 0x38 ; P
        MAP_IDX 0x4E, 0x39 ; -
        MAP_IDX 0x52, 0x3a ; '
        MAP_IDX 0x54, 0x3b ; [
        MAP_IDX 0x55, 0x3c ; =
        MAP_IDX 0x58, 0x3d ; CapsLock
        MAP_IDX 0x59, 0x3e ; right shift
        MAP_IDX 0x5A, 0x3f ; enter
        MAP_IDX 0x5B, 0x40 ; ]
        MAP_IDX 0x5D, 0x41 ; backslash
        MAP_IDX 0x61, 0x41 ; ISO 102nd key gets mapped to backslash too (they do the basically the same thing anyway)
        MAP_IDX 0x66, 0x42 ; backspace
        MAP_IDX 0x69, 0x43 ; (keypad) 1
        MAP_IDX 0x6B, 0x44 ; (keypad) 4
        MAP_IDX 0x6C, 0x45 ; (keypad) 7
        MAP_IDX 0x70, 0x46 ; (keypad) 0
        MAP_IDX 0x71, 0x47 ; (keypad) .
        MAP_IDX 0x72, 0x48 ; (keypad) 2
        MAP_IDX 0x73, 0x49 ; (keypad) 5
        MAP_IDX 0x74, 0x4a ; (keypad) 6
        MAP_IDX 0x75, 0x4b ; (keypad) 8
        MAP_IDX 0x76, 0x4c ; escape
        MAP_IDX 0x77, 0x4d ; NumberLock
        MAP_IDX 0x78, 0x4e ; F11
        MAP_IDX 0x79, 0x4f ; (keypad) +
        MAP_IDX 0x7A, 0x50 ; (keypad) 3
        MAP_IDX 0x7B, 0x51 ; (keypad) -
        MAP_IDX 0x7C, 0x52 ; (keypad) *
        MAP_IDX 0x7D, 0x53 ; (keypad) 9
        MAP_IDX 0x7E, 0x54 ; ScrollLock
        MAP_IDX 0x7f, 0x7f ; alias for sysrq
        MAP_IDX 0x83, 0x55 ; F7
        MAP_IDX 0x84, 0x7f ; sysrq (special)
    STOP_MAPPING
    START_MAPPING 256
        MAP_IDX 0x10, 0x56 ; (multimedia) WWW search
        MAP_IDX 0x11, 0x57 ; right alt
        MAP_IDX 0x14, 0x58 ; right control
        MAP_IDX 0x15, 0x59 ; (multimedia) previous track
        MAP_IDX 0x18, 0x5a ; (multimedia) WWW favourites
        MAP_IDX 0x1F, 0x5b ; left GUI
        MAP_IDX 0x20, 0x5c ; (multimedia) WWW refresh
        MAP_IDX 0x21, 0x5d ; (multimedia) volume down
        MAP_IDX 0x23, 0x5e ; (multimedia) mute
        MAP_IDX 0x27, 0x5f ; right GUI
        MAP_IDX 0x28, 0x60 ; (multimedia) WWW stop
        MAP_IDX 0x2B, 0x61 ; (multimedia) calculator
        MAP_IDX 0x2F, 0x62 ; apps
        MAP_IDX 0x30, 0x63 ; (multimedia) WWW forward
        MAP_IDX 0x32, 0x64 ; (multimedia) volume up
        MAP_IDX 0x34, 0x65 ; (multimedia) play/pause
        MAP_IDX 0x37, 0x66 ; (ACPI) power
        MAP_IDX 0x38, 0x67 ; (multimedia) WWW back
        MAP_IDX 0x3A, 0x68 ; (multimedia) WWW home
        MAP_IDX 0x3B, 0x69 ; (multimedia) stop
        MAP_IDX 0x3F, 0x6a ; (ACPI) sleep
        MAP_IDX 0x40, 0x6b ; (multimedia) my computer
        MAP_IDX 0x48, 0x6c ; (multimedia) email
        MAP_IDX 0x4A, 0x6d ; (keypad) /
        MAP_IDX 0x4D, 0x6e ; (multimedia) next track
        MAP_IDX 0x50, 0x6f ; (multimedia) media select
        MAP_IDX 0x5A, 0x70 ; (keypad) enter
        MAP_IDX 0x5E, 0x71 ; (ACPI) wake
        MAP_IDX 0x69, 0x72 ; end
        MAP_IDX 0x6B, 0x73 ; cursor left
        MAP_IDX 0x6C, 0x74 ; home
        MAP_IDX 0x70, 0x75 ; insert
        MAP_IDX 0x71, 0x76 ; delete
        MAP_IDX 0x72, 0x77 ; cursor down
        MAP_IDX 0x74, 0x78 ; cursor right
        MAP_IDX 0x75, 0x79 ; cursor up
        MAP_IDX 0x7A, 0x7a ; page down
        MAP_IDX 0x7C, 0x7c ; print-screen (special)
        MAP_IDX 0x7D, 0x7b ; page up
        MAP_IDX 0x7E, 0x7e ; break (special)
        ; special key values:
            ; - print screen = 0x7c
            ; - pause = 0x7d
            ; - break = 0x7e
            ; - sysrq = 0x7f

        ; note, pause isn't in this array because it isn't produced through a normal array lookup,
        ; but rather has special edge-case logic directly in the driver
    STOP_MAPPING

    ; character map for terminal, maps keycodes to ascii codes, structure partially auto-generated
    ; with GNU AWK, the format here is 4-byte entries representing the different ASCII characters generated
    ; by a keycode for normal, shift, altgr, and shift+altgr modifiers respectively. There are two notable
    ; exceptions, NUL and SOH, keycodes mapped to NUL are treated as *unmapped*, and display as '\0'
    ; (this is also put into the line buffer as the two characters to avoid confusion about the screen/what was actually read),
    ; keycodes mapped to SOH are treated as *nonprinting*, and thus are ignored entirely
    ; (example, pressing modifier keys shouldn't mess up the screen)

    ; finally, for the general philosophy of how this is filled out, I consider any character that isn't useful *in*
    ; the terminal as better left unmapped than mapped to SOH, this means that while left shift and altgr are mapped to SOH,
    ; pretty much anything else that doesn't generate a character is unmapped, I believe this to be better than silently dropping
    ; all non-printing characters, though if you find yourself fat-fingering keys often you can change the TERMINAL_DRIVER function

    ; todo: fill out the entries here
    align 4, db 0
    char_map:
        db `\0\0\0\0` ; no character, reserved
        db `\0\0\0\0` ; 0x01: F9
        db `\0\0\0\0` ; 0x02: F5
        db `\0\0\0\0` ; 0x03: F3
        db `\0\0\0\0` ; 0x04: F1
        db `\0\0\0\0` ; 0x05: F2
        db `\0\0\0\0` ; 0x06: F12
        db `\0\0\0\0` ; 0x07: F10
        db `\0\0\0\0` ; 0x08: F8
        db `\0\0\0\0` ; 0x09: F6
        db `\0\0\0\0` ; 0x0a: F4
        db `\0\0\0\0` ; 0x0b: tab
        db `\`~\0\0` ; 0x0c: ` (back tick)
        db `\0\0\0\0` ; 0x0d: left alt
        db `\1\1\1\1` ; 0x0e: left shift
        db `\0\0\0\0` ; 0x0f: left control
        db `qQ\0\0` ; 0x10: Q
        db `1!\0\0` ; 0x11: 1
        db `zZ\0\0` ; 0x12: Z
        db `sS\0\0` ; 0x13: S
        db `aA\0\0` ; 0x14: A
        db `wW\0\0` ; 0x15: W
        db `2@\0\0` ; 0x16: 2
        db `cC\0\0` ; 0x17: C
        db `xX\0\0` ; 0x18: X
        db `dD\0\0` ; 0x19: D
        db `eE\0\0` ; 0x1a: E
        db `4$\0\0` ; 0x1b: 4
        db `3#\0\0` ; 0x1c: 3
        db ` \0\0\0` ; 0x1d: space
        db `vV\0\0` ; 0x1e: V
        db `fF\0\0` ; 0x1f: F
        db `tT\0\0` ; 0x20: T
        db `rR\0\0` ; 0x21: R
        db `5%\0\0` ; 0x22: 5
        db `nN\0\0` ; 0x23: N
        db `bB\0\0` ; 0x24: B
        db `hH\0\0` ; 0x25: H
        db `gG\0\0` ; 0x26: G
        db `yY\0\0` ; 0x27: Y
        db `6^\0\0` ; 0x28: 6
        db `mM\0\0` ; 0x29: M
        db `jJ\0\0` ; 0x2a: J
        db `uU\0\0` ; 0x2b: U
        db `7&\0\0` ; 0x2c: 7
        db `8*\0\0` ; 0x2d: 8
        db `,<\0\0` ; 0x2e: ,
        db `kK\0\0` ; 0x2f: K
        db `iI\0\0` ; 0x30: I
        db `oO\0\0` ; 0x31: O
        db `0)\0\0` ; 0x32: 0 (zero)
        db `9(\0\0` ; 0x33: 9
        db `.>\0\0` ; 0x34: .
        db `/?\0\0` ; 0x35: /
        db `lL\0\0` ; 0x36: L
        db `;:\0\0` ; 0x37: ;
        db `pP\0\0` ; 0x38: P
        db `-_\0\0` ; 0x39: -
        db `'"\0\0` ; 0x3a: '
        db `[{\0\0` ; 0x3b: [
        db `=+\0\0` ; 0x3c: =
        db `\0\0\0\0` ; 0x3d: CapsLock
        db `\0\0\0\0` ; 0x3e: right shift
        db `\n\r\0\0` ; 0x3f: enter
        db `]}\0\0` ; 0x40: ]
        db `\\|\0\0` ; 0x41: backslash
        db `\b\0\0\0` ; 0x42: backspace
        db `\0\0\0\0` ; 0x43: (keypad) 1
        db `\0\0\0\0` ; 0x44: (keypad) 4
        db `\0\0\0\0` ; 0x45: (keypad) 7
        db `\0\0\0\0` ; 0x46: (keypad) 0
        db `\0\0\0\0` ; 0x47: (keypad) .
        db `\0\0\0\0` ; 0x48: (keypad) 2
        db `\0\0\0\0` ; 0x49: (keypad) 5
        db `\0\0\0\0` ; 0x4a: (keypad) 6
        db `\0\0\0\0` ; 0x4b: (keypad) 8
        db `\0\0\0\0` ; 0x4c: escape
        db `\0\0\0\0` ; 0x4d: NumberLock
        db `\0\0\0\0` ; 0x4e: F11
        db `\0\0\0\0` ; 0x4f: (keypad) +
        db `\0\0\0\0` ; 0x50: (keypad) 3
        db `\0\0\0\0` ; 0x51: (keypad) -
        db `\0\0\0\0` ; 0x52: (keypad) *
        db `\0\0\0\0` ; 0x53: (keypad) 9
        db `\0\0\0\0` ; 0x54: ScrollLock
        db `\0\0\0\0` ; 0x55: F7
        db `\0\0\0\0` ; 0x56: (multimedia) WWW search
        db `\1\1\1\1` ; 0x57: right alt
        db `\0\0\0\0` ; 0x58: right control
        db `\0\0\0\0` ; 0x59: (multimedia) previous track
        db `\0\0\0\0` ; 0x5a: (multimedia) WWW favourites
        db `\0\0\0\0` ; 0x5b: left GUI
        db `\0\0\0\0` ; 0x5c: (multimedia) WWW refresh
        db `\0\0\0\0` ; 0x5d: (multimedia) volume down
        db `\0\0\0\0` ; 0x5e: (multimedia) mute
        db `\0\0\0\0` ; 0x5f: right GUI
        db `\0\0\0\0` ; 0x60: (multimedia) WWW stop
        db `\0\0\0\0` ; 0x61: (multimedia) calculator
        db `\0\0\0\0` ; 0x62: apps
        db `\0\0\0\0` ; 0x63: (multimedia) WWW forward
        db `\0\0\0\0` ; 0x64: (multimedia) volume up
        db `\0\0\0\0` ; 0x65: (multimedia) play/pause
        db `\0\0\0\0` ; 0x66: (ACPI) power
        db `\0\0\0\0` ; 0x67: (multimedia) WWW back
        db `\0\0\0\0` ; 0x68: (multimedia) WWW home
        db `\0\0\0\0` ; 0x69: (multimedia) stop
        db `\0\0\0\0` ; 0x6a: (ACPI) sleep
        db `\0\0\0\0` ; 0x6b: (multimedia) my computer
        db `\0\0\0\0` ; 0x6c: (multimedia) email
        db `\0\0\0\0` ; 0x6d: (keypad) /
        db `\0\0\0\0` ; 0x6e: (multimedia) next track
        db `\0\0\0\0` ; 0x6f: (multimedia) media select
        db `\0\0\0\0` ; 0x70: (keypad) enter
        db `\0\0\0\0` ; 0x71: (ACPI) wake
        db `\0\0\0\0` ; 0x72: end
        db `\0\0\0\0` ; 0x73: cursor left
        db `\0\0\0\0` ; 0x74: home
        db `\0\0\0\0` ; 0x75: insert
        db `\0\0\0\0` ; 0x76: delete
        db `\0\0\0\0` ; 0x77: cursor down
        db `\0\0\0\0` ; 0x78: cursor right
        db `\0\0\0\0` ; 0x79: cursor up
        db `\0\0\0\0` ; 0x7a: page down
        db `\0\0\0\0` ; 0x7b: page up
        db `\0\0\0\0` ; 0x7c: print-screen (special)
        db `\0\0\0\0` ; 0x7d: pause (special)
        db `\0\0\0\0` ; 0x7e: break (special)
        db `\0\0\0\0` ; 0x7f: sysrq (special)

    HERE_START:
END_SECTION
