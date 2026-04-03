`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

// ============================================================================
// BPU Integration Testbench
//   - Fetch PC input / pc_next + pc_vals output
//   - Decode alloc_ports (FTQ / GHR / RAS dispatch)
//   - ROB commit_branch (mispredict detection and recovery)
// ============================================================================
module bpu_tb;

    // ------------------------------------------------------------------------
    // Scoreboard
    // ------------------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;

    // ------------------------------------------------------------------------
    // Clock and reset
    // ------------------------------------------------------------------------
    logic clk = 0;
    logic rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ------------------------------------------------------------------------
    // DUT ports
    // ------------------------------------------------------------------------
    logic                                  flush;
    logic [CPU_ADDR_BITS-1:0]              fetch_pc;
    logic [CPU_ADDR_BITS-1:0]              fetch_pc_next;
    logic [FETCH_WIDTH-1:0]                fetch_pc_vals;
    ftq_alloc_t   [FETCH_WIDTH-1:0]   alloc_ports;
    commit_branch_port_t [FETCH_WIDTH-1:0] commit_branch;
    logic [FETCH_WIDTH-1:0]                commit_mispredict;

branch_pred_t [FETCH_WIDTH-1:0] bpu_pred_out; // not checked in tb

    bpu dut (
        .clk               (clk),
        .rst               (rst),
        .flush             (flush),
        .pc                (fetch_pc),
        .pc_next           (fetch_pc_next),
        .pc_vals           (fetch_pc_vals),
        .pred              (bpu_pred_out),
        .alloc_ports       (alloc_ports),
        .commit_branch     (commit_branch),
        .commit_mispredict (commit_mispredict)
    );

    // ------------------------------------------------------------------------
    // Shared scratch variables (all at module scope for Verilator compatibility)
    // ------------------------------------------------------------------------
    localparam int RAS_PTR_WIDTH = $clog2(RAS_ENTRIES);

    logic [GHR_WIDTH-1:0]     saved_ghr;
    logic [RAS_PTR_WIDTH:0]   saved_ras_ptr;
    logic [CPU_ADDR_BITS-1:0] commit_pc0, commit_pc1;
    logic [GHR_WIDTH-1:0]     ghr_before_alloc;
    int                       drain_count;
    bit                       mispredict_slot0, mispredict_slot1;
    bit                       inject_mispredict;
    logic [1:0]               random_btype_slot0, random_btype_slot1;
    logic [CPU_ADDR_BITS-1:0] random_pc0, random_pc1;
    logic [CPU_ADDR_BITS-1:0] random_target0, random_target1;

    branch_pred_t       branch_metadata;
    ftq_alloc_t      alloc_slot0, alloc_slot1;
    commit_branch_port_t  commit_slot0, commit_slot1;

    // ------------------------------------------------------------------------
    // Struct builder functions
    // ------------------------------------------------------------------------

    // Build branch_pred_t: the prediction context stored in the FTQ entry.
    function automatic branch_pred_t make_branch_pred(
        input logic [$clog2(TAGE_TABLES):0] provider_table,
        input logic prediction_taken,
        input logic altpred_taken,
        input logic [1:0] branch_type,
        input logic [CPU_ADDR_BITS-1:0] predicted_target
    );
        branch_pred_t metadata;
        metadata.btb.hit       = 1'b0;
        metadata.btb.targ      = predicted_target;
        metadata.btb.btype     = branch_type;
        metadata.tage.provider = provider_table;
        metadata.tage.pred_taken = prediction_taken;
        metadata.tage.pred_alt   = altpred_taken;
        return metadata;
    endfunction

    // Build ftq_alloc_t: one decode slot presenting a branch to the BPU.
    function automatic ftq_alloc_t make_alloc_port(
        input logic                     valid,
        input logic [CPU_ADDR_BITS-1:0]  branch_pc,
        input branch_pred_t              metadata
    );
        ftq_alloc_t alloc;
        alloc.val  = valid;
        alloc.pc   = branch_pc;
        alloc.pred = metadata;
        return alloc;
    endfunction

    // Build commit_branch_port_t: one ROB slot committing a branch outcome.
    function automatic commit_branch_port_t make_commit_port(
        input logic                    valid,
        input logic [CPU_ADDR_BITS-1:0] actual_target,
        input logic                    actual_taken
    );
        commit_branch_port_t commit_port;
        commit_port.val   = valid;
        commit_port.targ  = actual_target;
        commit_port.taken = actual_taken;
        return commit_port;
    endfunction

    // ------------------------------------------------------------------------
    // Sequencing tasks
    // ------------------------------------------------------------------------

    // Full synchronous reset: assert for two negedge cycles, then release.
    task automatic do_reset();
        @(negedge clk);
        rst           = 1'b1;
        fetch_pc      = '0;
        alloc_ports   = '{default:'0};
        commit_branch = '{default:'0};
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    // Drive fetch_pc and wait 1ns for combinational outputs to settle.
    task automatic drive_fetch_pc(input logic [CPU_ADDR_BITS-1:0] new_pc);
        @(negedge clk);
        fetch_pc = new_pc;
        #1;
    endtask

    // Assert alloc signals for one cycle, then clear.
    // The posedge between assertion and clear is when FTQ/GHR/RAS update.
    task automatic do_alloc(
        input ftq_alloc_t slot0,
        input ftq_alloc_t slot1
    );
        @(negedge clk);
        alloc_ports[0] = slot0;
        alloc_ports[1] = slot1;
        @(negedge clk);
        alloc_ports = '{default:'0};
        #1;
    endtask

    // Assert commit signals for one cycle and clear.
    // The #1 gap after assertion lets callers sample combinational outputs
    // (flush, pc_next, commit_mispredict) before the clear posedge.
    task automatic do_commit(
        input commit_branch_port_t slot0,
        input commit_branch_port_t slot1
    );
        @(negedge clk);
        commit_branch[0] = slot0;
        commit_branch[1] = slot1;
        #1;
        @(negedge clk);
        commit_branch = '{default:'0};
        #1;
    endtask

    // ------------------------------------------------------------------------
    // Check helpers
    // ------------------------------------------------------------------------
    task automatic check_addr(
        input string                    description,
        input logic [CPU_ADDR_BITS-1:0] actual,
        input logic [CPU_ADDR_BITS-1:0] expected
    );
        if (actual === expected) begin
            $display("  [PASS] %-44s 0x%08h", description, actual);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-44s got 0x%08h  exp 0x%08h", description, actual, expected);
            tests_failed++;
        end
    endtask

    task automatic check_bits(
        input string                  description,
        input logic [FETCH_WIDTH-1:0] actual,
        input logic [FETCH_WIDTH-1:0] expected
    );
        if (actual === expected) begin
            $display("  [PASS] %-44s %b", description, actual);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-44s got %b  exp %b", description, actual, expected);
            tests_failed++;
        end
    endtask

    task automatic check_true(input string description, input logic condition);
        if (condition) begin
            $display("  [PASS] %s", description);
            tests_passed++;
        end else begin
            $display("  [FAIL] %s", description);
            tests_failed++;
        end
    endtask

    // ------------------------------------------------------------------------
    // Lightweight FTQ reference model (tracks PC order only)
    // Used by random tests to know which PCs are at the head of the FTQ
    // so commits can be constructed without peeking at DUT internals.
    // ------------------------------------------------------------------------
    logic [CPU_ADDR_BITS-1:0] model_queue [0:1023];
    int model_head, model_tail, model_count;

    task automatic model_reset();
        model_head = 0; model_tail = 0; model_count = 0;
    endtask

    task automatic model_push(input logic [CPU_ADDR_BITS-1:0] branch_pc);
        model_queue[model_tail] = branch_pc;
        model_tail++;
        model_count++;
    endtask

    function automatic logic [CPU_ADDR_BITS-1:0] model_peek_head();
        return (model_count > 0) ? model_queue[model_head] : '0;
    endfunction

    task automatic model_pop();
        if (model_count > 0) begin model_head++; model_count--; end
    endtask

    task automatic model_clear();
        model_head = 0; model_tail = 0; model_count = 0;
    endtask

    // ========================================================================
    // Test sequence
    // ========================================================================
    initial begin
        $dumpfile("bpu_tb.vcd");
        $dumpvars(0, bpu_tb);

        $display("========================================");
        $display("  BPU Testbench -- Comprehensive");
        $display("========================================");
        $display("  FETCH_WIDTH  = %0d", FETCH_WIDTH);
        $display("  FTQ_ENTRIES  = %0d", FTQ_ENTRIES);
        $display("  RAS_ENTRIES  = %0d", RAS_ENTRIES);
        $display("  GHR_WIDTH    = %0d", GHR_WIDTH);
        $display("========================================\n");

        // --------------------------------------------------------------------
        // T1: Reset state
        // After reset with no BTB hits, BPU must default to sequential fetch:
        // pc_next = pc+8, pc_vals = 2'b11 (both slots valid), no flush.
        // --------------------------------------------------------------------
        $display("[T1] Reset / default sequential fetch");
        do_reset(); model_reset();
        drive_fetch_pc(32'h1000);
        check_addr("pc_next = pc+8",          fetch_pc_next, 32'h1008);
        check_bits("pc_vals  = 2'b11",         fetch_pc_vals,  2'b11);
        check_bits("commit_mispredict = 0",   commit_mispredict, '0);
        check_true("flush = 0",               flush == 1'b0);
        $display("");

        // --------------------------------------------------------------------
        // T2: FTQ backpressure and state stability
        // Fill the FTQ to capacity via slot0-only allocs.  Once full,
        // enq_rdy must drop and GHR/RAS must not mutate while decode stalls.
        // --------------------------------------------------------------------
        $display("[T2] FTQ backpressure / GHR+RAS stable during stall");
        do_reset(); model_reset();
        for (int i = 0; i < FTQ_ENTRIES + 4; i++) begin
            branch_metadata = make_branch_pred(
                TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'h2004 + i*4);
            if (dut.ftq_enq_rdy[0]) begin
                do_alloc(make_alloc_port(1'b1, 32'h2000+i*4, branch_metadata),
                         make_alloc_port(1'b0, '0, '{default:'0}));
                model_push(32'h2000+i*4);
            end else begin
                do_alloc(make_alloc_port(1'b0, '0, '{default:'0}),
                         make_alloc_port(1'b0, '0, '{default:'0}));
            end
        end
        check_true("FTQ full (cnt == FTQ_ENTRIES)",   dut.u_ftq.cnt == FTQ_ENTRIES);
        check_bits("enq_rdy both low when full",      dut.ftq_enq_rdy, 2'b00);
        saved_ghr     = dut.ghr;
        saved_ras_ptr = dut.ras_ptr;
        repeat(3) do_alloc(make_alloc_port(1'b0,'0,'{default:'0}),
                           make_alloc_port(1'b0,'0,'{default:'0}));
        check_true("GHR unchanged while stalled",     dut.ghr    === saved_ghr);
        check_true("RAS ptr unchanged while stalled", dut.ras_ptr === saved_ras_ptr);
        $display("");

        // --------------------------------------------------------------------
        // T3: FTQ FIFO drain order
        // Commit the entries filled in T2 as correct NT branches.
        // No flush should occur; FTQ must reach zero in FIFO order.
        // Drains first half single-commit, then remainder dual-commit.
        // --------------------------------------------------------------------
        $display("[T3] FTQ FIFO drain -- correct NT commits, no spurious flush");
        drain_count = FTQ_ENTRIES / 2;
        for (int k = 0; k < drain_count; k++) begin
            commit_pc0 = model_peek_head(); model_pop();
            do_commit(make_commit_port(1'b1, commit_pc0 + 32'd4, 1'b0),
                      make_commit_port(1'b0, '0, 1'b0));
        end
        while (model_count >= 2) begin
            commit_pc0 = model_peek_head(); model_pop();
            commit_pc1 = model_peek_head(); model_pop();
            do_commit(make_commit_port(1'b1, commit_pc0 + 32'd4, 1'b0),
                      make_commit_port(1'b1, commit_pc1 + 32'd4, 1'b0));
        end
        if (model_count == 1) begin
            commit_pc0 = model_peek_head(); model_pop();
            do_commit(make_commit_port(1'b1, commit_pc0 + 32'd4, 1'b0),
                      make_commit_port(1'b0, '0, 1'b0));
        end
        check_true("no flush during drain",  flush == 1'b0);
        check_true("FTQ empty after drain",  dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T4: Slot0 direction mispredict Taken -> Not-Taken
        // Predicted taken but actual NT: flush to PC+4 (fallthrough).
        // Both commit_mispredict bits must be set (slot0 forces slot1 high).
        // --------------------------------------------------------------------
        $display("[T4] Slot0 mispredict: predicted Taken, actual NT -- flush to fallthrough");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'h3000);
        do_alloc(make_alloc_port(1'b1, 32'h2100, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'h3000, 1'b0); // actual NT
        commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
        #1;
        check_true("flush asserted",                      flush == 1'b1);
        check_true("commit_mispredict[0] set",            commit_mispredict[0] == 1'b1);
        check_true("commit_mispredict[1] ORed from [0]",  commit_mispredict[1] == 1'b1);
        check_addr("pc_next = fallthrough (pc+4)",        fetch_pc_next, 32'h2104);
        check_bits("pc_vals = 2'b00 on flush",             fetch_pc_vals, 2'b00);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("FTQ cleared after flush",             dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T5: Slot0 direction mispredict Not-Taken -> Taken
        // Predicted NT but actual taken: flush to the branch target.
        // --------------------------------------------------------------------
        $display("[T5] Slot0 mispredict: predicted NT, actual Taken -- flush to target");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'h4000);
        do_alloc(make_alloc_port(1'b1, 32'h2200, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'h4000, 1'b1); // actual taken
        commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
        #1;
        check_true("flush asserted",              flush == 1'b1);
        check_addr("pc_next = branch target",     fetch_pc_next, 32'h4000);
        check_bits("pc_vals = 2'b00 on flush",     fetch_pc_vals, 2'b00);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("FTQ cleared after flush",     dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T6: Slot0 target mispredict (direction correct, target wrong)
        // Predicted taken to 0x5000 but actual target was 0x5004.
        // --------------------------------------------------------------------
        $display("[T6] Slot0 mispredict: correct direction, wrong target -- flush to corrected target");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'h5000);
        do_alloc(make_alloc_port(1'b1, 32'h2300, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'h5004, 1'b1); // different target
        commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
        #1;
        check_true("flush asserted",                  flush == 1'b1);
        check_addr("pc_next = corrected target",      fetch_pc_next, 32'h5004);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("FTQ cleared after flush",         dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T7: Same-cycle flush + RAS recovery peek
        // Simulates a branch misprediction that recovers the RAS pointer
        // while the frontend simultaneously presents a new fetch PC.
        // Verifies that ras_peek_addr immediately reflects recover_ptr
        // (combinational) rather than the stale committed ptr_r.
        //
        // Sequence:
        //   1. CALL at 0x1000 pushes ret addr 0x1004 to RAS (ptr=1)
        //   2. COND at 0x2000 allocated with ras_cp=1
        //   3. RET at 0x3000 pops RAS (ptr=0)
        //   4. Commit mispredicts COND -> recover_ptr=1 -> peek shows 0x1004
        // --------------------------------------------------------------------
        $display("[T7] Flush + same-cycle RAS recover_ptr peek");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'h1800);
        do_alloc(make_alloc_port(1'b1, 32'h1000, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        do_commit(make_commit_port(1'b1, 32'h1800, 1'b1),
                  make_commit_port(1'b0, '0, 1'b0));
        check_true("RAS ptr=1 after CALL commit",   dut.ras_ptr == 1);
        drive_fetch_pc(32'h2000);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'h2004);
        do_alloc(make_alloc_port(1'b1, 32'h2000, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        drive_fetch_pc(32'h3000);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hDEAD);
        do_alloc(make_alloc_port(1'b1, 32'h3000, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("RAS ptr=0 after RET alloc (ptr advanced past checkpoint)", dut.ras_ptr == 0);
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'h8000, 1'b1); // mispredict COND
        commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
        fetch_pc = 32'h4000; // frontend already moved to corrected stream
        #1;
        check_true("flush asserted",                          flush == 1'b1);
        check_addr("RAS peek = ret addr 0x1004 (recovered)", dut.ras_peek_addr, 32'h1004);
        check_bits("pc_vals = 2'b00 during flush",            fetch_pc_vals, 2'b00);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("RAS ptr restored to 1 after flush edge", dut.ras_ptr == 1);
        $display("");

        // --------------------------------------------------------------------
        // T8: Constrained-random single-wide smoke test (200 cycles)
        // Slot0-only alloc with all branch types, random 10% mispredict inject.
        // Invariant: FTQ count must never exceed FTQ_ENTRIES.
        // --------------------------------------------------------------------
        $display("[T8] Constrained-random single-wide smoke (200 cycles)");
        do_reset(); model_reset();
        begin
            logic [1:0] random_btype;
            for (int t = 0; t < 200; t++) begin
                drive_fetch_pc(32'h5000 + t*4);
                if ($urandom_range(0,3) != 0 && dut.ftq_enq_rdy[0]) begin
                    case ($urandom_range(0,3))
                        0: random_btype = BRANCH_COND;
                        1: random_btype = BRANCH_JUMP;
                        2: random_btype = BRANCH_CALL;
                        default: random_btype = BRANCH_RET;
                    endcase
                    random_pc0     = 32'h6000 + t*4;
                    random_target0 = 32'h7000 + t*8;
                    branch_metadata = make_branch_pred(TAGE_TABLES,
                        ($urandom_range(0,1) != 0), ($urandom_range(0,1) != 0),
                        random_btype, random_target0);
                    do_alloc(make_alloc_port(1'b1, random_pc0, branch_metadata),
                             make_alloc_port(1'b0, '0, '{default:'0}));
                    model_push(random_pc0);
                end else begin
                    do_alloc(make_alloc_port(1'b0,'0,'{default:'0}),
                             make_alloc_port(1'b0,'0,'{default:'0}));
                end
                if ($urandom_range(0,3) == 0 && model_count > 0) begin
                    inject_mispredict = ($urandom_range(0,9) == 0);
                    commit_pc0 = model_peek_head();
                    @(negedge clk);
                    commit_branch[0] = make_commit_port(1'b1,
                        inject_mispredict ? 32'h9000+t*4 : commit_pc0+32'd4,
                        inject_mispredict ? 1'b1 : 1'b0);
                    commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
                    #1;
                    if (flush) model_clear(); else model_pop();
                    @(negedge clk); commit_branch = '{default:'0}; #1;
                end
                if (dut.u_ftq.cnt > FTQ_ENTRIES) begin
                    $display("  [FAIL] FTQ overflow: cnt=%0d at t=%0d",
                             dut.u_ftq.cnt, t);
                    tests_failed++;
                end
            end
        end
        check_true("T8 smoke: no FTQ overflow in 200 cycles", 1'b1);
        $display("");

        // --------------------------------------------------------------------
        // T9: Slot1-only alloc -- remapped to FTQ port 0
        // Decode presents a branch only in slot1 (slot0 is a non-branch ALU op).
        // BPU must remap this to FTQ port 0 because the FTQ hard-asserts
        // that enq_en[1] without enq_en[0] is illegal.
        // Also verifies CALL and RET can reach the RAS through the slot1 path.
        // --------------------------------------------------------------------
        $display("[T9] Slot1-only alloc: COND/CALL/RET remapped to FTQ port 0");
        do_reset(); model_reset();
        // COND in slot1 only
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'hA004);
        do_alloc(make_alloc_port(1'b0, '0, '{default:'0}),
                 make_alloc_port(1'b1, 32'hA000, branch_metadata));
        check_true("FTQ cnt=1 after slot1-only COND alloc",  dut.u_ftq.cnt == 1);
        do_commit(make_commit_port(1'b1, 32'hA004, 1'b0),
                  make_commit_port(1'b0, '0, 1'b0));
        check_true("no flush on correct slot1 NT commit",    flush == 1'b0);
        check_true("FTQ empty after commit",                 dut.u_ftq.cnt == 0);
        // CALL in slot1 -> RAS push must fire through slot1 remap path
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'hBB00);
        do_alloc(make_alloc_port(1'b0, '0, '{default:'0}),
                 make_alloc_port(1'b1, 32'hBB00, branch_metadata));
        check_true("RAS ptr=1 after slot1-only CALL",        dut.ras_ptr == 1);
        // RET in slot1 -> RAS pop must fire through slot1 remap path
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hBB04);
        do_alloc(make_alloc_port(1'b0, '0, '{default:'0}),
                 make_alloc_port(1'b1, 32'hBB04, branch_metadata));
        check_true("RAS ptr=0 after slot1-only RET",         dut.ras_ptr == 0);
        $display("");

        // --------------------------------------------------------------------
        // T10: Dual alloc -- two COND branches, GHR double-shift
        // The GHR must shift twice in one cycle: once for slot0's prediction,
        // then again for slot1's prediction.  TAGE applies both in sequence.
        // --------------------------------------------------------------------
        $display("[T10] Dual alloc: COND(s0 pred-T) + COND(s1 pred-NT) -- GHR shifts twice");
        do_reset(); model_reset();
        ghr_before_alloc = dut.ghr;
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'hB100);
        alloc_slot0 = make_alloc_port(1'b1, 32'hB000, branch_metadata); // pred taken
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hB008);
        alloc_slot1 = make_alloc_port(1'b1, 32'hB004, branch_metadata); // pred NT
        do_alloc(alloc_slot0, alloc_slot1);
        check_true("FTQ cnt=2",          dut.u_ftq.cnt == 2);
        // Expected GHR: slot0 shifts in 1 (taken), slot1 shifts in 0 (NT)
        check_true("GHR = {old[29:0],1,0}", dut.ghr === {ghr_before_alloc[GHR_WIDTH-3:0], 1'b1, 1'b0});
        do_commit(make_commit_port(1'b1, 32'hB100, 1'b1),
                  make_commit_port(1'b1, 32'hB008, 1'b0));
        check_true("no flush on correct dual COND commit", flush == 1'b0);
        check_true("FTQ empty after dual commit",          dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T11: Dual alloc -- COND-NT(slot0) + JUMP(slot1)
        // An unconditional branch (JUMP/CALL/RET) can only appear in slot1
        // when slot0 is a COND predicted NT -- because any unconditional in
        // slot0 sets pc_vals=2'b01 at fetch, killing slot1 before decode.
        // GHR must shift once only (slot0 COND shifts; JUMP does not).
        // --------------------------------------------------------------------
        $display("[T11] Dual alloc: COND-NT(s0) + JUMP(s1) -- only legal unconditional in slot1");
        do_reset(); model_reset();
        ghr_before_alloc = dut.ghr;
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hC004);
        alloc_slot0 = make_alloc_port(1'b1, 32'hC000, branch_metadata); // pred NT
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_JUMP, 32'hC200);
        alloc_slot1 = make_alloc_port(1'b1, 32'hC004, branch_metadata);
        do_alloc(alloc_slot0, alloc_slot1);
        check_true("FTQ cnt=2",                        dut.u_ftq.cnt == 2);
        check_true("GHR shifted once (COND NT only)",  dut.ghr === {ghr_before_alloc[GHR_WIDTH-2:0], 1'b0});
        do_commit(make_commit_port(1'b1, 32'hC004, 1'b0),
                  make_commit_port(1'b0, '0, 1'b0));
        check_true("no flush -- COND commit correct",  flush == 1'b0);
        do_commit(make_commit_port(1'b1, 32'hC200, 1'b1),
                  make_commit_port(1'b0, '0, 1'b0));
        check_true("no flush -- JUMP commit correct",  flush == 1'b0);
        check_true("FTQ empty",                        dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T12: Dual alloc -- COND-NT(slot0) + CALL(slot1)
        // slot0 is COND so it does not touch the RAS.  slot1 is a CALL,
        // so the RAS push fires through the slot1 path without contention.
        // Verifies that ras_cp stored in FTQ[1] captures the post-push pointer.
        // --------------------------------------------------------------------
        $display("[T12] Dual alloc: COND-NT(s0) + CALL(s1) -- slot1 RAS push, no contention");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hD004);
        alloc_slot0 = make_alloc_port(1'b1, 32'hD000, branch_metadata);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'hD100);
        alloc_slot1 = make_alloc_port(1'b1, 32'hD004, branch_metadata);
        do_alloc(alloc_slot0, alloc_slot1);
        check_true("RAS ptr=1 after slot1 CALL push",    dut.ras_ptr == 1);
        check_true("FTQ cnt=2",                          dut.u_ftq.cnt == 2);
        check_true("FTQ[1].ras_cp = 1 (post-push ptr)", dut.u_ftq.queue[1].ras_cp == 1);
        $display("");

        // --------------------------------------------------------------------
        // T13: Dual alloc -- COND-NT(slot0) + RET(slot1)
        // Same reasoning as T12 but for RET: slot0 is COND so the RAS port
        // is free, and slot1's RET pop fires without contention.
        // A prime CALL is allocated first to give the RAS something to pop.
        // FTQ count after: 1 (prime CALL) + 2 (dual alloc) = 3.
        // --------------------------------------------------------------------
        $display("[T13] Dual alloc: COND-NT(s0) + RET(s1) -- slot1 RAS pop, no contention");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'hEE00);
        do_alloc(make_alloc_port(1'b1, 32'hEE00, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("RAS ptr=1 after prime CALL",           dut.ras_ptr == 1);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hEF04);
        alloc_slot0 = make_alloc_port(1'b1, 32'hEF00, branch_metadata);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hEE04);
        alloc_slot1 = make_alloc_port(1'b1, 32'hEF04, branch_metadata);
        do_alloc(alloc_slot0, alloc_slot1);
        check_true("RAS ptr=0 after slot1 RET pop",        dut.ras_ptr == 0);
        check_true("FTQ cnt=3 (prime + dual alloc)",        dut.u_ftq.cnt == 3);
        $display("");

        // --------------------------------------------------------------------
        // T14: Dual commit -- slot1 mispredicts, slot0 is correct
        // Both slots commit in the same cycle.  slot0 actual=NT (matches pred).
        // slot1 actual=taken (pred was NT) -> mispredict.
        // commit_mispredict[0] must stay clear; [1] must be set.
        // pc_next must be slot1's corrected target.
        // --------------------------------------------------------------------
        $display("[T14] Dual commit: slot0 correct, slot1 mispredicts -- flush to slot1 target");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hE004);
        alloc_slot0 = make_alloc_port(1'b1, 32'hE000, branch_metadata); // pred NT
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'hE008);
        alloc_slot1 = make_alloc_port(1'b1, 32'hE004, branch_metadata); // pred NT
        do_alloc(alloc_slot0, alloc_slot1);
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'hE004, 1'b0); // actual NT -- correct
        commit_branch[1] = make_commit_port(1'b1, 32'hF000, 1'b1); // actual taken -- mispredict
        #1;
        check_true("flush asserted",                          flush == 1'b1);
        check_true("commit_mispredict[0] = 0 (slot0 ok)",    commit_mispredict[0] == 1'b0);
        check_true("commit_mispredict[1] = 1 (slot1 mp)",    commit_mispredict[1] == 1'b1);
        check_addr("pc_next = slot1 corrected target",        fetch_pc_next, 32'hF000);
        check_bits("pc_vals = 2'b00 on flush",                 fetch_pc_vals, 2'b00);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("FTQ cleared after slot1-mispredict flush", dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T15: Dual commit -- both slots mispredict, slot0 wins (program order)
        // slot0 is older, so its corrected PC takes priority when both
        // commit_mispredict bits assert simultaneously.
        // commit_mispredict[1] is set via OR with [0] per design spec.
        // --------------------------------------------------------------------
        $display("[T15] Dual commit: both mispredict -- slot0 (older) wins");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'h1100);
        alloc_slot0 = make_alloc_port(1'b1, 32'h1000, branch_metadata); // pred taken
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_COND, 32'h2200);
        alloc_slot1 = make_alloc_port(1'b1, 32'h1004, branch_metadata); // pred taken
        do_alloc(alloc_slot0, alloc_slot1);
        @(negedge clk);
        commit_branch[0] = make_commit_port(1'b1, 32'h1004, 1'b0); // actual NT -- mispredict
        commit_branch[1] = make_commit_port(1'b1, 32'h3000, 1'b0); // actual NT -- mispredict
        #1;
        check_true("flush asserted",                      flush == 1'b1);
        check_true("commit_mispredict[0] set",            commit_mispredict[0] == 1'b1);
        check_true("commit_mispredict[1] ORed from [0]",  commit_mispredict[1] == 1'b1);
        check_addr("pc_next = slot0 fallthrough (pc+4)",  fetch_pc_next, 32'h1004);
        @(negedge clk); commit_branch = '{default:'0}; #1;
        @(posedge clk); #1;
        check_true("FTQ cleared after dual-mispredict flush", dut.u_ftq.cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T16: Fetch-side slot1 BTB JUMP hit
        // Train the BTB by allocating COND-NT(0x4000) + JUMP(0x4004) and
        // committing them correctly.  On re-fetch at pc=0x4000:
        //   - slot0 BTB miss  (COND committed NT -> not written to BTB)
        //   - slot1 BTB hit   (JUMP committed taken -> written to BTB at pc+4)
        //   -> pc_next must redirect to JUMP target 0x5000
        //   -> pc_vals must remain 2'b11 (both instructions in bundle are valid)
        // --------------------------------------------------------------------
        $display("[T16] Fetch: BTB JUMP hit on slot1 (pc+4) -- pc_next = slot1 target");
        do_reset(); model_reset();
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, 32'h4004);
        alloc_slot0 = make_alloc_port(1'b1, 32'h4000, branch_metadata);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_JUMP, 32'h5000);
        alloc_slot1 = make_alloc_port(1'b1, 32'h4004, branch_metadata);
        do_alloc(alloc_slot0, alloc_slot1);
        do_commit(make_commit_port(1'b1, 32'h4004, 1'b0), // COND: actual NT (not written to BTB)
                  make_commit_port(1'b1, 32'h5000, 1'b1)); // JUMP: actual taken (written to BTB)
        check_true("no flush during BTB training",        flush == 1'b0);
        @(posedge clk); #1; // let BTB write register before re-fetch
        drive_fetch_pc(32'h4000); #1;
        check_addr("pc_next = slot1 JUMP target",         fetch_pc_next, 32'h5000);
        check_bits("pc_vals = 2'b11 (both slots valid)",   fetch_pc_vals, 2'b11);
        $display("");

        // --------------------------------------------------------------------
        // T17: Temporary RET-bypass contract
        // Once a speculative RET allocates, younger CALL/RET traffic bypasses
        // RAS rather than mutating it. The first RET still pops; subsequent
        // younger RETs in the window must leave ptr/peek unchanged until flush.
        // --------------------------------------------------------------------
        $display("[T17] Nested CALL/RET: first RET pops, younger RETs bypass until flush");
        do_reset(); model_reset();
        // Call A at 0x4000 -> push ret addr 0x4004
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'h4100);
        // Current contract: CALL/RET are BTB/RAS-driven, not TAGE-driven.
        // Mark them as BTB hits so commit-side behavior reflects the intended
        // temporary bypass design instead of inducing unrelated mispredicts.
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4000, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr=1, peek=0x4004 (A ret addr)",
                   dut.ras_ptr == 1 && dut.ras_peek_addr == 32'h4004);
        // Call B at 0x4100 -> push ret addr 0x4104
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'h4200);
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4100, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr=2, peek=0x4104 (B ret addr)",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4104);
        // Call C at 0x4200 -> push ret addr 0x4204
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_CALL, 32'h4300);
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4200, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr=3, peek=0x4204 (C ret addr)",
                   dut.ras_ptr == 3 && dut.ras_peek_addr == 32'h4204);
        // First RET still consumes RAS and enables bypass mode.
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hDEAD);
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4300, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr=2, peek=0x4104 (B ret addr after first RET)",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4104);
        check_true("bypass mode active after first speculative RET",
                   dut.ras_bypass_mode == 1'b1 && dut.ret_pending_cnt == 1);
        // Younger RETs must bypass RAS and leave ptr/peek unchanged.
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hDEAD);
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4400, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr/peek unchanged after younger RET bypass",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4104);
        check_true("ret_pending_cnt increments for bypassed younger RET",
                   dut.ret_pending_cnt == 2);
        branch_metadata = make_branch_pred(TAGE_TABLES, 1'b1, 1'b0, BRANCH_RET, 32'hDEAD);
        branch_metadata.btb.hit = 1'b1;
        do_alloc(make_alloc_port(1'b1, 32'h4500, branch_metadata),
                 make_alloc_port(1'b0, '0, '{default:'0}));
        check_true("ptr/peek still unchanged after third RET bypass",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4104);
        check_true("ret_pending_cnt tracks all outstanding speculative RETs",
                   dut.ret_pending_cnt == 3);
        // Do not over-specify commit-side RET retirement behavior here.
        // The temporary bypass feature guarantees alloc-side behavior and that
        // flush clears the bypass bookkeeping. Force a mispredict on the
        // oldest still-outstanding entry and separate the checks on the
        // assertion cycle from the post-edge bookkeeping clear.
        check_true("bypass bookkeeping still active before flush",
                   dut.ras_bypass_mode == 1'b1 && dut.ret_pending_cnt == 3);
        check_true("pre-flush ptr/peek still show younger RET bypass state",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4104);

        @(negedge clk);
        commit_branch[0] = make_commit_port(
            1'b1,
            dut.u_ftq.deq_data[0].pred.btb.targ + 32'h100,
            1'b1
        );
        commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
        #1;
        check_true("flush asserted on forced oldest-entry mispredict",
                   flush == 1'b1);
        check_true("flush cycle shows recover_ptr-backed peek for older entry",
                   dut.ras_ptr == 2 && dut.ras_peek_addr == 32'h4004);

        @(negedge clk);
        commit_branch = '{default:'0};
        #1;
        check_true("flush clears bypass bookkeeping",
                   dut.ras_bypass_mode == 1'b0 && dut.ret_pending_cnt == 0);
        $display("");

        // --------------------------------------------------------------------
        // T18: Constrained-random 2-wide smoke test (300 cycles)
        // Exercises all alloc patterns (slot0-only, slot1-only, dual) and both
        // single and dual commits with random 10% mispredict injection.
        //
        // Protocol enforced: when both slots are allocated, slot0 must be COND
        // (an unconditional in slot0 terminates the fetch bundle and kills slot1).
        //
        // Invariants checked every cycle:
        //   1. FTQ count never exceeds FTQ_ENTRIES
        //   2. pc_vals = 2'b00 whenever flush is asserted
        //   3. commit_mispredict[0] set -> commit_mispredict[1] also set
        // --------------------------------------------------------------------
        $display("[T18] Constrained-random 2-wide smoke (300 cycles)");
        do_reset(); model_reset();
        begin
            logic [1:0] random_btype;
            for (int t = 0; t < 300; t++) begin
                drive_fetch_pc(32'hA000 + t*8);

                case ($urandom_range(0,3))
                    0: random_btype_slot0 = BRANCH_COND;
                    1: random_btype_slot0 = BRANCH_JUMP;
                    2: random_btype_slot0 = BRANCH_CALL;
                    default: random_btype_slot0 = BRANCH_RET;
                endcase
                case ($urandom_range(0,3))
                    0: random_btype_slot1 = BRANCH_COND;
                    1: random_btype_slot1 = BRANCH_JUMP;
                    2: random_btype_slot1 = BRANCH_CALL;
                    default: random_btype_slot1 = BRANCH_RET;
                endcase
                random_pc0     = 32'hA000 + t*8;
                random_pc1     = 32'hA004 + t*8;
                random_target0 = 32'hB000 + t*4;
                random_target1 = 32'hB008 + t*4;

                if ($urandom_range(0,3) == 3
                        && dut.ftq_enq_rdy[0] && dut.ftq_enq_rdy[1]) begin
                    // Dual alloc: slot0 must be COND (fetch-bundle protocol)
                    branch_metadata = make_branch_pred(
                        TAGE_TABLES, 1'b0, 1'b0, BRANCH_COND, random_target0);
                    alloc_slot0 = make_alloc_port(1'b1, random_pc0, branch_metadata);
                    branch_metadata = make_branch_pred(
                        TAGE_TABLES, ($urandom_range(0,1) != 0), ($urandom_range(0,1) != 0),
                        random_btype_slot1, random_target1);
                    alloc_slot1 = make_alloc_port(1'b1, random_pc1, branch_metadata);
                    do_alloc(alloc_slot0, alloc_slot1);
                    model_push(random_pc0); model_push(random_pc1);

                end else if (($urandom_range(0,1) != 0) && dut.ftq_enq_rdy[0]) begin
                    // Slot0-only alloc: any branch type
                    branch_metadata = make_branch_pred(
                        TAGE_TABLES, ($urandom_range(0,1) != 0), ($urandom_range(0,1) != 0),
                        random_btype_slot0, random_target0);
                    do_alloc(make_alloc_port(1'b1, random_pc0, branch_metadata),
                             make_alloc_port(1'b0, '0, '{default:'0}));
                    model_push(random_pc0);

                end else if (dut.ftq_enq_rdy[0]) begin
                    // Slot1-only alloc: remapped to FTQ port 0 by BPU
                    branch_metadata = make_branch_pred(
                        TAGE_TABLES, ($urandom_range(0,1) != 0), ($urandom_range(0,1) != 0),
                        random_btype_slot1, random_target1);
                    do_alloc(make_alloc_port(1'b0, '0, '{default:'0}),
                             make_alloc_port(1'b1, random_pc1, branch_metadata));
                    model_push(random_pc1);

                end else begin
                    do_alloc(make_alloc_port(1'b0,'0,'{default:'0}),
                             make_alloc_port(1'b0,'0,'{default:'0}));
                end

                // Dual commit
                if (model_count >= 2 && $urandom_range(0,2) == 0) begin
                    mispredict_slot0 = ($urandom_range(0,9) == 0);
                    mispredict_slot1 = ($urandom_range(0,9) == 0);
                    commit_pc0 = model_peek_head(); model_pop();
                    commit_pc1 = model_peek_head();
                    @(negedge clk);
                    commit_branch[0] = make_commit_port(1'b1,
                        mispredict_slot0 ? 32'hC000+t*4 : commit_pc0+32'd4,
                        mispredict_slot0);
                    commit_branch[1] = make_commit_port(1'b1,
                        mispredict_slot1 ? 32'hC100+t*4 : commit_pc1+32'd4,
                        mispredict_slot1);
                    #1;
                    if (commit_mispredict[0] && !commit_mispredict[1]) begin
                        $display("  [FAIL] mispredict[0] set but [1] not ORed (t=%0d)", t);
                        tests_failed++;
                    end
                    if (flush && fetch_pc_vals !== 2'b00) begin
                        $display("  [FAIL] pc_vals != 2'b00 during flush, dual commit (t=%0d)", t);
                        tests_failed++;
                    end
                    if (flush) model_clear(); else model_pop();
                    @(negedge clk); commit_branch = '{default:'0}; #1;

                // Single commit
                end else if (model_count >= 1 && $urandom_range(0,2) == 0) begin
                    mispredict_slot0 = ($urandom_range(0,9) == 0);
                    commit_pc0 = model_peek_head();
                    @(negedge clk);
                    commit_branch[0] = make_commit_port(1'b1,
                        mispredict_slot0 ? 32'hC200+t*4 : commit_pc0+32'd4,
                        mispredict_slot0);
                    commit_branch[1] = make_commit_port(1'b0, '0, 1'b0);
                    #1;
                    if (flush && fetch_pc_vals !== 2'b00) begin
                        $display("  [FAIL] pc_vals != 2'b00 during flush, single commit (t=%0d)", t);
                        tests_failed++;
                    end
                    if (flush) model_clear(); else model_pop();
                    @(negedge clk); commit_branch = '{default:'0}; #1;
                end

                if (dut.u_ftq.cnt > FTQ_ENTRIES) begin
                    $display("  [FAIL] FTQ overflow: cnt=%0d at t=%0d",
                             dut.u_ftq.cnt, t);
                    tests_failed++;
                end
            end
        end
        check_true("T18 smoke: no invariant violations in 300 cycles", 1'b1);
        $display("");

        // --------------------------------------------------------------------
        // Summary
        // --------------------------------------------------------------------
        $display("========================================");
        $display("  Tests Passed: %0d", tests_passed);
        $display("  Tests Failed: %0d", tests_failed);
        $display("========================================");
        if (tests_failed != 0) $fatal(1, "FAILURES DETECTED");
        $finish;
    end

    initial begin
        #4000000;
        $fatal(1, "Simulation timeout");
    end

endmodule
