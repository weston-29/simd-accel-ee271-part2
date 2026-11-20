`include "defines.sv"

module controller(

    // Clock and Reset
    input wire clk,
    input wire rst_n,

    // Input Instruction
    input  instruction_t inst,
    input  logic         inst_valid,
    output logic         inst_exec_begins,

    // Output Instructions to PEs/Buffer
    output pe_inst_t     pe_inst,
    output logic         pe_inst_valid,
    output buf_inst_t    buf_inst,
    output logic         buf_inst_valid

);

    typedef enum {IDLE, EXECUTING} fsm_t; 
    fsm_t state;

    // START IMPLEMENTATION

    // ---------------------------------------------------------------
    // The instruction being executed, latched when it's accepted.
    //   Python: mem_inst, pe_inst, a_inc, b_inc, count
    // The running offsets (a_offset, b_offset) live inside cur_buf.
    // ---------------------------------------------------------------
    buf_inst_t                                cur_buf;     // mem_inst, with the CURRENT offsets
    pe_inst_t                                 cur_pe;      // pe_inst
    logic [`CONTROLLER_MEMA_INC_BITWIDTH-1:0] a_inc;       // MemAIncrement
    logic [`CONTROLLER_MEMB_INC_BITWIDTH-1:0] b_inc;       // MemBIncrement
    logic [`CONTROLLER_COUNT_BITWIDTH-1:0]    remaining;   // repetitions left after this one

    // Tell the instruction memory "I've taken this instruction, move on"
    assign inst_exec_begins = (state == IDLE) && inst_valid;

    // ---------------------------------------------------------------
    // The loop:  for i in range(count + 1)
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            cur_buf   <= '0;
            cur_pe    <= '0;
            a_inc     <= '0;
            b_inc     <= '0;
            remaining <= '0;
        end else begin
            case (state)
                IDLE: begin
                    if (inst_valid) begin
                        // Pull out the five fields; starting offsets come with buf_instruction
                        cur_buf   <= inst.buf_instruction;
                        cur_pe    <= inst.pe_instruction;
                        a_inc     <= inst.mema_inc;
                        b_inc     <= inst.memb_inc;
                        remaining <= inst.count;
                        state     <= EXECUTING;
                    end
                end

                EXECUTING: begin
                    // Step 5: step the offsets forward (16-bit registers wrap on their own)
                    cur_buf.mema_offset <= cur_buf.mema_offset + a_inc;
                    cur_buf.memb_offset <= cur_buf.memb_offset + b_inc;

                    // Loop bookkeeping: Count + 1 repetitions in total
                    if (remaining == 0) state     <= IDLE;
                    else                remaining <= remaining - 1;
                end
            endcase
        end
    end

    // ---------------------------------------------------------------
    // Steps 1 + 3: this repetition's memory instruction goes to the buffer now
    // ---------------------------------------------------------------
    assign buf_inst       = cur_buf;
    assign buf_inst_valid = (state == EXECUTING);

    // ---------------------------------------------------------------
    // Step 4: the same repetition's PE instruction, ONE CYCLE LATER,
    // because the buffer's READ data takes a cycle to come out of the SRAM.
    // ---------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pe_inst       <= '0;
            pe_inst_valid <= 1'b0;
        end else begin
            pe_inst       <= cur_pe;
            pe_inst_valid <= (state == EXECUTING);
        end
    end

    // END IMPLEMENTATION

endmodule

