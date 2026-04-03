import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

// Predecoder - combinational on imem_rec_packet
// JALR rd=x1/x5 = CALL, JALR rd=x0 rs1=x1/x5 = RET, else JUMP.
module predecode (
    input  logic [CPU_INST_BITS-1:0] inst,
    output logic                     is_branch,
    output logic [1:0]               btype
);
    logic [6:0] opcode;
    logic [4:0] rd, rs1;
    assign opcode = inst[6:0];
    assign rd     = inst[11:7];
    assign rs1    = inst[19:15];

    always_comb begin
        is_branch = 1'b0;
        btype     = BRANCH_COND;
        unique casez (opcode)
            OPC_BRANCH: begin 
                is_branch = 1'b1; 
                btype = BRANCH_COND; 
            end
            OPC_JAL: begin
                is_branch = 1'b1;
                btype = (rd == 5'd1 || rd == 5'd5) ? BRANCH_CALL : BRANCH_JUMP;
            end
            OPC_JALR: begin
                is_branch = 1'b1;
                if (rd == 5'd0 && (rs1 == 5'd1 || rs1 == 5'd5))
                    btype = BRANCH_RET;
                else if (rd == 5'd1 || rd == 5'd5)
                    btype = BRANCH_CALL;
                else
                    btype = BRANCH_JUMP;
            end
            default: ;
        endcase
    end
endmodule
