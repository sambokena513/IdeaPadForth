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

; number of sectors the stage 1 loader should read before jumping here
bootloader_sector_length db (end - $$ + 511) / 512
boot_drive db 0
align 16

; this should be at 0x8010
start:
    ; at this point cs, ds, es, and ss should be zeroed, and all interrupts should be disabled,
    ; serial output should also be initialized by the MBR bootstrap

    lstr ax, `Starting. \r\n`
    call serial_puts16

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
    call serial_puts16

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
    call serial_puts16

    ret

fatal16:
    lstr ax, `Fatal error, hanging.\r\n`
    call serial_puts16
    HANG16

COM1 equ 0x3f8
serial_putc16: ; args: al (char) | clobbers: dx
    push ax

    .wait:
        mov dx, COM1 + 5
        in al, dx
        test al, 0x20
        jz .wait

        pop ax
        mov dx, COM1 + 0
        out dx, al
        ret

serial_puts16: ; args: ax (strptr) | clobbers: dx, bx
    mov bx, ax
    .loop:
    mov al, [bx]
    test al, al
    jz .end
    call serial_putc16
    inc bx
    jmp .loop
    .end:
    ret

; from now on this is protected-mode code
bits 32

fatal32:
    lstr eax, `Fatal error, hanging.\r\n`
    call serial_puts32
    HANG32

serial_putc32: ; args: char
    push eax

    .wait:
        mov dx, COM1 + 5
        in al, dx
        test al, 0x20
        jz .wait

        pop eax
        mov dx, COM1 + 0
        out dx, al
        ret

serial_puts32: ; args: strptr
    mov ebx, eax
    .loop:
    mov al, [ebx]
    test al, al
    jz .end
    call serial_putc32
    inc ebx
    jmp .loop
    .end:
    ret

serial_puth32: ; args: number
    mov ebx, eax
    mov ecx, 8
    .loop:
        rol ebx, 4
        mov edx, ebx
        and edx, 0xf

        mov al, [hexchars + edx]
        call serial_putc32
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
        call serial_puts32

        ; address
        lstr eax, `ADDRESS = 0x`
        call serial_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 4]
        call serial_puth32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx]
        call serial_puth32
        lstr eax, `\r\n`
        call serial_puts32

        ; length
        lstr eax, `LENGTH = 0x`
        call serial_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 12]
        call serial_puth32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 8]
        call serial_puth32
        lstr eax, `\r\n`
        call serial_puts32

        ; type
        lstr eax, `TYPE = 0x`
        call serial_puts32
        mov ecx, [esp]
        mov eax, [e820_arr + ecx + 16]
        call serial_puth32
        lstr eax, `\r\n`
        call serial_puts32

        lstr eax, `-----END-----\r\n`
        call serial_puts32

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
        ; only allocate from memory within the 4GB address space
        mov eax, [e820_arr + ecx + e820_base_offset]
        add eax, [e820_arr + ecx + e820_length_offset]
        cmp eax, [e820_arr + ecx + e820_base_offset]
        jb .skip

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
            call serial_puth32
            lstr eax, `\r\n`
            call serial_puts32
            mov eax, esi
            call serial_puth32
            lstr eax, `\r\n`
            call serial_puts32
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
            call serial_puth32
            lstr eax, `\r\n`
            call serial_puts32
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


bits 16
; reads up to 32 sectors of boot disk using BIOS EDD
read_blocks_bios: ; args: lba, count
    mov [DAPS_lba], ax
    mov [DAPS_sectors], bx

    sreg si
    lea si, [DAPS]
    mov ah, 0x42
    mov dl, [boot_drive]
    rreg si
    jc fatal16

    cli ; BIOS might try to reenable interrupts, don't let it
    ret
bits 32

align 16
DAPS:
    db 0x10, 0x00
    DAPS_sectors dw 0x0000
    DAPS_buffer dw 0x0000, 0x0000
    DAPS_lba dq 0x00000000

bits 16
prot_mode_switch:
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

    ; shift return address down 2 bytes
    o16 pop ax
    and eax, 0xFFFF
    push eax
    ret

real_mode_switch:
    cli
    mov eax, cr0
    and eax, 0xfffffffe
    mov cr0, eax
    jmp 0x0000:.end
    .end:
bits 16

    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; shift return address up 2 bytes
    pop ax
    mov bx, sp
    mov [bx], ax
    ret
bits 32

read_blocks: ; args: lba, count, buf
    call real_mode_switch
    bits 16
    lstr ax, `Hello from real mode!\r\n`
    call serial_puts16
    call prot_mode_switch
    bits 32
    ret

protected_mode:
    ; by now we should be in protected mode with flat segmentation, BIOS functions will no longer work

    ; initialize segment registers
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; we already set sp in stage 1 but we need to make sure
    ; it's sane again since we switched memory models
    mov esp, 0x7c00

    VGA_MARK32 3

    lstr eax, `Entered protected mode.\r\n`
    call serial_puts32

    lstr eax, `Printing memory map:\r\n`
    call serial_puts32

    VGA_MARK32 4

    call print_mmap

    VGA_MARK32 5

    call read_blocks

    ; todo: read image into memory

    ; todo: fix pointers

    ; todo: set up forth stacks

    ; todo: enter image

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
