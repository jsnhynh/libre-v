/*
 * Generic Reservation Station (N inputs × M outputs)
 * 
 * Same-cycle wakeup: CDB data forwarded to entries_forwarded for wakeup and issue.
 * Prevents hazard where same entry is issued and re-allocated in same cycle.
 */

import riscv_isa_pkg::*;
import uarch_pkg::*;

module rs #(
    parameter int NUM_ENTRIES = 8,
    parameter int ISSUE_WIDTH = 2
) (
    input  logic clk, rst, flush,
    
    // Dispatch Interface
    output logic [PIPE_WIDTH-1:0]   rs_rdy,
    input  logic [PIPE_WIDTH-1:0]   rs_we,
    input  instruction_t            rs_entries_in [PIPE_WIDTH-1:0],
    
    // Issue Interface
    input  logic [ISSUE_WIDTH-1:0]  fu_rdy,
    output instruction_t            fu_packets [ISSUE_WIDTH-1:0],
    
    // Wakeup Interface
    input  writeback_packet_t       cdb_ports [PIPE_WIDTH-1:0],
    
    // Age tracking
    input  logic [TAG_WIDTH-1:0]    rob_head
);

    //-------------------------------------------------------------
    // RS Entries
    //-------------------------------------------------------------
    instruction_t entries      [NUM_ENTRIES-1:0];
    instruction_t entries_next [NUM_ENTRIES-1:0];

    //-------------------------------------------------------------
    // Data Capture from CDB
    //-------------------------------------------------------------
    
    function automatic source_t update_source(input source_t src);
        source_t result = src;
        
        // If not renamed, don't update
        if (!src.is_renamed) return result;
        
        // Check CDB ports for data
        for (int c = 0; c < PIPE_WIDTH; c++) begin
            if (cdb_ports[c].is_valid && cdb_ports[c].dest_tag == src.tag) begin
                result.data = cdb_ports[c].result;
                result.tag  = '0;
                result.is_renamed = '0;
            end
        end
        
        return result;
    endfunction

    //-------------------------------------------------------------
    // Forward CDB Data (separate from entries_next!)
    // This array has CDB data but is NOT affected by allocation/clear
    //-------------------------------------------------------------
    instruction_t entries_forwarded [NUM_ENTRIES-1:0];
    
    always_comb begin
        for (int e = 0; e < NUM_ENTRIES; e++) begin
            entries_forwarded[e] = entries[e];
            if (entries[e].is_valid) begin
                entries_forwarded[e].src_0_a = update_source(entries[e].src_0_a);
                entries_forwarded[e].src_0_b = update_source(entries[e].src_0_b);
                entries_forwarded[e].src_1_a = update_source(entries[e].src_1_a);
                entries_forwarded[e].src_1_b = update_source(entries[e].src_1_b);
            end
        end
    end

    //-------------------------------------------------------------
    // Wakeup Logic (read from entries_forwarded)
    //-------------------------------------------------------------
    logic [NUM_ENTRIES-1:0] entry_ready;
    
    always_comb begin
        for (int e = 0; e < NUM_ENTRIES; e++) begin
            entry_ready[e] = entries_forwarded[e].is_valid &&
                            (~entries_forwarded[e].src_0_a.is_renamed) &&
                            (~entries_forwarded[e].src_0_b.is_renamed) &&
                            (~entries_forwarded[e].src_1_a.is_renamed) &&
                            (~entries_forwarded[e].src_1_b.is_renamed);
        end
    end

    //-------------------------------------------------------------
    // Age Calculation (read from entries_forwarded)
    //-------------------------------------------------------------
    logic [TAG_WIDTH-1:0] entry_ages [NUM_ENTRIES-1:0];
    
    always_comb begin
        for (int e = 0; e < NUM_ENTRIES; e++) begin
            entry_ages[e] = entries_forwarded[e].dest_tag - rob_head;
        end
    end

    //-------------------------------------------------------------
    // Issue Selection
    //-------------------------------------------------------------
    logic [NUM_ENTRIES-1:0] issue_grants;
    int issue_indices [ISSUE_WIDTH-1:0];
    
    always_comb begin
        automatic logic [NUM_ENTRIES-1:0] used_mask = '0;
        issue_grants = '0;
        
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            automatic int oldest_idx = -1;
            automatic logic [TAG_WIDTH-1:0] oldest_age = '1;
            
            issue_indices[i] = -1;
            
            for (int e = 0; e < NUM_ENTRIES; e++) begin
                if (entry_ready[e] && !used_mask[e] && fu_rdy[i]) begin
                    if (entry_ages[e] < oldest_age) begin
                        oldest_age = entry_ages[e];
                        oldest_idx = e;
                    end
                end
            end
            
            if (oldest_idx >= 0) begin
                issue_grants[oldest_idx] = 1'b1;
                issue_indices[i] = oldest_idx;
                used_mask[oldest_idx] = 1'b1;
            end
        end
    end
    
    // Issue outputs - read from entries_forwarded (has CDB data, not overwritten!)
    always_comb begin
        for (int i = 0; i < ISSUE_WIDTH; i++) begin
            if (issue_indices[i] >= 0) begin
                fu_packets[i] = entries_forwarded[issue_indices[i]];
            end else begin
                fu_packets[i] = '{default: '0};
            end
        end
    end

    //-------------------------------------------------------------
    // Allocation Logic (read from entries, not entries_next)
    //-------------------------------------------------------------
    logic [NUM_ENTRIES-1:0] entry_free;
    logic [NUM_ENTRIES-1:0] entry_reallocated;
    logic [PIPE_WIDTH-1:0] can_allocate;
    int alloc_indices [PIPE_WIDTH-1:0];

    // Entry is free if: (1) currently invalid, OR (2) being issued this cycle
    always_comb begin
        for (int i = 0; i < NUM_ENTRIES; i++) begin
            entry_free[i] = ~entries[i].is_valid || issue_grants[i];
        end
    end

    always_comb begin
        automatic logic [NUM_ENTRIES-1:0] used_mask = '0;
        
        for (int d = 0; d < PIPE_WIDTH; d++) begin
            alloc_indices[d] = -1;
            can_allocate[d] = 0;
            
            for (int e = 0; e < NUM_ENTRIES; e++) begin
                if (entry_free[e] && !used_mask[e]) begin
                    alloc_indices[d] = e;
                    can_allocate[d] = 1;
                    used_mask[e] = 1;
                    break;
                end
            end
        end
    end

    always_comb begin
        entry_reallocated = '0;
        for (int d = 0; d < PIPE_WIDTH; d++) begin
            if (rs_we[d] && can_allocate[d] && alloc_indices[d] >= 0) begin
                entry_reallocated[alloc_indices[d]] = 1'b1;
            end
        end
    end

    always_comb begin
        for (int d = 0; d < PIPE_WIDTH; d++) begin
            rs_rdy[d] = can_allocate[d];
        end
    end

    //-------------------------------------------------------------
    // RS Update Logic (for entries_next -> entries register)
    //-------------------------------------------------------------
    always_comb begin
        entries_next = entries;
        
        // Step 1: CDB capture
        for (int e = 0; e < NUM_ENTRIES; e++) begin
            if (entries_next[e].is_valid) begin
                entries_next[e].src_0_a = update_source(entries_next[e].src_0_a);
                entries_next[e].src_0_b = update_source(entries_next[e].src_0_b);
                entries_next[e].src_1_a = update_source(entries_next[e].src_1_a);
                entries_next[e].src_1_b = update_source(entries_next[e].src_1_b);
            end
        end
        
        // Step 2: Allocate new entries
        for (int d = 0; d < PIPE_WIDTH; d++) begin
            if (rs_we[d] && can_allocate[d] && alloc_indices[d] >= 0) begin
                entries_next[alloc_indices[d]] = rs_entries_in[d];

                // Forward CDB data to newly allocated entry
                if (entries_next[alloc_indices[d]].is_valid) begin
                    entries_next[alloc_indices[d]].src_0_a = update_source(entries_next[alloc_indices[d]].src_0_a);
                    entries_next[alloc_indices[d]].src_0_b = update_source(entries_next[alloc_indices[d]].src_0_b);
                    entries_next[alloc_indices[d]].src_1_a = update_source(entries_next[alloc_indices[d]].src_1_a);
                    entries_next[alloc_indices[d]].src_1_b = update_source(entries_next[alloc_indices[d]].src_1_b);
                end
            end
        end
        
        // Step 3: Clear issued entries (unless being re-allocated)
        for (int e = 0; e < NUM_ENTRIES; e++) begin
            if (issue_grants[e] && !entry_reallocated[e]) begin
                entries_next[e] = '{default:'0};
            end
        end
    end

    //-------------------------------------------------------------
    // Sequential Logic
    //-------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for (int e = 0; e < NUM_ENTRIES; e++) begin
                entries[e] <= '{default: '0};
                entries[e].is_valid <= '0;
            end
        end else begin
            entries <= entries_next;
        end
    end

endmodule
