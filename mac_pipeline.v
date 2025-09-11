`timescale 1ns / 1ps

module MAC_pipeline #(
    parameter BITS = 8
  )(
    input clk,
    input rst,
    input enable,
    input signed [BITS-1:0] A,
    input signed [BITS-1:0] B,
    output reg signed [2*BITS-1:0] result,
    output reg done
  );

  // Stage 1 Registers
  reg            stage1_valid;
  reg signed [BITS-1:0] abs_B;
  // Stage 2 Registers
  reg signed [2*BITS-1:0] mult_result;
  reg       stage2_valid;

  reg signed [2*BITS-1:0] temp_product;

  always @(posedge clk or posedge rst)
  begin
    if (rst)
    begin
      mult_result  <= {2*BITS{1'd0}};
      result       <= {2*BITS{1'd0}};
      temp_product <= {2*BITS{1'd0}};
      stage1_valid <= 1'b0;
      stage2_valid <= 1'b0;
      done         <= 1'b0;
    end
    else
    begin
      // Stage 1: Latch A, B and perform shift-and-add multiplication (signed)
      if (enable)
      begin
        $display("A = %0d (int8),B = %0d (int8)", A, B);

        abs_B = (B < 0) ? -B : B;

        // Unrolled shift-and-add
        temp_product = {2*BITS{1'd0}};
        if (abs_B[0])
          temp_product = temp_product + (A <<< 0); // <<< 是 arithmetic shift
        if (abs_B[1])
          temp_product = temp_product + (A <<< 1);
        if (abs_B[2])
          temp_product = temp_product + (A <<< 2);
        if (abs_B[3])
          temp_product = temp_product + (A <<< 3);
        if (abs_B[4])
          temp_product = temp_product + (A <<< 4);
        if (abs_B[5])
          temp_product = temp_product + (A <<< 5);
        if (abs_B[6])
          temp_product = temp_product + (A <<< 6);
        if (abs_B[7])
          temp_product = temp_product + (A <<< 7);

        if (B < 0)
        begin
          mult_result  <= -temp_product;
          $display("A*B = %0d", -temp_product);
        end
        else
        begin
          mult_result  <= temp_product;
          $display("A*B = %0d", temp_product);
        end

        stage1_valid <= 1'b1;
      end
      else
      begin
        stage1_valid <= 1'b0;
      end

      // Stage 2: Output result and done signal
      if (stage1_valid)
      begin
        result <= mult_result;
        $display("result = %0d (int16)", mult_result);
        done   <= 1'b1;
        stage2_valid <= 1'b1;
      end
      else
      begin
        done <= 1'b0;
        stage2_valid <= 1'b0;
      end
    end
  end

endmodule
