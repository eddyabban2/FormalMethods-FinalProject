//====================================================================
// bsg_imul_iterative.sv
// 11/15/2016, shawnless.xie@gmail.com
//====================================================================
//
// An 32bit integer iterative multiplier, capable of signed & unsigned division
//                          a3      a2      a1      a0
//                          b3      b2      b1      b0
// ------------------------------------------------------------------
//                       |  a3b0    a2b0    a1b0    a0b0
//                 a3b1  |  a2b1    a1b1    a0b1
//            a3b2 a2b2  |  a1b2    a0b2
//       a3b3 a2b3 a1b3  |  a0b3
// ------------------------------------------------------------------
//       High Part       |            Low Part
//
// This is computing the section of a that is within 32 bits, on each iteration we add A left shifted over by a certain amount if the lowerst bit of b is positive
// 1. for LOW part output:
//        def imul( a, b ):
//            result = 0
//            for i in range(32):
//                if b & 0x1 == 1:
//                    result += a
//                a = a << 1
//                b = b >> 1
//            return result
//
// 2. for HIGH part output
//        def imul( a, b ):
//            result = 0
//            for i in range(31):
//                if b & 0x1 == 1:
//                   result = ( {1'b0,result} + {1'b0,a}) >> 1
//                else:
//                   result = result >> 1
//
//                b = b >> 1
//            return result
// 3. for negtive high part output, we have to check if the low part of the
// abs(result) are all zeros. If it is all zero, we have to add 1 to the
// neg high part, otherwise we only have to neg the high part
//  -(4'b10_00) = ~(4'b10 00) + 1 = 4'b01_11 + 1= 4'b10_00
//  -(4'b10_10) = ~(4'b10_10) + 1 = 4'b01_01 + 1= 4'b01_10
//
// We add a one bit register to track whether the shifted out LSB of the result
// are all zeros
//
`include "bsg_defines.sv"

module bsg_imul_iterative  #( width_p = 32)
    (input                  clk_i
    ,input                  reset_i

    ,input                  v_i      //there is a request
    ,output                 ready_and_o  //idiv is idle

    ,input [width_p-1: 0]   opA_i
    ,input                  signed_opA_i
    ,input [width_p-1: 0]   opB_i
    ,input                  signed_opB_i
    //needs the high part result or low part result
    ,input                  gets_high_part_i

    ,output                 v_o      //result is valid
    ,output [width_p-1: 0]  result_o
    ,input                  yumi_i
    );

    localparam lg_width_lp = `BSG_SAFE_CLOG2( width_p + 1);

///////////////////////////////////////////////////////////////////////////////
//   counter for the shift operation
   logic[lg_width_lp-1:0]  shift_counter_r;
   logic                   gets_high_part_r;

   wire shift_counter_full = gets_high_part_r
            ? ( shift_counter_r == (width_p-1) )
            : ( shift_counter_r ==  width_p    );
///////////////////////////////////////////////////////////////////////////////
// The state machine
   typedef enum logic[2:0] {IDLE, NEG_A, NEG_B, CALC, NEG_R, DONE } imul_ctrl_stat;
   imul_ctrl_stat curr_state_r, next_state;

   // state machine register
   always_ff@( posedge clk_i ) begin
        if( reset_i )   curr_state_r <= IDLE;
        else            curr_state_r <= next_state;
   end

   //determing next state
   always_comb begin
        unique case(curr_state_r )
            IDLE: begin
                if( v_i )  next_state = NEG_A;
                else       next_state = IDLE;
            end

            NEG_A:         next_state = NEG_B;
            NEG_B:         next_state = CALC ;

            CALC: begin
                if( !shift_counter_full ) next_state = CALC;
                else                      next_state = NEG_R;
            end

            NEG_R:         next_state = DONE;

            DONE: begin
                if( yumi_i ) next_state = IDLE;
                else         next_state = DONE;
            end

            default: next_state = IDLE;
        endcase
   end

///////////////////////////////////////////////////////////////////////////////
//   update the shift_counter_r
   always_ff@( posedge clk_i )  begin
        if ( reset_i ) shift_counter_r <= 'b0;   //reset
        else if( curr_state_r != CALC  && next_state == CALC )
                       shift_counter_r <= 'b0;   //new request
        else if( curr_state_r == CALC)
                       shift_counter_r <= shift_counter_r + 1;
   end

///////////////////////////////////////////////////////////////////////////////
//   the computation logic
  logic [width_p-1:0]  opA_r, opB_r, result_r;
  logic [width_p-1:0]  adder_a, adder_b;
  logic [width_p  :0]  adder_result,shifted_adder_result;

  // -opA_r = ~opA_r + 1, reusing the adder here
  // used to invert a number based on the current state
  assign adder_a = (curr_state_r == NEG_A) ? ~opA_r  :
                   (curr_state_r == NEG_B) ? ~opB_r  :
                   (curr_state_r == NEG_R) ? ~result_r : result_r;

  wire adder_neg_op = (curr_state_r == NEG_A
                    || curr_state_r == NEG_B
                    || curr_state_r == NEG_R);

  // assigned 1 with zero preprended or opA_r
  assign adder_b = adder_neg_op  ? { {(width_p-1){1'b0}}, 1'b1}
                                 :  opA_r   ;

  assign adder_result = {1'b0, adder_a} + {1'b0, adder_b};

  assign shifted_adder_result = adder_result >> 1;

///////////////////////////////////////////////////////////////////////////////
// control register  update logic

  wire latch_input = v_i & ready_and_o;
  logic signed_opA_r, signed_opB_r, need_neg_result_r;

  wire  signed_opA = signed_opA_i & opA_i[width_p-1];
  wire  signed_opB = signed_opB_i & opB_i[width_p-1];

  always_ff@(posedge clk_i ) begin
    if( reset_i )                  signed_opA_r <= 1'b0;
    else if( latch_input )         signed_opA_r <= signed_opA;
  end

  always_ff@(posedge clk_i ) begin
    if( reset_i )                  signed_opB_r <= 1'b0;
    else if( latch_input )         signed_opB_r <= signed_opB;
  end

  always_ff@(posedge clk_i ) begin
    if( reset_i )                  need_neg_result_r <= 1'b0;
    else if( latch_input )         need_neg_result_r <= signed_opA ^ signed_opB ;
  end

  always_ff@(posedge clk_i ) begin
    if( reset_i )                  gets_high_part_r <= 1'b0;
    else if( latch_input )         gets_high_part_r <= gets_high_part_i;
  end

///////////////////////////////////////////////////////////////////////////////
//   operands update logic
  always_ff@(posedge clk_i) begin
    if( reset_i )                   opA_r <= 'b0;
    else if( latch_input )          opA_r <= opA_i;

    //opA only shifts when we want low part result
    else if(curr_state_r == CALC  && (!gets_high_part_r ) )
                                    opA_r <= opA_r << 1 ;

    else if(curr_state_r == NEG_A && signed_opA_r)  //get the abs(opA)
                                    opA_r <= adder_result[width_p-1:0];
  end

  always_ff@(posedge clk_i) begin
    if( reset_i )                   opB_r <= 'b0;
    else if( latch_input )          opB_r <= opB_i;
    else if(curr_state_r == CALC)   opB_r <= opB_r >> 1 ;

    else if(curr_state_r == NEG_B && signed_opB_r)  //get the abs(opB)
                                    opB_r <= adder_result[width_p-1:0];
  end

///////////////////////////////////////////////////////////////////////////////
//  track the LSB of the result which is shifted out for high part  computation

  wire shifted_lsb = opB_r[0] ? adder_result[0]  : result_r[0];

  logic all_sh_lsb_zero_r;
  always_ff@(posedge clk_i ) begin
    if( reset_i )                   all_sh_lsb_zero_r <= 1'b0;
    else if( latch_input )          all_sh_lsb_zero_r <= 1'b1;
    else if( curr_state_r == CALC ) all_sh_lsb_zero_r <= all_sh_lsb_zero_r
                                                       & (~shifted_lsb);
  end

///////////////////////////////////////////////////////////////////////////////
//  update the result register
// synopsys sync_set_reset  "reset_i, latch_input"
  always_ff@(posedge clk_i) begin
    if( reset_i )                   result_r <= 'b0;
    else if( latch_input )          result_r <= 'b0;

    else if(curr_state_r == NEG_R && need_neg_result_r) //get the signed result
        //1. High part Neg in case Low part are not all zeros
        if( gets_high_part_r && !all_sh_lsb_zero_r )   //No cin, just reverse
                                    result_r <= ~result_r;
        //1. Low part Neg
        //2. High part Neg in case Low part are all zeros, ~(result_r) +1
        else
                                    result_r <= adder_result[width_p-1:0];

    else if(curr_state_r == CALC && opB_r[0]) begin     //get the accumulated result
        if( gets_high_part_r )      result_r <= shifted_adder_result[width_p-1:0];
        else                        result_r <= adder_result        [width_p-1:0];
    end
    else if(curr_state_r == CALC && !opB_r[0])begin    //No addition
        if( gets_high_part_r )      result_r <= result_r >>1 ;
    end
  end

reg first_cycle_done;
initial begin
    first_cycle_done = '0;
end

always_ff @(posedge clk_i) begin
    first_cycle_done <= '1;
end


///////////////////////////////////////////////////////////////////////////////
//   the output logic

  assign ready_and_o    =  ( curr_state_r == IDLE );
  assign result_o   =    result_r;
  assign v_o        =  ( curr_state_r == DONE );

`ifdef FORMAL

// verifying state logic 
initial curr_state_r = IDLE;
initial shift_counter_r = '0;
initial signed_opA_r = 1'b0;
initial signed_opB_r = 1'b0;
initial reset_i = 1'b1;

// verifying shift counter 
always_ff @(posedge clk_i) begin
  if ($past(reset_i))
    shift_counter_reset: assert(shift_counter_r == 1'b0);
  else if ($past(curr_state_r) != CALC && $past(next_state) == CALC) 
    shitft_counter_reset_before_calc: assert(shift_counter_r == 1'b0);
  else if ($past(curr_state_r) == CALC && curr_state_r == CALC)
    shitft_counter_reset_counts: assert(shift_counter_r == $past(shift_counter_r) + 1);
end

always_comb begin
  if (v_o)
    v_o_iff_done: assert(curr_state_r == DONE);
end

always_comb begin
  if (ready_and_o)
    ready_and_o_iff_idle: assert(curr_state_r == IDLE);
end

// Verify all control registers latch on valid input
always_ff @(posedge clk_i) begin
  if (!$past(reset_i)) begin
    if ($past(latch_input) && first_cycle_done) begin
      gets_high_part_latches: assert(gets_high_part_r == $past(gets_high_part_i));
      signed_opA_latches: assert(signed_opA_r == $past(signed_opA));
      signed_opB_latches: assert(signed_opB_r == $past(signed_opB));
      need_neg_result_latches: assert(need_neg_result_r == $past(signed_opA ^ signed_opB));
    end
  else if (first_cycle_done) 
    begin
      gets_high_part_latches_reset: assert(gets_high_part_r == 1'b0);
      signed_opA_latches_reset: assert(signed_opA_r == 1'b0);
      signed_opB_latches_reset: assert(signed_opB_r == 1'b0);
      need_neg_result_latches_reset: assert(need_neg_result_r == 1'b0);
    end
  end
end

always_comb begin 
  unique case(curr_state_r)
    IDLE: begin
      if( v_i )  idle_into_NEG_A: assert(next_state == NEG_A);
      else       idle_stays_idle: assert(next_state == IDLE);
    end
    NEG_A: neg_a_to_neg_b: assert(next_state == NEG_B);
    NEG_B: neg_b_to_calc:  assert(next_state == CALC);
    NEG_R: neg_r_to_done:  assert(next_state == DONE);

    CALC: begin
      if( !shift_counter_full ) calc_stays_calc: assert(next_state == CALC);
      else                      calc_to_neg_r: assert(next_state == NEG_R);
    end
    DONE: begin
      if( yumi_i ) yumi_to_idle_when_yumi: assert(next_state == IDLE);
      else         done_stays_done: assert(next_state == DONE);
    end
    default: default_to_idle: assert(next_state == IDLE);
  endcase
end 

`ifdef VERIFIC


`endif // VERIFIC

`endif // FORMAL


endmodule
