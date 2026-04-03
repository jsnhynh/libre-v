/* 
 * Decode Stage
 *
 * This module decodes two RISC-V instructions in parallel. It parses the
 * raw instruction bits from the instruction buffer, generates immediate
 * values, and creates all necessary control signals for the backend. It 
 * bundles this information into the instruction_t struct for the Rename 
 * stage.
 */

import riscv_isa_pkg::*;
import uarch_pkg::*;

module decode (
    input logic clk, rst, flush,

    // Ports from Fetch
    output logic                        decode_rdy,
    input  logic [CPU_ADDR_BITS-1:0]    inst_pcs    [PIPE_WIDTH-1:0],
    input  logic [CPU_INST_BITS-1:0]    insts       [PIPE_WIDTH-1:0],
    input  logic [PIPE_WIDTH-1:0]       fetch_vals,

    // Ports to Rename
    input  logic            rename_rdy,
    output instruction_t    decoded_insts [PIPE_WIDTH-1:0]
);

    //-------------------------------------------------------------
    // Immediate Generation Function
    //-------------------------------------------------------------
    function automatic logic [CPU_DATA_BITS-1:0] gen_imm(input logic [CPU_INST_BITS-1:0] inst);
        casez (inst[6:0])
            OPC_ARI_ITYPE, OPC_LOAD, OPC_JALR:  
                                return {{20{inst[31]}}, inst[31:20]};                               // I-type (+I*, +LOAD, +JALR)
            OPC_STORE:          return {{20{inst[31]}}, inst[31:25], inst[11:7]};                   // S-type
            OPC_BRANCH:         return {{20{inst[31]}}, inst[7], inst[30:25], inst[11:8], 1'b0};    // B-type
            OPC_LUI, OPC_AUIPC: return {inst[31:12], 12'b0};                                        // U-type (LUI/AUIPC)
            OPC_JAL:            return {{12{inst[31]}}, inst[19:12], inst[20], inst[30:21], 1'b0};  // J-type (JAL)
            default:            return '0;
        endcase
    endfunction

    function automatic instruction_t decode_inst (
        input logic [CPU_ADDR_BITS-1:0] pc,
        input logic [CPU_INST_BITS-1:0] inst,
        input logic                     val
    );
        logic [2:0] funct3 = inst[14:12];
        logic [4:0] rd  = inst[11:7];
        logic [4:0] rs1 = inst[19:15];
        logic [4:0] rs2 = inst[24:20];

        instruction_t d_inst;
        // Default values
        d_inst = '{default:'0};
        d_inst.pc       = pc;
        d_inst.opcode   = inst[6:0];

        casez (d_inst.opcode)
            OPC_STORE, OPC_BRANCH: 
                        d_inst.rd = '0;
            default:    d_inst.rd = rd;
        endcase

        casez (d_inst.opcode)
            OPC_AUIPC, OPC_JAL, OPC_LUI: 
                        d_inst.src_1_a.tag = '0;
            default:    d_inst.src_1_a.tag = rs1;
        endcase

        casez (d_inst.opcode)
            OPC_ARI_ITYPE, OPC_JAL, OPC_JALR, OPC_AUIPC, OPC_LUI: 
                        d_inst.src_1_b.tag = '0;
            default:    d_inst.src_1_b.tag = rs2;
        endcase

        casez (d_inst.opcode)  // Instructions are valid if sent from buffer and compliant opcode
            OPC_LUI, OPC_AUIPC, OPC_JAL, OPC_JALR, OPC_BRANCH, OPC_LOAD, OPC_STORE, OPC_ARI_ITYPE, OPC_ARI_RTYPE, OPC_CSR:
                        d_inst.is_valid = val;
            default:    d_inst.is_valid = '0;
        endcase
        
        casez (d_inst.opcode)
            OPC_LUI, OPC_AUIPC, OPC_JAL, OPC_JALR, OPC_LOAD, OPC_ARI_ITYPE, OPC_ARI_RTYPE: begin
                        d_inst.has_rd = 1'b1;
                        d_inst.rd = rd;
            end
            default:    d_inst.has_rd = 1'b0;
        endcase

        /* casez (d_inst.opcode)
            OPC_JAL, OPC_JALR: 
                        d_inst.br_taken = 1'b1;
            default:    d_inst.br_taken = 1'b0;

        endcase */

        casez (d_inst.opcode)
            OPC_AUIPC, OPC_JAL, OPC_BRANCH: 
                        d_inst.src_0_a.data = pc;   // Use PC as first operand
            OPC_LUI:    d_inst.src_0_a.data = '0;
            default:    d_inst.src_0_a.tag  = rs1;  // Use rs1
        endcase

        casez (d_inst.opcode)
            OPC_ARI_RTYPE:  
                        d_inst.src_0_b.tag  = rs2;              // Use rs2
            default:    d_inst.src_0_b.data = gen_imm(inst);    // Use immediate
        endcase

        casez (d_inst.opcode)
            OPC_ARI_RTYPE, OPC_ARI_ITYPE, OPC_LOAD, OPC_STORE:  
                        d_inst.uop_0    = funct3;
            default:    d_inst.uop_0    = FNC_ADD_SUB;
        endcase

        casez (d_inst.opcode)
            OPC_BRANCH: d_inst.uop_1 = funct3;
            default:    d_inst.uop_1 = '0;
        endcase

        casez (d_inst.opcode)
            OPC_ARI_RTYPE:                              d_inst.funct7   = inst[31:25];
            OPC_ARI_ITYPE:  if (funct3 == FNC_SRL_SRA)  d_inst.funct7   = inst[31:25];
            default:                                    d_inst.funct7   = '0;
        endcase
        
        return d_inst;
    endfunction

    //-------------------------------------------------------------
    // Handshake and Pipeline Control
    //-------------------------------------------------------------
    assign decode_rdy = rename_rdy;

    //-------------------------------------------------------------
    // Control Signal Generation
    //-------------------------------------------------------------
    instruction_t decoded_insts_next [PIPE_WIDTH-1:0];

    // Call the decoder function for each instruction path
    assign decoded_insts_next[0] = decode_inst(inst_pcs[0], insts[0], fetch_vals[0]);
    assign decoded_insts_next[1] = decode_inst(inst_pcs[1], insts[1], fetch_vals[1]);
    
    //-------------------------------------------------------------
    // Pipeline Register Logic
    //-------------------------------------------------------------
    always_ff @(posedge clk or posedge flush) begin
        if (rst || flush) begin
            decoded_insts[0] <= '{default:'0};
            decoded_insts[1] <= '{default:'0};
        end else if (decode_rdy) begin
            if (fetch_vals != '0) begin
                decoded_insts[0] <= decoded_insts_next[0];
                decoded_insts[1] <= decoded_insts_next[1];
            end else begin
                decoded_insts[0] <= '{default:'0};
                decoded_insts[1] <= '{default:'0};
            end
        end
    end

endmodule
