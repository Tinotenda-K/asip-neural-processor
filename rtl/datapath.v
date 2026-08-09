`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 16.10.2025 18:06:42
// Design Name: 
// Module Name: Datapath
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


module Datapath (
    input clk,
    input rst,
    
    // Control signals from Control Unit
    input reg_dst,
    input alu_src,
    input mem_to_reg,
    input reg_write,
    input mem_read,
    input mem_write,
    input branch_equal,
    input branch_not_equal,
    input jump,
    input [5:0] alu_op,
    input [1:0] pc_src,

    // Outputs back to TopModule or PC
    output [31:0] pc,
    output [31:0] instruction
);

    // ===================================================================
    // Program Counter
    // ===================================================================
    wire [31:0] branch_target;
    wire [31:0] jump_target;
//    wire [31:0] pc_next;

    reg pc_enable = 1'b1;

    ProgramCounter PC (
        .clk(clk),
        .rst(rst),
        .pc_enable(pc_enable),
        .pc_src(pc_src),
        .branch_target(branch_target),
        .jump_target(jump_target),
        .pc(pc)
    );


    // ====================================================================
    // Instruction Memory
    // ====================================================================
    // 32-bit instructions, 256 entries
    
//    wire [31:0] instruction_raw;
    
    InstructionMemory IMEM (
        .addr(pc),
        .instruction(instruction)
    );
    
    // ====================================================================
    // INSTRUCTION REGISTER 
//    // ====================================================================
//    reg [31:0] instruction_reg;
    
//    always @(posedge clk) begin
//        if (rst)
//            instruction_reg <= 32'b0;
//        else
//            instruction_reg <= instruction_raw;
//    end
    
//    assign instruction = instruction_reg;


    // ====================================================================
    // Instruction Field Extractio
    // ====================================================================
    wire [5:0] opcode = instruction[31:26];
    wire [4:0] rs_addr = instruction[25:21];
    wire [4:0] rt_addr = instruction[20:16];
    wire [4:0] rd_addr = instruction[15:11];
    wire [15:0] imm16  = instruction[15:0];
    wire [25:0] jump_imm = instruction[25:0];
    wire [5:0] funct  = instruction[5:0];
    wire [4:0] shamt  = instruction[10:6];


    // ====================================================================
    // Register File
    // ====================================================================
    wire [31:0] rs_data, rt_data, rd_data, write_data;
    
    // Choose destination register
    wire [4:0] write_reg = (reg_dst) ? rd_addr : rt_addr;

    RegisterFile RF (
        .clk(clk),
        .rst(rst),
        .reg_write(reg_write),
        .read_reg1(rs_addr),
        .read_reg2(rt_addr),
        .read_reg3(rd_addr),
        .write_reg(write_reg),
        .write_data(write_data),
        .read_data1(rs_data),
        .read_data2(rt_data),
        .read_data3(rd_data)
    );


    // ====================================================================
    // Immediate Sign Extension. 
    // ====================================================================
    // sign-extend imm16
    wire [31:0] imm_ext = {{16{imm16[15]}}, imm16}; 
    
    // ====================================================================
    // ALU Input Selection
    // ====================================================================
    wire [31:0] alu_inputB = (alu_src) ? imm_ext : rt_data;

    wire [31:0] alu_result;
    wire alu_overflow;

    ALU alu (
        .rs(rs_data),
        .rt(alu_inputB),
        .rd(rd_data),
        .funct(alu_op),
        .shamt(shamt),
        .result(alu_result),
        .overflow(alu_overflow)
    );

    // =======================================================================
    // Data Memory
    // =======================================================================
    wire [31:0] mem_read_data;

    DataMemory DMEM (
        .clk(clk),
        .mem_read(mem_read),
        .mem_write(mem_write),
        .addr(alu_result),
        .write_data(rt_data),
        .read_data(mem_read_data)
    );
    
    // =======================================================================
    // Assign IMEM and DMEM as outputs
    // =======================================================================
//    assign imem_out = 
    

    // =======================================================================
    // Writeback MUX
    // =======================================================================
    assign write_data = (mem_to_reg) ? mem_read_data : alu_result;

    // =======================================================================
    // Branch and Jump Target Logic
    // =======================================================================
    wire branch_taken;
    
    // set up the conditions for BEQ and BNE to affirm if we should move to branch
    assign branch_taken = (branch_equal && (rs_data == rt_data)) ||
                          (branch_not_equal && (rs_data != rt_data));

//    assign branch_target = (branch_taken)
//                            ? (pc + {{14{imm16[15]}}, imm16, 2'b00})
//                            : (pc + 4);

    wire [31:0] pc_plus4 = pc + 32'd4;
    wire [31:0] branch_offset = {{14{imm16[15]}}, imm16, 2'b00};
    assign branch_target = branch_taken ? (pc_plus4 + branch_offset) : pc_plus4;
    assign jump_target   = {pc[31:28], jump_imm, 2'b00};
    
    always @(posedge clk) if (!rst) begin
        $display("DBG pc=%h op=%b rs=%0d rt=%0d rd=%0d alu_src=%b rs=%0d rt=%0d imm=%0d aluB=%0d alu=%0d dmem_idx=%0d rd=%0d regW=%b W[%0d]=%0d",
                 pc, opcode, rs_addr, rt_addr, rd_addr, alu_src, rs_data, rt_data, $signed(imm16),
                 alu_inputB, alu_result, alu_result[18:2], mem_read_data, reg_write, write_reg, write_data);
        if (opcode == 6'b001000) // BNE
            $display("DBG BNE rs=%0d rt=%0d taken=%b target=%h", rs_data, rt_data, branch_taken, branch_target);
    end
    
    // Right after instruction field extraction
//always @(*) begin
//    if (instruction == 32'h00446007) begin
//        $display("DEBUG: Decoding second MAC instruction");
//        $display("  instruction = %h (%b)", instruction, instruction);
//        $display("  instruction[15] = %b", instruction[15]);
//        $display("  instruction[14] = %b", instruction[14]);
//        $display("  instruction[13] = %b", instruction[13]);
//        $display("  instruction[12] = %b", instruction[12]);
//        $display("  instruction[11] = %b", instruction[11]);
//        $display("  instruction[15:11] = %b (%d)", instruction[15:11], instruction[15:11]);
//        $display("  rd_addr wire = %b (%d)", rd_addr, rd_addr);
//    end
//end

endmodule

