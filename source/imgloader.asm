; forth image loader, this file's job is to
; set up everything needed to be able to boot
; the forth image starting at lba 128

; ABI note; we don't have a complex calling convention in the bootloader, especially in real mode, but once we switch to protected
; mode we treat the first four registers (eax, ebx, ecx, edx) as caller-saved, and the other four (esi, edi, ebp, esp) as callee-saved,
; and args as being in order in the first four registers. So a quaternary function is called with eax = arg1, ebx = arg2, ecx = arg3, and edx = arg4.

bits 16
org 0x8000 ; start just after boot sector

; number of sectors the stage 1 loader should read before jumping here
db (end - $$ + 511) / 512
boot_drive db 0
align 16

; this should be at 0x8010
start:
    ; at this point ds, es, and ss should be zeroed, and all interrupts should be disabled
    call serial_init

    lea ax, [startmsg]
    call serial_puts16

    ; todo: we should discover RAM with e820 before we exit real mode

    lgdt [gdtr]
    mov eax, cr0
    or eax, 1 ; CR0.PE
    mov cr0, eax

    jmp 0x08:protected_mode

get_mmap:
    ; todo: call int 0x15 EAX=0xE820 in a loop to populate our entry array
    ret

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

    mov al, '0'
    call serial_putc32
    mov al, 'x'
    call serial_putc32

    mov ecx, 8
    .loop:
        rol ebx, 4
        mov edx, ebx
        and edx, 0xf

        mov al, [hexchars + edx]
        call serial_putc32
        loop .loop
    ret
    

; todo: implement basic disk driver with read_blocks(lba, count, buf) and write_blocks(lba, count, buf) functions,
; our emulated disk is an ATA drive, don't try to support anything else

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

    lea ax, [prmmsg]
    call serial_puts32

    mov eax, esp
    call serial_puth32
    mov al, 13
    call serial_putc32
    mov al, 10
    call serial_putc32

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
errmsg db "STAGE2: Fatal error, hanging.", 13, 10, 0
startmsg db "STAGE2: Starting.", 13, 10, 0
e820msg db "STAGE2: Detecting memory.", 13, 10, 0
prmmsg db "STAGE2: Successfully entered protected mode.", 13, 10, 0

; mark the end so we can calculate how many sectors this takes up
end equ $

; pad to 127 sectors, together with the boot sector
; this makes the pre-image disk be 128 sectors
times 512 * 127 - ($ - $$) db 0
