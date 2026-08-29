`timescale 1ns / 1ps
/*
 * wake_ctrl_enhanced - adds two read-only diagnostic features on top of the
 * already-verified base design, using spare tile area rather than padding:
 *
 *   1. Per-channel wake counters (ch0_wcnt..ch3_wcnt): how many times each
 *      individual sensor channel has contributed to a genuine wake, so you
 *      can tell which sensor is actually driving activity.
 *   2. 8-entry event history log (hist_flat, hist_wptr): a circular buffer
 *      recording which channel (by priority_ch) caused each of the last 8
 *      wakes, so you can reconstruct "what happened" after the fact instead
 *      of only seeing a live snapshot.
 *
 * Both are purely additive: no change to thresh_in/ch_en/mode_and behavior,
 * no new input pins required. All new ports are outputs, read-only.
 */

module wake_ctrl #(
    parameter N  = 4,
    parameter DB = 8,
    parameter PW = 4
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire [N-1:0] thresh_in,
    input  wire [N-1:0] ch_en,
    input  wire         mode_and,
    output reg          wake_out,
    output reg  [N-1:0] evt_flags,
    output reg  [2:0]   priority_ch,
    output reg  [15:0]  wake_count,
    output reg  [15:0]  false_wake_cnt,

    // -------- new diagnostic outputs (read-only, additive) --------
    output reg  [15:0]  ch0_wcnt,
    output reg  [15:0]  ch1_wcnt,
    output reg  [15:0]  ch2_wcnt,
    output reg  [15:0]  ch3_wcnt,
    output reg  [23:0]  hist_flat,   // 8 entries x 3 bits, entry0 in bits[2:0]
    output reg  [2:0]   hist_wptr    // next write slot (0-7, wraps)
);

    localparam DBW = (DB <= 1) ? 1 : $clog2(DB);
    localparam [DBW-1:0] DB_M1 = DB - 1;

    reg [N-1:0]   sync1, sync2;
    reg [DBW-1:0] dbcnt [0:N-1];
    reg [N-1:0]   stable;
    reg [N-1:0]   stable_prev;
    reg [PW-1:0]  pcnt;
    reg           firing;
    reg           wake_out_d;

    // Stage 1: Synchronizer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sync1 <= {N{1'b0}};
            sync2 <= {N{1'b0}};
        end else begin
            sync1 <= thresh_in;
            sync2 <= sync1;
        end
    end

    // Stage 2: Debouncer
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_debounce
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (!ch_en[i]) begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end else if (sync2[i]) begin
                    if (dbcnt[i] >= DB_M1)
                        stable[i] <= 1'b1;
                    else
                        dbcnt[i] <= dbcnt[i] + 1'b1;
                end else begin
                    dbcnt[i]  <= {DBW{1'b0}};
                    stable[i] <= 1'b0;
                end
            end
        end
    endgenerate

    // Stage 3: Priority Encoder
    wire [N-1:0] pri_active = stable & ch_en;
    reg  [2:0]   pri_next;
    always @* begin
        pri_next = 3'd7;
        if      (pri_active[0]) pri_next = 3'd0;
        else if (pri_active[1]) pri_next = 3'd1;
        else if (pri_active[2]) pri_next = 3'd2;
        else if (pri_active[3]) pri_next = 3'd3;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            priority_ch <= 3'd7;
        else
            priority_ch <= pri_next;
    end

    // Stage 4: Event Detection FSM
    wire [N-1:0] active_stable    = stable & ch_en;
    wire [N-1:0] active_prev      = stable_prev & ch_en;
    wire         all_active       = (ch_en != {N{1'b0}}) && (active_stable == ch_en);
    wire         all_active_prev  = (ch_en != {N{1'b0}}) && (active_prev == ch_en);
    wire         all_active_edge  = all_active && !all_active_prev;
    wire         any_active       = (active_stable != {N{1'b0}});
    wire         new_edge         = (active_stable != active_prev) && any_active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            firing         <= 1'b0;
            evt_flags      <= {N{1'b0}};
            stable_prev    <= {N{1'b0}};
            false_wake_cnt <= 16'd0;
        end else begin
            stable_prev <= stable;

            if (!firing) begin
                if (mode_and) begin
                    if (all_active_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end else if (all_active) begin
                    end else if (new_edge) begin
                        if (!(&false_wake_cnt))
                            false_wake_cnt <= false_wake_cnt + 1'b1;
                    end
                end else begin
                    if (any_active && new_edge) begin
                        firing    <= 1'b1;
                        evt_flags <= active_stable;
                    end
                end
            end else if (&pcnt) begin
                firing    <= 1'b0;
                evt_flags <= {N{1'b0}};
            end
        end
    end

    // Stage 5: Pulse Generator
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out <= 1'b0;
            pcnt     <= {PW{1'b0}};
        end else begin
            if (firing && !wake_out) begin
                wake_out <= 1'b1;
                pcnt     <= {PW{1'b0}};
            end else if (wake_out) begin
                if (&pcnt) begin
                    wake_out <= 1'b0;
                    pcnt     <= {PW{1'b0}};
                end else begin
                    pcnt <= pcnt + 1'b1;
                end
            end
        end
    end

    // Stage 6: Wake Counter (saturating) + rising-edge detect, shared by
    // the aggregate counter and the new per-channel / history features
    wire wake_rise = wake_out && !wake_out_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wake_out_d <= 1'b0;
            wake_count <= 16'd0;
        end else begin
            wake_out_d <= wake_out;
            if (wake_rise && !(&wake_count))
                wake_count <= wake_count + 1'b1;
        end
    end

    // Stage 7 (new): Per-channel saturating wake counters. On each wake
    // rising edge, every channel bit set in evt_flags at that instant gets
    // its own counter incremented (evt_flags is still holding the latched
    // cause of the wake at this point -- it only clears when the pulse ends).
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch0_wcnt <= 16'd0;
            ch1_wcnt <= 16'd0;
            ch2_wcnt <= 16'd0;
            ch3_wcnt <= 16'd0;
        end else if (wake_rise) begin
            if (evt_flags[0] && !(&ch0_wcnt)) ch0_wcnt <= ch0_wcnt + 1'b1;
            if (evt_flags[1] && !(&ch1_wcnt)) ch1_wcnt <= ch1_wcnt + 1'b1;
            if (evt_flags[2] && !(&ch2_wcnt)) ch2_wcnt <= ch2_wcnt + 1'b1;
            if (evt_flags[3] && !(&ch3_wcnt)) ch3_wcnt <= ch3_wcnt + 1'b1;
        end
    end

    // Stage 8 (new): 8-entry circular event history log. Records
    // priority_ch (the highest-priority contributing channel, or 7 if
    // somehow none -- shouldn't happen on a real wake) at each wake event.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hist_flat <= 24'd0;
            hist_wptr <= 3'd0;
        end else if (wake_rise) begin
            case (hist_wptr)
                3'd0: hist_flat[2:0]   <= priority_ch;
                3'd1: hist_flat[5:3]   <= priority_ch;
                3'd2: hist_flat[8:6]   <= priority_ch;
                3'd3: hist_flat[11:9]  <= priority_ch;
                3'd4: hist_flat[14:12] <= priority_ch;
                3'd5: hist_flat[17:15] <= priority_ch;
                3'd6: hist_flat[20:18] <= priority_ch;
                3'd7: hist_flat[23:21] <= priority_ch;
            endcase
            hist_wptr <= hist_wptr + 1'b1; // wraps naturally, 3'd7+1=3'd0
        end
    end

endmodule
/*
 * ===========================================================================
 * tt_um_wake_ctrl - TinyTapeout top-level wrapper (enhanced)
 * ===========================================================================
 * Pin mapping is UNCHANGED from the base design -- no existing behavior or
 * pin meaning is altered. Only the reg_sel readback bus is widened (3->5
 * bits) to expose the new diagnostic data, using uio_in bits that were
 * previously unused.
 *
 *   ui_in[3:0]  = thresh_in[3:0]        (unchanged)
 *   ui_in[7:4]  = ch_en[3:0]            (unchanged)
 *   uio_in[0]   = mode_and              (unchanged)
 *   uio_in[5:1] = reg_sel[4:0]          (widened from 3 to 5 bits)
 *   uio_in[7:6] = unused
 *
 *   reg_sel map:
 *     0      -> {wake_out, priority_ch[2:0], evt_flags[3:0]}
 *     1      -> wake_count[7:0]
 *     2      -> wake_count[15:8]
 *     3      -> false_wake_cnt[7:0]
 *     4      -> false_wake_cnt[15:8]
 *     5      -> ch0_wcnt[7:0]
 *     6      -> ch0_wcnt[15:8]
 *     7      -> ch1_wcnt[7:0]
 *     8      -> ch1_wcnt[15:8]
 *     9      -> ch2_wcnt[7:0]
 *     10     -> ch2_wcnt[15:8]
 *     11     -> ch3_wcnt[7:0]
 *     12     -> ch3_wcnt[15:8]
 *     13-20  -> event_history[0..7]  (3-bit channel code per entry, upper 5 bits 0)
 *     21     -> hist_wptr (next write slot, 0-7)
 *     other  -> reads back 0x00
 * ===========================================================================
 */
module tt_um_wake_ctrl (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire        ena,
    input  wire        clk,
    input  wire        rst_n
);

    wire [3:0] thresh_in = ui_in[3:0];
    wire [3:0] ch_en     = ui_in[7:4];
    wire       mode_and  = uio_in[0];
    wire [4:0] reg_sel   = uio_in[5:1];

    wire        wake_out;
    wire [3:0]  evt_flags;
    wire [2:0]  priority_ch;
    wire [15:0] wake_count;
    wire [15:0] false_wake_cnt;
    wire [15:0] ch0_wcnt, ch1_wcnt, ch2_wcnt, ch3_wcnt;
    wire [23:0] hist_flat;
    wire [2:0]  hist_wptr;

    wake_ctrl #(
        .N  (4),
        .DB (8),
        .PW (4)
    ) u_wake_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .thresh_in      (thresh_in),
        .ch_en          (ch_en),
        .mode_and       (mode_and),
        .wake_out       (wake_out),
        .evt_flags      (evt_flags),
        .priority_ch    (priority_ch),
        .wake_count     (wake_count),
        .false_wake_cnt (false_wake_cnt),
        .ch0_wcnt       (ch0_wcnt),
        .ch1_wcnt       (ch1_wcnt),
        .ch2_wcnt       (ch2_wcnt),
        .ch3_wcnt       (ch3_wcnt),
        .hist_flat      (hist_flat),
        .hist_wptr      (hist_wptr)
    );

    reg [7:0] out_mux;
    always @(*) begin
        case (reg_sel)
            5'd0:  out_mux = {wake_out, priority_ch, evt_flags};
            5'd1:  out_mux = wake_count[7:0];
            5'd2:  out_mux = wake_count[15:8];
            5'd3:  out_mux = false_wake_cnt[7:0];
            5'd4:  out_mux = false_wake_cnt[15:8];
            5'd5:  out_mux = ch0_wcnt[7:0];
            5'd6:  out_mux = ch0_wcnt[15:8];
            5'd7:  out_mux = ch1_wcnt[7:0];
            5'd8:  out_mux = ch1_wcnt[15:8];
            5'd9:  out_mux = ch2_wcnt[7:0];
            5'd10: out_mux = ch2_wcnt[15:8];
            5'd11: out_mux = ch3_wcnt[7:0];
            5'd12: out_mux = ch3_wcnt[15:8];
            5'd13: out_mux = {5'b0, hist_flat[2:0]};
            5'd14: out_mux = {5'b0, hist_flat[5:3]};
            5'd15: out_mux = {5'b0, hist_flat[8:6]};
            5'd16: out_mux = {5'b0, hist_flat[11:9]};
            5'd17: out_mux = {5'b0, hist_flat[14:12]};
            5'd18: out_mux = {5'b0, hist_flat[17:15]};
            5'd19: out_mux = {5'b0, hist_flat[20:18]};
            5'd20: out_mux = {5'b0, hist_flat[23:21]};
            5'd21: out_mux = {5'b0, hist_wptr};
            default: out_mux = 8'h00;
        endcase
    end

    assign uo_out  = out_mux;
    assign uio_out = {7'b0, (ena & (&uio_in[7:6]) & 1'b0)};
    assign uio_oe  = 8'h00;

endmodule
