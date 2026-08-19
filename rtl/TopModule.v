`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// TopModule -- MAC4 build, with pipelined result detection
//
// THE TIMING BUG THIS FIXES
// -------------------------
// The five worst paths in the MAC4 build ended at done_reg/CE and
// result_out_reg[*]/CE, at -1.254 ns. They were caused by this line:
//
//     else if (dmem_we && dmem_en && dmem_addr == RESULT_ADDR)
//
// dmem_addr IS alu_result -- the end of the already-longest path in the
// design. Hanging a 32-bit equality comparator off it, driving a clock
// enable, added roughly 1.5 ns to a path that was already critical. The
// result-latch debug feature was the single worst offender in the design.
//
// FIX: register the store event first, compare on the following cycle. The
// comparator now starts FROM a register instead of from alu_result, so it is
// off the critical path entirely. Cost: 65 flip-flops of 65,200. done
// asserts one core cycle later, which nothing depends on.
//
// After this, the binding paths become the register-file writebacks at
// -0.988 ns, which the ALU changes (balanced MAC4 adder tree, MAC arm
// disabled) are intended to close.
//
// CLOCKING
// --------
// Board clock is 100 MHz; the core runs on a /2 divided clock at 50 MHz.
// The design needs 21.254 ns before these fixes (47.05 MHz). If it still
// fails to close after the ALU changes, replace the divider with an MMCM at
// 45 MHz -- 610,845 cycles is 13.57 ms there, still 1.98x faster than the
// 26.9 ms pre-MAC4 baseline. A working 45 MHz bitstream beats a failing
// 50 MHz one.
//
// RESULT_ADDR is 27776 for the MAC4 memory map (pack_data_mem_v3.py).
// It was 28508 for the pre-MAC4 map -- do not mix them up, or the digit
// never latches and done never asserts.
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