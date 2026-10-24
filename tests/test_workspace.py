from gongcao.config import Config
from gongcao.github import command
from gongcao.model import Role
from gongcao.workspace import context


async def test_pr_context_contains_exact_base_to_head_diff(store, task_id, repo, sha):
    (repo / "sample.txt").write_text("changed in PR\n")
    await command("git", "add", "sample.txt", cwd=str(repo))
    await command("git", "commit", "-qm", "PR change", cwd=str(repo))
    head = (await command("git", "rev-parse", "HEAD", cwd=str(repo))).strip()
    task = store.task(task_id)
    task["target_sha"] = head
    task["snapshot"] |= {"base_sha": sha, "head_sha": head}
    data, digest = await context(repo, task, Role.ANALYST, Config(), None)
    assert data["diff"]["base_sha"] == sha
    assert data["diff"]["head_sha"] == head
    assert "+changed in PR" in data["diff"]["patch"]
    assert "-original" in data["diff"]["patch"]
    assert len(digest) == len(data["diff"]["sha256"]) == 64
