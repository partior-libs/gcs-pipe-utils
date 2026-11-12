from dpmc_reviewer import (
    build_failed, build_prompt, parse_verdict, parse_verdict_findings, report_header,
    DEFAULT_LIMITATIONS, DEFAULT_SUPPORT_DOC,
)


def test_verdict_pass_even_if_phrase_mentioned():
    report = "## Summary\nNo BLOCKING ERROR found. [BLOCKING ERROR] means a crash.\n\nAUDIT_VERDICT: PASS\n"
    assert parse_verdict(report) == "PASS"
    assert not build_failed(parse_verdict(report))


def test_verdict_warning_does_not_fail():
    assert not build_failed(parse_verdict("text\nAUDIT_VERDICT: WARNING"))


def test_verdict_blocking_fails_and_tolerates_bold():
    report = "text\n**AUDIT_VERDICT: BLOCKING_ERROR**\n"
    assert parse_verdict(report) == "BLOCKING_ERROR"
    assert build_failed(parse_verdict(report))


def test_last_verdict_wins():
    report = "Legend:\nAUDIT_VERDICT: PASS\n...\nAUDIT_VERDICT: BLOCKING_ERROR\n"
    assert parse_verdict(report) == "BLOCKING_ERROR"


def test_missing_verdict_fails():
    assert parse_verdict("a report with no verdict line") is None
    assert build_failed(None)


def test_verdict_with_cited_findings():
    report = "...\n**AUDIT_VERDICT: BLOCKING_ERROR (F2, F5)**\n"
    assert parse_verdict(report) == "BLOCKING_ERROR"
    assert parse_verdict_findings(report) == ["F2", "F5"]
    assert parse_verdict_findings("AUDIT_VERDICT: PASS") == []


def test_prompt_contains_inputs_verbatim():
    prompt = build_prompt("LIMITS-TEXT", "kind: Deployment\n", "| readinessProbe | no |")
    assert "=== DOCUMENTED LIMITATIONS ===\nLIMITS-TEXT" in prompt
    assert "=== PODMAN KUBE PLAY FIELD SUPPORT ===\n| readinessProbe | no |" in prompt
    assert "=== COMPILED MANIFEST ===\nkind: Deployment\n" in prompt
    assert "(not provided)" in build_prompt("L", "M")


def test_report_header_has_run_metadata(monkeypatch):
    monkeypatch.setenv("GITHUB_SHA", "abc123")
    monkeypatch.setenv("GITHUB_RUN_ID", "42")
    monkeypatch.setenv("GITHUB_REPOSITORY", "org/repo")
    header = report_header("gemini-x", "output/podman-ready.yaml")
    assert "`gemini-x`" in header and "`abc123`" in header
    assert "https://github.com/org/repo/actions/runs/42" in header
    assert parse_verdict(header) is None


def test_fail_on_policies():
    import pytest
    cases = {  # verdict: (blocking, warning, never)
        "PASS": (False, False, False),
        "WARNING": (False, True, False),
        "BLOCKING_ERROR": (True, True, False),
        None: (True, True, False),
    }
    for verdict, expected in cases.items():
        assert tuple(build_failed(verdict, f) for f in ("blocking", "warning", "never")) == expected, verdict
    assert build_failed("BLOCKING_ERROR") is True  # default is "blocking"
    with pytest.raises(ValueError):
        build_failed("PASS", "sometimes")


def test_review_notes_section_only_when_given():
    assert "CHART-SPECIFIC REVIEW NOTES" not in build_prompt("L", "M", "S")
    prompt = build_prompt("L", "M", "S", "update-ca-trust failing is expected for this chart")
    assert "=== CHART-SPECIFIC REVIEW NOTES ===\nupdate-ca-trust failing is expected" in prompt
    assert prompt.index("CHART-SPECIFIC REVIEW NOTES") < prompt.index("=== COMPILED MANIFEST ===")


def test_bundled_docs_resolve_independent_of_cwd():
    import os
    assert os.path.isabs(DEFAULT_LIMITATIONS) and os.path.exists(DEFAULT_LIMITATIONS)
    assert os.path.isabs(DEFAULT_SUPPORT_DOC) and os.path.exists(DEFAULT_SUPPORT_DOC)


def _fake_antigravity(monkeypatch, error):
    """Installs a stand-in google.antigravity whose agent raises `error` on chat."""
    import sys, types

    class Agent:
        def __init__(self, config):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def chat(self, prompt):
            raise error

    module = types.ModuleType("google.antigravity")
    module.Agent = Agent
    module.LocalAgentConfig = lambda **kwargs: kwargs
    module.CapabilitiesConfig = lambda: None
    google = types.ModuleType("google")
    google.antigravity = module
    monkeypatch.setitem(sys.modules, "google", google)
    monkeypatch.setitem(sys.modules, "google.antigravity", module)


def _run_failing_audit(monkeypatch, tmp_path, error, fail_on="blocking"):
    import asyncio
    import pytest
    from dpmc_reviewer import run_audit
    _fake_antigravity(monkeypatch, error)
    manifest = tmp_path / "podman-ready.yaml"
    manifest.write_text("kind: Pod\n")
    outputs, summary = tmp_path / "gh-output", tmp_path / "gh-summary"
    monkeypatch.setenv("GITHUB_OUTPUT", str(outputs))
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    report = tmp_path / "out" / "ai-review-report.md"
    with pytest.raises(SystemExit) as exit_info:
        asyncio.run(run_audit(str(manifest), DEFAULT_LIMITATIONS, str(report), str(tmp_path / "out" / "prompt.md"),
                              DEFAULT_SUPPORT_DOC, None, fail_on))
    return exit_info.value.code, outputs.read_text(), summary.read_text(), report.read_text()


def test_agent_error_is_reported_and_fails(monkeypatch, tmp_path):
    error = RuntimeError("Permission 'iam.serviceAccounts.getAccessToken' denied on resource")
    code, outputs, summary, report = _run_failing_audit(monkeypatch, tmp_path, error)
    assert code == 1
    assert "verdict=ERROR" in outputs
    assert "AI REVIEW DID NOT RUN" in summary and "[!CAUTION]" in summary
    assert "getAccessToken" in summary and "roles/iam.workloadIdentityUser" in summary
    assert "AI review did not run" in report
    assert parse_verdict(report) is None


def test_agent_error_with_fail_on_never_passes(monkeypatch, tmp_path):
    code, outputs, summary, _ = _run_failing_audit(monkeypatch, tmp_path, RuntimeError("boom"), fail_on="never")
    assert code == 0
    assert "verdict=ERROR" in outputs
    assert "[!WARNING]" in summary and "fail-on: never" in summary


def test_long_agent_error_is_truncated(monkeypatch, tmp_path):
    from dpmc_reviewer import ERROR_DETAIL_MAX_CHARS
    _, _, summary, _ = _run_failing_audit(monkeypatch, tmp_path, RuntimeError("x" * 10_000))
    assert "(truncated, full error in the step log)" in summary
    assert len(summary) < ERROR_DETAIL_MAX_CHARS + 2_000
