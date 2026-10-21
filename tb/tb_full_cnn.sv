module tb_full_cnn;
  logic clk = 0;
  logic rst_n = 0;
  logic [7:0] awaddr;
  logic awvalid;
  logic awready;
  logic [31:0] wdata;
  logic [3:0] wstrb;
  logic wvalid;
  logic wready;
  logic [1:0] bresp;
  logic bvalid;
  logic bready;
  logic [7:0] araddr;
  logic arvalid;
  logic arready;
  logic [31:0] rdata;
  logic [1:0] rresp;
  logic rvalid;
  logic rready;
  logic irq;
  logic [31:0] expected_words [0:2];
  logic [31:0] expected_layer0 [0:1567];
  logic [31:0] expected_layer1 [0:391];
  logic [31:0] expected_layer2 [0:391];
  logic [31:0] expected_layer3 [0:97];
  logic [31:0] expected_layer4 [0:2];
  logic [31:0] read_value;
  integer i;
  integer j;
  integer layer_index;
  integer layer_words;
  logic [31:0] actual_word;
  integer timeout_count;

  always #5 clk = ~clk;

  accel_top dut (
    .clk(clk), .rst_n(rst_n),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .irq(irq)
  );

  task automatic write_reg(input logic [7:0] address, input logic [31:0] value);
    begin
      @(negedge clk);
      awaddr = address;
      awvalid = 1;
      wdata = value;
      wstrb = 4'hf;
      wvalid = 1;
      do @(posedge clk); while (!(awready && wready));
      @(negedge clk);
      awvalid = 0;
      wvalid = 0;
      wait (bvalid);
      @(posedge clk);
    end
  endtask

  task automatic read_reg(input logic [7:0] address, output logic [31:0] value);
    begin
      @(negedge clk);
      araddr = address;
      arvalid = 1;
      do @(posedge clk); while (!arready);
      @(negedge clk);
      arvalid = 0;
      wait (rvalid);
      value = rdata;
      @(posedge clk);
    end
  endtask

  initial begin
    awaddr = 0;
    awvalid = 0;
    wdata = 0;
    wstrb = 0;
    wvalid = 0;
    bready = 1;
    araddr = 0;
    arvalid = 0;
    rready = 1;
    for (i = 0; i < 4096; i = i + 1) begin
      dut.memory.weights[i] = 0;
      dut.memory.feature_a[i] = 0;
      dut.memory.feature_b[i] = 0;
    end
    for (i = 0; i < 256; i = i + 1)
      dut.memory.biases[i] = 0;
    for (i = 0; i < 64; i = i + 1)
      dut.control.instruction_mem[i] = 0;
    $readmemh("vectors/smoke/weights.hex", dut.memory.weights, 0, 1391);
    $readmemh("vectors/smoke/biases.hex", dut.memory.biases, 0, 6);
    $readmemh("vectors/smoke/input.hex", dut.memory.feature_a, 0, 783);
    $readmemh("vectors/smoke/golden_layer4.hex", expected_words);
    $readmemh("vectors/smoke/golden_layer0.hex", expected_layer0);
    $readmemh("vectors/smoke/golden_layer1.hex", expected_layer1);
    $readmemh("vectors/smoke/golden_layer2.hex", expected_layer2);
    $readmemh("vectors/smoke/golden_layer3.hex", expected_layer3);
    $readmemh("vectors/smoke/golden_layer4.hex", expected_layer4);
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    $readmemh("vectors/smoke/instructions.hex", dut.control.instruction_mem, 0, 5);
    write_reg(8'h00, 32'h00000001);
    timeout_count = 0;
    layer_index = 0;
    while (!dut.done && !dut.err && timeout_count < 150000) begin
      @(posedge clk);
      timeout_count = timeout_count + 1;
      if (dut.control.state == 3'd5) begin
        @(negedge clk);
        case (layer_index)
          0: layer_words = 1568;
          1: layer_words = 392;
          2: layer_words = 392;
          3: layer_words = 98;
          default: layer_words = 3;
        endcase
        for (j = 0; j < layer_words; j = j + 1) begin
          if (dut.memory.input_select)
            actual_word = dut.memory.feature_a[j];
          else
            actual_word = dut.memory.feature_b[j];
          case (layer_index)
            0: if (actual_word !== expected_layer0[j]) $fatal(1, "layer 0 word %0d mismatch: got %h expected %h", j, actual_word, expected_layer0[j]);
            1: if (actual_word !== expected_layer1[j]) $fatal(1, "layer 1 word %0d mismatch: got %h expected %h", j, actual_word, expected_layer1[j]);
            2: if (actual_word !== expected_layer2[j]) $fatal(1, "layer 2 word %0d mismatch: got %h expected %h", j, actual_word, expected_layer2[j]);
            3: if (actual_word !== expected_layer3[j]) $fatal(1, "layer 3 word %0d mismatch: got %h expected %h", j, actual_word, expected_layer3[j]);
            default: if (actual_word !== expected_layer4[j]) $fatal(1, "layer 4 word %0d mismatch: got %h expected %h", j, actual_word, expected_layer4[j]);
          endcase
        end
        layer_index = layer_index + 1;
      end
    end
    if (timeout_count == 150000) begin
      $display("mem_state=%0d ctrl_state=%0d tile=%0d group=%0d chunk=%0d stream=%0d drain=%0d wrote=%0d tile_pixels=%0d gen_done=%0b",
          dut.memory.state, dut.control.state, dut.memory.tile_count, dut.memory.group_count,
          dut.memory.chunk_count, dut.memory.stream_count, dut.memory.drain_count,
          dut.memory.write_count, dut.memory.tile_pixels, dut.gen_done);
      $fatal(1, "full CNN schedule timed out");
    end
    if (dut.err)
      $fatal(1, "full CNN program was rejected");
    for (i = 0; i < 12; i = i + 1) begin
      write_reg(8'h18, i);
      repeat (2) @(posedge clk);
      read_reg(8'h1c, read_value);
      if (read_value[7:0] !== expected_words[i/4][(i%4)*8 +: 8])
        $fatal(1, "final output byte %0d mismatch: got %0d expected %0d", i, read_value[7:0], expected_words[i/4][(i%4)*8 +: 8]);
    end
    $display("PASS: full 28x28 CONV/POOL/CONV/POOL/FC schedule matches Python integer vectors, cycles=%0d", timeout_count);
    $finish;
  end
endmodule
