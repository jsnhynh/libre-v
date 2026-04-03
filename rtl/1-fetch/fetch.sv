import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

/* Fetch stage */
//
// Current pc, pc_vals, and bpu_pred align with the returning imem_rec_packet.
// Using delayed copies breaks redirect recovery because flush drives pc_vals=00
// for the redirect cycle, which incorrectly tags the first post-flush response.

module fetch (
    input  logic clk, rst, flush,

    // BPU
    output logic [CPU_ADDR_BITS-1:0]       pc,
    input  logic [CPU_ADDR_BITS-1:0]       pc_next,
    input  logic [FETCH_WIDTH-1:0]         pc_vals,
    input  branch_pred_t [FETCH_WIDTH-1:0] bpu_pred,

    // FTQ alloc
    output ftq_alloc_t [FETCH_WIDTH-1:0]   alloc_ports,

    // IMEM request
    input  logic                                 imem_req_rdy,
    output logic                                 imem_req_val,
    output logic [CPU_ADDR_BITS-1:0]             imem_req_packet,

    // IMEM response
    output logic                                 imem_rec_rdy,
    input  logic                                 imem_rec_val,
    input  logic [FETCH_WIDTH*CPU_INST_BITS-1:0] imem_rec_packet,

    // Decoder
    input  logic                                      decode_rdy,
    output logic [CPU_ADDR_BITS-1:0]                   inst_pcs [PIPE_WIDTH-1:0],
    output logic [CPU_INST_BITS-1:0]                   insts    [PIPE_WIDTH-1:0],
    output logic [FETCH_WIDTH-1:0]                    fetch_vals
);

    // Debug-visible alias kept for existing hierarchical TB probes.
    logic [FETCH_WIDTH-1:0] pc_vals_r;
    assign pc_vals_r = pc_vals;

    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= PC_RESET;
        end else if (imem_req_rdy && imem_req_val) begin
            pc <= pc_next;
        end
    end

    inst_buffer ib (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush),
        .pc              (pc),
        .pc_vals         (pc_vals),
        .inst_buffer_rdy (imem_rec_rdy),
        .imem_rec_packet (imem_rec_packet),
        .imem_rec_val    (imem_rec_val),
        .decode_rdy      (decode_rdy),
        .inst_pcs        (inst_pcs),
        .insts           (insts),
        .fetch_vals      (fetch_vals)
    );

    logic [FETCH_WIDTH-1:0]      pd_is_branch;
    logic [FETCH_WIDTH-1:0][1:0] pd_btype;

    for (genvar s = 0; s < FETCH_WIDTH; s++) begin : g_pd
        predecode u_pd (
            .inst      (imem_rec_packet[s*CPU_INST_BITS +: CPU_INST_BITS]),
            .is_branch (pd_is_branch[s]),
            .btype     (pd_btype[s])
        );
    end

    always_comb begin
        alloc_ports = '{default:'0};
        for (int s = 0; s < FETCH_WIDTH; s++) begin
            if (imem_rec_val && pc_vals[s] && pd_is_branch[s]) begin
                alloc_ports[s].val  = 1'b1;
                alloc_ports[s].pc   = pc + CPU_ADDR_BITS'(s * 4);
                alloc_ports[s].pred = bpu_pred[s];
                if (!bpu_pred[s].btb.hit)
                    alloc_ports[s].pred.btb.btype = pd_btype[s];
            end
        end
    end

    assign imem_req_packet = pc_next;
    assign imem_req_val    = imem_req_rdy && imem_rec_rdy;

endmodule
