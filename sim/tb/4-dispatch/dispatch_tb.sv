`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module dispatch_tb;
    
    //-------------------------------------------------------------
    // RS Type Indices (matching dispatch module)
    //-------------------------------------------------------------
    localparam RS_ALU = 0;
    localparam RS_LD  = 1;
    localparam RS_ST  = 2;
    localparam RS_MDU = 3;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;

    //-------------------------------------------------------------
    // Clock Generation
    //-------------------------------------------------------------
    logic clk;
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------
    // Stimulus Signals (inputs to DUT)
    //-------------------------------------------------------------
    instruction_t            renamed_insts_i    [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   rs_rdys_i          [NUM_RS-1:0];
    logic [PIPE_WIDTH-1:0]   rob_rdy_i;

    //-------------------------------------------------------------
    // Monitored Signals (outputs from DUT)
    //-------------------------------------------------------------
    logic                    dispatch_rdy_o;
    logic [PIPE_WIDTH-1:0]   rs_wes_o           [NUM_RS-1:0];
    instruction_t            rs_issue_ports_o   [NUM_RS-1:0][PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   rob_we_o;
    rob_entry_t              rob_entries_o      [PIPE_WIDTH-1:0];

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    dispatch dut (
        .dispatch_rdy(dispatch_rdy_o),
        .renamed_insts(renamed_insts_i),
        
        .rs_rdys(rs_rdys_i),
        .rs_wes(rs_wes_o),
        .rs_issue_ports(rs_issue_ports_o),
        
        .rob_rdy(rob_rdy_i),
        .rob_we(rob_we_o),
        .rob_entries(rob_entries_o)
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
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            renamed_insts_i[i] = '{default:'0};
        end
        for (int i = 0; i < NUM_RS; i++) begin
            rs_rdys_i[i] = '1;  // All RS ready by default
        end
        rob_rdy_i = 2'b11;  // Both slots available
        @(negedge clk);
        #1;
    endtask

    // Task: Create a renamed instruction
    task automatic create_renamed_inst(
        output instruction_t inst,
        input logic [CPU_ADDR_BITS-1:0] pc,
        input logic [4:0] rd,
        input logic has_rd,
        input logic [6:0] opcode,
        input logic [6:0] funct7,
        input logic [TAG_WIDTH-1:0] dest_tag
    );
        inst = '{default:'0};
        inst.is_valid = 1'b1;
        inst.pc = pc;
        inst.rd = rd;
        inst.has_rd = has_rd;
        inst.opcode = opcode;
        inst.funct7 = funct7;
        inst.dest_tag = dest_tag;
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("dispatch_tb.vcd");
        $dumpvars(0, dispatch_tb);
        
        $display("========================================");
        $display("  Dispatch Stage Testbench (with Compaction)");
        $display("========================================\n");
        
        init_signals();
        
        //-------------------------------------------------------------
        // TEST 1: Single ALU Instruction
        //-------------------------------------------------------------
        $display("[TEST 1] Single ALU Instruction Dispatch");
        $display("  Sending: ADD (ALU instruction) in slot 0");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1000, 5'd3, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd10);
        renamed_insts_i[1] = '{default:'0};
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Dispatch ready",
                       dispatch_rdy_o == 1'b1,
                       $sformatf("Expected dispatch_rdy=1, got %b", dispatch_rdy_o));
        
        check_assertion("ALU RS write enable [0]",
                       rs_wes_o[RS_ALU][0] == 1'b1,
                       $sformatf("Expected rs_wes[ALU][0]=1, got %b", rs_wes_o[RS_ALU][0]));
        
        check_assertion("No ALU RS write [1]",
                       rs_wes_o[RS_ALU][1] == 1'b0,
                       $sformatf("Expected rs_wes[ALU][1]=0, got %b", rs_wes_o[RS_ALU][1]));
        
        check_assertion("ROB write enable [0]",
                       rob_we_o[0] == 1'b1,
                       $sformatf("Expected rob_we[0]=1, got %b", rob_we_o[0]));
        
        check_assertion("No LSQ/MDU writes",
                       (rs_wes_o[RS_LD] == 2'b00) && (rs_wes_o[RS_ST] == 2'b00) && (rs_wes_o[RS_MDU] == 2'b00),
                       "Expected no LSQ or MDU writes");
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 2: Two ALU Instructions (SAME RS - No Compaction)
        //-------------------------------------------------------------
        $display("[TEST 2] Two ALU Instructions (SAME RS - No Compaction)");
        $display("  inst[0]=ALU, inst[1]=ALU → Same RS, use ch0 and ch1");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1004, 5'd5, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd11);
        create_renamed_inst(renamed_insts_i[1], 32'h1008, 5'd6, 1'b1, OPC_ARI_ITYPE, 7'b0000000, 5'd12);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Both ALU writes (ch0 and ch1)",
                       rs_wes_o[RS_ALU] == 2'b11,
                       $sformatf("Expected rs_wes[ALU]=11, got %b", rs_wes_o[RS_ALU]));
        
        check_assertion("ALU port[0] receives inst[0]",
                       rs_issue_ports_o[RS_ALU][0].pc == 32'h1004,
                       $sformatf("Expected ALU port[0] pc=1004, got %h", rs_issue_ports_o[RS_ALU][0].pc));
        
        check_assertion("ALU port[1] receives inst[1]",
                       rs_issue_ports_o[RS_ALU][1].pc == 32'h1008,
                       $sformatf("Expected ALU port[1] pc=1008, got %h", rs_issue_ports_o[RS_ALU][1].pc));
        
        check_assertion("Both ROB writes",
                       rob_we_o == 2'b11,
                       $sformatf("Expected rob_we=11, got %b", rob_we_o));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 3: Load Instruction
        //-------------------------------------------------------------
        $display("[TEST 3] Load Instruction Dispatch");
        
        create_renamed_inst(renamed_insts_i[0], 32'h100C, 5'd7, 1'b1, OPC_LOAD, 7'b0000000, 5'd13);
        renamed_insts_i[1] = '{default:'0};
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("LSQ LD write enable",
                       rs_wes_o[RS_LD][0] == 1'b1,
                       $sformatf("Expected rs_wes[LD][0]=1, got %b", rs_wes_o[RS_LD][0]));
        
        check_assertion("No ALU write",
                       rs_wes_o[RS_ALU] == 2'b00,
                       $sformatf("Expected rs_wes[ALU]=00, got %b", rs_wes_o[RS_ALU]));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 4: Store Instruction
        //-------------------------------------------------------------
        $display("[TEST 4] Store Instruction Dispatch");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1010, 5'd0, 1'b0, OPC_STORE, 7'b0000000, 5'd14);
        renamed_insts_i[1] = '{default:'0};
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("LSQ ST write enable",
                       rs_wes_o[RS_ST][0] == 1'b1,
                       $sformatf("Expected rs_wes[ST][0]=1, got %b", rs_wes_o[RS_ST][0]));
        
        check_assertion("ROB entry has_rd=0 for store",
                       rob_entries_o[0].has_rd == 1'b0,
                       $sformatf("Expected has_rd=0, got %b", rob_entries_o[0].has_rd));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 5: MDU Instruction
        //-------------------------------------------------------------
        $display("[TEST 5] MDU (MUL) Instruction Dispatch");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1014, 5'd8, 1'b1, OPC_ARI_RTYPE, FNC7_MULDIV, 5'd15);
        renamed_insts_i[1] = '{default:'0};
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("MDU RS write enable",
                       rs_wes_o[RS_MDU][0] == 1'b1,
                       $sformatf("Expected rs_wes[MDU][0]=1, got %b", rs_wes_o[RS_MDU][0]));
        
        check_assertion("No ALU write for MDU",
                       rs_wes_o[RS_ALU] == 2'b00,
                       $sformatf("Expected rs_wes[ALU]=00, got %b", rs_wes_o[RS_ALU]));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 6: ALU + LOAD (DIFFERENT RS - COMPACTION!)
        //-------------------------------------------------------------
        $display("[TEST 6] ALU + LOAD (DIFFERENT RS - COMPACTION!)");
        $display("  inst[0]=ALU, inst[1]=LOAD → Different RS, should compact!");
        $display("  Expected: ALU ch0, LOAD ch0 (compacted!)");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1018, 5'd9, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd16);
        create_renamed_inst(renamed_insts_i[1], 32'h101C, 5'd10, 1'b1, OPC_LOAD, 7'b0000000, 5'd17);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("ALU write to channel 0 only",
                       rs_wes_o[RS_ALU] == 2'b01,
                       $sformatf("Expected rs_wes[ALU]=01, got %b", rs_wes_o[RS_ALU]));
        
        check_assertion("LOAD write to channel 0 (COMPACTED!)",
                       rs_wes_o[RS_LD] == 2'b01,
                       $sformatf("Expected rs_wes[LD]=01 (compacted), got %b", rs_wes_o[RS_LD]));
        
        check_assertion("LOAD NOT to channel 1",
                       rs_wes_o[RS_LD][1] == 1'b0,
                       $sformatf("Expected rs_wes[LD][1]=0 (no ch1 with compaction), got %b", rs_wes_o[RS_LD][1]));
        
        check_assertion("Both ROB writes",
                       rob_we_o == 2'b11,
                       $sformatf("Expected rob_we=11, got %b", rob_we_o));
        
        check_assertion("LSQ port[0] receives inst[1] (LOAD)",
                       rs_issue_ports_o[RS_LD][0].pc == 32'h101C,
                       $sformatf("Expected LSQ port[0] to get LOAD (pc=101C), got pc=%h", rs_issue_ports_o[RS_LD][0].pc));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 7: LOAD + ALU (DIFFERENT RS - COMPACTION!)
        //-------------------------------------------------------------
        $display("[TEST 7] LOAD + ALU (DIFFERENT RS - COMPACTION!)");
        $display("  inst[0]=LOAD, inst[1]=ALU → Different RS, should compact!");
        $display("  Expected: LOAD ch0, ALU ch0 (compacted!)");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1020, 5'd11, 1'b1, OPC_LOAD, 7'b0000000, 5'd18);
        create_renamed_inst(renamed_insts_i[1], 32'h1024, 5'd12, 1'b1, OPC_ARI_ITYPE, 7'b0000000, 5'd19);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("LOAD write to channel 0 only",
                       rs_wes_o[RS_LD] == 2'b01,
                       $sformatf("Expected rs_wes[LD]=01, got %b", rs_wes_o[RS_LD]));
        
        check_assertion("ALU write to channel 0 (COMPACTED!)",
                       rs_wes_o[RS_ALU] == 2'b01,
                       $sformatf("Expected rs_wes[ALU]=01 (compacted), got %b", rs_wes_o[RS_ALU]));
        
        check_assertion("ALU NOT to channel 1",
                       rs_wes_o[RS_ALU][1] == 1'b0,
                       $sformatf("Expected rs_wes[ALU][1]=0 (no ch1 with compaction), got %b", rs_wes_o[RS_ALU][1]));
        
        check_assertion("ALU port[0] receives inst[1] (ALU)",
                       rs_issue_ports_o[RS_ALU][0].pc == 32'h1024,
                       $sformatf("Expected ALU port[0] to get ALU inst (pc=1024), got pc=%h", rs_issue_ports_o[RS_ALU][0].pc));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 8: ALU + MDU (DIFFERENT RS - COMPACTION!)
        //-------------------------------------------------------------
        $display("[TEST 8] ALU + MDU (DIFFERENT RS - COMPACTION!)");
        $display("  inst[0]=ALU, inst[1]=MDU → Different RS, should compact!");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1028, 5'd13, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd20);
        create_renamed_inst(renamed_insts_i[1], 32'h102C, 5'd14, 1'b1, OPC_ARI_RTYPE, FNC7_MULDIV, 5'd21);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("ALU write to channel 0 only",
                       rs_wes_o[RS_ALU] == 2'b01,
                       $sformatf("Expected rs_wes[ALU]=01, got %b", rs_wes_o[RS_ALU]));
        
        check_assertion("MDU write to channel 0 (COMPACTED!)",
                       rs_wes_o[RS_MDU] == 2'b01,
                       $sformatf("Expected rs_wes[MDU]=01 (compacted), got %b", rs_wes_o[RS_MDU]));
        
        check_assertion("MDU port[0] receives inst[1]",
                       rs_issue_ports_o[RS_MDU][0].pc == 32'h102C,
                       $sformatf("Expected MDU port[0] pc=102C, got %h", rs_issue_ports_o[RS_MDU][0].pc));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 9: LOAD + LOAD (SAME RS - No Compaction)
        //-------------------------------------------------------------
        $display("[TEST 9] LOAD + LOAD (SAME RS - No Compaction)");
        $display("  inst[0]=LOAD, inst[1]=LOAD → Same RS, use ch0 and ch1");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1030, 5'd15, 1'b1, OPC_LOAD, 7'b0000000, 5'd22);
        create_renamed_inst(renamed_insts_i[1], 32'h1034, 5'd16, 1'b1, OPC_LOAD, 7'b0000000, 5'd23);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Both LOAD writes (ch0 and ch1)",
                       rs_wes_o[RS_LD] == 2'b11,
                       $sformatf("Expected rs_wes[LD]=11, got %b", rs_wes_o[RS_LD]));
        
        check_assertion("LSQ port[0] receives inst[0]",
                       rs_issue_ports_o[RS_LD][0].pc == 32'h1030,
                       $sformatf("Expected LSQ port[0] pc=1030, got %h", rs_issue_ports_o[RS_LD][0].pc));
        
        check_assertion("LSQ port[1] receives inst[1]",
                       rs_issue_ports_o[RS_LD][1].pc == 32'h1034,
                       $sformatf("Expected LSQ port[1] pc=1034, got %h", rs_issue_ports_o[RS_LD][1].pc));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 10: Compaction with Limited Resources
        //-------------------------------------------------------------
        $display("[TEST 10] Compaction with Limited Resources");
        $display("  ALU + LOAD, but LOAD RS only has ch0 available");
        $display("  Should dispatch successfully with compaction!");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1038, 5'd17, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd24);
        create_renamed_inst(renamed_insts_i[1], 32'h103C, 5'd18, 1'b1, OPC_LOAD, 7'b0000000, 5'd25);
        
        rs_rdys_i[RS_ALU] = 2'b11;
        rs_rdys_i[RS_LD]  = 2'b01;  // Only ch0 available - compaction saves the day!
        rs_rdys_i[RS_ST]  = 2'b11;
        rs_rdys_i[RS_MDU] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Dispatch succeeds with compaction",
                       dispatch_rdy_o == 1'b1,
                       $sformatf("Expected dispatch_rdy=1 (compaction allows dispatch), got %b", dispatch_rdy_o));
        
        check_assertion("LOAD uses available ch0",
                       rs_wes_o[RS_LD] == 2'b01,
                       $sformatf("Expected rs_wes[LD]=01, got %b", rs_wes_o[RS_LD]));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 11: Same RS Stall (No Compaction Possible)
        //-------------------------------------------------------------
        $display("[TEST 11] Same RS Stall (No Compaction Possible)");
        $display("  Two ALU instructions, but only ch0 available → Should STALL");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1040, 5'd19, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd26);
        create_renamed_inst(renamed_insts_i[1], 32'h1044, 5'd20, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd27);
        
        rs_rdys_i[RS_ALU] = 2'b01;  // Only ch0 available, but need ch1 for same RS
        rs_rdys_i[RS_LD]  = 2'b11;
        rs_rdys_i[RS_ST]  = 2'b11;
        rs_rdys_i[RS_MDU] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Dispatch STALLS (same RS, need both channels)",
                       dispatch_rdy_o == 1'b0,
                       $sformatf("Expected dispatch_rdy=0 (stall), got %b", dispatch_rdy_o));
        
        check_assertion("No writes during stall",
                       (rs_wes_o[RS_ALU] == 2'b00) && (rob_we_o == 2'b00),
                       "Expected no writes during stall");
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 12: ROB Partial Availability
        //-------------------------------------------------------------
        $display("[TEST 12] ROB Partial Availability - Should Stall");
        
        create_renamed_inst(renamed_insts_i[0], 32'h1048, 5'd21, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd28);
        create_renamed_inst(renamed_insts_i[1], 32'h104C, 5'd22, 1'b1, OPC_ARI_RTYPE, 7'b0000000, 5'd29);
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b01;  // Only 1 ROB slot available
        
        @(negedge clk);
        #1;
        
        check_assertion("Dispatch NOT ready (ROB full)",
                       dispatch_rdy_o == 1'b0,
                       $sformatf("Expected dispatch_rdy=0, got %b", dispatch_rdy_o));
        
        $display("");
        
        //-------------------------------------------------------------
        // TEST 13: Invalid Instructions Pass Through
        //-------------------------------------------------------------
        $display("[TEST 13] Invalid Instructions (Bubbles)");
        
        renamed_insts_i[0] = '{default:'0};
        renamed_insts_i[1] = '{default:'0};
        
        for (int i = 0; i < NUM_RS; i++) rs_rdys_i[i] = 2'b11;
        rob_rdy_i = 2'b11;
        
        @(negedge clk);
        #1;
        
        check_assertion("Dispatch ready for invalid insts",
                       dispatch_rdy_o == 1'b1,
                       $sformatf("Expected dispatch_rdy=1, got %b", dispatch_rdy_o));
        
        check_assertion("No writes for invalid insts",
                       (rs_wes_o[RS_ALU] == 2'b00) && (rob_we_o == 2'b00) && 
                       (rs_wes_o[RS_LD] == 2'b00) && (rs_wes_o[RS_ST] == 2'b00) && (rs_wes_o[RS_MDU] == 2'b00),
                       "Expected no writes");
        
        $display("");
        
        //-------------------------------------------------------------
        // End of Tests
        //-------------------------------------------------------------
        #10;
        
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
