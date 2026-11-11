import io

from ruamel.yaml import YAML

from placeholders import (
    MARKER, DUMMY_BASE64, annotate_tree, annotate_values_file, annotate_secrets_file,
    apply_dummy_values, has_bare_marker, scan_placeholders,
)


def test_annotate_whole_partial_and_list_paths():
    data = {
        "global": {"secrets": {"create": MARKER}, "keep": "real-value"},
        "db": {"url": f"jdbc:{MARKER}:1521"},
        "nodes": [{"tmUrl": "a"}, {"tmUrl": MARKER}],
    }
    paths = []
    annotate_tree(data, paths)
    assert paths == ["global.secrets.create", "db.url", "nodes[1].tmUrl"]
    assert data["global"]["secrets"]["create"] == "__TBU:global.secrets.create__"
    assert data["global"]["keep"] == "real-value"
    assert data["db"]["url"] == "jdbc:__TBU:db.url__:1521"
    assert data["nodes"][1]["tmUrl"] == "__TBU:nodes[1].tmUrl__"


def test_scan_placeholders():
    docs = [{"kind": "ConfigMap", "data": {
        "a": "__TBU:x.y__",
        "b": "http://__TBU:nodes[2].tmUrl__:8545/__TBU:x.y__",
        "c": "__init__ is not a placeholder",
    }}]
    assert scan_placeholders(docs) == {"x.y", "nodes[2].tmUrl"}


def test_has_bare_marker():
    assert has_bare_marker([{"kind": "ConfigMap", "data": {"a": "x-__TBU__"}}])
    assert not has_bare_marker([{"kind": "ConfigMap", "data": {"a": "__TBU:x.y__"}}])


def test_apply_dummy_values_is_type_aware():
    deploy = {"kind": "Deployment", "spec": {"template": {"spec": {"containers": [{
        "image": "__TBU:node.image__:latest",
        "ports": [{"containerPort": "__TBU:node.port__"}],
        "securityContext": {"readOnlyRootFilesystem": "__TBU:node.ro__"},
    }]}}}}
    secret = {"kind": "Secret", "metadata": {"name": "__TBU:s.name__"},
              "data": {"password": "__TBU:s.data.password__", "username": "YWRtaW4="}}
    apply_dummy_values([deploy, secret])
    c = deploy["spec"]["template"]["spec"]["containers"][0]
    assert c["ports"][0]["containerPort"] == 1
    assert c["securityContext"]["readOnlyRootFilesystem"] is False
    assert c["image"] == "dummy:latest"
    assert secret["data"] == {"password": DUMMY_BASE64, "username": "YWRtaW4="}
    assert secret["metadata"]["name"] == "dummy"


def test_annotate_files(tmp_path):
    values = tmp_path / "values.yaml"
    values.write_text(f'node:\n  db:\n    url: "{MARKER}"\n    dialect: oracle\n')
    secrets = tmp_path / "secrets.yaml"
    secrets.write_text(
        "apiVersion: v1\nkind: List\nitems:\n"
        "- apiVersion: v1\n  kind: Secret\n  metadata:\n    name: db-creds\n"
        f'  data:\n    password: "{MARKER}"\n    username: YWRtaW4=\n'
    )
    paths = []
    annotate_values_file(str(values), str(tmp_path / "out" / "values.yaml"), paths)
    annotate_secrets_file(str(secrets), str(tmp_path / "out" / "secrets.yaml"), paths)
    assert paths == ["node.db.url", "db-creds.data.password"]

    out = (tmp_path / "out" / "values.yaml").read_text()
    assert "__TBU:node.db.url__" in out and "dialect: oracle" in out
    sec = list(YAML().load_all(io.StringIO((tmp_path / "out" / "secrets.yaml").read_text())))
    assert sec[0]["items"][0]["data"] == {"password": "__TBU:db-creds.data.password__", "username": "YWRtaW4="}
