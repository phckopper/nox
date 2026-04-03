/**
 * File   : tlb.sv
 * Date   : 2026-04-01
 *
 * Sv39 fully-associative TLB
 *
 * Combinational lookup: VPN + ASID (or global) → PA + permission check.
 * Round-robin replacement on refill.
 * SFENCE.VMA invalidation: by ASID, by VPN, both, or all entries.
 *
 * Superpage-aware VPN matching:
 *   PAGE_4K (level 0 leaf): match all 27 VPN bits
 *   PAGE_2M (level 1 leaf): match upper 18 bits (VPN[2:1]), ignore VPN[0] (va[20:12])
 *   PAGE_1G (level 2 leaf): match upper 9 bits  (VPN[2]),   ignore VPN[1:0] (va[29:12])
 *
 * Physical address construction:
 *   PAGE_4K: {ppn[43:0], va[11:0]}
 *   PAGE_2M: {ppn[43:9], va[20:12], va[11:0]}
 *   PAGE_1G: {ppn[43:18], va[29:12], va[11:0]}
 */
module tlb
  import nox_utils_pkg::*;
  import mmu_pkg::*;
#(
  parameter int ENTRIES = 32
)(
  input  logic            clk,
  input  logic            rst,

  // Lookup inputs
  input  logic [63:0]     va_i,
  input  logic [15:0]     asid_i,
  input  mmu_access_t     access_i,    // MMU_FETCH / MMU_LOAD / MMU_STORE
  input  logic [1:0]      priv_i,      // current privilege mode
  input  logic            mxr_i,       // make executable readable
  input  logic            sum_i,       // supervisor user-memory access

  // Lookup outputs (combinational)
  output logic            hit_o,
  output logic [55:0]     pa_o,        // physical address (56-bit Sv39 PA)
  output logic            perm_fault_o,// permission/protection fault

  // Refill from PTW
  input  logic            refill_valid_i,
  input  sv39_tlb_entry_t refill_entry_i,

  // SFENCE.VMA
  input  logic            sfence_i,
  input  logic [63:0]     sfence_vaddr_i,
  input  logic [63:0]     sfence_asid_i,
  input  logic            sfence_rs1_x0_i, // rs1=x0 → flush all VPNs
  input  logic            sfence_rs2_x0_i  // rs2=x0 → flush all ASIDs
);

  sv39_tlb_entry_t entries_ff [ENTRIES];
  logic [$clog2(ENTRIES)-1:0] victim_ff;

  // ---- Lookup (combinational) ----
  logic        hit_vec   [ENTRIES];
  logic [55:0] pa_vec    [ENTRIES];
  logic        pf_vec    [ENTRIES];

  logic [26:0] lookup_vpn;
  assign lookup_vpn = va_i[38:12];

  for (genvar i = 0; i < ENTRIES; i++) begin : g_lookup
    // Intermediate signals declared at generate scope (Verilator requires this)
    logic vpn_match;
    logic asid_match;
    logic perm_ok;

    always_comb begin
      // VPN match depends on page granularity
      unique case (entries_ff[i].pgsz)
        PAGE_4K: vpn_match = (entries_ff[i].vpn[26:0]  == lookup_vpn[26:0]);
        PAGE_2M: vpn_match = (entries_ff[i].vpn[26:9]  == lookup_vpn[26:9]);
        PAGE_1G: vpn_match = (entries_ff[i].vpn[26:18] == lookup_vpn[26:18]);
        default: vpn_match = 1'b0;
      endcase

      // ASID match: global pages ignore ASID
      asid_match = entries_ff[i].global_p || (entries_ff[i].asid == asid_i);

      hit_vec[i] = entries_ff[i].valid && vpn_match && asid_match;

      // Physical address construction
      unique case (entries_ff[i].pgsz)
        PAGE_4K: pa_vec[i] = {entries_ff[i].ppn[43:0],           va_i[11:0]};
        PAGE_2M: pa_vec[i] = {entries_ff[i].ppn[43:9],  va_i[20:12], va_i[11:0]};
        PAGE_1G: pa_vec[i] = {entries_ff[i].ppn[43:18], va_i[29:12], va_i[11:0]};
        default: pa_vec[i] = '0;
      endcase

      // Permission check
      perm_ok = 1'b1;
      unique case (access_i)
        MMU_FETCH: begin
          if (!entries_ff[i].x)                                    perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_U && !entries_ff[i].u)           perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_S &&  entries_ff[i].u)           perm_ok = 1'b0;
        end
        MMU_LOAD: begin
          if (!entries_ff[i].r && !(mxr_i && entries_ff[i].x))    perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_U && !entries_ff[i].u)           perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_S && entries_ff[i].u && !sum_i)  perm_ok = 1'b0;
        end
        MMU_STORE: begin
          if (!entries_ff[i].w)                                    perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_U && !entries_ff[i].u)           perm_ok = 1'b0;
          if (priv_i == `RV_PRIV_S && entries_ff[i].u && !sum_i)  perm_ok = 1'b0;
        end
        default: perm_ok = 1'b0;
      endcase
      pf_vec[i] = hit_vec[i] && !perm_ok;
    end
  end

  // Priority-encode the hit (at most one should fire; use OR-reduction for safety)
  always_comb begin
    hit_o        = 1'b0;
    pa_o         = '0;
    perm_fault_o = 1'b0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (hit_vec[i]) begin
        hit_o        = 1'b1;
        pa_o         = pa_vec[i];
        perm_fault_o = pf_vec[i];
      end
    end
  end

  // ---- Sequential: refill + SFENCE.VMA + victim counter ----
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      for (int i = 0; i < ENTRIES; i++)
        entries_ff[i] <= '0;
      victim_ff <= '0;
    end
    else begin
      // SFENCE.VMA: invalidate matching entries
      if (sfence_i) begin
        for (int i = 0; i < ENTRIES; i++) begin
          logic vaddr_match, asid_match;
          // rs1=x0 → match any VPN; rs2=x0 → match any ASID
          vaddr_match = sfence_rs1_x0_i ||
                        (entries_ff[i].vpn[26:18] == sfence_vaddr_i[38:30]) &&
                        (entries_ff[i].pgsz == PAGE_1G ||
                          (entries_ff[i].vpn[17:9] == sfence_vaddr_i[29:21] &&
                           (entries_ff[i].pgsz == PAGE_2M ||
                            entries_ff[i].vpn[8:0]  == sfence_vaddr_i[20:12])));
          asid_match  = sfence_rs2_x0_i ||
                        entries_ff[i].global_p ||
                        (entries_ff[i].asid == sfence_asid_i[15:0]);
          if (vaddr_match && asid_match)
            entries_ff[i].valid <= 1'b0;
        end
      end

      // Refill: write to victim slot; bump victim
      if (refill_valid_i) begin
        entries_ff[victim_ff] <= refill_entry_i;
        if (victim_ff == ($clog2(ENTRIES))'(ENTRIES-1))
          victim_ff <= '0;
        else
          victim_ff <= victim_ff + 1'b1;
      end
    end
  end

endmodule
