
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

HEADER 0, WD_TABLE, IMPL_TABLE, DICT, GVCT_TABLE

; word descriptor table
START_SECTION WD_TABLE
    WORD_DESC INIT, 0
    WORD_DESC SET_INT, 0
    WORD_DESC PLACEHOLDER_INT, 0
END_SECTION

; word implementation table
START_SECTION IMPL_TABLE
    IMPL_PRIM INIT, 1

        ; set up int3 handler
        DPUSH 2 ; PLACEHOLDER_INT
        DPUSH 0 ; interrupt gate
        DPUSH 3 ; #BP
        FCALL SET_INT

        ; load IDT
        mov eax, [0x7c20]
        add dword [eax + (idtr - GVCT_TABLE_START) + 2], eax
        lidt [eax + (idtr - GVCT_TABLE_START)]
        sub dword [eax + (idtr - GVCT_TABLE_START) + 2], eax

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

    ; given an interrupt vector, gate type, and word descriptor index
    ; set that word's current implementation as the interrupt
    ; handler. Note that this does not set that *word* as the handler,
    ; but rather its *current impl*, if it is redefined then tough luck.
    IMPL_PRIM SET_INT, 1
        ; set eax to the GVCT base
        mov eax, [0x7c20]

        ; ebx gets the offset into the IDT
        DPOPR ebx
        shl ebx, 3

        DSWAP ; swap idx and gate type

        ; set ecx to the linear address of the word's impl
        DPOPR ecx
        mov edx, ecx
        shl ecx, 3
        shl edx, 2
        add ecx, edx
        add ecx, edi ; now ecx has the pointer to the word desc with the impl
        mov ecx, [ecx] ; dereference to get the imp ; dereference to get the impll

        DPOPR edx ; pop gate type (0 = interrupt; -1 = trap) into edx
        test edx, edx
        jnz .trap
        .int:
            mov dl, 0x8e
            jmp .gate_type_known
        .trap:
            mov dl, 0x8f
        .gate_type_known:

        ; offset 0..15
        mov word [eax + (idt_start - GVCT_TABLE_START) + ebx], cx
        shr ecx, 16
        ; offset 16..31
        mov word [eax + (idt_start - GVCT_TABLE_START) + ebx + 6], cx

        ; segment selector, the bootloader gives us flat segmentation
        ; with 0x08 being the code segment and 0x10 being the data segment
        mov word [eax + (idt_start - GVCT_TABLE_START) + ebx + 2], 0x08

        ; zero field
        mov byte [eax + (idt_start - GVCT_TABLE_START) + ebx + 4], 0

        ; type (32-bit interrupt gate) as well as DPL (0) and p (1)
        mov byte [eax + (idt_start - GVCT_TABLE_START) + ebx + 5], dl
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
    DICT_ENTRY SET_INT, "SET_INT"
    DICT_ENTRY PLACEHOLDER_INT, "PLACEHOLDER_INT"
END_SECTION

; global-variable & constant table
START_SECTION GVCT_TABLE
    here dd HERE_START - GVCT_TABLE_START ; cursor in the constant table
    latest dd %$LATEST
    idt_start:
        times 256 dq 0 ; fake entries, we'll set these at runtime
    idt_end:
    idtr:
        dw idt_end - idt_start
        ; note, IDTR requires the linear address of the IDT,
        ; this is a section offset, so we need to change it
        ; at runtime before doing LIDT
        dd idt_start - GVCT_TABLE_START
    HERE_START:
END_SECTION
