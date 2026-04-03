/*
    Writeback Stage - CDB Arbiter
    
    Selects up to PIPE_WIDTH oldest instructions to broadcast.
    Uses iterative selection with masking.
*/

import riscv_isa_pkg::*;
import uarch_pkg::*;

module cdb (
    // Ports from Execute
    input  writeback_packet_t   fu_results  [NUM_FU-1:0],
    output logic                fu_cdb_gnts  [NUM_FU-1:0],

    // Ports to ROB & Execute
    output writeback_packet_t   cdb_ports   [PIPE_WIDTH-1:0],

    // Ports from ROB
    input  logic [TAG_WIDTH-1:0] rob_head
);
    // Calculate age (distance from ROB head) for each source
    logic [TAG_WIDTH-1:0] age [NUM_FU];
    
    always_comb begin
        for (int i = 0; i < NUM_FU; i++) age[i] = fu_results[i].dest_tag - rob_head;
    end
    
    //-------------------------------------------------------------
    // Select oldest valid source that hasn't been picked yet
    //-------------------------------------------------------------
    function automatic int find_oldest(
        input logic [NUM_FU-1:0] mask  // 1 = already selected, skip it
    );
        int oldest_idx;
        logic [TAG_WIDTH-1:0] oldest_age;
        logic found;
        
        oldest_idx = 0;
        oldest_age = '1;  // Start with max age
        found = 1'b0;
        
        for (int i = 0; i < NUM_FU; i++) begin
            // Skip if already selected or invalid
            if (mask[i] || !fu_results[i].is_valid) 
                continue;
            
            // Is this the oldest so far?
            if (!found || age[i] < oldest_age) begin
                oldest_age = age[i];
                oldest_idx = i;
                found = 1'b1;
            end
        end
        
        return found ? oldest_idx : -1;  // Return -1 if nothing found
    endfunction
    
    //-------------------------------------------------------------
    // Iteratively select PIPE_WIDTH oldest sources
    //-------------------------------------------------------------
    int selected [PIPE_WIDTH];
    logic [NUM_FU-1:0] used_mask;
    
    always_comb begin
        used_mask = '0;
        
        // Select each CDB port in order
        for (int port = 0; port < PIPE_WIDTH; port++) begin
            selected[port] = find_oldest(used_mask);
            
            // Mark this source as used
            if (selected[port] >= 0) begin
                used_mask[selected[port]] = 1'b1;
            end
        end
    end
    
    //-------------------------------------------------------------
    // Drive outputs
    //-------------------------------------------------------------
    always_comb begin
        // Default: no grants
        fu_cdb_gnts = '{default: 1'b0};
        
        // For each CDB port
        for (int port = 0; port < PIPE_WIDTH; port++) begin
            if (selected[port] >= 0) begin
                // Valid selection - grant and broadcast
                fu_cdb_gnts[selected[port]] = 1'b1;
                cdb_ports[port] = fu_results[selected[port]];
            end else begin
                // No valid source for this port
                cdb_ports[port] = '{default: '0};
            end
        end
    end

endmodule
