`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// TopModule
//
// PURPOSE
//   Top-level wrapper for the ASIP. Instantiates the control unit and datapath,
//   generates the 50 MHz core clock from the 100 MHz board oscillator,
//   synchronises the asynchronous reset, and drives the board's observable
//   outputs.
//
// INTERFACE
//   clk         100 MHz board oscillator (Boolean board, Spartan-7 XC7S50)
//   rst         asynchronous push-button reset, active high,
//               synchronised internally before use
//   pc_out      [10:0]  current program counter, to LEDs
//   result_out  [3:0]   latched argmax result (0-9), to LEDs
//   done        inference-complete flag, to LED
//
// CLOCKING
//   A single flop divides the 100 MHz input by two:
//
//       always @(posedge clk) clk_div <= ~clk_div;
//
//   Everything downstream runs on core_clk at 50 MHz. The constraint
//
//       create_generated_clock -name core_clk -source [get_ports clk] \
//           -divide_by 2 [get_pins clk_div_reg/Q]
//
//   DESCRIBES this divider; it does not configure it. Changing -divide_by
//   without changing the RTL makes Vivado analyse a clock that does not exist,
//   and the design fails silently on hardware.
//
//   50 MHz rather than 100 MHz because the critical path
//       IMEM BRAM out -> register-file read mux -> ALU -> DMEM address
//   does not close at 10 ns. At 20 ns the MAC4 build closes at WNS +0.066 ns.
//
// RESET
//   rst arrives asynchronously from a push button. It is passed through a
//   two-flop synchroniser here before being distributed, so a release that
//   violates recovery/removal on one flop cannot put different parts of the
//   design into different states.
//
// WHY THE OBSERVABLE OUTPUTS EXIST
//   Vivado performs sequential equivalence pruning: any register or memory
//   whose value cannot reach a primary output is deleted. An earlier version
//   exposed only pc_out. With the .mem files missing, the instruction ROM
//   synthesised as all-zeros, every instruction decoded as ADD R0,R0,R0, no
//   branch ever depended on memory contents, and the entire datapath became
//   unobservable -- Vivado reduced the design to a 17-flop counter and 3 LUTs.
//   It reported success.
//
//   Exposing the writeback bus and latching the result register makes the
//   datapath observable, so that class of silent stripping cannot recur. It
//   also gives something to probe on the board.
//
//   If utilisation ever collapses unexpectedly, check observability before
//   anything else.
//
// PIN BUDGET
//   pc_out was originally 16 bits, occupying every LED. The PC only reaches
//   max 620 (156 instructions) so the upper bits were permanently
//   zero. Narrowing it to 11 bits freed five LEDs for result_out and done.
//
// CHANGE HISTORY
//   - Added clk_div and core_clk distribution; core moved from 100 to 50 MHz.
//   - Added two-flop reset synchroniser.
//   - Added result_out and done; narrowed pc_out from 16 to 11 bits.
//   - Wired the three sequencing signals from ControlUnit to Datapath when the
//     design moved from single-cycle to the multi-cycle FSM.
//////////////////////////////////////////////////////////////////////////////////

module TopModule #(
    parameter RESULT_ADDR = 32'd27776
)(
    input             clk,             // 100 MHz board clock
    input             rst,             // asynchronous, active high
    output     [10:0] pc_out,          // PC max 620, 11 bits is enough
    output reg [3:0]  result_out,      // predicted digit
    output reg        done             // high once the result is stored
);

    // ---------------- /2 clock divider -> 50 MHz core clock ----------------
    reg clk_div = 1'b0;
    always @(posedge clk)
        clk_div <= ~clk_div;

    wire core_clk;
    BUFG bufg_core (.I(clk_div), .O(core_clk));

    // ---------------- reset synchroniser -----------------------------------
    reg rst_meta, rst_sync;
    always @(posedge core_clk or posedge rst) begin
        if (rst) begin
            rst_meta <= 1'b1;
            rst_sync <= 1'b1;
        end else begin
            rst_meta <= 1'b0;
            rst_sync <= rst_meta;
        end
    end

    // ---------------- core -------------------------------------------------
    wire reg_dst, alu_src, mem_to_reg, reg_write;
    wire mem_read, mem_write, branch_equal, branch_not_equal, jump;
    wire [5:0] alu_op;
    wire [1:0] pc_src;
    wire imem_en, dmem_en, pc_enable;

    wire [31:0] pc, instruction, wb_data;
    wire [31:0] dmem_addr, dmem_wdata;
    wire        dmem_we;

    wire [5:0] opcode = instruction[31:26];
    wire [5:0] funct  = instruction[5:0];

    ControlUnit ctrl (
        .clk(core_clk), .rst(rst_sync),
        .opcode(opcode), .funct(funct),
        .reg_dst(reg_dst), .alu_src(alu_src), .mem_to_reg(mem_to_reg),
        .reg_write(reg_write), .mem_read(mem_read), .mem_write(mem_write),
        .branch_equal(branch_equal), .branch_not_equal(branch_not_equal),
        .jump(jump), .alu_op(alu_op), .pc_src(pc_src),
        .imem_en(imem_en), .dmem_en(dmem_en), .pc_enable(pc_enable)
    );

    Datapath datapath (
        .clk(core_clk), .rst(rst_sync),
        .reg_dst(reg_dst), .alu_src(alu_src), .mem_to_reg(mem_to_reg),
        .reg_write(reg_write), .mem_read(mem_read), .mem_write(mem_write),
        .branch_equal(branch_equal), .branch_not_equal(branch_not_equal),
        .jump(jump), .alu_op(alu_op), .pc_src(pc_src),
        .imem_en(imem_en), .dmem_en(dmem_en), .pc_enable(pc_enable),
        .pc(pc), .instruction(instruction),
        .wb_data(wb_data),
        .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_we(dmem_we)
    );

    assign pc_out = pc[10:0];

    // ---------------- result detection, PIPELINED --------------------------
    // Stage 1: capture the store event. Inputs come straight off the
    // datapath, but they only have to reach a D pin, not a D pin behind a
    // 32-bit comparator.
    reg        st_valid;
    reg [31:0] st_addr;
    reg [31:0] st_data;

    always @(posedge core_clk) begin
        if (rst_sync)
            st_valid <= 1'b0;
        else
            st_valid <= dmem_we && dmem_en;
        st_addr <= dmem_addr;
        st_data <= dmem_wdata;
    end

    // Stage 2: the comparator now starts from st_addr, a register output.
    always @(posedge core_clk) begin
        if (rst_sync) begin
            result_out <= 4'd0;
            done       <= 1'b0;
        end else if (st_valid && st_addr == RESULT_ADDR) begin
            result_out <= st_data[3:0];
            done       <= 1'b1;
        end
    end

endmodule
