import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module ftq (
    input  logic clk, rst, flush,
    
    // Alloc
    input  logic        [FETCH_WIDTH-1:0] enq_en,
    input  ftq_entry_t  [FETCH_WIDTH-1:0] enq_data,
    output logic        [FETCH_WIDTH-1:0] enq_rdy,

    // Read
    input  logic        [FETCH_WIDTH-1:0] deq_en,
    output ftq_entry_t  [FETCH_WIDTH-1:0] deq_data,
    output logic        [FETCH_WIDTH-1:0] deq_rdy
);
    ftq_entry_t queue [FTQ_ENTRIES-1:0];
    
    logic [$clog2(FTQ_ENTRIES)-1:0] head;   // Oldest entry (dequeue point)
    logic [$clog2(FTQ_ENTRIES)-1:0] tail;   // Next allocation point
    logic [$clog2(FTQ_ENTRIES):0]   cnt;    // Current count

    logic [FETCH_WIDTH-1:0] enq_fire, deq_fire;
    logic [1:0] enq_cnt, deq_cnt; 

    assign deq_rdy[0]   = (cnt >= 'd1);
    assign deq_rdy[1]   = (cnt >= 'd2);
    assign deq_fire[0]  = deq_en[0] && deq_rdy[0];
    assign deq_fire[1]  = deq_en[1] && deq_rdy[1];
    assign deq_cnt      = deq_fire[0] + deq_fire[1];

    assign enq_rdy[0]   = (cnt < ($bits(cnt)'(FTQ_ENTRIES) + $bits(cnt)'(deq_cnt)));    
    assign enq_rdy[1]   = (cnt < ($bits(cnt)'(FTQ_ENTRIES) + $bits(cnt)'(deq_cnt) - $bits(cnt)'(1)));
    assign enq_fire[0]  = enq_en[0] && enq_rdy[0];
    assign enq_fire[1]  = enq_en[1] && enq_rdy[1];
    assign enq_cnt      = enq_fire[0] + enq_fire[1];
    
    //----------------------------------------------------------
    // Combinational Read
    //
    // Expose the current head entries whenever they are present.
    // Do not gate deq_data with deq_fire, otherwise a consumer that
    // needs to inspect head metadata before deciding deq_en can create
    // a combinational loop through deq_fire/deq_en.
    //----------------------------------------------------------
    assign deq_data[0]  = deq_rdy[0] ? queue[head] : '0;
    assign deq_data[1]  = deq_rdy[1] ? queue[head + $bits(head)'(1)] : '0;
    
    //----------------------------------------------------------
    // Sequential Logic
    //----------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            head <= '0;
            tail <= '0;
            cnt  <= '0;
            for (int i = 0; i < FTQ_ENTRIES; i++) begin
                queue[i] <= '{default: '0};
            end
        end else begin
            // Write
            if (enq_fire[0])
                queue[tail]     <= enq_data[0];
            if (enq_fire[1])
                queue[tail+1]   <= enq_data[1];
            tail <= tail + $bits(tail)'(enq_cnt);

            // Read (mark as invalid when read completes)
            if (deq_fire[0])
                queue[head].val     <= 1'b0;
            if (deq_fire[1])
                queue[head+1].val   <= 1'b0;
            head <= head + $bits(head)'(deq_cnt);
            
            // Update count
            cnt <= cnt + $bits(cnt)'(enq_cnt) - $bits(cnt)'(deq_cnt);
        end
    end
    `ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && !flush) begin
            /* Structural Invariants */
            assert (cnt <= FTQ_ENTRIES) else $fatal(1, "FTQ overflow: cnt=%0d, max=%0d", cnt, FTQ_ENTRIES);
            assert (FTQ_ENTRIES > 0) else $fatal(1, "FTQ must be > 0");
            assert ((FTQ_ENTRIES & FTQ_ENTRIES - 1) == 0) else $fatal(1, "FTQ entires must be power of 2");

            /* Protocol Violations */
            assert (enq_en != 2'b10) else $fatal(1, "FTQ: invalid enq_en=10 (slot 1 without slot 0)");
            assert (deq_en != 2'b10) else $fatal(1, "FTQ: invalid deq_en=10 (slot 1 without slot 0)");
            
            /* Underflow Checks */
            assert (!(deq_en[0] && cnt == 0)) else $fatal(1, "FTQ: dequeue slot 0 from empty (cnt=0)");
            assert (!(deq_en[1] && cnt < 2)) else $fatal(1, "FTQ: dequeue slot 1 when cnt=%0d", cnt);
            
            /* Data Validity */
            // Enqueuing invalid data
            if (enq_fire[0] && !enq_data[0].val) $warning("FTQ: enqueuing invalid entry slot 0");
            if (enq_fire[1] && !enq_data[1].val) $warning("FTQ: enqueuing invalid entry slot 1");
            
            // Dequeuing invalid entry (internal bug)
            if (deq_fire[0] && !queue[head].val) $fatal(1, "FTQ: dequeued invalid entry at head=%0d", head);
            if (deq_fire[1] && !queue[(head == $bits(head)'(FTQ_ENTRIES-1)) ? '0 : (head + $bits(head)'(1))].val) $fatal(1, "FTQ: dequeued invalid entry at head+1");
        end
    end
    `endif

endmodule
