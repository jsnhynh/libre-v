/*
    Execute Stage - Execute Unit

    This module encapsulates all Functional Units
    2 ALU: REG'd IN/OUT
    1 MEM: Arbitrates Memory Access / StoreToLoad Forwards, REG'd IN/OUT
    1 AGU: Writes back to LSQ combinationally, REG'd IN
    1 MDU: REG'd IN/OUT
*/

import riscv_isa_pkg::*;
import uarch_pkg::*;
module execute (
    input  logic clk, rst, flush,

    // Ports from Issue
    output logic [NUM_FU-1:0]   fu_rdys,
    input  instruction_t        fu_packets      [NUM_FU-1:0],

    // CDB Ports
    output writeback_packet_t   fu_results      [NUM_FU-1:0],
    input  logic                fu_cdb_gnts     [NUM_FU-1:0],

    // AGU Writeback
    output writeback_packet_t   agu_result,

    // Memory Interface
    output logic                dmem_rec_rdy,       // Backpressure to memory
    input  writeback_packet_t   dmem_rec_packet,    // From DMEM
    input  writeback_packet_t   forward_pkt         // Store-to-load forward
);
    //-------------------------------------------------------------
    // ALU_0/1                                                (0/1)
    //-------------------------------------------------------------
    generate
        for (genvar i = 0; i < 2; i++) begin : gen_alu
            alu alu_inst (
                .clk(clk),
                .rst(rst),
                .flush(flush),
                // In
                .alu_rdy(fu_rdys[i]),
                .alu_packet(fu_packets[i]),
                // Output
                .alu_result(fu_results[i]),
                .alu_cdb_gnt(fu_cdb_gnts[i])
            );
        end
    endgenerate

    //-------------------------------------------------------------
    // MEM (Mux + Output Register)                            (2)
    //-------------------------------------------------------------
    writeback_packet_t mem_result_d;
    logic mem_adv_out_reg;
    
    // Mux: Select between dmem response and store-to-load forward
    // LSQ guarantees only one is valid at a time
    always_comb begin
        if (forward_pkt.is_valid) begin
            mem_result_d = forward_pkt;
        end else begin
            mem_result_d = dmem_rec_packet;
        end
    end
    
    // Output register advances when empty OR CDB grants
    assign mem_adv_out_reg = ~fu_results[2].is_valid || fu_cdb_gnts[2];
    
    // Output register (holds result until CDB grant)
    REGISTER_R_CE #(.N($bits(writeback_packet_t))) mem_result_reg (
        .q(fu_results[2]),
        .d(mem_result_d),
        .clk(clk),
        .rst(rst || flush),
        .ce(mem_adv_out_reg)
    );
        
    // Backpressure to memory: ready when output register can accept new data
    assign dmem_rec_rdy = mem_adv_out_reg;
    
    // Ready to issue: when output register can accept (same as dmem_rec_rdy)
    // Note: forward_pkt doesn't need backpressure (LSQ controls timing)
    assign fu_rdys[2] = mem_adv_out_reg;

    //-------------------------------------------------------------
    // AGU                                                      (3)
    //-------------------------------------------------------------
    agu agu_inst (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .agu_packet(fu_packets[3]),
        .agu_result(agu_result)
    );
    assign fu_results[3] = '{default:'0}; // AGU doesnt write to CDB
    assign fu_rdys[3] = 1'b1; // AGU has no backpressure (always ready)

    //-------------------------------------------------------------
    // MDU                                                      (4)
    //-------------------------------------------------------------
    // TODO: Add MDU instantiation

    mdu mdu_inst (
    .clk(clk), 
    .rst(rst), 
    .flush(flush),
    .mdu_rdy(fu_rdys[4]),
    .mdu_packet(fu_packets[4]),
    .mdu_result(fu_results[4]),
    .mdu_cdb_gnt(fu_cdb_gnts[4])
);

    //assign fu_results[4] = '{default:'0};
    //assign fu_rdys[4] = 1'b0;

endmodule
