#!/usr/bin/env python3
"""All-in-one Azure DevOps PR CLI for AKS.

Usage:
    ado_pr_cli.py fetch <repo> <pr-id>
    ado_pr_cli.py cleanup <repo> <pr-id>
    ado_pr_cli.py threads <pr> [--json] [--repo REPO]
    ado_pr_cli.py post-comment <pr> <json-file> [--repo REPO]
    ado_pr_cli.py reply-thread <pr> <thread-id> <message> [--repo REPO] [--dry-run]
    ado_pr_cli.py resolve-thread <pr> <thread-id> [--status STATUS] [--repo REPO] [--dry-run]
    ado_pr_cli.py status <pr> [--full] [--repo REPO]
    ado_pr_cli.py pr-url <pr> [--repo REPO]
    ado_pr_cli.py diff <pr> [--repo REPO] [--outdir DIR]
    ado_pr_cli.py requeue-policy <pr> [--all-broken] [--include-not-started] [--eval-id ID ...] [--dry-run]
    ado_pr_cli.py build-failures <pr> [--def-id ID]
    ado_pr_cli.py trigger-build <pr> <build-def-id> [--dry-run]
    ado_pr_cli.py flake-check <build-def-id> [--top N]

<pr> can be a numeric PR ID or a full ADO PR URL.

Prerequisites:
    - Azure CLI (az) logged in
    - git (for fetch/cleanup commands)
    - jq (optional, for manual inspection of output files)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
from datetime import datetime, timezone
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# ADO org/project/repo defaults are NOT hard-coded here: they are captain-specific
# ADO-org specifics that must live in LOCAL config, not firstmate's tracked shared
# material (data/captain.md scope discipline, report §2). ado-pr-cli.sh sources
# config/ado-review.env and exports FM_ADO_ORG / FM_ADO_PROJECT / FM_ADO_REPO before
# invoking this CLI. A missing value stays empty; a bare numeric PR id then errors
# with an actionable message (see parse_pr_input) instead of silently targeting some
# other org. Full PR URLs are self-describing (org/project/repo parsed from the URL)
# and need no defaults.
DEFAULT_ORG = os.environ.get("FM_ADO_ORG", "")
DEFAULT_PROJECT = os.environ.get("FM_ADO_PROJECT", "")
DEFAULT_REPO = os.environ.get("FM_ADO_REPO", "")
ADO_TOKEN_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"

DATA_DIR = Path.home() / ".aks" / "ado-pr-review" / "data"
BARE_REPOS_DIR = DATA_DIR / "bare-repos"
PR_DATA_DIR = DATA_DIR / "pr-data"
GIT_TIMEOUT = int(os.environ.get("GIT_TIMEOUT", "300"))

SKIP_AUTHORS = {"Microsoft.VisualStudio.Services.TFS", "AKS Dev Assistant"}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------


def info(msg: str) -> None:
    print(f"[INFO] {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"[WARN] {msg}", file=sys.stderr, flush=True)


def error(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)


def die(msg: str) -> None:
    error(msg)
    sys.exit(1)


# ---------------------------------------------------------------------------
# URL Parsing
# ---------------------------------------------------------------------------

_URL_PATTERNS = [
    # https://dev.azure.com/{org}/{project}/_git/{repo}/pullrequest/{id}
    re.compile(
        r"https?://dev\.azure\.com/(?P<org>[^/]+)/(?P<project>[^/]+)/"
        r"_git/(?P<repo>[^/]+)/pullrequest/(?P<pr_id>\d+)"
    ),
    # https://{org}.visualstudio.com/{project}/_git/{repo}/pullrequest/{id}
    re.compile(
        r"https?://(?P<org>[^.]+)\.visualstudio\.com/(?P<project>[^/]+)/"
        r"_git/(?P<repo>[^/]+)/pullrequest/(?P<pr_id>\d+)"
    ),
]


def parse_pr_input(
    value: str,
    default_org: str = DEFAULT_ORG,
    default_project: str = DEFAULT_PROJECT,
    default_repo: str = DEFAULT_REPO,
) -> tuple[str, str, str, str]:
    """Parse a PR URL or numeric ID into (org, project, repo, pr_id)."""
    for pat in _URL_PATTERNS:
        m = pat.search(value)
        if m:
            return m.group("org"), m.group("project"), m.group("repo"), m.group("pr_id")
    # Assume plain numeric ID
    if value.isdigit():
        if not (default_org and default_project and default_repo):
            die(
                f"Bare PR id {value} needs ADO org/project/repo defaults, but they "
                "are not configured. Set them in the firstmate home's "
                "config/ado-review.env (FM_ADO_ORG / FM_ADO_PROJECT / FM_ADO_REPO), "
                "or pass a full PR URL instead."
            )
        return default_org, default_project, default_repo, value
    die(f"Cannot parse PR input: {value}")
    return "", "", "", ""  # unreachable


def org_url(org: str) -> str:
    return f"https://dev.azure.com/{org}"


def org_web_base(org: str) -> str:
    """Web base URL for an org, for building human-clickable PR links.

    A bare org name maps to the visualstudio.com host form (the captain's
    canonical form). A caller that already holds a full org base URL (either
    host form) can pass it through verbatim to preserve that host.
    """
    if org.startswith("http://") or org.startswith("https://"):
        return org.rstrip("/")
    return f"https://{org}.visualstudio.com"


def pr_web_url(org: str, project: str, repo: str, pr_id: str) -> str:
    """Canonical full, human-clickable ADO PR URL.

    This is the single source of truth for rendering a PR reference to the
    captain: every report header and status escalation builds its URL here so a
    bare numeric id can never leak into captain-facing output.
    """
    return f"{org_web_base(org)}/{project}/_git/{repo}/pullrequest/{pr_id}"


def pr_web_url_or_bare(
    value: str,
    org: str = DEFAULT_ORG,
    project: str = DEFAULT_PROJECT,
    repo: str = DEFAULT_REPO,
) -> str:
    """Full PR URL for `value`, or the bare id when it cannot be constructed.

    `value` is a full PR URL (returned unchanged, preserving its host form) or a
    bare numeric id resolved against org/project/repo (the explicit flags when
    provided, otherwise the configured FM_ADO_ORG/PROJECT/REPO). When those are
    missing the id cannot become a URL, so return a marked bare id rather than
    silently emit it as if it were a proper link.
    """
    for pat in _URL_PATTERNS:
        if pat.search(value):
            return value
    if value.isdigit():
        if org and project and repo:
            return pr_web_url(org, project, repo, value)
        return f"PR {value} (no full URL: ADO org/project/repo not configured)"
    return value


# ---------------------------------------------------------------------------
# Markdown links for comment bodies
# ---------------------------------------------------------------------------
#
# ADO PR comment content is markdown-rendered, so a bare `https://...` shows as
# non-clickable plain text. Every URL firstmate posts to a PR thread must render
# as a clickable `[label](url)` link. `md_link` composes one; `autolink_bare_urls`
# is the defensive backstop that wraps any stray bare URL a comment body slipped
# through with. Both are idempotent: an already-wrapped link is left untouched.

# One alternation: an existing markdown link, an existing <url> autolink, or a
# bare url. Only the bare-url branch is rewritten, so re-running is a no-op.
_LINK_OR_URL_RE = re.compile(
    r"\[[^\]]*\]\([^)]*\)"        # existing [label](url)
    r"|<https?://[^>\s]+>"        # existing <url> autolink
    r"|https?://[^\s<>\[\]()]+"   # bare url
)
_TRAILING_PUNCT = ".,;:!?"


def md_link(label: str, url: str) -> str:
    """Render a clickable markdown link, defaulting the label to the URL."""
    url = (url or "").strip()
    label = (label or url).strip()
    return f"[{label}]({url})"


def autolink_bare_urls(text: str) -> str:
    """Wrap any bare `https://...` in `text` as a clickable markdown link.

    Existing markdown links and `<url>` autolinks are left untouched, so this is
    safe to run over a comment body that already uses `md_link` and is idempotent.
    """
    if not text:
        return text

    def repl(m: re.Match) -> str:
        s = m.group(0)
        if not s.startswith(("http://", "https://")):
            return s  # already a markdown link or an <url> autolink
        core, trailing = s, ""
        while core and core[-1] in _TRAILING_PUNCT:
            trailing = core[-1] + trailing
            core = core[:-1]
        return md_link(core, core) + trailing

    return _LINK_OR_URL_RE.sub(repl, text)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def get_token() -> str:
    """Acquire an Azure CLI access token for ADO."""
    try:
        result = subprocess.run(
            ["az", "account", "get-access-token",
             "--resource", ADO_TOKEN_RESOURCE,
             "--query", "accessToken", "-o", "tsv"],
            capture_output=True, text=True, check=True, timeout=30,
        )
        token = result.stdout.strip()
        if not token:
            die("Empty token returned. Run: az login")
        return token
    except FileNotFoundError:
        die("Azure CLI (az) not found. Install it first.")
    except subprocess.CalledProcessError:
        die("Azure CLI not logged in. Run: az login")
    except subprocess.TimeoutExpired:
        die("Azure CLI token request timed out. Run: az login")
    return ""


def ensure_az_login() -> str:
    """Validate Azure CLI auth is fresh and return token.

    Call this early - before any git or API operations - so that expired
    auth surfaces immediately with an actionable message instead of
    hanging for minutes inside a git fetch.
    """
    info("Checking Azure CLI authentication...")
    token = get_token()
    info("Azure CLI auth OK")
    return token


def check_git_access(org: str, project: str, repo: str) -> None:
    """Verify git can reach the repo."""
    url = f"{org_url(org)}/{project}/_git/{repo}"
    try:
        subprocess.run(
            ["git", "ls-remote", url, "HEAD"],
            capture_output=True, timeout=15, check=True,
        )
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        die(f"Git credentials failed or timed out for {url}")


# ---------------------------------------------------------------------------
# ADO REST API helpers
# ---------------------------------------------------------------------------


def _curl_get(url: str, token: str) -> dict:
    """GET an ADO REST endpoint, return parsed JSON."""
    result = subprocess.run(
        ["curl", "-s", "-H", f"Authorization: Bearer {token}", url],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        die(f"curl failed: {result.stderr}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        die(f"Invalid JSON from {url}: {result.stdout[:200]}")
    return {}


def _curl_post(url: str, token: str, data: dict) -> dict:
    """POST JSON to an ADO REST endpoint."""
    body = json.dumps(data)
    result = subprocess.run(
        ["curl", "-s", "-X", "POST",
         "-H", f"Authorization: Bearer {token}",
         "-H", "Content-Type: application/json",
         "-d", body, url],
        capture_output=True, text=True, timeout=60,
    )
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"_raw": result.stdout, "_stderr": result.stderr}


def _curl_patch(url: str, token: str, data: dict | None = None) -> dict:
    """PATCH an ADO REST endpoint."""
    cmd = ["curl", "-s", "-X", "PATCH",
           "-H", f"Authorization: Bearer {token}",
           "-H", "Content-Type: application/json",
           url]
    if data:
        cmd.extend(["-d", json.dumps(data)])
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return {"_raw": result.stdout}


def api_get_pr(org: str, project: str, repo: str, pr_id: str, token: str) -> dict:
    url = f"{org_url(org)}/{project}/_apis/git/repositories/{repo}/pullrequests/{pr_id}?api-version=7.1"
    return _curl_get(url, token)


def api_get_repo_id(org: str, project: str, repo: str, token: str) -> str:
    url = f"{org_url(org)}/{project}/_apis/git/repositories/{repo}?api-version=7.1"
    data = _curl_get(url, token)
    repo_id = data.get("id", "")
    if not repo_id:
        die(f"Could not get repository ID for {repo}")
    return repo_id


def api_get_project_id(org: str, project: str, token: str) -> str:
    url = f"{org_url(org)}/_apis/projects/{project}?api-version=7.1"
    data = _curl_get(url, token)
    pid = data.get("id", "")
    if not pid:
        die(f"Could not get project ID for {project}")
    return pid


def api_get_threads(org: str, project: str, repo_id: str, pr_id: str, token: str) -> list[dict]:
    url = (f"{org_url(org)}/{project}/_apis/git/repositories/{repo_id}/"
           f"pullRequests/{pr_id}/threads?api-version=7.1-preview.1")
    data = _curl_get(url, token)
    return data.get("value", [])


def api_get_policies(org: str, project: str, project_id: str, pr_id: str, token: str) -> list[dict]:
    artifact_id = f"vstfs:///CodeReview/CodeReviewId/{project_id}/{pr_id}"
    url = (f"{org_url(org)}/{project}/_apis/policy/evaluations"
           f"?artifactId={artifact_id}&api-version=7.2-preview.1")
    data = _curl_get(url, token)
    return data.get("value", [])


def api_post_thread(org: str, project: str, repo: str, pr_id: str,
                    thread_data: dict, token: str) -> dict:
    """Create a new PR thread via az devops invoke."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(thread_data, f)
        tmp_path = f.name
    try:
        result = subprocess.run(
            ["az", "devops", "invoke",
             "--area", "git", "--resource", "pullRequestThreads",
             "--route-parameters", f"project={project}", f"repositoryId={repo}", f"pullRequestId={pr_id}",
             "--org", org_url(org),
             "--http-method", "POST", "--api-version", "7.0",
             "--in-file", tmp_path,
             "--query", "{id: id, status: status}", "-o", "json"],
            capture_output=True, text=True, timeout=60,
        )
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            return {"_error": result.stdout + result.stderr}
    finally:
        os.unlink(tmp_path)


def api_get_diff(org: str, project: str, repo: str,
                 base_commit: str, target_commit: str, token: str) -> dict:
    """Get diff between two commits via REST API."""
    # First get the repo ID
    repo_id = api_get_repo_id(org, project, repo, token)
    url = (f"{org_url(org)}/{project}/_apis/git/repositories/{repo_id}/diffs/commits"
           f"?baseVersion={base_commit}&baseVersionType=commit"
           f"&targetVersion={target_commit}&targetVersionType=commit"
           f"&api-version=7.1")
    return _curl_get(url, token)


def api_requeue_policy(org: str, project: str, eval_id: str, token: str) -> dict:
    url = (f"{org_url(org)}/{project}/_apis/policy/evaluations/{eval_id}"
           f"?api-version=7.2-preview.1")
    return _curl_patch(url, token)


def api_reply_thread(org: str, project: str, repo_id: str, pr_id: str,
                     thread_id: str, content: str, token: str) -> dict:
    url = (f"{org_url(org)}/{project}/_apis/git/repositories/{repo_id}/"
           f"pullRequests/{pr_id}/threads/{thread_id}/comments"
           f"?api-version=7.1-preview.1")
    return _curl_post(url, token, {
        "content": content,
        "parentCommentId": 1,
        "commentType": 1,
    })


def api_set_thread_status(org: str, project: str, repo_id: str, pr_id: str,
                          thread_id: str, status: str, token: str) -> dict:
    url = (f"{org_url(org)}/{project}/_apis/git/repositories/{repo_id}/"
           f"pullRequests/{pr_id}/threads/{thread_id}"
           f"?api-version=7.1-preview.1")
    return _curl_patch(url, token, {"status": status})


def api_get_builds_for_definition(org: str, project: str, def_id: str,
                                  token: str, top: int = 10) -> list[dict]:
    url = (f"{org_url(org)}/{project}/_apis/build/builds"
           f"?definitions={def_id}&$top={top}&api-version=7.1")
    data = _curl_get(url, token)
    return data.get("value", [])


def api_get_pr_build(org: str, project: str, def_id: str, pr_id: str,
                     token: str) -> dict | None:
    """Find the most recent build for a given def triggered by this PR.

    Queries by branchName=refs/pull/{pr_id}/merge - the canonical PR build branch.
    Falls back to scanning triggerInfo if branch filter returns nothing.
    """
    branch = f"refs/pull/{pr_id}/merge"
    url = (f"{org_url(org)}/{project}/_apis/build/builds"
           f"?definitions={def_id}&branchName={branch}&$top=5&api-version=7.1")
    builds = _curl_get(url, token).get("value", [])
    if builds:
        return builds[0]
    # Fallback for older trigger styles
    for b in api_get_builds_for_definition(org, project, def_id, token, top=20):
        tinfo = b.get("triggerInfo") or {}
        if str(tinfo.get("pr.number", "")) == str(pr_id):
            return b
    return None


def api_get_build_timeline(org: str, project: str, build_id: str, token: str) -> dict:
    url = (f"{org_url(org)}/{project}/_apis/build/builds/{build_id}/timeline"
           f"?api-version=7.1")
    return _curl_get(url, token)


def api_trigger_build(org: str, project: str, def_id: str, source_branch: str,
                      pr_id: str, token: str) -> dict:
    url = f"{org_url(org)}/{project}/_apis/build/builds?api-version=7.1"
    return _curl_post(url, token, {
        "definition": {"id": int(def_id)},
        "sourceBranch": source_branch,
        "reason": "pullRequest",
        "triggerInfo": {"pr.number": str(pr_id)},
    })


# ---------------------------------------------------------------------------
# Git helpers (for fetch/cleanup)
# ---------------------------------------------------------------------------


def run_git(*args: str, cwd: str | Path | None = None, timeout: int = GIT_TIMEOUT) -> subprocess.CompletedProcess:
    info(f"Running: git {' '.join(args)}")
    try:
        return subprocess.run(
            ["git", *args],
            cwd=cwd, capture_output=True, text=True,
            timeout=timeout, check=True,
        )
    except subprocess.TimeoutExpired:
        die(f"Git timed out after {timeout}s \u2014 this may indicate expired auth. Run: az login")
    except subprocess.CalledProcessError as e:
        die(f"Git failed: {e.stderr.strip()}")
    return subprocess.CompletedProcess(args=[], returncode=1)  # unreachable


# ---------------------------------------------------------------------------
# Command: fetch
# ---------------------------------------------------------------------------


def cmd_fetch(args: argparse.Namespace) -> None:
    """Fetch PR data and create a worktree for review."""
    repo = args.repo
    pr_id = args.pr_id
    org = args.org
    project = args.project

    info(f"Fetching PR {pr_id} from repo {repo}...")

    # Validate auth early so expired credentials surface immediately
    # instead of hanging for minutes during git fetch.
    token = ensure_az_login()

    # Skip git credential pre-check if bare repo exists; git fetch will catch auth issues.
    bare_repo_path = BARE_REPOS_DIR / repo
    if not bare_repo_path.is_dir():
        check_git_access(org, project, repo)

    # Configure az devops defaults
    subprocess.run(
        ["az", "devops", "configure", "--defaults",
         f"organization={org_url(org)}", f"project={project}"],
        capture_output=True, check=True,
    )

    BARE_REPOS_DIR.mkdir(parents=True, exist_ok=True)
    PR_DATA_DIR.mkdir(parents=True, exist_ok=True)

    pr_data_path = PR_DATA_DIR / f"{repo}-{pr_id}"
    pr_data_path.mkdir(parents=True, exist_ok=True)

    # Fetch PR metadata
    pr_json = api_get_pr(org, project, repo, pr_id, token)
    if "pullRequestId" not in pr_json and "id" not in pr_json:
        die(f"Failed to fetch PR {pr_id}: {json.dumps(pr_json)[:200]}")

    source_branch = pr_json.get("sourceRefName", "").replace("refs/heads/", "")
    title = pr_json.get("title", "No title")
    description = pr_json.get("description", "No description")
    author = pr_json.get("createdBy", {}).get("displayName", "Unknown")
    created = pr_json.get("creationDate", "Unknown")

    if not source_branch:
        die("Could not determine source branch")

    metadata_file = pr_data_path / "metadata.md"
    metadata_file.write_text(textwrap.dedent(f"""\
        # PR {pr_id} Metadata

        **Repository:** {repo}
        **PR ID:** {pr_id}
        **URL:** {pr_web_url(org, project, repo, pr_id)}
        **Source Branch:** {source_branch}
        **Author:** {author}
        **Created:** {created}

        ## Title
        {title}

        ## Description
        {description}
    """))
    info("PR metadata saved")

    # Setup bare repo
    bare_repo_path = BARE_REPOS_DIR / repo
    repo_url = f"{org_url(org)}/{project}/_git/{repo}"

    if not bare_repo_path.is_dir():
        error(f"Bare repository not found at {bare_repo_path}")
        print()
        print("Please clone manually (may take 10-20 min for large repos):")
        print(f'  git clone --bare --progress "{repo_url}" "{bare_repo_path}"')
        print()
        sys.exit(1)

    # Fetch master (skip if fetched within the last hour) and PR branch.
    # Use --no-tags to speed things up on large repos.
    import time
    fetch_head = bare_repo_path / "FETCH_HEAD"
    skip_master = (
        fetch_head.exists()
        and (time.time() - fetch_head.stat().st_mtime) < 3600
    )
    if skip_master:
        info("Master branch is recent (< 1h), skipping fetch")
    else:
        info("Fetching master branch...")
        run_git("fetch", "--no-tags", "origin", "master:refs/remotes/origin/master",
                cwd=bare_repo_path, timeout=600)
        run_git("update-ref", "refs/heads/master", "refs/remotes/origin/master",
                cwd=bare_repo_path)

    info(f"Fetching PR branch: {source_branch}...")
    run_git("fetch", "--no-tags", "origin",
            f"{source_branch}:refs/remotes/origin/{source_branch}",
            cwd=bare_repo_path, timeout=600)
    info("Bare repository ready")

    # Create worktree
    worktree_path = pr_data_path / "worktree"
    if worktree_path.is_dir():
        info("Removing existing worktree...")
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(worktree_path)],
            cwd=bare_repo_path, capture_output=True,
        )
        if worktree_path.is_dir():
            shutil.rmtree(worktree_path, ignore_errors=True)

    run_git("worktree", "add", str(worktree_path), f"origin/{source_branch}",
            cwd=bare_repo_path)

    # Merge master into worktree
    merge_result = subprocess.run(
        ["git", "merge", "origin/master", "--no-edit"],
        cwd=worktree_path, capture_output=True, text=True,
    )
    if merge_result.returncode != 0:
        warn("Merge conflicts detected, continuing with current state")

    # Generate diff
    diff_file = pr_data_path / "diff.patch"
    diff_result = subprocess.run(
        ["git", "diff", "origin/master"],
        cwd=worktree_path, capture_output=True, text=True, check=True,
    )
    diff_file.write_text(diff_result.stdout)

    info(f"Diff: {diff_file} ({len(diff_result.stdout)} bytes)")
    info(f"Worktree: {worktree_path}")
    info(f"PR {pr_id} fetch completed!")
    info(f"PR data: {pr_data_path}")


# ---------------------------------------------------------------------------
# Command: cleanup
# ---------------------------------------------------------------------------


def cmd_cleanup(args: argparse.Namespace) -> None:
    """Remove worktree and PR data."""
    repo = args.repo
    pr_id = args.pr_id

    info(f"Cleaning up PR {pr_id}...")

    pr_data_path = PR_DATA_DIR / f"{repo}-{pr_id}"
    bare_repo_path = BARE_REPOS_DIR / repo
    worktree_path = pr_data_path / "worktree"

    if not pr_data_path.is_dir():
        warn(f"PR data not found: {pr_data_path}")
        return

    if worktree_path.is_dir() and bare_repo_path.is_dir():
        subprocess.run(
            ["git", "worktree", "remove", "--force", str(worktree_path)],
            cwd=bare_repo_path, capture_output=True,
        )
        if worktree_path.is_dir():
            shutil.rmtree(worktree_path, ignore_errors=True)

    shutil.rmtree(pr_data_path, ignore_errors=True)
    info("Cleanup completed")


# ---------------------------------------------------------------------------
# Command: threads
# ---------------------------------------------------------------------------


def cmd_threads(args: argparse.Namespace) -> None:
    """Fetch and display human review comments on a PR."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    token = get_token()
    repo_id = api_get_repo_id(org, project, repo, token)
    threads = api_get_threads(org, project, repo_id, pr_id, token)

    # Filter to active/pending threads with human comments
    results = []
    for t in threads:
        status = t.get("status", "unknown")
        comments = t.get("comments", [])
        human_comments = []
        for c in comments:
            author_name = c.get("author", {}).get("displayName", "")
            ctype = c.get("commentType", 0)
            if author_name not in SKIP_AUTHORS and ctype != 3:
                human_comments.append(c)

        if human_comments:
            tc = t.get("threadContext")
            fpath = tc.get("filePath", "N/A") if tc else "N/A"
            line = None
            if tc and tc.get("rightFileStart"):
                line = tc["rightFileStart"].get("line")
            results.append({
                "threadId": t["id"],
                "status": status,
                "filePath": fpath,
                "line": line,
                "comments": [
                    {"author": c["author"]["displayName"],
                     "content": c.get("content", "")}
                    for c in human_comments
                ],
            })

    if args.json:
        print(json.dumps(results, indent=2))
        return

    if not results:
        print("No human review comments found on this PR.")
        return

    for r in results:
        line_info = f":{r['line']}" if r["line"] else ""
        print(f"=== Thread {r['threadId']} | Status: {r['status']} | File: {r['filePath']}{line_info} ===")
        for c in r["comments"]:
            print(f"  Author: {c['author']}")
            content_preview = c["content"][:600]
            print(f"  Content: {content_preview}")
            print()


# ---------------------------------------------------------------------------
# Command: post-comment
# ---------------------------------------------------------------------------


def cmd_post_comment(args: argparse.Namespace) -> None:
    """Post inline review comments from a JSON file."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    json_file = Path(args.json_file)
    if not json_file.is_file():
        die(f"Comments file not found: {json_file}")

    try:
        comments = json.loads(json_file.read_text())
    except json.JSONDecodeError as e:
        die(f"Invalid JSON in {json_file}: {e}")

    if not isinstance(comments, list):
        die("JSON file must contain an array of comment objects")

    info(f"Posting {len(comments)} comment(s) to PR {pr_id} in {repo}...")

    success = 0
    failed = 0

    for i, comment in enumerate(comments):
        file_path = comment.get("file", "")
        start_line = comment.get("startLine", 1)
        end_line = comment.get("endLine", start_line)
        severity = comment.get("severity", "Medium")
        content = autolink_bare_urls(comment.get("content", ""))

        thread_data = {
            "comments": [{
                "parentCommentId": 0,
                "content": content,
                "commentType": "text",
            }],
            "threadContext": {
                "filePath": file_path,
                "rightFileStart": {"line": start_line, "offset": 1},
                "rightFileEnd": {"line": end_line, "offset": 2},
            },
            "status": "active",
        }

        info(f"Posting comment {i + 1}/{len(comments)} [{severity}] on {file_path}:{start_line}-{end_line}...")

        result = api_post_thread(org, project, repo, pr_id, thread_data, get_token())
        thread_id = result.get("id")
        if thread_id:
            print(f"[OK]   Thread {thread_id} created")
            success += 1
        else:
            err = result.get("_error", json.dumps(result)[:200])
            print(f"[FAIL] Could not create thread: {err}")
            failed += 1

    print()
    print(f"[DONE] Posted: {success}  Failed: {failed}  Total: {len(comments)}")
    if failed > 0:
        sys.exit(1)


# ---------------------------------------------------------------------------
# Command: pr-url
# ---------------------------------------------------------------------------


def cmd_pr_url(args: argparse.Namespace) -> None:
    """Print the canonical full ADO PR URL for a PR URL or bare id.

    The report builder and status escalations call this so a bare id never
    reaches captain-facing output. Exits non-zero when a bare id cannot be
    resolved (no configured org/project/repo), printing a marked bare id.
    """
    out = pr_web_url_or_bare(args.pr, args.org, args.project, args.repo)
    print(out)
    if out.startswith("PR ") and "no full URL" in out:
        sys.exit(1)


# ---------------------------------------------------------------------------
# Command: status
# ---------------------------------------------------------------------------


def cmd_status(args: argparse.Namespace) -> None:
    """Show PR metadata, policy evaluations, and merge status."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    token = get_token()

    # PR metadata
    print(f"=== PR #{pr_id} metadata ===")
    print(f"URL: {pr_web_url(org, project, repo, pr_id)}")
    pr = api_get_pr(org, project, repo, pr_id, token)
    meta = {
        "title": pr.get("title"),
        "status": pr.get("status"),
        "sourceBranch": pr.get("sourceRefName"),
        "targetBranch": pr.get("targetRefName"),
        "author": pr.get("createdBy", {}).get("displayName"),
        "mergeStatus": pr.get("mergeStatus"),
    }
    print(json.dumps(meta, indent=2))

    # Save full metadata for downstream use
    tmp = Path(f"/tmp/pr-{pr_id}-full.json")
    tmp.write_text(json.dumps(pr, indent=2))

    # Policy evaluations
    print(f"\n=== Policy evaluations ===")
    project_id = api_get_project_id(org, project, token)
    policies = api_get_policies(org, project, project_id, pr_id, token)

    # Optional: dump the full unsimplified response for downstream tooling
    # (babysit's Stage 1.1 build-policy extraction needs the full shape).
    if getattr(args, "full", False):
        full_file = Path(f"/tmp/pr-{pr_id}-policies-full.json")
        full_file.write_text(json.dumps(policies, indent=2))
        info(f"Wrote full policy details: {full_file}")

    simplified = []
    for p in policies:
        cfg = p.get("configuration", {})
        settings = cfg.get("settings", {})
        simplified.append({
            "evaluationId": p.get("evaluationId"),
            "displayName": settings.get("displayName"),
            "status": p.get("status"),
            "policyType": cfg.get("type", {}).get("displayName"),
            "buildDefinitionId": settings.get("buildDefinitionId"),
        })

    # Save for downstream
    pol_file = Path(f"/tmp/pr-{pr_id}-policies.json")
    pol_file.write_text(json.dumps(simplified, indent=2))

    # Group by status
    from collections import defaultdict
    by_status: dict[str, list[str]] = defaultdict(list)
    for p in simplified:
        by_status[p["status"] or "unknown"].append(p["displayName"] or "unnamed")

    print("Policy summary:")
    for status, gates in sorted(by_status.items()):
        print(f"  {status} ({len(gates)}): {', '.join(g for g in gates if g)}")

    # Reviewers
    print(f"\n=== Reviewers ===")
    vote_labels = {10: "approved", 5: "approved with suggestions", 0: "no vote",
                   -5: "waiting for author", -10: "rejected"}
    for r in pr.get("reviewers", []):
        vote = r.get("vote", 0)
        label = vote_labels.get(vote, f"unknown ({vote})")
        req = " [required]" if r.get("isRequired") else ""
        print(f"  {r.get('displayName', 'unknown')}: {label}{req}")

    # Merge conflict check
    print(f"\n=== Merge status ===")
    merge_status = pr.get("mergeStatus", "unknown")
    print(f"mergeStatus: {merge_status}")

    if merge_status == "conflicts":
        source = pr.get("sourceRefName", "").replace("refs/heads/", "")
        target = pr.get("targetRefName", "").replace("refs/heads/", "")
        print()
        print("WARNING: MERGE CONFLICTS DETECTED")
        print()
        print("To resolve:")
        print("  1. cd <local-repo>")
        print(f"  2. git fetch origin {target} && git checkout {target} && git pull origin {target}")
        print(f"  3. git fetch origin {source} && git checkout {source} && git reset --hard origin/{source}")
        print(f"  4. git merge origin/{target} --no-edit")
        print("  5. Resolve conflicts, git add, git commit --no-edit, git push")

    print(f"\n=== DONE ===")
    print(f"Files saved to: /tmp/pr-{pr_id}-*.json")


# ---------------------------------------------------------------------------
# Command: diff
# ---------------------------------------------------------------------------


def cmd_diff(args: argparse.Namespace) -> None:
    """Fetch PR metadata, changed files, and diff to local files."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    token = get_token()

    # Fetch PR metadata via az repos pr show
    info(f"Fetching PR #{pr_id} metadata...")
    result = subprocess.run(
        ["az", "repos", "pr", "show", "--id", pr_id,
         "--org", org_url(org), "--output", "json"],
        capture_output=True, text=True, timeout=60,
    )
    if result.returncode != 0:
        die(f"Failed to fetch PR: {result.stderr}")
    pr = json.loads(result.stdout)

    # Derive file prefix
    title = pr.get("title", "untitled")
    source_commit = pr.get("lastMergeSourceCommit", {}).get("commitId", "00000000")
    short_commit = source_commit[:8]
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")[:60]
    prefix = outdir / f"{slug}-{short_commit}"

    # Save metadata
    meta_file = Path(f"{prefix}-metadata.json")
    meta_file.write_text(json.dumps(pr, indent=2))
    info(f"Metadata: {meta_file}")

    # Extract key info
    meta_summary = {
        "title": pr.get("title"),
        "description": pr.get("description"),
        "author": pr.get("createdBy", {}).get("displayName"),
        "status": pr.get("status"),
        "targetBranch": pr.get("targetRefName"),
        "sourceBranch": pr.get("sourceRefName"),
        "reviewers": [
            {"name": r.get("displayName"), "vote": r.get("vote")}
            for r in pr.get("reviewers", [])
        ],
        "workItems": [w.get("id") for w in (pr.get("workItemRefs") or []) if w],
        "mergeStatus": pr.get("mergeStatus"),
    }
    print(json.dumps(meta_summary, indent=2))

    # Get changed files
    info("Fetching changed files...")
    # Fetch commit diff (contains changed files list)
    target_commit = pr.get("lastMergeTargetCommit", {}).get("commitId", "")
    diff_json = {}
    if source_commit and target_commit:
        info("Fetching commit diff...")
        cdiff = api_get_diff(org, project, repo, target_commit, source_commit, token)
        cdiff_file = Path(f"{prefix}-commitdiff.json")
        cdiff_file.write_text(json.dumps(cdiff, indent=2))
        info(f"Commit diff: {cdiff_file}")
        diff_json = cdiff

        # Extract changed files from commit diff
        changes = cdiff.get("changes", [])
        if changes:
            print("\nChanged files:")
            for c in changes:
                item = c.get("item", {})
                print(f"  {item.get('path', '?')} ({c.get('changeType', '?')})")
    else:
        warn("Could not determine source/target commits for diff")

    # Write summary
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    source_branch = pr.get("sourceRefName", "").replace("refs/heads/", "")
    target_branch = pr.get("targetRefName", "").replace("refs/heads/", "")
    reviewers_str = ", ".join(
        f"{r.get('displayName', '?')} (vote: {r.get('vote', 0)})"
        for r in pr.get("reviewers", [])
    ) or "none"
    work_items_str = ", ".join(
        str(w.get("id", "")) for w in (pr.get("workItemRefs") or []) if w
    ) or "none"

    changes_table = ""
    for c in diff_json.get("changes", []):
        item = c.get("item", {})
        changes_table += f"| {item.get('path', '?')} | {c.get('changeType', '?')} |\n"

    summary = f"""# PR {pr_id}: {title}

- **URL**: {pr_web_url(org, project, repo, pr_id)}
- **Fetched**: {now}
- **Source Commit**: {source_commit}
- **Author**: {meta_summary['author']}
- **Status**: {meta_summary['status']}
- **Branch**: {source_branch} -> {target_branch}
- **Reviewers**: {reviewers_str}
- **Work Items**: {work_items_str}
- **Merge Status**: {meta_summary['mergeStatus']}

## Changed Files

| File | Change Type |
|------|-------------|
{changes_table}
## Local Artifacts

- metadata: `{prefix}-metadata.json`
- commitdiff: `{prefix}-commitdiff.json`
"""

    summary_file = Path(f"{prefix}-summary.md")
    summary_file.write_text(summary)
    info(f"Summary: {summary_file}")


# ---------------------------------------------------------------------------
# Command: requeue-policy
# ---------------------------------------------------------------------------


def _load_policies_file(pr_id: str) -> list[dict]:
    """Load the simplified policy list saved by `status`."""
    pol_file = Path(f"/tmp/pr-{pr_id}-policies.json")
    if not pol_file.is_file():
        die(f"Policy snapshot not found: {pol_file}. Run `status {pr_id}` first.")
    try:
        return json.loads(pol_file.read_text())
    except json.JSONDecodeError as e:
        die(f"Invalid JSON in {pol_file}: {e}")
    return []


def cmd_requeue_policy(args: argparse.Namespace) -> None:
    """Re-queue one or more policy evaluations (broken/notStarted/rejected)."""
    org, project, _, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    targets: list[tuple[str, str]] = []  # (eval_id, label)

    if args.eval_id:
        for eid in args.eval_id:
            targets.append((eid, "explicit"))

    if args.all_broken or args.include_not_started:
        policies = _load_policies_file(pr_id)
        wanted = {"broken"}
        if args.include_not_started:
            wanted.add("notStarted")
        if args.all_broken:
            wanted.add("broken")
        for p in policies:
            if p.get("status") in wanted:
                targets.append((str(p.get("evaluationId")), p.get("status")))

    if not targets:
        die("No targets to re-queue. Pass --eval-id, --all-broken, or --include-not-started.")

    # De-dup while preserving order
    seen: set[str] = set()
    unique: list[tuple[str, str]] = []
    for eid, label in targets:
        if eid in seen:
            continue
        seen.add(eid)
        unique.append((eid, label))

    if args.dry_run:
        info(f"DRY RUN - would re-queue {len(unique)} evaluation(s):")
        for eid, label in unique:
            print(f"  {eid} ({label})")
        return

    token = get_token()
    for eid, label in unique:
        info(f"Re-queuing {eid} ({label})...")
        resp = api_requeue_policy(org, project, eid, token)
        status = resp.get("status", "?")
        display = (resp.get("configuration", {}) or {}).get("settings", {}).get("displayName", "")
        print(f"  -> status={status} display={display}")


# ---------------------------------------------------------------------------
# Command: reply-thread
# ---------------------------------------------------------------------------


def cmd_reply_thread(args: argparse.Namespace) -> None:
    """Post a reply to an existing PR thread."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    # ADO renders comment markdown, so any bare URL is wrapped as a clickable
    # link before it posts (and before the dry-run preview, so the preview is
    # faithful to what would land).
    message = autolink_bare_urls(args.message)

    if args.dry_run:
        info(f"DRY RUN - would post to thread {args.thread_id} in PR {pr_id}:")
        print(f"---\n{message}\n---")
        return

    token = get_token()
    repo_id = api_get_repo_id(org, project, repo, token)
    resp = api_reply_thread(org, project, repo_id, pr_id,
                            args.thread_id, message, token)
    if resp.get("id"):
        print(f"[OK] Posted comment id={resp['id']} on thread {args.thread_id}")
    else:
        err = resp.get("_raw", json.dumps(resp)[:300])
        die(f"Failed to post reply: {err}")


# ---------------------------------------------------------------------------
# Command: resolve-thread
# ---------------------------------------------------------------------------


_THREAD_STATUSES = {"fixed", "closed", "active", "wontFix", "pending", "byDesign"}


def cmd_resolve_thread(args: argparse.Namespace) -> None:
    """Change the status of a PR thread (fixed/closed/active/...)."""
    org, project, repo, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    status = args.status
    if status not in _THREAD_STATUSES:
        die(f"Invalid status {status!r}. Valid: {sorted(_THREAD_STATUSES)}")

    if args.dry_run:
        info(f"DRY RUN - would set thread {args.thread_id} in PR {pr_id} to status={status}")
        return

    token = get_token()
    repo_id = api_get_repo_id(org, project, repo, token)
    resp = api_set_thread_status(org, project, repo_id, pr_id,
                                 args.thread_id, status, token)
    new_status = resp.get("status", "?")
    print(f"[OK] Thread {args.thread_id} status -> {new_status}")


# ---------------------------------------------------------------------------
# Command: build-failures
# ---------------------------------------------------------------------------


def cmd_build_failures(args: argparse.Namespace) -> None:
    """Find PR builds that failed and print their failing task details."""
    org, project, _, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    token = get_token()

    # Decide which build definitions to check
    def_ids: list[tuple[str, str]] = []  # (def_id, displayName)
    if args.def_id:
        def_ids.append((args.def_id, "explicit"))
    else:
        policies = _load_policies_file(pr_id)
        for p in policies:
            if p.get("status") not in ("rejected", "broken"):
                continue
            did = p.get("buildDefinitionId")
            if did:
                def_ids.append((str(did), p.get("displayName") or ""))

    if not def_ids:
        print("No failed build policies with buildDefinitionId found.")
        return

    for did, label in def_ids:
        print(f"\n=== Build def {did} ({label}) ===")
        build = api_get_pr_build(org, project, did, pr_id, token)
        if not build:
            print(f"  No PR build found for definition {did}.")
            continue
        print(f"  buildId={build.get('id')} number={build.get('buildNumber')} "
              f"status={build.get('status')} result={build.get('result')}")
        url = (build.get("_links", {}) or {}).get("web", {}).get("href")
        if url:
            print(f"  url={url}")

        if build.get("result") in ("succeeded", None):
            continue

        timeline = api_get_build_timeline(org, project, str(build["id"]), token)
        failed = [
            r for r in (timeline.get("records") or [])
            if r.get("result") == "failed"
        ]
        if not failed:
            print("  (no failed records in timeline)")
            continue
        print(f"  Failed records ({len(failed)}):")
        for r in failed:
            issues = [
                i.get("message", "")
                for i in (r.get("issues") or [])
                if i.get("type") == "error"
            ]
            print(f"    - {r.get('name')} (errorCount={r.get('errorCount', 0)})")
            for msg in issues[:3]:
                snippet = msg.strip().splitlines()[0][:200]
                print(f"        ! {snippet}")


# ---------------------------------------------------------------------------
# Command: trigger-build
# ---------------------------------------------------------------------------


def cmd_trigger_build(args: argparse.Namespace) -> None:
    """Manually queue a build for a PR's source branch."""
    org, project, _, pr_id = parse_pr_input(
        args.pr, args.org, args.project, args.repo)

    token = get_token()
    pr = api_get_pr(org, project, args.repo, pr_id, token)
    source = pr.get("sourceRefName")
    if not source:
        die(f"Could not determine sourceRefName for PR {pr_id}")

    if args.dry_run:
        info(f"DRY RUN - would queue build def {args.build_def_id} for "
             f"PR {pr_id} on branch {source}")
        return

    resp = api_trigger_build(org, project, args.build_def_id, source, pr_id, token)
    if resp.get("id"):
        url = (resp.get("_links", {}) or {}).get("web", {}).get("href", "")
        print(f"[OK] Queued build id={resp['id']} number={resp.get('buildNumber')}")
        print(f"     status={resp.get('status')} url={url}")
    else:
        err = resp.get("_raw", json.dumps(resp)[:300])
        die(f"Failed to queue build: {err}")


# ---------------------------------------------------------------------------
# Command: flake-check
# ---------------------------------------------------------------------------


def cmd_flake_check(args: argparse.Namespace) -> None:
    """Show recent build results for a definition to spot repo-wide flakes."""
    token = get_token()
    builds = api_get_builds_for_definition(
        args.org, args.project, args.build_def_id, token, top=args.top)
    if not builds:
        print(f"No recent builds for definition {args.build_def_id}.")
        return

    print(f"=== Last {len(builds)} builds for def {args.build_def_id} ===")
    counts: dict[str, int] = {}
    for b in builds:
        result = b.get("result") or b.get("status") or "unknown"
        counts[result] = counts.get(result, 0) + 1
        print(f"  id={b.get('id'):<10} result={result:<20} "
              f"branch={b.get('sourceBranch', '?'):<40} "
              f"finish={b.get('finishTime', '?')}")

    total = len(builds)
    print(f"\nSummary:")
    for r, c in sorted(counts.items()):
        pct = (c / total) * 100
        print(f"  {r}: {c}/{total} ({pct:.0f}%)")

    non_success = total - counts.get("succeeded", 0)
    if non_success / total > 0.5:
        print(f"\n[FLAKE] {non_success}/{total} non-succeeded - likely repo-wide flake.")


# ---------------------------------------------------------------------------
# argparse main
# ---------------------------------------------------------------------------


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="ado-pr-cli",
        description="All-in-one Azure DevOps PR CLI for AKS",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # Shared args helper
    def add_common_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--org", default=DEFAULT_ORG, help=f"ADO organization (default: {DEFAULT_ORG})")
        p.add_argument("--project", default=DEFAULT_PROJECT, help=f"ADO project (default: {DEFAULT_PROJECT})")
        p.add_argument("--repo", default=DEFAULT_REPO, help=f"Repository name (default: {DEFAULT_REPO})")

    # fetch
    p_fetch = sub.add_parser("fetch", help="Fetch PR data and create worktree for review")
    p_fetch.add_argument("repo", help="Repository name (e.g., aks-rp)")
    p_fetch.add_argument("pr_id", help="Pull request ID")
    p_fetch.add_argument("--org", default=DEFAULT_ORG)
    p_fetch.add_argument("--project", default=DEFAULT_PROJECT)
    p_fetch.set_defaults(func=cmd_fetch)

    # cleanup
    p_cleanup = sub.add_parser("cleanup", help="Remove PR worktree and data")
    p_cleanup.add_argument("repo", help="Repository name")
    p_cleanup.add_argument("pr_id", help="Pull request ID")
    p_cleanup.set_defaults(func=cmd_cleanup)

    # threads
    p_threads = sub.add_parser("threads", help="List human review comments on a PR")
    p_threads.add_argument("pr", help="PR URL or numeric ID")
    p_threads.add_argument("--json", action="store_true", help="Output as JSON")
    add_common_args(p_threads)
    p_threads.set_defaults(func=cmd_threads)

    # post-comment
    p_post = sub.add_parser("post-comment", help="Post inline review comments from JSON")
    p_post.add_argument("pr", help="PR URL or numeric ID")
    p_post.add_argument("json_file", help="Path to JSON file with comment array")
    add_common_args(p_post)
    p_post.set_defaults(func=cmd_post_comment)

    # status
    p_status = sub.add_parser("status", help="Show PR status, policies, and reviewers")
    p_status.add_argument("pr", help="PR URL or numeric ID")
    p_status.add_argument("--full", action="store_true",
                          help="Also write /tmp/pr-{id}-policies-full.json with the full API shape")
    add_common_args(p_status)
    p_status.set_defaults(func=cmd_status)

    # pr-url
    p_prurl = sub.add_parser("pr-url", help="Print the canonical full ADO PR URL for a PR URL or bare id")
    p_prurl.add_argument("pr", help="PR URL or numeric ID")
    add_common_args(p_prurl)
    p_prurl.set_defaults(func=cmd_pr_url)

    # diff
    p_diff = sub.add_parser("diff", help="Fetch PR diff and metadata to local files")
    p_diff.add_argument("pr", help="PR URL or numeric ID")
    p_diff.add_argument("--outdir", default="/tmp/pr-diff", help="Output directory (default: /tmp/pr-diff)")
    add_common_args(p_diff)
    p_diff.set_defaults(func=cmd_diff)

    # requeue-policy
    p_req = sub.add_parser("requeue-policy", help="Re-queue PR policy evaluations")
    p_req.add_argument("pr", help="PR URL or numeric ID")
    p_req.add_argument("--eval-id", action="append", default=[],
                       help="Specific evaluation ID to re-queue (repeatable)")
    p_req.add_argument("--all-broken", action="store_true",
                       help="Re-queue every policy with status=broken")
    p_req.add_argument("--include-not-started", action="store_true",
                       help="Also re-queue policies with status=notStarted")
    p_req.add_argument("--dry-run", action="store_true",
                       help="Print targets without calling the API")
    add_common_args(p_req)
    p_req.set_defaults(func=cmd_requeue_policy)

    # reply-thread
    p_reply = sub.add_parser("reply-thread", help="Post a reply to a PR thread")
    p_reply.add_argument("pr", help="PR URL or numeric ID")
    p_reply.add_argument("thread_id", help="Thread ID to reply to")
    p_reply.add_argument("message", help="Reply message body")
    p_reply.add_argument("--dry-run", action="store_true")
    add_common_args(p_reply)
    p_reply.set_defaults(func=cmd_reply_thread)

    # resolve-thread
    p_res = sub.add_parser("resolve-thread", help="Change the status of a PR thread")
    p_res.add_argument("pr", help="PR URL or numeric ID")
    p_res.add_argument("thread_id", help="Thread ID to update")
    p_res.add_argument("--status", default="fixed",
                       help="New status (fixed|closed|active|wontFix|pending|byDesign)")
    p_res.add_argument("--dry-run", action="store_true")
    add_common_args(p_res)
    p_res.set_defaults(func=cmd_resolve_thread)

    # build-failures
    p_bf = sub.add_parser("build-failures",
                          help="Show failed task details for failed PR builds")
    p_bf.add_argument("pr", help="PR URL or numeric ID")
    p_bf.add_argument("--def-id", help="Limit to a single build definition ID")
    add_common_args(p_bf)
    p_bf.set_defaults(func=cmd_build_failures)

    # trigger-build
    p_tb = sub.add_parser("trigger-build",
                          help="Manually queue a build for a PR's source branch")
    p_tb.add_argument("pr", help="PR URL or numeric ID")
    p_tb.add_argument("build_def_id", help="Build definition ID to queue")
    p_tb.add_argument("--dry-run", action="store_true")
    add_common_args(p_tb)
    p_tb.set_defaults(func=cmd_trigger_build)

    # flake-check
    p_fc = sub.add_parser("flake-check",
                          help="Show recent build results to spot repo-wide flakes")
    p_fc.add_argument("build_def_id", help="Build definition ID to inspect")
    p_fc.add_argument("--top", type=int, default=10, help="How many recent builds (default 10)")
    p_fc.add_argument("--org", default=DEFAULT_ORG)
    p_fc.add_argument("--project", default=DEFAULT_PROJECT)
    p_fc.set_defaults(func=cmd_flake_check)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
