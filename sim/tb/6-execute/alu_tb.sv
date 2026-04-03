`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module alu_tb;

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
    // DUT I/O
    //-------------------------------------------------------------
    instruction_t       alu_packet_i;
    writeback_packet_t  alu_result_o;
    logic               alu_rdy_o;
    logic               alu_cdb_gnt_i;
    logic               flush;

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    alu dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .alu_rdy(alu_rdy_o),
        .alu_packet(alu_packet_i),
        .alu_result(alu_result_o),
        .alu_cdb_gnt(alu_cdb_gnt_i)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------

    task automatic check_assertion(
        input string test_name,
        input logic condition,
        input string fail_msg
    );
        assertions_checked++;
        if (condition) begin
            $display("%0t  [PASS] %s", $time, test_name);
            tests_passed++;
        end else begin
            $display("%0t  [FAIL] %s: %s", $time,  test_name, fail_msg);
            tests_failed++;
        end
    endtask

    // Reset/init all inputs
    task automatic init_signals();
        rst = 1'b1;
        flush = 1'b0;
        alu_cdb_gnt_i = 1'b0;
        alu_packet_i  = '{default:'0};
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;
    endtask

    // Build a simple ALU R-type packet
    function automatic instruction_t make_alu_rr(
        input logic [CPU_DATA_BITS-1:0] a,
        input logic [CPU_DATA_BITS-1:0] b,
        input logic [2:0]               funct3,
        input logic [6:0]               funct7 = 7'b0
    );
        instruction_t t = '{default:'0};
        t.is_valid     = 1'b1;
        t.opcode       = OPC_ARI_RTYPE;
        t.funct7       = funct7;
        t.uop_0        = funct3;
        t.src_0_a.data = a;
        t.src_0_b.data = b;
        return t;
    endfunction

    // Build a branch packet
    function automatic instruction_t make_branch(
        input logic [CPU_DATA_BITS-1:0] rs1,
        input logic [CPU_DATA_BITS-1:0] rs2,
        input logic [2:0]               br_fn
    );
        instruction_t t = '{default:'0};
        t.is_valid     = 1'b1;
        t.opcode       = OPC_BRANCH;
        t.uop_1        = br_fn;
        t.src_1_a.data = rs1;
        t.src_1_b.data = rs2;
        return t;
    endfunction

    // Drive one instruction through the 2-stage ALU pipeline
    task automatic drive_and_check(
        input string                       name,
        input instruction_t                pkt,
        input logic [CPU_DATA_BITS-1:0]    expected_result
    );
        // Present packet - hold it stable through the clock edge
        alu_packet_i = pkt;
        alu_cdb_gnt_i = 1'b0;
        
        @(posedge clk);  // Cycle 1: Input register captures
        #1;  // Wait for capture to complete
        
        // Now safe to clear input
        alu_packet_i = '{default:'0};
        
        @(posedge clk);  // Cycle 2: Output register updates with result
        #1;  // Wait for output to settle
        
        // Check result BEFORE granting CDB
        check_assertion($sformatf("%s: result matches", name),
                        alu_result_o.result === expected_result,
                        $sformatf("Got 0x%08h, expected 0x%08h",
                                  alu_result_o.result, expected_result));
        check_assertion($sformatf("%s: valid bit", name),
                        alu_result_o.is_valid === 1'b1,
                        $sformatf("is_valid=%0b (expected 1)", alu_result_o.is_valid));
        
        // Grant CDB to consume result
        alu_cdb_gnt_i = 1'b1;
        @(posedge clk);  // Cycle 3: Result consumed
        #1;
        
        // Clear grant for next instruction
        alu_cdb_gnt_i = 1'b0;
        @(posedge clk);
        #1;
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("alu_tb.vcd");
        $dumpvars(0, alu_tb);

        $display("========================================");
        $display("  ALU Testbench Started");
        $display("========================================\n");

        init_signals();

        //---------------------------------------------------------
        // TEST 1: Basic arithmetic/logical ops
        //---------------------------------------------------------
        $display("[TEST 1] Basic ALU Ops");

        drive_and_check("ADD 5+7",
            make_alu_rr(32'h0000_0005, 32'h0000_0007, FNC_ADD_SUB, 7'b0),
            32'h0000_000C);

        drive_and_check("SUB 10-3",
            make_alu_rr(32'h0000_000A, 32'h0000_0003, FNC_ADD_SUB, FNC7_SUB_SRA),
            32'h0000_0007);

        drive_and_check("AND",
            make_alu_rr(32'hF0F0_1234, 32'h0FF0_00FF, FNC_AND),
            32'h00F0_0034);

        drive_and_check("OR",
            make_alu_rr(32'h1234_0000, 32'h0000_FF00, FNC_OR),
            32'h1234_FF00);

        drive_and_check("XOR",
            make_alu_rr(32'h00FF_00FF, 32'h0F0F_F0F0, FNC_XOR),
            32'h0FF0_F00F);                                     

        drive_and_check("SLL",
            make_alu_rr(32'h0000_0001, 32'd8, FNC_SLL),
            32'h0000_0100);

        drive_and_check("SRL",
            make_alu_rr(32'h8000_0000, 32'd1, FNC_SRL_SRA, 7'b0),
            32'h4000_0000);

        drive_and_check("SRA",
            make_alu_rr(32'h8000_0000, 32'd1, FNC_SRL_SRA, FNC7_SUB_SRA),
            32'hC000_0000);

        drive_and_check("SLT signed (−1 < 1) = 1",
            make_alu_rr(32'hFFFF_FFFF, 32'h0000_0001, FNC_SLT),
            32'h0000_0001);

        drive_and_check("SLTU unsigned (0xFFFF_FFFF < 1) = 0",
            make_alu_rr(32'hFFFF_FFFF, 32'h0000_0001, FNC_SLTU),
            32'h0000_0000);

        $display("");

        //---------------------------------------------------------
        // TEST 2: Branch compares
        //---------------------------------------------------------
        $display("[TEST 2] Branch Compares (result LSB is compare)");

        drive_and_check("BEQ true",
            make_branch(32'h1234_5678, 32'h1234_5678, FNC_BEQ),
            {31'b0, 1'b1});

        drive_and_check("BNE false",
            make_branch(32'hAAAA_0001, 32'hAAAA_0001, FNC_BNE),
            {31'b0, 1'b0});

        drive_and_check("BLT true",
            make_branch(32'hFFFF_FFFF, 32'h0000_0001, FNC_BLT),
            {31'b0, 1'b1});

        drive_and_check("BGEU true",
            make_branch(32'h0000_0001, 32'h0000_0000, FNC_BGEU),
            {31'b0, 1'b1});

        $display("");

        //---------------------------------------------------------
        // TEST 3: Flush functionality
        //---------------------------------------------------------
        $display("[TEST 3] Flush");
        
        // Load instruction into pipeline
        alu_packet_i = make_alu_rr(32'h1234_5678, 32'h8765_4321, FNC_ADD_SUB, 7'b0);
        alu_cdb_gnt_i = 1'b0;
        @(posedge clk);
        #1;
        
        alu_packet_i = '{default:'0};
        @(posedge clk);
        #1;
        
        // Verify output is valid before flush
        check_assertion("Pre-flush: output valid",
                        alu_result_o.is_valid === 1'b1,
                        $sformatf("is_valid=%0b (expected 1)", alu_result_o.is_valid));
        
        // Assert flush
        flush = 1'b1;
        @(posedge clk);
        #1;
        
        flush = 1'b0;
        @(posedge clk);
        #1;
        
        // Check that flush cleared pipeline
        check_assertion("Flush clears output",
                        alu_result_o.is_valid === 1'b0,
                        $sformatf("is_valid=%0b (expected 0 after flush)", alu_result_o.is_valid));
        
        check_assertion("ALU ready after flush",
                        alu_rdy_o === 1'b1,
                        $sformatf("alu_rdy=%0b (expected 1 after flush)", alu_rdy_o));
        
        $display("");

        //---------------------------------------------------------
        // End of Tests / Summary
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
        $display("\n[ERROR] ALU testbench timeout!");
        $finish;
    end

endmodule
