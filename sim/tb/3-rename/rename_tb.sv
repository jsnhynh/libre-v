`timescale 1ns/1ps

module rename_tb;
    import riscv_isa_pkg::*;
    import uarch_pkg::*;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;

    //-------------------------------------------------------------
    // Clock and Reset Generation
    //-------------------------------------------------------------
    logic clk;
    logic rst;
    logic flush;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------
    // Stimulus Signals (inputs to DUT)
    //-------------------------------------------------------------
    logic                    dispatch_rdy_i;
    instruction_t            decoded_insts_i    [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   rob_alloc_gnt_i;
    logic [TAG_WIDTH-1:0]    rob_alloc_tags_i   [PIPE_WIDTH-1:0];
    prf_commit_write_port_t  commit_write_ports_i [PIPE_WIDTH-1:0];
    rob_entry_t              rob_entries_bypass_i [ROB_ENTRIES-1:0];

    //-------------------------------------------------------------
    // Monitored Signals (outputs from DUT)
    //-------------------------------------------------------------
    logic                    rename_rdy_o;
    instruction_t            renamed_insts_o    [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   rob_alloc_req_o;

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    rename dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        
        // From Decode
        .rename_rdy(rename_rdy_o),
        .decoded_insts(decoded_insts_i),
        
        // To Dispatch
        .dispatch_rdy(dispatch_rdy_i),
        .renamed_insts(renamed_insts_o),
        
        // From ROB
        .rob_alloc_req(rob_alloc_req_o),
        .rob_alloc_gnt(rob_alloc_gnt_i),
        .rob_alloc_tags(rob_alloc_tags_i),
        .commit_write_ports(commit_write_ports_i),
        .rob_entries_bypass(rob_entries_bypass_i)
    );

    //-------------------------------------------------------------
    // Helper Tasks
    //-------------------------------------------------------------
    
    // Task: Check assertion with detailed reporting
    task automatic check_assertion(
        input string test_name,
        input logic condition,
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
    
    // Task: Initialize all stimulus signals
    task automatic init_signals();
        rst = 1;
        flush = 0;
        dispatch_rdy_i = 1;
        rob_alloc_gnt_i = '0;
        
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            decoded_insts_i[i] = '{default:'0};
            rob_alloc_tags_i[i] = '0;
            commit_write_ports_i[i] = '{default:'0};
        end
        for (int i = 0; i < ROB_ENTRIES; i++) begin
            rob_entries_bypass_i[i] = '{default:'0};
        end
        
        repeat(2) @(posedge clk);
        rst = 0;
        @(posedge clk);
    endtask

    // Task: Create a simple decoded instruction
    task automatic create_instruction(
        output instruction_t inst,
        input logic [CPU_ADDR_BITS-1:0] pc,
        input logic [4:0] rd, rs1, rs2,
        input logic has_rd,
        input logic [6:0] opcode
    );
        inst = '{default:'0};
        inst.is_valid = 1'b1;
        inst.pc = pc;
        inst.rd = rd;
        inst.has_rd = has_rd;
        inst.opcode = opcode;
        
        // Set source register addresses in tag field
        inst.src_1_a.tag = rs1;
        inst.src_1_a.is_renamed = 1'b0;
        inst.src_1_a.data = '0;
        
        inst.src_1_b.tag = rs2;
        inst.src_1_b.is_renamed = 1'b0;
        inst.src_1_b.data = '0;
        
        // For src_0_a and src_0_b, set different tags to indicate PC/IMM
        inst.src_0_a.tag = 5'h1F; // Different from rs1
        inst.src_0_a.data = pc;
        
        inst.src_0_b.tag = 5'h1E; // Different from rs2
        inst.src_0_b.data = 32'h00000000; // IMM placeholder
    endtask

    // Task: Apply commit write
    task automatic commit_write(
        input int port,
        input logic [4:0] addr,
        input logic [CPU_DATA_BITS-1:0] data,
        input logic [TAG_WIDTH-1:0] tag
    );
        commit_write_ports_i[port].we = 1'b1;
        commit_write_ports_i[port].addr = addr;
        commit_write_ports_i[port].data = data;
        commit_write_ports_i[port].tag = tag;
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    instruction_t prev_renamed_0;
    instruction_t prev_renamed_1; 
    initial begin
        $dumpfile("rename_tb.vcd");
        $dumpvars(0, rename_tb);
        
        $display("========================================");
        $display("  Rename Stage Testbench Started");
        $display("========================================\n");
        
        init_signals();
        
        //-------------------------------------------------------------
        // TEST 1: Single Instruction Rename
        //-------------------------------------------------------------
        $display("[TEST 1] Single Instruction Rename");
        $display("  Sending: ADD x3, x1, x2");
        
        create_instruction(decoded_insts_i[0], 32'h11111111, 5'd3, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        decoded_insts_i[1] = '{default:'0};
        
        rob_alloc_gnt_i = 2'b01;  // Grant for inst[0]
        rob_alloc_tags_i[0] = 5'd10;

        @(negedge clk);
        #1;
                
        // Check ROB allocation request
        check_assertion("ROB alloc request for inst[0]", 
                       rob_alloc_req_o[0] == 1'b1,
                       $sformatf("Expected req[0]=1, got %b", rob_alloc_req_o[0]));
        
        check_assertion("No ROB alloc request for inst[1]", 
                       rob_alloc_req_o[1] == 1'b0,
                       $sformatf("Expected req[1]=0, got %b", rob_alloc_req_o[1]));
        
        check_assertion("Rename ready asserted", 
                       rename_rdy_o == 1'b1,
                       $sformatf("Expected rename_rdy=1, got %b", rename_rdy_o));
                
        // Check renamed instruction output
        check_assertion("Renamed inst[0] is valid", 
                       renamed_insts_o[0].is_valid == 1'b1,
                       $sformatf("Expected valid=1, got %b", renamed_insts_o[0].is_valid));
        
        check_assertion("Renamed inst[0] dest_tag correct", 
                       renamed_insts_o[0].dest_tag == 5'd10,
                       $sformatf("Expected tag=10, got %d", renamed_insts_o[0].dest_tag));
        
        check_assertion("Renamed inst[0] rd preserved", 
                       renamed_insts_o[0].rd == 5'd3,
                       $sformatf("Expected rd=3, got %d", renamed_insts_o[0].rd));
        
        check_assertion("Renamed inst[0] PC preserved", 
                       renamed_insts_o[0].pc == 32'h11111111,
                       $sformatf("Expected PC=0x1000, got 0x%h", renamed_insts_o[0].pc));
        
        check_assertion("Renamed inst[1] is invalid", 
                       renamed_insts_o[1].is_valid == 1'b0,
                       $sformatf("Expected valid=0, got %b", renamed_insts_o[1].is_valid));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 2: Two Instructions Rename (Both Granted)
        //-------------------------------------------------------------
        $display("[TEST 2] Two Instructions Rename (Both Granted)");
        $display("  Sending: ADD x5, x1, x2 and SUB x6, x3, x4");
        
        create_instruction(decoded_insts_i[0], 32'h33333333, 5'd5, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        create_instruction(decoded_insts_i[1], 32'h44444444, 5'd6, 5'd3, 5'd4, 1'b1, OPC_ARI_RTYPE);
        
        rob_alloc_gnt_i = 2'b11;  // Grant both
        rob_alloc_tags_i[0] = 5'd11;
        rob_alloc_tags_i[1] = 5'd12;
        
        @(negedge clk);
        #1;
        
        check_assertion("Both ROB alloc requests", 
                       rob_alloc_req_o == 2'b11,
                       $sformatf("Expected req=11, got %b", rob_alloc_req_o));
        
        check_assertion("Rename ready for both", 
                       rename_rdy_o == 1'b1,
                       $sformatf("Expected rename_rdy=1, got %b", rename_rdy_o));
                
        check_assertion("Both instructions valid", 
                       (renamed_insts_o[0].is_valid && renamed_insts_o[1].is_valid),
                       $sformatf("Expected both valid, got [0]=%b [1]=%b", 
                                renamed_insts_o[0].is_valid, renamed_insts_o[1].is_valid));
        
        check_assertion("Inst[0] dest_tag correct", 
                       renamed_insts_o[0].dest_tag == 5'd11,
                       $sformatf("Expected tag=11, got %d", renamed_insts_o[0].dest_tag));
        
        check_assertion("Inst[1] dest_tag correct", 
                       renamed_insts_o[1].dest_tag == 5'd12,
                       $sformatf("Expected tag=12, got %d", renamed_insts_o[1].dest_tag));
        
        check_assertion("Inst[0] rd=5", 
                       renamed_insts_o[0].rd == 5'd5,
                       $sformatf("Expected rd=5, got %d", renamed_insts_o[0].rd));
        
        check_assertion("Inst[1] rd=6", 
                       renamed_insts_o[1].rd == 5'd6,
                       $sformatf("Expected rd=6, got %d", renamed_insts_o[1].rd));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 3: RAW Dependency (Intra-group Forwarding)
        //-------------------------------------------------------------
        $display("[TEST 3] RAW Dependency (inst[1] depends on inst[0])");
        $display("  Sending: ADD x5, x1, x2 and ADD x6, x5, x4");
        $display("  inst[1].rs1 (x5) matches inst[0].rd (x5)");
        
        create_instruction(decoded_insts_i[0], 32'h55555555, 5'd5, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        create_instruction(decoded_insts_i[1], 32'h66666666, 5'd6, 5'd5, 5'd4, 1'b1, OPC_ARI_RTYPE);
        
        rob_alloc_gnt_i = 2'b11;
        rob_alloc_tags_i[0] = 5'd13;
        rob_alloc_tags_i[1] = 5'd14;
        
        @(negedge clk);
        #1;
        
        check_assertion("Inst[1] src_1_a marked as renamed", 
                       renamed_insts_o[1].src_1_a.is_renamed == 1'b1,
                       $sformatf("Expected is_renamed=1, got %b", renamed_insts_o[1].src_1_a.is_renamed));
        
        check_assertion("Inst[1] src_1_a tag forwarded from inst[0]", 
                       renamed_insts_o[1].src_1_a.tag == 5'd13,
                       $sformatf("Expected tag=13 (from inst[0]), got %d", renamed_insts_o[1].src_1_a.tag));
        
        check_assertion("Inst[1] src_1_b not affected", 
                       renamed_insts_o[1].src_1_b.tag != 5'd13,
                       $sformatf("src_1_b should not be forwarded, got tag=%d", renamed_insts_o[1].src_1_b.tag));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 4: Partial Grant (Only inst[0] granted)
        //-------------------------------------------------------------
        $display("[TEST 4] Partial Grant - Should Stall");
        $display("  Sending: Two instructions, but only inst[0] gets grant");
        
        create_instruction(decoded_insts_i[0], 32'h77777777, 5'd7, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        create_instruction(decoded_insts_i[1], 32'h88888888, 5'd8, 5'd3, 5'd4, 1'b1, OPC_ARI_RTYPE);
        
        rob_alloc_gnt_i = 2'b01;  // Only grant inst[0]
        rob_alloc_tags_i[0] = 5'd15;
        
        @(negedge clk);
        #1;
        
        check_assertion("Both ROB requests asserted", 
                       rob_alloc_req_o == 2'b11,
                       $sformatf("Expected req=11, got %b", rob_alloc_req_o));
        
        check_assertion("Rename NOT ready (stalled)", 
                       rename_rdy_o == 1'b0,
                       $sformatf("Expected rename_rdy=0 (stall), got %b", rename_rdy_o));
                
        check_assertion("Renamed outputs invalid during partial-grant stall", 
                       !renamed_insts_o[0].is_valid && !renamed_insts_o[1].is_valid,
                       $sformatf("Expected both invalid, got [0]=%b [1]=%b",
                                renamed_insts_o[0].is_valid, renamed_insts_o[1].is_valid));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 5: Grant both after stall
        //-------------------------------------------------------------
        $display("[TEST 5] Grant Both After Stall");
        rob_alloc_gnt_i = 2'b11;  // Now grant both
        rob_alloc_tags_i[1] = 5'd16;
        
        @(negedge clk);
        #1;
        
        check_assertion("Rename ready after both grants", 
                       rename_rdy_o == 1'b1,
                       $sformatf("Expected rename_rdy=1, got %b", rename_rdy_o));
                
        check_assertion("Both instructions now valid", 
                       renamed_insts_o[0].is_valid && renamed_insts_o[1].is_valid,
                       $sformatf("Expected both valid, got [0]=%b [1]=%b",
                                renamed_insts_o[0].is_valid, renamed_insts_o[1].is_valid));
        
        check_assertion("Inst[0] has correct tag", 
                       renamed_insts_o[0].dest_tag == 5'd15,
                       $sformatf("Expected tag=15, got %d", renamed_insts_o[0].dest_tag));
        
        check_assertion("Inst[1] has correct tag", 
                       renamed_insts_o[1].dest_tag == 5'd16,
                       $sformatf("Expected tag=16, got %d", renamed_insts_o[1].dest_tag));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 6: Commit and Read (Verify PRF Update)
        //-------------------------------------------------------------
        $display("[TEST 6] Commit Write and Subsequent Read");
        $display("  Committing x3 = 0xDEADBEEF with tag 10");
        
        commit_write(0, 5'd3, 32'hDEADBEEF, 5'd10);
        decoded_insts_i[0] = '{default:'0};
        decoded_insts_i[1] = '{default:'0};
        rob_alloc_gnt_i = 2'b00;
        
        @(negedge clk);
        #1;
        commit_write_ports_i[0].we = 1'b0;
        
        // Now try to read x3
        $display("  Reading x3 in next rename cycle");
        create_instruction(decoded_insts_i[0], 32'h99999999, 5'd9, 5'd3, 5'd0, 1'b1, OPC_ARI_RTYPE);
        rob_alloc_gnt_i = 2'b01;
        rob_alloc_tags_i[0] = 5'd17;
        
        @(negedge clk);
        #1;
        
        check_assertion("Committed data read correctly", 
                       renamed_insts_o[0].src_1_a.data == 32'hDEADBEEF,
                       $sformatf("Expected data=0xDEADBEEF, got 0x%h", renamed_insts_o[0].src_1_a.data));
        
        check_assertion("Renamed flag cleared after commit", 
                       renamed_insts_o[0].src_1_a.is_renamed == 1'b0,
                       $sformatf("Expected is_renamed=0, got %b", renamed_insts_o[0].src_1_a.is_renamed));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 7: Flush Test
        //-------------------------------------------------------------
        $display("[TEST 7] Flush - Clear All Renamed Flags");
        
        // First, rename some registers
        create_instruction(decoded_insts_i[0], 32'hAAAAAAAA, 5'd10, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        rob_alloc_gnt_i = 2'b01;
        rob_alloc_tags_i[0] = 5'd18;
        
        @(negedge clk);
        
        // Verify instruction was renamed
        check_assertion("Instruction renamed before flush", 
                       renamed_insts_o[0].is_valid == 1'b1,
                       "Setup check failed");
        
        // Now flush
        $display("  Asserting flush...");
        flush = 1'b1;
        decoded_insts_i[0] = '{default:'0};
        
        @(negedge clk);
        #1;
        flush = 1'b0;
        
        $display("After flush, all renamed flags should be cleared");
        
        @(negedge clk);
        #1;
        
        check_assertion("Pipeline cleared after flush", 
                       renamed_insts_o[0].is_valid == 1'b0,
                       $sformatf("Expected valid=0, got %b", renamed_insts_o[0].is_valid));
        
        check_assertion("Inst[1] also cleared", 
                       renamed_insts_o[1].is_valid == 1'b0,
                       $sformatf("Expected valid=0, got %b", renamed_insts_o[1].is_valid));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 8: Compaction Test
        //-------------------------------------------------------------
        $display("[TEST 8] Compaction - Only inst[1] valid");
        $display("  Sending: inst[0] invalid, inst[1] valid");
        
        decoded_insts_i[0] = '{default:'0};  // Invalid
        create_instruction(decoded_insts_i[1], 32'hBBBBBBBB, 5'd11, 5'd1, 5'd2, 1'b1, OPC_ARI_RTYPE);
        
        rob_alloc_gnt_i = 2'b10;  // Grant inst[1]
        rob_alloc_tags_i[1] = 5'd19;
        
        @(negedge clk);
        #1;
        
        check_assertion("After compaction, inst[0] is valid", 
                       renamed_insts_o[0].is_valid == 1'b1,
                       $sformatf("Expected valid=1, got %b", renamed_insts_o[0].is_valid));
        
        check_assertion("Compacted inst has correct tag", 
                       renamed_insts_o[0].dest_tag == 5'd19,
                       $sformatf("Expected tag=19, got %d", renamed_insts_o[0].dest_tag));
        
        check_assertion("Compacted inst has correct PC", 
                       renamed_insts_o[0].pc == 32'hBBBBBBBB,
                       $sformatf("Expected PC=0x1024, got 0x%h", renamed_insts_o[0].pc));
        
        check_assertion("Inst[1] should be invalid after compaction", 
                       renamed_insts_o[1].is_valid == 1'b0,
                       $sformatf("Expected valid=0, got %b", renamed_insts_o[1].is_valid));
        
        $display("");
        
        //-------------------------------------------------------------
        // End of Tests
        //-------------------------------------------------------------
        repeat(5) @(posedge clk);
        
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
        #10000;
        $display("\n[ERROR] Testbench timeout!");
        $finish;
    end

endmodule
