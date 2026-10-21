`timescale 1ns/1ps

module accel_top import cnn_pkg::*; (
  input logic clk,
  input logic rst_n,
  input logic [7:0] s_axil_awaddr,
  input logic s_axil_awvalid,
  output logic s_axil_awready,
  input logic [31:0] s_axil_wdata,
  input logic [3:0] s_axil_wstrb,
  input logic s_axil_wvalid,
  output logic s_axil_wready,
  output logic [1:0] s_axil_bresp,
  output logic s_axil_bvalid,
  input logic s_axil_bready,
  input logic [7:0] s_axil_araddr,
  input logic s_axil_arvalid,
  output logic s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0] s_axil_rresp,
  output logic s_axil_rvalid,
  input logic s_axil_rready,
  output logic irq
);
  logic aw_saved;
  logic w_saved;
  logic [7:0] aw_addr_q;
  logic [31:0] w_data_q;
  logic [3:0] w_strb_q;
  logic write_fire;
  logic [7:0] write_addr;
  logic [31:0] write_data;
  logic [3:0] write_strb;
  logic [31:0] ctrl_reg;
  logic [13:0] dma_addr;
  logic [13:0] result_addr;
  logic [31:0] instr_w0;
  logic [31:0] instr_w1;
  logic [31:0] instr_w2;
  logic [31:0] instr_w3;
  logic [PC_W-1:0] instr_addr;
  logic start_pulse;
  logic instr_wr_en;
  logic dma_wr_en;
  logic [1:0] dma_wr_sel;
  logic [ADDR_W-1:0] dma_wr_addr;
  logic [DATA_W-1:0] dma_wr_data;
  logic res_rd_en;
  logic [ADDR_W-1:0] res_rd_addr;
  logic [DATA_W-1:0] res_rd_data;
  logic busy;
  logic done;
  logic err;
  logic gen_start;
  logic gen_done;
  logic swap_buf;
  layer_cfg_t cfg;
  logic w_load_en;
  logic [$clog2(N)-1:0] w_load_row;
  logic [N*DATA_W-1:0] w_load_data;
  logic act_valid;
  logic [N*DATA_W-1:0] act_in;
  logic act_first;
  logic act_last;
  logic [TILE_W-1:0] act_idx;
  logic psum_valid;
  logic [N*ACC_W-1:0] psum_out;
  logic psum_first;
  logic psum_last;
  logic [TILE_W-1:0] psum_idx;
  logic pool_valid;
  logic pool_first;
  logic pool_last;
  logic [N*DATA_W-1:0] pool_data;
  logic [N*ACC_W-1:0] bias_vec;
  logic out_wr_en;
  logic [N*DATA_W-1:0] out_wr_data;

  assign s_axil_awready = !aw_saved && !s_axil_bvalid;
  assign s_axil_wready = !w_saved && !s_axil_bvalid;
  assign s_axil_arready = !s_axil_rvalid;
  assign s_axil_bresp = 2'b00;
  assign s_axil_rresp = 2'b00;
  assign write_fire = (aw_saved || (s_axil_awvalid && s_axil_awready)) &&
                      (w_saved || (s_axil_wvalid && s_axil_wready)) && !s_axil_bvalid;
  assign write_addr = aw_saved ? aw_addr_q : s_axil_awaddr;
  assign write_data = w_saved ? w_data_q : s_axil_wdata;
  assign write_strb = w_saved ? w_strb_q : s_axil_wstrb;
  assign irq = done && ctrl_reg[1];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_saved <= 1'b0;
      w_saved <= 1'b0;
      aw_addr_q <= '0;
      w_data_q <= '0;
      w_strb_q <= '0;
      ctrl_reg <= '0;
      dma_addr <= '0;
      result_addr <= '0;
      instr_w0 <= '0;
      instr_w1 <= '0;
      instr_w2 <= '0;
      instr_w3 <= '0;
      instr_addr <= '0;
      start_pulse <= 1'b0;
      instr_wr_en <= 1'b0;
      dma_wr_en <= 1'b0;
      dma_wr_sel <= '0;
      dma_wr_addr <= '0;
      dma_wr_data <= '0;
      res_rd_en <= 1'b0;
      res_rd_addr <= '0;
      s_axil_bvalid <= 1'b0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata <= '0;
    end else begin
      start_pulse <= 1'b0;
      instr_wr_en <= 1'b0;
      dma_wr_en <= 1'b0;
      res_rd_en <= 1'b0;
      if (s_axil_awvalid && s_axil_awready) begin
        aw_saved <= 1'b1;
        aw_addr_q <= s_axil_awaddr;
      end
      if (s_axil_wvalid && s_axil_wready) begin
        w_saved <= 1'b1;
        w_data_q <= s_axil_wdata;
        w_strb_q <= s_axil_wstrb;
      end
      if (write_fire) begin
        aw_saved <= 1'b0;
        w_saved <= 1'b0;
        s_axil_bvalid <= 1'b1;
        case (write_addr)
          8'h00: begin
            if (write_strb[0]) begin
              ctrl_reg[1] <= write_data[1];
              if (write_data[0])
                start_pulse <= 1'b1;
            end
          end
          8'h10: dma_addr <= write_data[13:0];
          8'h14: begin
            dma_wr_en <= write_strb[0];
            dma_wr_sel <= write_data[9:8];
            dma_wr_addr <= dma_addr;
            dma_wr_data <= write_data[7:0];
            dma_addr <= dma_addr + 1'b1;
          end
          8'h18: begin
            result_addr <= write_data[13:0];
            res_rd_en <= 1'b1;
            res_rd_addr <= write_data[13:0];
          end
          8'h20: begin
            for (integer i = 0; i < 4; i = i + 1)
              if (write_strb[i]) instr_w0[i*8 +: 8] <= write_data[i*8 +: 8];
          end
          8'h24: begin
            for (integer i = 0; i < 4; i = i + 1)
              if (write_strb[i]) instr_w1[i*8 +: 8] <= write_data[i*8 +: 8];
          end
          8'h28: begin
            for (integer i = 0; i < 4; i = i + 1)
              if (write_strb[i]) instr_w2[i*8 +: 8] <= write_data[i*8 +: 8];
          end
          8'h2c: begin
            for (integer i = 0; i < 4; i = i + 1)
              if (write_strb[i]) instr_w3[i*8 +: 8] <= write_data[i*8 +: 8];
          end
          8'h30: begin
            instr_addr <= write_data[PC_W-1:0];
            instr_wr_en <= 1'b1;
          end
          default: begin end
        endcase
      end
      if (s_axil_bvalid && s_axil_bready)
        s_axil_bvalid <= 1'b0;
      if (s_axil_arvalid && s_axil_arready) begin
        s_axil_rvalid <= 1'b1;
        case (s_axil_araddr)
          8'h00: s_axil_rdata <= ctrl_reg;
          8'h04: s_axil_rdata <= {29'b0, err, done, busy};
          8'h08: s_axil_rdata <= 32'h01040408;
          8'h10: s_axil_rdata <= {18'b0, dma_addr};
          8'h18: s_axil_rdata <= {18'b0, result_addr};
          8'h1c: s_axil_rdata <= {24'b0, res_rd_data};
          8'h20: s_axil_rdata <= instr_w0;
          8'h24: s_axil_rdata <= instr_w1;
          8'h28: s_axil_rdata <= instr_w2;
          8'h2c: s_axil_rdata <= instr_w3;
          8'h30: s_axil_rdata <= {{(32-PC_W){1'b0}}, instr_addr};
          default: s_axil_rdata <= '0;
        endcase
      end
      if (s_axil_rvalid && s_axil_rready)
        s_axil_rvalid <= 1'b0;
    end
  end

  ctrl_unit control (
    .clk(clk), .rst_n(rst_n), .instr_wr_en(instr_wr_en), .instr_wr_addr(instr_addr),
    .instr_wr_data({instr_w3, instr_w2, instr_w1, instr_w0}), .start(start_pulse),
    .busy(busy), .done(done), .err(err), .cfg(cfg), .gen_start(gen_start),
    .gen_done(gen_done), .swap_buf(swap_buf)
  );

  mem_ctrl memory (
    .clk(clk), .rst_n(rst_n), .dma_wr_en(dma_wr_en), .dma_wr_sel(dma_wr_sel),
    .dma_wr_addr(dma_wr_addr), .dma_wr_data(dma_wr_data), .res_rd_en(res_rd_en),
    .res_rd_addr(res_rd_addr), .res_rd_data(res_rd_data), .cfg(cfg),
    .gen_start(gen_start), .gen_done(gen_done), .swap_buf(swap_buf),
    .w_load_en(w_load_en), .w_load_row(w_load_row), .w_load_data(w_load_data),
    .act_valid(act_valid), .act_in(act_in), .act_first(act_first), .act_last(act_last),
    .act_idx(act_idx), .pool_valid(pool_valid), .pool_first(pool_first),
    .pool_last(pool_last), .pool_data(pool_data), .bias_vec(bias_vec),
    .out_wr_en(out_wr_en), .out_wr_data(out_wr_data)
  );

  pe_array array (
    .clk(clk), .rst_n(rst_n), .w_load_en(w_load_en), .w_load_row(w_load_row),
    .w_load_data(w_load_data), .act_valid(act_valid), .act_in(act_in),
    .act_first(act_first), .act_last(act_last), .act_idx(act_idx),
    .psum_valid(psum_valid), .psum_out(psum_out), .psum_first(psum_first),
    .psum_last(psum_last), .psum_idx(psum_idx)
  );

  post_proc finishing (
    .clk(clk), .rst_n(rst_n), .cfg(cfg), .bias_vec(bias_vec),
    .psum_valid(psum_valid), .psum_in(psum_out), .psum_first(psum_first),
    .psum_last(psum_last), .psum_idx(psum_idx), .pool_valid(pool_valid),
    .pool_first(pool_first), .pool_last(pool_last), .pool_data(pool_data),
    .out_wr_en(out_wr_en), .out_wr_data(out_wr_data)
  );
endmodule
