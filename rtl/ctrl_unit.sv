`timescale 1ns/1ps

module ctrl_unit import cnn_pkg::*; (
  input logic clk,
  input logic rst_n,
  input logic instr_wr_en,
  input logic [PC_W-1:0] instr_wr_addr,
  input logic [INSTR_W-1:0] instr_wr_data,
  input logic start,
  output logic busy,
  output logic done,
  output logic err,
  output layer_cfg_t cfg,
  output logic gen_start,
  input logic gen_done,
  output logic swap_buf
);
  typedef enum logic [2:0] {IDLE, FETCH, DECODE, RUN, WAIT, SWAP, DONE, ERR} state_t;
  logic [INSTR_W-1:0] instruction_mem [0:63];
  logic [PC_W-1:0] pc;
  logic [INSTR_W-1:0] instruction;
  state_t state;
  logic legal;
  layer_cfg_t decoded;

  assign decoded = instruction[CFG_W-1:0];

  always_comb begin
    legal = 1'b1;
    if (decoded.op == OP_CONV || decoded.op == OP_FC) begin
      if (decoded.in_c == 0 || decoded.in_c % N != 0)
        legal = 1'b0;
      if (decoded.out_c == 0 || decoded.out_c % N != 0)
        legal = 1'b0;
      if (decoded.kernel == 0 || decoded.stride == 0)
        legal = 1'b0;
      if (decoded.in_h == 0 || decoded.in_w == 0)
        legal = 1'b0;
      if (decoded.in_h + 2*decoded.pad < decoded.kernel || decoded.in_w + 2*decoded.pad < decoded.kernel)
        legal = 1'b0;
      if (decoded.op == OP_FC && (decoded.in_h != 1 || decoded.in_w != 1 || decoded.kernel != 1 || decoded.stride != 1 || decoded.pad != 0))
        legal = 1'b0;
    end else if (decoded.op == OP_POOL) begin
      if (decoded.in_c == 0 || decoded.in_c % N != 0 || decoded.in_h < 2 || decoded.in_w < 2)
        legal = 1'b0;
      if (decoded.out_c != decoded.in_c || decoded.in_h[0] || decoded.in_w[0])
        legal = 1'b0;
      if (decoded.kernel != 2 || decoded.stride != 2 || decoded.pad != 0)
        legal = 1'b0;
    end
  end

  always_comb begin
    busy = state != IDLE && state != DONE && state != ERR;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= IDLE;
      pc <= '0;
      instruction <= '0;
      cfg <= '0;
      done <= 1'b0;
      err <= 1'b0;
      gen_start <= 1'b0;
      swap_buf <= 1'b0;
      for (integer i = 0; i < 64; i = i + 1)
        instruction_mem[i] <= '0;
    end else begin
      gen_start <= 1'b0;
      swap_buf <= 1'b0;
      if (instr_wr_en)
        instruction_mem[instr_wr_addr] <= {38'b0, instr_wr_data[89:0]};
      case (state)
        IDLE: begin
          if (start) begin
            pc <= '0;
            done <= 1'b0;
            err <= 1'b0;
            state <= FETCH;
          end
        end
        FETCH: begin
          instruction <= instruction_mem[pc];
          state <= DECODE;
        end
        DECODE: begin
          cfg <= decoded;
          if (decoded.op == OP_HALT)
            state <= DONE;
          else if (!legal)
            state <= ERR;
          else
            state <= RUN;
        end
        RUN: begin
          gen_start <= 1'b1;
          state <= WAIT;
        end
        WAIT: begin
          if (gen_done)
            state <= SWAP;
        end
        SWAP: begin
          swap_buf <= 1'b1;
          pc <= pc + 1'b1;
          state <= FETCH;
        end
        DONE: begin
          done <= 1'b1;
          if (start)
            state <= IDLE;
        end
        ERR: begin
          err <= 1'b1;
          if (start)
            state <= IDLE;
        end
        default: state <= IDLE;
      endcase
    end
  end
endmodule
