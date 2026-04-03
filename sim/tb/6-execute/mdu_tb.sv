`timescale 1ns/1ps

import riscv_isa_pkg::*;
import uarch_pkg::*;

module mdu_tb;

    // DUT interface signals
    logic              clk;
    logic              rst;
    logic              flush;

    logic              mdu_rdy;
    instruction_t      mdu_packet;
    writeback_packet_t mdu_result;
    logic              mdu_cdb_gnt;  // acts like a "read enable" for the CDB

    // ----------------------------------------------------------------
    // Clock generation
    // ----------------------------------------------------------------
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // ----------------------------------------------------------------
    // DUT instance
    // ----------------------------------------------------------------
    mdu dut (
        .clk          (clk),
        .rst          (rst),
        .flush        (flush),

        .mdu_rdy      (mdu_rdy),
        .mdu_packet   (mdu_packet),

        .mdu_result   (mdu_result),
        .mdu_cdb_gnt  (mdu_cdb_gnt)
    );

    // ----------------------------------------------------------------
    // Testbench bookkeeping
    // ----------------------------------------------------------------
    int unsigned num_tests   = 0;
    int unsigned num_errors  = 0;
    int unsigned tag_counter = 0;

    // ----------------------------------------------------------------
    // Helper: drive reset
    // ----------------------------------------------------------------
    task automatic do_reset();
        begin
            rst         = 1'b1;
            flush       = 1'b0;
            mdu_cdb_gnt = 1'b1; // always grant CDB (always ready to "read")
            mdu_packet  = '0;
            @(posedge clk);
            @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
        end
    endtask

    // ----------------------------------------------------------------
    // Simple, explicit reference model for RV32M ops
    // ----------------------------------------------------------------
    function automatic logic [31:0] ref_m_ext_result (
        input logic [2:0]  uop,
        input logic [31:0] rs1,
        input logic [31:0] rs2
    );
        // 32-bit signed / unsigned aliases
        int          s_rs1, s_rs2;
        int          s_q, s_r;
        int unsigned u_rs1, u_rs2;
        int unsigned u_q, u_r;
        logic [63:0] prod_ss, prod_su, prod_uu;
        logic [31:0] res;

        // Cast to 32-bit signed/unsigned
        s_rs1 = int'( $signed(rs1) );
        s_rs2 = int'( $signed(rs2) );
        u_rs1 = int'( rs1 );
        u_rs2 = int'( rs2 );

        // 64-bit products (for MULH variants)
        prod_ss = $signed(rs1) * $signed(rs2);        // signed * signed
        prod_su = $signed(rs1) * $unsigned(rs2);      // signed * unsigned
        prod_uu = $unsigned(rs1) * $unsigned(rs2);    // unsigned * unsigned

        unique case (uop)
            // MUL: low 32 bits
            FNC_MUL: begin
                res = prod_ss[31:0];
            end

            // MULH: high 32 bits (signed * signed)
            FNC_MULH: begin
                res = prod_ss[63:32];
            end

            // MULHSU: high 32 bits (signed * unsigned)
            FNC_MULHSU: begin
                res = prod_su[63:32];
            end

            // MULHU: high 32 bits (unsigned * unsigned)
            FNC_MULHU: begin
                res = prod_uu[63:32];
            end

            // DIV: signed division (RISC-V spec)
            FNC_DIV: begin
                if (rs2 == 32'd0) begin
                    // division by zero → all 1s
                    res = 32'hFFFF_FFFF;
                end
                else if ((rs1 == 32'h8000_0000) && (rs2 == 32'hFFFF_FFFF)) begin
                    // overflow case INT_MIN / -1 → INT_MIN
                    res = 32'h8000_0000;
                end
                else begin
                    s_q = s_rs1 / s_rs2;  // trunc toward 0
                    res = logic'(s_q);
                end
            end

            // DIVU: unsigned division
            FNC_DIVU: begin
                if (rs2 == 32'd0) begin
                    res = 32'hFFFF_FFFF;
                end
                else begin
                    u_q = u_rs1 / u_rs2;
                    res = logic'(u_q);
                end
            end

            // REM: signed remainder (same sign as dividend)
            FNC_REM: begin
                if (rs2 == 32'd0) begin
                    res = rs1;  // as per RISC-V spec
                end
                else if ((rs1 == 32'h8000_0000) && (rs2 == 32'hFFFF_FFFF)) begin
                    res = 32'h0000_0000;  // special case
                end
                else begin
                    s_r = s_rs1 % s_rs2;
                    res = logic'(s_r);
                end
            end

            // REMU: unsigned remainder
            FNC_REMU: begin
                if (rs2 == 32'd0) begin
                    res = rs1;
                end
                else begin
                    u_r = u_rs1 % u_rs2;
                    res = logic'(u_r);
                end
            end

            default: begin
                res = 32'hDEAD_BEEF;
            end
        endcase

        return res;
    endfunction

    // ----------------------------------------------------------------
    // Task: issue one instruction to MDU and check result
    // ----------------------------------------------------------------
    task automatic run_mdu_test(
        input string       name,
        input logic [2:0]  uop,
        input logic [31:0] rs1_val,
        input logic [31:0] rs2_val
    );
        logic [31:0] ref_res;
        begin
            num_tests++;

            // wait until MDU is ready
            @(posedge clk);
            wait (mdu_rdy == 1'b1);
            @(posedge clk);

            // prepare packet
            tag_counter++;

            mdu_packet                    = '0;
            mdu_packet.is_valid           = 1'b1;
            mdu_packet.uop_0              = uop;
            mdu_packet.src_0_a.data       = rs1_val;
            mdu_packet.src_0_b.data       = rs2_val;
            mdu_packet.src_0_a.is_renamed = 1'b0;
            mdu_packet.src_0_b.is_renamed = 1'b0;
            mdu_packet.dest_tag           = tag_counter[ uarch_pkg::TAG_WIDTH-1:0 ];
            mdu_packet.has_rd             = 1'b1;

            @(posedge clk);
            // deassert is_valid after one cycle
            mdu_packet.is_valid = 1'b0;

            // wait for result valid
            do begin
                @(posedge clk);
            end while (mdu_result.is_valid != 1'b1);

            // Get golden result from reference model
            ref_res = ref_m_ext_result(uop, rs1_val, rs2_val);

            if (mdu_result.result !== ref_res) begin
                num_errors++;
                $display("[%0t] ERROR %s: uop=%0d rs1=%h rs2=%h => got=%h expected=%h",
                         $time, name, uop, rs1_val, rs2_val,
                         mdu_result.result, ref_res);
            end
            else begin
                $display("[%0t] PASS  %s: uop=%0d rs1=%h rs2=%h => result=%h",
                         $time, name, uop, rs1_val, rs2_val,
                         mdu_result.result);
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Top-level stimulus
    // ----------------------------------------------------------------
    initial begin
        do_reset();

        // Directed MUL tests
        run_mdu_test("MUL_1",   FNC_MUL,    32'd3,           32'd5);
        run_mdu_test("MUL_2",   FNC_MUL,    32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MUL_3",   FNC_MUL,    32'h8000_0000,   32'd2);

        // MULH tests (signed * signed high)
        run_mdu_test("MULH_1",  FNC_MULH,   32'd3,           32'd5);
        run_mdu_test("MULH_2",  FNC_MULH,   32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MULH_3",  FNC_MULH,   32'h8000_0000,   32'hFFFF_FFFF);

        // MULHSU tests (signed * unsigned high)
        run_mdu_test("MULHSU_1", FNC_MULHSU, 32'd3,          32'd5);
        run_mdu_test("MULHSU_2", FNC_MULHSU, 32'hFFFF_FFFF,  32'd2);
        run_mdu_test("MULHSU_3", FNC_MULHSU, 32'h8000_0000,  32'd2);

        // MULHU tests (unsigned * unsigned high)
        run_mdu_test("MULHU_1", FNC_MULHU,  32'd3,           32'd5);
        run_mdu_test("MULHU_2", FNC_MULHU,  32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MULHU_3", FNC_MULHU,  32'h8000_0000,   32'h8000_0000);

        // DIV tests (signed)
        run_mdu_test("DIV_1",   FNC_DIV,    32'd10,          32'd3);
        run_mdu_test("DIV_2",   FNC_DIV,    32'hFFFF_FFF6,   32'd3);          // -10 / 3
        run_mdu_test("DIV_3",   FNC_DIV,    32'h8000_0000,   32'hFFFF_FFFF);  // INT_MIN / -1

        // DIVU tests (unsigned)
        run_mdu_test("DIVU_1",  FNC_DIVU,   32'd10,          32'd3);
        run_mdu_test("DIVU_2",  FNC_DIVU,   32'hFFFF_FFFF,   32'd2);

        // REM tests (signed)
        run_mdu_test("REM_1",   FNC_REM,    32'd10,          32'd3);
        run_mdu_test("REM_2",   FNC_REM,    32'hFFFF_FFF6,   32'd3);          // -10 % 3
        run_mdu_test("REM_3",   FNC_REM,    32'h8000_0000,   32'hFFFF_FFFF);  // INT_MIN % -1

        // REMU tests (unsigned)
        run_mdu_test("REMU_1",  FNC_REMU,   32'd10,          32'd3);
        run_mdu_test("REMU_2",  FNC_REMU,   32'hFFFF_FFFF,   32'd2);

        // Some random tests for all ops
        repeat (20) begin
            logic [31:0] r1;
            logic [31:0] r2;

            r1 = $urandom();
            r2 = $urandom();

            run_mdu_test("MUL_rand",    FNC_MUL,    r1, r2);
            run_mdu_test("MULH_rand",   FNC_MULH,   r1, r2);
            run_mdu_test("MULHSU_rand", FNC_MULHSU, r1, r2);
            run_mdu_test("MULHU_rand",  FNC_MULHU,  r1, r2);

            // for random div tests, avoid too many rs2==0 cases
            if (r2 == 32'd0) r2 = 32'd1;

            run_mdu_test("DIV_rand",    FNC_DIV,    r1, r2);
            run_mdu_test("DIVU_rand",   FNC_DIVU,   r1, r2);
            run_mdu_test("REM_rand",    FNC_REM,    r1, r2);
            run_mdu_test("REMU_rand",   FNC_REMU,   r1, r2);
        end

        $display("====================================================");
        $display("MDU TESTS COMPLETE: %0d tests, %0d errors", num_tests, num_errors);
        $display("====================================================");
        #20;
        $finish;
    end

endmodule
