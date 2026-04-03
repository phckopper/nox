`ifndef _MMU_PKG_
`define _MMU_PKG_

  // Sv39 page granularity (determined by which PTW level holds the leaf PTE)
  typedef enum logic [1:0] {
    PAGE_4K = 2'b00,   // 4 KiB  — leaf at level 0
    PAGE_2M = 2'b01,   // 2 MiB  — leaf at level 1 (megapage)
    PAGE_1G = 2'b10    // 1 GiB  — leaf at level 2 (gigapage)
  } sv39_page_size_t;

  // TLB access type (used for permission checking)
  typedef enum logic [1:0] {
    MMU_FETCH = 2'b00,
    MMU_LOAD  = 2'b01,
    MMU_STORE = 2'b10
  } mmu_access_t;

  // TLB entry
  typedef struct packed {
    logic            valid;
    logic            global_p;      // G: ignore ASID in match
    logic [15:0]     asid;
    logic [26:0]     vpn;          // {VPN[2],VPN[1],VPN[0]} = va[38:12]
    logic [43:0]     ppn;          // {PPN[2],PPN[1],PPN[0]} from PTE[53:10]
    sv39_page_size_t pgsz;
    logic            r, w, x, u;  // permission bits
  } sv39_tlb_entry_t;

  // MMU fault bundle (signals from MMU to pipeline)
  typedef struct packed {
    logic        instr_pf;   // instruction page fault  (cause 12)
    logic        load_pf;    // load page fault          (cause 13)
    logic        store_pf;   // store/AMO page fault     (cause 15)
    logic [63:0] va;         // faulting virtual address (→ stval; also mepc for instr_pf)
  } mmu_fault_t;

  // Sv39 PTE bit positions (64-bit PTE)
  `define SV39_PTE_V    0
  `define SV39_PTE_R    1
  `define SV39_PTE_W    2
  `define SV39_PTE_X    3
  `define SV39_PTE_U    4
  `define SV39_PTE_G    5
  `define SV39_PTE_A    6
  `define SV39_PTE_D    7
  `define SV39_PTE_PPN  53:10   // 44-bit concatenated PPN
  `define SV39_PTE_PPN0 18:10   //   PPN[0]: 9 bits
  `define SV39_PTE_PPN1 27:19   //   PPN[1]: 9 bits
  `define SV39_PTE_PPN2 53:28   //   PPN[2]: 26 bits

  // satp register fields (RV64 Sv39)
  `define SATP_PPN_F    43:0    // root page-table PPN
  `define SATP_ASID_F   59:44
  `define SATP_MODE_F   63:60

  `define SATP_MODE_BARE 4'd0
  `define SATP_MODE_SV39 4'd8

  // Page-fault exception causes (unsized to avoid width warnings)
  `define PF_INSTR  12
  `define PF_LOAD   13
  `define PF_STORE  15

`endif
