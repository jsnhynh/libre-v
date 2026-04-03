import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

/* TAGE - TAgged GEometric history length predictor */

module tage #(
    parameter GHR          = GHR_WIDTH,
    parameter B_ENTRIES    = BASE_ENTRIES,
    parameter T_ENTRIES    = TAGE_ENTRIES,
    parameter TABLES       = TAGE_TABLES,
    parameter T_TAG_WIDTH  = TAGE_TAG_WIDTH
)(
    input  logic clk, rst,

    input  logic            [FETCH_WIDTH-1:0][CPU_ADDR_BITS-1:0] pc,
    output tage_pred_t      [FETCH_WIDTH-1:0] pred_ports,

    input  tage_ghr_t       [FETCH_WIDTH-1:0] ghr_ports,
    input  tage_update_t    [FETCH_WIDTH-1:0] update_ports,

    output logic            [GHR-1:0] ghr
);

    localparam int HIST_LEN[TABLES-1:0] = '{4, 8, 16, 32};
    localparam int BASE_IDX_WIDTH = $clog2(B_ENTRIES);
    localparam int TAG_IDX_WIDTH  = $clog2(T_ENTRIES);

    typedef struct packed {
        logic                   val;
        logic [T_TAG_WIDTH-1:0] tag;
        logic [2:0]             ctr;
        logic [1:0]             u;
    } tag_entry_t;

    logic [1:0]     base_table [B_ENTRIES-1:0];
    tag_entry_t     tag_tables [TABLES-1:0][T_ENTRIES-1:0];
    logic [17:0]    reset_ctr;
    logic           reset_msb;

    function automatic logic [TAG_IDX_WIDTH-1:0] calc_index(
        input logic [CPU_ADDR_BITS-1:0] pc_in,
        input logic [GHR-1:0] hist,
        input int hist_len
    );
        logic [TAG_IDX_WIDTH-1:0] folded = '0;
        for (int i = 0; i < hist_len; i += TAG_IDX_WIDTH) begin
            logic [TAG_IDX_WIDTH-1:0] chunk;
            int rot = (i / TAG_IDX_WIDTH) % TAG_IDX_WIDTH;
            chunk = hist[i +: TAG_IDX_WIDTH];
            chunk = (chunk >> rot) | (chunk << (TAG_IDX_WIDTH - rot));
            folded ^= chunk;
        end
        return pc_in[TAG_IDX_WIDTH+1:2] ^ folded;
    endfunction

    function automatic logic [T_TAG_WIDTH-1:0] calc_tag(
        input logic [CPU_ADDR_BITS-1:0] pc_in,
        input logic [GHR-1:0] hist,
        input int hist_len
    );
        logic [T_TAG_WIDTH-1:0] folded = '0;
        for (int i = 0; i < hist_len; i += T_TAG_WIDTH) begin
            logic [T_TAG_WIDTH-1:0] chunk;
            int rot = ((i / T_TAG_WIDTH) + 1) % T_TAG_WIDTH;
            chunk = hist[i +: T_TAG_WIDTH];
            chunk = (chunk >> rot) | (chunk << (T_TAG_WIDTH - rot));
            folded ^= chunk;
        end
        return pc_in[T_TAG_WIDTH+TAG_IDX_WIDTH+1:TAG_IDX_WIDTH+2] ^ folded;
    endfunction

    function automatic logic [1:0] update_ctr_base(input logic [1:0] ctr, input logic taken);
        return taken ? ((ctr == 2'b11) ? ctr : (ctr + 1)) : ((ctr == 2'b00) ? ctr : (ctr - 1));
    endfunction

    function automatic logic [2:0] update_ctr(input logic [2:0] ctr, input logic taken);
        return taken ? ((ctr == 3'b111) ? ctr : (ctr + 1)) : ((ctr == 3'b000) ? ctr : (ctr - 1));
    endfunction

    function automatic logic [1:0] update_useful(
        input logic [1:0] u,
        input logic pred_taken,
        input logic actual_taken,
        input logic pred_alt
    );
        automatic logic [1:0] result = u;
        if ((pred_taken == actual_taken) && (pred_alt != actual_taken)) begin
            result = (u != 2'b11) ? (u + 1) : u;
        end else if ((pred_taken != actual_taken) && (pred_alt == actual_taken)) begin
            result = (u != 2'b00) ? (u - 1) : u;
        end
        return result;
    endfunction

    function automatic int alloc_provider_ord(
        input logic [$clog2(TABLES):0] provider
    );
        if (int'(provider) < TABLES) return int'(provider);
        else                         return -1;
    endfunction

    generate
        for (genvar p = 0; p < FETCH_WIDTH; p++) begin : gen_pred

            wire [BASE_IDX_WIDTH-1:0] base_idx = pc[p][BASE_IDX_WIDTH+1:2];
            wire base_pred = base_table[base_idx][1];

            wire [TAG_IDX_WIDTH-1:0]  idx [TABLES-1:0];
            wire [T_TAG_WIDTH-1:0]    tag [TABLES-1:0];
            wire [TABLES-1:0]         hit;

            for (genvar t = 0; t < TABLES; t++) begin : gen_table
                assign idx[t] = calc_index(pc[p], ghr, HIST_LEN[t]);
                assign tag[t] = calc_tag  (pc[p], ghr, HIST_LEN[t]);
                assign hit[t] = tag_tables[t][idx[t]].val && (tag_tables[t][idx[t]].tag == tag[t]);
            end

            logic [$clog2(TABLES):0] provider;
            logic provider_pred, altpred;

            always_comb begin
                provider      = TABLES;
                provider_pred = base_pred;
                altpred       = base_pred;

                for (int t = 0; t < TABLES; t++) begin
                    if (hit[t]) begin
                        altpred       = provider_pred;
                        provider      = t[$clog2(TABLES):0];
                        provider_pred = tag_tables[t][idx[t]].ctr[2];
                    end
                end
            end

            assign pred_ports[p].provider   = provider;
            assign pred_ports[p].pred_taken = provider_pred;
            assign pred_ports[p].pred_alt   = altpred;

        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) begin
            ghr <= '0;
        end else if (update_ports[0].val && (update_ports[0].pred_taken != update_ports[0].actual_taken)) begin
            ghr <= update_ports[0].ghr_cp;
        end else if (update_ports[1].val && (update_ports[1].pred_taken != update_ports[1].actual_taken)) begin
            ghr <= update_ports[1].ghr_cp;
        end else begin
            automatic logic [GHR-1:0] ghr_next = ghr;
            ghr_next = ghr_ports[0].val ? {ghr_next[GHR-2:0], ghr_ports[0].taken} : ghr_next;
            ghr_next = ghr_ports[1].val ? {ghr_next[GHR-2:0], ghr_ports[1].taken} : ghr_next;
            ghr <= ghr_next;
        end
    end

    logic [TAG_IDX_WIDTH-1:0]   tage_idx      [FETCH_WIDTH-1:0];
    logic [T_TAG_WIDTH-1:0]     tage_tag      [FETCH_WIDTH-1:0];
    logic [2:0]                 tage_ctr_next [FETCH_WIDTH-1:0];
    logic [1:0]                 tage_u_next   [FETCH_WIDTH-1:0];

    logic [TAG_IDX_WIDTH-1:0]   alloc_idx   [FETCH_WIDTH-1:0][TABLES-1:0];
    logic [T_TAG_WIDTH-1:0]     alloc_tag   [FETCH_WIDTH-1:0][TABLES-1:0];
    logic [TABLES-1:0]          alloc_hit   [FETCH_WIDTH-1:0];
    logic                       alloc_found [FETCH_WIDTH-1:0];
    logic [$clog2(TABLES)-1:0]  alloc_sel   [FETCH_WIDTH-1:0];

    always_comb begin
        int prov0, prov1;

        prov0 = int'(update_ports[0].provider);
        prov1 = int'(update_ports[1].provider);

        tage_idx[0]      = '0; tage_tag[0]      = '0; tage_ctr_next[0] = '0; tage_u_next[0] = '0;
        tage_idx[1]      = '0; tage_tag[1]      = '0; tage_ctr_next[1] = '0; tage_u_next[1] = '0;

        if (update_ports[0].val && (prov0 < TABLES)) begin
            tage_idx[0]      = calc_index(update_ports[0].pc, update_ports[0].ghr_cp, HIST_LEN[prov0]);
            tage_tag[0]      = calc_tag  (update_ports[0].pc, update_ports[0].ghr_cp, HIST_LEN[prov0]);
            tage_ctr_next[0] = tag_tables[prov0][tage_idx[0]].ctr;
            tage_u_next[0]   = tag_tables[prov0][tage_idx[0]].u;

            tage_ctr_next[0] = update_ctr(tage_ctr_next[0], update_ports[0].actual_taken);
            tage_u_next[0]   = update_useful(tage_u_next[0],
                                             update_ports[0].pred_taken,
                                             update_ports[0].actual_taken,
                                             update_ports[0].pred_alt);
        end

        if (update_ports[1].val && (prov1 < TABLES)) begin
            tage_idx[1]      = calc_index(update_ports[1].pc, update_ports[1].ghr_cp, HIST_LEN[prov1]);
            tage_tag[1]      = calc_tag  (update_ports[1].pc, update_ports[1].ghr_cp, HIST_LEN[prov1]);
            tage_ctr_next[1] = tag_tables[prov1][tage_idx[1]].ctr;
            tage_u_next[1]   = tag_tables[prov1][tage_idx[1]].u;

            if (update_ports[0].val && (prov0 < TABLES) && (prov0 == prov1) && (tage_idx[0] == tage_idx[1])) begin
                tage_ctr_next[0] = update_ctr(tage_ctr_next[0], update_ports[1].actual_taken);
                tage_u_next[0]   = update_useful(tage_u_next[0],
                                                 update_ports[1].pred_taken,
                                                 update_ports[1].actual_taken,
                                                 update_ports[1].pred_alt);
            end else begin
                tage_ctr_next[1] = update_ctr(tage_ctr_next[1], update_ports[1].actual_taken);
                tage_u_next[1]   = update_useful(tage_u_next[1],
                                                 update_ports[1].pred_taken,
                                                 update_ports[1].actual_taken,
                                                 update_ports[1].pred_alt);
            end
        end

        for (int u = 0; u < FETCH_WIDTH; u++) begin
            automatic logic mispred;
            automatic int provider_ord;

            alloc_found[u] = 1'b0;
            alloc_sel[u]   = '0;
            for (int t = 0; t < TABLES; t++) begin
                alloc_idx[u][t] = '0;
                alloc_tag[u][t] = '0;
                alloc_hit[u][t] = 1'b0;
            end

            mispred      = update_ports[u].val && (update_ports[u].pred_taken != update_ports[u].actual_taken);
            provider_ord = alloc_provider_ord(update_ports[u].provider);

            if (mispred) begin
                for (int t = 0; t < TABLES; t++) begin
                    alloc_idx[u][t] = calc_index(update_ports[u].pc, update_ports[u].ghr_cp, HIST_LEN[t]);
                    alloc_tag[u][t] = calc_tag  (update_ports[u].pc, update_ports[u].ghr_cp, HIST_LEN[t]);
                    alloc_hit[u][t] = tag_tables[t][alloc_idx[u][t]].val &&
                                      (tag_tables[t][alloc_idx[u][t]].tag == alloc_tag[u][t]);
                end

                for (int t = 0; t < TABLES; t++) begin
                    if (!alloc_found[u] &&
                        (t > provider_ord) &&
                        !alloc_hit[u][t] &&
                        (tag_tables[t][alloc_idx[u][t]].u == 2'b00)) begin
                        alloc_sel[u]   = t[$clog2(TABLES)-1:0];
                        alloc_found[u] = 1'b1;
                    end
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        int prov0_ff, prov1_ff;

        if (rst) begin
            for (int i = 0; i < B_ENTRIES; i++) base_table[i] = 2'b01;
            for (int t = 0; t < TABLES; t++) begin
                for (int i = 0; i < T_ENTRIES; i++) begin
                    tag_tables[t][i] = '{1'b0, '0, 3'b011, 2'b00};
                end
            end
            reset_ctr <= '0;
            reset_msb <= 1'b0;

        end else begin
            if (update_ports[0].val && (int'(update_ports[0].provider) >= TABLES)) begin
                automatic logic [BASE_IDX_WIDTH-1:0] bidx0;
                bidx0 = update_ports[0].pc[BASE_IDX_WIDTH+1:2];
                base_table[bidx0] <= update_ctr_base(base_table[bidx0], update_ports[0].actual_taken);
            end

            if (update_ports[1].val && (int'(update_ports[1].provider) >= TABLES)) begin
                automatic logic [BASE_IDX_WIDTH-1:0] bidx1;
                bidx1 = update_ports[1].pc[BASE_IDX_WIDTH+1:2];

                if (update_ports[0].val && (int'(update_ports[0].provider) >= TABLES) &&
                    (update_ports[0].pc[BASE_IDX_WIDTH+1:2] == bidx1)) begin
                    automatic logic [1:0] tmp;
                    tmp = update_ctr_base(base_table[bidx1], update_ports[0].actual_taken);
                    base_table[bidx1] <= update_ctr_base(tmp, update_ports[1].actual_taken);
                end else begin
                    base_table[bidx1] <= update_ctr_base(base_table[bidx1], update_ports[1].actual_taken);
                end
            end

            prov0_ff = int'(update_ports[0].provider);
            prov1_ff = int'(update_ports[1].provider);

            if (update_ports[0].val && (prov0_ff < TABLES)) begin
                tag_tables[prov0_ff][tage_idx[0]].ctr <= tage_ctr_next[0];
                tag_tables[prov0_ff][tage_idx[0]].u   <= tage_u_next[0];
            end

            if (update_ports[1].val && (prov1_ff < TABLES) &&
                !(update_ports[0].val && (prov0_ff < TABLES) && (prov0_ff == prov1_ff) && (tage_idx[0] == tage_idx[1]))) begin
                tag_tables[prov1_ff][tage_idx[1]].ctr <= tage_ctr_next[1];
                tag_tables[prov1_ff][tage_idx[1]].u   <= tage_u_next[1];
            end

            for (int u = 0; u < FETCH_WIDTH; u++) begin
                automatic logic mispred;
                automatic int provider_ord;
                mispred      = update_ports[u].val && (update_ports[u].pred_taken != update_ports[u].actual_taken);
                provider_ord = alloc_provider_ord(update_ports[u].provider);

                if (mispred) begin
                    if (alloc_found[u]) begin
                        tag_tables[alloc_sel[u]][alloc_idx[u][alloc_sel[u]]] <=
                            '{1'b1,
                              alloc_tag[u][alloc_sel[u]],
                              (update_ports[u].actual_taken ? 3'b100 : 3'b011),
                              2'b00};
                    end else begin
                        for (int t = 0; t < TABLES; t++) begin
                            if ((t > provider_ord) && !alloc_hit[u][t]) begin
                                tag_tables[t][alloc_idx[u][t]].u <=
                                    (tag_tables[t][alloc_idx[u][t]].u == 2'b00) ? 2'b00
                                                                                  : (tag_tables[t][alloc_idx[u][t]].u - 1);
                            end
                        end
                    end
                end
            end

            if (update_ports[0].val || update_ports[1].val) begin
                reset_ctr <= reset_ctr + 1;
                if (reset_ctr == '1) begin
                    reset_msb <= ~reset_msb;
                    for (int t = 0; t < TABLES; t++) begin
                        for (int i = 0; i < T_ENTRIES; i++) begin
                            tag_tables[t][i].u[reset_msb] = 1'b0;
                        end
                    end
                end
            end
        end
    end

endmodule
