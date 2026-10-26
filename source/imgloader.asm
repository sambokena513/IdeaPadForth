
;  imgloader.asm
;
;  Copyright (C) 2026 Samuel Peciar
;  
;  This program is free software: you can redistribute it and/or modify
;  it under the terms of the GNU General Public License as published by
;  the Free Software Foundation, either version 3 of the License, or 
;  any later version.



; forth image loader, this file's job is to
; set up everything needed to be able to boot
; the forth image starting at lba 64

; ABI note; we don't have a complex calling convention in the bootloader, especially in real mode, but once we switch to protected
; mode we treat the first four registers (eax, ebx, ecx, edx) as caller-saved, and the other four (esi, edi, ebp, esp) as callee-saved,
; and args as being in order in the first four registers. So a quaternary function is called with eax = arg1, ebx = arg2, ecx = arg3, and edx = arg4.

bits 16
org 0x8000 ; start just after boot sector

%define e820_base_offset 0 ; qword
%define e820_length_offset 8 ; qword
%define e820_type_offset 16 ; dword

; essentially only type 1 is initially allocatable

%define e820_USABLE 1 ; valid RAM
%define e820_RESERVED 2 ; reserved by firmware or devices
%define e820_ACPI 3 ; can reclaim after processing ACPI data
%define e820_NVS 4 ; firmware expects this to be preserved across sleep/restore states
%define e820_UNUSABLE 5 ; bad memory
; custom types
%define e820_BOOTLOADER_RECLAIMABLE 127 ; may reclaim once no longer using BIOS/real mode for anything
%define e820_FIF_SECTION 128 ; forth image format section

; signature we pass to 15h, e820 to say we want a memory map
%define SMAP 0x534d4150

; very slightly increases binary size compared to db because it uses a jmp (more specifically, adds 2 bytes on most strings),
; but we have 64KB of code space here, so it's not really an issue for the convenience
%macro lstr 2+
    jmp %%skip
    %%string:
    db %2,0
    %%skip:
    lea %1,%%string
%endmacro

; save n registers to stack
%macro sreg 1-*
    %rep %0
        push %1
        %rotate 1
    %endrep
%endmacro

; restore n registers
%macro rreg 1-*
    %rep %0
        %rotate -1
        pop %1
    %endrep
%endmacro

; put a character (offset from start of alphabet) into the top left corner of the screen
%macro VGA_MARK16 1
    %ifdef DEBUG
        sreg ax
        mov ax, 0xb800
        mov es, ax
        mov word [es:0], 0x0f40 + %1
        xor ax, ax
        mov es, ax
        rreg ax
    %endif
%endmacro

%macro VGA_MARK32 1
    %ifdef DEBUG
        mov word [0xb8000], 0x0f40 + %1
    %endif
%endmacro

; hang forever
%macro HANG16 0
    %%hang:
    %ifdef DEBUG
        VGA_MARK16 10
        VGA_MARK16 11
        VGA_MARK16 12
    %else
        hlt
    %endif
    jmp %%hang
%endmacro

%macro HANG32 0
    %%hang:
    %ifdef DEBUG
        VGA_MARK32 20
        VGA_MARK32 21
        VGA_MARK32 22
    %else
        hlt
    %endif
    jmp %%hang
%endmacro

; save volatile registers, ie. caller-saved registers
%macro SAVEVOL32 0
    sreg eax, ebx, ecx, edx
%endmacro

%macro RESVOL32 0
    rreg eax, ebx, ecx, edx
%endmacro

; save persistent registers, ie. callee-saved registers
%macro SAVEPER32 0
    sreg esi, edi, ebp
%endmacro

%macro RESPER32 0
    rreg esi, edi, ebp
%endmacro

; call bootloader function and save registers,
; only works on functions that don't return anything (since registers are overwritten)
%macro CALLB32 1
    SAVEVOL32
    call %1
    RESVOL32
%endmacro

; wait for a little bit
%macro BUSYWAIT 0
    sreg ax
    ; just an arbitrary value I picked since it's slow enough on my processor
    ; that I can read the output of operations as they're done
    %ifndef WAITITER
        mov eax, 0x004fffff
    %else
        mov eax. WAITITER ; wait time override
    %endif
    %%wait:
        dec eax
        jnz %%wait
    rreg ax
%endmacro

; number of sectors the stage 1 loader should read before jumping here
bootloader_sector_length db (end - $$ + 511) / 512
boot_drive db 0
align 16, db 0

; this should be at 0x8010
start:
    ; at this point cs, ds, es, and ss should be zeroed, and all interrupts should be disabled,

    lstr ax, `Starting.\r\n`
    call bios_puts

    VGA_MARK16 1

    call get_mmap

    VGA_MARK16 2

    cli
    lgdt [gdtr]
    mov eax, cr0
    or eax, 1 ; CR0.PE
    mov cr0, eax

    jmp 0x08:protected_mode

get_mmap:
    lstr ax, `Detecting memory.\r\n`
    call bios_puts

    lea di, [e820_arr]
    mov edx, SMAP
    mov ecx, 20 ; short entries, not extended ones
    xor ebx, ebx
    mov eax, 0xe820
    int 0x15
    jc fatal16
    cmp eax, SMAP
    jne fatal16
    cmp cl, 20 ; a bit paranoid
    jne fatal16
    cmp ebx, 0
    je .end

    ; first iter setup
    add byte [e820_arr_len], 1
    add di, 20

    ; call e820 until ebx is zero or the carry flag is set
    .loop:
        mov edx, SMAP
        mov ecx, 20
        mov eax, 0xe820
        int 0x15
        jc .end ; carry on a call other than first means end of list
        cmp byte [e820_arr_len], 254 ; stop collecting entries if it would overflow
        je .end
        cmp ebx, 0
        je .end
        cmp cl, 20
        jne fatal16
        add byte [e820_arr_len], 1
        add di, 20
        jmp .loop
    .end:

    add byte [e820_arr_len], 1

    lstr ax, `Finished detecting memory.\r\n`
    call bios_puts

    ret

fatal16:
    lstr ax, `Fatal error, hanging.\r\n`
    call bios_puts
    HANG16

bios_putc: ; args: al (char)
    %ifdef DEBUG
        BUSYWAIT
    %endif
    push bx
    mov ah, 0x0e
    xor bx, bx
    mov bl, 0x07
    int 0x10
    pop bx
    ret

bios_puts: ; args: ax (strptr)
    push bx
    mov bx, ax
    .loop:
    mov al, [bx]
    test al, al
    jz .end
    call bios_putc
    inc bx
    jmp .loop
    .end:
    pop bx
    ret

bits 32
fatal32:
    lstr eax, `Fatal error, hanging.\r\n`
    call bios_puts32
    HANG32

bits 16

tmp dd 0 ; buffer to save e/ax for preserving arguments during mode switches

; switch from real mode to protected mode,
; note that both this and real_mode_switch are bootloader-only functions,
; we don't implement anything like this in the forth image being loaded since that actually
; has its own drivers, using BIOS there would be incredibly inefficient
prot_mode_switch:
    mov [tmp], eax
    cli
    mov eax, cr0
    or eax, 1 ; CR0.PE
    mov cr0, eax
    jmp 0x08:.end
bits 32
    .end:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; shift return address down 2 bytes
    o16 pop ax
    and eax, 0xFFFF
    push eax
    mov eax, [tmp]
    ret

; switch from protected mode to real mode
real_mode_switch:
    mov [tmp], eax
    cli
    jmp 0x18:.pm16 ; intel says to not directly clear CR0.PE in a 32-bit segment
bits 16
    .pm16:
    mov eax, cr0
    and eax, 0xfffffffe
    mov cr0, eax
    jmp 0x0000:.end
    .end:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; shift return address up 2 bytes
    pop ax
    add sp, 2
    push ax
    mov eax, [tmp]
    ret
bits 32

%macro REAL 0
    call real_mode_switch
    bits 16
%endmacro

%macro PROT 0
    call prot_mode_switch
    bits 32
%endmacro

; wrapper for invoking bios_putc in protected mode
bios_putc32: ; args: al (char)
    REAL
    call bios_putc
    PROT
    ret

; wrapper for invoking bios_puts in protected mode
bios_puts32: ; args: ax (strptr)
    REAL
    call bios_puts
    PROT
    ret

; print a 32-bit hexadecimal integer
bios_puth32: ; args: number
    mov ebx, eax
    mov ecx, 8
    .loop:
        rol ebx, 4
        mov edx, ebx
        and edx, 0xf

        mov al, [hexchars + edx]
        call bios_putc32
        loop .loop
    ret

; print 0 or more e820 entries
print_mmap: ; no args
    xor ecx, ecx
    .loop:
        movzx eax, byte [e820_arr_len]
        mov dx, 20
        mul dx
        cmp ecx, eax
        je .exit
        push ecx

        lstr eax, `----ENTRY----\r\n`
        call bios_puts32

        ; address
        lstr eax, `ADDRESS = 0x`
        call bios_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 4]
        call bios_puth32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx]
        call bios_puth32
        lstr eax, `\r\n`
        call bios_puts32

        ; length
        lstr eax, `LENGTH = 0x`
        call bios_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 12]
        call bios_puth32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 8]
        call bios_puth32
        lstr eax, `\r\n`
        call bios_puts32

        ; type
        lstr eax, `TYPE = 0x`
        call bios_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 16]
        call bios_puth32
        lstr eax, `\r\n`
        call bios_puts32

        lstr eax, `-----END-----\r\n`
        call bios_puts32

        pop ecx
        add ecx, 20
        jmp .loop
    .exit:

    ret

; "bootloader allocate" (size, alignment, type) - Allocate <size> bytes aligned to an at least
; <alignment>-byte boundary (must be a power of 2), reserving the allocated memory
; as an e820 entry of type <type>.
; Returns the address of the aligned allocation and the address of the new entry,
; or NULL and NULL for failure.

; Performance is O(n), and will fail if allocation causes the e820_arr to exceed 255 entries,
; this function is intended for being called a few times when reserving memory for page tables or
; when loading a kernel/forth image, not for general-purpose allocation, as such, there is no equivalent bfree,
; the kernel or image loaded from disk is responsible for managing physical memory later.

; Note that the new entry's ADDRESS field may not necessarily be the same as the pointer returned by balloc,
; because of it returning an aligned pointer, this means the new entry may have some extra bytes at the
; start before the logical start of allocated memory.
; As such, if you need a stable identity for the entry then either use the returned entry address here,
; or ensure no overlapping entries and then do a linear search for a range containing the address.

balloc: ; args: size, alignment, type
    sreg esi, edi, ebp

    ; set up args
    mov esi, eax
    mov edi, ebx
    sub edi, 1 ; subtract here to make it a bit easier to align later
    mov ebp, ecx

    xor ecx, ecx
    .loop:
        movzx eax, byte [e820_arr_len]
        mov dx, 20
        mul dx
        cmp ecx, eax
        je .fail ; if loop ends without early return, we could not allocate memory

        ; only allocate from usable RAM
        cmp dword [e820_arr + ecx + e820_type_offset], e820_USABLE
        jne .skip

        ; only allocate from memory within the 4GB address space,
        ; technically we should only have 32-bit entries anyway since this is meant to run on an IdeaPad,
        ; but just in case someone tries to boot this on a processor supporting long mode, and has memory above the 4GB mark,
        ; then we shouldn't crash
        cmp dword [e820_arr + ecx + e820_base_offset + 4], 0
        jne .skip
        cmp dword [e820_arr + ecx + e820_length_offset + 4], 0
        jne .skip
        ; overflow check
        mov eax, [e820_arr + ecx + e820_base_offset]
        add eax, [e820_arr + ecx + e820_length_offset]
        jc .skip

        ; get aligned base by doing `eax = (base + (alignment - 1)) & ~(alignment - 1)`
        mov ebx, edi
        not ebx
        mov eax, [e820_arr + ecx + e820_base_offset]
        add eax, edi
        and eax, ebx

        ; skip if aligning base overflowed
        cmp eax, [e820_arr + ecx + e820_base_offset]
        jb .skip

        ; edx now has the post-alignment length of the entry, eax still has the aligned start
        mov ebx, eax
        sub ebx, [e820_arr + ecx + e820_base_offset]
        mov edx, [e820_arr + ecx + e820_length_offset]
        sub edx, ebx
        jc .skip ; underflow check

        ; reject entries too short to satisfy allocation
        cmp edx, esi
        jb .skip
        jne .split

        ; if exact match, just change the type and return this entry
        mov [e820_arr + ecx + e820_type_offset], ebp
        lea ebx, [e820_arr + ecx]
        jmp .end

        ; split from start and append new entry, return new entry
        .split:

        ; fail if we can't append a new entry for the split-off chunk
        cmp byte [e820_arr_len], 255
        je .fail

        ; ebx is now the pointer to the new entry we're appending
        sreg eax, edx
        movzx eax, byte [e820_arr_len]
        mov dx, 20
        mul dx
        lea ebx, [e820_arr + eax]
        rreg eax, edx

        ; shorten entry we're splitting from, putting its original start in edi
        mov edi, eax
        xchg edi, [e820_arr + ecx + e820_base_offset]
        mov [e820_arr + ecx + e820_length_offset], edx
        add [e820_arr + ecx + e820_base_offset], esi
        sub [e820_arr + ecx + e820_length_offset], esi

        ; set up new entry
        mov [ebx + e820_base_offset], edi
        mov dword [ebx + e820_base_offset + 4], 0
        mov dword [ebx + e820_length_offset + 4], 0
        mov [ebx + e820_type_offset], ebp

        ; now that we're done with splitting, we can use ecx to avoid having to spill eax to memory
        mov ecx, eax

        ; finish new entry be setting its length to (parent_base_aligned - parent_base) + allocation_size
        sub ecx, edi
        add ecx, esi
        mov [ebx + e820_length_offset], ecx

        ; finally, return
        inc byte [e820_arr_len]
        jmp .end

        .skip:
        add ecx, 20
        jmp .loop

    .fail:
    mov eax, 0
    mov ebx, 0
    .end:
    rreg esi, edi, ebp
    ret


; read sectors into a low-memory buffer using BIOS EDD
read_blocks_bios: ; args: lba, count
    ; BIOS functions are allowed to clobber registers,
    ; so we have to explicitly preserve all the callee-saved ones here
    SAVEPER32
    REAL

    mov [DAPS_lba], eax ; 32-bit LBA is enough for loading the kernel
    mov [DAPS_sectors], bl ; should not exceed 127 because some BIOSes will error

    lea si, [DAPS]
    mov ah, 0x42 ; read disk
    mov dl, [boot_drive]
    int 0x13 ; extended disk services
    jc fatal16
    test ah, ah
    jnz fatal16

    cli ; BIOS might try to reenable interrupts, don't let it
    PROT
    RESPER32
    ret

align 16, db 0
%define BBUFADDR (0x8000 + 32 * 1024)
DAPS:
    db 0x10, 0
    DAPS_sectors dw 0
    DAPS_buffer dw BBUFADDR % 16, BBUFADDR / 16 ; put the bounce buffer right after the bootloader
    DAPS_lba dq 0

read_blocks: ; args: lba, count, buf
    SAVEPER32

    ; save count and buf since we'll be updating these
    mov edx, eax ; lba
    mov esi, ebx ; count
    mov edi, ecx ; buf

    .loop:
        cmp ebx, 0
        je .end

        ; don't read more than 127 blocks (just under 64KB) at a time,
        ; because some BIOSes will error
        cmp ebx, 127
        jle .normal
        .too_high:
        mov ebx, 127
        .normal:

        ; read blocks into low-memory buffer
        CALLB32 read_blocks_bios

        add edx, ebx ; move disk cursor
        sub esi, ebx ; decrement the remaining count
        shl ebx, 9 ; ebx now contains the amount of bytes to copy into the output buffer
        
        ; copy the blocks we read into the final buffer
        lea eax, [BBUFADDR]
        .memcpy:
            cmp ebx, 0
            je .memcpy_end

            ; copy one byte
            mov cl, [eax]
            mov [edi], cl

            ; increment buffer cursors and decrement remaining count
            dec ebx
            inc eax
            inc edi
            jmp .memcpy
        .memcpy_end:

        ; set up lba and count for next iteration
        mov eax, edx
        mov ebx, esi
    .end:
    RESPER32
    ret

; mark the area containing the bootloader (0 - 0x20000) as BOOTLOADER_RESERVED
; note; this only creates a new entry, it does not remove existing ones,
; meaning that using this function will likely create an overlap with 1 or more entries,
; the caller must resolve this
reserve_bootloader:
    movzx eax, byte [e820_arr_len]
    cmp eax, 255
    jne .normal
    dec eax ; just discard the last entry, it can't be that important
    dec byte [e820_arr_len]
    .normal:

    mov ebx, eax
    shl eax, 4
    shl ebx, 2
    add eax, ebx
    add eax, e820_arr
    
    mov dword [eax + e820_base_offset], 0
    mov dword [eax + e820_base_offset + 4], 0
    mov dword [eax + e820_length_offset], 0x20000
    mov dword [eax + e820_length_offset + 4], 0
    mov dword [eax + e820_type_offset], e820_BOOTLOADER_RECLAIMABLE
    add byte [e820_arr_len], 1
    ret

; ascending bubble sort implementation, args: arr, len, el_size, compare_func
; compare_func must be a subroutine taking one argument el, and
; returning -1, 0, or 1 for A < B, A == B, A > B respectively.
sort:
    SAVEPER32

    ; before doing anything, if there's nothing to sort, don't sort anything
    cmp ebx, 2
    jl .sorted

    mov ebp, eax ; copy arr start into ebp
    imul ebx, ecx
    add ebx, eax
    ; since we read both i and i + 1 but compare i against
    ; the limit the limit must be 1 smaller to prevent a bounds error on i + 1
    sub ebx, ecx
    xor edi, edi ; edi holds the status of if the array was changed or not
    
    ; eax - cursor, ebx - limit, ecx - stride, edx - compare

    .loop:
        test edi, edi
        jnz .changed

        cmp eax, ebx
        je .sorted
        jmp .normal

        ; we can't blindly exit the loop without doing an
        ; extra pass to verify the array is sorted
        .changed:
        cmp eax, ebx
        jne .normal
        xor edi, edi ; clear "swapped" flag
        mov eax, ebp ; reset cursor
        jmp .loop
        .normal:

        ; call compare_func on el
        SAVEVOL32
        call edx
        mov esi, eax
        RESVOL32

        ; A > B despite coming before it
        cmp esi, 1
        je .unsorted

        add eax, ecx
        jmp .loop

    .sorted:
        RESPER32
        ret

    .unsorted:
        ; swap memory contents of adjacent elements

        ; esi = i, edi = remaining
        mov esi, eax
        mov edi, ecx

        sreg eax
        .copy: ; uses eax and edi for temporaries
            test edi, edi
            jz .endcopy

            ; swap one byte from element A to element B
            mov al, [esi]
            xchg al, [esi + ecx]
            xchg [esi], al

            inc esi
            dec edi
            jmp .copy
        .endcopy:
        rreg eax

        add eax, ecx
        mov edi, 1 ; mark the array as changed
        jmp .loop

; compare two boundary events
event_compare:
    ; first compare addresses
    mov ebx, [eax + 4]
    cmp ebx, [eax + 4 + 16]
    ja .greater
    jb .smaller

    mov ebx, [eax]
    cmp ebx, [eax + 16]
    ja .greater
    jb .smaller

    ; if addresses are equal, type decides
    mov ebx, [eax + 8]
    cmp ebx, [eax + 8 + 16]
    je .equal
    test ebx, ebx
    jz .greater
    jnz .smaller

    ; if addresses and types are equal, ordering is equal
    .equal:
    xor eax, eax
    ret
    .smaller:
    mov eax, -1
    ret
    .greater:
    mov eax, 1
    ret

; compare two e820 entries' start addresses
entry_compare:
    mov ebx, [eax]
    mov ecx, [eax + 4]

    cmp ebx, [eax + 20]
    ja .greater
    jb .smaller
    cmp ecx, [eax + 4 + 20]
    ja .greater
    jb .smaller

    .equal:
    xor eax, eax
    ret
    .smaller:
    mov eax, -1
    ret
    .greater:
    mov eax, 1
    ret

; compare whether one active memory type is more restrictive than another, args: A, B
memtype_max:
    mov ecx, 4 ; initialize with the priority for unknown types, which is the second highest
    mov edx, 4

    ; assign scalar priority score to event A and event B,
    ; storing in eax for A and edx for B
    .get_priority_a:
        cmp eax, 1
        cmove ecx, [mempr1] ; usable RAM is the lowest priority
        cmp eax, 2
        cmove ecx, [mempr3] ; firmware reserved loses to unknown types and to NVS
        cmp eax, 3
        cmove ecx, [mempr2] ; ACPI_RECLAIMABLE is reclaimable, and therefore loses to everything but usable RAM
        cmp eax, 4
        cmove ecx, [mempr4] ; NVS only loses to bad memory
        cmp eax, 5
        cmove ecx, [mempr5] ; bad memory should override everything else since it could be dangerous to access it

    .get_priority_b:
        cmp ebx, 1
        cmove edx, [mempr1]
        cmp ebx, 2
        cmove edx, [mempr3]
        cmp ebx, 3
        cmove edx, [mempr2]
        cmp ebx, 4
        cmove edx, [mempr4]
        cmp ebx, 5
        cmove edx, [mempr5]

    mov eax, ecx
    cmp ecx, edx
    cmovb eax, edx
    ret

; because CMOVcc can't deal with immediates
mempr1 dd 1
mempr2 dd 2
mempr3 dd 3
mempr4 dd 4
mempr5 dd 5

; macro for printing an event inside sanitize_smap
%macro PRINT_EVENT 0
    SAVEVOL32
    SAVEPER32
    mov ebp, eax

    lstr eax, `----EVENT----\r\n`
    call bios_puts32

    lstr eax, `ADDRESS = 0x`
    call bios_puts32
    mov eax, [ebp + 4]
    call bios_puth32
    mov eax, [ebp]
    call bios_puth32
    lstr eax, `\r\n`
    call bios_puts32

    lstr eax, `TYPE = 0x`
    call bios_puts32
    mov eax, [ebp + 8]
    call bios_puth32
    lstr eax, `\r\n`
    call bios_puts32

    lstr eax, `MEMTYPE = 0x`
    call bios_puts32
    mov eax, [ebp + 12]
    call bios_puth32
    lstr eax, `\r\n`
    call bios_puts32

    lstr eax, `-----END-----\r\n`
    call bios_puts32

    RESPER32
    RESVOL32
%endmacro

; Sanitize e820_arr, resolving overlaps, merging adjacent entries, and sorting it.
; Heavily inspired by e820_update_table in arch/x86/kernel/e820.c in the linux kernel.

; O(n^2) time complexity due to using bubble sort to sort the event array.
; O(n) space complexity due to keeping track of a few temporary arrays.
; For temporary allocations we use the 32KB starting at BBUFADDR.

; uses this struct for boundary events:

;    dq address
;    dd type ; either start or end, 4 bytes instead of 1 for alignment, zero means start, nonzero means end
;    dd mem_type ; e820_entry memory type

; and this one for active memory types:

; dd type
; dd count

sanitize_smap:
    SAVEPER32

    ; set up length of event array
    movzx eax, byte [e820_arr_len]
    shl eax, 1 ; each entry contributes a start and end event
    mov [BBUFADDR], eax ; length of event arr

    ; set up eax as loop cursor and ebx as limit,
    ; ecx is an extra cursor for the event array
    mov ebx, eax
    shl eax, 4
    shl ebx, 2
    add ebx, eax
    add ebx, e820_arr
    mov eax, e820_arr
    mov ecx, BBUFADDR + 16

    ; add boundary events for each e820 entry
    .add_event:
        cmp eax, ebx
        je .end_event_adding

        ; reason for using esi, and edi here is to
        ; prevent instruction dependencies slowing the CPU

        ; start event

            ; base
            mov edx, [eax]
            mov esi, [eax + 4]
            mov [ecx], edx
            mov [ecx + 4], esi

            ; type
            mov dword [ecx + 8], 0

            ; memtype
            mov edi, [eax + 16]
            mov [ecx + 12], edi

        ; end event

            ; base + length
            mov edx, [eax]
            mov esi, [eax + 4]
            add edx, [eax + 8]
            adc esi, [eax + 8 + 4]
            mov [ecx + 16], edx
            mov [ecx + 16 + 4], esi

            ; type
            mov dword [ecx + 16 + 8], -1

            ; memtype
            mov edi, [eax + 16]
            mov [ecx + 16 + 12], edi

        add ecx, 32
        add eax, 20
        jmp .add_event
    .end_event_adding:

    ; sort boundary events in ascending order by address,
    ; with the tie-breaker being the type (start|end),
    ; end events come before start events
    mov eax, BBUFADDR + 16
    mov ebx, [BBUFADDR]
    mov ecx, 16
    mov edx, event_compare
    call sort

    ; eax = event arr cursor, ebx = limit, ecx = e820_arr cursor
    mov eax, BBUFADDR + 16
    mov ebx, [BBUFADDR]
    shl ebx, 4 ; 16 bytes
    add ebx, eax
    mov ecx, e820_arr

    ; last_addr = esi:edi, esi is the low half, edi is the high half
    xor esi, esi
    xor edi, edi

    ; edx = active_types cursor, ebp = active_types limit
    mov ebp, BBUFADDR + (16 * 1024)
    mov edx, ebp

    mov byte [e820_arr_len], 0 ; since we'll be emitting new entries

    ; loop over boundary events and emit entries,
    ; the core idea is that the space between two boundary events represents an interval, 
    ; and the active types represent how many and what kinds of intervals are currently unfinished
    .process_event:
        cmp byte [e820_arr_len], 255 ; if we've filled the entry array then it would be useless to continue
        je .end_event_processing
        cmp eax, ebx
        je .end_event_processing

        %ifdef DEBUG
            PRINT_EVENT
        %endif

        ; if last_addr != event.addr && there is an active type,
        ; emit e820 entry with most restrictive type in the active array, advance ecx
        cmp esi, [eax]
        jne .addr_changed
        cmp edi, [eax + 4]
        je .after_addr
        .addr_changed:
            cmp edx, ebp ; no active intervals
            je .after_addr

            ; if entries are adjacent and same type, just
            ; make the last one longer instead of emitting a new one
            sreg edx, esi, edi
            ; last_entry.type == event.memtype
            mov edx, [eax + 12]
            cmp edx, [ecx - 20 + 16]
            jne .separate
            ; last_entry.end == event.addr
            mov esi, [ecx - 20]
            mov edi, [ecx - 20 + 4]
            add esi, [ecx - 20 + 8]
            adc edi, [ecx - 20 + 12]
            cmp esi, [eax]
            jne .separate
            cmp edi, [eax + 4]
            jne .separate
                ; last_entry.length = event.addr - last_entry.addr
                mov esi, [eax]
                mov edi, [eax + 4]
                sub esi, [ecx - 20]
                sbb edi, [ecx - 20 + 4]
                mov [ecx - 20 + 8], esi
                mov [ecx - 20 + 12], edi
                rreg edx, esi, edi
                jmp .after_addr
            .separate:
            rreg edx, esi, edi

            ; e820.base = last_addr
            mov [ecx], esi
            mov [ecx + 4], edi

            ; e820.length = event.addr - last_addr
            push dword [eax]
            push dword [eax + 4]

            xchg esi, [eax]
            xchg edi, [eax + 4]
            sub esi, [eax]
            sbb edi, [eax + 4]
            mov [ecx + 8], esi
            mov [ecx + 12], edi

            pop dword [eax + 4]
            pop dword [eax]

            ; from now until the next event we don't need last_addr so we can reuse esi and edi
            ; for loop variables to find the most restrictive active memtype

            ; esi = max_priority, edi = max_priority_type
            mov esi, 1
            mov edi, 1
            .check_type:
                cmp edx, ebp
                je .end_check_type

                SAVEVOL32
                mov eax, edi
                mov ebx, [edx]
                call memtype_max
                cmp esi, eax
                jne .new_max
                RESVOL32
                jmp .after_max
                .new_max:
                    mov esi, eax
                    RESVOL32
                    mov edi, [edx]
                .after_max:

                add edx, 8
                jmp .check_type
            .end_check_type:
            ; reset active_types cursor
            mov edx, BBUFADDR + (16 * 1024)

            ; e820.type = max_memtype(active_types)
            mov [ecx + 16], edi

            add ecx, 20
            inc byte [e820_arr_len]
        .after_addr:
        
        ; if event.type is zero, add event.memtype to active array
        mov esi, [eax + 12]
        cmp dword [eax + 8], 0
        jne .end_event
        ; find and increment type freq
        .add_type:
            cmp edx, ebp
            je .add_distinct_type

            cmp esi, [edx]
            je .end_add_type

            add edx, 8
            jmp .add_type
            .end_add_type:
            inc dword [edx + 4]
            jmp .after_type
            ; make new distinct type with freq 1
            .add_distinct_type:
            mov [ebp], esi
            mov dword [ebp + 4], 1
            add ebp, 8
        jmp .after_type

        ; if event.type is nonzero, remove event.memtype from active array
        .end_event:
            .remove_type:
            cmp esi, [edx]
            je .reduce_freq
            add edx, 8
            jmp .remove_type

            ; remove one instance
            .reduce_freq:
            dec dword [edx + 4]
            cmp dword [edx + 4], 0
            jne .after_type
            ; remove last occurence
            mov esi, [ebp - 8]
            mov edi, [ebp - 4]
            mov [edx], esi
            mov [edx + 4], edi
            sub ebp, 8
        .after_type:
        mov edx, BBUFADDR + (16 * 1024)

        ; last_addr = event.addr
        mov esi, [eax]
        mov edi, [eax + 4]

        ; advance to next event
        add eax, 16
        jmp .process_event
    .end_event_processing:

    RESPER32
    ret

protected_mode:
    ; by now we should be in protected mode with flat segmentation,
    ; BIOS functions will no longer work directly (since we haven't loaded an IDT we can still call them with a modeswitch)

    ; initialize segment registers
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    ; we already set sp in stage 1 but we need to make sure
    ; it's sane again since we switched memory models
    mov esp, 0x7c00

    VGA_MARK32 3

    lstr eax, `Entered protected mode.\r\n`
    call bios_puts32

    ; make sure physical allocator does not overwrite our stack or code
    lstr eax, `Reserving memory for bootloader.\r\n`
    call bios_puts32
    call reserve_bootloader

    lstr eax, `Sanitizing memory map.\r\n`
    call bios_puts32
    call sanitize_smap

    lstr eax, `Printing memory map:\r\n`
    call bios_puts32

    VGA_MARK32 4

    call print_mmap

    VGA_MARK32 5

    ; read image header
    mov eax, 64 ; lba
    mov ebx, 1 ; 1 sector
    mov ecx, 0x7c00 ; overwrite MBR code
    call read_blocks

parse_image:
    ; parse image header and read sections

    ; mark memory map location in runtime header
    movzx eax, byte [e820_arr_len]
    mov ebx, eax
    shl eax, 4
    shl ebx, 2
    add eax, ebx
    add eax, e820_arr

    mov dword [0x7c00], e820_arr
    mov dword [0x7c04], eax

    ; edi gets the amount of sections,
    ; and esi gets the address of the first section descriptor
    mov edi, [0x7c00 + 256 + 4]
    mov esi, 0x7c00 + 256 + 8

    ; parse section descriptor, allocate memory, and read from disk
    .loop:
        cmp edi, 0
        je .end

        ; print amount of memory the section takes up
        SAVEVOL32
        lstr eax, `Requesting 0x`
        call bios_puts32
        mov eax, [esi + 4]
        shl eax, 9
        call bios_puth32
        lstr eax, ` bytes of memory to load image section.\r\n`
        call bios_puts32
        RESVOL32

        ; allocate memory for section

        mov eax, [esi + 4] ; size
        shl eax, 9
        ; mark length in runtime header
        mov [esi - 256 + 4], eax

        mov ebx, 4096 ; aligment
        mov ecx, e820_FIF_SECTION ; type
        call balloc ; we ignore the returned entry address because we only care about the returned memory
        test eax, eax
        jz fatal32 ; if we cannot load image, bootloader failed

        SAVEVOL32
        sreg eax
        lstr eax, `Received memory at 0x`
        call bios_puts32
        rreg eax
        call bios_puth32
        lstr eax, `\r\n`
        call bios_puts32
        RESVOL32

        ; move start and end of section into runtime header
        mov [esi - 256], eax
        add [esi - 256 + 4], eax

        ; read section
        mov ecx, eax ; buffer is the allocated memory
        mov ebx, [esi + 4] ; sector count
        mov eax, [esi] ; lba
        call read_blocks

        add esi, 8
        dec edi
        jmp .loop
    .end:

    ; sort entries by address one more time for the new entries produced by the allocations we made
    mov eax, e820_arr
    movzx ebx, byte [e820_arr_len]
    mov ecx, 20
    mov edx, entry_compare
    call sort

    lstr eax, `Printing final memory map.\r\n`
    call bios_puts32
    call print_mmap

fix_pointers:
    mov edi, [0x7c08] ; edi points to start of word descriptor table

    mov ebx, edi ; cursor
    mov eax, [0x7c0c] ; limit

    ; make limit a multiple of 12
    sub eax, ebx
    mov esi, 12
    xor edx, edx
    div esi
    xor edx, edx
    mul esi
    add eax, ebx

    mov ecx, [0x7c10] ; word impl table base

    ; fix pointers from word descriptors to implementations
    .loop:
        cmp ebx, eax
        je .end

        ; since lengths of sections are
        ; in LBA, we don't actually know
        ; which of these word descriptors exist,
        ; but adding a number to an undefined
        ; descriptor should be fine,
        ; since it's still a valid memory access
        add [ebx], ecx

        add ebx, 12
        jmp .loop
    .end:

final:
    mov ebp, BBUFADDR ; initial stack is in the 32KB area previously used as a disk-read bounce buffer.

    mov eax, [0x7c00 + 256] ; word descriptor idx for image entry point
    mov ebx, eax
    shl eax, 3
    shl ebx, 2
    add eax, ebx ; word descriptors are 12 bytes each

    SAVEVOL32
    sreg eax
    lstr eax, `Entering image at address `
    call bios_puts32
    rreg eax
    mov eax, [edi + eax]
    call bios_puth32
    lstr eax, `\r\n`
    call bios_puts32
    RESVOL32

    call [edi + eax] ; enter image

fallthrough:
    lstr eax, `Reached end of bootloader code, if you are seeing this, it means the image returned unexpectedly.\r\n`
    call bios_puts32
    HANG32

align 8, db 0
gdt:
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

    ; real-mode transition segment since the intel programming manual for the N270
    ; says we need a 16-bit 64KB code segment *before* setting CR0.PE = 0.

    ; code, base = 0, limit = 64KB
    dw 0xffff ; limit 15:0
    dw 0 ; base 15:0
    db 0 ; base 23:16
    db 0b10011010 ; readable code segment, nonconforming
    db 0b00000000 ; last 4 bits in the limit, 4KB granularity and 32-bit size
    db 0 ; base 31:24

gdt_end:

gdtr:
dw gdt_end - gdt - 1 ; limit
dd gdt ; base

e820_arr_len db 0
e820_arr:
; space for 255 entries, we don't use the extended
; field so entries are 20 bytes rather than 24
times 20 * 255 db 0

; used for printing numbers
hexchars db "0123456789abcdef"
; mark the end so we can calculate how many sectors this takes up
end equ $

; print out size
%assign STAGE2_SIZE %eval(end - $$)
%warning Size of stage 2 is STAGE2_SIZE bytes
%if STAGE2_SIZE > (63 * 512)
    %error Executable too large.
%endif

; pad to 63 sectors, together with the boot sector
; this makes the pre-image disk be 64 sectors
times 512 * 63 - ($ - $$) db 0
