`timescale 1ns/1ps

module post_proc import cnn_pkg::*; (
  input logic clk,
  input logic rst_n,
  input layer_cfg_t cfg,
  input logic [N*ACC_W-1:0] bias_vec,
  input logic psum_valid,
  input logic [N*ACC_W-1:0] psum_in,
  input logic psum_first,
  input logic psum_last,
  input logic [TILE_W-1:0] psum_idx,
  input logic pool_valid,
  input logic pool_first,
  input logic pool_last,
  input logic [N*DATA_W-1:0] pool_data,
  output logic out_wr_en,
  output logic [N*DATA_W-1:0] out_wr_data
);
  logic signed [ACC_W-1:0] acc_buf [0:TILE_P-1][0:N-1];
  logic signed [DATA_W-1:0] pool_max [0:N-1];
  logic signed [ACC_W-1:0] sum_stage [0:N-1];
  logic signed [ACC_W-1:0] bias_stage [0:N-1];
  logic signed [ACC_W:0] biased_stage [0:N-1];
  logic signed [48:0] product_stage [0:N-1];
  logic signed [49:0] shifted_stage [0:N-1];
  logic [4:0] shift_stage [0:2];
  logic [2:0] relu_stage;
  logic [3:0] valid_stage;
  integer i;
  integer j;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_wr_en <= 1'b0;
      out_wr_data <= '0;
      valid_stage <= '0;
      relu_stage <= '0;
      shift_stage[0] <= '0;
      shift_stage[1] <= '0;
      shift_stage[2] <= '0;
      for (i = 0; i < TILE_P; i = i + 1)
        for (j = 0; j < N; j = j + 1)
          acc_buf[i][j] <= '0;
      for (j = 0; j < N; j = j + 1) begin
        pool_max[j] <= '0;
        sum_stage[j] <= '0;
        bias_stage[j] <= '0;
        biased_stage[j] <= '0;
        product_stage[j] <= '0;
        shifted_stage[j] <= '0;
      end
    end else begin
      out_wr_en <= 1'b0;

      valid_stage[0] <= psum_valid && psum_last;
      valid_stage[1] <= valid_stage[0];
      valid_stage[2] <= valid_stage[1];
      valid_stage[3] <= valid_stage[2];

      if (psum_valid) begin
        for (j = 0; j < N; j = j + 1) begin
          sum_stage[j] <= psum_first ? $signed(psum_in[j*ACC_W +: ACC_W]) :
              acc_buf[psum_idx][j] + $signed(psum_in[j*ACC_W +: ACC_W]);
          if (psum_last)
            bias_stage[j] <= $signed(bias_vec[j*ACC_W +: ACC_W]);
          acc_buf[psum_idx][j] <= psum_first ? $signed(psum_in[j*ACC_W +: ACC_W]) :
              acc_buf[psum_idx][j] + $signed(psum_in[j*ACC_W +: ACC_W]);
        end
        if (psum_last) begin
          shift_stage[0] <= cfg.quant_shift;
          relu_stage[0] <= cfg.relu_en;
        end
      end

      if (valid_stage[0]) begin
        for (j = 0; j < N; j = j + 1)
          biased_stage[j] <= $signed({sum_stage[j][ACC_W-1], sum_stage[j]}) +
              $signed(bias_stage[j]);
      end
      if (valid_stage[1]) begin
        for (j = 0; j < N; j = j + 1)
          product_stage[j] <= $signed({{16{biased_stage[j][ACC_W]}}, biased_stage[j]}) *
              $signed({32'b0, cfg.quant_mult});
        shift_stage[1] <= shift_stage[0];
        relu_stage[1] <= relu_stage[0];
      end
      if (valid_stage[2]) begin
        for (j = 0; j < N; j = j + 1) begin
          if (shift_stage[1] != 0)
            shifted_stage[j] <= ($signed({product_stage[j][48], product_stage[j]}) +
                (50'sd1 <<< (shift_stage[1] - 1'b1))) >>> shift_stage[1];
          else
            shifted_stage[j] <= $signed({product_stage[j][48], product_stage[j]});
        end
        shift_stage[2] <= shift_stage[1];
        relu_stage[2] <= relu_stage[1];
      end
      if (valid_stage[3]) begin
        out_wr_en <= 1'b1;
        for (j = 0; j < N; j = j + 1) begin
          if (relu_stage[2] && shifted_stage[j] < 0)
            out_wr_data[j*DATA_W +: DATA_W] <= 8'sd0;
          else if (shifted_stage[j] > 127)
            out_wr_data[j*DATA_W +: DATA_W] <= 8'sd127;
          else if (shifted_stage[j] < -128)
            out_wr_data[j*DATA_W +: DATA_W] <= -8'sd128;
          else
            out_wr_data[j*DATA_W +: DATA_W] <= shifted_stage[j][DATA_W-1:0];
        end
      end

      if (pool_valid) begin
        for (j = 0; j < N; j = j + 1) begin
          if (pool_first)
            pool_max[j] <= $signed(pool_data[j*DATA_W +: DATA_W]);
          else if ($signed(pool_data[j*DATA_W +: DATA_W]) > pool_max[j])
            pool_max[j] <= $signed(pool_data[j*DATA_W +: DATA_W]);
          if (pool_last) begin
            out_wr_en <= 1'b1;
            if (pool_first || $signed(pool_data[j*DATA_W +: DATA_W]) > pool_max[j])
              out_wr_data[j*DATA_W +: DATA_W] <= $signed(pool_data[j*DATA_W +: DATA_W]);
            else
              out_wr_data[j*DATA_W +: DATA_W] <= pool_max[j];
          end
        end
      end
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) begin
    if (rst_n)
      assert (!(psum_valid && pool_valid)) else $error("post_proc received convolution and pool data together");
  end
`endif
endmodule
