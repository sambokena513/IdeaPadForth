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

; number of sectors the stage 1 loader should read before jumping here
db (end - $$ + 511) / 512
boot_drive db 0
align 16

; this should be at 0x8010
start:
    ; at this point cs, ds, es, and ss should be zeroed, and all interrupts should be disabled

    call serial_init

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
serial_init:
    ; disable interrupts
    mov dx, COM1 + 1
    mov al, 0
    out dx, al

    ; enable DLAB, st baud divisor to 3 = 38400 baud
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al

    mov dx, COM1 + 0
    mov al, 3
    out dx, al

    ; 8 bits, no parity, 1 stop bit
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al

    ; enable FIFO, clear them, 14-byte threshold
    mov dx, COM1 + 2
    mov al, 0xc7
    out dx, al

    ; IRQs disabled, RST/DSR set
    mov dx, COM1 + 4
    mov al, 0x03
    out dx, al

    ret

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

read_blocks:
        ; todo: implement basic temporary disk driver with read_blocks(lba, count, buf) function,
        ; our emulated disk is an ATA drive, don't try to support anything else, use ATA PIO Mode (slow but easier to implement)
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

    ; todo: read image into memory with read_blocks(),
    ; and jump to image entry point
    ; img will then set up interrupts and handle entering long mode,

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
