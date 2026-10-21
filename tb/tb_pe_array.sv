module tb_pe_array import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;
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
  logic signed [7:0] expected [0:N-1];
  integer r;

  always #5 clk = ~clk;

  pe_array dut (.*);

  initial begin
    w_load_en = 0;
    w_load_row = 0;
    w_load_data = 0;
    act_valid = 0;
    act_in = 0;
    act_first = 0;
    act_last = 0;
    act_idx = 0;
    expected[0] = -2;
    expected[1] = 3;
    expected[2] = -4;
    expected[3] = 5;
    repeat (2) @(posedge clk);
    rst_n = 1;
    for (r = 0; r < N; r = r + 1) begin
      @(negedge clk);
      w_load_en = 1;
      w_load_row = r;
      w_load_data = 0;
      w_load_data[r*DATA_W +: DATA_W] = 8'd1;
    end
    @(negedge clk);
    w_load_en = 0;
    for (r = 0; r < N; r = r + 1)
      act_in[r*DATA_W +: DATA_W] = expected[r];
    act_valid = 1;
    act_first = 1;
    act_last = 1;
    act_idx = 4'hb;
    @(negedge clk);
    act_valid = 0;
    act_first = 0;
    act_last = 0;
    wait (psum_valid);
    #1;
    if (!psum_first || !psum_last || psum_idx != 4'hb)
      $fatal(1, "array tag mismatch");
    for (r = 0; r < N; r = r + 1)
      if ($signed(psum_out[r*ACC_W +: ACC_W]) !== expected[r])
        $fatal(1, "array lane %0d mismatch", r);
    $display("PASS: systolic array alignment, tags, and signed lane results");
    $finish;
  end
endmodule
