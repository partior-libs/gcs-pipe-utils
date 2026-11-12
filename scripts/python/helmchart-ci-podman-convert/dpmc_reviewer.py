#!/usr/bin/env python3
import argparse
import asyncio
import datetime
import os
import re
import sys

# Bundled reference docs, resolved relative to the tool (works from any working directory)
TOOL_ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LIMITATIONS = os.path.join(TOOL_ROOT, "doc", "limitations-0714.md")
DEFAULT_SUPPORT_DOC = os.path.join(TOOL_ROOT, "doc", "podman-kube-play-support.md")

FAIL_ON_CHOICES = ("blocking", "warning", "never")

# Pricing for standard fast developer-tier model (e.g. Gemini 1.5/2.5 Flash)
# Input tokens: $0.075 per 1M tokens ($0.000000075 per token)
# Output tokens: $0.30 per 1M tokens ($0.00000030 per token)
PRICE_PER_INPUT_TOKEN = 0.075 / 1_000_000
PRICE_PER_OUTPUT_TOKEN = 0.30 / 1_000_000

# Average characters per token for standard models (SentencePiece)
CHARS_PER_TOKEN = 4

REVIEWER_SYSTEM_INSTRUCTIONS = """
You are an expert systems engineer and rootless Podman deployment specialist.
Your role is to perform an AI-driven audit of compiled Kubernetes YAML manifests that will be deployed on local VMs using 'podman kube play'.

For each review:
1. Verify compliance against the documented limitations list.
2. Heuristically check for other compatibility issues or edge cases not covered by the current limitations list (e.g., potential hostPath permissions, network alias conflicts, system mount conflicts, securityContext fields).
3. Write a Markdown audit report. Start with a short executive summary:
   - [PASS]: If the file is 100% compliant.
   - [WARNING]: If there are non-breaking recommendations (e.g., security enhancements or optimization tips).
   - [BLOCKING ERROR]: If there are actual incompatible attributes that will crash or fail under rootless Podman.

Findings: list every finding under a "Findings" heading, numbered F1, F2, ... Each finding MUST contain
all of these fields, so an engineer can locate and verify it without re-running the review:
   - **ID / Severity**: e.g. `F1 / BLOCKING` or `F2 / WARNING`
   - **Resource**: `<kind>/<metadata.name>` (e.g. `Deployment/quorum`)
   - **Path**: YAML path inside that resource (e.g. `spec.template.spec.containers[0].securityContext.privileged`)
   - **Snippet**: the offending lines quoted verbatim from the manifest in a ```yaml code block
   - **Limitation**: the Limitation ID from the guide (e.g. `ID 13`), or `new` if not documented
   - **Why it fails**: the concrete failure under rootless `podman kube play`
   - **Fix**: the suggested change
Do not report a finding you cannot tie to a specific resource and path. If there are no findings, say so.

Placeholders: values written as '__TBU:<yaml.path>__' (e.g. '__TBU:node.tessera.db.url__', '__TBU:nodes[2].tmUrl__',
'__TBU:tessera-db-creds.data.password__') are intentional placeholders traced back to the Helm values / secrets files.
They are filled in at deployment time, even in integer, boolean or base64 fields. Never report them as
[BLOCKING ERROR]; at most list them once under an informational "Unresolved placeholders" section.

Podman field support: the "PODMAN KUBE PLAY FIELD SUPPORT" tables come from the Podman project and list
which Kubernetes fields `podman kube play` reads (✅), does not support ("no"), or cannot support on a
single node ("N/A"). They do not say whether an unsupported field causes an error or is silently ignored.
   - Report a field marked "no" or "N/A" as WARNING, not BLOCKING, unless the limitations guide documents
     that it breaks. The compile log already lists them, so group them into one finding per resource.
   - Never report a field marked ✅ (e.g. volumeMounts.subPath, readOnlyRootFilesystem, hostPort,
     initContainers, hostAliases) as unsupported by Podman.
   - For how things actually behave on the target RHEL 8 rootless setup, the limitations guide takes
     precedence over the support tables.

Startup scripts: every `sh -c` container script in this manifest has already passed a deterministic
`sh -n` syntax check in the compile step (after the Kubernetes `$$` -> `$` escape). Do not report shell
syntax errors. Long double-quoted YAML strings may be wrapped across lines by the YAML writer; those
line breaks are not part of the value, so judge a script by its parsed value, not its line layout.

The LAST line of your report must be exactly one of the following, with nothing after it.
For WARNING and BLOCKING_ERROR, list the IDs of the findings that caused that verdict:
AUDIT_VERDICT: PASS
AUDIT_VERDICT: WARNING (F1, F3)
AUDIT_VERDICT: BLOCKING_ERROR (F2)
"""

PROMPT_TEMPLATE = """
Please perform a detailed audit of the compiled manifest below against our documented limitations guide.
Also, proactively identify any other potential rootless Podman deployment issues.

=== DOCUMENTED LIMITATIONS ===
{limitations}

=== PODMAN KUBE PLAY FIELD SUPPORT ===
{support}
{notes}
=== COMPILED MANIFEST ===
{manifest}
"""

VERDICT_RE = re.compile(
    r"^\s*\**\s*AUDIT_VERDICT:\s*(PASS|WARNING|BLOCKING_ERROR)\b[ \t]*(?:\(([^)\n]*)\))?", re.MULTILINE
)


def _last_verdict_match(report: str):
    matches = list(VERDICT_RE.finditer(report))
    return matches[-1] if matches else None


def parse_verdict(report: str):
    """Returns the last AUDIT_VERDICT value in the report ('PASS', 'WARNING', 'BLOCKING_ERROR'), or None."""
    m = _last_verdict_match(report)
    return m.group(1) if m else None


def parse_verdict_findings(report: str) -> list:
    """Returns the finding IDs cited on the last AUDIT_VERDICT line, e.g. ['F2', 'F5']."""
    m = _last_verdict_match(report)
    if not m or not m.group(2):
        return []
    return [f.strip() for f in m.group(2).split(",") if f.strip()]


def build_prompt(limitations: str, manifest: str, support: str = "", notes: str = "") -> str:
    """`notes`: optional chart-specific review notes from the calling pipeline."""
    notes_section = f"\n=== CHART-SPECIFIC REVIEW NOTES ===\n{notes}\n" if notes else ""
    return PROMPT_TEMPLATE.format(limitations=limitations, manifest=manifest,
                                  support=support or "(not provided)", notes=notes_section)


def report_header(model: str, manifest_path: str) -> str:
    """Deterministic run metadata, written by the script (not the model) above the AI report."""
    commit = os.environ.get("GITHUB_SHA", "local")
    run_url = ""
    if os.environ.get("GITHUB_RUN_ID"):
        run_url = (f"{os.environ.get('GITHUB_SERVER_URL', 'https://github.com')}/"
                   f"{os.environ.get('GITHUB_REPOSITORY', '')}/actions/runs/{os.environ['GITHUB_RUN_ID']}")
    when = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        f"> **Model:** `{model}` · **Manifest:** `{manifest_path}` · **Commit:** `{commit}` · **Reviewed:** {when}",
    ]
    if run_url:
        lines.append(f"> **Run:** {run_url}")
    lines.append("> Exact prompt sent to the model: `ai-review-prompt.md` in the same artifact.")
    return "\n".join(lines) + "\n\n"


def build_failed(verdict, fail_on: str = "blocking") -> bool:
    """
    Whether the step should fail for this verdict.
      blocking (default): fail on BLOCKING_ERROR, or when the model gave no verdict at all
      warning:            also fail on WARNING
      never:              report only, never fail
    """
    if fail_on not in FAIL_ON_CHOICES:
        raise ValueError(f"fail_on must be one of {FAIL_ON_CHOICES}, got '{fail_on}'")
    if fail_on == "never":
        return False
    if verdict is None or verdict == "BLOCKING_ERROR":
        return True
    return fail_on == "warning" and verdict == "WARNING"

ERROR_DETAIL_MAX_CHARS = 1500


def error_hint(message: str) -> str:
    """A pointer for the most likely cause, based on the error text."""
    if "getAccessToken" in message or "PERMISSION_DENIED" in message or "403" in message:
        return ("The runner's identity is not allowed to call Vertex AI. Check that this repository is bound to "
                "the service account (`roles/iam.workloadIdentityUser`) and allowed by the Workload Identity "
                "provider's attribute condition.")
    if "RESOURCE_EXHAUSTED" in message or "429" in message:
        return "Vertex AI quota or rate limit reached. Re-run the job later."
    return "Re-run the job; if it keeps failing, check the step log for the full error."


def report_review_error(error: BaseException, model_name: str, manifest_path: str, report_output_path: str,
                        fail_on: str = "blocking"):
    """
    The review could not run. Writes the report file, `verdict=ERROR` to the step outputs and a block to the
    step summary, then exits: non-zero unless fail_on is 'never' (an unreviewed manifest is not a passed one).
    """
    message = f"{type(error).__name__}: {error}".strip()
    if len(message) > ERROR_DETAIL_MAX_CHARS:
        message = message[:ERROR_DETAIL_MAX_CHARS] + "\n... (truncated, full error in the step log)"
    hint = error_hint(message)
    failed = fail_on != "never"
    header = report_header(model_name, manifest_path)
    body = f"## AI review did not run\n\n{hint}\n\n```text\n{message}\n```\n"

    os.makedirs(os.path.dirname(report_output_path) or ".", exist_ok=True)
    with open(report_output_path, "w") as f:
        f.write(header + body)
    print(f"AI review error report written to '{report_output_path}'")

    github_output_path = os.environ.get("GITHUB_OUTPUT")
    if github_output_path:
        with open(github_output_path, "a") as go:
            go.write("verdict=ERROR\n")
            go.write("verdict_findings=\n")

    github_summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if github_summary_path:
        try:
            with open(github_summary_path, "a") as sf:
                sf.write("## 🤖 AI Podman Manifest Auditor Report\n\n")
                sf.write(header)
                sf.write("> [!CAUTION]\n" if failed else "> [!WARNING]\n")
                outcome = "This build has been failed" if failed else "The step passes (fail-on: never)"
                sf.write(f"> **AI REVIEW DID NOT RUN**: {outcome}. {hint}\n\n")
                sf.write(f"```text\n{message}\n```\n")
        except Exception as e:
            print(f"Warning: Failed to write to GITHUB_STEP_SUMMARY: {e}")

    if failed:
        print(f"\n❌ AI review did not run; cannot confirm the manifest is safe (fail-on: {fail_on}). Failing pipeline step...")
        sys.exit(1)
    print("\n⚠️ AI review did not run; not failing the step (fail-on: never).")
    sys.exit(0)


async def run_audit(manifest_path: str, limitations_path: str, report_output_path: str, prompt_output_path: str,
                    support_path: str, notes_path: str = None, fail_on: str = "blocking"):
    print(f"Loading manifest from '{manifest_path}'...")
    if not os.path.exists(manifest_path):
        print(f"Error: Manifest file '{manifest_path}' not found. Please compile the manifest first.")
        sys.exit(1)

    print(f"Loading limitations guide from '{limitations_path}'...")
    if not os.path.exists(limitations_path):
        print(f"Error: Limitations guide '{limitations_path}' not found.")
        sys.exit(1)

    with open(manifest_path, "r") as f:
        manifest_content = f.read()

    with open(limitations_path, "r") as f:
        limitations_content = f.read()

    support_content = ""
    if os.path.exists(support_path):
        print(f"Loading Podman field support tables from '{support_path}'...")
        with open(support_path, "r") as f:
            support_content = f.read()
    else:
        print(f"Warning: Podman field support tables '{support_path}' not found; reviewing without them.")

    notes_content = ""
    if notes_path:
        if not os.path.exists(notes_path):
            print(f"Error: Review notes file '{notes_path}' not found.")
            sys.exit(1)
        print(f"Loading chart-specific review notes from '{notes_path}'...")
        with open(notes_path, "r") as f:
            notes_content = f.read()

    prompt = build_prompt(limitations_content, manifest_content, support_content, notes_content)
    model_name = os.getenv("ANTIGRAVITY_MODEL", "gemini-3.5-flash")
    use_vertex = os.getenv("ANTIGRAVITY_USE_VERTEX", "true").lower() == "true"

    # Save the exact input before calling the model, so it is available even if the call fails
    os.makedirs(os.path.dirname(prompt_output_path) or ".", exist_ok=True)
    with open(prompt_output_path, "w") as f:
        f.write(f"<!-- model: {model_name} (vertex={use_vertex}) -->\n\n")
        f.write("# SYSTEM INSTRUCTIONS\n")
        f.write(REVIEWER_SYSTEM_INSTRUCTIONS)
        f.write("\n# USER PROMPT\n")
        f.write(prompt)
    print(f"Exact prompt written to '{prompt_output_path}'")

    try:
        from google.antigravity import Agent, LocalAgentConfig, CapabilitiesConfig
    except ImportError:
        print("Error The 'google-antigravity' Python SDK is not installed.")
        print("Please install it using: pip install google-antigravity")
        report_review_error(ImportError("The 'google-antigravity' Python SDK is not installed."),
                            model_name, manifest_path, report_output_path, fail_on)

    print("Spawning Antigravity Reviewer Agent...")

    full_response_text = ""
    try:
        config = LocalAgentConfig(
            model=model_name,
            vertex=use_vertex,
            system_instructions=REVIEWER_SYSTEM_INSTRUCTIONS,
            capabilities=CapabilitiesConfig()  # Read-only safe configuration
        )
        async with Agent(config) as agent:
            print("Reviewing manifest (streaming feedback)...")
            print("-" * 60)

            # Call the agent
            response = await agent.chat(prompt)
            async for token in response:
                sys.stdout.write(token)
                sys.stdout.flush()
                full_response_text += token
            print()
            print("-" * 60)
    except Exception as e:  # auth, quota, network, model errors: report them instead of leaving the summary empty
        import traceback
        traceback.print_exc()
        report_review_error(e, model_name, manifest_path, report_output_path, fail_on)

    # 4. Write Markdown Report
    os.makedirs(os.path.dirname(report_output_path) or ".", exist_ok=True)
    header = report_header(model_name, manifest_path)
    with open(report_output_path, "w") as f:
        f.write(header + full_response_text)
    print(f"AI review report written to '{report_output_path}'")

    # 5. Token Usage & Cost Benchmark calculations
    # Input tokens estimation
    input_char_count = len(prompt) + len(REVIEWER_SYSTEM_INSTRUCTIONS)
    est_input_tokens = input_char_count // CHARS_PER_TOKEN
    est_input_cost = est_input_tokens * PRICE_PER_INPUT_TOKEN

    # Output tokens estimation
    output_char_count = len(full_response_text)
    est_output_tokens = output_char_count // CHARS_PER_TOKEN
    est_output_cost = est_output_tokens * PRICE_PER_OUTPUT_TOKEN

    total_est_cost = est_input_cost + est_output_cost

    print("\n" + "=" * 40)
    print("      AI AUDIT BENCHMARK REPORT")
    print("=" * 40)
    print(f"Input Characters:  {input_char_count:,}")
    print(f"Input Tokens (est): {est_input_tokens:,}")
    print(f"Input Cost (est):   ${est_input_cost:.6f}")
    print("-" * 40)
    print(f"Output Characters: {output_char_count:,}")
    print(f"Output Tokens (est):{est_output_tokens:,}")
    print(f"Output Cost (est):  ${est_output_cost:.6f}")
    print("-" * 40)
    print(f"Total Tokens (est): {est_input_tokens + est_output_tokens:,}")
    print(f"Total Cost (est):   ${total_est_cost:.6f} (${total_est_cost * 1000:.4f} per 1k runs)")
    print("=" * 40)

    # 6. Read the verdict line to decide whether to fail the pipeline
    verdict = parse_verdict(full_response_text)
    verdict_findings = parse_verdict_findings(full_response_text)
    failed = build_failed(verdict, fail_on)
    cited = f" (findings: {', '.join(verdict_findings)})" if verdict_findings else ""
    print(f"Audit verdict: {verdict or 'MISSING (no AUDIT_VERDICT line in report)'}{cited}  [fail-on: {fail_on}]")

    # Expose the verdict to the calling workflow step (written before any exit, so it is set on failure too)
    github_output_path = os.environ.get("GITHUB_OUTPUT")
    if github_output_path:
        with open(github_output_path, "a") as go:
            go.write(f"verdict={verdict or 'MISSING'}\n")
            go.write(f"verdict_findings={','.join(verdict_findings)}\n")

    # 7. Write to GitHub Step Summary if running in GitHub Actions
    github_summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if github_summary_path:
        print(f"Writing audit report and benchmark data to GitHub Step Summary at '{github_summary_path}'...")
        try:
            with open(github_summary_path, "a") as sf:
                sf.write("## 🤖 AI Podman Manifest Auditor Report\n\n")
                sf.write(header)
                sf.write(full_response_text)
                sf.write("\n\n---\n\n")
                sf.write("### 📊 AI Audit Cost & Token Usage Benchmark\n\n")
                sf.write("| Metric | Value |\n")
                sf.write("| :--- | :--- |\n")
                sf.write(f"| **Input Characters** | {input_char_count:,} |\n")
                sf.write(f"| **Input Tokens (est)** | {est_input_tokens:,} |\n")
                sf.write(f"| **Input Cost (est)** | ${est_input_cost:.6f} |\n")
                sf.write(f"| **Output Characters** | {output_char_count:,} |\n")
                sf.write(f"| **Output Tokens (est)** | {est_output_tokens:,} |\n")
                sf.write(f"| **Output Cost (est)** | ${est_output_cost:.6f} |\n")
                sf.write(f"| **Total Tokens (est)** | {est_input_tokens + est_output_tokens:,} |\n")
                sf.write(f"| **Total Cost (est)** | **${total_est_cost:.6f}** |\n\n")
                cited_md = f" Findings: {', '.join(verdict_findings)}." if verdict_findings else ""
                if failed and verdict is None:
                    sf.write("> [!CAUTION]\n")
                    sf.write("> **NO VERDICT**: The AI Manifest Auditor report has no `AUDIT_VERDICT` line, so the build has been failed. Re-run the job.\n")
                elif failed:
                    sf.write("> [!CAUTION]\n")
                    sf.write(f"> **FAILED ({verdict}, fail-on: {fail_on})**: This build has been failed by the AI Manifest Auditor.{cited_md}\n")
                else:
                    sf.write("> [!NOTE]\n")
                    sf.write(f"> **AUDIT COMPLETED ({verdict or 'no verdict'}, fail-on: {fail_on})**: The step passes.{cited_md}\n")
        except Exception as e:
            print(f"Warning: Failed to write to GITHUB_STEP_SUMMARY: {e}")

    # 8. Fail the step according to --fail-on
    if failed and verdict is None:
        print("\n❌ AI Reviewer report has no AUDIT_VERDICT line; cannot confirm the manifest is safe. Failing pipeline step...")
        sys.exit(1)
    elif failed:
        print(f"\n❌ AI Reviewer verdict {verdict} fails the step (fail-on: {fail_on}). Failing pipeline step...")
        sys.exit(1)
    else:
        print(f"\n✅ AI Reviewer verdict {verdict or 'missing'} does not fail the step (fail-on: {fail_on}).")

def main():
    parser = argparse.ArgumentParser(description="AI audit of a compiled podman-ready manifest.")
    parser.add_argument("--manifest", default="output/podman-ready.yaml", help="Compiled manifest to audit.")
    parser.add_argument("--limitations", default=DEFAULT_LIMITATIONS,
                        help="Documented limitations guide (default: the one shipped with the tool).")
    parser.add_argument("--support", default=DEFAULT_SUPPORT_DOC,
                        help="Podman kube play field support tables (default: the pinned copy shipped with the tool).")
    parser.add_argument("--review-notes", default=None,
                        help="Optional chart-specific notes added to the prompt (e.g. known, accepted chart behaviour).")
    parser.add_argument("--fail-on", choices=FAIL_ON_CHOICES, default="blocking",
                        help="Which verdict fails the step: blocking (default; also no verdict), warning, never.")
    parser.add_argument("--report", default="output/ai-review-report.md", help="Where to write the Markdown report.")
    parser.add_argument("--prompt-out", default="output/ai-review-prompt.md",
                        help="Where to save the exact system instructions + prompt sent to the model.")
    args = parser.parse_args()
    asyncio.run(run_audit(args.manifest, args.limitations, args.report, args.prompt_out, args.support,
                          args.review_notes, args.fail_on))


if __name__ == "__main__":
    main()
