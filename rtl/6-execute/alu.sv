import riscv_isa_pkg::*;
import uarch_pkg::*;

module alu (
    input  logic clk, rst, flush,

    output logic                alu_rdy,
    input  instruction_t        alu_packet,
    
    output writeback_packet_t   alu_result,
    input  logic                alu_cdb_gnt
);
    instruction_t alu_packet_q;
    writeback_packet_t alu_result_d, alu_result_q;
    
    logic adv_inp_reg;
    logic adv_out_reg;
    
    // Output advances when empty OR granted
    assign adv_out_reg = ~alu_result_q.is_valid || alu_cdb_gnt;
    
    // Input advances when empty OR output advancing
    assign adv_inp_reg = ~alu_packet_q.is_valid || adv_out_reg;
    
    assign alu_rdy = adv_inp_reg;
    
    // Input register
    REGISTER_R_CE #(.N($bits(instruction_t))) alu_packet_reg_i (
        .q(alu_packet_q),
        .d(alu_packet),
        .clk(clk),
        .rst(rst || flush),
        .ce(adv_inp_reg)
    );
    
    // Output register
    REGISTER_R_CE #(.N($bits(writeback_packet_t))) alu_result_reg_o (
        .q(alu_result_q),
        .d(alu_result_d),
        .clk(clk),
        .rst(rst || flush),
        .ce(adv_out_reg)
    );
    
    // Drive output from register
    assign alu_result = alu_result_q;

    logic [CPU_DATA_BITS-1:0] a, b;
    logic [CPU_DATA_BITS-1:0] rs1, rs2;

    assign a    = alu_packet_q.src_0_a.data;
    assign b    = alu_packet_q.src_0_b.data;
    assign rs1  = alu_packet_q.src_1_a.data;
    assign rs2  = alu_packet_q.src_1_b.data;

    always_comb begin
        alu_result_d = '{default:0};
        alu_result_d.dest_tag   = alu_packet_q.dest_tag;
        alu_result_d.is_valid   = alu_packet_q.is_valid;

        if (alu_packet_q.is_valid) begin
            casez (alu_packet_q.uop_0)
                FNC_ADD_SUB:    alu_result_d.result = (alu_packet_q.funct7[5])? (a - b) : (a + b);
                FNC_SLL:        alu_result_d.result = a << b[4:0];
                FNC_SLT:        alu_result_d.result = {31'b0, $signed(a) < $signed(b)};
                FNC_SLTU:       alu_result_d.result = {31'b0, a < b};
                FNC_XOR:        alu_result_d.result = a ^ b;
                FNC_SRL_SRA:    alu_result_d.result = (alu_packet_q.funct7[5])? $signed($signed(a) >>> b[4:0]) : (a >> b[4:0]);
                FNC_OR:         alu_result_d.result = a | b;
                FNC_AND:        alu_result_d.result = a & b;
                default:        alu_result_d = '{default:0};
            endcase

            if (alu_packet_q.opcode == OPC_BRANCH) begin
                casez (alu_packet_q.uop_1)
                    FNC_BEQ:    alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], rs1 == rs2};
                    FNC_BNE:    alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], rs1 != rs2};
                    FNC_BLT:    alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], $signed(rs1) < $signed(rs2)};
                    FNC_BGE:    alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], $signed(rs1) >= $signed(rs2)};
                    FNC_BLTU:   alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], rs1 < rs2};
                    FNC_BGEU:   alu_result_d.result = {alu_result_d.result[CPU_DATA_BITS-1:1], rs1 >= rs2};
                    default:    alu_result_d.result = alu_result_d.result;
                endcase     
            end       
        end
    end

endmodule
