bits 16 ; we always start in 16-bit real mode
org 0x7c00 ; BIOS loads our code at this address

start:
    jmp 0:.skip ; make sure CS is correct
    .skip:

    ; we reenable these in stage 2
    cli

    ; NMIs
    in al, 0x70
    or al, 0x80
    out 0x70, al

    ; zero ds so we can use absolute addresses for our first 64kb (the size of stage 1 + stage 2)
    xor ax, ax
    mov es, ax
    mov ss, ax
    mov ds, ax
    mov sp, 0x7c00 ; stack grows downwards from our bootstrap code

    mov [drive], dl

    ; initialize serial port so that the stage two bootloader and later the kernel
    ; can do debug logs, note that these are not meant to be user-visible messages,
    ; which is why we use bios "teletype" instead for the messages here
    call serial_init

    ; print message so user knows their BIOS loaded the bootloader succesfully
    lea ax, [startmsg]
    call bios_puts

    clc
    ; get available low memory, stage 2 later does
    ; `int 0x15, eax = 0xe820` to get extended memory
    int 0x12
    jc fatal
    ; stage 2 starts at 32KB, and may occupy space up to 64KB,
    ; so if we have less memory than that we can't boot
    cmp ax, 64
    jl fatal

    ; try to enable A20
    mov ax, 0x2403
    int 0x15
    jc fatal
    test ah, ah
    jnz fatal

    mov ax, 0x2402
    int 0x15
    jc fatal
    test ah, ah
    jnz fatal
    test al, al
    jnz .a20_activated

    mov ax, 0x2401
    int 0x15
    jc fatal
    test ah, ah
    jnz fatal

    .a20_activated:
    lea ax, [a20msg]
    call bios_puts

    ; check if EDD is supported
    mov dl, [drive]
    mov ah, 0x41
    mov bx, 0x55aa
    int 0x13
    jc fatal

    test cx, 1 ; first bit should be set if LBA addressing is supported
    jz fatal ; we don't deal with CHS since every BIOS since the 90s supports LBA, so we just fail here

    mov dl, [drive]
    mov si, DAPS
    mov ah, 0x42
    int 0x13
    jc fatal

    mov al, [0x8000] ; first byte of stage 2 is its length in disk sectors
    mov [0x8001], dl ; second byte of stage 2 is where we put the boot drive
    dec al ; since we already read 1 sector
    jz .handoff

    ; read extra sectors, stage two can be up to 127 sectors
    mov [DAPS_sector_count], al

    ; skip sector we already loaded
    add word [DAPS_buffer], 512
    mov byte [DAPS_lbaaddr], 2

    ; no need to set up si since its value has not changed
    mov ah, 0x42
    int 0x13
    jc fatal

    .handoff:
    lea ax, [endmsg]
    call bios_puts
    ; jmp to the start of the stage 2 code,
    ; +16 bytes because of the single-byte length header,
    ; and then padding to ensure stage 2 starts at a 16-byte aligned address
    jmp 0x8010

hang:
    hlt
    jmp hang

; no way to put complex error handling in 512 bytes,
; so we just make sure we don't corrupt anything by continuing execution
fatal:
    lea ax, [errmsg]
    call bios_puts
    jmp hang

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

bios_putc: ; args: al (char)
    push bx
    mov ah, 0x0e
    xor bx, bx
    mov bl, 0x07
    int 0x10
    pop bx
    ret

bios_puts: ; args: ax (strptr) | clobbers: bx
    mov bx, ax
    .loop:
    mov al, [bx]
    test al, al
    jz .end
    call bios_putc
    inc bx
    jmp .loop
    .end:
    ret

align 4
DAPS: ; disk address packet structure
db 0x10, 0x00
DAPS_sector_count dw 0x0001 ; number of sectors to transfer
DAPS_buffer dw 0x8000, 0x0000 ; offset, segment; buffer to read into
DAPS_lbaaddr dq 1 ; lba address of first sector to read

drive db 0
startmsg db "Serial port initialized.", 13, 10, 0
errmsg db "Fatal error, hanging.", 13, 10, 0
a20msg db "A20 gate enabled.", 13, 10, 0
endmsg db "Succesfully read stage 2 from disk, entering stage 2", 13, 10, 0
; leave partition table empty since we don't use partitioning
times 64 db 0
; pad file to 512 bytes
times 510-($-$$) db 0
dw 0xaa55
