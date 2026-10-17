; forth image loader, this file's job is to
; set up everything needed to be able to boot
; the forth image starting at lba 128

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

; wait for a little bit
%macro BUSYWAIT 0
    sreg ax
    ; just an arbitrary value I picked since it's slow enough on my processor
    ; that I can read the output of operations as they're done
    mov eax, 0x004fffff
    %%wait:
        dec eax
        jnz %%wait
    rreg ax
%endmacro

; number of sectors the stage 1 loader should read before jumping here
bootloader_sector_length db (end - $$ + 511) / 512
boot_drive db 0
align 16

; this should be at 0x8010
start:
    ; at this point cs, ds, es, and ss should be zeroed, and all interrupts should be disabled,
    ; serial output should also be initialized by the MBR bootstrap

    lstr ax, `Starting. \r\n`
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

; Performance is O(n), and will fail if allocation causes the e820_arr to to exceed 255 entries,
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

        ; get aligned base by doing `eax = (base + (alignment - 1)) & ~(alignment - 1)`
        mov ebx, edi
        not ebx
        mov eax, [e820_arr + ecx + e820_base_offset]
        add eax, edi
        and eax, ebx

        ; edx now has the post-alignment length of the entry, eax still has the aligned start
        mov ebx, eax
        sub ebx, [e820_arr + ecx + e820_base_offset]
        mov edx, [e820_arr + ecx + e820_length_offset]
        sub edx, ebx

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

        %ifdef DEBUG
            ; print entry start, and amount to allocate
            sreg eax, ebx, ecx, edx
            call bios_puth32
            lstr eax, `\r\n`
            call bios_puts32
            mov eax, esi
            call bios_puth32
            lstr eax, `\r\n`
            call bios_puts32
            rreg eax, ebx, ecx, edx
        %endif

        ; ebx is now the pointer to the new entry we're appending
        sreg eax, edx
        movzx eax, byte [e820_arr_len]
        mov dx, 20
        mul dx
        lea ebx, [e820_arr + eax]
        rreg eax, edx

        %ifdef DEBUG
            ; print new entry pointer
            sreg eax, ebx, ecx, edx
            mov eax, ebx
            call bios_puth32
            lstr eax, `\r\n`
            call bios_puts32
            rreg eax, ebx, ecx, edx
        %endif

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
    REAL
    ; BIOS functions are allowed to clobber registers,
    ; so we have to explicitly preserve all the callee-saved ones here
    sreg si, di, bp, sp

    mov [DAPS_lba], eax ; 32-bit LBA is enough for loading the kernel
    mov [DAPS_sectors], bl ; should not exceed 127 because some BIOSes will error

    lea si, [DAPS]
    mov ah, 0x42 ; read disk
    mov dl, [boot_drive]
    int 0x13 ; extended disk services
    jc fatal16

    cli ; BIOS might try to reenable interrupts, don't let it
    rreg si, di, bp, sp
    PROT
    ret

align 16
%define BBUFADDR 0x8000 + 32 * 1024
DAPS:
    db 0x10, 0
    DAPS_sectors dw 0
    DAPS_buffer dw (BBUFADDR / 16), BBUFADDR % 16 ; put the bounce buffer right after the bootloader
    DAPS_lba dq 0

read_blocks: ; args: lba, count, buf
    ; save count and buf since we'll be updating these
    mov edx, eax ; lba
    mov esi, ebx ; count
    mov edi, ecx ; buf

    .loop:
        cmp ebx, 0
        je .end

        ; don't read more than 64 blocks (32KB) at a time
        cmp ebx, 64
        jle .normal
        .too_high:
        mov ebx, 64
        .normal:

        ; read blocks into low-memory buffer
        call read_blocks_bios

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
    ret

protected_mode:
    ; by now we should be in protected mode with flat segmentation, BIOS functions will no longer work

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

    lstr eax, `Printing memory map:\r\n`
    call bios_puts32

    VGA_MARK32 4

    call print_mmap

    VGA_MARK32 5

    ; read image header
    mov eax, 64
    mov ebx, 1
    mov ecx, 0x7c00
    call read_blocks

    ; todo: parse image header and read image into memory

    ; todo: fix image pointers

    ; todo: set up forth stacks

    ; todo: enter image

    lstr eax, `Reached end of bootloader code, if you are seeing this, it means the image handoff failed.\r\n`
    call bios_puts32
    HANG32

align 8
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

; pad to 63 sectors, together with the boot sector
; this makes the pre-image disk be 64 sectors
times 512 * 63 - ($ - $$) db 0
