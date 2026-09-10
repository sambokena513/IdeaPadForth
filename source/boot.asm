bits 16 ; we always start in 16-bit real mode
org 0x7c00 ; BIOS loads our code at this address

start:
    ; zero ds so the assembler can give us addresses within our boot sector
    xor ax, ax
    mov ds, ax

    lea ax, [msg]
    call putstr

hang: ; loop forever
    hlt
    jmp hang

putstr: ; args: strptr (in ax) | clobbers: ax
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

msg db "Hello, world!", 0
; leave partition table empty
times 64 db 0
; pad file to 512 bytes
times 510-($-$$) db 0
dw 0xaa55
