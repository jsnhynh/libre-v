`timescale 1ns/1ps

import uarch_pkg::*;
import riscv_isa_pkg::*;

module rob_tb;
    //----------------------------------------------------------
    // Test Configuration
    //----------------------------------------------------------
    
    localparam int TEST_ROB_SIZE = 8;
    localparam int TEST_TAG_WIDTH = $clog2(TEST_ROB_SIZE);

    //----------------------------------------------------------
    // Test Infrastructure
    //----------------------------------------------------------
    
    int tests_passed = 0;
    int tests_failed = 0;
    int total_checks = 0;
    
    task check(input string name, input logic condition, input string msg = "");
        total_checks++;
        if (condition) begin
            $display("%0t [PASS] %s", $time, name);
            tests_passed++;
        end else begin
            $display("%0t [FAIL] %s", $time, name);
            if (msg != "") $display("        %s", msg);
            tests_failed++;
        end
    endtask

    //----------------------------------------------------------
    // DUT Signals
    //----------------------------------------------------------
    
    logic clk, rst;
    
    // Allocation
    logic [PIPE_WIDTH-1:0]              alloc_req;
    logic [PIPE_WIDTH-1:0]              alloc_gnt;
    logic [TEST_TAG_WIDTH-1:0]          alloc_tags [PIPE_WIDTH-1:0];
    
    // Dispatch
    logic [PIPE_WIDTH-1:0]              rob_rdy;
    logic [PIPE_WIDTH-1:0]              rob_we;
    rob_entry_t                         rob_entries [PIPE_WIDTH-1:0];
    
    // Writeback
    writeback_packet_t                  cdb_ports [PIPE_WIDTH-1:0];
    
    // Commit
    logic                               flush;
    logic [CPU_ADDR_BITS-1:0]           rob_pc;
    prf_commit_write_port_t             commit_ports [PIPE_WIDTH-1:0];
    logic [TEST_TAG_WIDTH-1:0]          store_ids [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]              store_vals;
    
    // Debug
    logic [TEST_TAG_WIDTH-1:0]          head, tail;

    //----------------------------------------------------------
    // DUT Instantiation
    //----------------------------------------------------------
    
    rob #(.N(TEST_ROB_SIZE)) dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .rob_pc(rob_pc),
        .rob_alloc_req(alloc_req),
        .rob_alloc_gnt(alloc_gnt),
        .rob_alloc_tags(alloc_tags),
        .rob_rdy(rob_rdy),
        .rob_we(rob_we),
        .rob_entries(rob_entries),
        .cdb_ports(cdb_ports),
        .commit_write_ports(commit_ports),
        .commit_store_ids(store_ids),
        .commit_store_vals(store_vals),
        .rob_head(head)
    );

    assign tail = dut.rob_tail;

    //----------------------------------------------------------
    // Clock Generation
    //----------------------------------------------------------
    
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //----------------------------------------------------------
    // Helper Tasks
    //----------------------------------------------------------
    
    task reset_dut();
        rst = 1;
        alloc_req = '0;
        rob_we = '0;
        rob_entries = '{default: '0};
        cdb_ports = '{default: '0};
        repeat(2) @(posedge clk);
        rst = 0;
        @(posedge clk);
        #1;
    endtask

    function automatic rob_entry_t make_entry(
        input logic [CPU_ADDR_BITS-1:0] pc,
        input logic [4:0] rd,
        input logic [6:0] opcode,
        input logic has_rd = 1'b1
    );
        rob_entry_t entry;
        entry = '{default: '0};
        entry.is_valid = 1'b1;
        entry.is_ready = 1'b0;
        entry.pc = pc;
        entry.rd = rd;
        entry.has_rd = has_rd;
        entry.opcode = opcode;
        entry.exception = 1'b0;
        entry.result = '0;
        return entry;
    endfunction

    // Single-cycle allocate and dispatch
    // All signals set together, captured on next posedge
    task allocate_and_dispatch(
        input rob_entry_t e0,
        input rob_entry_t e1,
        input logic [1:0] count
    );
        // Set allocation request and dispatch signals together
        alloc_req = count;
        rob_we = count;
        if (count[0]) rob_entries[0] = e0;
        if (count[1]) rob_entries[1] = e1;
        
        @(posedge clk);
        #1;
        
        // Clear all signals
        alloc_req = '0;
        rob_we = '0;
        rob_entries = '{default: '0};
    endtask

    task writeback_single(
        input logic [TEST_TAG_WIDTH-1:0] tag,
        input logic [CPU_DATA_BITS-1:0] result,
        input logic exception = 1'b0,
        input int port = 0
    );
        cdb_ports[port].is_valid = 1'b1;
        cdb_ports[port].dest_tag = tag;
        cdb_ports[port].result = result;
        cdb_ports[port].exception = exception;
        @(posedge clk);
        #1;
        cdb_ports[port] = '{default: '0};
    endtask

    task writeback_dual(
        input logic [TEST_TAG_WIDTH-1:0] tag0,
        input logic [CPU_DATA_BITS-1:0] result0,
        input logic [TEST_TAG_WIDTH-1:0] tag1,
        input logic [CPU_DATA_BITS-1:0] result1
    );
        cdb_ports[0] = '{is_valid: 1'b1, dest_tag: tag0, result: result0, exception: 1'b0};
        cdb_ports[1] = '{is_valid: 1'b1, dest_tag: tag1, result: result1, exception: 1'b0};
        @(posedge clk);
        #1;
        cdb_ports = '{default: '0};
    endtask

    task wait_cycles(input int n);
        repeat(n) @(posedge clk);
        #1;
    endtask

    //----------------------------------------------------------
    // Test Stimulus
    //----------------------------------------------------------
    
    initial begin
        $dumpfile("rob_tb.vcd");
        $dumpvars(0, rob_tb);
        
        $display("========================================");
        $display("  ROB Testbench (Single-Cycle Alloc)");
        $display("  ROB_SIZE = %0d", TEST_ROB_SIZE);
        $display("  PIPE_WIDTH = %0d", PIPE_WIDTH);
        $display("========================================\n");

        //---------------------------------------------------------------------
        // TEST 1: Reset and Initial State
        //---------------------------------------------------------------------
        $display("[TEST 1] Reset and Initial State");
        reset_dut();
        
        check("Head at zero", head == 0,
              $sformatf("Expected: 0, Got: %0d", head));
        check("Tail at zero", tail == 0,
              $sformatf("Expected: 0, Got: %0d", tail));
        check("ROB empty", dut.avail_slots == TEST_ROB_SIZE,
              $sformatf("Expected: %0d, Got: %0d", TEST_ROB_SIZE, dut.avail_slots));
        check("No flush on reset", !flush,
              $sformatf("Expected: 0, Got: %0d", flush));
        $display("");

        //---------------------------------------------------------------------
        // TEST 2: Basic Allocation and Commit
        //---------------------------------------------------------------------
        $display("[TEST 2] Basic Allocation and Commit");
        
        allocate_and_dispatch(
            make_entry(32'h00001000, 5'd5, OPC_ARI_ITYPE),
            make_entry(32'h00001004, 5'd6, OPC_ARI_ITYPE),
            2'b11
        );
        
        check("Tail advanced by 2", tail == 2,
              $sformatf("Expected: 2, Got: %0d", tail));
        check("Available slots decreased", dut.avail_slots == TEST_ROB_SIZE - 2,
              $sformatf("Expected: %0d, Got: %0d", TEST_ROB_SIZE - 2, dut.avail_slots));
        check("Entry 0 valid", dut.rob_mem[0].is_valid,
              $sformatf("Expected: 1, Got: %0d", dut.rob_mem[0].is_valid));
        check("Entry 1 valid", dut.rob_mem[1].is_valid,
              $sformatf("Expected: 1, Got: %0d", dut.rob_mem[1].is_valid));
        
        // Writeback and commit
        writeback_dual(3'd0, 32'hDEADBEEF, 3'd1, 32'hCAFEBABE);

        check("Both entries commit", commit_ports[0].we && commit_ports[1].we,
              $sformatf("Expected: we[0]=1 & we[1]=1, Got: we[0]=%0d & we[1]=%0d",
                       commit_ports[0].we, commit_ports[1].we));
        check("Correct data committed", 
              commit_ports[0].data == 32'hDEADBEEF && commit_ports[1].data == 32'hCAFEBABE,
              $sformatf("Expected: 0xDEADBEEF & 0xCAFEBABE, Got: 0x%h & 0x%h",
                       commit_ports[0].data, commit_ports[1].data));
        
        @(posedge clk);
        #1;
        check("Head advanced", head == 2,
              $sformatf("Expected: 2, Got: %0d", head));
        check("ROB empty", head == tail,
              $sformatf("Expected: head==tail, Got: head=%0d tail=%0d", head, tail));
        $display("");

        //---------------------------------------------------------------------
        // TEST 3: Out-of-Order Writeback
        //---------------------------------------------------------------------
        $display("[TEST 3] Out-of-Order Writeback");
        reset_dut();
        
        // Dispatch 4 instructions
        allocate_and_dispatch(
            make_entry(32'h00002000, 5'd1, OPC_ARI_ITYPE),
            make_entry(32'h00002004, 5'd2, OPC_ARI_ITYPE),
            2'b11
        );
        allocate_and_dispatch(
            make_entry(32'h00002008, 5'd3, OPC_ARI_ITYPE),
            make_entry(32'h0000200C, 5'd4, OPC_ARI_ITYPE),
            2'b11
        );
        
        // Writeback out of order: 3, 2, 1, 0
        writeback_single(3'd3, 32'h00000003);
        check("No commit (head not ready)", !commit_ports[0].we,
              $sformatf("Expected: we=0, Got: we=%0d", commit_ports[0].we));
        
        writeback_single(3'd2, 32'h00000002);
        writeback_single(3'd1, 32'h00000001);
        writeback_single(3'd0, 32'h00000000);
        
        check("Head entries commit", commit_ports[0].we && commit_ports[1].we,
              $sformatf("Expected: we[0]=1 & we[1]=1, Got: we[0]=%0d & we[1]=%0d",
                       commit_ports[0].we, commit_ports[1].we));
        
        @(posedge clk);
        #1;
        check("Remaining entries commit", commit_ports[0].we && commit_ports[1].we,
              $sformatf("Expected: we[0]=1 & we[1]=1, Got: we[0]=%0d & we[1]=%0d",
                       commit_ports[0].we, commit_ports[1].we));
        $display("");

        //---------------------------------------------------------------------
        // TEST 4: Branch Misprediction
        //---------------------------------------------------------------------
        $display("[TEST 4] Branch Misprediction");
        reset_dut();
        
        allocate_and_dispatch(
            make_entry(32'h00003000, 5'd0, OPC_BRANCH, 1'b0),
            make_entry(32'h00003004, 5'd1, OPC_ARI_ITYPE),
            2'b11
        );
        
        // Branch taken (mispredicted) - LSB=1 indicates mispredict
        writeback_single(3'd0, 32'hDEADBEE1);
        
        check("Flush asserted", flush,
              $sformatf("Expected: 1, Got: %0d", flush));
        check("Redirect PC correct", rob_pc == 32'hDEADBEE0,
              $sformatf("Expected: 0xDEADBEE0, Got: 0x%h", rob_pc));
        check("Branch doesn't commit", !commit_ports[0].we,
              $sformatf("Expected: we=0, Got: we=%0d", commit_ports[0].we));
        
        @(posedge clk);
        #1;
        check("ROB flushed", head == 0 && tail == 0,
              $sformatf("Expected: head=0 & tail=0, Got: head=%0d & tail=%0d", head, tail));
        $display("");

        //---------------------------------------------------------------------
        // TEST 5: JAL Instruction
        //---------------------------------------------------------------------
        $display("[TEST 5] JAL Instruction");
        reset_dut();
        
        allocate_and_dispatch(
            make_entry(32'h00004000, 5'd1, OPC_JAL),
            make_entry(32'h00004004, 5'd2, OPC_ARI_ITYPE),
            2'b11
        );
        
        writeback_single(3'd0, 32'h00010000);
        
        check("JAL flushes", flush,
              $sformatf("Expected: 1, Got: %0d", flush));
        check("JAL commits with return address", 
              commit_ports[0].we && commit_ports[0].data == 32'h00004004,
              $sformatf("Expected: we=1 & data=0x00004004, Got: we=%0d & data=0x%h",
                       commit_ports[0].we, commit_ports[0].data));
        check("Following inst doesn't commit", !commit_ports[1].we,
              $sformatf("Expected: we=0, Got: we=%0d", commit_ports[1].we));
        $display("");

        //---------------------------------------------------------------------
        // TEST 6: Store Instructions
        //---------------------------------------------------------------------
        $display("[TEST 6] Store Instructions");
        reset_dut();
        
        allocate_and_dispatch(
            make_entry(32'h00005000, 5'd0, OPC_STORE, 1'b0),
            make_entry(32'h00005004, 5'd1, OPC_STORE, 1'b0),
            2'b11
        );
                
        check("Stores immediately ready", 
              dut.rob_mem[0].is_ready && dut.rob_mem[1].is_ready,
              $sformatf("Expected: ready[0]=1 & ready[1]=1, Got: ready[0]=%0d & ready[1]=%0d",
                       dut.rob_mem[0].is_ready, dut.rob_mem[1].is_ready));
        check("Stores signal to LSQ", store_vals[0] && store_vals[1],
              $sformatf("Expected: vals=2'b11, Got: vals=2'b%b", store_vals));
        check("Stores don't write PRF", !commit_ports[0].we && !commit_ports[1].we,
              $sformatf("Expected: we[0]=0 & we[1]=0, Got: we[0]=%0d & we[1]=%0d",
                       commit_ports[0].we, commit_ports[1].we));
        $display("");

        //---------------------------------------------------------------------
        // TEST 7: ROB Full (N=8)
        //---------------------------------------------------------------------
        $display("[TEST 7] ROB Full Condition");
        reset_dut();
        
        $display("  Filling ROB (%0d entries)...", TEST_ROB_SIZE);
        
        // Fill ROB: 4 pairs = 8 entries
        for (int i = 0; i < TEST_ROB_SIZE/2; i++) begin
            allocate_and_dispatch(
                make_entry(32'h00006000 + i*8, i*2, OPC_ARI_ITYPE),
                make_entry(32'h00006004 + i*8, i*2+1, OPC_ARI_ITYPE),
                2'b11
            );
        end
        
        check("ROB full", dut.avail_slots == 0,
              $sformatf("Expected: 0, Got: %0d", dut.avail_slots));
        check("Tail wrapped", tail == 0,
              $sformatf("Expected: 0, Got: %0d", tail));
        
        // Try to allocate when full
        alloc_req = 2'b11;
        #1;
        check("Allocation denied when full", alloc_gnt == 2'b00,
              $sformatf("Expected: 2'b00, Got: 2'b%b", alloc_gnt));
        alloc_req = '0;
        
        // Free up space
        writeback_dual(3'd0, 32'h11111111, 3'd1, 32'h22222222);
        
        @(posedge clk);
        #1;
        check("Space available after commit", dut.avail_slots == 2,
              $sformatf("Expected: 2, Got: %0d", dut.avail_slots));
        
        // Try again
        alloc_req = 2'b11;
        #1;
        check("Allocation succeeds", alloc_gnt == 2'b11,
              $sformatf("Expected: 2'b11, Got: 2'b%b", alloc_gnt));
        alloc_req = '0;
        $display("");

        //---------------------------------------------------------------------
        // TEST 8: Pointer Wraparound
        //---------------------------------------------------------------------
        $display("[TEST 8] Pointer Wraparound");
        reset_dut();
        
        $display("  Testing wraparound at boundary...");
        
        for (int cycle = 0; cycle < 2; cycle++) begin
            automatic logic [TEST_TAG_WIDTH-1:0] base_tag = tail;
            
            // Fill
            for (int i = 0; i < TEST_ROB_SIZE/2; i++) begin
                allocate_and_dispatch(
                    make_entry(32'h00007000 + i*8, (i*2) % 32, OPC_ARI_ITYPE),
                    make_entry(32'h00007004 + i*8, (i*2+1) % 32, OPC_ARI_ITYPE),
                    2'b11
                );
            end
            
            // Drain using calculated tags
            for (int i = 0; i < TEST_ROB_SIZE/2; i++) begin
                automatic logic [TEST_TAG_WIDTH-1:0] tag0 = (base_tag + i*2) % TEST_ROB_SIZE;
                automatic logic [TEST_TAG_WIDTH-1:0] tag1 = (base_tag + i*2 + 1) % TEST_ROB_SIZE;
                writeback_dual(tag0, 32'h00000000 + i, tag1, 32'h10000000 + i);
                @(posedge clk);
                #1;
            end
            
            wait_cycles(1);
            check($sformatf("Cycle %0d: ROB empty", cycle), 
                  head == tail && dut.avail_slots == TEST_ROB_SIZE,
                  $sformatf("Expected: head==tail & avail=%0d, Got: head=%0d tail=%0d avail=%0d",
                           TEST_ROB_SIZE, head, tail, dut.avail_slots));
        end
        $display("");

        //---------------------------------------------------------------------
        // TEST 9: CDB Same-Cycle Bypass
        //---------------------------------------------------------------------
        $display("[TEST 9] CDB Same-Cycle Bypass");
        reset_dut();
        
        // Dispatch and writeback in same cycle
        alloc_req = 2'b01;
        rob_we = 2'b01;
        rob_entries[0] = make_entry(32'h00008000, 5'd7, OPC_ARI_ITYPE);
        cdb_ports[0] = '{is_valid: 1'b1, dest_tag: 3'd0, result: 32'h12345678, exception: 1'b0};
        
        @(posedge clk);
        #1;
        
        check("Bypass worked", dut.rob_mem[0].is_ready,
              $sformatf("Expected: ready=1, Got: ready=%0d", dut.rob_mem[0].is_ready));
        check("Correct data", dut.rob_mem[0].result == 32'h12345678,
              $sformatf("Expected: 0x12345678, Got: 0x%h", dut.rob_mem[0].result));
        
        alloc_req = '0;
        rob_we = '0;
        rob_entries = '{default: '0};
        cdb_ports = '{default: '0};
        $display("");

        //---------------------------------------------------------------------
        // TEST 10: Single Instruction Allocation (Compacted)
        //---------------------------------------------------------------------
        $display("[TEST 10] Single Instruction Allocation");
        reset_dut();
        
        // Allocate single instruction via slot 0 (compacted input)
        allocate_and_dispatch(
            make_entry(32'h00009000, 5'd10, OPC_ARI_ITYPE),
            '{default: '0},
            2'b01
        );
        
        check("Tail advanced by 1", tail == 1,
              $sformatf("Expected: 1, Got: %0d", tail));
        check("Entry 0 valid", dut.rob_mem[0].is_valid,
              $sformatf("Expected: 1, Got: %0d", dut.rob_mem[0].is_valid));
        
        // Allocate another single instruction via slot 0 (compacted - always use slot 0 first)
        allocate_and_dispatch(
            make_entry(32'h00009004, 5'd11, OPC_ARI_ITYPE),
            '{default: '0},
            2'b01
        );
        
        check("Tail advanced by 1 more", tail == 2,
              $sformatf("Expected: 2, Got: %0d", tail));
        check("Entry 1 valid", dut.rob_mem[1].is_valid,
              $sformatf("Expected: 1, Got: %0d", dut.rob_mem[1].is_valid));
        $display("");

        //---------------------------------------------------------------------
        // End of Tests
        //---------------------------------------------------------------------
        wait_cycles(5);
        
        $display("========================================");
        $display("  All Tests Complete!");
        $display("========================================");
        $display("  Checks Passed:  %0d / %0d", tests_passed, total_checks);
        $display("  Checks Failed:  %0d / %0d", tests_failed, total_checks);
        $display("========================================");
        
        if (tests_failed == 0) begin
            $display("  ✓ ALL TESTS PASSED!");
        end else begin
            $display("  ✗ SOME TESTS FAILED!");
        end
        
        $finish;
    end

    //----------------------------------------------------------
    // Timeout Watchdog
    //----------------------------------------------------------
    
    initial begin
        #100000;
        $display("\n[ERROR] Testbench timeout!");
        $finish;
    end

endmodule
