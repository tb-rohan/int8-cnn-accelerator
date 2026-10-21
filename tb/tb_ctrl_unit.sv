module tb_ctrl_unit import cnn_pkg::*; ();
  logic clk = 0;
  logic rst_n = 0;
  logic instr_wr_en;
  logic [PC_W-1:0] instr_wr_addr;
  logic [INSTR_W-1:0] instr_wr_data;
  logic start;
  logic busy;
  logic done;
  logic err;
  layer_cfg_t cfg;
  logic gen_start;
  logic gen_done;
  logic swap_buf;
  layer_cfg_t illegal_cfg;

  always #5 clk = ~clk;

  ctrl_unit dut (.*);

  initial begin
    instr_wr_en = 0;
    instr_wr_addr = 0;
    instr_wr_data = 0;
    start = 0;
    gen_done = 0;
    illegal_cfg = '0;
    illegal_cfg.op = OP_CONV;
    illegal_cfg.in_h = 4;
    illegal_cfg.in_w = 4;
    illegal_cfg.in_c = 3;
    illegal_cfg.out_c = 4;
    illegal_cfg.kernel = 1;
    illegal_cfg.stride = 1;
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(negedge clk);
    instr_wr_en = 1;
    instr_wr_addr = 0;
    instr_wr_data = {38'b0, illegal_cfg};
    @(negedge clk);
    instr_wr_en = 0;
    start = 1;
    @(negedge clk);
    start = 0;
    wait (err);
    if (busy || gen_start || done)
      $fatal(1, "illegal descriptor did not enter the error state");
    $display("PASS: instruction decode and illegal channel descriptor rejection");
    $finish;
  end
endmodule
