-module(led_test).
-export([test/0]).

test() ->
    LEDs = [1, 2],
    % Flash both LEDs red for 500ms intervals
    [grisp_led:flash(L, red, 500) || L <- LEDs],
    timer:sleep(5000),
    
    % Turn off the second LED
    grisp_led:off(2),
    
    % Randomly evaluate R, G, B channel states (0 or 1)
    Random = fun() ->
        {rand:uniform(2) - 1, rand:uniform(2) - 1, rand:uniform(2) - 1}
    end,
    
    % Apply the random color pattern to LED 1 every 100ms
    grisp_led:pattern(1, [{100, Random}]).
