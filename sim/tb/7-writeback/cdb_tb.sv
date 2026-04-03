`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module cdb_tb;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;

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
    logic [TAG_WIDTH-1:0]       rob_head;
    writeback_packet_t          fu_results  [NUM_FU-1:0];
    logic                       fu_cdb_gnts  [NUM_FU-1:0];
    writeback_packet_t          cdb_ports   [PIPE_WIDTH-1:0];

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    cdb dut (
        .rob_head(rob_head),
        .fu_results(fu_results),
        .fu_cdb_gnts(fu_cdb_gnts),
        .cdb_ports(cdb_ports)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------

    // Reset/init all inputs
    task automatic init_signals();
        rst = 1'b1;
        rob_head = '0;
        for (int i = 0; i < NUM_FU; i++) begin
            fu_results[i] = '{default:'0};
        end
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
    endtask

    // Helper to create a writeback packet
    function automatic writeback_packet_t make_wb_packet(
        input logic [TAG_WIDTH-1:0]       tag,
        input logic [CPU_DATA_BITS-1:0]   result,
        input logic                       valid = 1'b1
    );
        writeback_packet_t pkt;
        pkt.dest_tag  = tag;
        pkt.result    = result;
        pkt.is_valid  = valid;
        pkt.exception = 1'b0;
        return pkt;
    endfunction

    // Run a single test
    task automatic run_test(
        input string test_name,
        input logic [TAG_WIDTH-1:0] head,
        input writeback_packet_t inputs [NUM_FU-1:0],
        input logic expected_grants [NUM_FU-1:0],
        input logic expected_cdb_valid [PIPE_WIDTH-1:0],
        input logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0],
        input logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0]
    );
        logic test_passed;
        string error_msg;
        string info_msg;
        
        // Print test info
        $display("%-30s: head=0x%02h, valid=[%0d,%0d,%0d,%0d], tags=[0x%02h,0x%02h,0x%02h,0x%02h]",
                 test_name, head,
                 inputs[0].is_valid, inputs[1].is_valid, inputs[2].is_valid, inputs[3].is_valid,
                 inputs[0].dest_tag, inputs[1].dest_tag, inputs[2].dest_tag, inputs[3].dest_tag);
        
        // Drive DUT
        @(posedge clk);
        rob_head = head;
        fu_results = inputs;
        
        // Check outputs
        @(negedge clk);
        
        test_passed = 1'b1;
        error_msg = "";
        
        // Build info message with actual outputs
        info_msg = $sformatf("gnt=[%0d,%0d,%0d,%0d] CDB0={v=%0d,tag=0x%02h,res=0x%08h} CDB1={v=%0d,tag=0x%02h,res=0x%08h}",
                             fu_cdb_gnts[0], fu_cdb_gnts[1], fu_cdb_gnts[2], fu_cdb_gnts[3],
                             cdb_ports[0].is_valid, cdb_ports[0].dest_tag, cdb_ports[0].result,
                             cdb_ports[1].is_valid, cdb_ports[1].dest_tag, cdb_ports[1].result);
        
        // Check grants
        for (int i = 0; i < NUM_FU; i++) begin
            if (fu_cdb_gnts[i] != expected_grants[i]) begin
                test_passed = 1'b0;
                error_msg = $sformatf("%s gnt[%0d]=%0b(exp %0b)", 
                                      error_msg, i, fu_cdb_gnts[i], expected_grants[i]);
            end
        end
        
        // Check CDB ports
        for (int port = 0; port < PIPE_WIDTH; port++) begin
            if (cdb_ports[port].is_valid != expected_cdb_valid[port]) begin
                test_passed = 1'b0;
                error_msg = $sformatf("%s CDB[%0d].valid=%0b(exp %0b)",
                                      error_msg, port, cdb_ports[port].is_valid, expected_cdb_valid[port]);
            end
            
            if (expected_cdb_valid[port]) begin
                if (cdb_ports[port].dest_tag != expected_cdb_tags[port]) begin
                    test_passed = 1'b0;
                    error_msg = $sformatf("%s CDB[%0d].tag=0x%02h(exp 0x%02h)",
                                          error_msg, port, cdb_ports[port].dest_tag, expected_cdb_tags[port]);
                end
                if (cdb_ports[port].result != expected_cdb_results[port]) begin
                    test_passed = 1'b0;
                    error_msg = $sformatf("%s CDB[%0d].result=0x%08h(exp 0x%08h)",
                                          error_msg, port, cdb_ports[port].result, expected_cdb_results[port]);
                end
            end
        end
        
        // Print result
        if (test_passed) begin
            $display("                                [PASS] %s", info_msg);
            tests_passed++;
        end else begin
            $display("                                [FAIL] %s", error_msg);
            tests_failed++;
        end
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("cdb_tb.vcd");
        $dumpvars(0, cdb_tb);

        $display("========================================");
        $display("  CDB Testbench Started");
        $display("========================================\n");

        init_signals();

        //---------------------------------------------------------
        // TEST 1: No valid requests
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            inputs[0] = make_wb_packet(5'h05, 32'h1111_1111, 1'b0);
            inputs[1] = make_wb_packet(5'h0A, 32'h2222_2222, 1'b0);
            inputs[2] = make_wb_packet(5'h0F, 32'h3333_3333, 1'b0);
            inputs[3] = make_wb_packet(5'h03, 32'h4444_4444, 1'b0);
            
            expected_grants[0] = 0;
            expected_grants[1] = 0;
            expected_grants[2] = 0;
            expected_grants[3] = 0;
            
            expected_cdb_valid[0] = 0;
            expected_cdb_valid[1] = 0;
            
            expected_cdb_tags[0] = 5'h00;
            expected_cdb_tags[1] = 5'h00;
            
            expected_cdb_results[0] = 32'h0;
            expected_cdb_results[1] = 32'h0;
            
            run_test("No valid requests", 5'h00, inputs, expected_grants, 
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // TEST 2: Single valid request (compaction to CDB_0)
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            inputs[0] = make_wb_packet(5'h05, 32'h1111_1111, 1'b0);
            inputs[1] = make_wb_packet(5'h0A, 32'h2222_2222, 1'b1);  // Only valid
            inputs[2] = make_wb_packet(5'h0F, 32'h3333_3333, 1'b0);
            inputs[3] = make_wb_packet(5'h03, 32'h4444_4444, 1'b0);
            
            expected_grants[0] = 0;
            expected_grants[1] = 1;  // Source 1 granted
            expected_grants[2] = 0;
            expected_grants[3] = 0;
            
            expected_cdb_valid[0] = 1;  // CDB_0 valid
            expected_cdb_valid[1] = 0;  // CDB_1 invalid
            
            expected_cdb_tags[0] = 5'h0A;  // Tag from source 1
            expected_cdb_tags[1] = 5'h00;
            
            expected_cdb_results[0] = 32'h2222_2222;  // Result from source 1
            expected_cdb_results[1] = 32'h0;
            
            run_test("Single valid request", 5'h00, inputs, expected_grants,
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // TEST 3: Two valid requests (simple age ordering)
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            // head=0x00, tag 0x03 has age 3, tag 0x08 has age 8
            // 0x03 is older (smaller age)
            inputs[0] = make_wb_packet(5'h03, 32'h1111_1111, 1'b1);  // Age 3 (older)
            inputs[1] = make_wb_packet(5'h08, 32'h2222_2222, 1'b1);  // Age 8 (newer)
            inputs[2] = make_wb_packet(5'h0F, 32'h3333_3333, 1'b0);
            inputs[3] = make_wb_packet(5'h12, 32'h4444_4444, 1'b0);
            
            expected_grants[0] = 1;  // Source 0 granted (older)
            expected_grants[1] = 1;  // Source 1 granted
            expected_grants[2] = 0;
            expected_grants[3] = 0;
            
            expected_cdb_valid[0] = 1;
            expected_cdb_valid[1] = 1;
            
            expected_cdb_tags[0] = 5'h03;  // Older tag first
            expected_cdb_tags[1] = 5'h08;
            
            expected_cdb_results[0] = 32'h1111_1111;  // Source 0 result
            expected_cdb_results[1] = 32'h2222_2222;  // Source 1 result
            
            run_test("Two valid - age ordering", 5'h00, inputs, expected_grants,
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // TEST 4: All sources valid (pick 2 oldest)
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            // head=0x00, ages: 0x04→4, 0x01→1(oldest), 0x07→7, 0x02→2(2nd oldest)
            inputs[0] = make_wb_packet(5'h04, 32'h1111_1111, 1'b1);  // Age 4
            inputs[1] = make_wb_packet(5'h01, 32'h2222_2222, 1'b1);  // Age 1 (oldest)
            inputs[2] = make_wb_packet(5'h07, 32'h3333_3333, 1'b1);  // Age 7
            inputs[3] = make_wb_packet(5'h02, 32'h4444_4444, 1'b1);  // Age 2 (2nd oldest)
            
            expected_grants[0] = 0;
            expected_grants[1] = 1;  // Source 1 (age 1, oldest)
            expected_grants[2] = 0;
            expected_grants[3] = 1;  // Source 3 (age 2, 2nd oldest)
            
            expected_cdb_valid[0] = 1;
            expected_cdb_valid[1] = 1;
            
            expected_cdb_tags[0] = 5'h01;  // Source 1 tag
            expected_cdb_tags[1] = 5'h02;  // Source 3 tag
            
            expected_cdb_results[0] = 32'h2222_2222;  // Source 1 result
            expected_cdb_results[1] = 32'h4444_4444;  // Source 3 result
            
            run_test("All valid - pick 2 oldest", 5'h00, inputs, expected_grants,
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // TEST 5: Wrap-around case (critical!)
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            // head=0x1E (30), tags: 0x1E→age 0, 0x1F→age 1, 0x00→age 2, 0x01→age 3
            inputs[0] = make_wb_packet(5'h1E, 32'h1111_1111, 1'b1);  // Age 0 (oldest)
            inputs[1] = make_wb_packet(5'h1F, 32'h2222_2222, 1'b1);  // Age 1 (2nd oldest)
            inputs[2] = make_wb_packet(5'h00, 32'h3333_3333, 1'b1);  // Age 2
            inputs[3] = make_wb_packet(5'h01, 32'h4444_4444, 1'b1);  // Age 3
            
            expected_grants[0] = 1;  // Source 0 (age 0, oldest)
            expected_grants[1] = 1;  // Source 1 (age 1, 2nd oldest)
            expected_grants[2] = 0;
            expected_grants[3] = 0;
            
            expected_cdb_valid[0] = 1;
            expected_cdb_valid[1] = 1;
            
            expected_cdb_tags[0] = 5'h1E;  // Source 0 tag
            expected_cdb_tags[1] = 5'h1F;  // Source 1 tag
            
            expected_cdb_results[0] = 32'h1111_1111;  // Source 0 result
            expected_cdb_results[1] = 32'h2222_2222;  // Source 1 result
            
            run_test("Wrap-around age comparison", 5'h1E, inputs, expected_grants,
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // TEST 6: Wrap-around with mixed valid
        //---------------------------------------------------------
        begin
            writeback_packet_t inputs [NUM_FU-1:0];
            logic expected_grants [NUM_FU-1:0];
            logic expected_cdb_valid [PIPE_WIDTH-1:0];
            logic [TAG_WIDTH-1:0] expected_cdb_tags [PIPE_WIDTH-1:0];
            logic [CPU_DATA_BITS-1:0] expected_cdb_results [PIPE_WIDTH-1:0];
            
            // head=0x1D (29), only sources 1 and 2 valid
            // tag 0x1E→age 1, tag 0x00→age 3
            inputs[0] = make_wb_packet(5'h1C, 32'h1111_1111, 1'b0);  // Invalid
            inputs[1] = make_wb_packet(5'h1E, 32'h2222_2222, 1'b1);  // Age 1 (older)
            inputs[2] = make_wb_packet(5'h00, 32'h3333_3333, 1'b1);  // Age 3 (newer)
            inputs[3] = make_wb_packet(5'h05, 32'h4444_4444, 1'b0);  // Invalid
            
            expected_grants[0] = 0;
            expected_grants[1] = 1;  // Source 1 (age 1, older)
            expected_grants[2] = 1;  // Source 2 (age 3, newer but still granted)
            expected_grants[3] = 0;
            
            expected_cdb_valid[0] = 1;
            expected_cdb_valid[1] = 1;
            
            expected_cdb_tags[0] = 5'h1E;  // Source 1 tag (older)
            expected_cdb_tags[1] = 5'h00;  // Source 2 tag
            
            expected_cdb_results[0] = 32'h2222_2222;  // Source 1 result
            expected_cdb_results[1] = 32'h3333_3333;  // Source 2 result
            
            run_test("Wrap-around mixed valid", 5'h1D, inputs, expected_grants,
                     expected_cdb_valid, expected_cdb_tags, expected_cdb_results);
        end

        //---------------------------------------------------------
        // End of Tests / Summary
        //---------------------------------------------------------
        @(posedge clk);
        $display("");
        $display("========================================");
        $display("  All Tests Complete!");
        $display("========================================");
        $display("  Tests Passed:  %0d", tests_passed);
        $display("  Tests Failed:  %0d", tests_failed);
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
        $display("\n[ERROR] CDB testbench timeout!");
        $finish;
    end

endmodule
