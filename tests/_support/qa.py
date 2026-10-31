from qa.ledger import Run


def new_run(tmp_path, scenario="loop"):
    return Run.create(
        tmp_path,
        scenario,
        "a" * 40,
        repository="example/demo",
        github_login="qa",
        base_branch="main",
        base_sha="a" * 40,
    )


def base_response(run, path):
    if path == "repos/example/demo":
        return {"default_branch": run.value["base_branch"]}
    if path == "repos/example/demo/git/ref/heads/main":
        return {"object": {"sha": run.value["base_sha"]}}
    return None
