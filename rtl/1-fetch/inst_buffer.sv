import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

/* Instruction Buffer */

module inst_buffer (
    input  logic clk, rst, flush,

    // From fetch
    input  logic [CPU_ADDR_BITS-1:0]                pc,
    input  logic [FETCH_WIDTH-1:0]                  pc_vals,
    input  logic [FETCH_WIDTH*CPU_INST_BITS-1:0]    imem_rec_packet,
    input  logic                                    imem_rec_val,
    output logic                                    inst_buffer_rdy,

    // To decoder
    input  logic                                    decode_rdy,
    output logic [CPU_ADDR_BITS-1:0]                inst_pcs [PIPE_WIDTH-1:0],
    output logic [CPU_INST_BITS-1:0]                insts    [PIPE_WIDTH-1:0],
    output logic [FETCH_WIDTH-1:0]                  fetch_vals
);

    typedef struct packed {
        logic [CPU_ADDR_BITS-1:0]             pc;
        logic [FETCH_WIDTH-1:0]               pc_vals;
        logic [FETCH_WIDTH*CPU_INST_BITS-1:0] insts;
    } ib_entry_t;

    localparam DEPTH_W = $clog2(INST_BUF_DEPTH);

    ib_entry_t          buff  [INST_BUF_DEPTH-1:0];
    logic [DEPTH_W-1:0] rd_ptr, wr_ptr;
    logic [DEPTH_W:0]   count;

    logic is_full, is_empty;
    assign is_full         = (count == (DEPTH_W+1)'(INST_BUF_DEPTH));
    assign is_empty        = (count == '0);
    assign inst_buffer_rdy = ~is_full || flush;

    logic do_write, do_read;
    assign do_write = imem_rec_val && ~is_full  && ~flush;
    assign do_read  = decode_rdy   && ~is_empty && ~flush;

    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr <= '0;
            wr_ptr <= '0;
            count  <= '0;
            buff   <= '{default:'0};
        end else if (flush) begin
            rd_ptr <= '0;
            wr_ptr <= '0;
            count  <= '0;
        end else begin
            if (do_write) begin
                buff[wr_ptr] <= '{pc: pc, pc_vals: pc_vals, insts: imem_rec_packet};
                wr_ptr <= (wr_ptr == DEPTH_W'(INST_BUF_DEPTH-1)) ? '0 : wr_ptr + 1'b1;
            end
            if (do_read)
                rd_ptr <= (rd_ptr == DEPTH_W'(INST_BUF_DEPTH-1)) ? '0 : rd_ptr + 1'b1;
            unique case ({do_write, do_read})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: ;
            endcase
        end
    end

    always_comb begin
        if (!is_empty && !flush) begin
            insts[0]    = buff[rd_ptr].insts[CPU_INST_BITS-1:0];
            insts[1]    = buff[rd_ptr].insts[FETCH_WIDTH*CPU_INST_BITS-1:CPU_INST_BITS];
            inst_pcs[0] = buff[rd_ptr].pc;
            inst_pcs[1] = buff[rd_ptr].pc + CPU_ADDR_BITS'(4);
            fetch_vals  = buff[rd_ptr].pc_vals;
        end else begin
            insts[0]    = '0;
            insts[1]    = '0;
            inst_pcs[0] = '0;
            inst_pcs[1] = '0;
            fetch_vals  = '0;
        end
    end

endmodule
