
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

; align to logical block
%define ALIGN_LBLK align 512

; the start of the image header
%define IMG_START_LBA 64

; bootloader gives us our boot information here
%define RUNTIME_HEADER 0x7c00

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
    %push section_ctx
    %define %$section_name %1
    %$section_name %+ _START:
%endmacro

; end an image section
%macro END_SECTION 0
    ALIGN_LBLK
    %$section_name %+ _END:
    %pop
%endmacro



HEADER 0, WD_TABLE, IMPL_TABLE, DICT, GVCT_TABLE

; word descriptor table
START_SECTION WD_TABLE
    db "PLACEHOLDER"
END_SECTION

; word implementation table
START_SECTION IMPL_TABLE
    db "PLACEHOLDER"
END_SECTION

; dictionary
START_SECTION DICT
    db "PLACEHOLDER"
END_SECTION

; global-variable & constant table
START_SECTION GVCT_TABLE
    db "PLACEHOLDER"
END_SECTION
