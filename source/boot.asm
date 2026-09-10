bits 16 ; we always start in 16-bit real mode
org 0x7c00 ; BIOS loads our code at this address

start:
    cli ; so that we and stage two start without being interrupted

    ; zero ds so the assembler can give us addresses within our boot sector
    xor ax, ax
    mov ds, ax

    ; print message so user knows their BIOS works
    lea ax, [msg]
    call putstr

    mov ah, 0x41
    mov bx, 0x55aa
    mov dl, 0x80 ; check if EDD is supported
    int 0x13
    jc fatal

    test cx, 1 ; first bit should be set if lba addressing is supported
    jz fatal

    mov si, DAPS
    mov ah, 0x42 ; read disk
    ; we don't set dl here since we didn't modify it and
    ; the BIOS starts our code with DL = drive number
    int 0x13
    jc fatal

    mov al, [DAPS_sector_count]
    dec al
    jz .handoff

    ; read extra sectors, stage two can be up to 127 sectors
    mov [DAPS_sector_count], al
    mov ax, 512
    add [DAPS_buffer], ax

    ; no need to set up si since its value has not changed
    mov ah, 0x42 ; read disk
    int 0x13
    jc fatal

    .handoff:
    lea ax, [endmsg]
    call putstr
    jmp 0x8010 ; jmp to the start of the stage 2 code

hang: ; loop forever
    hlt
    jmp hang

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

align 4 ; this struct needs 4-byte alignment
DAPS: ; disk address packet structure
db 0x10, 0x00
DAPS_sector_count dw 0x0001 ; number of sectors to transfer
DAPS_buffer dw 0x8000, 0x0000 ; offset, segment; buffer to read into
dq 1 ; lba address of first sector to read

errmsg db "STAGE1: Fatal error, hanging.", 13, 10, 0
msg db "STAGE1: Starting.", 13, 10, 0
endmsg db "STAGE1: Entering STAGE2.", 13, 10, 0
; leave partition table empty
times 64 db 0
; pad file to 512 bytes
times 510-($-$$) db 0
dw 0xaa55
