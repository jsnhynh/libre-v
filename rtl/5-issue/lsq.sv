import riscv_isa_pkg::*;
import uarch_pkg::*;

module lsq #(
    parameter int STQ_DEPTH = 8,
    parameter int LDQ_DEPTH = 8
)(
    input  logic clk, rst, flush,
    
    // D-Cache interface
    input  logic                    dmem_rdy,
    output instruction_t            dmem_pkt,
    
    // Forward interface
    output writeback_packet_t       forward_pkt,
    
    // Dispatch - Loads
    input  logic [PIPE_WIDTH-1:0]   ld_we,
    input  instruction_t            ld_entries_in [PIPE_WIDTH-1:0],
    output logic [PIPE_WIDTH-1:0]   ld_rdy,
    
    // Dispatch - Stores  
    input  logic [PIPE_WIDTH-1:0]   st_we,
    input  instruction_t            st_entries_in [PIPE_WIDTH-1:0],
    output logic [PIPE_WIDTH-1:0]   st_rdy,
    
    // CDB interface
    input  writeback_packet_t       cdb_ports [PIPE_WIDTH-1:0],
    
    // AGU interface
    input  logic                    agu_rdy,
    output instruction_t            agu_pkt,
    input  writeback_packet_t       agu_result,
    
    // ROB interface
    input  logic [TAG_WIDTH-1:0]    rob_head,
    input  logic [TAG_WIDTH-1:0]    commit_store_ids [PIPE_WIDTH-1:0],
    input  logic [PIPE_WIDTH-1:0]   commit_store_vals
);

    assign forward_pkt = '0;

    //=========================================================================
    // Internal Queue Storage
    //=========================================================================
    instruction_t           ldq          [LDQ_DEPTH-1:0];
    instruction_t           ldq_next     [LDQ_DEPTH-1:0];
    logic [LDQ_DEPTH-1:0]   ldq_agu_comp,     ldq_agu_comp_next;
    logic [LDQ_DEPTH-1:0]   ldq_agu_sent,     ldq_agu_sent_next;

    instruction_t           stq          [STQ_DEPTH-1:0];
    instruction_t           stq_next     [STQ_DEPTH-1:0];
    logic [STQ_DEPTH-1:0]   stq_agu_comp,     stq_agu_comp_next;
    logic [STQ_DEPTH-1:0]   stq_agu_sent,     stq_agu_sent_next;
    logic [STQ_DEPTH-1:0]   stq_committed,    stq_committed_next;
    
    logic [$clog2(STQ_DEPTH)-1:0] stq_head, stq_tail;
    logic [$clog2(STQ_DEPTH):0]   stq_count;

    //=========================================================================
    // Helpers
    //=========================================================================
    function automatic source_t update_source(input source_t src);
        source_t result = src;
        if (!src.is_renamed) return result;
        for (int c = 0; c < PIPE_WIDTH; c++) begin
            if (cdb_ports[c].is_valid && cdb_ports[c].dest_tag == src.tag) begin
                result.data = cdb_ports[c].result;
                result.tag = '0;
                result.is_renamed = 1'b0;
            end
        end
        return result;
    endfunction

    //=========================================================================
    // AGU Result Forwarding (Combinational)
    //=========================================================================
    logic [LDQ_DEPTH-1:0]       ldq_addr_ready_comb;
    logic [CPU_DATA_BITS-1:0]   ldq_addr_val_comb [LDQ_DEPTH-1:0];
    
    logic [STQ_DEPTH-1:0]       stq_addr_ready_comb;
    logic [CPU_DATA_BITS-1:0]   stq_addr_val_comb [STQ_DEPTH-1:0];

    always_comb begin
        for (int i = 0; i < LDQ_DEPTH; i++) begin
            if (ldq_agu_comp[i]) begin
                ldq_addr_ready_comb[i] = 1'b1;
                ldq_addr_val_comb[i]   = ldq[i].src_0_a.data;
            end else if (agu_result.is_valid && ldq[i].is_valid && ldq[i].dest_tag == agu_result.dest_tag) begin
                ldq_addr_ready_comb[i] = 1'b1;
                ldq_addr_val_comb[i]   = agu_result.result;
            end else begin
                ldq_addr_ready_comb[i] = 1'b0;
                ldq_addr_val_comb[i]   = '0;
            end
        end
        for (int i = 0; i < STQ_DEPTH; i++) begin
            if (stq_agu_comp[i]) begin
                stq_addr_ready_comb[i] = 1'b1;
                stq_addr_val_comb[i]   = stq[i].src_0_a.data;
            end else if (agu_result.is_valid && stq[i].is_valid && stq[i].dest_tag == agu_result.dest_tag) begin
                stq_addr_ready_comb[i] = 1'b1;
                stq_addr_val_comb[i]   = agu_result.result;
            end else begin
                stq_addr_ready_comb[i] = 1'b0;
                stq_addr_val_comb[i]   = '0;
            end
        end
    end

    //=========================================================================
    // Status Logic
    //=========================================================================
    logic [LDQ_DEPTH-1:0]   ldq_agu_req_valid;
    logic [TAG_WIDTH-1:0]   ldq_ages [LDQ_DEPTH-1:0];
    
    logic [STQ_DEPTH-1:0]   stq_agu_req_valid;
    logic [STQ_DEPTH-1:0]   stq_commit_match;
    logic [STQ_DEPTH-1:0]   stq_is_committed;

    always_comb begin
        for (int i = 0; i < LDQ_DEPTH; i++) begin
            ldq_agu_req_valid[i] = ldq[i].is_valid && !ldq_agu_comp[i] && !ldq_agu_sent[i] &&
                                  !ldq[i].src_0_a.is_renamed && !ldq[i].src_0_b.is_renamed;
            ldq_ages[i] = ldq[i].dest_tag - rob_head;
        end

        for (int i = 0; i < STQ_DEPTH; i++) begin
            stq_agu_req_valid[i] = stq[i].is_valid && !stq_agu_comp[i] && !stq_agu_sent[i] &&
                                  !stq[i].src_0_a.is_renamed && !stq[i].src_0_b.is_renamed;
            
            stq_commit_match[i] = 1'b0;
            for (int c = 0; c < PIPE_WIDTH; c++) begin
                if (commit_store_vals[c] && commit_store_ids[c] == stq[i].dest_tag) begin
                    stq_commit_match[i] = 1'b1;
                end
            end
            stq_is_committed[i] = stq_committed[i] || stq_commit_match[i];
        end
    end

    //=========================================================================
    // Memory Disambiguation
    //=========================================================================
    logic [LDQ_DEPTH-1:0] ldq_stall;

    always_comb begin
        for (int ld = 0; ld < LDQ_DEPTH; ld++) begin
            ldq_stall[ld] = 1'b0;
            if (ldq[ld].is_valid && ldq_addr_ready_comb[ld]) begin
                for (int st = 0; st < STQ_DEPTH; st++) begin
                    if (stq[st].is_valid) begin
                        logic [TAG_WIDTH-1:0] st_age = stq[st].dest_tag - rob_head;
                        logic store_is_older = stq_is_committed[st] || (st_age < ldq_ages[ld]);
                        if (store_is_older) begin
                            if (!stq_addr_ready_comb[st]) begin
                                ldq_stall[ld] = 1'b1;
                            end else if (stq_addr_val_comb[st][31:2] == ldq_addr_val_comb[ld][31:2]) begin
                                ldq_stall[ld] = 1'b1;
                            end
                        end
                    end
                end
            end
        end
    end

    //=========================================================================
    // AGU Arbitration
    //=========================================================================
    logic                           agu_gnt_is_store;
    logic [$clog2(LDQ_DEPTH)-1:0]   agu_gnt_ld_idx;
    logic [$clog2(STQ_DEPTH)-1:0]   agu_gnt_st_idx;

    always_comb begin
        agu_gnt_is_store = 1'b0;
        agu_gnt_ld_idx = '0;
        agu_gnt_st_idx = '0;
        agu_pkt = '{default: '0};
        
        if (agu_rdy) begin
            automatic logic [TAG_WIDTH-1:0] oldest_age = '1;
            automatic logic found = 1'b0;
            
            for (int i = 0; i < LDQ_DEPTH; i++) begin
                if (ldq_agu_req_valid[i] && ldq_ages[i] < oldest_age) begin
                    oldest_age = ldq_ages[i];
                    agu_gnt_ld_idx = i;
                    agu_gnt_is_store = 1'b0;
                    found = 1'b1;
                end
            end
            for (int i = 0; i < STQ_DEPTH; i++) begin
                if (stq_agu_req_valid[i]) begin
                    logic [TAG_WIDTH-1:0] st_age = stq[i].dest_tag - rob_head;
                    if (st_age < oldest_age) begin
                        oldest_age = st_age;
                        agu_gnt_st_idx = i;
                        agu_gnt_is_store = 1'b1;
                        found = 1'b1;
                    end
                end
            end
            if (found) begin
                if (agu_gnt_is_store) agu_pkt = stq[agu_gnt_st_idx];
                else                  agu_pkt = ldq[agu_gnt_ld_idx];
            end
        end
    end

    //=========================================================================
    // Store Head Forwarding
    //=========================================================================
    logic stq_head_ready;
    logic stq_head_data_ready;
    logic [CPU_DATA_BITS-1:0] stq_head_data;

    always_comb begin
        stq_head_data_ready = !stq[stq_head].src_1_b.is_renamed;
        stq_head_data = stq[stq_head].src_1_b.data;
        for (int c = 0; c < PIPE_WIDTH; c++) begin
            if (cdb_ports[c].is_valid && stq[stq_head].src_1_b.is_renamed && 
                cdb_ports[c].dest_tag == stq[stq_head].src_1_b.tag) begin
                stq_head_data_ready = 1'b1;
                stq_head_data = cdb_ports[c].result;
            end
        end
        stq_head_ready = stq[stq_head].is_valid && stq_addr_ready_comb[stq_head] && 
                        stq_is_committed[stq_head] && stq_head_data_ready;
    end

    //=========================================================================
    // Memory Interface Arbitration
    //=========================================================================
    logic                           mem_gnt_valid;
    logic                           mem_gnt_is_store;
    logic [$clog2(LDQ_DEPTH)-1:0]   mem_gnt_ld_idx;

    always_comb begin
        mem_gnt_valid = 1'b0;
        mem_gnt_is_store = 1'b0;
        mem_gnt_ld_idx = '0;
        dmem_pkt = '{default: '0};
        
        if (dmem_rdy) begin
            if (stq_head_ready) begin
                mem_gnt_valid = 1'b1;
                mem_gnt_is_store = 1'b1;
                dmem_pkt = stq[stq_head];
                dmem_pkt.src_0_a.data = stq_addr_val_comb[stq_head]; // Bypass
                dmem_pkt.src_1_b.data = stq_head_data; // Bypass
                dmem_pkt.src_1_b.is_renamed = 1'b0;
            end else begin
                automatic logic [TAG_WIDTH-1:0] oldest_age = '1;
                automatic logic found = 1'b0;
                for (int i = 0; i < LDQ_DEPTH; i++) begin
                    if (ldq[i].is_valid && ldq_addr_ready_comb[i] && !ldq_stall[i]) begin
                         if (ldq_ages[i] < oldest_age) begin
                            oldest_age = ldq_ages[i];
                            mem_gnt_ld_idx = i;
                            found = 1'b1;
                         end
                    end
                end
                if (found) begin
                    mem_gnt_valid = 1'b1;
                    dmem_pkt = ldq[mem_gnt_ld_idx];
                    dmem_pkt.src_0_a.data = ldq_addr_val_comb[mem_gnt_ld_idx]; // Bypass
                end
            end
        end
    end

    //=========================================================================
    // Alloc / Update
    //=========================================================================
    logic [PIPE_WIDTH-1:0] ld_can_alloc;
    int                    ld_alloc_idx [PIPE_WIDTH-1:0];
    logic stq_full;
    assign stq_full = (stq_count == STQ_DEPTH);

    // Ready Signals
    always_comb begin
        automatic logic [LDQ_DEPTH-1:0] used_mask = '0;
        for (int d = 0; d < PIPE_WIDTH; d++) begin
            ld_alloc_idx[d] = -1;
            ld_can_alloc[d] = 1'b0;
            for (int e = 0; e < LDQ_DEPTH; e++) begin
                logic will_free = !ldq[e].is_valid || (mem_gnt_valid && !mem_gnt_is_store && mem_gnt_ld_idx == e);
                if (will_free && !used_mask[e]) begin
                    ld_alloc_idx[d] = e;
                    ld_can_alloc[d] = 1'b1;
                    used_mask[e] = 1'b1;
                    break;
                end
            end
        end
        ld_rdy = ld_can_alloc;
        
        st_rdy[0] = !stq_full;
        st_rdy[1] = (stq_count <= STQ_DEPTH - 2);
    end

    // Queue Updates
    logic [1:0] st_push_cnt;
    logic       st_pop;
    assign st_push_cnt = (st_we[0] && st_rdy[0]) + (st_we[1] && st_rdy[1]);
    assign st_pop = mem_gnt_valid && mem_gnt_is_store;
    
    // Declare temp index variable at the TOP of the scope (Fixes VRFC error)
    int st_idx_2;

    always_comb begin
        // Default: Hold state
        ldq_next = ldq;
        ldq_agu_comp_next = ldq_agu_comp;
        ldq_agu_sent_next = ldq_agu_sent;
        stq_next = stq;
        stq_agu_comp_next = stq_agu_comp;
        stq_agu_sent_next = stq_agu_sent;
        stq_committed_next = stq_committed;
        
        // Init variable
        st_idx_2 = 0;

        //=====================================================================
        // 1. DEALLOCATE (Moved to Top to Fix Race Condition)
        //=====================================================================
        if (mem_gnt_valid) begin
            if (mem_gnt_is_store) begin
                stq_next[stq_head] = '{default: '0};
                stq_agu_comp_next[stq_head] = 1'b0;
                stq_agu_sent_next[stq_head] = 1'b0;
                stq_committed_next[stq_head] = 1'b0;
            end else begin
                ldq_next[mem_gnt_ld_idx] = '{default: '0};
                ldq_agu_comp_next[mem_gnt_ld_idx] = 1'b0;
                ldq_agu_sent_next[mem_gnt_ld_idx] = 1'b0;
            end
        end

        //=====================================================================
        // 2. Snoop CDB (Updates Src Data)
        //=====================================================================
        for (int e = 0; e < LDQ_DEPTH; e++) if(ldq_next[e].is_valid) begin
            ldq_next[e].src_0_a = update_source(ldq_next[e].src_0_a);
            ldq_next[e].src_0_b = update_source(ldq_next[e].src_0_b);
            ldq_next[e].src_1_b = update_source(ldq_next[e].src_1_b);
        end
        for (int e = 0; e < STQ_DEPTH; e++) if(stq_next[e].is_valid) begin
            stq_next[e].src_0_a = update_source(stq_next[e].src_0_a);
            stq_next[e].src_1_b = update_source(stq_next[e].src_1_b);
        end

        //=====================================================================
        // 3. Capture AGU Results
        //=====================================================================
        if (agu_result.is_valid) begin
            for (int e = 0; e < LDQ_DEPTH; e++) if(ldq_next[e].is_valid && !ldq_agu_comp[e] && ldq_next[e].dest_tag == agu_result.dest_tag) begin
                ldq_next[e].src_0_a.data = agu_result.result;
                ldq_agu_comp_next[e] = 1'b1;
            end
            for (int e = 0; e < STQ_DEPTH; e++) if(stq_next[e].is_valid && !stq_agu_comp[e] && stq_next[e].dest_tag == agu_result.dest_tag) begin
                stq_next[e].src_0_a.data = agu_result.result;
                stq_agu_comp_next[e] = 1'b1;
            end
        end

        //=====================================================================
        // 4. Mark AGU Request as Sent
        //=====================================================================
        if (agu_pkt.is_valid) begin 
             if (agu_gnt_is_store) stq_agu_sent_next[agu_gnt_st_idx] = 1'b1;
             else                  ldq_agu_sent_next[agu_gnt_ld_idx] = 1'b1;
        end

        //=====================================================================
        // 5. Commit Stores
        //=====================================================================
        for (int e = 0; e < STQ_DEPTH; e++) if(stq_commit_match[e]) stq_committed_next[e] = 1'b1;

        //=====================================================================
        // 6. Alloc Loads
        //=====================================================================
        for (int d = 0; d < PIPE_WIDTH; d++) if (ld_we[d] && ld_can_alloc[d]) begin
            int idx = ld_alloc_idx[d];
            ldq_next[idx] = ld_entries_in[d];
            ldq_agu_comp_next[idx] = 1'b0;
            ldq_agu_sent_next[idx] = 1'b0;
            ldq_next[idx].src_0_a = update_source(ldq_next[idx].src_0_a);
            ldq_next[idx].src_0_b = update_source(ldq_next[idx].src_0_b);
        end

        //=====================================================================
        // 7. Alloc Stores (Overwrites Deallocate if same index)
        //=====================================================================
        case ({ (st_we[1] && st_rdy[1]), (st_we[0] && st_rdy[0]) })
            2'b01: begin // Push 1 (Instr 0)
                stq_next[stq_tail] = st_entries_in[0];
                stq_agu_comp_next[stq_tail] = 1'b0;
                stq_agu_sent_next[stq_tail] = 1'b0;
                stq_committed_next[stq_tail] = 1'b0;
                stq_next[stq_tail].src_0_a = update_source(stq_next[stq_tail].src_0_a);
                stq_next[stq_tail].src_1_b = update_source(stq_next[stq_tail].src_1_b);
            end
            2'b11: begin // Push 2 (Instr 0 and 1)
                stq_next[stq_tail] = st_entries_in[0];
                stq_agu_comp_next[stq_tail] = 1'b0;
                stq_agu_sent_next[stq_tail] = 1'b0;
                stq_committed_next[stq_tail] = 1'b0;
                stq_next[stq_tail].src_0_a = update_source(stq_next[stq_tail].src_0_a);
                stq_next[stq_tail].src_1_b = update_source(stq_next[stq_tail].src_1_b);
                
                // Calculate next index
                st_idx_2 = (stq_tail == STQ_DEPTH-1) ? '0 : stq_tail + 1;
                
                stq_next[st_idx_2] = st_entries_in[1];
                stq_agu_comp_next[st_idx_2] = 1'b0;
                stq_agu_sent_next[st_idx_2] = 1'b0;
                stq_committed_next[st_idx_2] = 1'b0;
                stq_next[st_idx_2].src_0_a = update_source(stq_next[st_idx_2].src_0_a);
                stq_next[st_idx_2].src_1_b = update_source(stq_next[st_idx_2].src_1_b);
            end
            // 2'b10 is impossible due to dispatch compaction
            default: ;
        endcase
    end

    //=========================================================================
    // Sequential Logic
    //=========================================================================
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for(int i=0; i<LDQ_DEPTH; i++) ldq[i] <= '{default: '0};
            ldq_agu_comp <= '0;
            ldq_agu_sent <= '0;
            for(int i=0; i<STQ_DEPTH; i++) stq[i] <= '{default: '0};
            stq_agu_comp <= '0;
            stq_agu_sent <= '0;
            stq_committed <= '0;
            stq_head <= '0;
            stq_tail <= '0;
            stq_count <= '0;
        end else begin
            ldq <= ldq_next;
            ldq_agu_comp <= ldq_agu_comp_next;
            ldq_agu_sent <= ldq_agu_sent_next;
            stq <= stq_next;
            stq_agu_comp <= stq_agu_comp_next;
            stq_agu_sent <= stq_agu_sent_next;
            stq_committed <= stq_committed_next;
            
            if (st_pop) stq_head <= (stq_head == STQ_DEPTH-1) ? '0 : stq_head + 1;
            
            case (st_push_cnt)
                2'd1: stq_tail <= (stq_tail == STQ_DEPTH-1) ? '0 : stq_tail + 1;
                2'd2: stq_tail <= (stq_tail >= STQ_DEPTH-2) ? (stq_tail + 2 - STQ_DEPTH) : stq_tail + 2;
            endcase
            stq_count <= stq_count + st_push_cnt - st_pop;
        end
    end

endmodule







