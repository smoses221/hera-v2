-module(hera_nav).

-behaviour(hera_measure).

-export([init/1, measure/1]).
-export([sample/1, calibrate_acc/0, calibrate_acc/1, calibrate_mag/1, calibrate_mag/2]).

%% hera_measure for the Pmod NAV (LSM9DS1 accelerometer, gyroscope and
%% magnetometer) on SPI2. It runs on the master board, next to the
%% Kalman filter.
%%
%% Start it with hera:start_measure(hera_nav, Opts). Each sample is
%%   [Ax, Ay, Az, Gx, Gy, Gz, Mx, My, Mz]
%% calibrated (nav_calib) and in SI units, in the sensor's body frame:
%%   acceleration in m/s^2 (specific force: includes gravity),
%%   angular rate in rad/s, magnetic field in uT.
%% Without `mag`, only the first six values are sent.
%%
%% Rotating these into the world frame and removing gravity needs an
%% orientation estimate, so it belongs to the fusion, not to the
%% measure.
%%
%% Calibration (see nav_calib):
%%   - Offline parameters are loaded from `calib_file` at start-up. Make
%%     them once with calibrate_acc/0,1 and calibrate_mag/1,2 from the
%%     shell (with this measure stopped), then copy the file into
%%     grisp/default/common/deploy/files/ so every deploy puts it back
%%     on the SD card (the deploy wipes the card first).
%%   - The gyroscope bias is measured at every start-up: keep the board
%%     still for the first `gyro_bias_samples` samples. If it moved
%%     (stddev above `still_dps`), the bias from the file is kept.
%%
%% Options (all optional):
%%   name              measure name                 (nav)
%%   period_ms         ms between samples           (10, i.e. ~100 Hz)
%%   iter              number of samples            (infinity)
%%   odr               LSM9DS1 output data rate     ({hz, 119})
%%   acc_fs, gyro_fs   full scales                  ({g, 4}, {dps, 500})
%%   mag               include the magnetometer     (true)
%%   calib_file        offline calibration          ("/nav_calib.term")
%%   gyro_bias_samples start-up gyro bias samples   (200)
%%   still_dps         max gyro stddev when still   (0.5)

-define(G, 9.80665).          % m/s^2 per g
-define(DEG, (math:pi() / 180)).
-define(UT_PER_GAUSS, 100.0).

-define(ACC_REGS, [out_x_xl, out_y_xl, out_z_xl, out_x_g, out_y_g, out_z_g]).
-define(MAG_REGS, [out_x_m, out_y_m, out_z_m]).

defaults() ->
    #{name => nav, period_ms => 10, iter => infinity,
      odr => {hz, 119}, acc_fs => {g, 4}, gyro_fs => {dps, 500},
      mag => true, calib_file => "/nav_calib.term",
      gyro_bias_samples => 200, still_dps => 0.5}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% hera_measure callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Opts) ->
    Cfg = maps:merge(defaults(), Opts),
    ok = setup(Cfg),
    Calib0 = load_calib(maps:get(calib_file, Cfg)),
    Calib = startup_gyro_bias(Calib0, Cfg),
    #{name := Name, period_ms := Period, iter := Iter, mag := Mag} = Cfg,
    {ok, #{calib => Calib, mag => Mag},
     #{name => Name, iter => Iter, timeout => Period}}.

measure(State = #{calib := Calib, mag := WithMag}) ->
    {Acc, Gyro, Mag} = nav_calib:apply(Calib, read_raw(WithMag)),
    {Ax, Ay, Az} = scale(Acc, ?G),
    {Gx, Gy, Gz} = scale(Gyro, ?DEG),
    Values = case WithMag of
        true ->
            {Mx, My, Mz} = scale(Mag, ?UT_PER_GAUSS),
            [Ax, Ay, Az, Gx, Gy, Gz, Mx, My, Mz];
        false ->
            [Ax, Ay, Az, Gx, Gy, Gz]
    end,
    {ok, Values, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Offline calibration, from the shell
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% N raw samples {Acc, Gyro, Mag} (g, dps, gauss), uncalibrated.
sample(N) ->
    ok = setup(defaults()),
    [begin timer:sleep(10), read_raw(true) end || _ <- lists:seq(1, N)].

%% Six-position accelerometer calibration: prompts for each axis up and
%% down, averages 200 samples per position, and saves the result into
%% File (merged with what it already holds).
calibrate_acc() ->
    calibrate_acc(maps:get(calib_file, defaults())).

calibrate_acc(File) ->
    Means = maps:from_list(
        [begin
             _ = io:get_line(io_lib:format("Board still, ~p axis pointing ~p, then Enter: ", [A, D])),
             {{A, D}, nav_calib:mean([Acc || {Acc, _, _} <- sample(200)])}
         end || A <- [x, y, z], D <- [up, down]]),
    store(File, nav_calib:acc_six_position(Means)).

%% Magnetometer hard/soft iron: samples for Seconds while the board is
%% rotated slowly through all orientations, and saves the result.
calibrate_mag(Seconds) ->
    calibrate_mag(Seconds, maps:get(calib_file, defaults())).

calibrate_mag(Seconds, File) ->
    io:format("Rotate the board slowly in all directions for ~p s...~n", [Seconds]),
    Samples = [Mag || {_, _, Mag} <- sample(Seconds * 100)],
    store(File, nav_calib:mag_hard_soft(Samples)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Starts the pmod_nav driver on SPI2 if needed, and sets rates and
%% full scales. On the LSM9DS1, with the gyroscope on, the
%% accelerometer runs at the gyroscope's rate (odr_g).
setup(#{odr := Odr, acc_fs := AccFs, gyro_fs := GyroFs}) ->
    try grisp_devices:default(pmod_nav)
    catch error:{no_device_present, pmod_nav} -> grisp:add_device(spi2, pmod_nav)
    end,
    ok = pmod_nav:config(acc, #{odr_g => Odr, fs_g => GyroFs, fs_xl => AccFs}),
    ok = pmod_nav:config(mag, #{do => {hz, 80}}).

read_raw(WithMag) ->
    [Ax, Ay, Az, Gx, Gy, Gz] = pmod_nav:read(acc, ?ACC_REGS),
    Mag = case WithMag of
        true -> list_to_tuple(pmod_nav:read(mag, ?MAG_REGS));
        false -> {0.0, 0.0, 0.0}
    end,
    {{Ax, Ay, Az}, {Gx, Gy, Gz}, Mag}.

load_calib(File) ->
    case nav_calib:load(File) of
        {ok, Calib} ->
            Calib;
        {error, Reason} ->
            logger:warning("hera_nav: no calibration from ~s (~p), using none", [File, Reason]),
            nav_calib:default()
    end.

startup_gyro_bias(Calib, #{gyro_bias_samples := N, still_dps := Still}) ->
    Gyro = [G || {_, G, _} <- [begin timer:sleep(10), read_raw(false) end
                                || _ <- lists:seq(1, N)]],
    {Sx, Sy, Sz} = nav_calib:stddev(Gyro),
    case lists:max([Sx, Sy, Sz]) =< Still of
        true ->
            Calib#{gyro_bias := nav_calib:gyro_bias(Gyro)};
        false ->
            logger:warning("hera_nav: board moved during gyro bias (stddev ~p dps), "
                           "keeping the stored bias", [{Sx, Sy, Sz}]),
            Calib
    end.

store(File, Params) ->
    Old = case file:consult(File) of
        {ok, [M]} when is_map(M) -> M;
        _ -> #{}
    end,
    New = maps:merge(Old, Params),
    ok = nav_calib:save(File, New),
    New.

scale({X, Y, Z}, K) -> {X * K, Y * K, Z * K}.
