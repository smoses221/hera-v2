# Copied from GwendalLaurent/pmod_uwb

Source: https://github.com/GwendalLaurent/pmod_uwb, `src/` at commit
`b48835d39b473ef3060cc0a2f407363d2139b510` (2024-06-27). Apache-2.0, see `LICENSE`.

Copied: the DW1000 driver (`pmod_uwb.erl`) and the IEEE 802.15.4 stack
(`ieee802154*.erl`, `mac_frame.erl`, the duty-cycle and CSMA modules, and the headers).

Not copied: `robot.erl`, `robot_sup.erl` and `robot.app.src` (the example
application of the upstream GRiSP project), and `ranging/` (replaced by
`src/uwb_twr.erl`, see `REDESIGN_LOG.md`).

Local changes (marked `hera:` in the code):
- `duty_cycle_non_beacon.erl`: two `-spec`s with an unbound type variable
  (`MacTXState`/`MacTxState`), which is a compile error on OTP 29. Only the
  specs changed, not the code.
- `duty_cycle_non_beacon.erl`, `rx_loop_on/1`: ARX2INIT (automatic transition to
  INIT after each reception) is off by default instead of always on. On the board,
  ranging intervals that span a reception came out tens of ms short. The suspected
  cause is the DW1000 timebase stopping in INIT. `application:set_env(hera,
  uwb_arx2init, true)` restores upstream's behaviour, for comparison.

Also copied, for host tests: `test/mock_phy_network.erl`, `test/network_simulation.erl`
and `test/pmod_uwb_registers.erl` (upstream `test/`). Only their `-include` path
changed (marked `hera:`). `test/uwb_twr_SUITE.erl` uses them.
