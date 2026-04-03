import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module ras #(
    parameter DEPTH = RAS_ENTRIES
)(
    input  logic clk, rst,

    // Fetch-time (read-only)
    output logic [CPU_ADDR_BITS-1:0] peek_addr,
    output logic                     peek_rdy,

    // Predecode-time (state mutation)
    input  logic                     push,        // CALL
    input  logic                     pop,         // RET (consume)
    input  logic [CPU_ADDR_BITS-1:0] push_addr,

    output logic                     push_rdy,
    output logic                     pop_rdy,

    // -------------------------------------------------
    // Checkpointing
    // -------------------------------------------------
    output logic [$clog2(DEPTH):0]   ptr,

    // -------------------------------------------------
    // Recovery (mispredict)
    // -------------------------------------------------
    input  logic                     recover,
    input  logic [$clog2(DEPTH):0]   recover_ptr
);

    localparam PTR_WIDTH = $clog2(DEPTH);

    // Stack storage
    logic [CPU_ADDR_BITS-1:0] stack [DEPTH-1:0];
    logic [PTR_WIDTH:0]       ptr_r;

    // -------------------------------------------------
    // Fetch-time peek
    // -------------------------------------------------
    logic [PTR_WIDTH:0] ptr_eff;
    assign ptr_eff = recover ? recover_ptr : ptr_r;
    assign peek_rdy  = (ptr_eff > 0);
    assign peek_addr = peek_rdy ? stack[ptr_eff[PTR_WIDTH-1:0] - 1'b1] : '0;

    // Ready signals for Predecode-time mutation
    assign push_rdy = (ptr_r < DEPTH[PTR_WIDTH:0]);
    assign pop_rdy  = (ptr_r > 0);

    assign ptr = ptr_r;

    // -------------------------------------------------
    // Sequential state update (Predecode / recover only)
    // -------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            ptr_r <= '0;
            for (int i = 0; i < DEPTH; i++) begin
                stack[i] <= '0;
            end
        end else if (recover) begin
            // Restore pointer from FTQ checkpoint
            ptr_r <= recover_ptr;
        end else if (push && push_rdy) begin
            // CALL
            stack[ptr_r[PTR_WIDTH-1:0]] <= push_addr;
            ptr_r <= ptr_r + 1'b1;
        end else if (pop && pop_rdy) begin
            // RET (consume)
            ptr_r <= ptr_r - 1'b1;
        end
    end

endmodule
