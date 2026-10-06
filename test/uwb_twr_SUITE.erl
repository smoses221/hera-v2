-module(uwb_twr_SUITE).

%% Host test of the DS-TWR protocol in uwb_twr: a tag and an anchor,
%% each an Erlang node running the copied IEEE 802.15.4 stack and
%% uwb_twr, exchange real frames over upstream pmod_uwb's simulated UWB
%% network (mock_phy_network + network_simulation, copied into test/).
%%
%% The mock's timestamp registers are always 0, so a complete exchange
%% ends in {error, bad_timestamps} instead of a distance: what's tested
%% here is the protocol (POLL, ACK, FINAL, REPORT from the right anchor,
%% timeouts), not the distance maths, which uwb_twr_tests covers.
%%
%% Run with: rebar3 ct --sname=test --suite=test/uwb_twr_SUITE

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([exchange_completes/1, unknown_anchor/1, two_anchors/1]).

-define(TAG, 16#0001).
-define(ANCHOR1, 16#0002).
-define(ANCHOR2, 16#0003).

all() -> [exchange_completes, unknown_anchor, two_anchors].

init_per_suite(Config) ->
    {Peer, Net} = boot(network),
    ok = erpc:call(Net, application, ensure_started, [common_test]),
    {ok, _} = erpc:call(Net, network_simulation, start, [{}, #{}]),
    [{net, Net}, {net_peer, Peer} | Config].

end_per_suite(Config) ->
    peer:stop(?config(net_peer, Config)).

init_per_testcase(two_anchors, Config) ->
    Net = ?config(net, Config),
    Nodes = [radio(tag, ?TAG, Net), radio(anchor1, ?ANCHOR1, Net), radio(anchor2, ?ANCHOR2, Net)],
    [{nodes, Nodes} | Config];
init_per_testcase(_, Config) ->
    Net = ?config(net, Config),
    Nodes = [radio(tag, ?TAG, Net), radio(anchor1, ?ANCHOR1, Net)],
    [{nodes, Nodes} | Config].

end_per_testcase(_, Config) ->
    [peer:stop(Peer) || {_, Peer, _} <- ?config(nodes, Config)],
    ok.

%% Tag ranges to the anchor: the anchor answers with a REPORT, the tag
%% parses it (bad_timestamps only because the mock clocks are 0).
exchange_completes(Config) ->
    Tag = node_of(tag, Config),
    Anchor = node_of(anchor1, Config),
    ?assertEqual({error, bad_timestamps}, erpc:call(Tag, uwb_twr, range, [?ANCHOR1, 2000])),
    ?assertMatch(#{bad_timestamps := 1, timeout := 0}, erpc:call(Tag, uwb_twr, stats, [])),
    ?assertMatch(#{reports := 1}, erpc:call(Anchor, uwb_twr, stats, [])).

%% Nobody at that address: the POLL is never acknowledged.
unknown_anchor(Config) ->
    Tag = node_of(tag, Config),
    ?assertEqual({error, {poll, no_ack}}, erpc:call(Tag, uwb_twr, range, [16#0009, 2000])),
    ?assertMatch(#{reports := 0}, erpc:call(node_of(anchor1, Config), uwb_twr, stats, [])).

%% Round-robin over two anchors: each answers only the exchanges
%% addressed to it.
two_anchors(Config) ->
    Tag = node_of(tag, Config),
    [?assertEqual({error, bad_timestamps}, erpc:call(Tag, uwb_twr, range, [A, 2000]))
     || A <- [?ANCHOR1, ?ANCHOR2, ?ANCHOR1]],
    ?assertMatch(#{reports := 2}, erpc:call(node_of(anchor1, Config), uwb_twr, stats, [])),
    ?assertMatch(#{reports := 1}, erpc:call(node_of(anchor2, Config), uwb_twr, stats, [])).

%% Helpers

%% A node with the mock PHY on the simulated network, running uwb_twr.
radio(Name, Addr, Net) ->
    {Peer, Node} = boot(Name),
    ok = erpc:call(Node, application, ensure_started, [common_test]),
    {ok, _} = erpc:call(Node, mock_phy_network, start, [spi2, #{network => Net}]),
    {ok, _} = erpc:call(Node, uwb_twr, start, [#{short_addr => Addr, phy => mock_phy_network}]),
    {Name, Peer, Node}.

boot(Name) ->
    Paths = lists:usort([filename:dirname(code:which(M))
                         || M <- [uwb_twr, ieee802154, mock_phy_network]]),
    {ok, Peer, Node} = ?CT_PEER(#{name => Name, args => ["-pa" | Paths]}),
    unlink(Peer),
    {Peer, Node}.

node_of(Name, Config) ->
    {Name, _, Node} = lists:keyfind(Name, 1, ?config(nodes, Config)),
    Node.
