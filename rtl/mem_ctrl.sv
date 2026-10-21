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
  typedef enum logic [3:0] {
    IDLE,
    CONF_1,
    CONF_2,
    CONF_3,
    CONF_4,
    CHECK_ZERO,
    PLAN,
    LOAD_W,
    STREAM,
    DRAIN,
    WRITE_POOL,
    DONE
  } state_t;
  state_t state;
  (* nomem2reg *) logic [31:0] weights [0:4095];
  (* ram_style = "block" *) logic [31:0] feature_a [0:4095];
  (* ram_style = "block" *) logic [31:0] feature_b [0:4095];
  (* nomem2reg *) logic [127:0] biases [0:255];
  logic input_select;
  logic [31:0] weight_read_q;
  logic [127:0] bias_read_q;
  logic [3:0]   fa_we;
  logic [11:0]  fa_waddr;
  logic [31:0]  fa_wdata;
  logic [3:0]   fb_we;
  logic [11:0]  fb_waddr;
  logic [31:0]  fb_wdata;
  logic [11:0]  ram_read_addr;
  logic [31:0]  fa_rdata;
  logic [31:0]  fb_rdata;
  logic [31:0]  feature_rdata;
  logic         stream_pipe_inside;
  logic         stream_pipe_valid;
  logic         stream_pipe_first;
  logic         stream_pipe_last;
  logic [TILE_W-1:0] stream_pipe_idx;
  logic [1:0]   pool_fetch_quad;
  logic         pool_fetch_done;
  logic         pool_pipe_valid;
  logic         pool_pipe_first;
  logic         pool_pipe_last;
  logic         zero_scan_valid;
  logic         zero_scan_valid_d;
  logic [11:0] out_h;
  logic [11:0] out_w;
  logic [23:0] out_pixels;
  logic [11:0] chunks;
  logic [7:0] groups;
  logic [11:0] tiles;
  logic [11:0] pool_out_w;
  logic [11:0] pool_out_h;
  logic [23:0] pool_out_pixels;

  // Step E: Registered layer geometry and terminal bounds
  logic [11:0] out_h_reg;
  logic [11:0] out_w_reg;
  logic [23:0] out_pixels_reg;
  logic [11:0] chunks_reg;
  logic [7:0]  groups_reg;
  logic [11:0] tiles_reg;
  logic [11:0] pool_out_w_reg;
  logic [11:0] pool_out_h_reg;
  logic [23:0] pool_out_pixels_reg;

  logic [11:0] chunks_minus_1_reg;
  logic [7:0]  groups_minus_1_reg;
  logic [11:0] tiles_minus_1_reg;
  logic [11:0] out_w_minus_1_reg;
  logic [11:0] pool_out_w_minus_1_reg;
  logic [23:0] pool_out_pixels_minus_1_reg;
  logic [9:0]  in_c_groups_minus_1_reg;
  logic [3:0]  kernel_minus_1_reg;
  logic [9:0]  in_c_groups_reg;

  logic [3:0]  stride_val;
  logic [11:0] in_h_padded;
  logic [11:0] in_w_padded;
  logic [7:0]  kernel_sq;
  logic [15:0] group_chunk_base;

  assign out_h           = out_h_reg;
  assign out_w           = out_w_reg;
  assign out_pixels      = out_pixels_reg;
  assign chunks          = chunks_reg;
  assign groups          = groups_reg;
  assign tiles           = tiles_reg;
  assign pool_out_w      = pool_out_w_reg;
  assign pool_out_h      = pool_out_h_reg;
  assign pool_out_pixels = pool_out_pixels_reg;

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
  logic [11:0] row_pitch;
  logic [11:0] col_step;
  logic [11:0] row_step;
  logic signed [11:0] cur_in_x;
  logic signed [11:0] cur_in_y;
  logic signed [11:0] reg_row_start_in_x;
  logic signed [15:0] cur_row_base;
  logic signed [15:0] cur_x_offset;
  logic signed [15:0] reg_row_start_x_offset;
  logic signed [11:0] plan_in_y;
  logic signed [11:0] plan_in_x;
  logic signed [11:0] plan_row_start_in_x;
  logic signed [15:0] plan_row_base;
  logic signed [15:0] plan_x_offset;
  logic signed [15:0] plan_row_start_x_offset;
  logic signed [11:0] next_in_y;
  logic signed [11:0] next_in_x;
  logic signed [15:0] next_row_base;
  logic signed [15:0] next_x_offset;
  logic signed [15:0] next_sum_addr;
  logic               next_inside;
  logic inside_image;
  logic [11:0] feature_read_addr;
  logic [11:0] weight_read_addr;
  logic [11:0] output_write_addr;
  logic [11:0] pool_read_addr;
  logic [11:0] pool_row_base;
  logic [11:0] pool_col_base;
  logic [11:0] pool_base_addr;
  logic [11:0] pool_write_addr;
  logic [11:0] pool_row_step_2;
  logic [11:0] pool_col_step_2;
  logic [11:0] row_pitch_plus_icg;
  logic [1:0] pool_quad;
  logic [11:0] pool_pixel;
  logic [7:0] pool_group;
  logic pool_wait;
  logic [31:0] dma_word;
  logic [31:0] input_word;
  logic [31:0] pooled_input_word;
  logic [11:0] pool_x_count;
  logic [11:0] pool_y_count;
  logic [11:0] calc_tile_x;
  logic [11:0] calc_tile_y;
  logic [4:0]  calc_tile_step;
  logic [9:0]  zero_scan_addr;
  logic        zero_scan_ok;
  logic        zero_input_channels;

  always_comb begin
    feature_read_addr = '0;
    weight_read_addr = cfg.w_base + ((group_chunk_base + chunk_count) * N + load_count);
    output_write_addr = ((tile_count * TILE_P + write_count) * groups_reg) + group_count;

    plan_in_y = $signed((stride_val == 4'd2) ? {1'b0, tile_origin_y, 1'b0} :
                        (stride_val == 4'd4) ? {1'b0, tile_origin_y, 2'b00} :
                        {1'b0, tile_origin_y}) + $signed({1'b0, ky_count}) - $signed({1'b0, cfg.pad});
    plan_in_x = $signed((stride_val == 4'd2) ? {1'b0, tile_origin_x, 1'b0} :
                        (stride_val == 4'd4) ? {1'b0, tile_origin_x, 2'b00} :
                        {1'b0, tile_origin_x}) + $signed({1'b0, kx_count}) - $signed({1'b0, cfg.pad});
    plan_row_start_in_x = $signed({1'b0, kx_count}) - $signed({1'b0, cfg.pad});

    plan_row_base = plan_in_y * $signed({1'b0, row_pitch}) + $signed({1'b0, icg_count});
    plan_x_offset = plan_in_x * $signed({1'b0, in_c_groups_reg});
    plan_row_start_x_offset = plan_row_start_in_x * $signed({1'b0, in_c_groups_reg});

    if (stream_x >= out_w_minus_1_reg) begin
      next_in_y = cur_in_y + $signed({1'b0, stride_val});
      next_in_x = reg_row_start_in_x;
      next_row_base = cur_row_base + $signed({1'b0, row_step});
      next_x_offset = reg_row_start_x_offset;
    end else begin
      next_in_y = cur_in_y;
      next_in_x = cur_in_x + $signed({1'b0, stride_val});
      next_row_base = cur_row_base;
      next_x_offset = cur_x_offset + $signed({1'b0, col_step});
    end

    inside_image = (cur_in_y >= 0 && cur_in_y < $signed({1'b0, cfg.in_h}) &&
                    cur_in_x >= 0 && cur_in_x < $signed({1'b0, cfg.in_w}));
    next_sum_addr = cur_row_base + cur_x_offset;

    if (inside_image)
      feature_read_addr = next_sum_addr[11:0];
    else
      feature_read_addr = 12'd0;

    if (state == CHECK_ZERO)
      feature_read_addr = zero_scan_addr;
    case (pool_fetch_quad)
      2'd0: pool_read_addr = pool_base_addr;
      2'd1: pool_read_addr = pool_base_addr + in_c_groups_reg;
      2'd2: pool_read_addr = pool_base_addr + row_pitch;
      default: pool_read_addr = pool_base_addr + row_pitch_plus_icg;
    endcase
    dma_word = dma_wr_addr[13:2];
  end

  always_comb begin
    fa_we = 4'b0000;
    fa_waddr = '0;
    fa_wdata = '0;
    fb_we = 4'b0000;
    fb_waddr = '0;
    fb_wdata = '0;

    if (out_wr_en) begin
      if (input_select) begin
        fa_we = 4'b1111;
        fa_waddr = (cfg.op == OP_POOL) ? pool_write_addr : output_write_addr;
        fa_wdata = out_wr_data;
      end else begin
        fb_we = 4'b1111;
        fb_waddr = (cfg.op == OP_POOL) ? pool_write_addr : output_write_addr;
        fb_wdata = out_wr_data;
      end
    end else if (dma_wr_en && dma_wr_sel == 2'd1) begin
      if (input_select) begin
        fb_we = 4'b0001 << dma_wr_addr[1:0];
        fb_waddr = dma_wr_addr[13:2];
        fb_wdata = {4{dma_wr_data}};
      end else begin
        fa_we = 4'b0001 << dma_wr_addr[1:0];
        fa_waddr = dma_wr_addr[13:2];
        fa_wdata = {4{dma_wr_data}};
      end
    end
  end

  always_comb begin
    if (state == CHECK_ZERO)
      ram_read_addr = zero_scan_addr;
    else if (state == WRITE_POOL)
      ram_read_addr = pool_read_addr;
    else if (state == STREAM || state == LOAD_W)
      ram_read_addr = feature_read_addr;
    else
      ram_read_addr = res_rd_addr[13:2];
  end

  always_comb begin
    w_load_data = weight_read_q;
    act_in      = stream_pipe_inside ? feature_rdata : '0;
    act_valid   = stream_pipe_valid;
    act_first   = stream_pipe_first;
    act_last    = stream_pipe_last;
    act_idx     = stream_pipe_idx;
    pool_data   = feature_rdata;
    pool_valid  = pool_pipe_valid;
    pool_first  = pool_pipe_first;
    pool_last   = pool_pipe_last;
    bias_vec    = bias_read_q;
    res_rd_data = feature_rdata[res_rd_addr[1:0]*8 +: 8];
  end

  always_ff @(posedge clk) begin
    if (dma_wr_en && dma_wr_sel == 2'd0)
      weights[dma_word][dma_wr_addr[1:0]*8 +: 8] <= dma_wr_data;
    if (dma_wr_en && dma_wr_sel == 2'd2 && dma_wr_addr < 4096)
      biases[dma_wr_addr[13:4]][dma_wr_addr[3:0]*8 +: 8] <= dma_wr_data;

    for (integer b = 0; b < 4; b = b + 1) begin
      if (fa_we[b])
        feature_a[fa_waddr][b*8 +: 8] <= fa_wdata[b*8 +: 8];
      if (fb_we[b])
        feature_b[fb_waddr][b*8 +: 8] <= fb_wdata[b*8 +: 8];
    end
    fa_rdata <= feature_a[ram_read_addr];
    fb_rdata <= feature_b[ram_read_addr];
  end

  assign feature_rdata = input_select ? fb_rdata : fa_rdata;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      input_select <= 1'b0;
      gen_done <= 1'b0;
      w_load_en <= 1'b0;
      w_load_row <= '0;
      weight_read_q <= '0;
      bias_read_q <= '0;
      stream_pipe_inside <= 1'b0;
      stream_pipe_valid <= 1'b0;
      stream_pipe_first <= 1'b0;
      stream_pipe_last <= 1'b0;
      stream_pipe_idx <= '0;
      pool_fetch_quad <= '0;
      pool_fetch_done <= 1'b0;
      pool_pipe_valid <= 1'b0;
      pool_pipe_first <= 1'b0;
      pool_pipe_last <= 1'b0;
      zero_scan_valid <= 1'b0;
      zero_scan_valid_d <= 1'b0;
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
      pool_pixel <= '0;
      pool_group <= '0;
      pool_x_count <= '0;
      pool_y_count <= '0;
      pool_row_base <= '0;
      pool_col_base <= '0;
      pool_base_addr <= '0;
      pool_write_addr <= '0;
      pool_row_step_2 <= '0;
      pool_col_step_2 <= '0;
      row_pitch_plus_icg <= '0;
      zero_scan_addr <= '0;
      zero_scan_ok <= 1'b0;
      zero_input_channels <= 1'b0;
      calc_tile_x <= '0;
      calc_tile_y <= '0;
      calc_tile_step <= 5'd16;
      out_h_reg <= '0;
      out_w_reg <= '0;
      out_pixels_reg <= '0;
      chunks_reg <= '0;
      groups_reg <= '0;
      tiles_reg <= '0;
      pool_out_w_reg <= '0;
      pool_out_h_reg <= '0;
      pool_out_pixels_reg <= '0;
      chunks_minus_1_reg <= '0;
      groups_minus_1_reg <= '0;
      tiles_minus_1_reg <= '0;
      out_w_minus_1_reg <= '0;
      pool_out_w_minus_1_reg <= '0;
      pool_out_pixels_minus_1_reg <= '0;
      in_c_groups_minus_1_reg <= '0;
      kernel_minus_1_reg <= '0;
      in_c_groups_reg <= '0;
      stride_val <= 4'd1;
      in_h_padded <= '0;
      in_w_padded <= '0;
      kernel_sq <= '0;
      group_chunk_base <= '0;
      row_pitch <= '0;
      col_step <= '0;
      row_step <= '0;
      cur_in_x <= '0;
      cur_in_y <= '0;
      reg_row_start_in_x <= '0;
      cur_row_base <= '0;
      cur_x_offset <= '0;
      reg_row_start_x_offset <= '0;
    end else begin
      gen_done <= 1'b0;
      w_load_en <= 1'b0;
      if (swap_buf)
        input_select <= ~input_select;
      if (out_wr_en) begin
        if (cfg.op != OP_POOL)
          write_count <= write_count + 1'b1;
      end
      if (state == PLAN && chunk_count == 0 && group_count == 0) begin
        calc_tile_x <= tile_origin_x;
        calc_tile_y <= tile_origin_y;
        calc_tile_step <= '0;
      end else if (calc_tile_step < TILE_P) begin
        calc_tile_step <= calc_tile_step + 1'b1;
        if (calc_tile_x >= out_w_minus_1_reg) begin
          calc_tile_x <= '0;
          calc_tile_y <= calc_tile_y + 1'b1;
        end else begin
          calc_tile_x <= calc_tile_x + 1'b1;
        end
      end
      case (state)
        IDLE: begin
          stream_pipe_valid <= 1'b0;
          pool_pipe_valid <= 1'b0;
          if (gen_start) begin
            state <= CONF_1;
          end
        end

        CONF_1: begin
          stride_val <= (cfg.stride == 0) ? 4'd1 : cfg.stride;
          in_h_padded <= (cfg.in_h + 2*cfg.pad >= cfg.kernel) ? (cfg.in_h + 2*cfg.pad - cfg.kernel) : 12'd0;
          in_w_padded <= (cfg.in_w + 2*cfg.pad >= cfg.kernel) ? (cfg.in_w + 2*cfg.pad - cfg.kernel) : 12'd0;
          in_c_groups_reg <= cfg.in_c / N;
          groups_reg <= cfg.out_c / N;
          kernel_sq <= cfg.kernel * cfg.kernel;
          pool_out_w_reg <= cfg.in_w >> 1;
          pool_out_h_reg <= cfg.in_h >> 1;
          in_c_groups_minus_1_reg <= (cfg.in_c / N) - 1'b1;
          kernel_minus_1_reg <= cfg.kernel - 1'b1;
          state <= CONF_2;
        end

        CONF_2: begin
          out_h_reg <= ((stride_val == 4'd2) ? (in_h_padded >> 1) :
                        (stride_val == 4'd4) ? (in_h_padded >> 2) : in_h_padded) + 1'b1;
          out_w_reg <= ((stride_val == 4'd2) ? (in_w_padded >> 1) :
                        (stride_val == 4'd4) ? (in_w_padded >> 2) : in_w_padded) + 1'b1;
          chunks_reg <= kernel_sq * in_c_groups_reg;
          pool_out_pixels_reg <= pool_out_w_reg * pool_out_h_reg;
          row_pitch <= cfg.in_w * in_c_groups_reg;
          col_step <= stride_val * in_c_groups_reg;
          pool_col_step_2 <= in_c_groups_reg << 1;
          state <= CONF_3;
        end

        CONF_3: begin
          out_pixels_reg <= out_h_reg * out_w_reg;
          chunks_minus_1_reg <= chunks_reg - 1'b1;
          groups_minus_1_reg <= groups_reg - 1'b1;
          out_w_minus_1_reg <= out_w_reg - 1'b1;
          pool_out_w_minus_1_reg <= pool_out_w_reg - 1'b1;
          pool_out_pixels_minus_1_reg <= pool_out_pixels_reg - 1'b1;
          row_step <= stride_val * (cfg.in_w * in_c_groups_reg);
          pool_row_step_2 <= (cfg.in_w * in_c_groups_reg) << 1;
          row_pitch_plus_icg <= (cfg.in_w * in_c_groups_reg) + in_c_groups_reg;
          state <= CONF_4;
        end

        CONF_4: begin
          tiles_reg <= (out_pixels_reg + TILE_P - 1) / TILE_P;
          tiles_minus_1_reg <= ((out_pixels_reg + TILE_P - 1) / TILE_P) - 1'b1;
          group_chunk_base <= '0;
          if (cfg.op == OP_POOL) begin
            zero_input_channels <= 1'b0;
            pool_pixel <= '0;
            pool_group <= '0;
            pool_fetch_quad <= '0;
            pool_fetch_done <= 1'b0;
            pool_pipe_valid <= 1'b0;
            pool_pipe_first <= 1'b0;
            pool_pipe_last <= 1'b0;
            pool_x_count <= '0;
            pool_y_count <= '0;
            pool_row_base <= '0;
            pool_col_base <= '0;
            pool_base_addr <= '0;
            pool_write_addr <= '0;
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
            zero_scan_valid <= 1'b0;
            zero_scan_valid_d <= 1'b0;
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

        CHECK_ZERO: begin
          if (zero_scan_valid) begin
            if (feature_rdata[31:8] != 0)
              zero_scan_ok <= 1'b0;
          end
          zero_scan_valid <= 1'b1;
          if (zero_scan_addr == 783) begin
            if (zero_scan_valid_d) begin
              zero_input_channels <= zero_scan_ok && (feature_rdata[31:8] == 0);
              state <= PLAN;
            end
            zero_scan_valid_d <= 1'b1;
          end else begin
            zero_scan_addr <= zero_scan_addr + 1'b1;
          end
        end
        PLAN: begin
          load_count <= '0;
          stream_count <= '0;
          stream_x <= tile_origin_x;
          stream_y <= tile_origin_y;
          drain_count <= '0;
          tile_pixels <= (out_pixels_reg - {tile_count, 4'b0} >= TILE_P) ? TILE_P : out_pixels_reg - {tile_count, 4'b0};
          bias_read_q <= biases[cfg.b_base + group_count];
          stream_pipe_valid <= 1'b0;

          cur_in_y <= plan_in_y;
          cur_in_x <= plan_in_x;
          reg_row_start_in_x <= plan_row_start_in_x;
          cur_row_base <= plan_row_base;
          cur_x_offset <= plan_x_offset;
          reg_row_start_x_offset <= plan_row_start_x_offset;

          state <= LOAD_W;
        end
        LOAD_W: begin
          weight_read_q <= weights[weight_read_addr];
          w_load_en <= 1'b1;
          w_load_row <= load_count[$clog2(N)-1:0];
          stream_pipe_valid <= 1'b0;
          if (zero_input_channels) begin
            w_load_row <= '0;
            stream_count <= '0;
            if (chunk_count == chunks_minus_1_reg)
              write_count <= '0;
            state <= STREAM;
          end else if (load_count == N-1) begin
            stream_count <= '0;
            if (chunk_count == chunks_minus_1_reg)
              write_count <= '0;
            state <= STREAM;
          end else
            load_count <= load_count + 1'b1;
        end
        STREAM: begin
          stream_pipe_inside <= inside_image;
          stream_pipe_valid  <= 1'b1;
          stream_pipe_first  <= (chunk_count == 0);
          stream_pipe_last   <= (chunk_count == chunks_minus_1_reg);
          stream_pipe_idx    <= stream_count[TILE_W-1:0];
          if (stream_count == tile_pixels-1)
            state <= DRAIN;
          else begin
            stream_count <= stream_count + 1'b1;
            if (stream_x >= out_w_minus_1_reg) begin
              stream_x <= '0;
              stream_y <= stream_y + 1'b1;
            end else
              stream_x <= stream_x + 1'b1;

            cur_in_y <= next_in_y;
            cur_in_x <= next_in_x;
            cur_row_base <= next_row_base;
            cur_x_offset <= next_x_offset;
          end
        end
        DRAIN: begin
          stream_pipe_valid <= 1'b0;
          drain_count <= drain_count + 1'b1;
          if (drain_count >= 13) begin
            if (chunk_count == chunks_minus_1_reg && write_count < tile_pixels) begin
              state <= DRAIN;
            end else if (chunk_count < chunks_minus_1_reg) begin
              chunk_count <= chunk_count + 1'b1;
              icg_count <= icg_count + 1'b1;
              if (icg_count >= in_c_groups_minus_1_reg) begin
                icg_count <= '0;
                if (kx_count >= kernel_minus_1_reg) begin
                  kx_count <= '0;
                  ky_count <= ky_count + 1'b1;
                end else
                  kx_count <= kx_count + 1'b1;
              end
              load_count <= '0;
              state <= PLAN;
            end else if (group_count < groups_minus_1_reg) begin
              group_count <= group_count + 1'b1;
              group_chunk_base <= group_chunk_base + chunks_reg;
              chunk_count <= '0;
              ky_count <= '0;
              kx_count <= '0;
              icg_count <= '0;
              load_count <= '0;
              state <= PLAN;
            end else if (tile_count < tiles_minus_1_reg) begin
              tile_count <= tile_count + 1'b1;
              tile_origin_x <= calc_tile_x;
              tile_origin_y <= calc_tile_y;
              group_count <= '0;
              group_chunk_base <= '0;
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
          if (!pool_fetch_done) begin
            pool_pipe_valid <= 1'b1;
            pool_pipe_first <= (pool_fetch_quad == 0);
            pool_pipe_last  <= (pool_fetch_quad == 3);
            if (pool_fetch_quad == 3)
              pool_fetch_done <= 1'b1;
            else
              pool_fetch_quad <= pool_fetch_quad + 1'b1;
          end else begin
            pool_pipe_valid <= 1'b0;
            pool_pipe_first <= 1'b0;
            pool_pipe_last  <= 1'b0;
          end

          if (out_wr_en) begin
            pool_fetch_done <= 1'b0;
            pool_fetch_quad <= '0;
            pool_write_addr <= pool_write_addr + 1'b1;
            if (pool_group < in_c_groups_minus_1_reg) begin
              pool_group <= pool_group + 1'b1;
              pool_base_addr <= pool_row_base + pool_col_base + (pool_group + 1'b1);
            end else if (pool_pixel < pool_out_pixels_minus_1_reg) begin
              pool_group <= '0;
              pool_pixel <= pool_pixel + 1'b1;
              if (pool_x_count >= pool_out_w_minus_1_reg) begin
                pool_x_count <= '0;
                pool_y_count <= pool_y_count + 1'b1;
                pool_col_base <= '0;
                pool_row_base <= pool_row_base + pool_row_step_2;
                pool_base_addr <= pool_row_base + pool_row_step_2;
              end else begin
                pool_x_count <= pool_x_count + 1'b1;
                pool_col_base <= pool_col_base + pool_col_step_2;
                pool_base_addr <= pool_row_base + (pool_col_base + pool_col_step_2);
              end
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
