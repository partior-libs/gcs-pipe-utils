#!/usr/bin/env python3
"""
Placeholder tracing for DPMC.

Values in the overriding values / secrets files set to the marker '__TBU__'
(whole value or part of a string) get their YAML path appended: '__TBU:<yaml.path>__', e.g.
'__TBU:node.tessera.db.url__', '__TBU:nodes[2].tmUrl__', '__TBU:tessera-db-creds.data.password__'.

The '__TBU:...__' form passes through `helm template` and dpmc.py unchanged, so it ends up
in the podman-ready manifest as-is, where it can be cross-checked against the Helm values.

Helpers used by dpmc.py:
  - scan_placeholders(): which placeholder paths appear in the compiled documents
  - apply_dummy_values(): replaces placeholders with deployable dummy values, for the copy
    used by `podman kube play` validation (placeholders in integer/boolean/base64 fields
    would otherwise be rejected).
"""

import argparse
import base64
import os
import re
from ruamel.yaml import YAML

MARKER = "__TBU__"
PLACEHOLDER_RE = re.compile(r"__TBU:(\S+?)__")

DUMMY_STRING = "dummy"
DUMMY_INT = 1
DUMMY_BOOL = False
DUMMY_BASE64 = base64.b64encode(DUMMY_STRING.encode()).decode()

# K8s fields that must be integers / booleans for `podman kube play` to parse the manifest.
INT_FIELDS = {
    "containerPort", "hostPort", "port", "nodePort", "replicas",
    "runAsUser", "runAsGroup", "fsGroup",
    "initialDelaySeconds", "periodSeconds", "timeoutSeconds", "failureThreshold",
    "successThreshold", "terminationGracePeriodSeconds", "defaultMode", "mode",
}
BOOL_FIELDS = {
    "readOnly", "readOnlyRootFilesystem", "privileged", "allowPrivilegeEscalation",
    "runAsNonRoot", "optional", "hostNetwork", "hostPID", "hostIPC", "stdin", "tty",
}


def placeholder(path: str) -> str:
    return f"__TBU:{path}__"


def _yaml() -> YAML:
    y = YAML()
    y.preserve_quotes = True
    y.indent(mapping=2, sequence=4, offset=2)
    y.width = 4096
    return y


# --- Annotation (before helm template) ---

def annotate_tree(node, paths: list, path: str = ""):
    """Replaces every MARKER occurrence (whole or partial value) with '__TBU:<path>__'."""
    if isinstance(node, dict):
        items = [(k, f"{path}.{k}" if path else str(k)) for k in node.keys()]
    elif isinstance(node, list):
        items = [(i, f"{path}[{i}]") for i in range(len(node))]
    else:
        return
    for key, child in items:
        v = node[key]
        if isinstance(v, str):
            if MARKER in v:
                node[key] = v.replace(MARKER, placeholder(child))
                if child not in paths:
                    paths.append(child)
        else:
            annotate_tree(v, paths, child)


def annotate_values_file(src: str, dst: str, paths: list):
    """Values file: paths are from the file root, e.g. 'node.tessera.db.url', 'nodes[2].tmUrl'."""
    y = _yaml()
    with open(src) as f:
        data = y.load(f)
    annotate_tree(data, paths)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w") as f:
        y.dump(data, f)


def _secret_docs(docs: list):
    """Yields (name, doc) for each resource in a multi-doc stream, unwrapping kind: List."""
    for idx, doc in enumerate(docs):
        if not isinstance(doc, dict):
            continue
        members = doc.get("items") or [] if doc.get("kind") == "List" else [doc]
        for item in members:
            if isinstance(item, dict):
                yield item.get("metadata", {}).get("name") or f"doc{idx}", item


def annotate_secrets_file(src: str, dst: str, paths: list):
    """Secrets file: paths are prefixed by the Secret name, e.g. 'tessera-db-creds.data.password'."""
    y = _yaml()
    with open(src) as f:
        docs = [d for d in y.load_all(f) if d is not None]
    for name, doc in _secret_docs(docs):
        annotate_tree(doc, paths, name)
    os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
    with open(dst, "w") as f:
        y.dump_all(docs, f)


# --- Helpers for dpmc.py (after compilation) ---

def _strings(node):
    """Yields (container, key, value) for every string value in a nested structure."""
    if isinstance(node, dict):
        items = list(node.items())
    elif isinstance(node, list):
        items = list(enumerate(node))
    else:
        return
    for k, v in items:
        if isinstance(v, str):
            yield node, k, v
        else:
            yield from _strings(v)


def scan_placeholders(documents: list) -> set:
    """Returns the set of placeholder paths present in the documents."""
    found = set()
    for doc in documents:
        for _, _, v in _strings(doc):
            found.update(PLACEHOLDER_RE.findall(v))
    return found


def has_bare_marker(documents: list) -> bool:
    """True if an un-annotated '__TBU__' (no path) is present in the documents."""
    return any(MARKER in v for doc in documents for _, _, v in _strings(doc))


def _dummy_for(key, value: str, in_secret_data: bool):
    whole = PLACEHOLDER_RE.fullmatch(value.strip()) is not None
    if whole and key in INT_FIELDS:
        return DUMMY_INT
    if whole and key in BOOL_FIELDS:
        return DUMMY_BOOL
    if in_secret_data:
        return DUMMY_BASE64  # Secret.data must be valid base64
    return PLACEHOLDER_RE.sub(DUMMY_STRING, value)


def apply_dummy_values(documents: list):
    """In-place: replaces placeholders with type-appropriate dummy values."""
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        is_secret = doc.get("kind") == "Secret"
        for container, k, v in list(_strings(doc)):
            if PLACEHOLDER_RE.search(v):
                in_data = is_secret and container is doc.get("data")
                container[k] = _dummy_for(k, v, in_data)


def main():
    parser = argparse.ArgumentParser(
        description=f"Replace '{MARKER}' in values/secrets files with '__TBU:<yaml.path>__'."
    )
    parser.add_argument("--values", nargs="*", default=[], help="Helm values file(s) to annotate.")
    parser.add_argument("--secrets", nargs="*", default=[], help="Secrets file(s) to annotate.")
    parser.add_argument("--out-dir", required=True, help="Directory for the annotated copies.")
    parser.add_argument("--paths-file", required=True,
                        help="Output file listing every placeholder path, one per line.")
    args = parser.parse_args()

    paths = []
    for src in args.values:
        annotate_values_file(src, os.path.join(args.out_dir, os.path.basename(src)), paths)
    for src in args.secrets:
        annotate_secrets_file(src, os.path.join(args.out_dir, os.path.basename(src)), paths)

    os.makedirs(os.path.dirname(args.paths_file) or ".", exist_ok=True)
    with open(args.paths_file, "w") as f:
        f.writelines(f"{p}\n" for p in paths)
    print(f"Annotated {len(paths)} placeholder path(s); list written to '{args.paths_file}'")
    for p in paths:
        print(f"  {placeholder(p)}")


if __name__ == "__main__":
    main()
