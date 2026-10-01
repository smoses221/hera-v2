-module(nav_calib).

-export([default/0, load/1, save/2]).
-export([apply/2]).
-export([mean/1, stddev/1]).
-export([gyro_bias/1, acc_six_position/1, mag_hard_soft/1]).

%% Calibration of the Pmod NAV (LSM9DS1) readings, as pure functions so
%% they can be tested on the host. hera_nav uses them to correct every
%% sample before it leaves the measure, so consumers (the Kalman filter)
%% only ever see calibrated values.
%%
%% Model, per axis i, in sensor units (g, dps, gauss), then the axis map:
%%   acc_i  = (raw_i - acc_bias_i)  * acc_scale_i
%%   gyro_i =  raw_i - gyro_bias_i
%%   mag_i  = (raw_i - mag_bias_i)  * mag_scale_i
%% Scales are diagonal (no cross-axis / misalignment terms). That's the
%% usual first step; a full 3x3 matrix is a possible later refinement.
%%
%% Where each parameter comes from:
%%   - gyro_bias: measured at every start-up while the board is still
%%     (it drifts with temperature), see gyro_bias/1 and hera_nav.
%%   - acc_bias/acc_scale: six-position calibration, done once from the
%%     shell, see acc_six_position/1.
%%   - mag_bias/mag_scale: hard/soft iron, done once by rotating the
%%     board through all orientations, see mag_hard_soft/1.
%% Offline results are stored on the SD card with save/2 and read back
%% by hera_nav with load/1.
%%
%% mag_axes maps the magnetometer axes onto the accelerometer/gyroscope
%% frame as a signed permutation, e.g. {-1, 2, 3} flips X. The LSM9DS1's
%% magnetometer axes are not aligned with its accelerometer/gyroscope
%% axes (datasheet, pin description figure); the default is the
%% identity until that is checked on the board.

-type vec3() :: {float(), float(), float()}.
-type axis() :: -3..3.
-type calib() :: #{acc_bias := vec3(), acc_scale := vec3(),
                   gyro_bias := vec3(),
                   mag_bias := vec3(), mag_scale := vec3(),
                   mag_axes := {axis(), axis(), axis()}}.

-export_type([vec3/0, calib/0]).

%% No correction.
-spec default() -> calib().
default() ->
    #{acc_bias => {0.0, 0.0, 0.0}, acc_scale => {1.0, 1.0, 1.0},
      gyro_bias => {0.0, 0.0, 0.0},
      mag_bias => {0.0, 0.0, 0.0}, mag_scale => {1.0, 1.0, 1.0},
      mag_axes => {1, 2, 3}}.

%% Reads a calibration saved by save/2. Missing keys keep their default,
%% so a file can hold only, e.g., the accelerometer part.
-spec load(file:filename()) -> {ok, calib()} | {error, term()}.
load(File) ->
    case file:consult(File) of
        {ok, [Map]} when is_map(Map) -> {ok, maps:merge(default(), Map)};
        {ok, Other} -> {error, {bad_calibration_file, Other}};
        {error, _} = Error -> Error
    end.

-spec save(file:filename(), map()) -> ok | {error, term()}.
save(File, Calib) ->
    file:write_file(File, io_lib:format("~p.~n", [Calib])).

%% Applies Calib to one raw sample {Acc, Gyro, Mag} (g, dps, gauss) and
%% returns the corrected sample in the same units.
-spec apply(calib(), {vec3(), vec3(), vec3()}) -> {vec3(), vec3(), vec3()}.
apply(Calib, {Acc, Gyro, Mag}) ->
    #{acc_bias := AB, acc_scale := AS, gyro_bias := GB,
      mag_bias := MB, mag_scale := MS, mag_axes := MA} = Calib,
    {mul(sub(Acc, AB), AS),
     sub(Gyro, GB),
     remap(mul(sub(Mag, MB), MS), MA)}.

%% Gyroscope bias: the mean of samples taken while the board is still.
-spec gyro_bias([vec3(), ...]) -> vec3().
gyro_bias(Samples) ->
    mean(Samples).

%% Six-position accelerometer calibration. Takes the mean reading (in g)
%% with each axis pointing up and then down, as
%% #{{x, up} => Vec, {x, down} => Vec, {y, up} => ..., {z, down} => ...}.
%% Along the vertical axis the sensor should read +1 g up and -1 g down:
%%   bias  = (up + down) / 2
%%   scale = 2 / (up - down)
-spec acc_six_position(#{{x | y | z, up | down} => vec3()}) ->
    #{acc_bias := vec3(), acc_scale := vec3()}.
acc_six_position(Means) ->
    Axis = fun(A, I) ->
        Up = element(I, maps:get({A, up}, Means)),
        Down = element(I, maps:get({A, down}, Means)),
        {(Up + Down) / 2, 2 / (Up - Down)}
    end,
    {Bx, Sx} = Axis(x, 1),
    {By, Sy} = Axis(y, 2),
    {Bz, Sz} = Axis(z, 3),
    #{acc_bias => {Bx, By, Bz}, acc_scale => {Sx, Sy, Sz}}.

%% Magnetometer hard/soft iron from samples taken while rotating the
%% board through as many orientations as possible (min/max method):
%%   bias  = (max + min) / 2                 (hard iron)
%%   scale = mean radius / ((max - min) / 2) (soft iron, diagonal)
-spec mag_hard_soft([vec3(), ...]) -> #{mag_bias := vec3(), mag_scale := vec3()}.
mag_hard_soft(Samples) ->
    Axis = fun(I) ->
        Vs = [element(I, S) || S <- Samples],
        {Min, Max} = {lists:min(Vs), lists:max(Vs)},
        {(Max + Min) / 2, (Max - Min) / 2}
    end,
    {{Bx, Rx}, {By, Ry}, {Bz, Rz}} = {Axis(1), Axis(2), Axis(3)},
    R = (Rx + Ry + Rz) / 3,
    #{mag_bias => {Bx, By, Bz}, mag_scale => {R / Rx, R / Ry, R / Rz}}.

-spec mean([vec3(), ...]) -> vec3().
mean(Samples) ->
    N = length(Samples),
    {X, Y, Z} = lists:foldl(fun({A, B, C}, {SA, SB, SC}) -> {SA + A, SB + B, SC + C} end,
                            {0.0, 0.0, 0.0}, Samples),
    {X / N, Y / N, Z / N}.

%% Per-axis standard deviation, e.g. to check the board was still.
-spec stddev([vec3(), ...]) -> vec3().
stddev(Samples) ->
    {MX, MY, MZ} = mean(Samples),
    N = length(Samples),
    {VX, VY, VZ} = lists:foldl(
        fun({A, B, C}, {SA, SB, SC}) ->
            {SA + (A - MX) * (A - MX), SB + (B - MY) * (B - MY), SC + (C - MZ) * (C - MZ)}
        end, {0.0, 0.0, 0.0}, Samples),
    {math:sqrt(VX / N), math:sqrt(VY / N), math:sqrt(VZ / N)}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

sub({A, B, C}, {X, Y, Z}) -> {A - X, B - Y, C - Z}.

mul({A, B, C}, {X, Y, Z}) -> {A * X, B * Y, C * Z}.

remap(V, {I, J, K}) -> {pick(V, I), pick(V, J), pick(V, K)}.

pick(V, I) when I > 0 -> element(I, V);
pick(V, I) when I < 0 -> -element(-I, V).
