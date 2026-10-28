
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

    times 256 db 0 ; runtime, nothing on disk

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

; pop a value from the data stack into a specific register
%macro DPOPR 1
    mov %1, esi
    sub ebp, 4
    mov esi, dword [ebp]
%endmacro

; ----
; CODE
; ----

HEADER 0, WD_TABLE, IMPL_TABLE, DICT, GVCT

; word descriptor table
START_SECTION WD_TABLE
    WORD_DESC INIT, 0
    WORD_DESC INT_INIT, 0
    WORD_DESC SET_INT, 0
    WORD_DESC PLACEHOLDER_INT, 0
END_SECTION

; word implementation table
START_SECTION IMPL_TABLE
    IMPL_PRIM INIT, 1
        ; load GDT (technically we know the bootloader gives us a valid one since we are
        ; executing in protected mode, but we don't want to rely on the bootloader environment)
        mov eax, [0x7c20]
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

        ; initialize and load interrupt descriptor table
        FCALL INT_INIT

        ; set up int3 handler
        DPUSH WDIDX(PLACEHOLDER_INT)
        DPUSH 0 ; interrupt gate
        DPUSH 3 ; #BP
        FCALL SET_INT

        ; our "hello world",
        ; fills the screen with Z characters

        xor eax, eax
        .loop:
            cmp eax, 2000 * 2
            je .end

            mov byte [0xb8000 + eax], 'Z'

            add eax, 2
            jmp .loop
        .end:

        int3 ; test our interrupt handler, should triple-fault if we f'ed up

        .hang:
            hlt
            jmp .hang
    END_IMPL

    ; load the IDT, and make each entry in it point to the corresponding IDeT entry in our flat code segment
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

        ret
    END_IMPL

    ; given an interrupt vector, gate type, and word descriptor index
    ; set that word idx as the interrupt handler, and set the type of the
    ; IDT entry at <interrupt_vector> to <gate_type> (0 = interrupt, -1 = trap)

    ; Note, while interrupt handlers set by SET_INT do see changes to a word's impl,
    ; they do not check the generation counter, so similarly to compiled word calls,
    ; if you DELETE a word registered as an interrupt handler, and then DEFINE a new
    ; word that happens to use the same descriptor slot, then rather than erroring,
    ; the word will be dispatched to with most probably unintended and bad consequences
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

     ; placeholder interrupt handler
     IMPL_PRIM PLACEHOLDER_INT, 1
         inc byte [0xb8000] ; so that it's visible something happened
         iret
     END_IMPL
END_SECTION

; dictionary
START_SECTION DICT
    DICT_ENTRY INIT, "INIT"
    DICT_ENTRY INT_INIT, "INT_INIT"
    DICT_ENTRY SET_INT, "SET_INT"
    DICT_ENTRY PLACEHOLDER_INT, "PLACEHOLDER_INT"
END_SECTION

; global-variable & constant table
START_SECTION GVCT
    here dd HERE_START - GVCT_START ; cursor in the constant table
    latest dd %$LATEST ; latest defined dictionary entry

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

    HERE_START:
END_SECTION
