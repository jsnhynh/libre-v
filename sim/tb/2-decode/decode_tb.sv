`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module decode_tb;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;

    //-------------------------------------------------------------
    // Clock / Reset
    //-------------------------------------------------------------
    logic clk;
    logic rst;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------
    // Stimulus (inputs to DUT)
    //-------------------------------------------------------------
    logic                        flush_i;
    logic [CPU_ADDR_BITS-1:0]    inst_pcs_i [PIPE_WIDTH-1:0];
    logic [CPU_INST_BITS-1:0]    insts_i    [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]       fetch_vals_i;
    logic                        rename_rdy_i;   // bundle-ready: BOTH must be able to proceed

    //-------------------------------------------------------------
    // Monitored (outputs from DUT)
    //-------------------------------------------------------------
    logic                        decode_rdy_o;
    instruction_t                decoded_o   [PIPE_WIDTH-1:0];

    //-------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------
    decode dut (
        .clk(clk),
        .rst(rst),
        .flush(flush_i),

        // From Fetch
        .decode_rdy(decode_rdy_o),
        .inst_pcs(inst_pcs_i),
        .insts(insts_i),
        .fetch_vals(fetch_vals_i),

        // To Rename
        .rename_rdy(rename_rdy_i),
        .decoded_insts(decoded_o)
    );

    //-------------------------------------------------------------
    // Helpers
    //-------------------------------------------------------------
    instruction_t prev0, prev1;
    instruction_t hold0, hold1;

    task automatic check_assertion(
        input string test_name,
        input logic condition,
        input string fail_msg
    );
        assertions_checked++;
        if (condition) begin
            $display("%0t [PASS] %s", $time, test_name);
            tests_passed++;
        end else begin
            $display("%0t  [FAIL] %s: %s", $time, test_name, fail_msg);
            tests_failed++;
        end
    endtask

    task automatic init_signals();
        rst          = 1'b1;
        flush_i      = 1'b0;
        fetch_vals_i = '0;
        rename_rdy_i = 1'b1;    // downstream “bundle can accept” by default
        for (int i=0; i<PIPE_WIDTH; i++) begin
            inst_pcs_i[i] = '0;
            insts_i[i]    = '0;
        end
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;
    endtask

    // --- Tiny encoders (just enough for valid/invalid opcodes) ---
    function automatic logic [31:0] enc_R(
        input logic [6:0]  opcode,
        input logic [6:0]  funct7,
        input logic [2:0]  funct3,
        input logic [4:0]  rd,
        input logic [4:0]  rs1,
        input logic [4:0]  rs2
    );
        return {funct7, rs2, rs1, funct3, rd, opcode};
    endfunction

    // Known valid R-type ADD x3, x1, x2
    function automatic logic [31:0] valid_add();
        return enc_R(OPC_ARI_RTYPE, 7'b0, FNC_ADD_SUB, 5'd3, 5'd1, 5'd2);
    endfunction

    // Clearly invalid (unknown opcode 0)
    function automatic logic [31:0] invalid_instr();
        return 32'h00000000;
    endfunction

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("decode_tb.vcd");
        $dumpvars(0, decode_tb);

        $display("========================================");
        $display("  Decode Handshake + Valid Testbench");
        $display("========================================\n");

        init_signals();

        //---------------------------------------------------------
        // TEST 1: Reset -> outputs invalid
        //---------------------------------------------------------
        $display("[TEST 1] Reset clears outputs");
        check_assertion("decoded[0] invalid after reset",
                        decoded_o[0].is_valid == 1'b0,
                        $sformatf("is_valid=%0b", decoded_o[0].is_valid));
        check_assertion("decoded[1] invalid after reset",
                        decoded_o[1].is_valid == 1'b0,
                        $sformatf("is_valid=%0b", decoded_o[1].is_valid));
        $display("");

        //---------------------------------------------------------
        // TEST 2: Handshake high - BOTH can proceed
        //         fetch_vals=11, valid opcodes => both valid
        //---------------------------------------------------------
        $display("[TEST 2] rename_rdy=1, fetch_vals=11 => advance bundle");
        rename_rdy_i   = 1'b1;      // bundle-ready
        fetch_vals_i   = 2'b11;
        inst_pcs_i[0]  = 32'h1000; insts_i[0] = valid_add();
        inst_pcs_i[1]  = 32'h1004; insts_i[1] = valid_add();

        @(posedge clk); #1;

        check_assertion("decode_rdy mirrors rename_rdy (1)",
                        decode_rdy_o == 1'b1,
                        $sformatf("decode_rdy=%0b", decode_rdy_o));
        check_assertion("slot0 is_valid=1",
                        decoded_o[0].is_valid == 1'b1, "");
        check_assertion("slot1 is_valid=1",
                        decoded_o[1].is_valid == 1'b1, "");
        $display("");

        //---------------------------------------------------------
        // TEST 3: fetch_vals=00 -> when accepted, outputs invalid
        //---------------------------------------------------------
        $display("[TEST 3] fetch_vals=00 => invalid outputs when bundle accepted");
        fetch_vals_i   = 2'b00;
        rename_rdy_i   = 1'b1;      // still accepting bundle

        @(posedge clk); #1;

        check_assertion("slot0 invalid when fetch_vals=00",
                        decoded_o[0].is_valid == 1'b0, "");
        check_assertion("slot1 invalid when fetch_vals=00",
                        decoded_o[1].is_valid == 1'b0, "");
        $display("");

        //---------------------------------------------------------
        // TEST 4: Stall (rename_rdy=0) => hold BOTH; do not advance
        //---------------------------------------------------------
        $display("[TEST 4] Stall bundle if BOTH cannot proceed (rename_rdy=0 holds)");
        // Prime with a known valid pair
        fetch_vals_i   = 2'b11;
        rename_rdy_i   = 1'b1;
        insts_i[0]     = valid_add();
        insts_i[1]     = valid_add();
        @(posedge clk); #1;

        // Snapshot current outputs
        prev0 = decoded_o[0];
        prev1 = decoded_o[1];

        // Change inputs but deassert rename_rdy -> neither slot may advance
        insts_i[0]     = invalid_instr();   // would decode invalid if accepted
        insts_i[1]     = valid_add();       // valid
        fetch_vals_i   = 2'b11;
        rename_rdy_i   = 1'b0;              // NOT accepting bundle

        @(posedge clk); #1;

        check_assertion("decode_rdy mirrors rename_rdy (0)",
                        decode_rdy_o == 1'b0,
                        $sformatf("decode_rdy=%0b", decode_rdy_o));
        check_assertion("slot0 held during stall",
                        decoded_o[0] == prev0, "slot0 changed under stall");
        check_assertion("slot1 held during stall",
                        decoded_o[1] == prev1, "slot1 changed under stall");
        $display("");

        //---------------------------------------------------------
        // TEST 5: Mixed valid/invalid opcodes with bundle accepted
        //---------------------------------------------------------
        $display("[TEST 5] Mixed valid/invalid with bundle acceptance");
        // Now allow the bundle to be accepted
        rename_rdy_i   = 1'b1;      // bundle can proceed
        // Keep fetch_vals=11 and mixed instructions from previous setup
        @(posedge clk); #1;

        check_assertion("decode_rdy mirrors rename_rdy (1)",
                        decode_rdy_o == 1'b1, "");
        // Slot 0 was invalid opcode → is_valid=0
        check_assertion("slot0 is_valid=0 (invalid opcode)",
                        decoded_o[0].is_valid == 1'b0, "");
        // Slot 1 was valid opcode → is_valid=1
        check_assertion("slot1 is_valid=1 (valid opcode)",
                        decoded_o[1].is_valid == 1'b1, "");
        $display("");

        //---------------------------------------------------------
        // TEST 6: Per-slot valid mask passes through decode
        //---------------------------------------------------------
        $display("[TEST 6] fetch_vals mask is applied per slot");
        inst_pcs_i[0]  = 32'h2000;
        inst_pcs_i[1]  = 32'h2004;
        insts_i[0]     = valid_add();
        insts_i[1]     = valid_add();
        fetch_vals_i   = 2'b01;
        rename_rdy_i   = 1'b1;

        @(posedge clk); #1;

        check_assertion("slot0 valid when fetch_vals[0]=1",
                        decoded_o[0].is_valid == 1'b1, "");
        check_assertion("slot1 invalid when fetch_vals[1]=0",
                        decoded_o[1].is_valid == 1'b0, "");
        check_assertion("slot0 PC preserved under masked bundle",
                        decoded_o[0].pc == 32'h2000,
                        $sformatf("pc=0x%h", decoded_o[0].pc));
        $display("");

        //---------------------------------------------------------
        // TEST 7: Flush clears BOTH outputs to invalid
        //---------------------------------------------------------
        $display("[TEST 7] Flush clears outputs (bundle reset)");
        // Put valid data in first
        insts_i[0]     = valid_add();
        insts_i[1]     = valid_add();
        fetch_vals_i   = 2'b11;
        rename_rdy_i   = 1'b1;
        @(posedge clk); #1;

        flush_i = 1'b1; @(posedge clk); #1; flush_i = 1'b0;
        #1;

        check_assertion("slot0 invalid after flush",
                        decoded_o[0].is_valid == 1'b0, "");
        check_assertion("slot1 invalid after flush",
                        decoded_o[1].is_valid == 1'b0, "");
        $display("");

        //---------------------------------------------------------
        // TEST 8: Atomic bundle accept - only continue if BOTH can
        //---------------------------------------------------------
        $display("[TEST 8] Atomic bundle accept: only continue if BOTH can");
        // Present a new pair
        insts_i[0] = valid_add();
        insts_i[1] = valid_add();
        fetch_vals_i = 2'b11;

        // First, stall: rename_rdy=0 → nothing should change
        rename_rdy_i = 1'b0;
        hold0 = decoded_o[0];
        hold1 = decoded_o[1];
        @(posedge clk); #1;

        check_assertion("decode_rdy=0 when BOTH cannot proceed",
                        decode_rdy_o == 1'b0, "");
        check_assertion("slot0 held (atomic bundle rule)",
                        decoded_o[0] == hold0, "slot0 advanced during stall");
        check_assertion("slot1 held (atomic bundle rule)",
                        decoded_o[1] == hold1, "slot1 advanced during stall");

        // Now accept bundle atomically
        rename_rdy_i = 1'b1;
        @(posedge clk); #1;

        check_assertion("decode_rdy=1 when BOTH can proceed",
                        decode_rdy_o == 1'b1, "");
        check_assertion("slot0 advanced when BOTH ready",
                        decoded_o[0].is_valid == 1'b1, "");
        check_assertion("slot1 advanced when BOTH ready",
                        decoded_o[1].is_valid == 1'b1, "");
        $display("");

        //---------------------------------------------------------
        // End / Summary
        //---------------------------------------------------------
        #5;
        $display("========================================");
        $display("  All Tests Complete!");
        $display("========================================");
        $display("  Tests Passed:  %0d", tests_passed);
        $display("  Tests Failed:  %0d", tests_failed);
        $display("  Total Checks:  %0d", assertions_checked);
        $display("========================================");

        if (tests_failed == 0) begin
            $display("  ✓ ALL TESTS PASSED!");
        end else begin
            $display("  ✗ SOME TESTS FAILED!");
            $fatal(1, "Test failures detected");
        end

        $finish;
    end

    //-------------------------------------------------------------
    // Timeout Watchdog
    //-------------------------------------------------------------
    initial begin
        #100000;
        $display("\n[ERROR] Decode handshake testbench timeout!");
        $finish;
    end

endmodule
