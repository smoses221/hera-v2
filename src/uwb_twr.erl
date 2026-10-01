-module(uwb_twr).

-behaviour(gen_statem).

-export([start_tag/1, start_anchor/1, start/1, start_link/1, stop/0]).
-export([range/2, stats/0]).
-export([rx_callback/4]).
-export([distance/2]).
-export([init/1, callback_mode/0, terminate/3]).
-export([idle/3, wait_report/3, wait_final/3]).

%% Double-sided two-way ranging (DS-TWR, 3 messages + report) on the
%% DW1000 (Pmod UWB) and the IEEE 802.15.4 stack copied from
%% GwendalLaurent/pmod_uwb (src/pmod_uwb/). The exchange is the one of
%% upstream's ranging/double_sided_3_msg.erl:
%%
%%   tag (initiator)                       anchor (responder)
%%   POLL  (ack requested, ranging) ----->   PollRx
%%   RespRx  <----- ACK (sent by the DW1000) RespTx
%%   FINAL (ranging) -------------------->   FinalRx
%%   <------------------------------------ REPORT(PollRx, RespTx, FinalRx)
%%   distance from PollTx, RespRx, FinalTx + the report
%%
%% Differences from upstream (see REDESIGN_LOG.md):
%%   - range(Anchor, Timeout) ranges to any anchor address and returns
%%     the distance, or {error, Reason} after Timeout instead of hanging
%%     in wait_report when a frame is lost.
%%   - distance/2 uses the standard asymmetric DS-TWR formula
%%     (Tround1*Tround2 - Treply1*Treply2) / sum; upstream multiplies
%%     Treply1 by Tround2, which roughly halves the distance.
%%   - Timestamps are 40-bit DW1000 counters that wrap every ~17.2 s;
%%     intervals are taken modulo 2^40.
%%   - One process plays both roles: a tag calls range/2, an anchor
%%     only answers POLLs. stats/0 counts results, for the thesis.

-include("pmod_uwb/mac_frame.hrl").
-include("pmod_uwb/ieee802154.hrl").

-define(TU, 15.65e-12).                % s per DW1000 time unit
-define(C, 299792458.0).               % m/s
-define(TS_MASK, 16#FFFFFFFFFF).       % 40-bit timestamps
-define(FINAL_TIMEOUT, 1000).          % ms an anchor waits for FINAL

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Starts the radio and the ranging process on a tag or an anchor.
%% Opts:
%%   short_addr  this node's 16-bit address (integer)      required
%%   pan_id      16-bit PAN id                             (16#CAFE)
%%   tx_antd, rx_antd  antenna delays, in DW1000 time units (16450)
%%   phy         PHY module                                (pmod_uwb)
%% The antenna delays are a per-board calibration (see hera_uwb).
%% start_tag/1 and start_anchor/1 don't link the caller (e.g. a shell or
%% a hera_measure that may restart); start_link/1 is for a supervisor.
start_tag(Opts) -> start(Opts).
start_anchor(Opts) -> start(Opts).

start(Opts) ->
    ok = setup_radio(Opts),
    gen_statem:start({local, ?MODULE}, ?MODULE, Opts, []).

start_link(Opts) ->
    ok = setup_radio(Opts),
    gen_statem:start_link({local, ?MODULE}, ?MODULE, Opts, []).

stop() ->
    gen_statem:stop(?MODULE).

%% Ranges to the anchor at short address Anchor (integer). Returns the
%% distance in metres, uncorrected (see hera_uwb for the per-anchor
%% correction), or an error if no answer within Timeout ms.
-spec range(Anchor :: 0..16#FFFF, Timeout :: pos_integer()) ->
    {ok, float()} | {error, term()}.
range(Anchor, Timeout) ->
    gen_statem:call(?MODULE, {range, <<Anchor:16>>, Timeout}, Timeout + 5000).

%% Counters since start: ranges ok, timeouts, transmission errors,
%% reports answered (as an anchor).
stats() ->
    gen_statem:call(?MODULE, stats).

%% Input callback of the IEEE 802.15.4 stack (runs in its event
%% process): forward every received frame to the ranging process.
rx_callback(Frame, _LQI, _Security, Ranging) ->
    gen_statem:cast(?MODULE, {rx, Frame, Ranging}).

%% DS-TWR distance in metres from the tag's {PollTx, RespRx, FinalTx}
%% and the anchor's {PollRx, RespTx, FinalRx} timestamps (DW1000 time
%% units, each on its own clock). Asymmetric formula, which cancels the
%% clock offset and, to first order, the clock drift:
%%   Tprop = (Tround1 * Tround2 - Treply1 * Treply2)
%%         / (Tround1 + Tround2 + Treply1 + Treply2)
-spec distance({integer(), integer(), integer()}, {integer(), integer(), integer()}) ->
    {ok, float()} | {error, bad_timestamps}.
distance({PollTx, RespRx, FinalTx}, {PollRx, RespTx, FinalRx}) ->
    TRound1 = interval(PollTx, RespRx),   % tag:    POLL out -> ACK in
    TReply1 = interval(PollRx, RespTx),   % anchor: POLL in  -> ACK out
    TRound2 = interval(RespTx, FinalRx),  % anchor: ACK out  -> FINAL in
    TReply2 = interval(RespRx, FinalTx),  % tag:    ACK in   -> FINAL out
    Sum = TRound1 + TRound2 + TReply1 + TReply2,
    case Sum > 0 of
        true ->
            TProp = (TRound1 * TRound2 - TReply1 * TReply2) / Sum,
            {ok, TProp * ?TU * ?C};
        false ->
            {error, bad_timestamps}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% gen_statem callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Opts) ->
    Data = #{addr => <<(maps:get(short_addr, Opts)):16>>,
             pan => <<(maps:get(pan_id, Opts, 16#CAFE)):16>>,
             seq => 0,
             stats => #{ok => 0, timeout => 0, tx_error => 0, bad_timestamps => 0,
                        reports => 0}},
    {ok, idle, Data}.

callback_mode() ->
    state_functions.

terminate(_Reason, _State, _Data) ->
    ok.

%% Tag: start a range. The POLL and FINAL transmissions block until
%% sent (each also sleeps ~100 ms in ieee802154, see REDESIGN_LOG.md);
%% a REPORT arriving meanwhile waits in the mailbox for wait_report.
idle({call, From}, {range, Anchor, Timeout}, Data) ->
    case poll_final(Anchor, Data) of
        {ok, TagTs, Data1} ->
            {next_state, wait_report,
             Data1#{from => From, anchor => Anchor, tag_ts => TagTs},
             [{state_timeout, Timeout, no_report}]};
        {error, Reason, Data1} ->
            {keep_state, count(tx_error, Data1), [{reply, From, {error, Reason}}]}
    end;
%% Anchor: a POLL starts an exchange.
idle(cast, {rx, {_, #mac_header{src_addr = Tag}, <<"POLL">>},
            #ranging_informations{ranging_received = ?RANGING_ACTIVE,
                                  ranging_counter_start = PollRx,
                                  ranging_counter_stop = RespTx}}, Data) ->
    {next_state, wait_final, Data#{tag => Tag, anchor_ts => {PollRx, RespTx}},
     [{state_timeout, ?FINAL_TIMEOUT, no_final}]};
idle(EventType, Event, Data) ->
    common(EventType, Event, Data).

wait_report(cast, {rx, {_, #mac_header{src_addr = Anchor},
                        <<"REPORT", PollRx:40, RespTx:40, FinalRx:40>>}, _},
            Data = #{anchor := Anchor, tag_ts := TagTs, from := From}) ->
    case distance(TagTs, {PollRx, RespTx, FinalRx}) of
        {ok, D} ->
            {next_state, idle, done(count(ok, Data)), [{reply, From, {ok, D}}]};
        {error, Reason} ->
            {next_state, idle, done(count(Reason, Data)), [{reply, From, {error, Reason}}]}
    end;
wait_report(state_timeout, no_report, Data = #{from := From}) ->
    {next_state, idle, done(count(timeout, Data)), [{reply, From, {error, timeout}}]};
wait_report({call, _}, {range, _, _}, _Data) ->
    {keep_state_and_data, [postpone]};
wait_report(EventType, Event, Data) ->
    common(EventType, Event, Data).

%% Anchor: FINAL from the same tag completes the exchange.
wait_final(cast, {rx, {_, #mac_header{src_addr = Tag}, <<"FINAL">>},
                  #ranging_informations{ranging_received = ?RANGING_ACTIVE,
                                        ranging_counter_start = FinalRx}},
           Data = #{tag := Tag, anchor_ts := {PollRx, RespTx}}) ->
    Report = <<"REPORT", PollRx:40, RespTx:40, FinalRx:40>>,
    {Frame, Data1} = frame(Tag, ?DISABLED, Report, Data),
    _ = ieee802154:transmission(Frame),
    {next_state, idle, count(reports, maps:without([tag, anchor_ts], Data1))};
%% A new POLL (the previous FINAL was lost): restart from idle.
wait_final(cast, {rx, {_, _, <<"POLL">>}, _}, Data) ->
    {next_state, idle, maps:without([tag, anchor_ts], Data), [postpone]};
wait_final(state_timeout, no_final, Data) ->
    {next_state, idle, maps:without([tag, anchor_ts], Data)};
wait_final(EventType, Event, Data) ->
    common(EventType, Event, Data).

%% In any state: stats, and other frames are ignored.
common({call, From}, stats, #{stats := Stats}) ->
    {keep_state_and_data, [{reply, From, Stats}]};
common({call, From}, {range, _, _}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, busy}}]};
common(cast, {rx, _, _}, _Data) ->
    keep_state_and_data.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Starts the PHY (unless already there), the IEEE 802.15.4 stack with
%% our rx callback, sets the addresses and turns reception on.
setup_radio(Opts) ->
    Phy = maps:get(phy, Opts, pmod_uwb),
    case Phy of
        pmod_uwb ->
            try grisp_devices:default(pmod_uwb)
            catch error:{no_device_present, pmod_uwb} -> grisp:add_device(spi2, pmod_uwb)
            end,
            pmod_uwb:write(tx_antd, #{tx_antd => maps:get(tx_antd, Opts, 16450)}),
            pmod_uwb:write(lde_if, #{lde_rxantd => maps:get(rx_antd, Opts, 16450)});
        _ ->
            ok
    end,
    case whereis(ieee802154) of
        undefined ->
            {ok, _} = ieee802154:start(#ieee_parameters{phy_layer = Phy,
                                                        duty_cycle = duty_cycle_non_beacon,
                                                        input_callback = fun ?MODULE:rx_callback/4});
        _ ->
            ok
    end,
    ok = ieee802154:set_pib_attribute(mac_pan_id, <<(maps:get(pan_id, Opts, 16#CAFE)):16>>),
    ok = ieee802154:set_pib_attribute(mac_short_address, <<(maps:get(short_addr, Opts)):16>>),
    case ieee802154:rx_on() of
        ok -> ok;
        {error, rx_already_on} -> ok
    end.

%% POLL (ack requested) then FINAL, both with ranging; returns the tag's
%% timestamps {PollTx, RespRx, FinalTx}.
poll_final(Anchor, Data) ->
    {Poll, Data1} = frame(Anchor, ?ENABLED, <<"POLL">>, Data),
    case ieee802154:transmission(Poll, ?ALL_RANGING) of
        {ok, #ranging_informations{ranging_received = true,
                                   ranging_counter_start = PollTx,
                                   ranging_counter_stop = RespRx}} ->
            {Final, Data2} = frame(Anchor, ?DISABLED, <<"FINAL">>, Data1),
            case ieee802154:transmission(Final, ?ALL_RANGING) of
                {ok, #ranging_informations{ranging_counter_start = FinalTx}} ->
                    {ok, {PollTx, RespRx, FinalTx}, Data2};
                {error, Reason} ->
                    {error, {final, Reason}, Data2}
            end;
        {ok, _} ->
            {error, no_ranging, Data1};
        {error, Reason} ->
            {error, {poll, Reason}, Data1}
    end.

frame(Dest, AckReq, Payload, Data = #{addr := Addr, pan := Pan, seq := Seq}) ->
    FC = #frame_control{ack_req = AckReq,
                        src_addr_mode = ?SHORT_ADDR,
                        dest_addr_mode = ?SHORT_ADDR},
    MH = #mac_header{seqnum = Seq, src_pan = Pan, src_addr = Addr,
                     dest_pan = Pan, dest_addr = Dest},
    {{FC, MH, Payload}, Data#{seq := (Seq + 1) rem 256}}.

%% Interval from A to B on a 40-bit wrapping counter.
interval(A, B) ->
    (B - A) band ?TS_MASK.

done(Data) ->
    maps:without([from, anchor, tag_ts], Data).

count(Key, Data = #{stats := Stats}) ->
    Data#{stats := maps:update_with(Key, fun(N) -> N + 1 end, 1, Stats)}.
