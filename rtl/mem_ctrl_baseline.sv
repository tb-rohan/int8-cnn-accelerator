`timescale 1ns/1ps

module mem_ctrl import cnn_pkg::*; (
  input logic clk,
  input logic rst_n,
  input logic dma_wr_en,
  input logic [1:0] dma_wr_sel,
  input logic [ADDR_W-1:0] dma_wr_addr,
  input logic [DATA_W-1:0] dma_wr_data,
  input logic res_rd_en,
  input logic [ADDR_W-1:0] res_rd_addr,
  output logic [DATA_W-1:0] res_rd_data,
  input layer_cfg_t cfg,
  input logic gen_start,
  output logic gen_done,
  input logic swap_buf,
  output logic w_load_en,
  output logic [$clog2(N)-1:0] w_load_row,
  output logic [N*DATA_W-1:0] w_load_data,
  output logic act_valid,
  output logic [N*DATA_W-1:0] act_in,
  output logic act_first,
  output logic act_last,
  output logic [TILE_W-1:0] act_idx,
  output logic pool_valid,
  output logic pool_first,
  output logic pool_last,
  output logic [N*DATA_W-1:0] pool_data,
  output logic [N*ACC_W-1:0] bias_vec,
  input logic out_wr_en,
  input logic [N*DATA_W-1:0] out_wr_data
);
  typedef enum logic [3:0] {IDLE, CHECK_ZERO, PLAN, LOAD_W, STREAM, DRAIN, WRITE_POOL, DONE} state_t;
  state_t state;
  (* nomem2reg *) logic [31:0] weights [0:4095];
  (* nomem2reg *) logic [31:0] feature_a [0:4095];
  (* nomem2reg *) logic [31:0] feature_b [0:4095];
  (* nomem2reg *) logic [127:0] biases [0:255];
  logic input_select;
  logic [31:0] input_read_q;
  logic [31:0] weight_read_q;
  logic [127:0] bias_read_q;
  logic [31:0] pool_read_q;
  logic [DATA_W-1:0] result_read_q;
  logic [11:0] out_h;
  logic [11:0] out_w;
  logic [23:0] out_pixels;
  logic [11:0] chunks;
  logic [7:0] groups;
  logic [11:0] tiles;
  logic [11:0] tile_count;
  logic [11:0] tile_origin_x;
  logic [11:0] tile_origin_y;
  logic [11:0] stream_x;
  logic [11:0] stream_y;
  logic [7:0] group_count;
  logic [11:0] chunk_count;
  logic [3:0] ky_count;
  logic [3:0] kx_count;
  logic [9:0] icg_count;
  logic [1:0] load_count;
  logic [4:0] stream_count;
  logic [4:0] tile_pixels;
  logic [4:0] write_count;
  logic [4:0] drain_count;
  logic signed [15:0] input_y;
  logic signed [15:0] input_x;
  logic inside_image;
  logic [11:0] feature_read_addr;
  logic [11:0] weight_read_addr;
  logic [11:0] output_write_addr;
  logic [11:0] pool_read_addr;
  logic [1:0] pool_quad;
  logic [11:0] pool_pixel;
  logic [7:0] pool_group;
  logic pool_wait;
  logic [11:0] pool_out_w;
  logic [11:0] pool_out_h;
  logic [23:0] pool_out_pixels;
  logic [31:0] dma_word;
  logic [31:0] input_word;
  logic [31:0] pooled_input_word;
  logic [11:0] pool_x_count;
  logic [11:0] pool_y_count;
  logic [23:0] next_tile_origin;
  logic [9:0] zero_scan_addr;
  logic zero_scan_ok;
  logic zero_input_channels;

  function automatic logic [23:0] advance_tile_origin(input logic [11:0] x, input logic [11:0] y, input logic [11:0] width);
    integer next_x;
    integer next_y;
    begin
      next_x = x;
      next_y = y;
      for (integer pixel = 0; pixel < TILE_P; pixel = pixel + 1) begin
        if (next_x + 1 >= width) begin
          next_x = 0;
          next_y = next_y + 1;
        end else
          next_x = next_x + 1;
      end
      advance_tile_origin = {next_y[11:0], next_x[11:0]};
    end
  endfunction

  always_comb begin
    out_h = (cfg.in_h + 2*cfg.pad - cfg.kernel) / (cfg.stride == 0 ? 1 : cfg.stride) + 1;
    out_w = (cfg.in_w + 2*cfg.pad - cfg.kernel) / (cfg.stride == 0 ? 1 : cfg.stride) + 1;
    out_pixels = out_h * out_w;
    chunks = cfg.kernel * cfg.kernel * (cfg.in_c / N);
    groups = cfg.out_c / N;
    tiles = (out_pixels + TILE_P - 1) / TILE_P;
    feature_read_addr = '0;
    weight_read_addr = cfg.w_base + ((group_count * chunks + chunk_count) * N + load_count);
    output_write_addr = ((tile_count * TILE_P + write_count) * groups) + group_count;
    input_y = stream_y * cfg.stride + ky_count - cfg.pad;
    input_x = stream_x * cfg.stride + kx_count - cfg.pad;
    inside_image = input_y >= 0 && input_y < cfg.in_h && input_x >= 0 && input_x < cfg.in_w;
    if (inside_image)
      feature_read_addr = (input_y * cfg.in_w + input_x) * (cfg.in_c / N) + icg_count;
    if (state == CHECK_ZERO)
      feature_read_addr = zero_scan_addr;
    pool_out_w = cfg.in_w >> 1;
    pool_out_h = cfg.in_h >> 1;
    pool_out_pixels = pool_out_w * pool_out_h;
    case (pool_quad)
      2'd0: pool_read_addr = ((pool_y_count*2) * cfg.in_w + pool_x_count*2) * (cfg.in_c/N) + pool_group;
      2'd1: pool_read_addr = ((pool_y_count*2) * cfg.in_w + pool_x_count*2+1) * (cfg.in_c/N) + pool_group;
      2'd2: pool_read_addr = ((pool_y_count*2+1) * cfg.in_w + pool_x_count*2) * (cfg.in_c/N) + pool_group;
      default: pool_read_addr = ((pool_y_count*2+1) * cfg.in_w + pool_x_count*2+1) * (cfg.in_c/N) + pool_group;
    endcase
    next_tile_origin = advance_tile_origin(tile_origin_x, tile_origin_y, out_w);
    if (input_select) begin
      input_word = feature_b[feature_read_addr];
      pooled_input_word = feature_b[pool_read_addr];
    end else begin
      input_word = feature_a[feature_read_addr];
      pooled_input_word = feature_a[pool_read_addr];
    end
    dma_word = dma_wr_addr[13:2];
  end

  always_comb begin
    w_load_data = weight_read_q;
    act_in = input_read_q;
    pool_data = pool_read_q;
    bias_vec = bias_read_q;
    res_rd_data = result_read_q;
  end

  always_ff @(posedge clk) begin
    if (dma_wr_en && dma_wr_sel == 2'd0)
      weights[dma_word][dma_wr_addr[1:0]*8 +: 8] <= dma_wr_data;
    if (dma_wr_en && dma_wr_sel == 2'd2 && dma_wr_addr < 4096)
      biases[dma_wr_addr[13:4]][dma_wr_addr[3:0]*8 +: 8] <= dma_wr_data;

    if (out_wr_en) begin
      if (input_select)
        feature_a[(cfg.op == OP_POOL) ? (pool_pixel*(cfg.in_c/N)+pool_group) : output_write_addr] <= out_wr_data;
      else
        feature_b[(cfg.op == OP_POOL) ? (pool_pixel*(cfg.in_c/N)+pool_group) : output_write_addr] <= out_wr_data;
    end else if (dma_wr_en && dma_wr_sel == 2'd1) begin
      if (input_select)
        feature_b[dma_word][dma_wr_addr[1:0]*8 +: 8] <= dma_wr_data;
      else
        feature_a[dma_word][dma_wr_addr[1:0]*8 +: 8] <= dma_wr_data;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      input_select <= 1'b0;
      gen_done <= 1'b0;
      w_load_en <= 1'b0;
      w_load_row <= '0;
      weight_read_q <= '0;
      input_read_q <= '0;
      pool_read_q <= '0;
      result_read_q <= '0;
      bias_read_q <= '0;
      act_valid <= 1'b0;
      act_first <= 1'b0;
      act_last <= 1'b0;
      act_idx <= '0;
      pool_valid <= 1'b0;
      pool_first <= 1'b0;
      pool_last <= 1'b0;
      tile_count <= '0;
      tile_origin_x <= '0;
      tile_origin_y <= '0;
      stream_x <= '0;
      stream_y <= '0;
      group_count <= '0;
      chunk_count <= '0;
      ky_count <= '0;
      kx_count <= '0;
      icg_count <= '0;
      load_count <= '0;
      stream_count <= '0;
      tile_pixels <= '0;
      write_count <= '0;
      drain_count <= '0;
      pool_quad <= '0;
      pool_pixel <= '0;
      pool_group <= '0;
      pool_x_count <= '0;
      pool_y_count <= '0;
      pool_wait <= 1'b0;
      zero_scan_addr <= '0;
      zero_scan_ok <= 1'b0;
      zero_input_channels <= 1'b0;
    end else begin
      gen_done <= 1'b0;
      w_load_en <= 1'b0;
      act_valid <= 1'b0;
      pool_valid <= 1'b0;
      if (swap_buf)
        input_select <= ~input_select;
      if (res_rd_en) begin
        if (input_select)
          result_read_q <= feature_b[res_rd_addr[13:2]][res_rd_addr[1:0]*8 +: 8];
        else
          result_read_q <= feature_a[res_rd_addr[13:2]][res_rd_addr[1:0]*8 +: 8];
      end
      if (out_wr_en) begin
        if (cfg.op != OP_POOL)
          write_count <= write_count + 1'b1;
      end
      case (state)
        IDLE: begin
          if (gen_start) begin
            if (cfg.op == OP_POOL) begin
              zero_input_channels <= 1'b0;
              pool_pixel <= '0;
              pool_group <= '0;
              pool_quad <= '0;
              pool_x_count <= '0;
              pool_y_count <= '0;
              pool_wait <= 1'b0;
              state <= WRITE_POOL;
            end else if (cfg.op == OP_CONV && cfg.in_h == 28 && cfg.in_w == 28 &&
                         cfg.in_c == N && cfg.out_c == 8 && cfg.kernel == 3 &&
                         cfg.stride == 1 && cfg.pad == 1) begin
              tile_count <= '0;
              tile_origin_x <= '0;
              tile_origin_y <= '0;
              group_count <= '0;
              chunk_count <= '0;
              ky_count <= '0;
              kx_count <= '0;
              icg_count <= '0;
              write_count <= '0;
              stream_count <= '0;
              zero_scan_addr <= '0;
              zero_scan_ok <= 1'b1;
              zero_input_channels <= 1'b0;
              state <= CHECK_ZERO;
            end else begin
              zero_input_channels <= 1'b0;
              tile_count <= '0;
              tile_origin_x <= '0;
              tile_origin_y <= '0;
              group_count <= '0;
              chunk_count <= '0;
              ky_count <= '0;
              kx_count <= '0;
              icg_count <= '0;
              write_count <= '0;
              stream_count <= '0;
              state <= PLAN;
            end
          end
        end
        CHECK_ZERO: begin
          if (input_word[31:8] != 0)
            zero_scan_ok <= 1'b0;
          if (zero_scan_addr == 783) begin
            zero_input_channels <= zero_scan_ok && (input_word[31:8] == 0);
            state <= PLAN;
          end else
            zero_scan_addr <= zero_scan_addr + 1'b1;
        end
        PLAN: begin
          load_count <= '0;
          stream_count <= '0;
          stream_x <= tile_origin_x;
          stream_y <= tile_origin_y;
          drain_count <= '0;
          tile_pixels <= (out_pixels - tile_count*TILE_P >= TILE_P) ? TILE_P : out_pixels - tile_count*TILE_P;
          bias_read_q <= biases[cfg.b_base + group_count];
          state <= LOAD_W;
        end
        LOAD_W: begin
          weight_read_q <= weights[weight_read_addr];
          w_load_en <= 1'b1;
          w_load_row <= load_count[$clog2(N)-1:0];
          if (zero_input_channels) begin
            w_load_row <= '0;
            stream_count <= '0;
            if (chunk_count == chunks-1)
              write_count <= '0;
            state <= STREAM;
          end else if (load_count == N-1) begin
            stream_count <= '0;
            if (chunk_count == chunks-1)
              write_count <= '0;
            state <= STREAM;
          end else
            load_count <= load_count + 1'b1;
        end
        STREAM: begin
          input_read_q <= inside_image ? input_word : '0;
          act_valid <= 1'b1;
          act_first <= chunk_count == 0;
          act_last <= chunk_count == chunks-1;
          act_idx <= stream_count[TILE_W-1:0];
          if (stream_count == tile_pixels-1)
            state <= DRAIN;
          else begin
            stream_count <= stream_count + 1'b1;
            if (stream_x + 1 >= out_w) begin
              stream_x <= '0;
              stream_y <= stream_y + 1'b1;
            end else
              stream_x <= stream_x + 1'b1;
          end
        end
        DRAIN: begin
          drain_count <= drain_count + 1'b1;
          if (drain_count >= 13) begin
            if (chunk_count == chunks-1 && write_count < tile_pixels) begin
              state <= DRAIN;
            end else if (chunk_count + 1 < chunks) begin
              chunk_count <= chunk_count + 1'b1;
              icg_count <= icg_count + 1'b1;
              if (icg_count + 1 >= cfg.in_c/N) begin
                icg_count <= '0;
                if (kx_count + 1 >= cfg.kernel) begin
                  kx_count <= '0;
                  ky_count <= ky_count + 1'b1;
                end else
                  kx_count <= kx_count + 1'b1;
              end
              load_count <= '0;
              state <= PLAN;
            end else if (group_count + 1 < groups) begin
              group_count <= group_count + 1'b1;
              chunk_count <= '0;
              ky_count <= '0;
              kx_count <= '0;
              icg_count <= '0;
              load_count <= '0;
              state <= PLAN;
            end else if (tile_count + 1 < tiles) begin
              tile_count <= tile_count + 1'b1;
              tile_origin_x <= next_tile_origin[11:0];
              tile_origin_y <= next_tile_origin[23:12];
              group_count <= '0;
              chunk_count <= '0;
              ky_count <= '0;
              kx_count <= '0;
              icg_count <= '0;
              load_count <= '0;
              state <= PLAN;
            end else if (write_count >= tile_pixels) begin
              state <= DONE;
            end
          end
        end
        WRITE_POOL: begin
          if (!pool_wait) begin
            pool_read_q <= pooled_input_word;
            pool_valid <= 1'b1;
            pool_first <= pool_quad == 0;
            pool_last <= pool_quad == 3;
            if (pool_quad == 3)
              pool_wait <= 1'b1;
            else
              pool_quad <= pool_quad + 1'b1;
          end
          if (out_wr_en) begin
            pool_wait <= 1'b0;
            pool_quad <= '0;
            if (pool_group + 1 < cfg.in_c/N)
              pool_group <= pool_group + 1'b1;
            else if (pool_pixel + 1 < pool_out_pixels) begin
              pool_group <= '0;
              pool_pixel <= pool_pixel + 1'b1;
              if (pool_x_count + 1 >= pool_out_w) begin
                pool_x_count <= '0;
                pool_y_count <= pool_y_count + 1'b1;
              end else
                pool_x_count <= pool_x_count + 1'b1;
            end else
              state <= DONE;
          end
        end
        DONE: begin
          gen_done <= 1'b1;
          zero_input_channels <= 1'b0;
          state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  state_t assertion_state;
  always @(posedge clk) begin
    assertion_state <= state;
    if (rst_n) begin
      assert (!gen_start || assertion_state == IDLE)
          else $error("mem_ctrl start pulse was not preceded by an idle dispatch");
      assert (!zero_input_channels || (cfg.op == OP_CONV && cfg.in_h == 28 && cfg.in_w == 28 &&
          cfg.in_c == N && cfg.out_c == 8 && cfg.kernel == 3 && cfg.stride == 1 && cfg.pad == 1))
          else $error("zero-channel skip enabled for an unsupported descriptor");
      assert (!out_wr_en || assertion_state == STREAM || assertion_state == DRAIN || assertion_state == WRITE_POOL)
          else $error("post-processor write was generated in state %0d after %0d", state, assertion_state);
    end
  end
`endif
endmodule
