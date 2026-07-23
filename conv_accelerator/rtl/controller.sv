`timescale 1ns / 1ps
//============================================================
// controller.sv
//  - 전체 파이프라인을 지휘하는 FSM
//  - 역할1: input_buffer 읽기 주소 0~63 순차 발행
//  - 역할2: 파이프라인이 다 비워질 때까지 기다렸다가 done
//
//  [파이프라인 지연]
//    주소발행 → BRAM(1) → window_gen(1) → mac_array(5) = 총 7클럭
//============================================================
module controller #(
    parameter int IMG_SIZE  = 8,
    parameter int DEPTH     = IMG_SIZE * IMG_SIZE,   // 64
    parameter int ADDR_W    = $clog2(DEPTH),         // 6
    parameter int OUT_SIZE  = IMG_SIZE - 2,          // 3x3 유효 출력 = 6
    parameter int OUT_DEPTH = OUT_SIZE * OUT_SIZE,   // 36
    parameter int OUT_ADDR_W= $clog2(OUT_DEPTH),     // 6
    parameter int PIPE_LAT  = 7                      // 파이프라인 총 지연
)(
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    start,          // 시작 명령

    // input_buffer 제어
    output logic                    ib_rd_en,
    output logic [ADDR_W-1:0]       ib_rd_addr,

    // window_gen 제어
    output logic                    wg_in_valid,

    // mac_array 결과 (완료 판단용)
    input  logic                    mac_out_valid,

    // output_buffer 제어
    output logic                    ob_wr_en,
    output logic [OUT_ADDR_W-1:0]   ob_wr_addr,

    // 상태
    output logic                    busy,
    output logic                    done
);

    //--------------------------------------------------------
    // FSM 상태 정의
    //--------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE,     // 대기
        S_RUN,      // 주소 발행 중
        S_DRAIN,    // 파이프라인 비우는 중
        S_DONE      // 완료
    } state_t;

    state_t state, next_state;

    // 카운터들
    logic [ADDR_W-1:0]     rd_cnt;      // 읽기 주소 (0~63)
    logic [OUT_ADDR_W-1:0] wr_cnt;      // 쓰기 주소 (0~35)
    logic [3:0]            drain_cnt;   // 파이프라인 비우기 카운터

    //--------------------------------------------------------
    // 상태 전이 (조합)
    //--------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE:  if (start)                    next_state = S_RUN;
            S_RUN:   if (rd_cnt == DEPTH-1)        next_state = S_DRAIN;
            S_DRAIN: if (drain_cnt >= PIPE_LAT+2)  next_state = S_DONE;
            S_DONE:                                next_state = S_IDLE;
        endcase
    end

    //--------------------------------------------------------
    // 상태 레지스터
    //--------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= next_state;
    end

    //--------------------------------------------------------
    // 읽기 주소 카운터 (input_buffer용)
    //--------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_cnt <= '0;
        end
        else if (state == S_IDLE) begin
            rd_cnt <= '0;
        end
        else if (state == S_RUN) begin
            rd_cnt <= rd_cnt + 1;
        end
    end

    //--------------------------------------------------------
    // 파이프라인 비우기 카운터
    //--------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    drain_cnt <= '0;
        else if (state != S_DRAIN)     drain_cnt <= '0;
        else                           drain_cnt <= drain_cnt + 1;
    end

    //--------------------------------------------------------
    // 쓰기 주소 카운터 (output_buffer용)
    //  - mac 결과가 나올 때마다 증가
    //--------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     wr_cnt <= '0;
        else if (state == S_IDLE)       wr_cnt <= '0;
        else if (mac_out_valid)         wr_cnt <= wr_cnt + 1;
    end

    //--------------------------------------------------------
    // 출력 신호
    //--------------------------------------------------------
    // input_buffer 읽기
    assign ib_rd_en   = (state == S_RUN);
    assign ib_rd_addr = rd_cnt;

    // window_gen 입력 유효
    //  → BRAM 1클럭 지연 반영: 주소 낸 다음 클럭에 데이터가 나오므로
    //    in_valid도 1클럭 늦게 줘야 함
    logic ib_rd_en_d;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) ib_rd_en_d <= 1'b0;
        else        ib_rd_en_d <= ib_rd_en;
    end
    assign wg_in_valid = ib_rd_en_d;

    // output_buffer 쓰기 (mac 결과가 나오면 바로 저장)
    assign ob_wr_en   = mac_out_valid;
    assign ob_wr_addr = wr_cnt;

    // 상태 신호
    assign busy = (state == S_RUN) || (state == S_DRAIN);
    assign done = (state == S_DONE);

endmodule