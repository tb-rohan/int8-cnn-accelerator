module tb_post_proc import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;
  layer_cfg_t cfg;
  logic [N*ACC_W-1:0] bias_vec;
  logic psum_valid;
  logic [N*ACC_W-1:0] psum_in;
  logic psum_first;
  logic psum_last;
  logic [TILE_W-1:0] psum_idx;
  logic pool_valid;
  logic pool_first;
  logic pool_last;
  logic [N*DATA_W-1:0] pool_data;
  logic out_wr_en;
  logic [N*DATA_W-1:0] out_wr_data;
  integer lane;
  integer quad;

  always #5 clk = ~clk;

  post_proc dut (.*);

  initial begin
    cfg = '0;
    cfg.quant_mult = 1;
    bias_vec = '0;
    psum_valid = 0;
    psum_in = 0;
    psum_first = 0;
    psum_last = 0;
    psum_idx = 0;
    pool_valid = 0;
    pool_first = 0;
    pool_last = 0;
    pool_data = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    psum_in[0*ACC_W +: ACC_W] = 50;
    psum_in[1*ACC_W +: ACC_W] = -150;
    psum_in[2*ACC_W +: ACC_W] = 130;
    psum_in[3*ACC_W +: ACC_W] = -10;
    psum_valid = 1;
    psum_first = 1;
    psum_last = 1;
    @(posedge clk);
    @(negedge clk);
    psum_valid = 0;
    wait (out_wr_en === 1'b1);
    #1;
    if (!out_wr_en || $signed(out_wr_data[7:0]) != 50 || $signed(out_wr_data[15:8]) != -128 ||
        $signed(out_wr_data[23:16]) != 127 || $signed(out_wr_data[31:24]) != -10)
      $fatal(1, "requantization, single-chunk, or saturation mismatch");
    @(negedge clk);
    psum_valid = 0;
    psum_first = 0;
    psum_last = 0;
    cfg.quant_mult = 2;
    cfg.quant_shift = 1;
    psum_in = 0;
    psum_in[0 +: ACC_W] = -3;
    psum_valid = 1;
    psum_first = 1;
    psum_last = 1;
    @(posedge clk);
    @(negedge clk);
    psum_valid = 0;
    wait (out_wr_en === 1'b1);
    #1;
    if ($signed(out_wr_data[7:0]) != -3)
      $fatal(1, "negative rounded shift mismatch: got %0d", $signed(out_wr_data[7:0]));
    @(negedge clk);
    psum_valid = 0;
    cfg.relu_en = 1;
    cfg.quant_mult = 1;
    cfg.quant_shift = 0;
    psum_in[0 +: ACC_W] = -9;
    psum_valid = 1;
    psum_first = 1;
    psum_last = 1;
    @(posedge clk);
    @(negedge clk);
    psum_valid = 0;
    wait (out_wr_en === 1'b1);
    #1;
    if ($signed(out_wr_data[7:0]) != 0)
      $fatal(1, "ReLU mismatch");
    @(negedge clk);
    psum_valid = 0;
    cfg.relu_en = 0;
    bias_vec[0 +: ACC_W] = 5;
    psum_in[0 +: ACC_W] = 10;
    psum_first = 1;
    psum_last = 0;
    psum_valid = 1;
    @(posedge clk);
    @(negedge clk);
    psum_in[0 +: ACC_W] = 20;
    psum_first = 0;
    psum_last = 1;
    @(posedge clk);
    @(negedge clk);
    psum_valid = 0;
    wait (out_wr_en === 1'b1);
    #1;
    if (!out_wr_en || $signed(out_wr_data[7:0]) != 35)
      $fatal(1, "multi-chunk accumulation or bias mismatch");
    @(negedge clk);
    psum_valid = 0;
    psum_first = 0;
    psum_last = 0;
    bias_vec = '0;
    pool_valid = 1;
    for (quad = 0; quad < 4; quad = quad + 1) begin
      pool_first = quad == 0;
      pool_last = quad == 3;
      for (lane = 0; lane < N; lane = lane + 1)
        pool_data[lane*DATA_W +: DATA_W] = (quad * 4 + lane) - 5;
      @(posedge clk);
      #1;
      @(negedge clk);
    end
    pool_valid = 0;
    #1;
    if (!out_wr_en)
      $fatal(1, "pool output was not emitted");
    for (lane = 0; lane < N; lane = lane + 1)
      if ($signed(out_wr_data[lane*DATA_W +: DATA_W]) != 7 + lane)
        $fatal(1, "pool lane %0d mismatch", lane);
    $display("PASS: requantization, shift-zero, rounding, ReLU, saturation, accumulation, bias, and pooling");
    $finish;
  end
endmodule
