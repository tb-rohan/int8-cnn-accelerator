module tb_mem_ctrl_zero_scan import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;
  logic dma_wr_en = 0;
  logic [1:0] dma_wr_sel = 0;
  logic [ADDR_W-1:0] dma_wr_addr = 0;
  logic [DATA_W-1:0] dma_wr_data = 0;
  logic res_rd_en = 0;
  logic [ADDR_W-1:0] res_rd_addr = 0;
  logic [DATA_W-1:0] res_rd_data;
  layer_cfg_t cfg = '0;
  logic gen_start = 0;
  logic gen_done;
  logic swap_buf = 0;
  logic w_load_en;
  logic [$clog2(N)-1:0] w_load_row;
  logic [N*DATA_W-1:0] w_load_data;
  logic act_valid;
  logic [N*DATA_W-1:0] act_in;
  logic act_first;
  logic act_last;
  logic [TILE_W-1:0] act_idx;
  logic pool_valid;
  logic pool_first;
  logic pool_last;
  logic [N*DATA_W-1:0] pool_data;
  logic [N*ACC_W-1:0] bias_vec;
  logic out_wr_en = 0;
  logic [N*DATA_W-1:0] out_wr_data = 0;
  integer timeout_count;

  always #5 clk = ~clk;

  mem_ctrl dut (.*);

  task automatic start_scan;
    begin
      @(negedge clk);
      gen_start = 1;
      @(negedge clk);
      gen_start = 0;
      timeout_count = 0;
      while (dut.state != dut.PLAN && timeout_count < 800) begin
        @(posedge clk);
        timeout_count = timeout_count + 1;
      end
      if (timeout_count == 800)
        $fatal(1, "input scan did not finish");
      #1;
    end
  endtask

  task automatic check_weight_loads(input integer expected_rows);
    integer rows;
    integer count;
    integer finished;
    begin
      rows = 0;
      count = 0;
      finished = 0;
      while (!finished && count < 12) begin
        @(negedge clk);
        if (w_load_en) begin
          if (w_load_row != rows[$clog2(N)-1:0])
            $fatal(1, "weight row order mismatch");
          rows = rows + 1;
        end
        if (dut.state == dut.STREAM)
          finished = 1;
        count = count + 1;
      end
      if (!finished || rows != expected_rows)
        $fatal(1, "expected %0d weight rows, observed %0d", expected_rows, rows);
    end
  endtask

  initial begin
    cfg.op = OP_CONV;
    cfg.in_h = 28;
    cfg.in_w = 28;
    cfg.in_c = 4;
    cfg.out_c = 8;
    cfg.kernel = 3;
    cfg.stride = 1;
    cfg.pad = 1;
    for (integer i = 0; i < 784; i = i + 1)
      dut.feature_a[i] = '0;

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    start_scan();
    if (!dut.zero_input_channels)
      $fatal(1, "all-zero upper lanes were not detected");
    check_weight_loads(1);

    @(negedge clk);
    rst_n = 0;
    dut.feature_a[100] = 32'h00010000;
    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    start_scan();
    if (dut.zero_input_channels)
      $fatal(1, "nonzero upper lane incorrectly enabled row skipping");
    check_weight_loads(4);

    $display("PASS: zero-lane scan skips redundant rows and retains all rows for nonzero lanes");
    $finish;
  end
endmodule
