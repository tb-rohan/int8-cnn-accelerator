`timescale 1ns/1ps

module tb_repeated_inference import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;
  logic [7:0] awaddr = 0;
  logic awvalid = 0;
  logic awready;
  logic [31:0] wdata = 0;
  logic [3:0] wstrb = 0;
  logic wvalid = 0;
  logic [1:0] bresp;
  logic bvalid;
  logic bready = 1;
  logic [7:0] araddr = 0;
  logic arvalid = 0;
  logic arready;
  logic [31:0] rdata;
  logic [1:0] rresp;
  logic rvalid;
  logic rready = 1;
  logic irq;

  integer timeout_count;
  logic [31:0] read_value;
  logic [7:0] result_byte;
  logic [7:0] golden [0:11];

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
      wstrb = 4'b1111;
      wvalid = 1;
      do @(posedge clk); while (!awready || !wready);
      @(negedge clk);
      awvalid = 0;
      wvalid = 0;
      wstrb = 0;
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

  task automatic dma_write(input logic [1:0] select, input logic [7:0] value);
    begin
      write_reg(8'h14, {22'b0, select, value});
    end
  endtask

  task automatic write_instruction(input integer address, input logic [127:0] value);
    begin
      write_reg(8'h20, value[31:0]);
      write_reg(8'h24, value[63:32]);
      write_reg(8'h28, value[95:64]);
      write_reg(8'h2c, value[127:96]);
      write_reg(8'h30, address);
    end
  endtask

  function automatic logic [127:0] make_instruction(
    input logic [1:0] op,
    input logic [7:0] in_h,
    input logic [7:0] in_w,
    input logic [9:0] in_c,
    input logic [7:0] out_c,
    input logic [3:0] kernel,
    input logic [3:0] stride,
    input logic [3:0] pad,
    input logic relu_en,
    input logic [11:0] w_base,
    input logic [7:0] b_base,
    input logic [15:0] quant_mult,
    input logic [4:0] quant_shift
  );
    make_instruction = {38'b0, op, in_h, in_w, in_c, out_c, kernel, stride, pad, relu_en, w_base, b_base, quant_mult, quant_shift};
  endfunction

  task automatic load_cnn_program();
    begin
      $readmemh("vectors/smoke/instructions.hex", dut.control.instruction_mem, 0, 5);
    end
  endtask

  task automatic load_weights_and_biases();
    begin
      $readmemh("vectors/smoke/weights.hex", dut.memory.weights, 0, 1391);
      $readmemh("vectors/smoke/biases.hex", dut.memory.biases, 0, 6);
    end
  endtask

  task automatic load_input_image();
    begin
      $readmemh("vectors/smoke/input.hex", dut.memory.feature_a, 0, 783);
    end
  endtask

  task automatic run_and_verify(input integer run_idx, input logic apply_reset_before_run);
    integer i;
    logic [31:0] expected_words [0:2];
    begin
      $readmemh("vectors/smoke/golden_layer4.hex", expected_words);
      if (apply_reset_before_run) begin
        @(negedge clk);
        rst_n = 0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);
        load_cnn_program();
        load_weights_and_biases();
      end

      load_input_image();

      // Launch inference
      write_reg(8'h00, 32'h00000001);

      timeout_count = 0;
      read_reg(8'h04, read_value);
      while (!read_value[1] && !read_value[2] && timeout_count < 100000) begin
        read_reg(8'h04, read_value);
        timeout_count = timeout_count + 1;
      end

      if (timeout_count >= 100000)
        $fatal(1, "RUN %0d: Accelerator timed out", run_idx);
      if (read_value[2])
        $fatal(1, "RUN %0d: Accelerator reported execution error", run_idx);

      for (i = 0; i < 12; i = i + 1) begin
        write_reg(8'h18, i);
        repeat (2) @(posedge clk);
        read_reg(8'h1c, read_value);
        result_byte = read_value[7:0];
        if (result_byte !== expected_words[i/4][(i%4)*8 +: 8])
          $fatal(1, "RUN %0d: Byte mismatch at %0d: got %h, expected %h", run_idx, i, result_byte, expected_words[i/4][(i%4)*8 +: 8]);
      end
      $display("RUN %0d PASSED: All 12 output bytes match golden reference", run_idx);
    end
  endtask

  initial begin
    // Initial power-on reset
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    $display("=== STARTING REPEATED INFERENCE REGRESSION ===");
    load_cnn_program();
    load_weights_and_biases();

    // Run 1: First inference
    run_and_verify(1, 0);

    // Run 2: Second consecutive inference with reset
    run_and_verify(2, 1);

    $display("=== REPEATED INFERENCE REGRESSION PASSED ===");
    $finish;
  end
endmodule
