/*
 * Physical Register File (PRF) with Integrated Renaming Logic
 *
 * This module is the central store for both committed architectural data and
 * speculative register mappings (tags). It implements an area-efficient PRF
 * architecture.
 *
 * It features:
 * - 4 Asynchronous Read Ports (for Rename stage)
 * - 2 Synchronous RAT Write Ports (for Rename stage)
 * - 2 Synchronous Data Write Ports (for Commit stage)
 */

import riscv_isa_pkg::*;
import uarch_pkg::*;

module prf (
    // Module I/O
    input logic clk, rst, flush,

    //-------------------------------------------------------------
    // RENAME STAGE PORTS (4 READ, 2 TAG WRITE)
    //-------------------------------------------------------------
    // Read Ports
    input  logic [$clog2(ARCH_REGS)-1:0]    rs1                 [PIPE_WIDTH-1:0],
    input  logic [$clog2(ARCH_REGS)-1:0]    rs2                 [PIPE_WIDTH-1:0],
    output source_t                         rs1_read_ports      [PIPE_WIDTH-1:0],
    output source_t                         rs2_read_ports      [PIPE_WIDTH-1:0],

    // Tag Write Ports
    input  prf_rat_write_port_t             rat_write_ports     [PIPE_WIDTH-1:0],

    //-------------------------------------------------------------
    // COMMIT STAGE PORTS (2 DATA WRITE)
    //-------------------------------------------------------------
    input  prf_commit_write_port_t          commit_write_ports  [PIPE_WIDTH-1:0]
);

    // Internal storage for the PRF
    logic [CPU_DATA_BITS-1:0]   data_reg    [ARCH_REGS-1:0];
    logic [TAG_WIDTH-1:0]       tag_reg     [ARCH_REGS-1:0];
    logic                       renamed_reg [ARCH_REGS-1:0];

    //-------------------------------------------------------------
    // READ LOGIC (Asynchronous)
    //-------------------------------------------------------------
    assign rs1_read_ports[0] = '{data: data_reg[rs1[0]], tag: tag_reg[rs1[0]], is_renamed: renamed_reg[rs1[0]]};
    assign rs2_read_ports[0] = '{data: data_reg[rs2[0]], tag: tag_reg[rs2[0]], is_renamed: renamed_reg[rs2[0]]};
    assign rs1_read_ports[1] = '{data: data_reg[rs1[1]], tag: tag_reg[rs1[1]], is_renamed: renamed_reg[rs1[1]]};
    assign rs2_read_ports[1] = '{data: data_reg[rs2[1]], tag: tag_reg[rs2[1]], is_renamed: renamed_reg[rs2[1]]};

    //-------------------------------------------------------------
    // WRITE LOGIC (Synchronous)
    //-------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ARCH_REGS; i++) begin
                data_reg[i]    <= '0;
                renamed_reg[i] <= '0;
                tag_reg[i]     <= '0;
            end
        end else begin
            // --- Commit Stage Writes ---
            for (integer i = 0; i < PIPE_WIDTH; i++) begin
                if (commit_write_ports[i].we && commit_write_ports[i].addr != 0) begin
                    data_reg[commit_write_ports[i].addr] <= commit_write_ports[i].data;
                    if (renamed_reg[commit_write_ports[i].addr] && (tag_reg[commit_write_ports[i].addr] == commit_write_ports[i].tag)) begin
                        renamed_reg[commit_write_ports[i].addr] <= 1'b0;
                        tag_reg[commit_write_ports[i].addr]     <= '0;
                    end
                end
            end

            if (~flush) begin
                // --- Rename Stage Writes ---
                for (integer i = 0; i < PIPE_WIDTH; i++) begin
                    if (rat_write_ports[i].we && rat_write_ports[i].addr != 0) begin
                        tag_reg[rat_write_ports[i].addr]     <= rat_write_ports[i].tag;
                        renamed_reg[rat_write_ports[i].addr] <= 1'b1;
                    end
                end
            end else begin
                // --- Clear Renames ---
                for (int i = 0; i < ARCH_REGS; i++) begin
                    renamed_reg[i]  <= 1'b0;
                    tag_reg[i]      <= '0;
                end
            end

            
        end
    end

endmodule
