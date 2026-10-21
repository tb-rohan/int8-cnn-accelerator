`timescale 1ns/1ps

module pe #(parameter int DATA_W = 8, parameter int ACC_W = 32) (
  input logic clk,
  input logic rst_n,
  input logic w_load_en,
  input logic signed [DATA_W-1:0] w_in,
  input logic signed [DATA_W-1:0] act_in,
  input logic signed [ACC_W-1:0] psum_in,
  output logic signed [DATA_W-1:0] act_out,
  output logic signed [ACC_W-1:0] psum_out
);
  logic signed [DATA_W-1:0] weight;
  logic signed [2*DATA_W-1:0] product;
  logic signed [ACC_W-1:0] product_extended;

  assign product = act_in * weight;
  assign product_extended = {{(ACC_W-2*DATA_W){product[2*DATA_W-1]}}, product};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      weight <= '0;
      act_out <= '0;
      psum_out <= '0;
    end else begin
      if (w_load_en)
        weight <= w_in;
      act_out <= act_in;
      psum_out <= psum_in + product_extended;
    end
  end
endmodule
