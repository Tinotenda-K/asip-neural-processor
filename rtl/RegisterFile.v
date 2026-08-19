`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 17.10.2025 20:28:14
// Design Name: 
// Module Name: RegisterFile
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module RegisterFile(
    input clk,
    input rst,
    input reg_write,
    input [4:0] read_reg1,
    input [4:0] read_reg2,
    input [4:0] read_reg3,
    input [4:0] write_reg,
    input [31:0] write_data,
    output [31:0] read_data1,
    output [31:0] read_data2,
    output [31:0] read_data3
);

    reg [31:0] regs [0:31];
    integer i;

    // Reset all registers
    always @(posedge clk) begin
        if (rst)
            for (i = 0; i < 32; i = i + 1)
                regs[i] <= 32'b0;
        else if (reg_write && (write_reg != 5'b0))
            regs[write_reg] <= write_data;
    end

    // Asynchronous read
    assign read_data1 = (read_reg1 == 5'b0) ? 32'b0 : regs[read_reg1];
    assign read_data2 = (read_reg2 == 5'b0) ? 32'b0 : regs[read_reg2];
    assign read_data3 = (read_reg3 == 5'b0) ? 32'b0 : regs[read_reg3];

endmodule

