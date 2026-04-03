import riscv_isa_pkg::*;
import uarch_pkg::*;

module agu (
    input  logic clk, rst, flush,
    
    input  instruction_t        agu_packet,  // From LSQ
    
    output writeback_packet_t   agu_result   // Back to LSQ (combinational)
);
    instruction_t agu_packet_q;
        
    // Input register
    REGISTER_R #(.N($bits(instruction_t))) agu_packet_reg (
        .q(agu_packet_q),
        .d(agu_packet),
        .clk(clk),
        .rst(rst || flush)
    );
    
    // Combinational output (address calculation)
    always_comb begin
        agu_result.dest_tag  = agu_packet_q.dest_tag;
        agu_result.result    = agu_packet_q.src_0_a.data + agu_packet_q.src_0_b.data; // address
        agu_result.is_valid  = agu_packet_q.is_valid;
        agu_result.exception = 1'b0;
    end
endmodule
