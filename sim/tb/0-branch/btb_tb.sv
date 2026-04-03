`timescale 1ns/1ps
import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module btb_tb;

    //-------------------------------------------------------------
    // Parameters
    //-------------------------------------------------------------
    localparam ENTRIES   = 128;
    localparam B_TAG_WIDTH = 12;
    localparam IDX_WIDTH = $clog2(ENTRIES);

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
    // DUT I/O - Using Structs!
    //-------------------------------------------------------------
    logic [CPU_ADDR_BITS-1:0]   pc;
    btb_pred_t     [FETCH_WIDTH-1:0] read_ports;
    btb_write_t    [FETCH_WIDTH-1:0] write_ports;

    //-------------------------------------------------------------
    // Test Variables
    //-------------------------------------------------------------
    logic [31:0] diff_tag_pc;
    logic [31:0] aliased_pc;

    //-------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------
    btb #(
        .ENTRIES(ENTRIES),
        .B_TAG_WIDTH(B_TAG_WIDTH)
    ) dut (
        .clk(clk),
        .rst(rst),
        .pc(pc),
        .read_ports(read_ports),
        .write_ports(write_ports)
    );

    //-------------------------------------------------------------
    // Helper Functions
    //-------------------------------------------------------------
    function automatic logic [IDX_WIDTH-1:0] get_index(input logic [CPU_ADDR_BITS-1:0] addr);
        return addr[IDX_WIDTH+1:2];
    endfunction

    function automatic logic [B_TAG_WIDTH-1:0] get_tag(input logic [CPU_ADDR_BITS-1:0] addr);
        return addr[B_TAG_WIDTH+IDX_WIDTH+1:IDX_WIDTH+2];
    endfunction

    function automatic string btype_to_str(input logic [1:0] btype);
        case (btype)
            BRANCH_COND: return "COND";
            BRANCH_JUMP: return "JUMP";
            BRANCH_CALL: return "CALL";
            BRANCH_RET:  return "RET";
            default:     return "????";
        endcase
    endfunction

    //-------------------------------------------------------------
    // Tasks
    //-------------------------------------------------------------
    task automatic clear_signals();
        pc = '0;
        for (int i = 0; i < FETCH_WIDTH; i++) begin
            write_ports[i].val   = 1'b0;
            write_ports[i].pc    = '0;
            write_ports[i].targ  = '0;
            write_ports[i].btype  = 2'b00;
            write_ports[i].taken = 1'b0;
        end
    endtask

    task automatic do_update(
        input logic [CPU_ADDR_BITS-1:0] upc,
        input logic [CPU_ADDR_BITS-1:0] utarg,
        input logic [1:0]               utype,
        input logic                     utaken
    );
        @(negedge clk);
        write_ports[0].val   = 1'b1;
        write_ports[0].pc    = upc;
        write_ports[0].targ  = utarg;
        write_ports[0].btype  = utype;
        write_ports[0].taken = utaken;
        @(negedge clk);
        write_ports[0] = '{default:'0};
    endtask

    task automatic do_dual_update(
        input logic [CPU_ADDR_BITS-1:0] upc0,
        input logic [CPU_ADDR_BITS-1:0] utarg0,
        input logic [1:0]               utype0,
        input logic                     utaken0,
        input logic [CPU_ADDR_BITS-1:0] upc1,
        input logic [CPU_ADDR_BITS-1:0] utarg1,
        input logic [1:0]               utype1,
        input logic                     utaken1
    );
        @(negedge clk);
        write_ports[0].val   = 1'b1;
        write_ports[0].pc    = upc0;
        write_ports[0].targ  = utarg0;
        write_ports[0].btype  = utype0;
        write_ports[0].taken = utaken0;
        
        write_ports[1].val   = 1'b1;
        write_ports[1].pc    = upc1;
        write_ports[1].targ  = utarg1;
        write_ports[1].btype  = utype1;
        write_ports[1].taken = utaken1;
        @(negedge clk);
        write_ports[0] = '{default:'0};
        write_ports[1] = '{default:'0};
    endtask

    task automatic check_pred(
        input string                    name,
        input logic [CPU_ADDR_BITS-1:0] check_pc,
        input logic                     exp_hit_0,
        input logic                     exp_hit_1,
        input logic [CPU_ADDR_BITS-1:0] exp_targ_0 = '0,
        input logic [CPU_ADDR_BITS-1:0] exp_targ_1 = '0,
        input logic [1:0]               exp_type_0 = '0,
        input logic [1:0]               exp_type_1 = '0
    );
        string info, errs;
        logic pass;
        
        pc = check_pc;
        @(negedge clk);
        
        info = $sformatf("hit=[%0d,%0d] targ=[0x%h,0x%h] type=[%s,%s]",
                         read_ports[0].hit, read_ports[1].hit,
                         read_ports[0].targ, read_ports[1].targ,
                         btype_to_str(read_ports[0].btype), btype_to_str(read_ports[1].btype));
        
        pass = 1;
        errs = "";
        
        if (read_ports[0].hit !== exp_hit_0) begin pass = 0; errs = $sformatf("%s hit[0]=%0d(exp %0d)", errs, read_ports[0].hit, exp_hit_0); end
        if (read_ports[1].hit !== exp_hit_1) begin pass = 0; errs = $sformatf("%s hit[1]=%0d(exp %0d)", errs, read_ports[1].hit, exp_hit_1); end
        if (exp_hit_0 && read_ports[0].targ !== exp_targ_0) begin pass = 0; errs = $sformatf("%s targ[0]=0x%h(exp 0x%h)", errs, read_ports[0].targ, exp_targ_0); end
        if (exp_hit_1 && read_ports[1].targ !== exp_targ_1) begin pass = 0; errs = $sformatf("%s targ[1]=0x%h(exp 0x%h)", errs, read_ports[1].targ, exp_targ_1); end
        if (exp_hit_0 && read_ports[0].btype !== exp_type_0) begin pass = 0; errs = $sformatf("%s type[0]=%s(exp %s)", errs, btype_to_str(read_ports[0].btype), btype_to_str(exp_type_0)); end
        if (exp_hit_1 && read_ports[1].btype !== exp_type_1) begin pass = 0; errs = $sformatf("%s type[1]=%s(exp %s)", errs, btype_to_str(read_ports[1].btype), btype_to_str(exp_type_1)); end
        
        if (pass) begin
            $display("  [PASS] %-28s : %s", name, info);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-28s : %s", name, info);
            $display("         %s", errs);
            tests_failed++;
        end
    endtask

    task automatic simul_rw_check(
        input string                    name,
        input logic [CPU_ADDR_BITS-1:0] read_pc,
        input logic [CPU_ADDR_BITS-1:0] write_pc,
        input logic [CPU_ADDR_BITS-1:0] write_targ,
        input logic [1:0]               write_type,
        input logic                     exp_hit_0,
        input logic                     exp_hit_1,
        input logic [CPU_ADDR_BITS-1:0] exp_targ_0 = '0,
        input logic [CPU_ADDR_BITS-1:0] exp_targ_1 = '0,
        input logic [1:0]               exp_type_0 = '0,
        input logic [1:0]               exp_type_1 = '0
    );
        string info, errs;
        logic pass;
        logic saved_hit [1:0];
        logic [CPU_ADDR_BITS-1:0] saved_targs [1:0];
        logic [1:0] saved_types [1:0];
        
        @(negedge clk);
        pc = read_pc;
        write_ports[0].val   = 1'b1;
        write_ports[0].pc    = write_pc;
        write_ports[0].targ  = write_targ;
        write_ports[0].btype  = write_type;
        write_ports[0].taken = 1'b1;
        
        #1;
        saved_hit[0] = read_ports[0].hit;
        saved_hit[1] = read_ports[1].hit;
        saved_targs[0] = read_ports[0].targ;
        saved_targs[1] = read_ports[1].targ;
        saved_types[0] = read_ports[0].btype;
        saved_types[1] = read_ports[1].btype;
        
        @(negedge clk);
        write_ports[0].val = 1'b0;
        
        info = $sformatf("hit=[%0d,%0d] targ=[0x%h,0x%h] type=[%s,%s]",
                         saved_hit[0], saved_hit[1],
                         saved_targs[0], saved_targs[1],
                         btype_to_str(saved_types[0]), btype_to_str(saved_types[1]));
        
        pass = 1;
        errs = "";
        
        if (saved_hit[0] !== exp_hit_0) begin pass = 0; errs = $sformatf("%s hit[0]=%0d(exp %0d)", errs, saved_hit[0], exp_hit_0); end
        if (saved_hit[1] !== exp_hit_1) begin pass = 0; errs = $sformatf("%s hit[1]=%0d(exp %0d)", errs, saved_hit[1], exp_hit_1); end
        if (exp_hit_0 && saved_targs[0] !== exp_targ_0) begin pass = 0; errs = $sformatf("%s targ[0]=0x%h(exp 0x%h)", errs, saved_targs[0], exp_targ_0); end
        if (exp_hit_1 && saved_targs[1] !== exp_targ_1) begin pass = 0; errs = $sformatf("%s targ[1]=0x%h(exp 0x%h)", errs, saved_targs[1], exp_targ_1); end
        if (exp_hit_0 && saved_types[0] !== exp_type_0) begin pass = 0; errs = $sformatf("%s type[0]=%s(exp %s)", errs, btype_to_str(saved_types[0]), btype_to_str(exp_type_0)); end
        if (exp_hit_1 && saved_types[1] !== exp_type_1) begin pass = 0; errs = $sformatf("%s type[1]=%s(exp %s)", errs, btype_to_str(saved_types[1]), btype_to_str(exp_type_1)); end
        
        if (pass) begin
            $display("  [PASS] %-28s : %s", name, info);
            tests_passed++;
        end else begin
            $display("  [FAIL] %-28s : %s", name, info);
            $display("         %s", errs);
            tests_failed++;
        end
    endtask

    task automatic do_reset();
        @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
    endtask

    //-------------------------------------------------------------
    // Tests
    //-------------------------------------------------------------
    initial begin
        $dumpfile("btb_tb.vcd");
        $dumpvars(0, btb_tb);

        $display("========================================");
        $display("  BTB Testbench (Struct Interface)");
        $display("  ENTRIES=%0d, B_TAG_WIDTH=%0d", ENTRIES, B_TAG_WIDTH);
        $display("========================================\n");

        clear_signals();
        do_reset();

        $display("[TEST 1] Empty BTB");
        check_pred("Miss", 32'h1000, 0, 0);
        $display("");

        $display("[TEST 2] Single Update");
        do_update(32'h1000, 32'h2000, BRANCH_COND, 1);
        check_pred("Hit", 32'h1000, 1, 0, 32'h2000, 0, BRANCH_COND, 0);
        $display("");

        $display("[TEST 3] Sequential (PC and PC+4)");
        do_update(32'h2004, 32'h3000, BRANCH_JUMP, 1);
        do_update(32'h2000, 32'h4000, BRANCH_CALL, 1);
        check_pred("Both hit", 32'h2000, 1, 1, 32'h4000, 32'h3000, BRANCH_CALL, BRANCH_JUMP);
        $display("");

        $display("[TEST 4] Not-Taken (No Update)");
        do_update(32'h3000, 32'h5000, BRANCH_COND, 0);
        check_pred("Still miss", 32'h3000, 0, 0);
        $display("");

        $display("[TEST 5] All Branch Types");
        do_update(32'h4000, 32'h5000, BRANCH_COND, 1);
        do_update(32'h4004, 32'h5004, BRANCH_JUMP, 1);
        check_pred("COND + JUMP", 32'h4000, 1, 1, 32'h5000, 32'h5004, BRANCH_COND, BRANCH_JUMP);
        do_update(32'h5000, 32'h6000, BRANCH_CALL, 1);
        do_update(32'h5004, 32'h6004, BRANCH_RET, 1);
        check_pred("CALL + RET", 32'h5000, 1, 1, 32'h6000, 32'h6004, BRANCH_CALL, BRANCH_RET);
        $display("");

        $display("[TEST 6] Tag Mismatch");
        do_update(32'h1000, 32'hAAAA, BRANCH_COND, 1);
        diff_tag_pc = 32'h1000 + (1 << (IDX_WIDTH + 3));
        check_pred("Different tag", diff_tag_pc, 0, 0);
        $display("");

        $display("[TEST 7] Overwrite");
        do_update(32'h1000, 32'hBBBB, BRANCH_JUMP, 1);
        check_pred("Updated", 32'h1000, 1, 0, 32'hBBBB, 0, BRANCH_JUMP, 0);
        $display("");

        $display("[TEST 8] Reset");
        do_reset();
        check_pred("After reset", 32'h1000, 0, 0);
        $display("");

        $display("[TEST 9] Aliasing");
        do_update(32'h2000, 32'h3000, BRANCH_COND, 1);
        aliased_pc = 32'h2000 + (1 << (B_TAG_WIDTH + IDX_WIDTH + 3));
        do_update(aliased_pc, 32'h9000, BRANCH_JUMP, 1);
        check_pred("Aliased", 32'h2000, 1, 0, 32'h9000, 0, BRANCH_JUMP, 0);
        $display("");

        $display("[TEST 10] Simultaneous R/W (Different Index)");
        do_reset();
        do_update(32'h1000, 32'hBBBB, BRANCH_COND, 1);
        simul_rw_check("Read sees old", 32'h1000, 32'h1008, 32'hDDDD, BRANCH_JUMP,
                       1, 0, 32'hBBBB, 0, BRANCH_COND, 0);
        check_pred("Both written", 32'h1000, 1, 0, 32'hBBBB, 0, BRANCH_COND, 0);
        check_pred("Both written", 32'h1008, 1, 0, 32'hDDDD, 0, BRANCH_JUMP, 0);
        $display("");

        $display("[TEST 11] Simultaneous R/W (Same Addr)");
        do_reset();
        do_update(32'hE000, 32'h1111, BRANCH_COND, 1);
        simul_rw_check("Read sees OLD", 32'hE000, 32'hE000, 32'h2222, BRANCH_CALL,
                       1, 0, 32'h1111, 0, BRANCH_COND, 0);
        check_pred("Now sees NEW", 32'hE000, 1, 0, 32'h2222, 0, BRANCH_CALL, 0);
        $display("");

        $display("[TEST 12] Dual Update (Different Entries)");
        do_reset();
        do_dual_update(32'hA000, 32'hAAAA, BRANCH_COND, 1,
                      32'hA010, 32'hBBBB, BRANCH_JUMP, 1);
        check_pred("Entry 0", 32'hA000, 1, 0, 32'hAAAA, 0, BRANCH_COND, 0);
        check_pred("Entry 1", 32'hA010, 1, 0, 32'hBBBB, 0, BRANCH_JUMP, 0);
        $display("");

        $display("[TEST 13] Dual Update (PC and PC+4)");
        do_reset();
        do_dual_update(32'hD000, 32'h1000, BRANCH_JUMP, 1,
                      32'hD004, 32'h2000, BRANCH_CALL, 1);
        check_pred("Both entries", 32'hD000, 1, 1, 32'h1000, 32'h2000, BRANCH_JUMP, BRANCH_CALL);
        $display("");

        $display("[TEST 14] Dual Update (Conflict - Slot 1 Wins)");
        do_reset();
        do_dual_update(32'hC000, 32'h1111, BRANCH_COND, 1,
                      32'hC000, 32'h2222, BRANCH_CALL, 1);
        check_pred("Slot 1 wins", 32'hC000, 1, 0, 32'h2222, 0, BRANCH_CALL, 0);
        $display("");

        $display("========================================");
        $display("  Tests Passed: %0d", tests_passed);
        $display("  Tests Failed: %0d", tests_failed);
        $display("========================================");
        if (tests_failed == 0) $display("  ALL TESTS PASSED!");
        else $fatal(1, "FAILURES DETECTED");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Timeout!");
    end

endmodule
