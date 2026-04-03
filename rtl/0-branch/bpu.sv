import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module bpu (
    input  logic clk, rst,

    output logic flush,

    // Frontend - prediction
    input  logic [CPU_ADDR_BITS-1:0]        pc,
    output logic [CPU_ADDR_BITS-1:0]        pc_next,
    output logic [FETCH_WIDTH-1:0]          pc_vals,
    output branch_pred_t [FETCH_WIDTH-1:0]  pred,

    // Fetch-time FTQ alloc - driven by predecoder in fetch
    input  ftq_alloc_t [FETCH_WIDTH-1:0]  alloc_ports,

    // ROB commit
    input  commit_branch_port_t [FETCH_WIDTH-1:0] commit_branch,
    output logic                [FETCH_WIDTH-1:0] commit_mispredict
);

    //----------------------------------------------------------
    // BTB
    //----------------------------------------------------------
    btb_pred_t  [FETCH_WIDTH-1:0] btb_read;
    btb_write_t [FETCH_WIDTH-1:0] btb_write;

    btb u_btb (
        .clk         (clk),
        .rst         (rst),
        .pc          (pc),
        .read_ports  (btb_read),
        .write_ports (btb_write)
    );

    //----------------------------------------------------------
    // TAGE
    //----------------------------------------------------------
    tage_pred_t   [FETCH_WIDTH-1:0] tage_pred;
    tage_ghr_t    [FETCH_WIDTH-1:0] tage_ghr;
    tage_update_t [FETCH_WIDTH-1:0] tage_update;
    logic [GHR_WIDTH-1:0] ghr;

    tage u_tage (
        .clk          (clk),
        .rst          (rst),
        .pc           ({pc + 32'd4, pc}),
        .pred_ports   (tage_pred),
        .ghr_ports    (tage_ghr),
        .update_ports (tage_update),
        .ghr          (ghr)
    );

    //----------------------------------------------------------
    // RAS
    //----------------------------------------------------------
    logic [CPU_ADDR_BITS-1:0]     ras_peek_addr;
    logic                         ras_peek_rdy;
    logic                         ras_push, ras_pop;
    logic [CPU_ADDR_BITS-1:0]     ras_push_addr;
    logic                         ras_push_rdy, ras_pop_rdy;
    logic [$clog2(RAS_ENTRIES):0] ras_ptr;
    logic [$clog2(RAS_ENTRIES):0] recover_ptr;

    localparam int RET_PENDING_W = $clog2(FTQ_ENTRIES + 1);
    logic [RET_PENDING_W-1:0] ret_pending_cnt;
    logic                     ras_bypass_mode;

    assign ras_bypass_mode = (ret_pending_cnt != '0);

    ras u_ras (
        .clk         (clk),
        .rst         (rst),
        .peek_addr   (ras_peek_addr),
        .peek_rdy    (ras_peek_rdy),
        .push        (ras_push),
        .pop         (ras_pop),
        .push_addr   (ras_push_addr),
        .push_rdy    (ras_push_rdy),
        .pop_rdy     (ras_pop_rdy),
        .ptr         (ras_ptr),
        .recover     (flush),
        .recover_ptr (recover_ptr)
    );

    //----------------------------------------------------------
    // FTQ
    //----------------------------------------------------------
    logic [FETCH_WIDTH-1:0] ftq_enq_en, ftq_enq_rdy;
    ftq_entry_t [FETCH_WIDTH-1:0] ftq_enq_data;

    logic [FETCH_WIDTH-1:0] ftq_deq_en, ftq_deq_rdy;
    ftq_entry_t [FETCH_WIDTH-1:0] ftq_deq_data;

    ftq u_ftq (
        .clk      (clk),
        .rst      (rst),
        .flush    (flush),
        .enq_en   (ftq_enq_en),
        .enq_data (ftq_enq_data),
        .enq_rdy  (ftq_enq_rdy),
        .deq_en   (ftq_deq_en),
        .deq_data (ftq_deq_data),
        .deq_rdy  (ftq_deq_rdy)
    );

    //----------------------------------------------------------
    // Fetch-time prediction
    //----------------------------------------------------------
    logic [FETCH_WIDTH-1:0]   pred_taken;
    logic [CPU_ADDR_BITS-1:0] pred_target [FETCH_WIDTH-1:0];

    always_comb begin
        pred_taken     = '0;
        pred_target[0] = pc + 32'd4;
        pred_target[1] = pc + 32'd8;

        pred[0].btb  = btb_read[0];
        pred[1].btb  = btb_read[1];
        pred[0].tage = tage_pred[0];
        pred[1].tage = tage_pred[1];

        if (btb_read[0].hit) begin
            pred_target[0] = btb_read[0].targ;
            unique case (btb_read[0].btype)
                BRANCH_COND:              pred_taken[0] = tage_pred[0].pred_taken;
                BRANCH_JUMP, BRANCH_CALL: pred_taken[0] = 1'b1;
                BRANCH_RET: begin
                    pred_taken[0] = 1'b1;
                    if (!ras_bypass_mode && ras_peek_rdy) pred_target[0] = ras_peek_addr;
                end
                default: pred_taken[0] = 1'b0;
            endcase
        end

        if (!pred_taken[0] && btb_read[1].hit) begin
            pred_target[1] = btb_read[1].targ;
            unique case (btb_read[1].btype)
                BRANCH_COND:              pred_taken[1] = tage_pred[1].pred_taken;
                BRANCH_JUMP, BRANCH_CALL: pred_taken[1] = 1'b1;
                BRANCH_RET: begin
                    pred_taken[1] = 1'b1;
                    if (!ras_bypass_mode && ras_peek_rdy) pred_target[1] = ras_peek_addr;
                end
                default: pred_taken[1] = 1'b0;
            endcase
        end
    end

    //----------------------------------------------------------
    // RAS arbitration - slot0 wins when both want the port
    //
    // Temporary containment policy:
    // once a speculative RET is outstanding, younger CALL/RET traffic
    // bypasses RAS rather than mutating it. A same-cycle slot0 RET also
    // forces slot1 into bypass mode.
    //----------------------------------------------------------
    function automatic logic [$clog2(RAS_ENTRIES):0]
    ras_ptr_post(input logic [$clog2(RAS_ENTRIES):0] cur,
                 input logic do_push, input logic do_pop);
        if (do_push)     return cur + 1'b1;
        else if (do_pop) return cur - 1'b1;
        else             return cur;
    endfunction

    logic slot0_ras_push, slot0_ras_pop;
    logic slot1_ras_push, slot1_ras_pop;
    logic slot0_ret_alloc;
    logic slot0_ras_bypass, slot1_ras_bypass;

    assign slot0_ret_alloc   = alloc_ports[0].val && (alloc_ports[0].pred.btb.btype == BRANCH_RET);
    assign slot0_ras_bypass  = ras_bypass_mode;
    assign slot1_ras_bypass  = ras_bypass_mode || slot0_ret_alloc;

    always_comb begin
        slot0_ras_push = alloc_ports[0].val && !slot0_ras_bypass &&
                         (alloc_ports[0].pred.btb.btype == BRANCH_CALL) && ras_push_rdy;
        slot0_ras_pop  = alloc_ports[0].val && !slot0_ras_bypass &&
                         (alloc_ports[0].pred.btb.btype == BRANCH_RET)  && ras_pop_rdy;
        slot1_ras_push = alloc_ports[1].val && !slot1_ras_bypass &&
                         (alloc_ports[1].pred.btb.btype == BRANCH_CALL) && ras_push_rdy;
        slot1_ras_pop  = alloc_ports[1].val && !slot1_ras_bypass &&
                         (alloc_ports[1].pred.btb.btype == BRANCH_RET)  && ras_pop_rdy;

        ras_push = 1'b0;
        ras_pop = 1'b0;
        ras_push_addr = '0;
        if (slot0_ras_push) begin
            ras_push      = 1'b1;
            ras_push_addr = alloc_ports[0].pc + 32'd4;
        end else if (slot0_ras_pop) begin
            ras_pop = 1'b1;
        end else if (slot1_ras_push) begin
            ras_push      = 1'b1;
            ras_push_addr = alloc_ports[1].pc + 32'd4;
        end else if (slot1_ras_pop) begin
            ras_pop = 1'b1;
        end
    end

    //----------------------------------------------------------
    // GHR update requests - only conditional branches shift GHR
    //----------------------------------------------------------
    always_comb begin
        tage_ghr = '{default:'0};
        if (alloc_ports[0].val && alloc_ports[0].pred.btb.btype == BRANCH_COND) begin
            tage_ghr[0].val   = 1'b1;
            tage_ghr[0].taken = alloc_ports[0].pred.tage.pred_taken;
        end
        if (alloc_ports[1].val && alloc_ports[1].pred.btb.btype == BRANCH_COND) begin
            tage_ghr[1].val   = 1'b1;
            tage_ghr[1].taken = alloc_ports[1].pred.tage.pred_taken;
        end
    end

    //----------------------------------------------------------
    // FTQ enqueue
    //----------------------------------------------------------
    always_comb begin
        ftq_enq_en   = '0;
        ftq_enq_data = '{default:'0};

        if (alloc_ports[0].val && alloc_ports[1].val) begin
            ftq_enq_en[0]          = 1'b1;
            ftq_enq_data[0].val    = 1'b1;
            ftq_enq_data[0].pc     = alloc_ports[0].pc;
            ftq_enq_data[0].pred   = alloc_ports[0].pred;
            ftq_enq_data[0].pred.btb.targ = pred_target[0];
            ftq_enq_data[0].ghr_cp = ghr;
            ftq_enq_data[0].ras_cp = ras_ptr_post(ras_ptr, slot0_ras_push, slot0_ras_pop);

            ftq_enq_en[1]          = 1'b1;
            ftq_enq_data[1].val    = 1'b1;
            ftq_enq_data[1].pc     = alloc_ports[1].pc;
            ftq_enq_data[1].pred   = alloc_ports[1].pred;
            ftq_enq_data[1].pred.btb.targ = pred_target[1];
            ftq_enq_data[1].ghr_cp = tage_ghr[0].val ? {ghr[GHR_WIDTH-2:0], tage_ghr[0].taken} : ghr;
            ftq_enq_data[1].ras_cp = ras_ptr_post(
                ras_ptr_post(ras_ptr, slot0_ras_push, slot0_ras_pop),
                slot1_ras_push && !slot0_ras_push && !slot0_ras_pop,
                slot1_ras_pop  && !slot0_ras_push && !slot0_ras_pop
            );

        end else if (alloc_ports[0].val) begin
            ftq_enq_en[0]          = 1'b1;
            ftq_enq_data[0].val    = 1'b1;
            ftq_enq_data[0].pc     = alloc_ports[0].pc;
            ftq_enq_data[0].pred   = alloc_ports[0].pred;
            ftq_enq_data[0].pred.btb.targ = pred_target[0];
            ftq_enq_data[0].ghr_cp = ghr;
            ftq_enq_data[0].ras_cp = ras_ptr_post(ras_ptr, slot0_ras_push, slot0_ras_pop);

        end else if (alloc_ports[1].val) begin
            ftq_enq_en[0]          = 1'b1;
            ftq_enq_data[0].val    = 1'b1;
            ftq_enq_data[0].pc     = alloc_ports[1].pc;
            ftq_enq_data[0].pred   = alloc_ports[1].pred;
            ftq_enq_data[0].pred.btb.targ = pred_target[1];
            ftq_enq_data[0].ghr_cp = ghr;
            ftq_enq_data[0].ras_cp = ras_ptr_post(ras_ptr, slot1_ras_push, slot1_ras_pop);
        end
    end

    //----------------------------------------------------------
    // Commit-time dequeue + recovery
    //----------------------------------------------------------
    logic [FETCH_WIDTH-1:0]   commit_pop;
    logic                     slot0_commit_fire, slot1_commit_fire;
    logic                     slot0_commit_mispredict, slot1_commit_mispredict;
    logic [CPU_ADDR_BITS-1:0] correct_pc [FETCH_WIDTH-1:0];

    function automatic logic ftq_pred_taken(input ftq_entry_t e);
        unique case (e.pred.btb.btype)
            BRANCH_COND:              ftq_pred_taken = e.pred.tage.pred_taken;
            BRANCH_JUMP, BRANCH_CALL: ftq_pred_taken = e.pred.btb.hit;
            BRANCH_RET:               ftq_pred_taken = e.pred.btb.hit;
            default:                  ftq_pred_taken = 1'b0;
        endcase
    endfunction

    always_comb begin
        logic pred_taken_0, pred_taken_1;

        ftq_deq_en = '0;
        commit_pop = '0;

        pred_taken_0 = ftq_pred_taken(ftq_deq_data[0]);
        pred_taken_1 = ftq_pred_taken(ftq_deq_data[1]);

        slot0_commit_fire       = commit_branch[0].val && ftq_deq_rdy[0];
        slot1_commit_fire       = 1'b0;
        slot0_commit_mispredict = 1'b0;
        slot1_commit_mispredict = 1'b0;

        correct_pc[0] = ftq_deq_data[0].pc + 32'd4;
        correct_pc[1] = ftq_deq_data[1].pc + 32'd4;

        ftq_deq_en[0] = commit_branch[0].val;
        if (slot0_commit_fire) begin
            if ((pred_taken_0 != commit_branch[0].taken) ||
                (pred_taken_0 && commit_branch[0].taken &&
                 ftq_deq_data[0].pred.btb.targ != commit_branch[0].targ)) begin
                slot0_commit_mispredict = 1'b1;
                correct_pc[0] = commit_branch[0].taken ? commit_branch[0].targ
                                                       : ftq_deq_data[0].pc + 32'd4;
            end
        end

        ftq_deq_en[1] = commit_branch[1].val && !slot0_commit_mispredict;
        slot1_commit_fire = commit_branch[1].val && ftq_deq_rdy[1] && !slot0_commit_mispredict;
        if (slot1_commit_fire) begin
            if ((pred_taken_1 != commit_branch[1].taken) ||
                (pred_taken_1 && commit_branch[1].taken &&
                 ftq_deq_data[1].pred.btb.targ != commit_branch[1].targ)) begin
                slot1_commit_mispredict = 1'b1;
                correct_pc[1] = commit_branch[1].taken ? commit_branch[1].targ
                                                       : ftq_deq_data[1].pc + 32'd4;
            end
        end

        commit_pop[0] = slot0_commit_fire;
        commit_pop[1] = slot1_commit_fire;

        commit_mispredict[0] = slot0_commit_mispredict;
        commit_mispredict[1] = slot1_commit_mispredict | slot0_commit_mispredict;
        flush                = slot0_commit_mispredict | slot1_commit_mispredict;

        recover_ptr = slot0_commit_mispredict ? ftq_deq_data[0].ras_cp :
                      slot1_commit_mispredict ? ftq_deq_data[1].ras_cp :
                      ras_ptr;
    end

    //----------------------------------------------------------
    // PC select
    //----------------------------------------------------------
    always_comb begin
        pc_next = pc + 32'd8;
        pc_vals = 2'b11;

        if (rst) begin
            pc_next = PC_RESET;
            pc_vals = 2'b11;
        end else if (flush) begin
            pc_next = commit_mispredict[0] ? correct_pc[0] : correct_pc[1];
            pc_vals = 2'b00;
        end else if (pred_taken[0]) begin
            pc_next = pred_target[0];
            pc_vals = 2'b01;
        end else if (pred_taken[1]) begin
            pc_next = pred_target[1];
        end
    end

    //----------------------------------------------------------
    // Commit-time predictor updates
    //----------------------------------------------------------
    function automatic logic [GHR_WIDTH-1:0]
    corrected_ghr_cp(input ftq_entry_t e, input logic actual_taken);
        logic [GHR_WIDTH-1:0] cp;
        begin
            cp = e.ghr_cp;
            if (e.pred.btb.btype == BRANCH_COND)
                cp = {cp[GHR_WIDTH-2:0], actual_taken};
            return cp;
        end
    endfunction

    always_comb begin
        tage_update = '{default:'0};
        btb_write   = '{default:'0};

        if (commit_pop[0]) begin
            if (ftq_deq_data[0].pred.btb.btype == BRANCH_COND) begin
                tage_update[0].val          = 1'b1;
                tage_update[0].pc           = ftq_deq_data[0].pc;
                tage_update[0].actual_taken = commit_branch[0].taken;
                tage_update[0].provider     = ftq_deq_data[0].pred.tage.provider;
                tage_update[0].pred_taken   = ftq_deq_data[0].pred.tage.pred_taken;
                tage_update[0].pred_alt     = ftq_deq_data[0].pred.tage.pred_alt;
                tage_update[0].ghr_cp       = corrected_ghr_cp(ftq_deq_data[0], commit_branch[0].taken);
            end

            btb_write[0].val   = 1'b1;
            btb_write[0].pc    = ftq_deq_data[0].pc;
            btb_write[0].targ  = commit_branch[0].targ;
            btb_write[0].btype = ftq_deq_data[0].pred.btb.btype;
            btb_write[0].taken = commit_branch[0].taken;
        end

        if (commit_pop[1]) begin
            if (ftq_deq_data[1].pred.btb.btype == BRANCH_COND) begin
                tage_update[1].val          = 1'b1;
                tage_update[1].pc           = ftq_deq_data[1].pc;
                tage_update[1].actual_taken = commit_branch[1].taken;
                tage_update[1].provider     = ftq_deq_data[1].pred.tage.provider;
                tage_update[1].pred_taken   = ftq_deq_data[1].pred.tage.pred_taken;
                tage_update[1].pred_alt     = ftq_deq_data[1].pred.tage.pred_alt;
                tage_update[1].ghr_cp       = corrected_ghr_cp(ftq_deq_data[1], commit_branch[1].taken);
            end

            btb_write[1].val   = 1'b1;
            btb_write[1].pc    = ftq_deq_data[1].pc;
            btb_write[1].targ  = commit_branch[1].targ;
            btb_write[1].btype = ftq_deq_data[1].pred.btb.btype;
            btb_write[1].taken = commit_branch[1].taken;
        end
    end

    //----------------------------------------------------------
    // Speculative RET tracking for temporary RAS bypass mode
    //----------------------------------------------------------
    logic [1:0] ret_enq_cnt, ret_deq_cnt;

    always_comb begin
        ret_enq_cnt = '0;
        ret_deq_cnt = '0;

        if (ftq_enq_en[0] && ftq_enq_data[0].pred.btb.btype == BRANCH_RET)
            ret_enq_cnt = ret_enq_cnt + 2'd1;
        if (ftq_enq_en[1] && ftq_enq_data[1].pred.btb.btype == BRANCH_RET)
            ret_enq_cnt = ret_enq_cnt + 2'd1;

        if (commit_pop[0] && ftq_deq_data[0].pred.btb.btype == BRANCH_RET)
            ret_deq_cnt = ret_deq_cnt + 2'd1;
        if (commit_pop[1] && ftq_deq_data[1].pred.btb.btype == BRANCH_RET)
            ret_deq_cnt = ret_deq_cnt + 2'd1;
    end

    always_ff @(posedge clk) begin
        if (rst || flush)
            ret_pending_cnt <= '0;
        else
            ret_pending_cnt <= ret_pending_cnt + RET_PENDING_W'(ret_enq_cnt) - RET_PENDING_W'(ret_deq_cnt);
    end

    //----------------------------------------------------------
    // Assertions
    //----------------------------------------------------------
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            assert (ret_pending_cnt <= FTQ_ENTRIES)
                else $fatal(1, "BPU: ret_pending_cnt overflow (%0d)", ret_pending_cnt);
            assert (!(alloc_ports[0].val &&
                      alloc_ports[0].pred.btb.btype != BRANCH_COND &&
                      alloc_ports[1].val))
                else $fatal(1, "BPU: slot1 valid while slot0 is unconditional (btype=%0b)",
                            alloc_ports[0].pred.btb.btype);
        end
    end
    `endif

endmodule
