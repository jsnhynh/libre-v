`timescale 1ns/1ps

import riscv_isa_pkg::*;
import uarch_pkg::*;

module mdu_tb_clean;

    // DUT interface
    logic              clk;
    logic              rst;
    logic              flush;

    logic              mdu_rdy;
    instruction_t      mdu_packet;
    writeback_packet_t mdu_result;
    logic              mdu_cdb_gnt;

    // bookkeeping
    int unsigned num_tests   = 0;
    int unsigned num_errors  = 0;
    int unsigned tag_counter = 0;

    // ----------------------------------------------------------------
    // Clock
    // ----------------------------------------------------------------
    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    // ----------------------------------------------------------------
    // DUT
    // ----------------------------------------------------------------
    mdu dut (
        .clk         (clk),
        .rst         (rst),
        .flush       (flush),

        .mdu_rdy     (mdu_rdy),
        .mdu_packet  (mdu_packet),

        .mdu_result  (mdu_result),
        .mdu_cdb_gnt (mdu_cdb_gnt)
    );

    // ----------------------------------------------------------------
    // Reset
    // ----------------------------------------------------------------
    task automatic do_reset();
        begin
            rst         = 1'b1;
            flush       = 1'b0;
            mdu_cdb_gnt = 1'b1;   // always ready to "read" CDB
            mdu_packet  = '0;

            repeat (3) @(posedge clk);
            rst = 1'b0;
            @(posedge clk);
        end
    endtask

    // ----------------------------------------------------------------
    // RV32M reference model (spec-correct)
    // ----------------------------------------------------------------
    typedef struct packed {
    logic [31:0] result;  // main result (MUL/DIV/REM)
    logic [31:0] rem;     // remainder for DIV/REM if you want it
} result_t;

    function automatic result_t ref_m_ext_result(
    logic [2:0] uop,
    logic [31:0] rs1,
    logic [31:0] rs2
);
    result_t res;

    // local views
    logic signed [31:0] s_rs1, s_rs2;
    logic        [31:0] u_rs1, u_rs2;

    logic signed [63:0] s_prod;
    logic        [63:0] u_prod;

    logic signed [31:0] s_q, s_r;
    logic        [31:0] u_q, u_r;

    s_rs1 = rs1;
    s_rs2 = rs2;
    u_rs1 = rs1;
    u_rs2 = rs2;

    res.result = '0;
    res.rem    = '0;

    unique case (uop)
        3'd0: begin // MUL (low 32)
            s_prod     = s_rs1 * s_rs2;
            res.result = s_prod[31:0];
        end

        3'd1: begin // MULH (signed x signed, high 32)
            s_prod     = s_rs1 * s_rs2;
            res.result = s_prod[63:32];
        end

        3'd2: begin // MULHSU (signed rs1, unsigned rs2, high 32)
            // cast rs2 to signed but with non-sign-extended magnitude
            s_prod     = s_rs1 * $signed({1'b0, u_rs2});
            res.result = s_prod[63:32];
        end

        3'd3: begin // MULHU (unsigned x unsigned, high 32)
            u_prod     = u_rs1 * u_rs2;
            res.result = u_prod[63:32];
        end

        3'd4: begin // DIV (signed)
            if (rs2 == 32'd0) begin
                // q = -1, r = rs1
                res.result = 32'hFFFF_FFFF;
                res.rem    = rs1;
            end
            else if ((rs1 == 32'h8000_0000) && (rs2 == 32'hFFFF_FFFF)) begin
                // overflow: q = 0x80000000, r = 0
                res.result = 32'h8000_0000;
                res.rem    = 32'd0;
            end
            else begin
                s_q        = s_rs1 / s_rs2;
                s_r        = s_rs1 % s_rs2;   // sign of r follows dividend per spec
                res.result = s_q;             // QUOTIENT
                res.rem    = s_r;             // REMAINDER
            end
        end

        3'd5: begin // DIVU (unsigned)
            if (rs2 == 32'd0) begin
                // q = all 1s, r = rs1
                res.result = 32'hFFFF_FFFF;
                res.rem    = rs1;
            end
            else begin
                u_q        = u_rs1 / u_rs2;
                u_r        = u_rs1 % u_rs2;
                res.result = u_q;             // <-- FIX: use quotient here
                res.rem    = u_r;
            end
        end

        3'd6: begin // REM (signed)
            if (rs2 == 32'd0) begin
                res.result = rs1;             // per spec
            end
            else if ((rs1 == 32'h8000_0000) && (rs2 == 32'hFFFF_FFFF)) begin
                res.result = 32'd0;
            end
            else begin
                s_r        = s_rs1 % s_rs2;
                res.result = s_r;             // remainder (sign of rs1)
            end
        end

        3'd7: begin // REMU (unsigned)
            if (rs2 == 32'd0) begin
                res.result = rs1;
            end
            else begin
                u_r        = u_rs1 % u_rs2;
                res.result = u_r;
            end
        end

        default: begin
            res.result = '0;
            res.rem    = '0;
        end
    endcase

    return res;
endfunction


    // ----------------------------------------------------------------
    // One test helper
    // ----------------------------------------------------------------
    task automatic run_mdu_test(
        input string       name,
        input logic [2:0]  uop,
        input logic [31:0] rs1_val,
        input logic [31:0] rs2_val
    );
        //logic [31:0] ref_res;
        result_t ref_res;
        begin
            num_tests++;

            // wait until MDU is ready
            @(posedge clk);
            wait (mdu_rdy == 1'b1);
            @(posedge clk);

            // issue instruction
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
            mdu_packet.is_valid = 1'b0;

            // wait for result
            do begin
                @(posedge clk);
            end while (mdu_result.is_valid != 1'b1);

            // compute golden result
            ref_res = ref_m_ext_result(uop, rs1_val, rs2_val);

            if (mdu_result.result !== ref_res.result) begin
                num_errors++;
                $display("[%0t] ERROR %s: uop=%0d rs1=%h rs2=%h => got=%h expected=%h",
                    $time, name, uop, rs1_val, rs2_val,
                    mdu_result.result, ref_res.result);
            end
            else begin
                $display("[%0t] PASS  %s: uop=%0d rs1=%h rs2=%h => result=%h",
                    $time, name, uop, rs1_val, rs2_val,
                    mdu_result.result);
            end
        end
    endtask

    // ----------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------


    initial begin
          $display("==== MDU_TB_VERSION = 2 ====");
        do_reset();

        // -------- Directed MUL tests --------
        run_mdu_test("MUL_1",   FNC_MUL,     32'd3,           32'd5);
        run_mdu_test("MUL_2",   FNC_MUL,     32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MUL_3",   FNC_MUL,     32'h8000_0000,   32'd2);

        // MULH (signed*signed high)
        run_mdu_test("MULH_1",  FNC_MULH,    32'd3,           32'd5);
        run_mdu_test("MULH_2",  FNC_MULH,    32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MULH_3",  FNC_MULH,    32'h8000_0000,   32'hFFFF_FFFF);

        // MULHSU (signed*unsigned high)
        run_mdu_test("MULHSU_1", FNC_MULHSU, 32'd3,           32'd5);
        run_mdu_test("MULHSU_2", FNC_MULHSU, 32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MULHSU_3", FNC_MULHSU, 32'h8000_0000,   32'd2);

        // MULHU (unsigned*unsigned high)
        run_mdu_test("MULHU_1", FNC_MULHU,   32'd3,           32'd5);
        run_mdu_test("MULHU_2", FNC_MULHU,   32'hFFFF_FFFF,   32'd2);
        run_mdu_test("MULHU_3", FNC_MULHU,   32'h8000_0000,   32'h8000_0000);

        // -------- DIV / DIVU / REM / REMU directed --------
        run_mdu_test("DIV_1",   FNC_DIV,     32'd10,          32'd3);          // 3
        run_mdu_test("DIV_2",   FNC_DIV,     32'hFFFF_FFF6,   32'd3);          // -10 / 3 = -3
        run_mdu_test("DIV_3",   FNC_DIV,     32'h8000_0000,   32'hFFFF_FFFF);  // INT_MIN / -1

        run_mdu_test("DIVU_1",  FNC_DIVU,    32'd10,          32'd3);          // 3
        run_mdu_test("DIVU_2",  FNC_DIVU,    32'hFFFF_FFFF,   32'd2);          // 0x7FFFFFFF

        run_mdu_test("REM_1",   FNC_REM,     32'd10,          32'd3);          // 1
        run_mdu_test("REM_2",   FNC_REM,     32'hFFFF_FFF6,   32'd3);          // -10 % 3 = -1
        run_mdu_test("REM_3",   FNC_REM,     32'h8000_0000,   32'hFFFF_FFFF);  // 0

        run_mdu_test("REMU_1",  FNC_REMU,    32'd10,          32'd3);          // 1
        run_mdu_test("REMU_2",  FNC_REMU,    32'hFFFF_FFFF,   32'd2);          // 1

        // -------- Random tests --------
        repeat (20) begin
            logic [31:0] r1;
            logic [31:0] r2;

            r1 = $urandom();
            r2 = $urandom();

            run_mdu_test("MUL_rand",    FNC_MUL,    r1, r2);
            run_mdu_test("MULH_rand",   FNC_MULH,   r1, r2);
            run_mdu_test("MULHSU_rand", FNC_MULHSU, r1, r2);
            run_mdu_test("MULHU_rand",  FNC_MULHU,  r1, r2);

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
