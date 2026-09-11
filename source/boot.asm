bits 16 ; we always start in 16-bit real mode
org 0x7c00 ; BIOS loads our code at this address

start:
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

    ; print message so user knows their BIOS loaded the bootloader succesfully
    lea ax, [startmsg]
    call putstr

    ; try to enable A20
    mov ax, 0x2403
    int 0x15
    jc fatal
    test ah, ah
    jc fatal

    mov ax, 0x2402
    int 0x15
    jc fatal
    test ah, ah
    jc fatal
    test al, al
    jnz .a20_activated

    mov ax, 0x2401
    int 0x15
    jc fatal
    test ah, ah
    jnz fatal

    .a20_activated:
    lea ax, [a20msg]
    call putstr

    ; check if EDD is supported
    mov ah, 0x41
    mov bx, 0x55aa
    int 0x13
    jc fatal

    test cx, 1 ; first bit should be set if LBA addressing is supported
    jz fatal ; we don't deal with CHS since every BIOS since the 90s supports LBA, so we just fail here

    mov si, DAPS
    mov ah, 0x42 ; note that we don't set dl here since BIOS starts our code with DL = the drive being booted
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
    call putstr
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
    call putstr
    jmp hang

putstr: ; args: strptr (in ax)
    mov bx, ax
    .loop:
        mov al, [bx]
        cmp al, 0
        jne .char
        ret
    .char:
        mov ah, 0x0e ; teletype
        int 0x10 ; graphics interrupt
        inc bx
        jmp .loop

align 4
DAPS: ; disk address packet structure
db 0x10, 0x00
DAPS_sector_count dw 0x0001 ; number of sectors to transfer
DAPS_buffer dw 0x8000, 0x0000 ; offset, segment; buffer to read into
DAPS_lbaaddr dq 1 ; lba address of first sector to read

errmsg db "STAGE1: Fatal error, hanging.", 13, 10, 0
startmsg db "STAGE1: Starting.", 13, 10, 0
a20msg db "STAGE1: A20 gate enabled.", 13, 10, 0
endmsg db "STAGE1: Succesfully read STAGE2 from disk, entering STAGE2.", 13, 10, 0
; leave partition table empty since we don't use partitioning
times 64 db 0
; pad file to 512 bytes
times 510-($-$$) db 0
dw 0xaa55
