-module(uwb_twr_tests).

-include_lib("eunit/include/eunit.hrl").

%% Host tests of the DS-TWR distance computation. Each test simulates
%% one exchange in true time, then reads every event on the clock of the
%% board that timestamps it: 40-bit DW1000 counters with their own
%% offset and drift (ppm), as on real hardware.

-define(TU, 15.65e-12).
-define(C, 299792458.0).
-define(WRAP, (1 bsl 40)).

%% Exact apart from rounding to whole time units (~4.7 mm each).
no_drift_test() ->
    assert_near(5.0, 0.02, exchange(5.0, #{})).

%% Different crystal errors on both boards, asymmetric reply delays:
%% the asymmetric formula keeps the error at the millimetre level.
drift_and_asymmetric_replies_test() ->
    Opts = #{tag_ppm => 20, anchor_ppm => -20, reply1 => 0.4e-3, reply2 => 2.0e-3},
    [assert_near(D, 0.02, exchange(D, Opts)) || D <- [0.5, 3.0, 12.0, 40.0]].

%% Both counters wrap during the exchange.
wrap_around_test() ->
    Opts = #{tag_offset => ?WRAP - 1000, anchor_offset => ?WRAP - 50000,
             tag_ppm => 10, anchor_ppm => -5},
    assert_near(7.5, 0.02, exchange(7.5, Opts)).

zero_intervals_test() ->
    ?assertEqual({error, bad_timestamps}, uwb_twr:distance({0, 0, 0}, {0, 0, 0})).

%% The formula in upstream pmod_uwb (ranging/double_sided_3_msg.erl,
%% Treply1 * Tround2 instead of Treply1 * Treply2) on the same
%% exchange: it returns about Tprop * Treply2 / (Treply1 + Treply2),
%% here half the distance. Kept as a record of why it was replaced.
upstream_formula_is_biased_test() ->
    {TagTs, AnchorTs} = timestamps(10.0, #{}),
    {PollTx, RespRx, FinalTx} = TagTs,
    {PollRx, RespTx, FinalRx} = AnchorTs,
    TRound1 = RespRx - PollTx,
    TReply1 = RespTx - PollRx,
    TRound2 = FinalRx - RespTx,
    TReply2 = FinalTx - RespRx,
    Upstream = (TRound1 * TRound2 - TReply1 * TRound2)
               / (TRound1 + TRound2 + TReply1 + TReply2) * ?TU * ?C,
    assert_near(5.0, 0.05, {ok, Upstream}).

%% Helpers

exchange(Distance, Opts) ->
    {TagTs, AnchorTs} = timestamps(Distance, Opts),
    uwb_twr:distance(TagTs, AnchorTs).

%% True-time events of one exchange, read on each board's clock.
timestamps(Distance, Opts) ->
    Tof = Distance / ?C,
    Reply1 = maps:get(reply1, Opts, 1.0e-3),   % anchor: POLL in -> ACK out
    Reply2 = maps:get(reply2, Opts, 1.0e-3),   % tag: ACK in -> FINAL out
    T0 = 0.001,
    PollRxT = T0 + Tof,
    RespTxT = PollRxT + Reply1,
    RespRxT = RespTxT + Tof,
    FinalTxT = RespRxT + Reply2,
    FinalRxT = FinalTxT + Tof,
    Tag = clock(maps:get(tag_offset, Opts, 123456), maps:get(tag_ppm, Opts, 0)),
    Anchor = clock(maps:get(anchor_offset, Opts, 987654321), maps:get(anchor_ppm, Opts, 0)),
    {{Tag(T0), Tag(RespRxT), Tag(FinalTxT)},
     {Anchor(PollRxT), Anchor(RespTxT), Anchor(FinalRxT)}}.

clock(Offset, Ppm) ->
    fun(T) -> (Offset + round(T * (1 + Ppm * 1.0e-6) / ?TU)) rem ?WRAP end.

assert_near(Expected, Tol, {ok, D}) ->
    ?assert(abs(D - Expected) =< Tol).
