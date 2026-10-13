-module(nav_calib_tests).

-include_lib("eunit/include/eunit.hrl").

%% Host tests for the Pmod NAV calibration maths: each estimator is fed
%% readings from a simulated sensor with known errors and must recover
%% them, and apply/2 must then undo them.

-define(TOL, 1.0e-9).

default_is_identity_test() ->
    Sample = {{0.1, -0.2, 1.0}, {1.5, -2.0, 0.3}, {0.2, 0.3, -0.4}},
    ?assertEqual(Sample, nav_calib:apply(nav_calib:default(), Sample)).

gyro_bias_test() ->
    Bias = {0.8, -1.2, 0.3},
    Samples = [add(Bias, N) || N <- [{0.1, 0.0, -0.1}, {-0.1, 0.0, 0.1}, {0.0, 0.2, 0.0}, {0.0, -0.2, 0.0}]],
    assert_vec(Bias, nav_calib:gyro_bias(Samples)).

%% Sensor reading = true / scale + bias, i.e. apply/2 inverts it.
acc_six_position_test() ->
    Bias = {0.02, -0.03, 0.05},
    Scale = {1.01, 0.98, 1.02},
    Read = fun(True) -> add(divv(True, Scale), Bias) end,
    Means = #{{x, up} => Read({1.0, 0.0, 0.0}), {x, down} => Read({-1.0, 0.0, 0.0}),
              {y, up} => Read({0.0, 1.0, 0.0}), {y, down} => Read({0.0, -1.0, 0.0}),
              {z, up} => Read({0.0, 0.0, 1.0}), {z, down} => Read({0.0, 0.0, -1.0})},
    #{acc_bias := B, acc_scale := S} = nav_calib:acc_six_position(Means),
    assert_vec(Bias, B),
    assert_vec(Scale, S),
    Calib = maps:merge(nav_calib:default(), #{acc_bias => B, acc_scale => S}),
    {Acc, _, _} = nav_calib:apply(Calib, {Read({0.0, 0.0, 1.0}), {0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}}),
    assert_vec({0.0, 0.0, 1.0}, Acc).

%% Points on an axis-aligned ellipsoid (radii Rs, centre Bias) must map
%% back onto a sphere of the mean radius.
mag_hard_soft_test() ->
    Bias = {0.15, -0.05, 0.2},
    Rs = {0.5, 0.4, 0.6},
    Dirs = [{1.0, 0.0, 0.0}, {-1.0, 0.0, 0.0}, {0.0, 1.0, 0.0},
            {0.0, -1.0, 0.0}, {0.0, 0.0, 1.0}, {0.0, 0.0, -1.0}],
    Samples = [add(mulv(D, Rs), Bias) || D <- Dirs],
    #{mag_bias := B, mag_scale := S} = nav_calib:mag_hard_soft(Samples),
    assert_vec(Bias, B),
    Calib = maps:merge(nav_calib:default(), #{mag_bias => B, mag_scale => S}),
    R = 0.5,
    [begin
         {_, _, M} = nav_calib:apply(Calib, {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, Sample}),
         ?assert(abs(norm(M) - R) < ?TOL)
     end || Sample <- Samples].

mag_axes_test() ->
    Calib = maps:merge(nav_calib:default(), #{mag_axes => {-1, 3, 2}}),
    {_, _, M} = nav_calib:apply(Calib, {{0.0, 0.0, 0.0}, {0.0, 0.0, 0.0}, {1.0, 2.0, 3.0}}),
    ?assertEqual({-1.0, 3.0, 2.0}, M).

save_load_test() ->
    File = filename:join(test_dir(), "nav_calib_test.term"),
    Partial = #{gyro_bias => {0.1, 0.2, 0.3}},
    ok = nav_calib:save(File, Partial),
    {ok, Loaded} = nav_calib:load(File),
    ?assertEqual(maps:merge(nav_calib:default(), Partial), Loaded),
    ok = file:delete(File).

stddev_test() ->
    assert_vec({1.0, 0.0, 2.0}, nav_calib:stddev([{1.0, 5.0, 2.0}, {-1.0, 5.0, -2.0}])).

%% Helpers

test_dir() ->
    {ok, Cwd} = file:get_cwd(),
    Cwd.

add({A, B, C}, {X, Y, Z}) -> {A + X, B + Y, C + Z}.
mulv({A, B, C}, {X, Y, Z}) -> {A * X, B * Y, C * Z}.
divv({A, B, C}, {X, Y, Z}) -> {A / X, B / Y, C / Z}.
norm({A, B, C}) -> math:sqrt(A * A + B * B + C * C).

assert_vec({EA, EB, EC}, {A, B, C}) ->
    ?assert(abs(EA - A) < ?TOL),
    ?assert(abs(EB - B) < ?TOL),
    ?assert(abs(EC - C) < ?TOL).
