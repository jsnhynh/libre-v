package branch_pkg;
    import riscv_isa_pkg::*;
    import uarch_pkg::*;

    // Branch predictor sizing
    localparam BTB_ENTRIES    = 128;
    localparam BTB_TAG_WIDTH  = 12;
    localparam RAS_ENTRIES    = 16;
    localparam GHR_WIDTH      = 32;
    localparam BASE_ENTRIES   = 512;
    localparam TAGE_ENTRIES   = 256;
    localparam TAGE_TABLES    = 4;
    localparam TAGE_TAG_WIDTH = 8;
    localparam FTQ_ENTRIES    = 16;

    // Branch types
    localparam BRANCH_COND = 2'b00;
    localparam BRANCH_JUMP = 2'b01;
    localparam BRANCH_CALL = 2'b10;
    localparam BRANCH_RET  = 2'b11;

    // BTB read result
    typedef struct packed {
        logic                     hit;
        logic [CPU_ADDR_BITS-1:0] targ;
        logic [1:0]               btype;
    } btb_pred_t;

    // BTB write port - used at commit
    typedef struct packed {
        logic                     val;
        logic [CPU_ADDR_BITS-1:0] pc;
        logic [CPU_ADDR_BITS-1:0] targ;
        logic [1:0]               btype;
        logic                     taken;
    } btb_write_t;

    // TAGE prediction result
    typedef struct packed {
        logic [$clog2(TAGE_TABLES):0] provider;
        logic                         pred_taken;
        logic                         pred_alt;
    } tage_pred_t;

    // GHR shift request from decode
    typedef struct packed {
        logic val;
        logic taken;
    } tage_ghr_t;

    // TAGE training port - used at commit
    typedef struct packed {
        logic                         val;
        logic [CPU_ADDR_BITS-1:0]     pc;
        logic                         actual_taken;
        logic [$clog2(TAGE_TABLES):0] provider;
        logic                         pred_taken;
        logic                         pred_alt;
        logic [GHR_WIDTH-1:0]         ghr_cp;
    } tage_update_t;

    // Complete fetch-time prediction - nests BTB and TAGE results
    typedef struct packed {
        btb_pred_t  btb;
        tage_pred_t tage;
    } branch_pred_t;

    // FTQ entry - prediction + checkpoints for recovery
    typedef struct packed {
        logic                         val;
        logic [CPU_ADDR_BITS-1:0]     pc;
        branch_pred_t                 pred;
        logic [GHR_WIDTH-1:0]         ghr_cp;
        logic [$clog2(RAS_ENTRIES):0] ras_cp;
    } ftq_entry_t;

    // FTQ alloc port - driven from fetch via predecoder
    typedef struct packed {
        logic                     val;
        logic [CPU_ADDR_BITS-1:0] pc;
        branch_pred_t             pred;
    } ftq_alloc_t;

endpackage
