`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_TopModule -- behavioural testbench
//
// PURPOSE
//   Drives clock and reset, runs the processor to completion, and reports the
//   result word and cycle count. Used to confirm the hardware agrees with the
//   golden model in sim/ before synthesis.
//
// WHAT IT CHECKS
//   Expected result for the supplied input image: argmax = 3,
//   with the ten output logits matching sim/verify_final.py BIT-EXACTLY.
//   Not approximately. In fixed-point integer arithmetic every operation is
//   exactly defined, so any divergence is a real disagreement about semantics.
//   Near-agreement is the most dangerous outcome, because it resembles rounding
//   and is usually a scale error.
//
// BEFORE RUNNING
//   Confirm instruction_mac4.mem and data_mac4.mem in the simulation directory were
//   produced by the SAME toolchain version as each other -- assembler output
//   paired with pack_data_mem_v3.py output. A version mismatch between them
//   simulates cleanly and produces wrong logits, which is exactly what happened
//   once on this project and took a while to find.
//
// TRACING
//   Datapath.v contains a $display block inside `synthesis translate_off` that
//   prints PC, opcode, operands, ALU result and writeback each cycle. Enable it
//   and diff against sim/sim_isa.py output to locate the first divergent
//   instruction.
//
// RUNTIME
//   Full inference is 610,845 cycles (MAC4) or 1,343,355 (MAC only). At 20 ns
//   per cycle that is a long behavioural simulation. For iteration, truncate to
//   a single neuron or a single layer rather than waiting for the full run.
//////////////////////////////////////////////////////////////////////////////////

module tb_TopModule;

    // ---------------- configuration ----------------
    localparam HALF_PERIOD    = 5;          // 100 MHz board clock
    localparam RESULT_ADDR = 27776;      // packer's "result word"
    localparam EXPECTED_DIGIT = 3;          // from mnist_label.txt
    localparam Y3_BASE = 27766;      // packer's y_base for layer 3

    localparam TRACE          = 0;          // 1 = per-instruction trace
    localparam TRACE_FROM     = 0;          // first core cycle to trace
    localparam TRACE_TO       = 2000;       // last core cycle to trace

    localparam TIMEOUT_CYCLES = 2_000_000;  // core cycles; expected ~1,343,355

    // ---------------- DUT ----------------
    reg         clk = 1'b0;
    reg         rst;
    wire [10:0] pc_out;
    wire [3:0]  result_out;
    wire        done;

    TopModule top (
        .clk        (clk),
        .rst        (rst),
        .pc_out     (pc_out),
        .result_out (result_out),
        .done       (done)
    );

    always #HALF_PERIOD clk = ~clk;

    // ---------------- reset ----------------
    initial begin
        rst = 1'b1;
        #(HALF_PERIOD * 20);                // hold well past a few core edges
        rst = 1'b0;
        $display("[%0t] reset released", $time);
    end

    // ---------------- counters (on the CORE clock) ----------------
    integer core_cycles;
    integer instr_count;
    reg [31:0] last_pc;

    initial begin
        core_cycles = 0;
        instr_count = 0;
        last_pc     = 32'hFFFF_FFFF;
    end

    always @(posedge top.core_clk) begin
        if (rst) begin
            core_cycles <= 0;
            instr_count <= 0;
            last_pc     <= 32'hFFFF_FFFF;
        end else begin
            core_cycles <= core_cycles + 1;
            if (top.datapath.pc !== last_pc) begin
                instr_count <= instr_count + 1;
                last_pc     <= top.datapath.pc;
            end
        end
    end

    // ---------------- progress heartbeat ----------------
    always @(posedge top.core_clk) begin
        if (!rst && (core_cycles % 100_000 == 0) && core_cycles != 0)
            $display("[%0t] %0d core cycles, %0d instructions, PC=%0d",
                     $time, core_cycles, instr_count, top.datapath.pc);
    end

    // ---------------- finish on done ----------------
    integer i;
    reg [31:0] logit;

    always @(posedge top.core_clk) begin
        if (!rst && done) begin
            $display("\n================ INFERENCE COMPLETE ================");
            $display("core cycles      : %0d", core_cycles);
            $display("instructions     : %0d", instr_count);
            $display("simulated time   : %0t ns  (%0.2f ms)", $time, $time/1.0e6);
            $display("");
            $display("logits (y3_base = %0d):", Y3_BASE);
            for (i = 0; i < 10; i = i + 1) begin
                logit = top.datapath.DMEM.mem[Y3_BASE + i];
                $display("   class %0d : %0d", i, $signed(logit));
            end
            $display("");
            $display("mem[%0d] (argmax) : %0d", RESULT_ADDR,
                     $signed(top.datapath.DMEM.mem[RESULT_ADDR]));
            $display("result_out pins  : %0d", result_out);
            $display("expected digit   : %0d", EXPECTED_DIGIT);
            if (result_out === EXPECTED_DIGIT[3:0])
                $display("\n*** PASS ***\n");
            else
                $display("\n*** FAIL -- got %0d, expected %0d ***\n",
                         result_out, EXPECTED_DIGIT);
            $finish;
        end
    end

    // ---------------- timeout ----------------
    always @(posedge top.core_clk) begin
        if (!rst && core_cycles > TIMEOUT_CYCLES) begin
            $display("\n*** TIMEOUT after %0d core cycles, PC=%0d ***",
                     core_cycles, top.datapath.pc);
            $display("Expected completion near 1,343,355 cycles.");
            $display("If PC is stuck, check the branch offsets in the assembly.");
            $finish;
        end
    end

    // ---------------- optional instruction trace ----------------
    // Only prints in S_WB (one line per instruction, not per state) and only
    // inside the configured window.
    generate
    if (TRACE) begin : g_trace
        always @(posedge top.core_clk) begin
            if (!rst && top.pc_enable &&
                core_cycles >= TRACE_FROM && core_cycles <= TRACE_TO) begin
                $display("c%0d PC=%0d instr=%b ALU=%0d mem=%0d W[%0d]=%0d",
                         core_cycles,
                         top.datapath.pc,
                         top.datapath.instruction,
                         $signed(top.datapath.alu_result),
                         $signed(top.datapath.mem_read_data),
                         top.datapath.write_reg,
                         $signed(top.datapath.write_data));
            end
        end
    end
    endgenerate

endmodule
