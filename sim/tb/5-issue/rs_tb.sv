`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module rs_tb;

    //-------------------------------------------------------------
    // Test Configuration
    //-------------------------------------------------------------
    localparam NUM_ENTRIES = 8;
    localparam ISSUE_WIDTH = 2;

    //-------------------------------------------------------------
    // Test Statistics
    //-------------------------------------------------------------
    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;

    //-------------------------------------------------------------
    // Clock and Reset
    //-------------------------------------------------------------
    logic clk;
    logic rst;
    logic flush;

    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //-------------------------------------------------------------
    // DUT Signals
    //-------------------------------------------------------------
    logic [PIPE_WIDTH-1:0]      rs_rdy;
    logic [PIPE_WIDTH-1:0]      rs_we;
    instruction_t               rs_entries_in [PIPE_WIDTH-1:0];

    logic [ISSUE_WIDTH-1:0]     fu_rdy;
    instruction_t               fu_packets [ISSUE_WIDTH-1:0];

    writeback_packet_t          cdb_ports [PIPE_WIDTH-1:0];
    logic [TAG_WIDTH-1:0]       rob_head;

    //-------------------------------------------------------------
    // DUT Instantiation
    //-------------------------------------------------------------
    rs #(
        .NUM_ENTRIES(NUM_ENTRIES),
        .ISSUE_WIDTH(ISSUE_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .rs_rdy(rs_rdy),
        .rs_we(rs_we),
        .rs_entries_in(rs_entries_in),
        .fu_rdy(fu_rdy),
        .fu_packets(fu_packets),
        .cdb_ports(cdb_ports),
        .rob_head(rob_head)
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
            $display("  [PASS] %s", test_name);
            tests_passed++;
        end else begin
            $display("  [FAIL] %s: %s", test_name, fail_msg);
            tests_failed++;
        end
    endtask

    function automatic instruction_t make_test_inst(
        input logic [TAG_WIDTH-1:0] dest_tag,
        input logic [TAG_WIDTH-1:0] src_0_a_tag,
        input logic                 src_0_a_ready,
        input logic [TAG_WIDTH-1:0] src_0_b_tag,
        input logic                 src_0_b_ready,
        input logic                 valid = 1'b1
    );
        instruction_t inst;
        inst = '{default: '0};
        inst.is_valid = valid;
        inst.dest_tag = dest_tag;

        inst.src_0_a.is_renamed = !src_0_a_ready;
        inst.src_0_a.tag = src_0_a_tag;
        inst.src_0_a.data = src_0_a_ready ? 32'hAAAA_AAAA : 32'h0;

        inst.src_0_b.is_renamed = !src_0_b_ready;
        inst.src_0_b.tag = src_0_b_tag;
        inst.src_0_b.data = src_0_b_ready ? 32'hBBBB_BBBB : 32'h0;

        inst.src_1_a.is_renamed = 1'b0;
        inst.src_1_a.data = 32'hCCCC_CCCC;
        inst.src_1_b.is_renamed = 1'b0;
        inst.src_1_b.data = 32'hDDDD_DDDD;

        return inst;
    endfunction

    function automatic writeback_packet_t make_cdb_packet(
        input logic [TAG_WIDTH-1:0]     tag,
        input logic [CPU_DATA_BITS-1:0] result,
        input logic                     valid = 1'b1
    );
        writeback_packet_t pkt;
        pkt = '{default: '0};
        pkt.dest_tag = tag;
        pkt.result = result;
        pkt.is_valid = valid;
        pkt.exception = 1'b0;
        return pkt;
    endfunction

    function automatic logic packet_matches(
        input instruction_t pkt,
        input logic [TAG_WIDTH-1:0] tag
    );
        return pkt.is_valid && pkt.dest_tag == tag;
    endfunction

    task automatic clear_dispatch_inputs();
        rs_we = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            rs_entries_in[i] = '{default: '0};
        end
    endtask

    task automatic clear_cdb_inputs();
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            cdb_ports[i] = '{default: '0};
        end
    endtask

    task automatic drive_dispatch(
        input logic [PIPE_WIDTH-1:0] we,
        input instruction_t inst0,
        input instruction_t inst1
    );
        rs_we = we;
        rs_entries_in[0] = inst0;
        rs_entries_in[1] = inst1;
    endtask

    task automatic drive_cdb(
        input writeback_packet_t pkt0,
        input writeback_packet_t pkt1
    );
        cdb_ports[0] = pkt0;
        cdb_ports[1] = pkt1;
    endtask

    task automatic wait_for_negedge_settle();
        @(negedge clk);
        #1;
    endtask

    task automatic wait_for_posedge_settle();
        @(posedge clk);
        #1;
    endtask

    task automatic settle_comb();
        #1;
    endtask

    // This TB keeps stimulus stable through the capture edge to avoid
    // stimulus stable through the capture posedge, then check either:
    // - combinational issue/wakeup in the half-cycle before the next posedge
    // - registered state immediately after the posedge updates land
    task automatic init_signals();
        rst = 1'b1;
        flush = 1'b0;
        fu_rdy = '1;
        rob_head = '0;
        clear_dispatch_inputs();
        clear_cdb_inputs();

        wait_for_posedge_settle();
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        rst = 1'b0;
        wait_for_posedge_settle();
    endtask

    task automatic display_rs_state();
        $display("    RS State:");
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            if (dut.entries[i].is_valid) begin
                $display("      [%0d] tag=0x%02h, ready=%b, age=%0d",
                         i,
                         dut.entries[i].dest_tag,
                         dut.entry_ready[i],
                         dut.entry_ages[i]);
            end
        end
    endtask

    //-------------------------------------------------------------
    // Test Stimulus
    //-------------------------------------------------------------
    initial begin
        $dumpfile("rs_tb.vcd");
        $dumpvars(0, rs_tb);

        $display("========================================");
        $display("  Reservation Station Testbench");
        $display("========================================");
        $display("  NUM_ENTRIES = %0d", NUM_ENTRIES);
        $display("  ISSUE_WIDTH = %0d", ISSUE_WIDTH);
        $display("========================================\n");

        init_signals();

        //-------------------------------------------------------------
        // TEST 1: Basic Allocation
        //-------------------------------------------------------------
        $display("[TEST 1] Basic Allocation (2 ready instructions)");

        wait_for_negedge_settle();
        rob_head = 5'h00;
        drive_dispatch(
            2'b11,
            make_test_inst(5'h05, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h06, 5'h00, 1'b1, 5'h00, 1'b1)
        );

        check_assertion("RS ready to accept instructions",
                       rs_rdy == 2'b11,
                       $sformatf("Expected rs_rdy=11, got %b", rs_rdy));

        wait_for_posedge_settle();

        check_assertion("Both instructions stored",
                       dut.entries[0].is_valid && dut.entries[1].is_valid,
                       "Instructions should be stored in RS");

        check_assertion("Both instructions issued",
                       dut.issue_grants == 8'b0000_0011,
                       $sformatf("Expected issue_grants=0x03, got 0x%02h", dut.issue_grants));

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        wait_for_posedge_settle();

        $display("");

        //-------------------------------------------------------------
        // TEST 2: Age-Based Selection
        //-------------------------------------------------------------
        $display("[TEST 2] Age-Based Selection");

        init_signals();

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        rob_head = 5'h00;
        drive_dispatch(
            2'b11,
            make_test_inst(5'h03, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h01, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        drive_dispatch(
            2'b01,
            make_test_inst(5'h02, 5'h00, 1'b1, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        check_assertion("Three instructions staged before issue",
                       dut.entries[0].is_valid && dut.entries[1].is_valid && dut.entries[2].is_valid,
                       "Expected three valid RS entries before enabling issue");

        wait_for_negedge_settle();
        fu_rdy = 2'b11;
        clear_dispatch_inputs();
        settle_comb();

        check_assertion("Oldest instruction (age 1) issued to FU[0]",
                       fu_packets[0].dest_tag == 5'h01,
                       $sformatf("Expected tag=0x01, got 0x%02h", fu_packets[0].dest_tag));

        check_assertion("2nd oldest instruction (age 2) issued to FU[1]",
                       fu_packets[1].dest_tag == 5'h02,
                       $sformatf("Expected tag=0x02, got 0x%02h", fu_packets[1].dest_tag));

        wait_for_posedge_settle();

        check_assertion("Remaining oldest instruction (age 3) issued next",
                       fu_packets[0].dest_tag == 5'h03 && !fu_packets[1].is_valid,
                       $sformatf("Expected tag=0x03 only, got 0x%02h and valid1=%b",
                                fu_packets[0].dest_tag, fu_packets[1].is_valid));

        $display("");

        //-------------------------------------------------------------
        // TEST 3: Simple Wakeup
        //-------------------------------------------------------------
        $display("[TEST 3] Simple Wakeup on CDB");

        init_signals();

        wait_for_negedge_settle();
        rob_head = 5'h00;
        drive_dispatch(
            2'b01,
            make_test_inst(5'h05, 5'h0A, 1'b0, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        check_assertion("Instruction NOT ready (waiting for 0x0A)",
                       dut.entry_ready[0] == 1'b0,
                       "Instruction should not be ready yet");

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        drive_cdb(make_cdb_packet(5'h0A, 32'hDEAD_BEEF), '{default:'0});
        wait_for_posedge_settle();

        check_assertion("Instruction wakes up after CDB capture",
                       dut.entry_ready[0] == 1'b1,
                       "Instruction should be ready after the CDB result is captured");

        check_assertion("Instruction issues with captured data",
                       fu_packets[0].dest_tag == 5'h05 &&
                       fu_packets[0].src_0_a.data == 32'hDEAD_BEEF,
                       "Expected issued packet with captured CDB data");

        $display("");

        //-------------------------------------------------------------
        // TEST 4: Wraparound Age Calculation
        //-------------------------------------------------------------
        $display("[TEST 4] Wraparound Age Calculation");

        init_signals();

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        rob_head = 5'h1E;
        drive_dispatch(
            2'b11,
            make_test_inst(5'h01, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h1E, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        drive_dispatch(
            2'b01,
            make_test_inst(5'h1F, 5'h00, 1'b1, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        fu_rdy = 2'b11;
        clear_dispatch_inputs();
        settle_comb();

        check_assertion("Oldest (tag 0x1E, age 0) issued to FU[0]",
                       fu_packets[0].dest_tag == 5'h1E,
                       $sformatf("Expected tag=0x1E, got 0x%02h", fu_packets[0].dest_tag));
        check_assertion("2nd oldest (tag 0x1F, age 1) issued to FU[1]",
                       fu_packets[1].dest_tag == 5'h1F,
                       $sformatf("Expected tag=0x1F, got 0x%02h", fu_packets[1].dest_tag));

        wait_for_posedge_settle();
        check_assertion("3rd oldest (tag 0x01, age 3) issued next",
                       fu_packets[0].dest_tag == 5'h01 && !fu_packets[1].is_valid,
                       $sformatf("Expected tag=0x01 only, got 0x%02h and valid1=%b",
                                fu_packets[0].dest_tag, fu_packets[1].is_valid));

        $display("");

        //-------------------------------------------------------------
        // TEST 5: Back-to-back Dependencies
        //-------------------------------------------------------------
        $display("[TEST 5] Back-to-back Dependent Instructions");

        init_signals();

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        rob_head = 5'h00;
        drive_dispatch(
            2'b01,
            make_test_inst(5'h05, 5'h00, 1'b1, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        drive_dispatch(
            2'b01,
            make_test_inst(5'h06, 5'h05, 1'b0, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        check_assertion("Producer ready, consumer waiting",
                       dut.entry_ready[0] && !dut.entry_ready[1],
                       $sformatf("Expected ready bits 0=1 1=0, got %b", dut.entry_ready[1:0]));

        wait_for_negedge_settle();
        fu_rdy = 2'b11;
        clear_dispatch_inputs();
        drive_cdb(make_cdb_packet(5'h05, 32'h1234_5678), '{default:'0});
        settle_comb();

        check_assertion("Producer issues on the CDB cycle",
                       packet_matches(fu_packets[0], 5'h05) || packet_matches(fu_packets[1], 5'h05),
                       "Producer should issue once FU lanes are enabled");

        wait_for_posedge_settle();

        check_assertion("Consumer issues after wakeup is captured",
                       packet_matches(fu_packets[0], 5'h06) && !fu_packets[1].is_valid,
                       $sformatf("Expected only tag 0x06, got 0x%02h / valid1=%b",
                                fu_packets[0].dest_tag, fu_packets[1].is_valid));

        check_assertion("Consumer receives captured producer data",
                       fu_packets[0].src_0_a.data == 32'h1234_5678,
                       $sformatf("Expected data=0x12345678, got 0x%08h", fu_packets[0].src_0_a.data));

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        clear_cdb_inputs();
        drive_dispatch(
            2'b11,
            make_test_inst(5'h07, 5'h06, 1'b0, 5'h00, 1'b1),
            make_test_inst(5'h08, 5'h08, 1'b1, 5'h08, 1'b1)
        );
        wait_for_posedge_settle();

        check_assertion("Second pair stored",
                       dut.entries[0].is_valid && dut.entries[1].is_valid,
                       "Expected both follow-on instructions to be stored");

        check_assertion("Independent instruction ready while dependent one waits",
                       !dut.entry_ready[0] && dut.entry_ready[1],
                       $sformatf("Expected ready bits 0=0 1=1, got %b", dut.entry_ready[1:0]));

        $display("");

        //-------------------------------------------------------------
        // TEST 6: RS Full
        //-------------------------------------------------------------
        $display("[TEST 6] RS Full Scenario");

        init_signals();

        wait_for_negedge_settle();
        rob_head = 5'h00;
        fu_rdy = 2'b00;
        clear_cdb_inputs();

        for (int i = 0; i < NUM_ENTRIES/2; i++) begin
            drive_dispatch(
                2'b11,
                make_test_inst(TAG_WIDTH'((i*2)),   5'h10, 1'b0, 5'h00, 1'b1),
                make_test_inst(TAG_WIDTH'((i*2)+1), 5'h11, 1'b0, 5'h00, 1'b1)
            );
            wait_for_posedge_settle();
            if (i != (NUM_ENTRIES/2 - 1)) begin
                wait_for_negedge_settle();
            end
        end

        check_assertion("RS is full",
                       rs_rdy == 2'b00,
                       $sformatf("Expected rs_rdy=00 (full), got %b", rs_rdy));

        check_assertion("All 8 entries valid",
                       dut.entries[0].is_valid && dut.entries[1].is_valid &&
                       dut.entries[2].is_valid && dut.entries[3].is_valid &&
                       dut.entries[4].is_valid && dut.entries[5].is_valid &&
                       dut.entries[6].is_valid && dut.entries[7].is_valid,
                       "Not all entries are valid");

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        fu_rdy = 2'b10;
        drive_cdb(
            make_cdb_packet(5'h10, 32'hAAAA_AAAA),
            make_cdb_packet(5'h11, 32'hBBBB_BBBB)
        );
        wait_for_posedge_settle();

        check_assertion("Wakeups become visible after capture",
                       !fu_packets[0].is_valid && fu_packets[1].is_valid,
                       "Expected only one issue lane to be active after wakeup capture");

        check_assertion("RS has 1 free slot now",
                       rs_rdy == 2'b01,
                       $sformatf("Expected rs_rdy==01, got %b", rs_rdy));

        wait_for_negedge_settle();
        fu_rdy = 2'b11;
        clear_cdb_inputs();
        settle_comb();

        check_assertion("2 instructions issued (RS draining)",
                       fu_packets[0].is_valid && fu_packets[1].is_valid,
                       "Expected 2 instructions to issue");

        check_assertion("RS has 2 free slots now",
                       rs_rdy != 2'b00,
                       $sformatf("Expected rs_rdy!=00, got %b", rs_rdy));

        $display("");

        //-------------------------------------------------------------
        // TEST 7: Multi-Issue (2 ready instructions same cycle)
        //-------------------------------------------------------------
        $display("[TEST 7] Multi-Issue (2 instructions in 1 cycle)");

        init_signals();

        wait_for_negedge_settle();
        rob_head = 5'h00;
        drive_dispatch(
            2'b11,
            make_test_inst(5'h08, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h09, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        wait_for_posedge_settle();

        check_assertion("Both instructions ready",
                       dut.entry_ready[0] && dut.entry_ready[1],
                       "Both instructions should be ready");

        check_assertion("Both issued in same cycle",
                       fu_packets[0].is_valid && fu_packets[1].is_valid,
                       "Both FU packets should be valid");

        check_assertion("Correct tags issued",
                       (packet_matches(fu_packets[0], 5'h08) && packet_matches(fu_packets[1], 5'h09)) ||
                       (packet_matches(fu_packets[0], 5'h09) && packet_matches(fu_packets[1], 5'h08)),
                       $sformatf("Expected tags 0x08 and 0x09, got 0x%02h and 0x%02h",
                                fu_packets[0].dest_tag, fu_packets[1].dest_tag));

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        wait_for_posedge_settle();

        check_assertion("RS empty after dual issue",
                       !dut.entries[0].is_valid && !dut.entries[1].is_valid,
                       "Both entries should be cleared");

        $display("");

        //-------------------------------------------------------------
        // TEST 8: Flush
        //-------------------------------------------------------------
        $display("[TEST 8] Flush Clears All Entries");

        init_signals();

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        rob_head = 5'h00;
        drive_dispatch(
            2'b11,
            make_test_inst(5'h10, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h11, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        wait_for_posedge_settle();

        check_assertion("Entries valid before flush",
                       dut.entries[0].is_valid && dut.entries[1].is_valid,
                       "Entries should be valid");

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        flush = 1'b1;
        wait_for_posedge_settle();

        check_assertion("All entries cleared after flush",
                       !dut.entries[0].is_valid && !dut.entries[1].is_valid &&
                       !dut.entries[2].is_valid && !dut.entries[3].is_valid &&
                       !dut.entries[4].is_valid && !dut.entries[5].is_valid &&
                       !dut.entries[6].is_valid && !dut.entries[7].is_valid,
                       "All entries should be invalid after flush");

        wait_for_negedge_settle();
        flush = 1'b0;

        $display("");

        //-------------------------------------------------------------
        // TEST 9: Sequential Dispatch (Instructions arrive over time)
        //-------------------------------------------------------------
        $display("[TEST 9] Sequential Dispatch Over Multiple Cycles");

        init_signals();

        wait_for_negedge_settle();
        fu_rdy = 2'b00;
        rob_head = 5'h00;
        drive_dispatch(
            2'b01,
            make_test_inst(5'h10, 5'h00, 1'b1, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();
        check_assertion("First instruction allocated",
                       dut.entries[0].is_valid,
                       "Entry 0 should be valid");

        wait_for_negedge_settle();
        drive_dispatch(
            2'b01,
            make_test_inst(5'h0F, 5'h00, 1'b1, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();
        check_assertion("Second instruction allocated",
                       dut.entries[0].is_valid && dut.entries[1].is_valid,
                       "Entries 0 and 1 should be valid");

        wait_for_negedge_settle();
        drive_dispatch(
            2'b11,
            make_test_inst(5'h11, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h0E, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        wait_for_posedge_settle();
        check_assertion("Third and fourth instructions allocated",
                       dut.entries[0].is_valid && dut.entries[1].is_valid &&
                       dut.entries[2].is_valid && dut.entries[3].is_valid,
                       "Entries 0-3 should be valid");

        wait_for_negedge_settle();
        fu_rdy = 2'b11;
        clear_dispatch_inputs();
        settle_comb();

        check_assertion("Oldest pair issues first",
                       packet_matches(fu_packets[0], 5'h0E) && packet_matches(fu_packets[1], 5'h0F),
                       $sformatf("Expected tags 0x0E/0x0F, got 0x%02h/0x%02h",
                                fu_packets[0].dest_tag, fu_packets[1].dest_tag));

        wait_for_posedge_settle();

        check_assertion("Remaining pair stays queued next",
                       packet_matches(fu_packets[0], 5'h10) && packet_matches(fu_packets[1], 5'h11),
                       $sformatf("Expected tags 0x10/0x11, got 0x%02h/0x%02h",
                                fu_packets[0].dest_tag, fu_packets[1].dest_tag));

        wait_for_negedge_settle();
        wait_for_posedge_settle();

        check_assertion("RS empty after all sequential issues",
                       !dut.entries[0].is_valid && !dut.entries[1].is_valid &&
                       !dut.entries[2].is_valid && !dut.entries[3].is_valid,
                       "Entries 0-3 should be invalid");

        $display("");

        //-------------------------------------------------------------
        // TEST 10: Partial Dispatch (1 slot available)
        //-------------------------------------------------------------
        $display("[TEST 10] Partial Dispatch (RS has 1 slot free)");

        init_signals();

        wait_for_negedge_settle();
        rob_head = 5'h00;
        fu_rdy = 2'b00;

        for (int i = 0; i < 3; i++) begin
            drive_dispatch(
                2'b11,
                make_test_inst(TAG_WIDTH'((i*2)),   5'h10, 1'b0, 5'h00, 1'b1),
                make_test_inst(TAG_WIDTH'((i*2)+1), 5'h10, 1'b0, 5'h00, 1'b1)
            );
            wait_for_posedge_settle();
            wait_for_negedge_settle();
        end

        drive_dispatch(
            2'b01,
            make_test_inst(5'h06, 5'h10, 1'b0, 5'h00, 1'b1),
            '{default:'0}
        );
        wait_for_posedge_settle();

        check_assertion("RS has 1 slot free",
                       rs_rdy == 2'b01,
                       $sformatf("Expected rs_rdy=01 (1 slot), got %b", rs_rdy));

        wait_for_negedge_settle();
        drive_dispatch(
            2'b11,
            make_test_inst(5'h07, 5'h00, 1'b1, 5'h00, 1'b1),
            make_test_inst(5'h08, 5'h00, 1'b1, 5'h00, 1'b1)
        );
        settle_comb();

        check_assertion("Only 1 instruction can be written",
                       rs_rdy == 2'b01,
                       $sformatf("Expected rs_rdy=01, got %b", rs_rdy));

        wait_for_posedge_settle();

        check_assertion("RS now full",
                       rs_rdy == 2'b00,
                       $sformatf("Expected rs_rdy=00 (full), got %b", rs_rdy));

        check_assertion("Only first instruction allocated into final slot",
                       dut.entries[7].is_valid && dut.entries[7].dest_tag == 5'h07,
                       "Entry 7 should contain tag 0x07");

        $display("");

        //-------------------------------------------------------------
        // End of Tests
        //-------------------------------------------------------------
        wait_for_posedge_settle();

        $display("========================================");
        $display("  All Tests Complete!");
        $display("========================================");
        $display("  Tests Passed:  %0d", tests_passed);
        $display("  Tests Failed:  %0d", tests_failed);
        $display("  Total Checks:  %0d", assertions_checked);
        $display("========================================");

        if (tests_failed == 0) begin
            $display("  ALL TESTS PASSED!");
        end else begin
            $display("  SOME TESTS FAILED!");
            $fatal(1, "Test failures detected");
        end

        $finish;
    end

    //-------------------------------------------------------------
    // Timeout Watchdog
    //-------------------------------------------------------------
    initial begin
        #100000;
        $display("\n[ERROR] Testbench timeout!");
        $finish;
    end

endmodule
