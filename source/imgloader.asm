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
; but we have 32KB of code space here, so it's not really an issue for the convenience
%macro lstr 2+
    jmp %%skip
    %%string:
    db %2,0
    %%skip:
    lea %1,%%string
%endmacro

%macro sreg 1-*
    %rep %0
        push %1
        %rotate 1
    %endrep
%endmacro

%macro rreg 1-*
    %rep %0
        %rotate -1
        pop %1
    %endrep
%endmacro

; number of sectors the stage 1 loader should read before jumping here
db (end - $$ + 511) / 512
boot_drive db 0
align 16

; this should be at 0x8010
start:
    ; at this point cs, ds, es, and ss should be zeroed, and all interrupts should be disabled,
    ; serial output should also be initialized by the MBR bootstrap

    lstr ax, `Starting. \r\n`
    call serial_puts16

    call get_mmap

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

    lstr ax, `Finished detecting memory.\r\n`
    call serial_puts16

    ret

fatal16:
    lstr ax, `Fatal error, hanging.\r\n`
    call serial_puts16
    .hang:
        hlt
        jmp .hang

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
    .hang:
        hlt
        jmp .hang

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

; "bootloader allocate" - Allocate <size> bytes aligned to an at least
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

; 32-bit version of balloc, skips entries outside the 32-bit address space, cannot allocate more than 4GB of memory
; or return a pointer over 4GB
balloc32: ; args: size, type, alignment
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
        
        ; todo: after finding a suitable entry, if its length is enough to *exactly* satisfy allocation, change its type to <type> and just
        ;       return a pointer to this memory
        ;       else: split it and append new entry, return pointer to that entry and its memory

        ; placeholder
        sreg ecx
        call serial_puth32
        lstr eax, `\r\n`
        call serial_puts32
        rreg ecx

        .skip:
        add ecx, 20
        jmp .loop

    .fail:
    mov eax, 0
    mov ebx, 0
    .end:
    rreg esi, edi, ebp
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

    lstr eax, `Entered protected mode.\r\n`
    call serial_puts32

    lstr eax, `Printing memory map:\r\n`
    call serial_puts32

    call print_mmap

    ; placeholder for testing balloc
    mov eax, 16777216 ; 4096 pages
    mov ebx, 4096 ; page-aligned
    mov ecx, 6
    call balloc32

    ; todo: set up page tables with identity mapping, and enter long mode

    .hang: ; placeholder, when paging is done this'll be a far jump into our long mode code
    hlt
    jmp .hang

bits 64 ; long mode code

fatal64:
    lstr rax, `Fatal error, hanging.\r\n`
    call serial_puts64
    .hang:
        hlt
        jmp .hang

serial_putc64: ; args: char
    push rax

    .wait:
        mov dx, COM1 + 5
        in al, dx
        test al, 0x20
        jz .wait

        pop rax
        mov dx, COM1 + 0
        out dx, al
        ret

serial_puts64: ; args: strptr
    mov rbx, rax
    .loop:
    mov al, [rbx]
    test al, al
    jz .end
    call serial_putc64
    inc rbx
    jmp .loop
    .end:
    ret

serial_puth64: ; args: number
    mov rbx, rax
    mov rcx, 8
    .loop:
        rol rbx, 4
        mov rdx, rbx
        and rdx, 0xf

        mov al, [hexchars + rdx]
        call serial_putc64
        loop .loop
    ret

; port IO helpers, since this is a temporary driver and we're explicitly not trying to support new hardware, we can hardcode these numbers
%define ATA_pBASE 0x1f0

; "I/O" ports
%define ATA_pDATA ATA_pBASE ; 16-bit param size, all others are 8-bit since we use LBA28
%define ATA_pERROR ATA_pBASE + 1
%define ATA_pFEATURES ATA_pBASE + 1
%define ATA_pSECTOR_COUNT ATA_pBASE + 2
%define ATA_pLBAlo ATA_pBASE + 3
%define ATA_pLBAmid ATA_pBASE + 4
%define ATA_pLBAhi ATA_pBASE + 5
%define ATA_pDRIVE ATA_pBASE + 6
%define ATA_pSTATUS ATA_pBASE + 7
%define ATA_pCOMMAND ATA_pBASE + 7

; "Control" ports
%define ATA_pCTL_BASE 0x3f6
%define ATA_pALT_STATUS ATA_pCTL_BASE ; like status, but reading does not affect IRQs
%define ATA_pDEV_CTL ATA_pCTL_BASE
%define ATA_pDRIVE_ADDR ATA_pCTL_BASE + 1

; errors
%define ATA_MNF 1 ; address mark not found
%define TKZNF 2 ; track zero not found
%define ABRT 4 ; aborted
%define MCR 8 ; media change request
%define IDNF 16 ; id not found
%define MC 32 ; media changed
%define UNC 64 ; uncorrectable media error
%define BBK 128 ; bad block

; status
%define ERR 1 ; error occurred
%define IDX 2 ; index, always set to 0
%define CORR 4 ; corrected data, always set to 0
%define DRQ 8 ; data request
%define SRV 16 ; overlapped mode service request
%define DF 32 ; drive fault (does not set ERR)
%define RDY 64 ; ready
%define BSY 128 ; busy


read_blocks: ; args: lba, count, buf
    ; todo, wrap READ_SECTOR(S)
    ret

long_mode:
    lstr rax, "Entered long mode.\r\n"
    call serial_puts32 ; can still run 32-bit code

    ; todo: load and enter image

hang:
    hlt
    jmp hang

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

; pad to 127 sectors, together with the boot sector
; this makes the pre-image disk be 128 sectors
times 512 * 127 - ($ - $$) db 0
