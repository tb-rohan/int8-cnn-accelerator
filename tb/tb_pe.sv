module tb_pe;
  logic clk = 0;
  logic rst_n = 0;
  logic w_load_en;
  logic signed [7:0] w_in;
  logic signed [7:0] act_in;
  logic signed [31:0] psum_in;
  logic signed [7:0] act_out;
  logic signed [31:0] psum_out;

  always #5 clk = ~clk;

  pe dut (.*);

  initial begin
    w_load_en = 0;
    w_in = 0;
    act_in = 0;
    psum_in = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    w_load_en = 1;
    w_in = -3;
    @(negedge clk);
    w_load_en = 0;
    act_in = 7;
    psum_in = -4;
    @(posedge clk);
    #1;
    if (psum_out !== -25 || act_out !== 7)
      $fatal(1, "signed PE result mismatch");
    $display("PASS: signed PE multiply-accumulate and activation register");
    $finish;
  end
endmodule
