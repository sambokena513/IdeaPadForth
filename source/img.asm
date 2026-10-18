
;  img.asm
;
;  Copyright (C) 2026 Samuel Peciar
;  
;  This program is free software: you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, either version 3 of the License, or 
;  any later version.



bits 32
org 0 ; not actually loaded at 0x00000000, but this gives us simple relative label offsets

addr0:

; align to logical block
%define ALIGN_LBLK align 512

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
    dq 0 ; reserved for idx calculations to be simpler

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

    dd %1
    dd (%$impl_end - $$) - (%$impl_start - $$)
    dd 0 ; no IR for primitive/anonymous words
    %2 %+ _IMPL: ; make this word's impl available to other macros
%endmacro

%macro END_IMPL 0
    %$impl_end:
    %pop
%endmacro

; emit a WordDesc struct for a chosen impl
%macro WORD_DESC 2
    %1 %+ _WD:
    dd %1 %+ _IMPL ; target
    dd 0 ; new words start with generation 0
    dd %2 ; flags
%endmacro


; latest dict entry in assembler, NOT A RUNTIME VARIABLE!
%push dict_ctx
%define %$LATEST addr0

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

HEADER 0, WD_TABLE, IMPL_TABLE, DICT, GVCT_TABLE

; word descriptor table
START_SECTION WD_TABLE
    WORD_DESC INIT, 0
END_SECTION

; word implementation table
START_SECTION IMPL_TABLE
    IMPL_PRIM 1, INIT
        mov byte [0xb8000], 'Z' ; our "hello world", should print Z to the top left corner of the screen
        ret ; should normally be unreachable, but in the first few bootstrap images we will ret
    END_IMPL
END_SECTION

; dictionary
START_SECTION DICT
    db 0 ; offset the first dictionary entry by 1 byte so we can distinguish between entry 0 and NULL

    DICT_ENTRY INIT, "INIT"
END_SECTION

; global-variable & constant table
START_SECTION GVCT_TABLE
    here dd HERE_START - GVCT_TABLE_START ; cursor in the constant table
    latest dd %$LATEST
    HERE_START:
END_SECTION
