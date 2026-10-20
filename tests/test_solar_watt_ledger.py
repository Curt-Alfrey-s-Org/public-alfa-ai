"""Watt hop ledger: conversion losses, A3 split, voltage drop."""

from __future__ import annotations

from math import isclose

from src.ops.solar_watt_ledger import apply_ledger_to_meta, build_watt_ledger


def _row(eid: str, state: str) -> dict:
    return {"entity_id": eid, "state": state}


def test_vent_fan_is_trailer_minus_sph_ac_in() -> None:
    states = {
        "sensor.em16_a3_power": _row("sensor.em16_a3_power", "25"),
        "sensor.sungold_sph302480a_grid_voltage": _row(
            "sensor.sungold_sph302480a_grid_voltage", "117.9"
        ),
        "sensor.sungold_sph302480a_grid_current": _row(
            "sensor.sungold_sph302480a_grid_current", "0.04"
        ),
        "sensor.sungold_sph302480a_load_active_power": _row(
            "sensor.sungold_sph302480a_load_active_power", "5"
        ),
        "sensor.sungold_sph302480a_charging_power": _row(
            "sensor.sungold_sph302480a_charging_power", "0"
        ),
    }
    ledger = build_watt_ledger(states)
    ac_in = abs(117.9 * 0.04)
    assert isclose(ledger["sungold_ac_in_w"], ac_in, rel_tol=1e-6)
    assert ledger["trailer_outlet_w"] == 25.0
    # Since 2026-09-21 (ec89e76a) the vent fan runs on Sungold AC out, not as an A3
    # sibling: trailer outlet = max(A3/B3 CT, UTI) and vent_fan_w is a retired 0.
    assert ledger["vent_fan_w"] == 0.0
    by_id = {h["id"]: h for h in ledger["watt_hops"]}
    assert isclose(by_id["sungold"]["watts_in"], ac_in, rel_tol=1e-6)
    assert by_id["pi4"]["unmetered"] is True


def test_jumper_dc_vdrop_without_inventing_current() -> None:
    states = {
        "sensor.battery_1_voltage": _row("sensor.battery_1_voltage", "25.9"),
        "sensor.battery_2_voltage": _row("sensor.battery_2_voltage", "25.6"),
        "sensor.battery_1_current": _row("sensor.battery_1_current", "1.7"),
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "56"
        ),
        "sensor.battery_1_power": _row("sensor.battery_1_power", "44.1"),
    }
    ledger = build_watt_ledger(states)
    jumper = {h["id"]: h for h in ledger["watt_hops"]}["t2_ku_jumper"]
    assert isclose(jumper["vdrop_v"], 0.3, rel_tol=1e-6)
    assert jumper["vdrop_loss_w"] is None
    assert jumper["vdrop_incomplete"] is True
    assert isclose(ledger["combined_vdrop_v"], 0.3, rel_tol=1e-6)
    assert ledger["combined_vdrop_incomplete"] is True


def test_mppt_vdrop_uses_delta_v_times_current() -> None:
    states = {
        "sensor.solar_controller_battery": _row("sensor.solar_controller_battery", "26.2"),
        "sensor.battery_2_voltage": _row("sensor.battery_2_voltage", "25.9"),
        "sensor.solar_controller_battery_charging": _row(
            "sensor.solar_controller_battery_charging", "2.1"
        ),
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "56"
        ),
        "sensor.solar_controller_charging_power": _row(
            "sensor.solar_controller_charging_power", "54"
        ),
    }
    ledger = build_watt_ledger(states)
    mppt = {h["id"]: h for h in ledger["watt_hops"]}["ku_victron_mppt"]
    assert isclose(mppt["vdrop_v"], 0.3, rel_tol=1e-6)
    assert isclose(mppt["vdrop_loss_w"], 0.3 * 2.1, rel_tol=1e-6)
    assert ledger["combined_path_losses_w"] >= ledger["combined_vdrop_loss_w"]


def test_apply_ledger_subtracts_path_total_from_surplus() -> None:
    states = {
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "56"
        ),
        "sensor.solar_controller_charging_power": _row(
            "sensor.solar_controller_charging_power", "54"
        ),
        "sensor.solar_controller_battery": _row("sensor.solar_controller_battery", "26.2"),
        "sensor.battery_1_voltage": _row("sensor.battery_1_voltage", "25.9"),
        "sensor.solar_controller_battery_charging": _row(
            "sensor.solar_controller_battery_charging", "2.1"
        ),
    }
    meta: dict = {}
    after = apply_ledger_to_meta(meta, states, 56.0)
    assert after is not None
    assert isclose(after, 56.0 - meta["combined_path_losses_w"], rel_tol=1e-6)


def test_ku_unmetered_pv_residual_formula() -> None:
    from src.ops.solar_watt_ledger import ku_unmetered_pv_residual

    # 11 Sep 11:21-style close if KU Renogy DC were known.
    assert isclose(ku_unmetered_pv_residual(80.3, 4.5, 400.0), 475.8, rel_tol=1e-6)
    # Missing KU Renogy DC (this site) -- do not substitute 0.
    assert ku_unmetered_pv_residual(80.3, 4.5, None) is None
    # 15 Sep: batt2 discharging, jumper into KU; treating missing inverter as 0 is negative.
    assert isclose(ku_unmetered_pv_residual(-803.4, 223.4, 0.0), -1026.8, rel_tol=1e-6)
    assert ku_unmetered_pv_residual(-803.4, 223.4, None) is None


def test_ku_unmetered_pv_est_stays_none_without_renogy_dc() -> None:
    states = {
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "250"
        ),
        "sensor.battery_1_power": _row("sensor.battery_1_power", "26.6"),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "-803.4"),
    }
    ledger = build_watt_ledger(states)
    assert ledger["ku_unmetered_pv_est_w"] is None
    hops = {h["id"]: h for h in ledger["watt_hops"]}
    assert hops["ku_battery"]["stored_w"] == -803.4
    hop = hops["ku_victron_mppt"]
    assert hop["unmetered"] is False
    assert hop["watts_in"] == 250.0
    t2 = hops["t2_mppt"]
    assert t2["unmetered"] is True
    assert t2["watts_in"] is None


def test_ku_renogy_ac_est_is_batt2_load_not_shunt() -> None:
    states = {
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "150"
        ),
        "sensor.battery_1_power": _row("sensor.battery_1_power", "225"),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "276"),
        "sensor.em16_a3_power": _row("sensor.em16_a3_power", "25"),
    }
    ledger = build_watt_ledger(states)
    assert ledger["jumper_w"] is None
    assert isclose(ledger["ku_renogy_ac_est_w"], 25.0, rel_tol=1e-6)
    assert ledger["ku_unmetered_pv_est_w"] is None
    hops = {h["id"]: h for h in ledger["watt_hops"]}
    assert hops["ku_battery"]["stored_w"] == 276.0
    assert hops["ku_renogy_ac"]["watts_in"] == 25.0
    assert hops["ku_renogy_ac"]["watts_in"] != hops["ku_battery"]["stored_w"]
    assert hops["ku_victron_mppt"]["unmetered"] is False
    assert hops["ku_victron_mppt"]["watts_in"] == 150.0
    assert hops["t2_mppt"]["unmetered"] is True
    assert ledger["ku_charger_equal_share_w"] is None
    meta: dict = {}
    apply_ledger_to_meta(meta, states, 150.0)
    assert meta["ku_renogy_ac_est_w"] == 25.0
    assert meta["ku_charger_equal_share_w"] is None
    assert "ha_solar" not in str(ledger["ku_unmetered_pv_est_kind"])


def test_silent_75_15_is_shunt_balance_not_one_third() -> None:
    states = {
        "sensor.battery_1_power": _row("sensor.battery_1_power", "448.9"),
        "sensor.battery_1_current": _row("sensor.battery_1_current", "16.6"),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "17.0"),
        "sensor.battery_2_current": _row("sensor.battery_2_current", "0.6"),
        "sensor.smartsolar_100_50_solar_power": _row(
            "sensor.smartsolar_100_50_solar_power", "333"
        ),
        "sensor.smartsolar_100_50_battery_power": _row(
            "sensor.smartsolar_100_50_battery_power", "325.7"
        ),
        "sensor.smartsolar_100_50_battery_current": _row(
            "sensor.smartsolar_100_50_battery_current", "12.0"
        ),
        "sensor.solar_controller_charging_power": _row(
            "sensor.solar_controller_charging_power", "83.9"
        ),
        "sensor.solar_controller_battery_charging": _row(
            "sensor.solar_controller_battery_charging", "3.1"
        ),
    }
    ledger = build_watt_ledger(states)
    assert isclose(ledger["jumper_w"], 448.9 - 325.7, rel_tol=1e-6)
    assert isclose(ledger["jumper_a"], 16.6 - 12.0, rel_tol=1e-6)
    silent_raw = 17.0 - 83.9 + (448.9 - 325.7)
    assert isclose(ledger["ku_silent_mppt_w"], max(0.0, silent_raw), rel_tol=1e-6)
    silent_a_raw = 0.6 - 3.1 + (16.6 - 12.0)
    assert isclose(ledger["ku_silent_mppt_a"], max(0.0, silent_a_raw), rel_tol=1e-6)
    assert isclose(ledger["ku_silent_mppt_third_w"], 333.0 / 3.0, rel_tol=1e-6)
    assert ledger["ku_unmetered_pv_est_kind"] == "shunt_balance"
    hops = {h["id"]: h for h in ledger["watt_hops"]}
    assert hops["t2_mppt"]["unmetered"] is False
    assert hops["t2_mppt"]["watts_in"] == 333.0


def test_sungold_t2_load_fixes_jumper_silent_non_negative() -> None:
    states = {
        "sensor.battery_1_power": _row("sensor.battery_1_power", "-523"),
        "sensor.battery_1_current": _row("sensor.battery_1_current", "-20"),
        "sensor.battery_1_voltage": _row("sensor.battery_1_voltage", "26.0"),
        "sensor.smartsolar_100_50_battery_power": _row(
            "sensor.smartsolar_100_50_battery_power", "295"
        ),
        "sensor.smartsolar_100_50_battery_current": _row(
            "sensor.smartsolar_100_50_battery_current", "11"
        ),
        "sensor.sungold_sph302480a_charging_power": _row(
            "sensor.sungold_sph302480a_charging_power", "1000"
        ),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "-1060"),
        "sensor.battery_2_current": _row("sensor.battery_2_current", "-40"),
        "sensor.solar_controller_charging_power": _row(
            "sensor.solar_controller_charging_power", "84"
        ),
        "sensor.solar_controller_battery_charging": _row(
            "sensor.solar_controller_battery_charging", "3.2"
        ),
    }
    ledger = build_watt_ledger(states)
    assert ledger["jumper_w"] is not None
    assert not isclose(ledger["jumper_w"], -818.0, rel_tol=1e-6)
    assert isclose(ledger["jumper_w"], -523 - 295 + 1000, rel_tol=1e-6)
    assert ledger["ku_silent_mppt_w"] is not None
    assert ledger["ku_silent_mppt_w"] >= 0.0


def test_unmeasured_t2_dump_is_not_added_as_25w() -> None:
    """Charger-to-shunt residual is the silent watts. A 25 W dump guess is not."""
    states = {
        "sensor.battery_1_power": _row("sensor.battery_1_power", "776"),
        "sensor.battery_1_current": _row("sensor.battery_1_current", "28.5"),
        "sensor.battery_1_voltage": _row("sensor.battery_1_voltage", "27.2"),
        "sensor.smartsolar_100_50_battery_power": _row(
            "sensor.smartsolar_100_50_battery_power", "884.9"
        ),
        "sensor.smartsolar_100_50_battery_current": _row(
            "sensor.smartsolar_100_50_battery_current", "32.2"
        ),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "536.6"),
        "sensor.battery_2_current": _row("sensor.battery_2_current", "19.8"),
        "sensor.solar_controller_charging_power": _row(
            "sensor.solar_controller_charging_power", "236.6"
        ),
        "sensor.solar_controller_battery_charging": _row(
            "sensor.solar_controller_battery_charging", "8.7"
        ),
        "sensor.sungold_sph302480a_charging_power": _row(
            "sensor.sungold_sph302480a_charging_power", "0"
        ),
        "switch.ihoment_h5082_c061_right": _row("switch.ihoment_h5082_c061_right", "on"),
        "input_select.h5082_c061_right_inverter": _row(
            "input_select.h5082_c061_right_inverter", "T2"
        ),
        "input_text.h5082_c061_right_load": _row("input_text.h5082_c061_right_load", "0.5"),
        "input_number.dump_site_delta_min_w": _row("input_number.dump_site_delta_min_w", "25"),
    }
    ledger = build_watt_ledger(states)
    residual = (536.6 - 236.6) - (884.9 - 776)
    assert isclose(ledger["t2_bus_load_w"], 0.0)
    assert isclose(ledger["ku_silent_mppt_w"], residual, rel_tol=1e-6)
    assert not isclose(ledger["ku_silent_mppt_w"], residual + 25.0, rel_tol=1e-6)


def test_ku_equal_share_amps_use_batt2_voltage() -> None:
    from src.ops.solar_watt_ledger import ku_equal_share_w, ku_est_amps

    assert ku_equal_share_w(None) is None
    assert isclose(ku_equal_share_w(376.0), 376.0 / 2.0, rel_tol=1e-6)
    states = {
        "sensor.solar_controller_solar_power": _row(
            "sensor.solar_controller_solar_power", "150"
        ),
        "sensor.battery_1_power": _row("sensor.battery_1_power", "225"),
        "sensor.battery_2_power": _row("sensor.battery_2_power", "276"),
        "sensor.battery_2_voltage": _row("sensor.battery_2_voltage", "26.8"),
        "sensor.em16_a3_power": _row("sensor.em16_a3_power", "25"),
    }
    ledger = build_watt_ledger(states)
    assert ledger["jumper_w"] is None
    assert ledger["ku_charger_equal_share_w"] is None
    assert ledger["ku_charger_equal_share_a"] is None


def test_grid_va_zero_is_valid_ac_in_not_load() -> None:
    states = {
        "sensor.em16_a3_power": _row("sensor.em16_a3_power", "25"),
        "sensor.sungold_sph302480a_grid_voltage": _row(
            "sensor.sungold_sph302480a_grid_voltage", "117"
        ),
        "sensor.sungold_sph302480a_grid_current": _row(
            "sensor.sungold_sph302480a_grid_current", "0"
        ),
        "sensor.sungold_sph302480a_load_power": _row(
            "sensor.sungold_sph302480a_load_power", "5"
        ),
    }
    ledger = build_watt_ledger(states)
    assert ledger["sungold_ac_in_w"] == 0.0
    assert ledger["uti_hop_w"] == 5.0
    assert ledger["trailer_outlet_w"] == 25.0
    assert ledger["vent_fan_w"] == 0.0  # retired A3-sibling path (ec89e76a)
    hops = {h["id"]: h for h in ledger["watt_hops"]}
    assert hops["ac_a3_uti"]["watts_in"] == 5.0
    assert hops["sungold"]["watts_in"] == 0.0
