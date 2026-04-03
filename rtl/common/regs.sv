// These modules were provided by Berkeley's EECS 151 course.
`timescale 1ns/1ps

// Register of D-Type Flip-flops
module REGISTER(q, d, clk);
  parameter N = 1;
  output reg [N-1:0] q;
  input [N-1:0]      d;
  input         clk;
  always @(posedge clk)
    q <= d;
endmodule // REGISTER

// Register with clock enable
module REGISTER_CE(q, d, ce, clk);
  parameter N = 1;
  output reg [N-1:0] q;
  input [N-1:0]      d;
  input          ce, clk;
  always @(posedge clk)
    if (ce) q <= d;
endmodule // REGISTER_CE

// Register with reset value
module REGISTER_R(q, d, rst, clk);
  parameter N = 1;
  parameter INIT = {N{1'b0}};
  output reg [N-1:0] q;
  input [N-1:0]      d;
  input          rst, clk;
  always @(posedge clk)
    if (rst) q <= INIT;
    else q <= d;
endmodule // REGISTER_R

// Register with reset and clock enable
//  Reset works independently of clock enable
module REGISTER_R_CE(q, d, rst, ce, clk);
  parameter N = 1;
  parameter INIT = {N{1'b0}};
  output reg [N-1:0] q;
  input [N-1:0]      d;
  input          rst, ce, clk;
  always @(posedge clk)
    if (rst) q <= INIT;
    else if (ce) q <= d;
endmodule // REGISTER_R_CE
