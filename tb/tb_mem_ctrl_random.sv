module tb_mem_ctrl_random import cnn_pkg::*; ();
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
  logic [31:0] expected_weights [0:4095];
  logic [31:0] expected_a [0:4095];
  logic [31:0] expected_b [0:4095];
  logic [127:0] expected_bias [0:255];
  logic input_select_model = 0;
  integer random_seed = 32'h51a7c0de;
  integer random_value;
  integer transaction;
  integer address;
  integer lane;
  logic [31:0] active_word;

  always #5 clk = ~clk;

  mem_ctrl dut (.*);

  initial begin
    for (integer i = 0; i < 4096; i = i + 1) begin
      expected_weights[i] = '0;
      expected_a[i] = '0;
      expected_b[i] = '0;
      dut.weights[i] = '0;
      dut.feature_a[i] = '0;
      dut.feature_b[i] = '0;
    end
    for (integer i = 0; i < 256; i = i + 1) begin
      expected_bias[i] = '0;
      dut.biases[i] = '0;
    end

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_n = 1;

    for (transaction = 0; transaction < 600; transaction = transaction + 1) begin
      random_value = $urandom(random_seed) & 32'h7fffffff;
      dma_wr_sel = random_value % 3;
      random_value = $urandom(random_seed) & 32'h7fffffff;
      address = random_value % 16384;
      random_value = $urandom(random_seed) & 32'h7fffffff;
      dma_wr_data = random_value[7:0];
      random_value = $urandom(random_seed) & 32'h7fffffff;
      swap_buf = (random_value % 19) == 0;
      dma_wr_addr = address[ADDR_W-1:0];
      dma_wr_en = 1;
      @(posedge clk);
      case (dma_wr_sel)
        2'd0: expected_weights[address >> 2][(address & 3)*8 +: 8] = dma_wr_data;
        2'd1: begin
          if (input_select_model)
            expected_b[address >> 2][(address & 3)*8 +: 8] = dma_wr_data;
          else
            expected_a[address >> 2][(address & 3)*8 +: 8] = dma_wr_data;
        end
        2'd2: if (address < 4096)
          expected_bias[address >> 4][(address & 15)*8 +: 8] = dma_wr_data;
        default: begin end
      endcase
      if (swap_buf)
        input_select_model = !input_select_model;
      @(negedge clk);
      dma_wr_en = 0;
      swap_buf = 0;
    end

    for (transaction = 0; transaction < 4096; transaction = transaction + 1) begin
      if (dut.weights[transaction] !== expected_weights[transaction] ||
          dut.feature_a[transaction] !== expected_a[transaction] ||
          dut.feature_b[transaction] !== expected_b[transaction])
        $fatal(1, "random DMA word mismatch at word %0d: weights %h/%h feature_a %h/%h feature_b %h/%h", transaction,
            dut.weights[transaction], expected_weights[transaction], dut.feature_a[transaction], expected_a[transaction],
            dut.feature_b[transaction], expected_b[transaction]);
    end
    for (transaction = 0; transaction < 256; transaction = transaction + 1)
      if (dut.biases[transaction] !== expected_bias[transaction])
        $fatal(1, "random DMA bias mismatch at word %0d", transaction);

    for (transaction = 0; transaction < 200; transaction = transaction + 1) begin
      random_value = $urandom(random_seed) & 32'h7fffffff;
      address = random_value % 16384;
      res_rd_addr = address[ADDR_W-1:0];
      res_rd_en = 1;
      @(posedge clk);
      #1;
      if (input_select_model)
        active_word = expected_b[address >> 2];
      else
        active_word = expected_a[address >> 2];
      lane = address & 3;
      if (res_rd_data !== active_word[lane*8 +: 8])
        $fatal(1, "random result read mismatch at byte address %0d", address);
      @(negedge clk);
      res_rd_en = 0;
    end

    $display("PASS: randomized mem_ctrl DMA and result reads, seed=0x51a7c0de, writes=600, reads=200");
    $finish;
  end
endmodule
