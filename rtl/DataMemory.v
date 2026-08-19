`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// DataMemory
//
// PURPOSE
//   Read/write data store holding the packed INT8 network -- weights, biases,
//   input image, activation scratch buffers and the result word. Initialised
//   from a $readmemb image produced by tools/pack_data_mem_v3.py. Inferred as
//   Block RAM.
//
// INTERFACE
//   clk        core clock
//   en         enable -- asserted by ControlUnit in S_EXEC for LW and SW
//   we         write enable -- SW only
//   addr       [31:0] WORD address (see below)
//   wdata      [31:0] write data
//   rdata      [31:0] REGISTERED output -- valid the cycle AFTER addr
//
// ADDRESSING IS BY WORD, NOT BY BYTE
//   LW r5, 3(r10) reads the word at r10 + 3. This differs from stock MIPS and
//   is deliberate: the packed network is an array of 32-bit words with no
//   sub-word access anywhere in the program, so byte addressing would mean
//   every access carries a shift the hardware never needs.
//
//   The PC still uses byte convention (PC+4, branch offsets << 2). The two
//   conventions coexist. Getting them confused produces offsets wrong by
//   exactly 4x, which in a dense weight array still lands on a plausible
//   weight -- the loads succeed and the arithmetic is silently wrong. This cost
//   one of the longer debugging sessions on the project.
//
// DEPTH AND THE PACKING
//   The network does not fit unpacked:
//
//       one INT8 per 32-bit word : 110,390 words (~3,450 Kb)
//       XC7S50 total BRAM        :               2,700 Kb
//
//   Packing four INT8 values per word gives 28,509 words, which fits.
//   Lane layout, little-endian:
//
//       [31:24] lane 3 | [23:16] lane 2 | [15:8] lane 1 | [7:0] lane 0
//
//   This layout must match ALU.v's MAC4 lane order and
//   tools/pack_data_mem_v3.py exactly. A mismatch computes a valid-looking dot
//   product over the wrong pairs and produces no error of any kind.
//
// TIMING CONTRACT
//   The read is SYNCHRONOUS -- required for BRAM inference, same reasoning as
//   InstructionMemory.v. The address must be stable in the same cycle en is
//   asserted (S_EXEC), so do not insert a register between the ALU result and
//   addr without adding an FSM state.
//
// MEMORY MAP (word indices; DataMemory.v is word-addressed)
// ------------------------------------------------------------
//   [0 .. 8L-1]                        header, 8 words per layer
//   [x_base[0] ..]                     input image, one int8 per 32-bit word
//   per layer l:
//     [w_base[l] ..]                   PACKED weights, 4 int8 per word
//     [b_base[l] ..]                   biases, int32, at acc_scale[l]
//     [y_base[l] ..]                   activations, int32
//   [result_word]                      one word for the argmax result
//
// Header for layer l (base = 8*l):
//   +0 n_in          +1 n_out         +2 x_base        +3 w_base
//   +4 b_base        +5 y_base        +6 w_row_stride  +7 requant_shift
//
// Weight for neuron j, input i:
//   word = w_base + j*w_row_stride + (i >> 2),  byte = i & 3
//
// Final Layout
// -----------------------------
//     header      layer dimensions, scale factors, requantisation shifts
//     layer 1     784 x 128 weights packed 4/word; biases at accumulator scale
//     layer 2     128 x 64 weights; biases
//     layer 3     64 x 10 weights; biases
//     input       784 INT8 pixels, packed 4/word
//     activations hidden-layer scratch
//     result      word 28508 -- argmax output, latched to result_out
//
// Word by Word Layout
// ----------------------
//    header      0 ..    23     8 words per layer
//    image      24 ..   219     196 words, PACKED
//    L1 w      220 .. 25307     25088 words   b 25308..25435   y 25436..25467 (32 packed)
//    L2 w    25468 .. 27515      2048 words   b 27516..27579   y 27580..27595 (16 packed)
//    L3 w    27596 .. 27755       160 words   b 27756..27765   y 27766..27775 (10 int32)
//    result  27776
//
// PACKER VERSION
//   Only pack_data_mem_v3.py produces this layout. Running an earlier packer
//   against the current assembly gives a design that simulates cleanly and
//   computes nonsense -- the memory image is well-formed, just laid out
//   differently from what the program expects. v2 is deliberately not in this
//   repository.
//
// CHANGE HISTORY
//   - Read converted from asynchronous to registered for BRAM inference.
//   - Depth reduced from 131,072 words to 28,509 after packing.
//   - Addressing corrected from byte to word throughout.
//   - Lane order fixed to match the packer and the MAC4 adder tree.
//////////////////////////////////////////////////////////////////////////////////

module DataMemory #(
    parameter AW       = 15,                 // 2^15 = 32768 words
    parameter MEM_FILE = "data_mac4.mem"
)(
    input               clk,
    input               en,                  // launch an access this cycle
    input               mem_write,
    input      [31:0]   addr,                // WORD address (matches packer)
    input      [31:0]   write_data,
    output reg [31:0]   read_data
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:(1<<AW)-1];

    wire [AW-1:0] word_index = addr[AW-1:0];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = 32'b0;
        $readmemb(MEM_FILE, mem);
    end

    // Single always block, no reset, no initialisation loop.
    // Any of those three would break BRAM inference.
    always @(posedge clk) begin
        if (en) begin
            if (mem_write)
                mem[word_index] <= write_data;
            read_data <= mem[word_index];    // read-first
        end
    end

endmodule
