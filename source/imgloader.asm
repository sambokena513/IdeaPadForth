; forth image loader, this file's job is to
; set up everything needed to be able to boot
; the forth image starting at lba 128

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

    ; todo: we should discover RAM before we exit real mode

    lgdt [gdtr]
    mov eax, cr0
    or eax, 1 ; CR0.PE
    mov cr0, eax

    jmp 0x08:protected_mode

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

bits 32

serial_putc32: ; args: al (char) | clobbers: edx
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

serial_puts32: ; args: eax (strptr) | clobbers: edx, ebx
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

; todo: implement basic disk driver with read_blocks(lba, count, buf) and write_blocks(lba, count, buf) functions, our emulated disk is an ATA drive

protected_mode:
    ; by now we should be in protected mode with flat segmentation, BIOS functions will no longer work

    lea ax, [prmmsg]
    call serial_puts32

    ; todo: read image into memory with read_blocks(),
    ; enter long mode, reenable maskable and nonmaskable interrupts,
    ; and jump to image entry point

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

startmsg db "STAGE2: Starting.", 13, 10, 0
prmmsg db "STAGE2: Entered protected mode.", 13, 10, 0

; mark the end so we can calculate how many sectors this takes up
end equ $

; pad to 127 sectors, together with the boot sector
; this makes the pre-image disk be 128 sectors
times 512 * 127 - ($ - $$) db 0
