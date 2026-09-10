bits 16 ; we always start in 16-bit real mode
org 0x7c00 ; BIOS loads our code at this address

start:
    mov ah, 0x0e ; teletype
    mov al, 'H'
    int 0x10 ; BIOS interrupt
    mov al, 'i'
    int 0x10

hang:
    hlt
    jmp hang

; leave partition table empty
times 64 db 0
; pad file to 512 bytes
times 510-($-$$) db 0
dw 0xaa55
