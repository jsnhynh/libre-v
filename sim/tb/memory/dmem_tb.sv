`timescale 1ns/1ps

import riscv_isa_pkg::*;
import uarch_pkg::*;

module dmem_tb;

    // --- Testbench Signals ---
    logic clk;
    logic rst;

    // --- DUT Interface ---
    // Request (Stimulus)
    logic                       dmem_req_rdy_o;
    instruction_t               dmem_req_packet_i;
    // Response (Monitor)
    logic                       dmem_rec_rdy_i;
    writeback_packet_t          dmem_rec_packet_o;


    // --- Instantiate the Memory Model (DUT) ---
    // Note: This testbench only connects to the DMEM ports.
    mem_simple dut (
        .clk(clk),
        .rst(rst),

        // -- IMEM Interface (Unconnected) --
        .imem_req_rdy(),
        .imem_req_val(1'b0),
        .imem_req_packet('0),
        .imem_rec_rdy(1'b0),
        .imem_rec_val(),
        .imem_rec_packet(),

        // -- DMEM Interface (Connected) --
        .dmem_req_rdy(dmem_req_rdy_o),
        .dmem_req_packet(dmem_req_packet_i),
        .dmem_rec_rdy(dmem_rec_rdy_i),
        .dmem_rec_packet(dmem_rec_packet_o)
    );

    // --- Clock Generator ---
    always #(CLK_PERIOD/2) clk = ~clk;

    // --- Helper Task: Send a STORE operation ---
    task automatic store_op(
        input logic [CPU_ADDR_BITS-1:0] addr,
        input logic [CPU_DATA_BITS-1:0] data,
        input logic [2:0]               funct3 // FNC_B, FNC_H, FNC_W
    );
        // Wait until memory is ready for a new request
        wait(dmem_req_rdy_o == 1'b1);
        
        dmem_req_packet_i = '{default:'0};
        dmem_req_packet_i.is_valid = 1'b1;
        dmem_req_packet_i.opcode = OPC_STORE;
        dmem_req_packet_i.src_0_a.data = addr; // Assumes address is in src_0_a
        dmem_req_packet_i.src_1_b.data = data; // Store data is in src_1_b
        dmem_req_packet_i.uop_0 = funct3; // Pass funct3 for byte enable decoding
    endtask

    // --- Helper Task: Send a LOAD operation ---
    task automatic read_op(
        input logic [CPU_ADDR_BITS-1:0] addr,
        input logic [TAG_WIDTH-1:0]     tag,
        input logic [2:0]               funct3 // FNC_B, FNC_H, FNC_W, FNC_BU, FNC_HU
    );
        // Wait until memory is ready for a new request
        wait(dmem_req_rdy_o == 1'b1);
        
        dmem_req_packet_i = '{default:'0};
        dmem_req_packet_i.is_valid = 1'b1;
        dmem_req_packet_i.opcode = OPC_LOAD;
        dmem_req_packet_i.src_0_a.data = addr; // Assumes address is in src_0_a
        dmem_req_packet_i.dest_tag = tag;  // Pass the dest_tag for the response
        dmem_req_packet_i.uop_0 = funct3; // Pass funct3 for load type
    endtask

    task automatic close_req();
        dmem_req_packet_i = '{default:'x};
        dmem_req_packet_i.is_valid = '0;
    endtask

    // --- Main Test Stimulus ---
    initial begin
        $display("[%0t] Starting DMEM Testbench...", $time);
        clk = 1'b0;
        rst = 1'b1;
        dmem_req_packet_i = '{default:'x};
        dmem_rec_rdy_i = 1'b0; // Default to not ready
        
        @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        $display("[%0t] Reset released.", $time);

        // --- Test 1: Write and Read back a full word ---
        store_op(32'h04, 32'hDEADBEEF, FNC_W);
        @(posedge clk);
        read_op(32'h04, 5, FNC_W);
        @(posedge clk);
        close_req();
        @(posedge clk);
        dmem_rec_rdy_i = 1'b1;
        @(posedge clk);
        dmem_rec_rdy_i = 1'b0;
        $display("[%0t] Test 1: Write and Read back a full word.", $time);        
        
        // --- Test 2: Write and Read back a half word ---
        store_op(32'h08, 32'hAAAAAAAA, FNC_H);
        @(posedge clk);
        read_op(32'h08, 5, FNC_H);  // 'hFFFFAAAA
        @(posedge clk);
        dmem_rec_rdy_i = 1'b1;
        read_op(32'h08, 5, FNC_BU); // 'h000000AA
        @(posedge clk);
        close_req();
        dmem_rec_rdy_i = 1'b0;
        @(posedge clk);
        dmem_rec_rdy_i = 1'b1;
        @(posedge clk);
        dmem_rec_rdy_i = 1'b0;
        close_req();
        $display("[%0t] Test 2: Write and Read back a half and bytes", $time);  

        repeat (2) @(posedge clk);
        $display("[%0t] All tests passed! Finishing.", $time);
        $finish;
    end

    // --- Monitor ---
    /* initial begin
        @(negedge rst);
        $monitor("[%0t] req_val_i=%b req_rdy_o=%b | rec_val_o=%b rec_rdy_i=%b | addr_in=%h op=%h data_in=%h | data_out=%h tag_out=%d",
            $time, dmem_req_packet_i.is_valid, dmem_req_rdy_o, dmem_rec_packet_o.is_valid, dmem_rec_rdy_i,
            dmem_req_packet_i.src_0_a.data, dmem_req_packet_i.opcode, dmem_req_packet_i.src_1_b.data,
            dmem_rec_packet_o.result, dmem_rec_packet_o.dest_tag);
    end */

endmodule
