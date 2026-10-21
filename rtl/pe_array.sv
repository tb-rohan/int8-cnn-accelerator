`timescale 1ns/1ps

module pe_array import cnn_pkg::*; (
  input logic clk,
  input logic rst_n,
  input logic w_load_en,
  input logic [$clog2(N)-1:0] w_load_row,
  input logic [N*DATA_W-1:0] w_load_data,
  input logic act_valid,
  input logic [N*DATA_W-1:0] act_in,
  input logic act_first,
  input logic act_last,
  input logic [TILE_W-1:0] act_idx,
  output logic psum_valid,
  output logic [N*ACC_W-1:0] psum_out,
  output logic psum_first,
  output logic psum_last,
  output logic [TILE_W-1:0] psum_idx
);
  logic signed [DATA_W-1:0] act_bus [0:N-1][0:N];
  logic signed [DATA_W-1:0] row_input [0:N-1];
  logic signed [ACC_W-1:0] sum_bus [0:N][0:N-1];
  logic signed [DATA_W-1:0] row_delay [0:N-1][0:N-1];
  logic signed [ACC_W-1:0] deskew [0:N-1][0:N-1];
  logic [2*N-2:0] valid_pipe;
  logic [2*N-2:0] first_pipe;
  logic [2*N-2:0] last_pipe;
  logic [(2*N-1)*TILE_W-1:0] idx_pipe;

  genvar r;
  genvar c;
  genvar d;
  generate
    for (r = 0; r < N; r = r + 1) begin : g_rows
      if (r == 0) begin
        assign row_input[r] = act_valid ? $signed(act_in[r*DATA_W +: DATA_W]) : '0;
      end else begin
        for (d = 0; d < r; d = d + 1) begin : g_skew
          if (d == 0) begin
            always_ff @(posedge clk or negedge rst_n) begin
              if (!rst_n)
                row_delay[r][d] <= '0;
              else
                row_delay[r][d] <= act_valid ? $signed(act_in[r*DATA_W +: DATA_W]) : '0;
            end
          end else begin
            always_ff @(posedge clk or negedge rst_n) begin
              if (!rst_n)
                row_delay[r][d] <= '0;
              else
                row_delay[r][d] <= row_delay[r][d-1];
            end
          end
        end
        assign row_input[r] = row_delay[r][r-1];
      end
      for (c = 0; c < N; c = c + 1) begin : g_cols
        pe #(.DATA_W(DATA_W), .ACC_W(ACC_W)) pe_cell (
          .clk(clk),
          .rst_n(rst_n),
          .w_load_en(w_load_en && w_load_row == r),
          .w_in($signed(w_load_data[c*DATA_W +: DATA_W])),
          .act_in(c == 0 ? row_input[r] : act_bus[r][c]),
          .psum_in(sum_bus[r][c]),
          .act_out(act_bus[r][c+1]),
          .psum_out(sum_bus[r+1][c])
        );
        if (r == 0)
          assign sum_bus[r][c] = '0;
      end
    end
    for (c = 0; c < N; c = c + 1) begin : g_deskew
      if (c == N-1) begin
        assign psum_out[c*ACC_W +: ACC_W] = sum_bus[N][c];
      end else begin
        for (d = 0; d < N-1-c; d = d + 1) begin : g_delay
          if (d == 0) begin
            always_ff @(posedge clk or negedge rst_n) begin
              if (!rst_n)
                deskew[c][d] <= '0;
              else
                deskew[c][d] <= sum_bus[N][c];
            end
          end else begin
            always_ff @(posedge clk or negedge rst_n) begin
              if (!rst_n)
                deskew[c][d] <= '0;
              else
                deskew[c][d] <= deskew[c][d-1];
            end
          end
        end
        assign psum_out[c*ACC_W +: ACC_W] = deskew[c][N-2-c];
      end
    end
  endgenerate

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_pipe <= '0;
      first_pipe <= '0;
      last_pipe <= '0;
      idx_pipe <= '0;
    end else begin
      valid_pipe[0] <= act_valid;
      first_pipe[0] <= act_first;
      last_pipe[0] <= act_last;
      idx_pipe[0 +: TILE_W] <= act_idx;
      for (integer k = 1; k < 2*N-1; k = k + 1) begin
        valid_pipe[k] <= valid_pipe[k-1];
        first_pipe[k] <= first_pipe[k-1];
        last_pipe[k] <= last_pipe[k-1];
        idx_pipe[k*TILE_W +: TILE_W] <= idx_pipe[(k-1)*TILE_W +: TILE_W];
      end
    end
  end

  assign psum_valid = valid_pipe[2*N-2];
  assign psum_first = first_pipe[2*N-2];
  assign psum_last = last_pipe[2*N-2];
  assign psum_idx = idx_pipe[(2*N-2)*TILE_W +: TILE_W];
endmodule
