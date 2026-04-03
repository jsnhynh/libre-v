package uarch_pkg;
    import riscv_isa_pkg::*;

    // Core sizing knobs
    localparam CLK_PERIOD     = 10;
    localparam FETCH_WIDTH    = 2;
    localparam PIPE_WIDTH     = 2;
    localparam ROB_ENTRIES    = 32;
    localparam ALU_RS_ENTRIES = 8;
    localparam MDU_RS_ENTRIES = 4;
    localparam LSQ_ENTRIES    = 8;
    localparam INST_BUF_DEPTH = 4;
    localparam TAG_WIDTH      = $clog2(ROB_ENTRIES);
    localparam NUM_RS         = 4;
    localparam NUM_FU         = 5;

    // Instruction source operand
    typedef struct packed {
        logic [CPU_DATA_BITS-1:0] data;
        logic [TAG_WIDTH-1:0]     tag;
        logic                     is_renamed;
    } source_t;

    // Decoded instruction passed down the pipeline
    // branch_pred_t imported from branch_pkg - forward declared via import in modules
    typedef struct packed {
        logic [CPU_ADDR_BITS-1:0] pc;
        logic [4:0]               rd;
        logic [TAG_WIDTH-1:0]     dest_tag;

        source_t    src_0_a;    // a_sel? PC : RS1
        source_t    src_0_b;    // b_sel? IMM : RS2
        logic [2:0] uop_0;

        source_t    src_1_a;    // RS1 (branches)
        source_t    src_1_b;    // RS2 / store data
        logic [2:0] uop_1;

        logic       is_valid;
        logic       has_rd;
        logic       agu_comp;
        logic [6:0] opcode;
        logic [6:0] funct7;
    } instruction_t;

    // CDB writeback packet
    typedef struct packed {
        logic [TAG_WIDTH-1:0]     dest_tag;
        logic [CPU_DATA_BITS-1:0] result;
        logic                     is_valid;
        logic                     exception;
    } writeback_packet_t;

    // ROB entry
    typedef struct packed {
        logic                     is_valid;
        logic                     is_ready;
        logic [CPU_ADDR_BITS-1:0] pc;
        logic [4:0]               rd;
        logic                     has_rd;
        logic [CPU_DATA_BITS-1:0] result;
        logic                     exception;
        logic [6:0]               opcode;
        logic                     mem_op;
        logic                     br_op;
    } rob_entry_t;

    // Branch commit port - from ROB to BPU
    typedef struct packed {
        logic                     val;
        logic [CPU_ADDR_BITS-1:0] targ;
        logic                     taken;
    } commit_branch_port_t;

    // PRF write ports
    typedef struct packed {
        logic [$clog2(ARCH_REGS)-1:0] addr;
        logic [TAG_WIDTH-1:0]         tag;
        logic                         we;
    } prf_rat_write_port_t;

    typedef struct packed {
        logic [$clog2(ARCH_REGS)-1:0] addr;
        logic [CPU_DATA_BITS-1:0]     data;
        logic [TAG_WIDTH-1:0]         tag;
        logic                         we;
    } prf_commit_write_port_t;

endpackage
