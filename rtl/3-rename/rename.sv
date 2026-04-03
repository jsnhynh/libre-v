/*
 * Rename Stage
 *
 * This module performs register renaming for N instructions:
 * 1. PRF Read: Reads the status of source operands (rs1, rs2) for N instructions.
 * 2. ROB Allocation: Requests and is granted new tags from the ROB.
 * 3. PRF (RAT) Write: Writes the new speculative mappings (rd -> rob_tag) to the PRF.
 * 4. Dependency Forwarding: Resolves intra-group dependencies (e.g., inst1 depends on inst0).
 * 5. ROB Bypass: Forwards results from completed but uncommitted ROB entries.
 * 6. Commit Bypass: Detects same-cycle commit-rename hazards and bypasses committed data.
 * 7. Compaction: Ensures a single valid instruction is always in slot 0 for dispatch.
 *
 * Output is combinational - pipeline register lives in RS entries (via Dispatch).
 * ROB entry writes happen in Dispatch using reserved tags.
 *
 * Bypass Priority (highest to lowest):
 *   1. Intra-group forwarding (inst[0].rd -> inst[1].rs)
 *   2. ROB bypass (completed but not committed)
 *   3. Commit bypass (committing this cycle)
 *   4. PRF read (already committed)
 */
import riscv_isa_pkg::*;
import uarch_pkg::*;

module rename (
    input logic clk, rst, flush,

    // Ports from Decode
    output logic                    rename_rdy,
    input  instruction_t            decoded_insts       [PIPE_WIDTH-1:0],

    // Ports to Dispatch
    input  logic                    dispatch_rdy,
    output instruction_t            renamed_insts       [PIPE_WIDTH-1:0],

    // Ports to/from ROB (allocation)
    output logic [PIPE_WIDTH-1:0]   rob_alloc_req,
    input  logic [PIPE_WIDTH-1:0]   rob_alloc_gnt,
    input  logic [TAG_WIDTH-1:0]    rob_alloc_tags      [PIPE_WIDTH-1:0],

    // Ports from ROB (commit)
    input  prf_commit_write_port_t  commit_write_ports  [PIPE_WIDTH-1:0],

    // Ports from ROB (bypass)
    input  rob_entry_t              rob_entries_bypass  [ROB_ENTRIES-1:0]
);

    //-------------------------------------------------------------
    // Internal Wires and Connections
    //-------------------------------------------------------------
    source_t                rs1_read_ports  [PIPE_WIDTH-1:0];
    source_t                rs2_read_ports  [PIPE_WIDTH-1:0];
    prf_rat_write_port_t    rat_write_ports [PIPE_WIDTH-1:0];
    logic [$clog2(ARCH_REGS)-1:0] prf_rs1   [PIPE_WIDTH-1:0];
    logic [$clog2(ARCH_REGS)-1:0] prf_rs2   [PIPE_WIDTH-1:0];

    assign prf_rs1[0] = decoded_insts[0].src_1_a.tag[$clog2(ARCH_REGS)-1:0];
    assign prf_rs1[1] = decoded_insts[1].src_1_a.tag[$clog2(ARCH_REGS)-1:0];
    assign prf_rs2[0] = decoded_insts[0].src_1_b.tag[$clog2(ARCH_REGS)-1:0];
    assign prf_rs2[1] = decoded_insts[1].src_1_b.tag[$clog2(ARCH_REGS)-1:0];

    prf prf_inst (
        .clk(clk),
        .rst(rst),
        .flush(flush),

        .rs1(prf_rs1),
        .rs2(prf_rs2),
        .rs1_read_ports(rs1_read_ports),
        .rs2_read_ports(rs2_read_ports),

        .rat_write_ports(rat_write_ports),
        
        .commit_write_ports(commit_write_ports)
    );

    //-------------------------------------------------------------
    // ROB Bypass Logic
    // Check if the tag has a completed result in the ROB
    //-------------------------------------------------------------
    function automatic source_t apply_rob_bypass(
        input source_t src,
        input rob_entry_t rob [ROB_ENTRIES-1:0]
    );
        source_t result = src;
        
        if (src.is_renamed) begin
            // Index ROB directly by tag
            if (rob[src.tag].is_valid && rob[src.tag].is_ready) begin
                result.is_renamed = 1'b0;
                result.data = rob[src.tag].result;
                result.tag = '0;
            end
        end
        
        return result;
    endfunction

    //-------------------------------------------------------------
    // Commit Bypass Logic
    //-------------------------------------------------------------
    function automatic source_t apply_commit_bypass(
        input source_t src,
        input prf_commit_write_port_t commit_ports [PIPE_WIDTH-1:0]
    );
        source_t result = src;
        
        if (src.is_renamed) begin
            for (int c = 0; c < PIPE_WIDTH; c++) begin
                if (commit_ports[c].we && commit_ports[c].tag == src.tag) begin
                    result.is_renamed = 1'b0;
                    result.data = commit_ports[c].data;
                    result.tag = '0;
                    break;
                end
            end
        end
        
        return result;
    endfunction

    //-------------------------------------------------------------
    // Renaming Function
    //-------------------------------------------------------------
    function automatic instruction_t rename_inst (
        input instruction_t d_inst,
        input source_t rs1_port,
        input source_t rs2_port,
        input logic [TAG_WIDTH-1:0] new_tag,
        input logic                 alloc_gnt
    );
        instruction_t r_inst;
        
        r_inst = '{default:'0};
        r_inst.is_valid = alloc_gnt && d_inst.is_valid;

        // Pass-through fields from decode
        r_inst.pc           = d_inst.pc;
        r_inst.rd           = d_inst.rd;
        r_inst.has_rd       = d_inst.has_rd;
        //r_inst.br_taken     = d_inst.br_taken;
        r_inst.opcode       = d_inst.opcode;
        r_inst.funct7       = d_inst.funct7;
        r_inst.uop_0        = d_inst.uop_0;
        r_inst.uop_1        = d_inst.uop_1;

        // New field added by rename
        r_inst.dest_tag     = new_tag;

        // Source 0 (ALU operand A): PC or RS1
        if ((d_inst.src_0_a.tag == d_inst.src_1_a.tag) && 
            (d_inst.opcode != OPC_LUI) &&
            (d_inst.opcode != OPC_AUIPC) &&
            (d_inst.opcode != OPC_JAL) &&
            (d_inst.opcode != OPC_BRANCH))
        begin
            r_inst.src_0_a.data         = (rs1_port.is_renamed)? '0:rs1_port.data;
            r_inst.src_0_a.tag          = rs1_port.tag;
            r_inst.src_0_a.is_renamed   = rs1_port.is_renamed;
        end else begin
            r_inst.src_0_a.data = d_inst.src_0_a.data;
        end

        // Source 0 (ALU operand B): IMM or RS2
        if ((d_inst.src_0_b.tag == d_inst.src_1_b.tag) && (d_inst.opcode == OPC_ARI_RTYPE)) begin
            r_inst.src_0_b.data         = (rs2_port.is_renamed)? '0:rs2_port.data;
            r_inst.src_0_b.tag          = rs2_port.tag;
            r_inst.src_0_b.is_renamed   = rs2_port.is_renamed;
        end else begin
            r_inst.src_0_b.data = d_inst.src_0_b.data;
        end

        // Source 1 (always register values for branches/stores)
        r_inst.src_1_a.data         = (rs1_port.is_renamed)? '0:rs1_port.data;
        r_inst.src_1_a.tag          = rs1_port.tag;
        r_inst.src_1_a.is_renamed   = rs1_port.is_renamed;

        r_inst.src_1_b.data         = (rs2_port.is_renamed)? '0:rs2_port.data;
        r_inst.src_1_b.tag          = rs2_port.tag;
        r_inst.src_1_b.is_renamed   = rs2_port.is_renamed;

        return r_inst;
    endfunction

    //-------------------------------------------------------------
    // Combinational Renaming Logic
    //-------------------------------------------------------------
    instruction_t renamed_tmp     [PIPE_WIDTH-1:0];
    instruction_t renamed_fwd     [PIPE_WIDTH-1:0];
    instruction_t renamed_compact [PIPE_WIDTH-1:0];
    instruction_t renamed_robbyp  [PIPE_WIDTH-1:0];
    logic all_gnts_ok;

    always_comb begin
        rob_alloc_req[0] = decoded_insts[0].is_valid;
        rob_alloc_req[1] = decoded_insts[1].is_valid;
        all_gnts_ok = ((rob_alloc_req & ~rob_alloc_gnt) == '0);

        // Step 1: Initial renaming
        renamed_tmp[0] = rename_inst(decoded_insts[0], rs1_read_ports[0], rs2_read_ports[0], 
                                     rob_alloc_tags[0], decoded_insts[0].is_valid && all_gnts_ok);
        renamed_tmp[1] = rename_inst(decoded_insts[1], rs1_read_ports[1], rs2_read_ports[1], 
                                     rob_alloc_tags[1], decoded_insts[1].is_valid && all_gnts_ok);

        // Step 2: Intra-group forwarding for inst[1]
        renamed_fwd[0] = renamed_tmp[0];
        renamed_fwd[1] = renamed_tmp[1];

        // inst[0].rd -> inst[1].rs1?
        if (decoded_insts[0].is_valid && rob_alloc_gnt[0] && decoded_insts[0].has_rd && 
            (decoded_insts[1].src_1_a.tag[$clog2(ARCH_REGS)-1:0] == decoded_insts[0].rd) && 
            (decoded_insts[0].rd != 0)) 
        begin
            renamed_fwd[1].src_1_a.is_renamed = 1'b1;
            renamed_fwd[1].src_1_a.tag        = rob_alloc_tags[0];
        end

        // inst[0].rd -> inst[1].rs2?
        if (decoded_insts[0].is_valid && rob_alloc_gnt[0] && decoded_insts[0].has_rd && 
            (decoded_insts[1].src_1_b.tag[$clog2(ARCH_REGS)-1:0] == decoded_insts[0].rd) && 
            (decoded_insts[0].rd != 0)) 
        begin
            renamed_fwd[1].src_1_b.is_renamed = 1'b1;
            renamed_fwd[1].src_1_b.tag        = rob_alloc_tags[0];
        end

        // Step 3: Pass-through to src_0 where needed
        for (int i = 0; i < PIPE_WIDTH; i++) begin
            // src_0_a mirrors src_1_a for most ALU ops
            if ((decoded_insts[i].src_0_a.tag == decoded_insts[i].src_1_a.tag) &&
                (decoded_insts[i].opcode != OPC_AUIPC) && 
                (decoded_insts[i].opcode != OPC_LUI) &&
                (decoded_insts[i].opcode != OPC_JAL) &&
                (decoded_insts[i].opcode != OPC_BRANCH)) 
            begin
                renamed_fwd[i].src_0_a = renamed_fwd[i].src_1_a;
            end

            // src_0_b mirrors src_1_b for R-type only
            if ((decoded_insts[i].src_0_b.tag == decoded_insts[i].src_1_b.tag) &&
                (decoded_insts[i].opcode == OPC_ARI_RTYPE)) 
            begin
                renamed_fwd[i].src_0_b = renamed_fwd[i].src_1_b;
            end
        end

        // Step 4: Compaction for dispatch output (move inst[1] to slot 0 if inst[0] invalid)
        if (!renamed_fwd[0].is_valid && renamed_fwd[1].is_valid) begin
            renamed_compact[0] = renamed_fwd[1];
            renamed_compact[1] = '{default:'0};
        end else begin
            renamed_compact[0] = renamed_fwd[0];
            renamed_compact[1] = renamed_fwd[1];
        end
    end

    //-------------------------------------------------------------
    // ROB Bypass + Commit Bypass (applied to final output)
    // Priority: ROB bypass first, then commit bypass
    //-------------------------------------------------------------
    always_comb begin
        renamed_robbyp[0] = renamed_compact[0];
        renamed_robbyp[1] = renamed_compact[1];
        renamed_insts[0] = renamed_compact[0];
        renamed_insts[1] = renamed_compact[1];
        
        // Apply ROB bypass first (completed but not committed)
        if (renamed_compact[0].is_valid) begin
            renamed_robbyp[0].src_0_a = apply_rob_bypass(renamed_compact[0].src_0_a, rob_entries_bypass);
            renamed_robbyp[0].src_0_b = apply_rob_bypass(renamed_compact[0].src_0_b, rob_entries_bypass);
            renamed_robbyp[0].src_1_a = apply_rob_bypass(renamed_compact[0].src_1_a, rob_entries_bypass);
            renamed_robbyp[0].src_1_b = apply_rob_bypass(renamed_compact[0].src_1_b, rob_entries_bypass);
        end
        
        if (renamed_compact[1].is_valid) begin
            renamed_robbyp[1].src_0_a = apply_rob_bypass(renamed_compact[1].src_0_a, rob_entries_bypass);
            renamed_robbyp[1].src_0_b = apply_rob_bypass(renamed_compact[1].src_0_b, rob_entries_bypass);
            renamed_robbyp[1].src_1_a = apply_rob_bypass(renamed_compact[1].src_1_a, rob_entries_bypass);
            renamed_robbyp[1].src_1_b = apply_rob_bypass(renamed_compact[1].src_1_b, rob_entries_bypass);
        end
        
        // Then apply commit bypass (committing this cycle)
        if (renamed_robbyp[0].is_valid) begin
            renamed_insts[0].src_0_a = apply_commit_bypass(renamed_robbyp[0].src_0_a, commit_write_ports);
            renamed_insts[0].src_0_b = apply_commit_bypass(renamed_robbyp[0].src_0_b, commit_write_ports);
            renamed_insts[0].src_1_a = apply_commit_bypass(renamed_robbyp[0].src_1_a, commit_write_ports);
            renamed_insts[0].src_1_b = apply_commit_bypass(renamed_robbyp[0].src_1_b, commit_write_ports);
        end
        
        if (renamed_robbyp[1].is_valid) begin
            renamed_insts[1].src_0_a = apply_commit_bypass(renamed_robbyp[1].src_0_a, commit_write_ports);
            renamed_insts[1].src_0_b = apply_commit_bypass(renamed_robbyp[1].src_0_b, commit_write_ports);
            renamed_insts[1].src_1_a = apply_commit_bypass(renamed_robbyp[1].src_1_a, commit_write_ports);
            renamed_insts[1].src_1_b = apply_commit_bypass(renamed_robbyp[1].src_1_b, commit_write_ports);
        end
    end

    //-------------------------------------------------------------
    // RAT Write Ports (update PRF mappings)
    //-------------------------------------------------------------
    assign rat_write_ports[0].addr = decoded_insts[0].rd;
    assign rat_write_ports[0].tag  = rob_alloc_tags[0];
    assign rat_write_ports[0].we   = decoded_insts[0].is_valid && rob_alloc_gnt[0] && 
                                     decoded_insts[0].has_rd && rename_rdy;

    assign rat_write_ports[1].addr = decoded_insts[1].rd;
    assign rat_write_ports[1].tag  = rob_alloc_tags[1];
    assign rat_write_ports[1].we   = decoded_insts[1].is_valid && rob_alloc_gnt[1] && 
                                     decoded_insts[1].has_rd && rename_rdy;

    //-------------------------------------------------------------
    // Handshake
    //-------------------------------------------------------------
    assign rename_rdy = dispatch_rdy && all_gnts_ok;

endmodule
