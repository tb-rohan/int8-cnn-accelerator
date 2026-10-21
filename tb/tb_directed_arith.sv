`timescale 1ns/1ps

module tb_directed_arith import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;

  always #5 clk = ~clk;

  // ---------------------------------------------------------
  // 1. PE Direct Edge Case Tests
  // ---------------------------------------------------------
  logic pe_w_load_en;
  logic signed [DATA_W-1:0] pe_w_in;
  logic signed [DATA_W-1:0] pe_act_in;
  logic signed [ACC_W-1:0] pe_psum_in;
  logic signed [DATA_W-1:0] pe_act_out;
  logic signed [ACC_W-1:0] pe_psum_out;

  pe #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_pe (
    .clk(clk),
    .rst_n(rst_n),
    .w_load_en(pe_w_load_en),
    .w_in(pe_w_in),
    .act_in(pe_act_in),
    .psum_in(pe_psum_in),
    .act_out(pe_act_out),
    .psum_out(pe_psum_out)
  );

  task automatic test_pe_mult(
    input logic signed [7:0] weight_val,
    input logic signed [7:0] act_val,
    input logic signed [31:0] psum_val,
    input logic signed [31:0] exp_psum
  );
    begin
      @(negedge clk);
      pe_w_load_en = 1'b1;
      pe_w_in = weight_val;
      @(negedge clk);
      pe_w_load_en = 1'b0;
      pe_act_in = act_val;
      pe_psum_in = psum_val;
      @(posedge clk);
      #1;
      if (pe_psum_out !== exp_psum || pe_act_out !== act_val) begin
        $fatal(1, "[PE FAIL] w=%0d, act=%0d, psum_in=%0d | expected psum=%0d, got %0d (act_out=%0d)",
               weight_val, act_val, psum_val, exp_psum, pe_psum_out, pe_act_out);
      end
    end
  endtask

  // ---------------------------------------------------------
  // 2. Post-Proc Edge Case Tests
  // ---------------------------------------------------------
  layer_cfg_t pp_cfg;
  logic [N*ACC_W-1:0] pp_bias_vec;
  logic pp_psum_valid;
  logic [N*ACC_W-1:0] pp_psum_in;
  logic pp_psum_first;
  logic pp_psum_last;
  logic [TILE_W-1:0] pp_psum_idx;
  logic pp_pool_valid;
  logic pp_pool_first;
  logic pp_pool_last;
  logic [N*DATA_W-1:0] pp_pool_data;
  logic pp_out_wr_en;
  logic [N*DATA_W-1:0] pp_out_wr_data;

  post_proc u_pp (
    .clk(clk),
    .rst_n(rst_n),
    .cfg(pp_cfg),
    .bias_vec(pp_bias_vec),
    .psum_valid(pp_psum_valid),
    .psum_in(pp_psum_in),
    .psum_first(pp_psum_first),
    .psum_last(pp_psum_last),
    .psum_idx(pp_psum_idx),
    .pool_valid(pp_pool_valid),
    .pool_first(pp_pool_first),
    .pool_last(pp_pool_last),
    .pool_data(pp_pool_data),
    .out_wr_en(pp_out_wr_en),
    .out_wr_data(pp_out_wr_data)
  );

  task automatic test_pp_conv(
    input logic signed [31:0] sum0, sum1, sum2, sum3,
    input logic signed [31:0] b0, b1, b2, b3,
    input logic [15:0] q_mult,
    input logic [4:0]  q_shift,
    input logic        relu,
    input logic signed [7:0] exp0, exp1, exp2, exp3
  );
    begin
      @(negedge clk);
      pp_cfg = '0;
      pp_cfg.quant_mult = q_mult;
      pp_cfg.quant_shift = q_shift;
      pp_cfg.relu_en = relu;

      pp_bias_vec[0*ACC_W +: ACC_W] = b0;
      pp_bias_vec[1*ACC_W +: ACC_W] = b1;
      pp_bias_vec[2*ACC_W +: ACC_W] = b2;
      pp_bias_vec[3*ACC_W +: ACC_W] = b3;

      pp_psum_in[0*ACC_W +: ACC_W] = sum0;
      pp_psum_in[1*ACC_W +: ACC_W] = sum1;
      pp_psum_in[2*ACC_W +: ACC_W] = sum2;
      pp_psum_in[3*ACC_W +: ACC_W] = sum3;

      pp_psum_valid = 1'b1;
      pp_psum_first = 1'b1;
      pp_psum_last  = 1'b1;
      pp_psum_idx   = '0;
      @(posedge clk);
      @(negedge clk);
      pp_psum_valid = 1'b0;

      wait (pp_out_wr_en === 1'b1);
      #1;
      if ($signed(pp_out_wr_data[0*DATA_W +: DATA_W]) !== exp0 ||
          $signed(pp_out_wr_data[1*DATA_W +: DATA_W]) !== exp1 ||
          $signed(pp_out_wr_data[2*DATA_W +: DATA_W]) !== exp2 ||
          $signed(pp_out_wr_data[3*DATA_W +: DATA_W]) !== exp3) begin
        $fatal(1, "[POST-PROC FAIL] Got [%0d, %0d, %0d, %0d], Expected [%0d, %0d, %0d, %0d]",
               $signed(pp_out_wr_data[0*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[1*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[2*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[3*DATA_W +: DATA_W]),
               exp0, exp1, exp2, exp3);
      end
      @(posedge clk);
    end
  endtask

  task automatic test_pp_pool(
    input logic signed [7:0] q0_0, q0_1, q0_2, q0_3,
    input logic signed [7:0] q1_0, q1_1, q1_2, q1_3,
    input logic signed [7:0] q2_0, q2_1, q2_2, q2_3,
    input logic signed [7:0] q3_0, q3_1, q3_2, q3_3,
    input logic signed [7:0] exp0, exp1, exp2, exp3
  );
    integer quad_idx;
    begin
      @(negedge clk);
      pp_pool_valid = 1'b1;
      for (quad_idx = 0; quad_idx < 4; quad_idx = quad_idx + 1) begin
        pp_pool_first = (quad_idx == 0);
        pp_pool_last  = (quad_idx == 3);
        case (quad_idx)
          0: pp_pool_data = {q0_3, q0_2, q0_1, q0_0};
          1: pp_pool_data = {q1_3, q1_2, q1_1, q1_0};
          2: pp_pool_data = {q2_3, q2_2, q2_1, q2_0};
          3: pp_pool_data = {q3_3, q3_2, q3_1, q3_0};
        endcase
        @(posedge clk);
        #1;
        @(negedge clk);
      end
      pp_pool_valid = 1'b0;
      #1;
      if (!pp_out_wr_en) $fatal(1, "[POOL FAIL] out_wr_en not asserted on pool_last");
      if ($signed(pp_out_wr_data[0*DATA_W +: DATA_W]) !== exp0 ||
          $signed(pp_out_wr_data[1*DATA_W +: DATA_W]) !== exp1 ||
          $signed(pp_out_wr_data[2*DATA_W +: DATA_W]) !== exp2 ||
          $signed(pp_out_wr_data[3*DATA_W +: DATA_W]) !== exp3) begin
        $fatal(1, "[POOL FAIL] Got [%0d, %0d, %0d, %0d], Expected [%0d, %0d, %0d, %0d]",
               $signed(pp_out_wr_data[0*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[1*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[2*DATA_W +: DATA_W]),
               $signed(pp_out_wr_data[3*DATA_W +: DATA_W]),
               exp0, exp1, exp2, exp3);
      end
      @(posedge clk);
    end
  endtask

  // ---------------------------------------------------------
  // 3. Main Verification Sequence
  // ---------------------------------------------------------
  initial begin
    $display("=== STARTING DIRECTED ARITHMETIC & CORNER-CASE TESTS ===");
    pe_w_load_en = 0; pe_w_in = 0; pe_act_in = 0; pe_psum_in = 0;
    pp_cfg = '0; pp_bias_vec = '0; pp_psum_valid = 0; pp_psum_in = 0;
    pp_psum_first = 0; pp_psum_last = 0; pp_psum_idx = 0;
    pp_pool_valid = 0; pp_pool_first = 0; pp_pool_last = 0; pp_pool_data = 0;

    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // --- Section A: PE Multiplication Corners ---
    $display("[TEST] A. PE Signed Multiplication Corners");
    test_pe_mult(8'sd0,    8'sd0,    32'sd0, 32'sd0);     // 0 * 0 = 0
    test_pe_mult(8'sd127,  8'sd127,  32'sd0, 32'sd16129); // 127 * 127 = 16129
    test_pe_mult(-8'sd128, 8'sd127,  32'sd0, -32'sd16256);// -128 * 127 = -16256
    test_pe_mult(-8'sd128, -8'sd128, 32'sd0, 32'sd16384); // -128 * -128 = +16384 (Two's complement boundary)
    test_pe_mult(8'sd127,  -8'sd128, 32'sd0, -32'sd16256);// 127 * -128 = -16256
    test_pe_mult(-8'sd1,   -8'sd1,   32'sd0, 32'sd1);     // -1 * -1 = 1
    test_pe_mult(-8'sd128, 8'sd0,    32'sd0, 32'sd0);     // -128 * 0 = 0
    test_pe_mult(8'sd0,    -8'sd128, 32'sd0, 32'sd0);     // 0 * -128 = 0
    test_pe_mult(-8'sd128, -8'sd128, 32'sd1000, 32'sd17384); // -128 * -128 + 1000 = 17384

    // --- Section B: 33-bit Biased Intermediate & Extreme Overflow ---
    $display("[TEST] B. 33-bit Bias Addition Intermediate (Extreme Sums)");
    // sum = -2,000,000,000, bias = -2,000,000,000 -> Sum = -4,000,000,000 (would overflow 32-bit to positive +294,967,296!)
    // With 33 bits, it remains negative, and clamps to -128!
    test_pp_conv(-32'sd2000000000, 32'sd2000000000, -32'sd2147483647, 32'sd2147483647,
                 -32'sd2000000000, 32'sd2000000000, -32'sd1,          32'sd1,
                 16'd1, 5'd0, 1'b0,
                 -8'sd128, 8'sd127, -8'sd128, 8'sd127);

    // --- Section C: Rounding Thresholds (Round-Half-Up Nearest Integer) ---
    $display("[TEST] C. Fixed-Point Requantization Rounding Thresholds");
    // shift = 3 -> 2^(shift-1) = 4. Equation: (val + 4) >>> 3
    // val = 3  -> (3+4)>>3  = 7>>3  = 0
    // val = 4  -> (4+4)>>3  = 8>>3  = 1  (exact +0.5 threshold)
    // val = -4 -> (-4+4)>>3 = 0>>3  = 0  (exact -0.5 threshold rounds to 0)
    // val = -5 -> (-5+4)>>3 = -1>>3 = -1 (-0.625 rounds to -1)
    test_pp_conv(32'sd3, 32'sd4, -32'sd4, -32'sd5,
                 32'sd0, 32'sd0, 32'sd0,  32'sd0,
                 16'd1, 5'd3, 1'b0,
                 8'sd0, 8'sd1, 8'sd0, -8'sd1);

    // shift = 4 -> 2^(shift-1) = 8. Equation: (val + 8) >>> 4
    // val = 7  -> (7+8)>>4  = 15>>4 = 0
    // val = 8  -> (8+8)>>4  = 16>>4 = 1  (exact +0.5 threshold)
    // val = -8 -> (-8+8)>>4 = 0>>4  = 0  (exact -0.5 threshold rounds to 0)
    // val = -9 -> (-9+8)>>4 = -1>>4 = -1 (-0.5625 rounds to -1)
    test_pp_conv(32'sd7, 32'sd8, -32'sd8, -32'sd9,
                 32'sd0, 32'sd0, 32'sd0,  32'sd0,
                 16'd1, 5'd4, 1'b0,
                 8'sd0, 8'sd1, 8'sd0, -8'sd1);

    // --- Section D: Saturation Boundaries & Zero Shift ---
    $display("[TEST] D. Saturation Boundaries & Zero Shift");
    // quant_shift = 0 with values around [-128, 127]
    test_pp_conv(-32'sd129, -32'sd128, 32'sd127, 32'sd128,
                 32'sd0,    32'sd0,    32'sd0,   32'sd0,
                 16'd1, 5'd0, 1'b0,
                 -8'sd128, -8'sd128, 8'sd127, 8'sd127);

    // Large values saturation
    test_pp_conv(-32'sd500000, 32'sd500000, -32'sd100, 32'sd100,
                 32'sd0,       32'sd0,      32'sd0,    32'sd0,
                 16'd1, 5'd0, 1'b0,
                 -8'sd128, 8'sd127, -8'sd100, 8'sd100);

    // --- Section E: ReLU Activation Behavior ---
    $display("[TEST] E. ReLU Activation Behavior");
    // With ReLU enabled, negative values must clamp to 0; positive values preserved
    test_pp_conv(-32'sd50, -32'sd1, 32'sd0, 32'sd45,
                 32'sd0,   32'sd0,  32'sd0, 32'sd0,
                 16'd1, 5'd0, 1'b1,
                 8'sd0, 8'sd0, 8'sd0, 8'sd45);

    // --- Section F: Max-Pooling with Signed Comparisons ---
    $display("[TEST] F. Max-Pooling with Strict Signed Comparisons");
    // All-negative quad: [-128, -80, -2, -10] -> Max is -2
    test_pp_pool(-8'sd128, -8'sd128, -8'sd50, -8'sd20,
                 -8'sd80,  -8'sd70,  -8'sd60, -8'sd30,
                 -8'sd2,   -8'sd5,   -8'sd1,  -8'sd40,
                 -8'sd10,  -8'sd3,   -8'sd8,  -8'sd50,
                 -8'sd2,   -8'sd3,   -8'sd1,  -8'sd20);

    // Mixed quad: [-50, 0, -1, 15] -> Max is 15
    test_pp_pool(-8'sd50, -8'sd1, 8'sd127, -8'sd128,
                 8'sd0,   8'sd0,  8'sd0,   -8'sd100,
                 -8'sd1,  8'sd10, -8'sd10, -8'sd5,
                 8'sd15,  8'sd20, 8'sd30,  -8'sd2,
                 8'sd15,  8'sd20, 8'sd127, -8'sd2);

    // All identical negative: [-40, -40, -40, -40] -> Max is -40
    test_pp_pool(-8'sd40, -8'sd40, -8'sd40, -8'sd40,
                 -8'sd40, -8'sd40, -8'sd40, -8'sd40,
                 -8'sd40, -8'sd40, -8'sd40, -8'sd40,
                 -8'sd40, -8'sd40, -8'sd40, -8'sd40,
                 -8'sd40, -8'sd40, -8'sd40, -8'sd40);

    $display("=== ALL DIRECTED ARITHMETIC & CORNER-CASE TESTS PASSED ===");
    $finish(0);
  end

endmodule
