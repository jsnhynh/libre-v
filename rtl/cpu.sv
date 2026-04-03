/*
    2-Wide, OoO RV32IM CPU

    This module is the top level module that 
    encapsulates the processing logic and the 
    memory.

    By default, a simple memory model is 
    configured comprised of registers.
*/
import riscv_isa_pkg::*;
import uarch_pkg::*;

module cpu #(parameter TEST_FILE = "rv32im_test.hex", parameter SIMPLE_MEM_MODE = 1) (input clk, rst);
    logic                       imem_req_rdy;
    logic                       imem_req_val;
    logic [CPU_ADDR_BITS-1:0]   imem_req_packet;

    logic                       imem_rec_rdy;
    logic                       imem_rec_val;
    logic [FETCH_WIDTH*CPU_INST_BITS-1:0]    imem_rec_packet;

    logic                       dmem_req_rdy;
    instruction_t               dmem_req_packet;

    logic                       dmem_rec_rdy;
    writeback_packet_t          dmem_rec_packet;

    core core0 (
        .clk(clk),
        .rst(rst),
        // IMEM Ports
        .imem_req_rdy(imem_req_rdy),
        .imem_req_val(imem_req_val),
        .imem_req_packet(imem_req_packet),
        .imem_rec_rdy(imem_rec_rdy),
        .imem_rec_val(imem_rec_val),
        .imem_rec_packet(imem_rec_packet),
        // DMEM Ports
        .dmem_req_rdy(dmem_req_rdy),
        .dmem_req_packet(dmem_req_packet),
        .dmem_rec_rdy(dmem_rec_rdy),
        .dmem_rec_packet(dmem_rec_packet)
    );

    generate
        if (SIMPLE_MEM_MODE) begin : gen_simple_mem
            mem_simple #(.IMEM_HEX_FILE(TEST_FILE)) mem (
                .clk(clk),
                .rst(rst),
                // IMEM Ports
                .imem_req_rdy(imem_req_rdy),
                .imem_req_val(imem_req_val),
                .imem_req_packet(imem_req_packet),
                .imem_rec_rdy(imem_rec_rdy),
                .imem_rec_val(imem_rec_val),
                .imem_rec_packet(imem_rec_packet),
                // DMEM Ports
                .dmem_req_rdy(dmem_req_rdy),
                .dmem_req_packet(dmem_req_packet),
                .dmem_rec_rdy(dmem_rec_rdy),
                .dmem_rec_packet(dmem_rec_packet)
            );
        end else begin : gen_cache_mem
            // TODO: Cache System Goes Here
        end
    endgenerate

endmodule
