-module(hera_uwb).

-behaviour(hera_measure).

-export([init/1, measure/1]).
-export([start_anchor/1]).
-export([calibrate_range/3]).

%% hera_measure for the Pmod UWB on the UWB board (the tag): ranges to
%% the anchors in turn with DS-TWR (uwb_twr) and sends each range to the
%% master board, which runs the Kalman filter.
%%
%% Start it with hera:start_measure(hera_uwb, Opts). Each sample is
%%   [AnchorIndex, Range]
%% with Range the corrected distance in metres to anchor AnchorIndex.
%% The anchor positions are not sent: they are part of the filter's
%% measurement model on the master, which looks them up by index.
%% A failed range (timeout, lost frame) produces no sample.
%%
%% Each anchor is another GRiSP2 board with a Pmod UWB, running only the
%% responder: hera_uwb:start_anchor(#{short_addr => 16#0002}) from its
%% shell (later: from its configuration).
%%
%% Calibration (at the source, as for hera_nav):
%%   - Antenna delays (tx_antd, rx_antd): DW1000 registers, one pair per
%%     board, set when the radio starts. They shift every range by a
%%     constant and are the main UWB calibration. The default 16450 is
%%     upstream's value, not measured for these boards.
%%   - A residual linear correction per anchor, Range = Scale * Raw +
%%     Bias, from calibrate_range/3 at known distances.
%%
%% Options (all optional):
%%   name        measure name                               (uwb)
%%   period_ms   pause between two ranges, ms               (100)
%%   iter        number of samples                          (infinity)
%%   short_addr  this tag's address                         (16#0001)
%%   pan_id      PAN id                                     (16#CAFE)
%%   tx_antd, rx_antd  this board's antenna delays          (16450)
%%   anchors     [{Index, ShortAddr}]          ([{1, 16#0002}, {2, 16#0003}])
%%   correction  #{Index => {Scale, Bias}}                  (none)
%%   timeout_ms  max wait for an anchor's report, ms        (500)
%%
%% Conservative baseline: one range per period, anchors round-robin.
%% Each range costs at least ~300 ms (three frames, each followed by a
%% 100 ms sleep in the copied ieee802154 stack), see REDESIGN_LOG.md.

defaults() ->
    #{name => uwb, period_ms => 100, iter => infinity,
      short_addr => 16#0001, pan_id => 16#CAFE,
      anchors => [{1, 16#0002}, {2, 16#0003}],
      correction => #{}, timeout_ms => 500}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% hera_measure callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Opts) ->
    Cfg = maps:merge(defaults(), Opts),
    ok = ensure_twr(Cfg),
    #{name := Name, period_ms := Period, iter := Iter, anchors := Anchors} = Cfg,
    {ok, #{anchors => Anchors, next => Anchors,
           correction => maps:get(correction, Cfg),
           timeout => maps:get(timeout_ms, Cfg)},
     #{name => Name, iter => Iter, timeout => Period}}.

measure(State = #{anchors := Anchors, next := []}) ->
    measure(State#{next := Anchors});
measure(State = #{next := [{Index, Addr} | Rest], timeout := Timeout}) ->
    NewState = State#{next := Rest},
    case uwb_twr:range(Addr, Timeout) of
        {ok, Raw} ->
            {ok, [Index, correct(Index, Raw, State)], NewState};
        {error, _} ->
            {undefined, NewState}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Anchors and calibration, from the shell
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% On an anchor board: starts the radio and answers every tag's POLL.
%% Opts as uwb_twr:start_link/1, e.g. #{short_addr => 16#0002}.
start_anchor(Opts) ->
    uwb_twr:start_anchor(Opts).

%% On the tag, with the measure stopped: N ranges to the anchor at
%% Addr, placed at TrueDistance metres. Returns the statistics and the
%% bias to use in `correction` (Scale 1.0). Repeat at a few distances
%% and fit Scale too if the error grows with distance.
calibrate_range(Addr, TrueDistance, N) ->
    ok = ensure_twr(defaults()),
    Results = [uwb_twr:range(Addr, 500) || _ <- lists:seq(1, N)],
    Ranges = [D || {ok, D} <- Results],
    case Ranges of
        [] ->
            {error, no_ranges};
        _ ->
            Mean = lists:sum(Ranges) / length(Ranges),
            Var = lists:sum([(D - Mean) * (D - Mean) || D <- Ranges]) / length(Ranges),
            #{n => N, ok => length(Ranges), mean => Mean, stddev => math:sqrt(Var),
              bias => TrueDistance - Mean}
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Starts the radio and uwb_twr once; a restarted measure reuses them.
ensure_twr(Cfg) ->
    case whereis(uwb_twr) of
        undefined ->
            {ok, _} = uwb_twr:start_tag(maps:with([short_addr, pan_id, tx_antd, rx_antd, phy], Cfg)),
            ok;
        _ ->
            ok
    end.

correct(Index, Raw, #{correction := Correction}) ->
    {Scale, Bias} = maps:get(Index, Correction, {1.0, 0.0}),
    Scale * Raw + Bias.
