import riscv_isa_pkg::*;
import uarch_pkg::*;
import branch_pkg::*;

module btb #(
    parameter int ENTRIES       = BTB_ENTRIES,
    parameter int B_TAG_WIDTH   = BTB_TAG_WIDTH
)(
    input  logic clk, rst,

    // READ (async)
    input  logic            [CPU_ADDR_BITS-1:0] pc,
    output btb_pred_t       [FETCH_WIDTH-1:0]   read_ports,

    // WRITE (sync)
    input  btb_write_t      [FETCH_WIDTH-1:0]   write_ports 
);

    localparam int IDX_WIDTH = $clog2(ENTRIES);

    typedef struct packed {
        logic                       val;
        logic [B_TAG_WIDTH-1:0]     tag;
        logic [CPU_ADDR_BITS-1:0]   targ;
        logic [1:0]                 btype;
    } btb_entry_t;

    (* keep = "true" *) btb_entry_t btb [ENTRIES-1:0]; 

    //----------------------------------------------------------
    // Index and Tag Extraction
    //----------------------------------------------------------
    function automatic logic [IDX_WIDTH-1:0] get_index(input logic [CPU_ADDR_BITS-1:0] addr);
        return addr[IDX_WIDTH+1:2];
    endfunction

    function automatic logic [B_TAG_WIDTH-1:0] get_tag(input logic [CPU_ADDR_BITS-1:0] addr);
        return addr[B_TAG_WIDTH+IDX_WIDTH+1:IDX_WIDTH+2];
    endfunction

    //----------------------------------------------------------
    // Async prediction: slot0=pc, slot1=pc+4, others=pc+4*p
    //----------------------------------------------------------
    logic [CPU_ADDR_BITS-1:0] pcs   [FETCH_WIDTH-1:0];
    logic [IDX_WIDTH-1:0]     ridx  [FETCH_WIDTH-1:0];
    logic [B_TAG_WIDTH-1:0]   rtag  [FETCH_WIDTH-1:0];

    always_comb begin
        for (int p = 0; p < FETCH_WIDTH; p++) begin
            // generalize: pc + 4*p
            pcs[p]  = pc + (CPU_ADDR_BITS'(4) * CPU_ADDR_BITS'(p));
            ridx[p] = get_index(pcs[p]);
            rtag[p] = get_tag(pcs[p]);

            read_ports[p].hit   = btb[ridx[p]].val && (btb[ridx[p]].tag == rtag[p]);
            read_ports[p].targ  = btb[ridx[p]].targ;
            read_ports[p].btype = btb[ridx[p]].btype;
        end
    end

    //----------------------------------------------------------
    // Precompute write indices/tags combinationally
    //----------------------------------------------------------
    logic [IDX_WIDTH-1:0]   widx [FETCH_WIDTH-1:0];
    logic [B_TAG_WIDTH-1:0] wtag [FETCH_WIDTH-1:0];

    always_comb begin
        for (int w = 0; w < FETCH_WIDTH; w++) begin
            widx[w] = get_index(write_ports[w].pc);
            wtag[w] = get_tag(write_ports[w].pc);
        end
    end

    //----------------------------------------------------------
    // Sync update: highest slot wins on same index
    //----------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < ENTRIES; i++) btb[i] = '0;
        end else begin
            // Apply writes in ascending order so later ones override earlier ones
            for (int w = 0; w < FETCH_WIDTH; w++) begin
                if (write_ports[w].val && write_ports[w].taken) begin
                    btb[widx[w]].val   <= 1'b1;
                    btb[widx[w]].tag   <= wtag[w];
                    btb[widx[w]].targ  <= write_ports[w].targ;
                    btb[widx[w]].btype <= write_ports[w].btype;
                end
            end
        end
    end

endmodule
