/*
 * Dispatch Stage (with Compaction)
 *
 * This module is a purely combinational "switchyard" that routes renamed
 * instructions from the Rename stage to the correct backend issue queue
 * (ALU_RS, MDU_RS, or LSQ_RS).
 *
 * It has two parallel jobs:
 * 1. Arbitration: Checks for available slots in the issue queues.
 * 2. ROB Write: Writes the initial metadata (pc, rd, etc.) for each
 *               instruction into the Reorder Buffer.
 * It provides the final backpressure signal to the Rename stage.
 *
 * Compaction Logic:
 * - If inst[0] and inst[1] target the SAME RS:
 *   inst[0] → channel 0, inst[1] → channel 1
 * - If inst[0] and inst[1] target DIFFERENT RSs:
 *   inst[0] → channel 0 of its RS
 *   inst[1] → channel 0 of its RS
 */

import riscv_isa_pkg::*;
import uarch_pkg::*;

module dispatch (
    // Ports from Rename
    output logic                    dispatch_rdy,
    input  instruction_t            renamed_insts   [PIPE_WIDTH-1:0],

    // Ports to RS
    input  logic [PIPE_WIDTH-1:0]   rs_rdys         [NUM_RS-1:0],
    output logic [PIPE_WIDTH-1:0]   rs_wes          [NUM_RS-1:0],
    output instruction_t            rs_issue_ports  [NUM_RS-1:0][PIPE_WIDTH-1:0],

    // Ports to ROB
    input  logic [PIPE_WIDTH-1:0]   rob_rdy, // 00: 0 rdy, 01: 1 rdy, 10/11: 2+ rdy
    output logic [PIPE_WIDTH-1:0]   rob_we,
    output rob_entry_t              rob_entries     [PIPE_WIDTH-1:0]
);

    //-------------------------------------------------------------
    // Internal Logic
    //-------------------------------------------------------------
    logic [PIPE_WIDTH-1:0] is_alu;
    logic [PIPE_WIDTH-1:0] is_mdu;
    logic [PIPE_WIDTH-1:0] is_ld;
    logic [PIPE_WIDTH-1:0] is_st;
    logic is_alu_0, is_alu_1;
    logic is_ld_0,  is_ld_1;
    logic is_st_0,  is_st_1;
    logic is_mdu_0, is_mdu_1;
    logic can_dispatch_0;
    logic can_dispatch_1;
    logic rob_avail_for_inst1;
    logic rs_avail_for_inst0;
    logic rs_avail_for_inst1;
    logic same_rs;

    always_comb begin
        is_alu_0 = 1'b0;
        is_alu_1 = 1'b0;
        is_ld_0 = 1'b0;
        is_ld_1 = 1'b0;
        is_st_0 = 1'b0;
        is_st_1 = 1'b0;
        is_mdu_0 = 1'b0;
        is_mdu_1 = 1'b0;
        is_alu = '0;
        is_ld = '0;
        is_st = '0;
        is_mdu = '0;
        can_dispatch_0 = 1'b0;
        can_dispatch_1 = 1'b0;
        rob_avail_for_inst1 = 1'b0;
        rs_avail_for_inst0 = 1'b0;
        rs_avail_for_inst1 = 1'b0;
        same_rs = 1'b0;
        dispatch_rdy = 1'b0;
        rob_we = '0;

        for (int rs = 0; rs < NUM_RS; rs++) begin
            rs_wes[rs] = '0;
            for (int slot = 0; slot < PIPE_WIDTH; slot++) begin
                rs_issue_ports[rs][slot] = '{default:'0};
            end
        end

        // Classify both instructions.
        is_ld_0 = renamed_insts[0].is_valid && (renamed_insts[0].opcode == OPC_LOAD);
        is_st_0 = renamed_insts[0].is_valid && (renamed_insts[0].opcode == OPC_STORE);
        is_mdu_0 = renamed_insts[0].is_valid && (renamed_insts[0].opcode == OPC_ARI_RTYPE) &&
                   (renamed_insts[0].funct7 == FNC7_MULDIV);
        is_alu_0 = renamed_insts[0].is_valid && !is_ld_0 && !is_st_0 && !is_mdu_0;

        is_ld_1 = renamed_insts[1].is_valid && (renamed_insts[1].opcode == OPC_LOAD);
        is_st_1 = renamed_insts[1].is_valid && (renamed_insts[1].opcode == OPC_STORE);
        is_mdu_1 = renamed_insts[1].is_valid && (renamed_insts[1].opcode == OPC_ARI_RTYPE) &&
                   (renamed_insts[1].funct7 == FNC7_MULDIV);
        is_alu_1 = renamed_insts[1].is_valid && !is_ld_1 && !is_st_1 && !is_mdu_1;

        is_alu = {is_alu_1, is_alu_0};
        is_ld  = {is_ld_1,  is_ld_0};
        is_st  = {is_st_1,  is_st_0};
        is_mdu = {is_mdu_1, is_mdu_0};

        same_rs = renamed_insts[0].is_valid && renamed_insts[1].is_valid &&
                  ((is_alu_0 && is_alu_1) ||
                   (is_ld_0 && is_ld_1) ||
                   (is_st_0 && is_st_1) ||
                   (is_mdu_0 && is_mdu_1));

        rob_avail_for_inst1 = renamed_insts[0].is_valid ? rob_rdy[1] : rob_rdy[0];

        rs_avail_for_inst0 =
            (is_alu_0 && rs_rdys[0][0]) ||
            (is_ld_0  && rs_rdys[1][0]) ||
            (is_st_0  && rs_rdys[2][0]) ||
            (is_mdu_0 && rs_rdys[3][0]);

        if (!renamed_insts[1].is_valid) begin
            rs_avail_for_inst1 = 1'b1;
        end else if (is_alu_1) begin
            rs_avail_for_inst1 = same_rs ? rs_rdys[0][1] : rs_rdys[0][0];
        end else if (is_ld_1) begin
            rs_avail_for_inst1 = same_rs ? rs_rdys[1][1] : rs_rdys[1][0];
        end else if (is_st_1) begin
            rs_avail_for_inst1 = same_rs ? rs_rdys[2][1] : rs_rdys[2][0];
        end else if (is_mdu_1) begin
            rs_avail_for_inst1 = same_rs ? rs_rdys[3][1] : rs_rdys[3][0];
        end

        can_dispatch_0 = !renamed_insts[0].is_valid || (rob_rdy[0] && rs_avail_for_inst0);
        can_dispatch_1 = !renamed_insts[1].is_valid || (rob_avail_for_inst1 && rs_avail_for_inst1);
        dispatch_rdy = can_dispatch_0 && can_dispatch_1;

        // Route candidate payloads even when stalled so debug/TB can inspect them.
        rs_issue_ports[0][0] = is_alu_0 ? renamed_insts[0] : renamed_insts[1];
        rs_issue_ports[0][1] = renamed_insts[1];
        rs_issue_ports[1][0] = is_ld_0 ? renamed_insts[0] : renamed_insts[1];
        rs_issue_ports[1][1] = renamed_insts[1];
        rs_issue_ports[2][0] = is_st_0 ? renamed_insts[0] : renamed_insts[1];
        rs_issue_ports[2][1] = renamed_insts[1];
        rs_issue_ports[3][0] = is_mdu_0 ? renamed_insts[0] : renamed_insts[1];
        rs_issue_ports[3][1] = renamed_insts[1];

        rs_wes[0] = {
            dispatch_rdy && renamed_insts[1].is_valid && is_alu_1 && same_rs,
            dispatch_rdy && ((renamed_insts[0].is_valid && is_alu_0) ||
                             (renamed_insts[1].is_valid && is_alu_1 && !same_rs))
        };

        rs_wes[1] = {
            dispatch_rdy && renamed_insts[1].is_valid && is_ld_1 && same_rs,
            dispatch_rdy && ((renamed_insts[0].is_valid && is_ld_0) ||
                             (renamed_insts[1].is_valid && is_ld_1 && !same_rs))
        };

        rs_wes[2] = {
            dispatch_rdy && renamed_insts[1].is_valid && is_st_1 && same_rs,
            dispatch_rdy && ((renamed_insts[0].is_valid && is_st_0) ||
                             (renamed_insts[1].is_valid && is_st_1 && !same_rs))
        };

        rs_wes[3] = {
            dispatch_rdy && renamed_insts[1].is_valid && is_mdu_1 && same_rs,
            dispatch_rdy && ((renamed_insts[0].is_valid && is_mdu_0) ||
                             (renamed_insts[1].is_valid && is_mdu_1 && !same_rs))
        };

        rob_we = {dispatch_rdy && renamed_insts[1].is_valid, dispatch_rdy && renamed_insts[0].is_valid};
        rob_entries[0] = gen_rob_entry(renamed_insts[0]);
        rob_entries[1] = gen_rob_entry(renamed_insts[1]);
    end

    // ROB Entry Generation Function
    function automatic rob_entry_t gen_rob_entry (input instruction_t r_inst);
        rob_entry_t entry;
        entry = '{default:'0};
        entry.is_valid  = r_inst.is_valid;
        entry.is_ready  = 1'b0;
        entry.pc        = r_inst.pc;
        entry.rd        = r_inst.rd;
        entry.has_rd    = r_inst.has_rd;
        // Result is undetermined
        entry.exception = 1'b0;
        entry.opcode    = r_inst.opcode;
        return entry;
    endfunction

endmodule
