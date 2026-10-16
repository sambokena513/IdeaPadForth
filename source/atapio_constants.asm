; port IO helpers

; "I/O" ports
%define ATA_pDATA 0 ; 16-bit param size, all others are 8-bit since we use LBA28
%define ATA_pERROR 1
%define ATA_pFEATURES 1
%define ATA_pSECTOR_COUNT 2
%define ATA_pLBAlo 3
%define ATA_pLBAmid 4
%define ATA_pLBAhi 5
%define ATA_pDRIVE 6
%define ATA_pSTATUS 7
%define ATA_pCOMMAND 7

; "Control" ports
%define ATA_pALT_STATUS 0 ; like status, but reading does not affect IRQs
%define ATA_pDEV_CTL 0
%define ATA_pDRIVE_ADDR 1

; errors
%define ATA_AMNF 1 ; address mark not found
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
