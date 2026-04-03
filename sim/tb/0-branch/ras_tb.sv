`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module ras_tb;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;

    //-------------------------------------------------------------
    // Clock / Reset
    //-------------------------------------------------------------
    logic clk = 0;
    logic rst;
    always #(CLK_PERIOD/2) clk = ~clk;

    //-------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------
    localparam DEPTH = RAS_ENTRIES;
    localparam PTR_WIDTH = $clog2(DEPTH);

    //-------------------------------------------------------------
    // DUT I/O
    //-------------------------------------------------------------
    logic [CPU_ADDR_BITS-1:0] peek_addr;
    logic                     peek_rdy;

    logic                     push;
    logic                     pop;
    logic [CPU_ADDR_BITS-1:0] push_addr;
    logic                     push_rdy;
    logic                     pop_rdy;

    logic [PTR_WIDTH:0]       ptr;

    logic                     recover;
    logic [PTR_WIDTH:0]       recover_ptr;

    //-------------------------------------------------------------
    // Checkpoint Storage (simulates FTQ / ROB)
    //-------------------------------------------------------------
    logic [PTR_WIDTH:0] saved_checkpoints [0:31];
    logic [CPU_ADDR_BITS-1:0] peek_seen;

    //-------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------
    ras #(
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),

        // fetch-time peek
        .peek_addr(peek_addr),
        .peek_rdy(peek_rdy),

        // dispatch-time mutation
        .push(push),
        .pop(pop),
        .push_addr(push_addr),
        .push_rdy(push_rdy),
        .pop_rdy(pop_rdy),

        // checkpoint + recovery
        .ptr(ptr),
        .recover(recover),
        .recover_ptr(recover_ptr)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------
    task automatic clear_signals();
        push        = 1'b0;
        pop         = 1'b0;
        push_addr   = '0;
        recover     = 1'b0;
        recover_ptr = '0;
    endtask

    task automatic do_reset();
        @(negedge clk);
        rst = 1'b1;
        clear_signals();
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    task automatic do_push(input logic [CPU_ADDR_BITS-1:0] addr);
        @(negedge clk);
        push = 1'b1;
        push_addr = addr;
        @(negedge clk);
        push = 1'b0;
    endtask

    // Fetch observes peek_addr, dispatch consumes via pop
    task automatic do_pop_check(
        input string name,
        input logic [CPU_ADDR_BITS-1:0] expected
    );
        logic [CPU_ADDR_BITS-1:0] seen;
        logic pass;
        string msg;

        @(negedge clk);
        seen = peek_addr;   // fetch-time read

        pop = 1'b1;         // dispatch-time consume
        @(negedge clk);
        pop = 1'b0;

        pass = (seen === expected);

        if (pass) begin
            $display("  [PASS] %-30s : addr=0x%08h ptr=%0d",
                     name, seen, ptr);
            tests_passed++;
        end else begin
            msg = $sformatf("addr=0x%08h (exp 0x%08h) ptr=%0d",
                            seen, expected, ptr);
            $display("  [FAIL] %-30s : %s", name, msg);
            tests_failed++;
        end
    endtask

    task automatic save_checkpoint(input int id);
        saved_checkpoints[id] = ptr;
    endtask

    task automatic do_recover(input int id);
        @(negedge clk);
        recover = 1'b1;
        recover_ptr = saved_checkpoints[id];
        @(negedge clk);
        recover = 1'b0;
    endtask

    task automatic check_ptr(
        input string name,
        input logic [PTR_WIDTH:0] exp
    );
        @(negedge clk);
        if (ptr === exp) begin
            $display("  [PASS] %-30s : ptr=%0d", name, ptr);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-30s : ptr=%0d (exp %0d)", name, ptr, exp);
            tests_failed++;
        end
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("ras_tb.vcd");
        $dumpvars(0, ras_tb);

        $display("========================================");
        $display("  RAS Testbench");
        $display("  DEPTH = %0d", DEPTH);
        $display("========================================\n");

        //---------------------------------------------------------
        // TEST 1: Basic Push / Pop
        //---------------------------------------------------------
        do_reset();
        check_ptr("Initial empty", 0);
        do_push(32'h1000);
        check_ptr("After push", 1);
        do_pop_check("Pop", 32'h1000);
        check_ptr("Back to empty", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 2: LIFO Order
        //---------------------------------------------------------
        do_push(32'hAAAA);
        do_push(32'hBBBB);
        do_push(32'hCCCC);
        check_ptr("Three entries", 3);
        do_pop_check("Pop CCCC", 32'hCCCC);
        do_pop_check("Pop BBBB", 32'hBBBB);
        do_pop_check("Pop AAAA", 32'hAAAA);
        check_ptr("Empty", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 3: Checkpoint & Recovery
        //---------------------------------------------------------
        do_push(32'h1000);
        do_push(32'h2000);
        save_checkpoint(0);          // ptr=2
        do_push(32'h3000);
        do_push(32'h4000);
        check_ptr("Four entries", 4);
        do_recover(0);
        check_ptr("Recovered to 2", 2);
        do_pop_check("Pop 2000", 32'h2000);
        do_pop_check("Pop 1000", 32'h1000);
        check_ptr("Empty", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 4: Pop from Empty
        //---------------------------------------------------------
        do_reset();
        @(negedge clk);
        pop = 1'b1;
        @(negedge clk);
        pop = 1'b0;
        check_ptr("Ptr stays 0", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 5: Fill to DEPTH
        //---------------------------------------------------------
        do_reset();
        for (int i = 0; i < DEPTH; i++)
            do_push(32'h7000 + i*4);
        check_ptr("Filled", DEPTH);
        for (int i = DEPTH-1; i >= 0; i--)
            do_pop_check($sformatf("Pop %0d", i), 32'h7000 + i*4);
        check_ptr("Empty", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 6: Overflow
        //---------------------------------------------------------
        do_reset();
        for (int i = 0; i < DEPTH; i++)
            do_push(32'h8000 + i*4);
        do_push(32'hDEAD_BEEF);
        check_ptr("Overflow prevented", DEPTH);
        $display("");

        //---------------------------------------------------------
        // TEST 7: Multiple Checkpoints
        //---------------------------------------------------------
        do_reset();
        save_checkpoint(0);
        do_push(32'hA000);
        save_checkpoint(1);
        do_push(32'hB000);
        save_checkpoint(2);
        do_push(32'hC000);
        do_recover(1);
        check_ptr("Back to 1", 1);
        do_pop_check("Pop A000", 32'hA000);
        check_ptr("Empty", 0);
        $display("");

        //---------------------------------------------------------
        // TEST 8: Interleaved Ops
        //---------------------------------------------------------
        do_reset();
        do_push(32'h1111);
        save_checkpoint(10);
        do_push(32'h2222);
        do_pop_check("Pop 2222", 32'h2222);
        do_push(32'h3333);
        save_checkpoint(11);
        do_push(32'h4444);
        do_recover(10);
        check_ptr("Recovered to 1", 1);
        do_pop_check("Pop 1111", 32'h1111);
        $display("");

        //---------------------------------------------------------
        // TEST 9: Stress Test
        //---------------------------------------------------------
        do_reset();
        for (int i = 0; i < 8; i++)
            do_push(32'hC000 + i*4);
        save_checkpoint(20);
        repeat (4) begin
            @(negedge clk); pop = 1'b1;
            @(negedge clk); pop = 1'b0;
        end
        check_ptr("After pops", 4);
        for (int i = 0; i < 4; i++)
            do_push(32'hD000 + i*4);
        check_ptr("Back to 8", 8);
        do_recover(20);
        check_ptr("Recovered", 8);
        $display("");

        //---------------------------------------------------------
        // TEST 10: Same-Cycle Recover + Peek
        //---------------------------------------------------------
        do_reset();
        do_push(32'h1111);
        do_push(32'h2222);
        do_push(32'h3333);
        save_checkpoint(0);
        saved_checkpoints[0] = 1;   // force recover to ptr=1

        do_push(32'h4444);
        do_push(32'h5555);
        check_ptr("Speculative depth", 5);

        @(negedge clk);
        recover     = 1'b1;
        recover_ptr = saved_checkpoints[0];

        #1;
        peek_seen   = peek_addr;

        @(negedge clk);
        recover = 1'b0;

        if (peek_seen === 32'h1111) begin
            $display("  [PASS] %-30s : peek=0x%08h",
                     "Recover+peek same cycle", peek_seen);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-30s : peek=0x%08h (exp 0x1111)",
                     "Recover+peek same cycle", peek_seen);
            tests_failed++;
        end

        check_ptr("Recovered ptr", 1);
        do_pop_check("Post-recover pop", 32'h1111);
        $display("");

        //---------------------------------------------------------
        // Summary
        //---------------------------------------------------------
        $display("========================================");
        $display("  Tests Passed: %0d", tests_passed);
        $display("  Tests Failed: %0d", tests_failed);
        $display("========================================");

        if (tests_failed == 0)
            $display("  ✓ ALL TESTS PASSED!");
        else
            $fatal(1, "FAILURES DETECTED");

        $finish;
    end

    //-------------------------------------------------------------
    // Timeout
    //-------------------------------------------------------------
    initial begin
        #200000;
        $fatal(1, "Timeout!");
    end

endmodule
