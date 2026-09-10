; forth image loader, this file's job is to
; set up everything needed to be able to boot
; the forth image starting at lba 128

bits 16
org 0x8000 ; start just after boot sector

; number of sectors the stage 1 loader should read before jumping here
db (end - $$ + 511) / 512
align 16

start: ; this should be 0x8010
    ; placholder, for now we just print a greeting message
    mov ah, 0x0e
    mov al, 'h'
    int 0x10
    mov ah, 0x0e
    mov al, 'i'
    int 0x10

hang:
    hlt
    jmp hang

end equ $

; pad to 127 sectors, together with the boot sector
; this makes the pre-image disk be 128 sectors
times 512 * 127 - ($ - $$) db 0
