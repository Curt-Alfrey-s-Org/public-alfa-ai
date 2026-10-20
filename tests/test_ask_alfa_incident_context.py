"""Ask ALFa must not treat resolved incident history as currently firing."""

from src.api.models.incident import IncidentRecord, build_ask_alfa_incident_context


def _inc(*, alertname: str, status: str, opened_at: str = "2026-09-02T00:00:00+00:00") -> IncidentRecord:
    resolved = status == "resolved"
    return IncidentRecord(
        id="00000000-0000-0000-0000-000000000001",
        fingerprint=alertname,
        alertname=alertname,
        severity="critical",
        status=status,  # type: ignore[arg-type]
        labels={},
        annotations={},
        raw_payload={},
        summary=alertname,
        opened_at=opened_at,
        resolved_at="2026-09-02T01:00:00+00:00" if resolved else None,
        last_seen_at=opened_at,
        updated_at=opened_at,
    )


def test_resolved_windows_worker_is_not_in_open_alertnames() -> None:
    rows = [
        _inc(alertname="WindowsWorkerDownExtended", status="resolved"),
        _inc(alertname="WindowsWorkerDown", status="resolved"),
        _inc(alertname="CpuTemperatureHigh", status="resolved"),
        _inc(alertname="BlackboxProbeFailed", status="resolved"),
        _inc(alertname="LowDiskSpace", status="received"),
    ]
    ctx = build_ask_alfa_incident_context(rows)
    assert ctx["open_incidents_by_status"] == {"received": 1}
    assert ctx["open_incident_alertnames"] == ["LowDiskSpace"]
    assert ctx["recent_alertnames"] == ["LowDiskSpace"]
    assert "WindowsWorkerDownExtended" not in ctx["recent_alertnames"]
    assert ctx["incident_counts_in_window"]["resolved"] == 4
    assert ctx["incident_window_kind"] == "last_n_rows"
    assert ctx["incident_window_row_limit"] == 5
    assert ctx["recent_incidents"][0]["alertname"] == "WindowsWorkerDownExtended"
    assert ctx["recent_incidents"][0]["status"] == "resolved"


def test_empty_window() -> None:
    ctx = build_ask_alfa_incident_context([])
    assert ctx["open_incidents_by_status"] == {}
    assert ctx["recent_alertnames"] == []
    assert ctx["recent_incidents"] == []
    assert ctx["incident_window_kind"] == "last_n_rows"
    assert ctx["incident_window_row_limit"] == 0
