module tb_top;
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
  logic [31:0] read_value;
  logic [127:0] instruction;
  integer i;
  integer timeout_count;
  logic [7:0] result_byte;
  logic [7:0] input_bytes [0:15];
  logic [31:0] weight_words [0:7];
  logic [31:0] batch_weights [0:1391];
  logic [127:0] batch_biases [0:6];
  logic [127:0] batch_instructions [0:5];
  logic [31:0] batch_image_words [0:783];
  logic [7:0] expected_output [0:11];
  logic [7:0] actual_output [0:11];
  integer batch_start;
  integer batch_count;
  integer batch_image;
  integer image_index;
  integer input_file_fd;
  integer golden_file_fd;
  integer label_file_fd;
  integer result_file_fd;
  integer scan_count;
  integer byte_index;
  integer word_index;
  integer expected_class;
  integer actual_class;
  integer expected_score;
  integer actual_score;
  integer label_value;
  integer mismatch_count;
  integer batch_mismatches;
  integer accelerator_cycles;
  integer total_cycles;
  string input_file;
  string golden_file;
  string label_file;
  string result_file;
  string expected_hex;
  string actual_hex;

  task automatic run_full_batch;
    begin
      if (!$value$plusargs("START_INDEX=%d", batch_start)) $fatal(1, "missing START_INDEX");
      if (!$value$plusargs("IMAGE_COUNT=%d", batch_count)) $fatal(1, "missing IMAGE_COUNT");
      if (!$value$plusargs("INPUT_FILE=%s", input_file)) $fatal(1, "missing INPUT_FILE");
      if (!$value$plusargs("GOLDEN_FILE=%s", golden_file)) $fatal(1, "missing GOLDEN_FILE");
      if (!$value$plusargs("LABEL_FILE=%s", label_file)) $fatal(1, "missing LABEL_FILE");
      if (!$value$plusargs("RESULT_FILE=%s", result_file)) $fatal(1, "missing RESULT_FILE");
      $readmemh("vectors/smoke/weights.hex", batch_weights);
      $readmemh("vectors/smoke/biases.hex", batch_biases);
      $readmemh("vectors/smoke/instructions.hex", batch_instructions);
      input_file_fd = $fopen(input_file, "r");
      golden_file_fd = $fopen(golden_file, "r");
      label_file_fd = $fopen(label_file, "r");
      result_file_fd = $fopen(result_file, "w");
      if (!input_file_fd || !golden_file_fd || !label_file_fd || !result_file_fd)
        $fatal(1, "unable to open batch files");
      $fdisplay(result_file_fd, "image_index,label,python_class,rtl_class,expected_hex,rtl_hex,mismatched_bytes,accelerator_cycles,status");
      repeat (4) @(posedge clk);
      rst_n = 1;
      write_reg(8'h10, 0);
      for (word_index = 0; word_index < 1392; word_index = word_index + 1)
        for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
          dma_write(0, batch_weights[word_index][byte_index*8 +: 8]);
      write_reg(8'h10, 0);
      for (word_index = 0; word_index < 7; word_index = word_index + 1)
        for (byte_index = 0; byte_index < 16; byte_index = byte_index + 1)
          dma_write(2, batch_biases[word_index][byte_index*8 +: 8]);
      for (word_index = 0; word_index < 6; word_index = word_index + 1)
        write_instruction(word_index, batch_instructions[word_index]);
      total_cycles = 0;
      batch_mismatches = 0;
      for (batch_image = 0; batch_image < batch_count; batch_image = batch_image + 1) begin
        image_index = batch_start + batch_image;
        if (batch_image > 0)
          write_reg(8'h00, 32'h00000001);
        for (word_index = 0; word_index < 784; word_index = word_index + 1) begin
          scan_count = $fscanf(input_file_fd, "%h", batch_image_words[word_index]);
          if (scan_count != 1) $fatal(1, "input file ended at image %0d word %0d", image_index, word_index);
        end
        for (byte_index = 0; byte_index < 12; byte_index = byte_index + 1) begin
          scan_count = $fscanf(golden_file_fd, "%h", expected_output[byte_index]);
          if (scan_count != 1) $fatal(1, "golden file ended at image %0d byte %0d", image_index, byte_index);
        end
        scan_count = $fscanf(label_file_fd, "%d", label_value);
        if (scan_count != 1) $fatal(1, "label file ended at image %0d", image_index);
        write_reg(8'h10, 0);
        for (word_index = 0; word_index < 784; word_index = word_index + 1)
          for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
            dma_write(1, batch_image_words[word_index][byte_index*8 +: 8]);
        accelerator_cycles = 0;
        write_reg(8'h00, 32'h00000001);
        @(negedge clk);
        while (!dut.done && !dut.err && accelerator_cycles < 150000) begin
          @(posedge clk);
          accelerator_cycles = accelerator_cycles + 1;
        end
        if (accelerator_cycles >= 150000) $fatal(1, "accelerator timed out at image %0d", image_index);
        if (dut.err) $fatal(1, "accelerator rejected the program at image %0d", image_index);
        read_reg(8'h04, read_value);
        if (read_value[0] || !read_value[1] || read_value[2])
          $fatal(1, "invalid completion status at image %0d: %h", image_index, read_value);
        for (byte_index = 0; byte_index < 12; byte_index = byte_index + 1) begin
          write_reg(8'h18, byte_index);
          repeat (2) @(posedge clk);
          read_reg(8'h1c, read_value);
          actual_output[byte_index] = read_value[7:0];
        end
        expected_class = 0;
        actual_class = 0;
        expected_score = $signed(expected_output[0]);
        actual_score = $signed(actual_output[0]);
        expected_hex = "";
        actual_hex = "";
        mismatch_count = 0;
        for (byte_index = 0; byte_index < 12; byte_index = byte_index + 1) begin
          expected_hex = {expected_hex, $sformatf("%02x", expected_output[byte_index])};
          actual_hex = {actual_hex, $sformatf("%02x", actual_output[byte_index])};
          if (actual_output[byte_index] !== expected_output[byte_index])
            mismatch_count = mismatch_count + 1;
          if (byte_index < 10) begin
            if ($signed(expected_output[byte_index]) > expected_score) begin
              expected_score = $signed(expected_output[byte_index]);
              expected_class = byte_index;
            end
            if ($signed(actual_output[byte_index]) > actual_score) begin
              actual_score = $signed(actual_output[byte_index]);
              actual_class = byte_index;
            end
          end
        end
        batch_mismatches = batch_mismatches + mismatch_count;
        total_cycles = total_cycles + accelerator_cycles;
        $fdisplay(result_file_fd, "%0d,%0d,%0d,%0d,%s,%s,%0d,%0d,%s", image_index, label_value, expected_class, actual_class, expected_hex, actual_hex, mismatch_count, accelerator_cycles, mismatch_count == 0 ? "PASS" : "FAIL");
        $fflush(result_file_fd);
        if (mismatch_count != 0) begin
          $display("MISMATCH image=%0d label=%0d golden_class=%0d rtl_class=%0d expected=%s actual=%s bytes=%0d", image_index, label_value, expected_class, actual_class, expected_hex, actual_hex, mismatch_count);
          $fclose(result_file_fd);
          $fclose(input_file_fd);
          $fclose(golden_file_fd);
          $fclose(label_file_fd);
          $finish;
        end
      end
      $fclose(result_file_fd);
      $fclose(input_file_fd);
      $fclose(golden_file_fd);
      $fclose(label_file_fd);
      $display("PASS: batch first=%0d last=%0d images=%0d mismatches=%0d accelerator_cycles=%0d", batch_start, batch_start + batch_count - 1, batch_count, batch_mismatches, total_cycles);
      $finish;
    end
  endtask

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
    if ($test$plusargs("BATCH_MODE")) begin
      run_full_batch();
    end else begin
    for (i = 0; i < 16; i = i + 1)
      input_bytes[i] = 0;
    for (i = 0; i < 8; i = i + 1)
      weight_words[i] = 0;
    input_bytes[0] = 1;
    input_bytes[1] = 10;
    input_bytes[2] = 2;
    input_bytes[3] = 20;
    input_bytes[4] = 3;
    input_bytes[5] = 30;
    input_bytes[6] = 4;
    input_bytes[7] = 40;
    input_bytes[8] = 5;
    input_bytes[9] = 50;
    input_bytes[10] = 6;
    input_bytes[11] = 60;
    input_bytes[12] = 7;
    input_bytes[13] = 70;
    input_bytes[14] = 8;
    input_bytes[15] = 80;
    weight_words[0] = 32'h00000001;
    weight_words[1] = 32'h00000100;
    weight_words[2] = 32'h00010000;
    weight_words[3] = 32'h01000000;
    weight_words[4] = weight_words[0];
    weight_words[5] = weight_words[1];
    weight_words[6] = weight_words[2];
    weight_words[7] = weight_words[3];

    repeat (4) @(posedge clk);
    rst_n = 1;
    write_reg(8'h10, 0);
    for (i = 0; i < 16; i = i + 1)
      dma_write(1, input_bytes[i]);
    write_reg(8'h10, 0);
    for (i = 0; i < 32; i = i + 1)
      dma_write(0, weight_words[i/4][(i%4)*8 +: 8]);
    write_reg(8'h10, 0);
    for (i = 0; i < 32; i = i + 1)
      dma_write(2, 0);

    instruction = make_instruction(0, 2, 2, 4, 4, 1, 1, 0, 0, 0, 0, 1, 0);
    write_instruction(0, instruction);
    instruction = make_instruction(1, 2, 2, 4, 4, 2, 2, 0, 0, 0, 0, 1, 0);
    write_instruction(1, instruction);
    instruction = make_instruction(2, 1, 1, 4, 4, 1, 1, 0, 0, 4, 1, 1, 0);
    write_instruction(2, instruction);
    instruction = make_instruction(3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
    write_instruction(3, instruction);
    write_reg(8'h00, 32'h00000002);
    write_reg(8'h00, 32'h00000001);

    timeout_count = 0;
    read_reg(8'h04, read_value);
    while (!read_value[1] && !read_value[2] && timeout_count < 10000) begin
      read_reg(8'h04, read_value);
      timeout_count = timeout_count + 1;
    end
    if (timeout_count == 10000)
      $fatal(1, "accelerator timed out");
    if (read_value[2])
      $fatal(1, "control unit rejected a legal program");
    for (i = 0; i < 4; i = i + 1) begin
      write_reg(8'h18, i);
      repeat (2) @(posedge clk);
      read_reg(8'h1c, read_value);
      result_byte = read_value[7:0];
      case (i)
        0: if (result_byte !== 8'd7) $fatal(1, "lane 0 mismatch: %0d", result_byte);
        1: if (result_byte !== 8'd70) $fatal(1, "lane 1 mismatch: %0d", result_byte);
        2: if (result_byte !== 8'd8) $fatal(1, "lane 2 mismatch: %0d", result_byte);
        3: if (result_byte !== 8'd80) $fatal(1, "lane 3 mismatch: %0d", result_byte);
      endcase
    end
    $display("PASS: AXI-Lite, convolution, pooling, FC, buffer swapping, and byte results");
    $finish;
    end
  end
endmodule
