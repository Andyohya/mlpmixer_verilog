`timescale 1ns / 1ps

/* Parallel Dot Product Accumulator (Pipelined MAC + Handshake Wallace Tree)
   Iteratively computes dot product of long vectors using NUM_MACS MACs.
   Uses pipelined MAC and handshake-enabled Wallace Tree.
*/
module Parallel_Vector #(
    parameter HID_DIM = 16,
    parameter NUM_MACS = 64,                // 每列有幾個 MAC units = IN_PATCHES
    parameter OUT_PATCHES = 32,
    parameter VECTOR_SIZE = HID_DIM * NUM_MACS,          // 16*64 Total number of elements in vectors
    parameter BITS = 8
  )(
    input clk,
    input rst,
    input start,
    input [BITS*VECTOR_SIZE-1:0] vec_A_flat,            // 輸入資料
    input [BITS*NUM_MACS*OUT_PATCHES-1:0] vec_B_flat,   // 權重檔
    input signed [2*BITS*HID_DIM*OUT_PATCHES-1:0] bias_flat,      // Bias for each output patch

    output reg signed [2*BITS*HID_DIM*OUT_PATCHES-1:0] result,  // Final dot product result
    output reg done,                       // High for 1 cycle when done
    output reg [9:0] cycle_count,        // Counts how many MAC rounds executed
    output signed [2*BITS-1:0] adder_output,
    output [NUM_MACS-1:0] done_flags,
    output reg [2:0] state,next_state
  );

  // Vector Unpacking
  wire [BITS-1:0] vec_A [0:VECTOR_SIZE-1];
  wire [BITS-1:0] vec_B [0:NUM_MACS*OUT_PATCHES-1];
  wire signed [2*BITS-1:0] bias_ext [0:HID_DIM*OUT_PATCHES-1];
  genvar i,j;
  generate
    for (i = 0; i < HID_DIM; i = i + 1)
    begin
      for (j = 0; j < NUM_MACS; j = j + 1)
        begin
          assign vec_A[i*NUM_MACS + j] = vec_A_flat[BITS*(i*NUM_MACS + j) +: BITS];
        end
    end
    for (i = 0; i < NUM_MACS; i = i + 1)
    begin
      for (j = 0; j < OUT_PATCHES; j = j + 1)
        begin
          assign vec_B[i*OUT_PATCHES + j] = vec_B_flat[BITS*(i*OUT_PATCHES + j) +: BITS];
        end
    end
    for (j = 0; j < HID_DIM*OUT_PATCHES; j = j + 1)
    begin
      assign bias_ext[j] = { {BITS{bias_flat[BITS*j + BITS - 1]}}, bias_flat[BITS*j +: BITS] }; // sign-extend 8bit to 16bit
    end
  endgenerate

  // Index and MAC Wiring
  reg [7:0] row_idx, col_idx; // 控制目前計算哪一列哪一行
  wire signed [2*BITS-1:0] mac_results [0:NUM_MACS-1];
  wire [NUM_MACS-1:0] done_flags_internal;
  assign done_flags = done_flags_internal;
  reg signed [2*BITS-1:0] mac_results_latched [0:NUM_MACS-1];
  wire signed [NUM_MACS*2*BITS-1:0] mac_results_flat;

  // FSM states
  localparam IDLE  = 3'b000,
             LOAD  = 3'b001,
             WAIT  = 3'b010,
             LATCH = 3'b011,
             RUN   = 3'b100,
             DONE  = 3'b101;

  reg mac_start;          // Enables MACs for 1 cycle
  reg all_done_last;      // Previous cycle's done_flags check

  // New Wallace handshake signals
  reg  wallace_in_valid;

  // Instantiate MAC units and debug trackers
  generate
    for (i = 0; i < NUM_MACS; i = i + 1) //num_macs = 64
    begin : mac_array
      // 取出正確的 input/weight
      wire signed [BITS-1:0] a_val = vec_A[row_idx*NUM_MACS + i]; //已刪BITS
      wire signed [BITS-1:0] b_val = vec_B[i*OUT_PATCHES + col_idx];
      MAC_pipeline #(.BITS(BITS)) mac_inst (
        .clk(clk),
        .rst(rst),
        .enable(mac_start),
        .A(a_val),
        .B(b_val),
        .result(mac_results[i]),
        .done(done_flags_internal[i])
      );
      assign mac_results_flat[i*2*BITS +: 2*BITS] = mac_results_latched[i];
      always @(posedge clk)
        if (all_done_last)
          mac_results_latched[i] <= mac_results[i];   // Latch when MACs done
    end
  endgenerate

  wire signed [2*BITS-1:0] batch_sum;
  WallaceTree #(.BITS(BITS), .NUM_MACS(NUM_MACS)) wallace_tree_inst (
                .clk(clk),
                .rst(rst),
                .in_valid(wallace_in_valid),
                .in_ready(wallace_in_ready),
                .in_flat(mac_results_flat),
                .out_valid(wallace_out_valid),
                .out(batch_sum)
              );

  reg signed [2*BITS-1:0] adder_output_reg;
  assign adder_output = adder_output_reg;

  reg signed [2*BITS-1:0] batch_sum_with_bias;

//////////////////////////////////////////////更新狀態////////////////////////////////////////////////
  always @(posedge clk or posedge rst)
  begin
    if (rst)
    begin
      state                <= IDLE;
      result               <= 0;
      done                 <= 0;
      cycle_count          <= 0;
      adder_output_reg     <= 0;
      mac_start            <= 0;
      all_done_last        <= 0;
      wallace_in_valid     <= 0;
      // 在 reset 時
      row_idx              <= 0;
      col_idx              <= 0;
      cycle_count          <= 0;
    end
    else
    begin
      all_done_last <= &done_flags_internal;  // 當所有MAC都完成，all_done_last 才會拉高
      wallace_in_valid <= 0;
      state <= next_state;
    end
  end
//////////////////////////////////////////////組合電路////////////////////////////////////////////////
  always @(*)
  begin
    case (state)
      IDLE:  
      begin
        $display("IDLE");
        if (start)
        begin
          next_state = LOAD;
        end
        else
        begin
          next_state = IDLE;
        end
      end
      LOAD:
      begin
        $display("LOAD");
        next_state = WAIT;
      end
      WAIT:
      begin
        $display("WAIT");
        if (&done_flags_internal)
        begin
          next_state = LATCH;
        end
        else
        begin
          next_state = WAIT;
        end
      end
      LATCH:
      begin
        $display("LATCH");
        if (wallace_in_ready)
        begin
          next_state = RUN;
        end
        else
        begin
          next_state = LATCH;
        end
      end
      RUN:
      begin
        if (wallace_out_valid)
        begin
          if ((col_idx + 1 < OUT_PATCHES) || (row_idx + 1 < HID_DIM))
          begin
            next_state = LOAD;
          end
          else
          begin
            next_state = DONE;
          end
        end
        else
        begin
          next_state = RUN;
        end
      end
      DONE:
      begin
        $display("DONE");
        if (!start)
        begin
          next_state = IDLE;
        end
        else
        begin
          next_state = DONE;
        end
      end
      default: next_state = IDLE;
    endcase
  end

//////////////////////////////////////////////狀態機/////////////////////////////////////////////////
  always @(posedge clk)
  begin
    case (state)
      // IDLE: Wait for start
      IDLE:
      begin
        result           <= 0;
        mac_start        <= 0;
        done             <= 0;
        row_idx          <= 0;
        col_idx          <= 0;
      end

      // LOAD: Load MACs with 8-bit inputs
      LOAD:
      begin
        mac_start <= 1;
      end

      // WAIT: Wait for all MACs to finish computing
      WAIT:
      begin
        mac_start <= 0;
      end

      // LATCH: Capture MAC outputs and feed to Wallace Tree
      LATCH:
      begin
        if (wallace_in_ready) 
        begin
          wallace_in_valid <= 1'b1;  // Pulse input into Wallace Tree
        end
      end

      // RUN: Wait for Wallace Tree result
      RUN:
      begin
        $display("RUN: row_idx=%d, col_idx=%d, cycle_count=%d, wallace_out_valid=%b", row_idx, col_idx, cycle_count, wallace_out_valid);
        if (wallace_out_valid)
        begin
          batch_sum_with_bias = batch_sum + bias_ext[row_idx*OUT_PATCHES + col_idx];
          adder_output_reg <= batch_sum_with_bias;
          $display("WALLACE OUT: batch_sum=%0d (int16), %0d (int8), bias=%0d (int16), batch_sum_with_bias=%0d (int16), %0d (int8)", batch_sum, $signed(batch_sum[7:0]), bias_ext[row_idx*OUT_PATCHES + col_idx], batch_sum_with_bias, $signed(batch_sum_with_bias[7:0]));
          result[2*BITS*(row_idx*OUT_PATCHES + col_idx) +: 2*BITS] <= batch_sum_with_bias;
          cycle_count <= cycle_count + 1;
          // 下一個 col
          if (col_idx + 1 < OUT_PATCHES) begin
            col_idx <= col_idx + 1;
          end else if (row_idx + 1 < HID_DIM) begin
            col_idx <= 0;
            row_idx <= row_idx + 1;
          end else begin
            // All done
            col_idx <= col_idx;
            row_idx <= row_idx;
          end
        end
      end

      // DONE: Dot product complete
      DONE:
      begin
        done  <= 1;
      end
    endcase
  end
endmodule
