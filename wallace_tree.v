`timescale 1ns / 1ps

module WallaceTree #(
    parameter NUM_MACS = 64,
    parameter BITS = 8
  )(
    input clk,
    input rst,

    input in_valid,
    output reg in_ready,

    input signed [NUM_MACS*2*BITS-1:0] in_flat,

    output reg out_valid,
    output reg signed [2*BITS-1:0] out
  );

  // 將展平的 in_flat 轉回 NUM_MACS 個 16 位元元素，方便後續運算
  wire signed [2*BITS-1:0] in [0:NUM_MACS-1];
  genvar i;
  generate
    for (i = 0; i < NUM_MACS; i = i + 1)
    begin
      assign in[i] = in_flat[i*2*BITS +: 2*BITS];
    end
  endgenerate

  // Pipeline valid tracker
  reg [3:0] pipeline_valid;  //是用來追蹤資料在四級 pipeline 中的有效性
  always @(posedge clk or posedge rst)
  begin
    if (rst)
      pipeline_valid <= 4'b0000;
    else
      pipeline_valid <= {pipeline_valid[2:0], in_valid};  // pipeline_valid[0] 為最低位，每個時鐘週期將 in_valid 移入最低位，pipeline_valid 左移一位，追蹤資料在 pipeline 的有效性。
  end

  // Handshake outputs
  always @(posedge clk or posedge rst)
  begin
    if (rst)
    begin
      out_valid <= 1'b0;   // 清零，表示目前沒有有效輸出
      in_ready  <= 1'b1;   // 拉高，表示 pipeline 是空的，可以接受新資料
    end
    else
    begin
      out_valid <= pipeline_valid[3];   // 當資料通過四級 pipeline 時拉高，表示結果有效
      in_ready  <= ~pipeline_valid[0];  // 當 pipeline 第 0 級空閒時拉高，表示可接受新資料
    end
  end

  integer j;

  // Stage 1: CSA(carry save adder) compression
  localparam N1 = (NUM_MACS+2)/3;  // 計算壓縮後的組數，每 3 個數壓成 2 個（sum/carry），剩下 1 或 2 個也要處理
  reg signed [2*BITS-1:0] sum1   [0:N1-1];  // 分別存放每組的 sum 和 carry 結果，都是 16 位元
  reg signed [2*BITS-1:0] carry1 [0:N1-1];
  always @(posedge clk or posedge rst)
  begin
    if (rst)
    begin
      for (j = 0; j < N1; j = j + 1)
      begin
        sum1[j]   <= {2*BITS{1'b0}};
        carry1[j] <= {2*BITS{1'b0}};
      end
    end
    else if (pipeline_valid[0])
    begin
      $display("stage1");
      for (j = 0; j < NUM_MACS/3; j = j + 1)
      begin
        sum1[j]   <= in[3*j] ^ in[3*j+1] ^ in[3*j+2];  // 三數的 bitwise XOR，得到 sum
        carry1[j] <= (in[3*j] & in[3*j+1]) |
              (in[3*j] & in[3*j+2]) |
              (in[3*j+1] & in[3*j+2]);       //  三數的 bitwise AND/OR，得到 carry
      end
      if (NUM_MACS % 3 == 1)
      begin
        sum1[NUM_MACS/3]   <= in[NUM_MACS-1];
        carry1[NUM_MACS/3] <= {2*BITS{1'b0}};
      end
      else if (NUM_MACS % 3 == 2)
      begin
        sum1[NUM_MACS/3]   <= in[NUM_MACS-2] ^ in[NUM_MACS-1];
        carry1[NUM_MACS/3] <= in[NUM_MACS-2] & in[NUM_MACS-1];
      end
    end
  end

  // Stage 2: sum + (carry << 1)
  reg signed [2*BITS-1:0] stage2 [0:N1-1];
  always @(posedge clk or posedge rst)
  begin
    if (rst)
    begin
      for (j = 0; j < N1; j = j + 1)
        stage2[j] <= {2*BITS{1'b0}};
    end
    else if (pipeline_valid[1])
    begin
      $display("stage2");
      for (j = 0; j < N1; j = j + 1)
        stage2[j] <= sum1[j] + (carry1[j] << 1);
    end
  end

  // Stage 3: Accumulate all stage2[j]
  reg signed [2*BITS-1:0] result;
  reg signed [2*BITS-1:0] temp_sum;
  integer k;
  always @(posedge clk or posedge rst)
  begin
    if (rst)
      result <= {2*BITS{1'b0}};
    else if (pipeline_valid[2])
    begin
      $display("stage3");
      temp_sum = {2*BITS{1'b0}};
      for (k = 0; k < N1; k = k + 1)
        temp_sum = temp_sum + stage2[k];  // 確認是否為non_blocking?
      result <= temp_sum;
    end
  end

  // Final output register
  always @(posedge clk or posedge rst)
  begin
    if (rst)
      out <= {2*BITS{1'b0}};
    else if (pipeline_valid[3])
    begin
      $display("stage4");
      out <= result;
    end
  end
endmodule
