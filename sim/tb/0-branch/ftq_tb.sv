`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module ftq_tb;

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
    logic flush;
    always #(CLK_PERIOD/2) clk = ~clk;

    //-------------------------------------------------------------
    // DUT I/O
    //-------------------------------------------------------------
    logic [FETCH_WIDTH-1:0]          enq_en;
    ftq_entry_t [FETCH_WIDTH-1:0]    enq_data;
    logic [FETCH_WIDTH-1:0]          enq_rdy;
    
    logic [FETCH_WIDTH-1:0]          deq_en;
    ftq_entry_t [FETCH_WIDTH-1:0]    deq_data;
    logic [FETCH_WIDTH-1:0]          deq_rdy;

    //-------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------
    ftq dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .enq_en(enq_en),
        .enq_data(enq_data),
        .enq_rdy(enq_rdy),
        .deq_en(deq_en),
        .deq_data(deq_data),
        .deq_rdy(deq_rdy)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------
    task automatic reset();
        @(negedge clk);
        rst = 1'b1;
        flush = 1'b0;
        enq_en = '0;
        deq_en = '0;
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
    endtask

    task automatic do_enqueue(
        input logic [FETCH_WIDTH-1:0] en,
        input ftq_entry_t [FETCH_WIDTH-1:0] data
    );
        @(negedge clk);
        enq_en = en;
        enq_data = data;
        @(negedge clk);
        enq_en = '0;
        @(posedge clk);  // Wait for state update
        #1;  // Let ready signals settle
    endtask

    task automatic do_dequeue(
        input logic [FETCH_WIDTH-1:0] en,
        output ftq_entry_t [FETCH_WIDTH-1:0] data
    );
        @(negedge clk);
        deq_en = en;
        #1;
        data = deq_data;
        @(negedge clk);
        deq_en = '0;
        @(posedge clk);
        #1;
    endtask

    task automatic do_flush();
        @(negedge clk);
        flush = 1'b1;
        @(negedge clk);
        flush = 1'b0;
    endtask

    function automatic ftq_entry_t make_entry(
        input logic [CPU_ADDR_BITS-1:0] pc
    );
        ftq_entry_t entry;
        branch_pred_t data;
        data.tage.provider = TAGE_TABLES;
        data.tage.pred_taken = 1'b0;
        data.tage.pred_alt = 1'b0;
        data.btb.btype = BRANCH_COND;
        data.btb.targ = pc + 4;
        data.btb.hit = 1'b0;

        entry.val = 1'b1;
        entry.pc = pc;
        entry.pred = data;
        entry.ghr_cp = '0;
        entry.ras_cp = '0;
        
        return entry;
    endfunction

    task automatic check_rdy(
        input string name,
        input logic [1:0] expected_enq,
        input logic [1:0] expected_deq
    );
        if (enq_rdy !== expected_enq) begin
            $display("  [FAIL] %-35s : enq_rdy=%b (exp=%b)", name, enq_rdy, expected_enq);
            tests_failed++;
        end else if (deq_rdy !== expected_deq) begin
            $display("  [FAIL] %-35s : deq_rdy=%b (exp=%b)", name, deq_rdy, expected_deq);
            tests_failed++;
        end else begin
            $display("  [PASS] %-35s : enq_rdy=%b deq_rdy=%b", name, enq_rdy, deq_rdy);
            tests_passed++;
        end
    endtask

    task automatic check_deq_data(
        input string name,
        input ftq_entry_t [FETCH_WIDTH-1:0] data,
        input int slot,
        input logic [CPU_ADDR_BITS-1:0] expected_pc
    );
        if (data[slot].pc !== expected_pc) begin
            $display("  [FAIL] %-35s : slot%0d pc=0x%h (exp=0x%h)", 
                     name, slot, data[slot].pc, expected_pc);
            tests_failed++;
        end else begin
            $display("  [PASS] %-35s : slot%0d pc=0x%h", name, slot, data[slot].pc);
            tests_passed++;
        end
    endtask

    //-------------------------------------------------------------
    // Main Test
    //-------------------------------------------------------------
    initial begin
        ftq_entry_t [FETCH_WIDTH-1:0] deq_result;
        
        $display("========================================");
        $display("  FTQ Testbench");
        $display("========================================");
        $display("  FTQ_ENTRIES  = %0d", FTQ_ENTRIES);
        $display("  FETCH_WIDTH  = %0d", FETCH_WIDTH);
        $display("========================================");

        //---------------------------------------------------------
        // TEST 1: Basic Enqueue and Dequeue
        //---------------------------------------------------------
        $display("[TEST 1] Basic Enqueue and Dequeue");
        reset();
        
        check_rdy("After reset", 2'b11, 2'b00);
        
        do_enqueue(2'b01, '{'0, make_entry(32'h1000)});
        check_rdy("After enqueue 1", 2'b11, 2'b01);
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("Dequeue data", deq_result, 0, 32'h1000);
        check_rdy("After dequeue 1", 2'b11, 2'b00);
        $display("");

        //---------------------------------------------------------
        // TEST 2: Dual Enqueue
        //---------------------------------------------------------
        $display("[TEST 2] Dual Enqueue");
        reset();
        
        do_enqueue(2'b11, '{make_entry(32'h2004), make_entry(32'h2000)});
        check_rdy("After enqueue 2", 2'b11, 2'b11);
        
        do_dequeue(2'b11, deq_result);
        check_deq_data("Dequeue slot 0", deq_result, 0, 32'h2000);
        check_deq_data("Dequeue slot 1", deq_result, 1, 32'h2004);
        $display("");

        //---------------------------------------------------------
        // TEST 3: Fill Queue
        //---------------------------------------------------------
        $display("[TEST 3] Fill Queue");
        reset();
        
        for (int i = 0; i < FTQ_ENTRIES/2; i++) begin
            do_enqueue(2'b11, '{make_entry(32'h3004 + i*8), make_entry(32'h3000 + i*8)});
        end
        
        check_rdy("After filling", 2'b00, 2'b11);
        $display("");

        //---------------------------------------------------------
        // TEST 4: Wraparound
        //---------------------------------------------------------
        $display("[TEST 4] Wraparound");
        reset();
        
        for (int i = 0; i < FTQ_ENTRIES/2; i++) begin
            do_enqueue(2'b11, '{make_entry(32'h4004 + i*8), make_entry(32'h4000 + i*8)});
        end
        
        for (int i = 0; i < FTQ_ENTRIES/4; i++) begin
            do_dequeue(2'b11, deq_result);
        end
        
        for (int i = 0; i < FTQ_ENTRIES/4; i++) begin
            do_enqueue(2'b11, '{make_entry(32'h5004 + i*8), make_entry(32'h5000 + i*8)});
        end
        
        check_rdy("After wraparound", 2'b00, 2'b11);
        $display("");

        //---------------------------------------------------------
        // TEST 5: Bypass
        //---------------------------------------------------------
        $display("[TEST 5] Bypass - Enqueue When Full with Dequeue");
        reset();
        
        for (int i = 0; i < FTQ_ENTRIES/2; i++) begin
            do_enqueue(2'b11, '{make_entry(32'h6004 + i*8), make_entry(32'h6000 + i*8)});
        end
        check_rdy("Queue full", 2'b00, 2'b11);
        
        @(negedge clk);
        deq_en = 2'b11;
        enq_en = 2'b11;
        enq_data = '{make_entry(32'h7004), make_entry(32'h7000)};
        
        @(negedge clk);
        deq_en = '0;
        enq_en = '0;
        
        @(posedge clk);
        #1;  // Let signals settle
        
        check_rdy("After bypass", 2'b00, 2'b11);
        $display("");

        //---------------------------------------------------------
        // TEST 6: Flush
        //---------------------------------------------------------
        $display("[TEST 6] Flush");
        reset();
        
        for (int i = 0; i < 4; i++) begin
            do_enqueue(2'b11, '{make_entry(32'h8004 + i*8), make_entry(32'h8000 + i*8)});
        end
        
        check_rdy("Before flush", 2'b11, 2'b11);
        do_flush();
        check_rdy("After flush", 2'b11, 2'b00);
        $display("");

        //---------------------------------------------------------
        // TEST 7: Single Slot Operations
        //---------------------------------------------------------
        $display("[TEST 7] Single Slot Operations");
        reset();
        
        do_enqueue(2'b01, '{'0, make_entry(32'h9000)});
        check_rdy("After enq slot 0", 2'b11, 2'b01);
        
        do_enqueue(2'b01, '{'0, make_entry(32'h9004)});
        check_rdy("After 2nd enq slot 0", 2'b11, 2'b11);
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("Dequeue first", deq_result, 0, 32'h9000);
        check_rdy("After deq slot 0", 2'b11, 2'b01);
        $display("");

        //---------------------------------------------------------
        // TEST 8: FIFO Order
        //---------------------------------------------------------
        $display("[TEST 8] FIFO Order Verification");
        reset();
        
        do_enqueue(2'b11, '{make_entry(32'hA004), make_entry(32'hA000)});
        do_enqueue(2'b11, '{make_entry(32'hA00C), make_entry(32'hA008)});
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("FIFO order 1", deq_result, 0, 32'hA000);
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("FIFO order 2", deq_result, 0, 32'hA004);
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("FIFO order 3", deq_result, 0, 32'hA008);
        
        do_dequeue(2'b01, deq_result);
        check_deq_data("FIFO order 4", deq_result, 0, 32'hA00C);
        $display("");

        //---------------------------------------------------------
        // TEST 9: Almost Full Edge Cases
        //---------------------------------------------------------
        $display("[TEST 9] Almost Full Edge Cases");
        reset();
        
        for (int i = 0; i < 7; i++) begin
            do_enqueue(2'b11, '{make_entry(32'hB004 + i*8), make_entry(32'hB000 + i*8)});
        end
        do_enqueue(2'b01, '{'0, make_entry(32'hB070)});
        
        check_rdy("15/16 entries", 2'b01, 2'b11);
        
        do_enqueue(2'b01, '{'0, make_entry(32'hB074)});
        check_rdy("16/16 entries (full)", 2'b00, 2'b11);
        
        do_dequeue(2'b01, deq_result);
        @(negedge clk);
        check_rdy("15/16 entries again", 2'b01, 2'b11);
        $display("");

        //---------------------------------------------------------
        // TEST 10: Back-to-Back Operations
        //---------------------------------------------------------
        $display("[TEST 10] Back-to-Back Operations");
        reset();
        
        for (int i = 0; i < 8; i++) begin
            do_enqueue(2'b11, '{make_entry(32'hC004 + i*8), make_entry(32'hC000 + i*8)});
            do_dequeue(2'b01, deq_result);
        end
        
        check_rdy("After back-to-back", 2'b11, 2'b11);
        $display("");

        //---------------------------------------------------------
        // Summary
        //---------------------------------------------------------
        $display("========================================");
        $display("  Tests Passed: %0d", tests_passed);
        $display("  Tests Failed: %0d", tests_failed);
        $display("========================================");
        
        if (tests_failed == 0) begin
            $display("  ✓ ALL TESTS PASSED!");
        end else begin
            $display("  ✗ SOME TESTS FAILED!");
            $fatal(1, "Test failures detected");
        end
        
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Timeout - simulation ran too long");
    end

endmodule
