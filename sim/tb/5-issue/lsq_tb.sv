`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;

module lsq_tb;

    localparam STQ_DEPTH = 8;
    localparam LDQ_DEPTH = 8;

    int tests_passed = 0;
    int tests_failed = 0;
    int assertions_checked = 0;

    logic clk;
    logic rst;
    logic flush;

    logic                    dmem_rdy;
    instruction_t            dmem_pkt;

    writeback_packet_t       forward_pkt;

    logic [PIPE_WIDTH-1:0]   ld_we;
    instruction_t            ld_entries_in [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   ld_rdy;

    logic [PIPE_WIDTH-1:0]   st_we;
    instruction_t            st_entries_in [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   st_rdy;

    writeback_packet_t       cdb_ports [PIPE_WIDTH-1:0];

    logic                    agu_rdy;
    instruction_t            agu_pkt;
    writeback_packet_t       agu_result;

    logic [TAG_WIDTH-1:0]    rob_head;
    logic [TAG_WIDTH-1:0]    commit_store_ids [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]   commit_store_vals;

    lsq #(
        .STQ_DEPTH(STQ_DEPTH),
        .LDQ_DEPTH(LDQ_DEPTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .dmem_rdy(dmem_rdy),
        .dmem_pkt(dmem_pkt),
        .forward_pkt(forward_pkt),
        .ld_we(ld_we),
        .ld_entries_in(ld_entries_in),
        .ld_rdy(ld_rdy),
        .st_we(st_we),
        .st_entries_in(st_entries_in),
        .st_rdy(st_rdy),
        .cdb_ports(cdb_ports),
        .agu_rdy(agu_rdy),
        .agu_pkt(agu_pkt),
        .agu_result(agu_result),
        .rob_head(rob_head),
        .commit_store_ids(commit_store_ids),
        .commit_store_vals(commit_store_vals)
    );

    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

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

    function automatic instruction_t make_load(
        input logic [TAG_WIDTH-1:0] dest_tag,
        input logic [CPU_DATA_BITS-1:0] base_data = 32'h10,
        input logic [CPU_DATA_BITS-1:0] offs_data = 32'h4
    );
        instruction_t inst;
        inst = '{default:'0};
        inst.is_valid = 1'b1;
        inst.dest_tag = dest_tag;
        inst.src_0_a.data = base_data;
        inst.src_0_a.is_renamed = 1'b0;
        inst.src_0_b.data = offs_data;
        inst.src_0_b.is_renamed = 1'b0;
        return inst;
    endfunction

    function automatic instruction_t make_store(
        input logic [TAG_WIDTH-1:0] dest_tag,
        input logic [CPU_DATA_BITS-1:0] base_data = 32'h20,
        input logic [CPU_DATA_BITS-1:0] offs_data = 32'h8,
        input logic [CPU_DATA_BITS-1:0] store_data = 32'hCAFE_BABE
    );
        instruction_t inst;
        inst = '{default:'0};
        inst.is_valid = 1'b1;
        inst.dest_tag = dest_tag;
        inst.src_0_a.data = base_data;
        inst.src_0_a.is_renamed = 1'b0;
        inst.src_0_b.data = offs_data;
        inst.src_0_b.is_renamed = 1'b0;
        inst.src_1_b.data = store_data;
        inst.src_1_b.is_renamed = 1'b0;
        return inst;
    endfunction

    function automatic writeback_packet_t make_wb_pkt(
        input logic [TAG_WIDTH-1:0] tag,
        input logic [CPU_DATA_BITS-1:0] result,
        input logic valid = 1'b1
    );
        writeback_packet_t pkt;
        pkt = '{default:'0};
        pkt.dest_tag = tag;
        pkt.result = result;
        pkt.is_valid = valid;
        pkt.exception = 1'b0;
        return pkt;
    endfunction

    task automatic clear_dispatch_inputs();
        ld_we = '0;
        st_we = '0;
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            ld_entries_in[i] = '{default:'0};
            st_entries_in[i] = '{default:'0};
        end
    endtask

    task automatic clear_sideband_inputs();
        agu_result = '{default:'0};
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            cdb_ports[i] = '{default:'0};
            commit_store_ids[i] = '0;
        end
        commit_store_vals = '0;
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

    task automatic init_signals();
        rst = 1'b1;
        flush = 1'b0;
        dmem_rdy = 1'b0;
        agu_rdy = 1'b0;
        rob_head = '0;
        clear_dispatch_inputs();
        clear_sideband_inputs();

        wait_for_posedge_settle();
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        rst = 1'b0;
        wait_for_posedge_settle();
    endtask

    initial begin
        $dumpfile("lsq_tb.vcd");
        $dumpvars(0, lsq_tb);

        $display("========================================");
        $display("  lsq Testbench");
        $display("========================================");

        init_signals();

        //-------------------------------------------------------------
        // TEST 1: Reset / Empty State
        //-------------------------------------------------------------
        $display("[TEST 1] Reset / Empty State");
        check_assertion("Load queue ready after reset",
                       ld_rdy == 2'b11,
                       $sformatf("Expected ld_rdy=11, got %b", ld_rdy));
        check_assertion("Store queue ready after reset",
                       st_rdy == 2'b11,
                       $sformatf("Expected st_rdy=11, got %b", st_rdy));
        check_assertion("No AGU request at reset",
                       !agu_pkt.is_valid,
                       "AGU should be idle on reset exit");
        check_assertion("No dmem request at reset",
                       !dmem_pkt.is_valid && !forward_pkt.is_valid,
                       "Memory and forward outputs should be idle");
        $display("");

        //-------------------------------------------------------------
        // TEST 2: AGU Arbitration Picks Oldest Across Load/Store
        //-------------------------------------------------------------
        $display("[TEST 2] AGU Arbitration Picks Oldest Across Load/Store");
        init_signals();

        wait_for_negedge_settle();
        agu_rdy = 1'b1;
        ld_we = 2'b01;
        st_we = 2'b01;
        ld_entries_in[0] = make_load(5'h06);
        st_entries_in[0] = make_store(5'h04);
        wait_for_posedge_settle();

        check_assertion("Older store gets AGU first",
                       agu_pkt.is_valid && agu_pkt.dest_tag == 5'h04,
                       $sformatf("Expected store tag 0x04, got 0x%02h", agu_pkt.dest_tag));

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        wait_for_posedge_settle();

        check_assertion("Remaining load gets AGU next",
                       agu_pkt.is_valid && agu_pkt.dest_tag == 5'h06,
                       $sformatf("Expected load tag 0x06, got 0x%02h", agu_pkt.dest_tag));
        $display("");

        //-------------------------------------------------------------
        // TEST 3: Load Issues After AGU Result Capture
        //-------------------------------------------------------------
        $display("[TEST 3] Load Issues After AGU Result Capture");
        init_signals();

        wait_for_negedge_settle();
        ld_we = 2'b01;
        ld_entries_in[0] = make_load(5'h05);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        agu_result = make_wb_pkt(5'h05, 32'h1000_0020);
        wait_for_posedge_settle();

        check_assertion("Load address captured from AGU result",
                       dut.ldq_agu_comp[0] && dut.ldq[0].src_0_a.data == 32'h1000_0020,
                       "Expected captured AGU address in LDQ entry 0");

        wait_for_negedge_settle();
        clear_sideband_inputs();
        dmem_rdy = 1'b1;
        settle_comb();

        check_assertion("Load issues to dmem once address is known",
                       dmem_pkt.is_valid && dmem_pkt.dest_tag == 5'h05 &&
                       dmem_pkt.src_0_a.data == 32'h1000_0020,
                       "Expected dmem load request with captured address");
        $display("");

        //-------------------------------------------------------------
        // TEST 4: Store Requires Commit Before Memory Send
        //-------------------------------------------------------------
        $display("[TEST 4] Store Requires Commit Before Memory Send");
        init_signals();

        wait_for_negedge_settle();
        dmem_rdy = 1'b1;
        st_we = 2'b01;
        st_entries_in[0] = make_store(5'h07, 32'h20, 32'h4, 32'hABCD_1234);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        agu_result = make_wb_pkt(5'h07, 32'h2000_0004);
        wait_for_posedge_settle();

        check_assertion("Uncommitted store does not hit dmem",
                       !dmem_pkt.is_valid,
                       "Store should wait for commit before using dmem");

        wait_for_negedge_settle();
        clear_sideband_inputs();
        commit_store_ids[0] = 5'h07;
        commit_store_vals[0] = 1'b1;
        settle_comb();

        check_assertion("Committed store becomes dmem-eligible",
                       dmem_pkt.is_valid && dmem_pkt.dest_tag == 5'h07 &&
                       dmem_pkt.src_0_a.data == 32'h2000_0004 &&
                       dmem_pkt.src_1_b.data == 32'hABCD_1234,
                       "Expected committed store request with address and data");
        $display("");

        //-------------------------------------------------------------
        // TEST 5: Older Unresolved Store Stalls Younger Load
        //-------------------------------------------------------------
        $display("[TEST 5] Older Unresolved Store Stalls Younger Load");
        init_signals();

        wait_for_negedge_settle();
        dmem_rdy = 1'b1;
        st_we = 2'b01;
        st_entries_in[0] = make_store(5'h04);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        ld_we = 2'b01;
        ld_entries_in[0] = make_load(5'h06);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        agu_result = make_wb_pkt(5'h06, 32'h3000_0040);
        wait_for_posedge_settle();

        check_assertion("Younger load is blocked by older store with unknown address",
                       !dmem_pkt.is_valid,
                       "Expected no load issue while an older store address is unresolved");
        $display("");

        //-------------------------------------------------------------
        // TEST 6: Older Non-Aliasing Store Lets Younger Load Pass
        //-------------------------------------------------------------
        $display("[TEST 6] Older Non-Aliasing Store Lets Younger Load Pass");
        init_signals();

        wait_for_negedge_settle();
        dmem_rdy = 1'b1;
        st_we = 2'b01;
        st_entries_in[0] = make_store(5'h04);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        ld_we = 2'b01;
        ld_entries_in[0] = make_load(5'h06);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        agu_result = make_wb_pkt(5'h04, 32'h5000_0000);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_sideband_inputs();
        agu_result = make_wb_pkt(5'h06, 32'h5000_0004);
        settle_comb();

        check_assertion("Younger load bypasses older non-aliasing store",
                       dmem_pkt.is_valid && dmem_pkt.dest_tag == 5'h06 &&
                       dmem_pkt.src_0_a.data == 32'h5000_0004,
                       "Expected younger load to issue past non-aliasing older store");

        wait_for_posedge_settle();
        $display("");

        //-------------------------------------------------------------
        // TEST 7: Older Aliasing Store Blocks Load Until Store Drains
        //-------------------------------------------------------------
        $display("[TEST 7] Older Aliasing Store Blocks Load Until Store Drains");
        init_signals();

        wait_for_negedge_settle();
        dmem_rdy = 1'b1;
        st_we = 2'b01;
        st_entries_in[0] = make_store(5'h04, 32'h20, 32'h0, 32'h1111_2222);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        ld_we = 2'b01;
        ld_entries_in[0] = make_load(5'h06, 32'h30, 32'h0);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_dispatch_inputs();
        agu_result = make_wb_pkt(5'h04, 32'h6000_0000);
        wait_for_posedge_settle();

        wait_for_negedge_settle();
        clear_sideband_inputs();
        agu_result = make_wb_pkt(5'h06, 32'h6000_0000);
        wait_for_posedge_settle();

        check_assertion("Aliasing younger load is stalled before commit",
                       !dmem_pkt.is_valid,
                       "Expected aliasing younger load to remain stalled");

        wait_for_negedge_settle();
        clear_sideband_inputs();
        commit_store_ids[0] = 5'h04;
        commit_store_vals[0] = 1'b1;
        settle_comb();

        check_assertion("Committed head store reaches dmem first",
                       dmem_pkt.is_valid && dmem_pkt.dest_tag == 5'h04,
                       $sformatf("Expected store tag 0x04 first, got 0x%02h", dmem_pkt.dest_tag));

        wait_for_posedge_settle();

        check_assertion("Younger load issues after older aliasing store drains",
                       dmem_pkt.is_valid && dmem_pkt.dest_tag == 5'h06,
                       $sformatf("Expected load tag 0x06 next, got 0x%02h", dmem_pkt.dest_tag));
        $display("");

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

    initial begin
        #100000;
        $display("\n[ERROR] Testbench timeout!");
        $finish;
    end

endmodule
