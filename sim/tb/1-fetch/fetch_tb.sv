`timescale 1ns/1ps

import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module fetch_tb;

    localparam HEX_FILE = "sim/tests/hex/fetch_test.hex";

    // Stats
    int tests_passed       = 0;
    int tests_failed       = 0;
    int assertions_checked = 0;

    // Clock
    logic clk, rst;
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // BPU stub - sequential by default, redirect on flush_i
    logic [CPU_ADDR_BITS-1:0] pc;
    logic [CPU_ADDR_BITS-1:0] pc_next_i;
    logic [FETCH_WIDTH-1:0]   pc_vals_i;
    logic                     flush_i;
    logic [CPU_ADDR_BITS-1:0] bpu_redirect_pc;

    always_comb begin
        if (rst)          pc_next_i = PC_RESET;
        else if (flush_i) pc_next_i = bpu_redirect_pc;
        else              pc_next_i = pc + CPU_ADDR_BITS'(8);
    end

    // IMEM signals
    logic                                 imem_req_rdy;
    logic                                 imem_req_val;
    logic [CPU_ADDR_BITS-1:0]             imem_req_packet;
    logic                                 imem_rec_rdy;
    logic                                 imem_rec_val;
    logic [FETCH_WIDTH*CPU_INST_BITS-1:0] imem_rec_packet;

    logic decode_rdy_i;

    // DUT outputs
    logic [CPU_ADDR_BITS-1:0]                  inst_pcs_o [PIPE_WIDTH-1:0];
    logic [CPU_INST_BITS-1:0]                  insts_o    [PIPE_WIDTH-1:0];
    logic [FETCH_WIDTH-1:0]                   fetch_vals_o;

    // BPU stub inputs to fetch - default no prediction
    branch_pred_t [FETCH_WIDTH-1:0] bpu_pred_i;
    ftq_alloc_t   [FETCH_WIDTH-1:0] alloc_ports_o;  // FTQ alloc output, not checked in fetch tb

    // Test variables
    logic [CPU_INST_BITS-1:0] expected_sequence [30];
    logic [CPU_ADDR_BITS-1:0] pc_before_stall;
    logic [CPU_ADDR_BITS-1:0] redirect_target;
    logic [CPU_ADDR_BITS-1:0] redirect_addr;
    logic [CPU_INST_BITS-1:0] inst0_before_stall;
    logic [CPU_INST_BITS-1:0] inst_before_stall;
    logic [CPU_INST_BITS-1:0] expected_next;
    logic [CPU_ADDR_BITS-1:0] targets [3];
    logic [FETCH_WIDTH-1:0]   saved_fetch_vals;

    int instruction_index;
    int cycles_with_valid_output;
    int drain_cycles;
    int redirect_idx;
    int idx;

    // DUT
    fetch dut (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush_i),
        .pc              (pc),
        .pc_next         (pc_next_i),
        .pc_vals         (pc_vals_i),
        .bpu_pred         (bpu_pred_i),
        .alloc_ports      (alloc_ports_o),
        .imem_req_rdy    (imem_req_rdy),
        .imem_req_val    (imem_req_val),
        .imem_req_packet (imem_req_packet),
        .imem_rec_rdy    (imem_rec_rdy),
        .imem_rec_val    (imem_rec_val),
        .imem_rec_packet (imem_rec_packet),
        .decode_rdy      (decode_rdy_i),
        .inst_pcs        (inst_pcs_o),
        .insts           (insts_o),
        .fetch_vals      (fetch_vals_o)
    );

    // Memory model
    /* verilator lint_off PINCONNECTEMPTY */
    mem_simple #(
        .IMEM_HEX_FILE      (HEX_FILE),
        .IMEM_POSTLOAD_DUMP (1),
        .IMEM_SIZE_BYTES    (1024),
        .DMEM_SIZE_BYTES    (1024)
    ) mem (
        .clk             (clk),
        .rst             (rst),
        .imem_req_rdy    (imem_req_rdy),
        .imem_req_val    (imem_req_val),
        .imem_req_packet (imem_req_packet),
        .imem_rec_rdy    (imem_rec_rdy),
        .imem_rec_val    (imem_rec_val),
        .imem_rec_packet (imem_rec_packet),
        .dmem_req_rdy    (),
        .dmem_req_packet ('{default:'0}),
        .dmem_rec_rdy    (1'b0),
        .dmem_rec_packet ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Tasks
    task automatic check_assertion(
        input string test_name,
        input logic  condition,
        input string fail_msg
    );
        assertions_checked++;
        if (condition) begin
            $display("  [PASS] %s", test_name);
            tests_passed++;
        end else begin
            $display("  [FAIL] %s: %s", test_name, fail_msg);
            tests_failed++;
        end
    endtask

    task automatic wait_for_fetch(input int cycles);
        repeat(cycles) @(posedge clk);
    endtask

    task automatic display_fetch_output();
        $display("    PC[0]=0x%h Inst[0]=0x%h val=%b | PC[1]=0x%h Inst[1]=0x%h val=%b | fetch_val=%b",
                 inst_pcs_o[0], insts_o[0], fetch_vals_o[0],
                 inst_pcs_o[1], insts_o[1], fetch_vals_o[1],
                 fetch_vals_o != '0);
    endtask

    // Reset + flush one cycle to force start_pc as the first imem request.
    // Exits with buf_q[0]={start_pc, insts}, decode_rdy=0, rd_ptr=0.
    task automatic do_reset(input logic [CPU_ADDR_BITS-1:0] start_pc);
        rst             = 1;
        flush_i         = 0;
        pc_vals_i       = 2'b11;
        decode_rdy_i    = 0;
        bpu_pred_i      = '0;
        bpu_redirect_pc = start_pc;

        @(posedge clk);     // rst=1
        flush_i = 1;        // force pc_next=start_pc on rst release
        rst     = 0;
        @(posedge clk);     // request fires for start_pc
        flush_i = 0;
        @(posedge clk);     // imem_rec arrives, written to buf_q[0]
    endtask

    //-------------------------------------------------------------
    // Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("wave.vcd");
        $dumpvars(0, fetch_tb);

        $display("========================================");
        $display("  Fetch Stage Testbench");
        $display("========================================\n");

        expected_sequence = '{
            32'h11111111, 32'h22222222, 32'h33333333, 32'h44444444,
            32'h55555555, 32'h66666666, 32'h77777777, 32'h88888888,
            32'h99999999, 32'haaaaaaaa, 32'hbbbbbbbb, 32'hcccccccc,
            32'hdddddddd, 32'heeeeeeee, 32'hffffffff, 32'hffffffff,
            32'heeeeeeee, 32'hdddddddd, 32'hcccccccc, 32'hbbbbbbbb,
            32'haaaaaaaa, 32'h99999999, 32'h88888888, 32'h77777777,
            32'h66666666, 32'h55555555, 32'h44444444, 32'h33333333,
            32'h22222222, 32'h11111111
        };

        // TEST 1: Reset - first packet at PC_RESET visible, decode stalled
        $display("[TEST 1] Reset and PC Initialization");
        do_reset(PC_RESET);

        check_assertion("First instruction PC is PC_RESET",
                        inst_pcs_o[0] == PC_RESET,
                        $sformatf("Expected 0x%h, got 0x%h", PC_RESET, inst_pcs_o[0]));
        check_assertion("First instruction is 0x11111111",
                        insts_o[0] == 32'h11111111,
                        $sformatf("Expected 0x11111111, got 0x%h", insts_o[0]));
        check_assertion("Second instruction is 0x22222222",
                        insts_o[1] == 32'h22222222,
                        $sformatf("Expected 0x22222222, got 0x%h", insts_o[1]));
        check_assertion("fetch_val high after reset",
                        fetch_vals_o != '0,
                        $sformatf("fetch_vals=%b", fetch_vals_o));
        check_assertion("fetch_vals both set on normal fetch",
                        fetch_vals_o == 2'b11,
                        $sformatf("fetch_vals=%b, expected 2'b11", fetch_vals_o));
        $display("");

        // TEST 2: Sequential program order - consume one pair at a time
        $display("[TEST 2] Sequential Fetching and Program Order");
        do_reset(PC_RESET);
        instruction_index = 0;

        for (int i = 0; i < 10; i++) begin
            check_assertion($sformatf("Inst[0] program order [pair %0d]", i),
                            insts_o[0] == expected_sequence[instruction_index],
                            $sformatf("Expected 0x%h, got 0x%h",
                                      expected_sequence[instruction_index], insts_o[0]));
            check_assertion($sformatf("Inst[1] program order [pair %0d]", i),
                            insts_o[1] == expected_sequence[instruction_index+1],
                            $sformatf("Expected 0x%h, got 0x%h",
                                      expected_sequence[instruction_index+1], insts_o[1]));
            check_assertion($sformatf("PC[0] address [pair %0d]", i),
                            inst_pcs_o[0] == (PC_RESET + instruction_index*4),
                            $sformatf("Expected 0x%h, got 0x%h",
                                      PC_RESET + instruction_index*4, inst_pcs_o[0]));
            check_assertion($sformatf("PC[1] = PC[0]+4 [pair %0d]", i),
                            inst_pcs_o[1] == inst_pcs_o[0] + 4,
                            $sformatf("Expected 0x%h, got 0x%h",
                                      inst_pcs_o[0]+4, inst_pcs_o[1]));
            check_assertion($sformatf("fetch_vals=2'b11 on sequential fetch [pair %0d]", i),
                            fetch_vals_o == 2'b11,
                            $sformatf("fetch_vals=%b, expected 2'b11", fetch_vals_o));
            $display("  [Pair %0d] 0x%h:0x%h | 0x%h:0x%h | fetch_vals=%b ✓",
                     i, inst_pcs_o[0], insts_o[0],
                        inst_pcs_o[1], insts_o[1], fetch_vals_o);
            instruction_index += 2;
            decode_rdy_i = 1;
            @(posedge clk);
            decode_rdy_i = 0;
            while (fetch_vals_o == '0) @(posedge clk);
        end
        $display("");

        // TEST 3: Decoder stall - output held while decode_rdy=0
        $display("[TEST 3] Decoder Stall (Backpressure)");
        do_reset(PC_RESET);
        decode_rdy_i = 1;
        @(posedge clk);
        decode_rdy_i = 0;
        while (fetch_vals_o == '0) @(posedge clk);

        pc_before_stall    = inst_pcs_o[0];
        inst0_before_stall = insts_o[0];

        for (int i = 0; i < 3; i++) begin
            @(posedge clk);
            check_assertion($sformatf("Output held during stall (cycle %0d)", i),
                            inst_pcs_o[0] == pc_before_stall &&
                            insts_o[0]    == inst0_before_stall,
                            $sformatf("PC 0x%h->0x%h Inst 0x%h->0x%h",
                                      pc_before_stall, inst_pcs_o[0],
                                      inst0_before_stall, insts_o[0]));
            $display("    [STALLED] PC held at 0x%h", inst_pcs_o[0]);
        end

        decode_rdy_i = 1;
        @(posedge clk);
        check_assertion("Fetch advances after stall release",
                        inst_pcs_o[0] != pc_before_stall || fetch_vals_o == '0,
                        "PC did not advance after stall release");
        $display("  Stall released");
        display_fetch_output();
        $display("");

        // TEST 4: Fill/drain decoupling - fill with decode stalled, drain via decode
        $display("[TEST 4] Buffer Fill and Drain Decoupling");
        $display("  Filling buffer (decode stalled)...");
        do_reset(PC_RESET);
        wait_for_fetch(INST_BUF_DEPTH);
        check_assertion("Buffer fills when decode stalled",
                        dut.ib.is_full == 1'b1,
                        $sformatf("is_full=%b", dut.ib.is_full));

        $display("  Stopping fetch (flush), then draining...");
        bpu_redirect_pc = PC_RESET;
        flush_i         = 1;
        @(posedge clk);
        flush_i = 0;
        wait_for_fetch(INST_BUF_DEPTH);
        check_assertion("Buffer refilled after flush",
                        dut.ib.is_full == 1'b1,
                        $sformatf("is_full=%b after refill", dut.ib.is_full));

        flush_i = 1;
        @(posedge clk);
        flush_i = 0;
        wait_for_fetch(INST_BUF_DEPTH);
        check_assertion("Buffer full before drain",
                        dut.ib.is_full == 1'b1,
                        $sformatf("is_full=%b", dut.ib.is_full));

        decode_rdy_i             = 1;
        drain_cycles             = 0;
        cycles_with_valid_output = 0;
        repeat (INST_BUF_DEPTH) begin
            @(posedge clk);
            if (fetch_vals_o != '0) cycles_with_valid_output++;
            drain_cycles++;
        end
        decode_rdy_i = 0;
        check_assertion("Valid output on every drain cycle",
                        cycles_with_valid_output == INST_BUF_DEPTH,
                        $sformatf("valid=%0d expected=%0d",
                                  cycles_with_valid_output, INST_BUF_DEPTH));
        $display("    Drained %0d entries in %0d cycles", cycles_with_valid_output, drain_cycles);

        $display("  Normal operation (both running)...");
        decode_rdy_i = 1;
        wait_for_fetch(5);
        check_assertion("Normal operation: buffer neither full nor empty",
                        !dut.ib.is_empty && !dut.ib.is_full,
                        $sformatf("is_empty=%b is_full=%b", dut.ib.is_empty, dut.ib.is_full));
        $display("");

        // TEST 5: Flush/redirect - buffer clears, output shows redirect PC
        $display("[TEST 5] Flush / Redirect");
        redirect_target = 32'h0000_0010;
        $display("  Redirecting to 0x%h", redirect_target);

        decode_rdy_i    = 0;
        bpu_redirect_pc = redirect_target;
        flush_i         = 1;
        @(posedge clk);
        check_assertion("imem_req_packet follows redirect target",
                        imem_req_packet == redirect_target,
                        $sformatf("Expected 0x%h, got 0x%h", redirect_target, imem_req_packet));

        flush_i = 0;
        @(posedge clk);
        @(posedge clk);
        check_assertion("inst_pcs[0] matches redirect target",
                        inst_pcs_o[0] == redirect_target,
                        $sformatf("Expected 0x%h, got 0x%h", redirect_target, inst_pcs_o[0]));
        display_fetch_output();

        decode_rdy_i = 1;
        @(posedge clk);
        decode_rdy_i = 0;
        while (fetch_vals_o == '0) @(posedge clk);
        check_assertion("Sequential fetch after redirect (PC+8)",
                        inst_pcs_o[0] == redirect_target + 8,
                        $sformatf("Expected 0x%h, got 0x%h", redirect_target + 8, inst_pcs_o[0]));
        $display("");

        // TEST 6: Multiple consecutive redirects
        $display("[TEST 6] Multiple Consecutive Redirects");
        targets = '{32'h0000_0020, 32'h0000_0030, 32'h0000_0040};
        for (int i = 0; i < 3; i++) begin
            $display("  Redirect %0d to 0x%h", i, targets[i]);
            bpu_redirect_pc = targets[i];
            flush_i         = 1;
            @(posedge clk);
            check_assertion($sformatf("Redirect %0d: imem_req_packet correct", i),
                            imem_req_packet == targets[i],
                            $sformatf("Expected 0x%h, got 0x%h", targets[i], imem_req_packet));
            flush_i = 0;
            wait_for_fetch(2);
        end
        $display("");

        // TEST 7: pc_vals=2'b01 stored - inst1 squashed, set before rst so first CE captures it
        $display("[TEST 7] fetch_vals: inst0 predicted taken squashes inst1");
        rst             = 1;
        flush_i         = 0;
        pc_vals_i       = 2'b01;
        decode_rdy_i    = 0;
        bpu_redirect_pc = '0;

        @(posedge clk);
        rst = 0;
        @(posedge clk);
        @(posedge clk);

        check_assertion("fetch_vals[0] set when inst0 taken",
                        fetch_vals_o[0] == 1'b1,
                        $sformatf("fetch_vals=%b", fetch_vals_o));
        check_assertion("fetch_vals[1] clear when inst0 taken",
                        fetch_vals_o[1] == 1'b0,
                        $sformatf("fetch_vals=%b, expected 01", fetch_vals_o));
        $display("  fetch_vals=%b (inst0 valid, inst1 squashed) ✓", fetch_vals_o);
        pc_vals_i    = 2'b11;
        decode_rdy_i = 1;
        $display("");

        // TEST 8: Flush clears output immediately, recovers on next valid packet
        $display("[TEST 8] fetch_vals: flush clears output immediately");
        do_reset(PC_RESET);
        wait_for_fetch(2);

        bpu_redirect_pc = 32'h0000_0050;
        flush_i         = 1;
        @(posedge clk);
        check_assertion("fetch_vals=0 on flush cycle",
                        fetch_vals_o == '0,
                        $sformatf("fetch_vals=%b, expected 2'b00", fetch_vals_o));

        flush_i = 0;
        @(posedge clk);
        @(posedge clk);
        check_assertion("fetch_vals=2'b11 after flush recovery",
                        fetch_vals_o == 2'b11,
                        $sformatf("fetch_vals=%b", fetch_vals_o));
        $display("  Post-flush recovery: fetch_vals=%b ✓", fetch_vals_o);
        decode_rdy_i = 1;
        $display("");

        // TEST 9: pc_vals mask held stable across decoder stall cycles
        $display("[TEST 9] fetch_vals mask preserved through decoder stall");
        rst             = 1;
        flush_i         = 0;
        pc_vals_i       = 2'b01;
        decode_rdy_i    = 0;
        bpu_redirect_pc = '0;

        @(posedge clk);
        rst = 0;
        @(posedge clk);
        @(posedge clk);
        saved_fetch_vals = fetch_vals_o;

        repeat(3) begin
            @(posedge clk);
            check_assertion("fetch_vals held during decoder stall",
                            fetch_vals_o == saved_fetch_vals,
                            $sformatf("fetch_vals changed: %b -> %b",
                                      saved_fetch_vals, fetch_vals_o));
        end
        $display("  fetch_vals=%b held correctly through stall ✓", saved_fetch_vals);
        pc_vals_i    = 2'b11;
        decode_rdy_i = 1;
        $display("");

        // TEST 10: Program order maintained through stalls and redirects
        $display("[TEST 10] Program Order Through Stalls and Redirects");
        $display("  Scenario 1: Order through decoder stall...");
        do_reset(PC_RESET);
        inst_before_stall = insts_o[0];
        pc_before_stall   = inst_pcs_o[0];

        repeat(3) @(posedge clk);
        check_assertion("Output held during stall",
                        insts_o[0] == inst_before_stall,
                        $sformatf("0x%h -> 0x%h", inst_before_stall, insts_o[0]));

        decode_rdy_i = 1;
        @(posedge clk);
        decode_rdy_i = 0;
        while (fetch_vals_o == '0) @(posedge clk);

        idx           = (pc_before_stall - PC_RESET) / 4;
        expected_next = expected_sequence[idx + 2];
        check_assertion("Next instruction in sequence after stall",
                        insts_o[0] == expected_next,
                        $sformatf("Expected 0x%h, got 0x%h", expected_next, insts_o[0]));
        $display("    Order maintained: 0x%h -> 0x%h ✓", inst_before_stall, insts_o[0]);

        $display("  Scenario 2: Order after redirect...");
        redirect_addr   = 32'h00000020;
        redirect_idx    = redirect_addr / 4;
        bpu_redirect_pc = redirect_addr;
        flush_i         = 1;
        @(posedge clk);
        flush_i = 0;
        @(posedge clk);
        @(posedge clk);

        check_assertion("First inst after redirect matches target",
                        insts_o[0] == expected_sequence[redirect_idx],
                        $sformatf("Expected 0x%h, got 0x%h",
                                  expected_sequence[redirect_idx], insts_o[0]));
        check_assertion("Second inst after redirect is sequential",
                        insts_o[1] == expected_sequence[redirect_idx+1],
                        $sformatf("Expected 0x%h, got 0x%h",
                                  expected_sequence[redirect_idx+1], insts_o[1]));
        $display("    Redirect to 0x%h: 0x%h, 0x%h ✓", redirect_addr, insts_o[0], insts_o[1]);

        decode_rdy_i = 1;
        @(posedge clk);
        decode_rdy_i = 0;
        while (fetch_vals_o == '0) @(posedge clk);

        check_assertion("Sequence continues after redirect",
                        insts_o[0] == expected_sequence[redirect_idx+2],
                        $sformatf("Expected 0x%h, got 0x%h",
                                  expected_sequence[redirect_idx+2], insts_o[0]));
        $display("    Continued: 0x%h, 0x%h ✓", insts_o[0], insts_o[1]);
        $display("");

        // TEST 11: Flush while imem_rec_val=1 - stale in-flight packet must not enter buffer
        $display("[TEST 11] Flush suppresses in-flight imem response");
        do_reset(PC_RESET);
        decode_rdy_i = 1;
        @(posedge clk);             // consume entry 0, next request now in-flight
        decode_rdy_i = 0;

        bpu_redirect_pc = 32'h0000_0050;
        flush_i         = 1;        // lands same cycle imem_rec_val rises for in-flight req
        @(posedge clk);
        flush_i = 0;
        @(posedge clk);
        @(posedge clk);             // post-flush packet lands

        check_assertion("In-flight packet discarded: buffer contains post-flush PC",
                        inst_pcs_o[0] == 32'h0000_0050,
                        $sformatf("Expected 0x50, got 0x%h", inst_pcs_o[0]));
        check_assertion("No stale data visible after flush",
                        fetch_vals_o != '0,
                        "Buffer empty - should have post-flush entry");
        $display("  Post-flush PC=0x%h, fetch_vals=%b ✓", inst_pcs_o[0], fetch_vals_o);
        decode_rdy_i = 1;
        $display("");

        // TEST 12: Flush while buffer full + decode stalled
        // inst_buffer_rdy = ~is_full || flush lets ce fire on the flush cycle
        // so the redirect request isn't lost when the buffer was saturated.
        $display("[TEST 12] Flush during full buffer with decode stalled");
        do_reset(PC_RESET);
        wait_for_fetch(INST_BUF_DEPTH);
        check_assertion("Buffer full before flush",
                        dut.ib.is_full == 1'b1,
                        $sformatf("is_full=%b", dut.ib.is_full));

        bpu_redirect_pc = 32'h0000_0060;
        flush_i         = 1;        // inst_buffer_rdy forced 1, request for 0x60 fires this cycle
        @(posedge clk);             // buffer clears, pc→0x60, imem captures 0x60
        flush_i = 0;

        check_assertion("fetch_vals=0 on flush cycle",
                        fetch_vals_o == '0,
                        $sformatf("fetch_vals=%b, expected 0", fetch_vals_o));

        @(posedge clk);             // imem_rec for 0x60 arrives, written to buf_q

        check_assertion("Post-flush entry valid",
                        fetch_vals_o != '0,
                        $sformatf("fetch_vals=%b, expected non-zero", fetch_vals_o));
        check_assertion("Post-flush PC is redirect target",
                        inst_pcs_o[0] == 32'h0000_0060,
                        $sformatf("Expected 0x60, got 0x%h", inst_pcs_o[0]));
        $display("  PC=0x%h fetch_vals=%b ✓", inst_pcs_o[0], fetch_vals_o);

        decode_rdy_i = 1;
        @(posedge clk);
        decode_rdy_i = 0;
        $display("  Entry consumed correctly");
        $display("");

        // End
        wait_for_fetch(5);
        $display("========================================");
        $display("  All Tests Complete");
        $display("========================================");
        $display("  Passed:  %0d", tests_passed);
        $display("  Failed:  %0d", tests_failed);
        $display("  Total:   %0d", assertions_checked);
        $display("========================================");

        if (tests_failed == 0)
            $display("  ALL TESTS PASSED ✓");
        else begin
            $display("  SOME TESTS FAILED ✗");
            $fatal(1, "Test failures detected");
        end

        $finish;
    end

    // Timeout watchdog
    initial begin
        #100000;
        $display("\n[ERROR] Testbench timeout!");
        $finish;
    end

endmodule
