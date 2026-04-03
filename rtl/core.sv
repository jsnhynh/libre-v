import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module core (
    input clk, rst,

    // IMEM
    input  logic                                     imem_req_rdy,
    output logic                                     imem_req_val,
    output logic [CPU_ADDR_BITS-1:0]                 imem_req_packet,
    output logic                                     imem_rec_rdy,
    input  logic                                     imem_rec_val,
    input  logic [FETCH_WIDTH*CPU_INST_BITS-1:0]     imem_rec_packet,

    // DMEM
    input  logic                        dmem_req_rdy,
    output instruction_t                dmem_req_packet,
    output logic                        dmem_rec_rdy,
    input  writeback_packet_t           dmem_rec_packet
);

    //-------------------------------------------------------------
    // 0-Branch
    //-------------------------------------------------------------
    logic                            flush;
    logic [CPU_ADDR_BITS-1:0]        pc, pc_next;
    logic [FETCH_WIDTH-1:0]          pc_vals;
    branch_pred_t [FETCH_WIDTH-1:0]  bpu_pred;
    ftq_alloc_t   [FETCH_WIDTH-1:0]  alloc_ports;
    commit_branch_port_t [FETCH_WIDTH-1:0] commit_branch;
    logic [FETCH_WIDTH-1:0]          commit_mispredict;

    bpu bpu_stage (
        .clk               (clk),
        .rst               (rst),
        .flush             (flush),
        .pc                (pc),
        .pc_next           (pc_next),
        .pc_vals           (pc_vals),
        .pred              (bpu_pred),
        .alloc_ports       (alloc_ports),
        .commit_branch     (commit_branch),
        .commit_mispredict (commit_mispredict)
    );

    //-------------------------------------------------------------
    // 1-Fetch
    //-------------------------------------------------------------
    logic                                      decode_rdy;
    logic [CPU_ADDR_BITS-1:0]                  inst_pcs    [PIPE_WIDTH-1:0];
    logic [CPU_INST_BITS-1:0]                  insts       [PIPE_WIDTH-1:0];
    logic [FETCH_WIDTH-1:0]                    fetch_vals;

    fetch fetch_stage (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush),
        .pc              (pc),
        .pc_next         (pc_next),
        .pc_vals         (pc_vals),
        .bpu_pred        (bpu_pred),
        .alloc_ports     (alloc_ports),
        .imem_req_rdy    (imem_req_rdy),
        .imem_req_val    (imem_req_val),
        .imem_req_packet (imem_req_packet),
        .imem_rec_rdy    (imem_rec_rdy),
        .imem_rec_val    (imem_rec_val),
        .imem_rec_packet (imem_rec_packet),
        .decode_rdy      (decode_rdy),
        .inst_pcs        (inst_pcs),
        .insts           (insts),
        .fetch_vals      (fetch_vals)
    );

    //-------------------------------------------------------------
    // 2-Decode
    //-------------------------------------------------------------
    logic                                   rename_rdy;
    instruction_t                           decoded_insts [PIPE_WIDTH-1:0];

    decode decode_stage (
        .clk           (clk),
        .rst           (rst),
        .flush         (flush),
        .decode_rdy    (decode_rdy),
        .inst_pcs      (inst_pcs),
        .insts         (insts),
        .fetch_vals    (fetch_vals),
        .rename_rdy    (rename_rdy),
        .decoded_insts (decoded_insts)
    );

    //-------------------------------------------------------------
    // 3-Rename
    //-------------------------------------------------------------
    logic                       dispatch_rdy;
    instruction_t               renamed_insts       [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]      rob_alloc_req, rob_alloc_gnt;
    logic [TAG_WIDTH-1:0]       rob_alloc_tags      [PIPE_WIDTH-1:0];
    prf_commit_write_port_t     commit_write_ports  [PIPE_WIDTH-1:0];
    rob_entry_t                 rob_entries_bypass  [ROB_ENTRIES-1:0];

    rename rename_stage (
        .clk                (clk),
        .rst                (rst),
        .flush              (flush),
        .rename_rdy         (rename_rdy),
        .decoded_insts      (decoded_insts),
        .dispatch_rdy       (dispatch_rdy),
        .renamed_insts      (renamed_insts),
        .rob_alloc_req      (rob_alloc_req),
        .rob_alloc_gnt      (rob_alloc_gnt),
        .rob_alloc_tags     (rob_alloc_tags),
        .commit_write_ports (commit_write_ports),
        .rob_entries_bypass (rob_entries_bypass)
    );

    //-------------------------------------------------------------
    // 4-Dispatch
    //-------------------------------------------------------------
    logic [PIPE_WIDTH-1:0]  rs_rdys         [NUM_RS-1:0];
    logic [PIPE_WIDTH-1:0]  rs_wes          [NUM_RS-1:0];
    instruction_t           rs_issue_ports  [NUM_RS-1:0][PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]  rob_rdy, rob_we;
    rob_entry_t             rob_entries     [PIPE_WIDTH-1:0];

    dispatch dispatch_stage (
        .dispatch_rdy    (dispatch_rdy),
        .renamed_insts   (renamed_insts),
        .rs_rdys         (rs_rdys),
        .rs_wes          (rs_wes),
        .rs_issue_ports  (rs_issue_ports),
        .rob_rdy         (rob_rdy),
        .rob_we          (rob_we),
        .rob_entries     (rob_entries)
    );

    //-------------------------------------------------------------
    // 5-Issue
    //-------------------------------------------------------------
    logic [NUM_FU-1:0]      fu_rdys;
    instruction_t           fu_packets          [NUM_FU-1:0];
    logic [TAG_WIDTH-1:0]   commit_store_ids    [PIPE_WIDTH-1:0];
    logic [PIPE_WIDTH-1:0]  commit_store_vals;
    writeback_packet_t      cdb_ports           [FETCH_WIDTH-1:0];
    writeback_packet_t      agu_result;
    writeback_packet_t      forward_pkt;
    logic [TAG_WIDTH-1:0]   rob_head;

    issue issue_stage (
        .clk               (clk),
        .rst               (rst),
        .flush             (flush),
        .rs_rdys           (rs_rdys),
        .rs_wes            (rs_wes),
        .rs_issue_ports    (rs_issue_ports),
        .fu_rdys           (fu_rdys),
        .fu_packets        (fu_packets),
        .dmem_req_rdy      (dmem_req_rdy),
        .commit_store_ids  (commit_store_ids),
        .commit_store_vals (commit_store_vals),
        .cdb_ports         (cdb_ports),
        .agu_result        (agu_result),
        .forward_pkt       (forward_pkt),
        .rob_head          (rob_head)
    );

    //-------------------------------------------------------------
    // 6-Execute
    //-------------------------------------------------------------
    writeback_packet_t  fu_results  [NUM_FU-1:0];
    logic               fu_cdb_gnts [NUM_FU-1:0];

    execute execute_stage (
        .clk             (clk),
        .rst             (rst),
        .flush           (flush),
        .fu_rdys         (fu_rdys),
        .fu_packets      (fu_packets),
        .fu_results      (fu_results),
        .fu_cdb_gnts     (fu_cdb_gnts),
        .agu_result      (agu_result),
        .dmem_rec_rdy    (dmem_rec_rdy),
        .dmem_rec_packet (dmem_rec_packet),
        .forward_pkt     (forward_pkt)
    );

    //-------------------------------------------------------------
    // 7-Writeback
    //-------------------------------------------------------------
    cdb writeback_stage (
        .fu_results  (fu_results),
        .fu_cdb_gnts (fu_cdb_gnts),
        .cdb_ports   (cdb_ports),
        .rob_head    (rob_head)
    );

    //-------------------------------------------------------------
    // 8-Commit
    //-------------------------------------------------------------
    rob commit_stage (
        .clk                (clk),
        .rst                (rst),
        .flush              (flush),
        .rob_alloc_req      (rob_alloc_req),
        .rob_alloc_gnt      (rob_alloc_gnt),
        .rob_alloc_tags     (rob_alloc_tags),
        .commit_write_ports (commit_write_ports),
        .rob_rdy            (rob_rdy),
        .rob_we             (rob_we),
        .rob_entries        (rob_entries),
        .cdb_ports          (cdb_ports),
        .commit_store_ids   (commit_store_ids),
        .commit_store_vals  (commit_store_vals),
        .rob_head           (rob_head),
        .rob_read_entries   (rob_entries_bypass)
    );

    assign dmem_req_packet = fu_packets[2];

endmodule
