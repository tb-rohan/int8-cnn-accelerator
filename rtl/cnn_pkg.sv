`timescale 1ns/1ps

package cnn_pkg;
  parameter int DATA_W = 8;
  parameter int ACC_W = 32;
  parameter int N = 4;
  parameter int TILE_P = 16;
  parameter int TILE_W = 4;
  parameter int ADDR_W = 14;
  parameter int PC_W = 6;
  parameter int INSTR_W = 128;
  parameter int CFG_W = 90;

  typedef enum logic [1:0] {OP_CONV = 2'd0, OP_POOL = 2'd1, OP_FC = 2'd2, OP_HALT = 2'd3} op_e;

  typedef struct packed {
    op_e op;
    logic [7:0] in_h;
    logic [7:0] in_w;
    logic [9:0] in_c;
    logic [7:0] out_c;
    logic [3:0] kernel;
    logic [3:0] stride;
    logic [3:0] pad;
    logic relu_en;
    logic [11:0] w_base;
    logic [7:0] b_base;
    logic [15:0] quant_mult;
    logic [4:0] quant_shift;
  } layer_cfg_t;
endpackage
