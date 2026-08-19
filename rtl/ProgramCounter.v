`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.10.2025 11:41:18
// Design Name: 
// Module Name: ProgramCounter
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


module ProgramCounter(

    input clk, // clock
    input rst, // reset
    
    input pc_enable, // set to 1 to stall PC when we have NOP or have load delays
    input [1:0] pc_src, // Selects next PC source (00-> PC + 4, 01-> branch, 10-> jump)
    input [31:0] branch_target, // Target address for branching instruction BEQ/ BNE
    input [31:0] jump_target, // Target for J-type Jump
    
    output reg [31:0] pc // Current PC output
    );
    
    // System has instructions that are 32 bits long.
    // However MIPS-like systems are byte-addressable. 
    // So the instruction is stored in 4 bytes in system.
    // And each 32-bit address points to a byte in system.
    // So 1 adress -> a quarter of the instruction.
    // So PC inceases by 4 to skip 3 bytes (from previous instruction)
    
    always @(posedge clk) begin
        if (rst)
            pc <= 32'b0;
        else if (pc_enable) begin
            case (pc_src)
                2'b00: pc <= pc + 4;             // normal
                2'b01: pc <= branch_target;      // BEQ/BNE
                2'b10: pc <= jump_target;        // Jump
                default: pc <= pc;               // hold (NOP)
            endcase
        end
    end
endmodule
