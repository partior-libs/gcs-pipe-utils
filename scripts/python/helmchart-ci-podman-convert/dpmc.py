#!/usr/bin/env python3
"""
Deterministic Podman Manifest Compiler (DPMC)
A single-file cohesive utility to compile and sanitize Kubernetes manifests 
and secrets for deployment on local VMs using rootless Podman kube play.
"""

import argparse
import copy
import os
import posixpath
import re
import shlex
import shutil
import subprocess
import sys
from ruamel.yaml import YAML

from placeholders import MARKER, apply_dummy_values, has_bare_marker, scan_placeholders

# --- Tool-relative locations (so the tool works from any working directory) ---
TOOL_ROOT = os.path.dirname(os.path.abspath(__file__))
DEFAULT_BASE_CONFIG = os.path.join(TOOL_ROOT, "compiler-config.yaml")
DEFAULT_SUPPORT_DOC = os.path.join(TOOL_ROOT, "doc", "podman-kube-play-support.md")


# --- Custom Exception ---
class DPMCError(Exception):
    pass

# --- System Directory Protection (Limitation ID 14) ---
def check_system_overlays(documents: list):
    """
    Ensures that no hostPath volume mounts point directly to protected directories like /etc.
    Rootless Podman fails silently or crashes on such mounts.
    """
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        
        kind = doc.get("kind")
        if kind in ["Deployment", "Pod"]:
            spec = doc.get("spec", {})
            pod_spec = spec.get("template", {}).get("spec", {}) if kind == "Deployment" else spec
            if not pod_spec:
                continue

            volumes = pod_spec.get("volumes", [])
            for volume in volumes:
                if not isinstance(volume, dict):
                    continue
                
                host_path = volume.get("hostPath")
                if host_path and isinstance(host_path, dict):
                    path = host_path.get("path", "")
                    if path == "/etc" or path.startswith("/etc/"):
                        name = doc.get("metadata", {}).get("name", "unnamed")
                        raise DPMCError(
                            f"COMPILE ERROR [Limitation ID 14]: Resource '{name}' has a hostPath mount "
                            f"pointing directly to protected system directory '{path}'. "
                            f"In rootless Podman, mounting writable host paths to system folders causes "
                            f"unlogged OCI runtime silent crashes. "
                            f"FIX: Refactor destination directories to unprivileged zones (e.g., '/etc-override/')."
                        )

# --- Duplicate Resources ---
def deduplicate_resources(documents: list) -> list:
    """
    Keeps only the last definition of each kind/name. Secrets files are loaded after the
    Helm output, so a Secret from the secrets file overrides a same-named one rendered by Helm.
    """
    last_index = {}
    for idx, doc in enumerate(documents):
        if isinstance(doc, dict) and doc.get("metadata", {}).get("name"):
            last_index[(doc.get("kind"), doc["metadata"]["name"])] = idx

    result = []
    for idx, doc in enumerate(documents):
        if isinstance(doc, dict) and doc.get("metadata", {}).get("name"):
            key = (doc.get("kind"), doc["metadata"]["name"])
            if last_index[key] != idx:
                print(f"  WARNING: {key[0]}/{key[1]} is defined more than once; keeping the last definition "
                      f"(secrets file overrides Helm output)")
                continue
        result.append(doc)
    return result


# --- Filter Allowed Kinds (CRD Purging) ---
def filter_allowed_kinds(documents: list, allowed_kinds: list) -> list:
    """
    Drops any resources that are not explicitly whitelisted (e.g. CRDs, Certs, ExternalSecrets).
    """
    if allowed_kinds is None:
        return documents
    
    allowed = set(allowed_kinds)
    filtered = []
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind in allowed:
            filtered.append(doc)
    return filtered

# StatefulSet spec fields with no Deployment equivalent (volumeClaimTemplates is converted separately)
STATEFULSET_ONLY_FIELDS = ("serviceName", "podManagementPolicy", "updateStrategy",
                           "persistentVolumeClaimRetentionPolicy", "ordinals")


# --- StatefulSet Demotion & Storage Configuration (Limitation ID 3 & 5) ---
def convert_statefulsets_and_setup_storage(documents: list, storage_config: dict) -> list:
    """
    Demotes StatefulSets to Deployments, forces replicas to 1, and processes storage 
    configuration based on selected mode ('host_path' or 'local_volume').
    """
    mode = storage_config.get("mode", "local_volume")
    host_root_dir = storage_config.get("host_root_dir", "/home/user/podman-storage").rstrip("/")
    
    updated_documents = []
    
    # 1. If in host_path mode, drop standard standalone PVC documents from final stream
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if mode == "host_path" and kind == "PersistentVolumeClaim":
            continue
        updated_documents.append(doc)

    # 2. Main transformation pass
    additional_documents = []
    for doc in updated_documents:
        kind = doc.get("kind")
        metadata = doc.get("metadata", {})
        name = metadata.get("name", "app")
        spec = doc.get("spec", {})

        # Enforce replica scale-down for Deployments & StatefulSets
        if kind in ["Deployment", "StatefulSet"]:
            if "replicas" in spec:
                spec["replicas"] = 1

        if kind == "StatefulSet":
            # Demote kind, and drop fields that only exist on StatefulSets
            doc["kind"] = "Deployment"
            for field in STATEFULSET_ONLY_FIELDS:
                spec.pop(field, None)
            
            # Extract volumeClaimTemplates (VCT)
            volume_claim_templates = spec.pop("volumeClaimTemplates", [])
            if volume_claim_templates:
                template_spec = spec.get("template", {}).get("spec", {})
                if "volumes" not in template_spec:
                    template_spec["volumes"] = []
                
                for vct in volume_claim_templates:
                    vct_name = vct.get("metadata", {}).get("name")
                    if not vct_name:
                        continue
                    
                    pvc_name = f"{vct_name}-{name}-0"
                    
                    if mode == "host_path":
                        # Directly map to host path subdirectory
                        volume_entry = {
                            "name": vct_name,
                            "hostPath": {
                                "path": f"{host_root_dir}/{pvc_name}",
                                "type": "DirectoryOrCreate"
                            }
                        }
                    else:
                        # local_volume mode: Create PVC document
                        pvc_doc = {
                            "apiVersion": "v1",
                            "kind": "PersistentVolumeClaim",
                            "metadata": {
                                "name": pvc_name
                            },
                            "spec": vct.get("spec", {})
                        }
                        if "spec" in pvc_doc and "storageClassName" in pvc_doc["spec"]:
                            del pvc_doc["spec"]["storageClassName"]
                        
                        # Add PVC to additional documents
                        additional_documents.append(pvc_doc)
                        
                        volume_entry = {
                            "name": vct_name,
                            "persistentVolumeClaim": {
                                "claimName": pvc_name
                            }
                        }
                    
                    # Add to volumes if not already present
                    if not any(v.get("name") == vct_name for v in template_spec["volumes"]):
                        template_spec["volumes"].append(volume_entry)

        # Map existing standalone PVC references to hostPath if in host_path mode
        if mode == "host_path" and kind in ["Deployment", "Pod"]:
            pod_spec = spec.get("template", {}).get("spec", {}) if kind == "Deployment" else spec
            if pod_spec:
                volumes = pod_spec.get("volumes", [])
                for volume in volumes:
                    if not isinstance(volume, dict):
                        continue
                    pvc_ref = volume.get("persistentVolumeClaim")
                    if pvc_ref and isinstance(pvc_ref, dict):
                        claim_name = pvc_ref.get("claimName")
                        if claim_name:
                            del volume["persistentVolumeClaim"]
                            volume["hostPath"] = {
                                "path": f"{host_root_dir}/{claim_name}",
                                "type": "DirectoryOrCreate"
                            }
        
        # Strip storageClassName in local_volume mode for any standalone PVCs
        if mode == "local_volume" and kind == "PersistentVolumeClaim":
            if "spec" in doc and "storageClassName" in doc["spec"]:
                del doc["spec"]["storageClassName"]

    updated_documents.extend(additional_documents)

    # Deduplicate standard PVC additions in case they were appended
    final_docs = []
    seen_pvc = set()
    for d in updated_documents:
        if d.get("kind") == "PersistentVolumeClaim":
            pvc_name = d.get("metadata", {}).get("name")
            if pvc_name in seen_pvc:
                continue
            seen_pvc.add(pvc_name)
        final_docs.append(d)

    return final_docs

# --- Overlapping & Nested Volume Mounts (Limitation ID 13) ---
SHELLS = {"sh", "bash", "ash", "dash"}


def prepend_command_to_container(container: dict, script: str) -> bool:
    """
    Makes `script` run before the container's own command. Returns False (and changes nothing)
    when the container has no explicit `command`, since the image ENTRYPOINT is unknown and
    replacing it would stop the real process from starting.
    """
    if not script:
        return True
    command = list(container.get("command") or [])
    args = list(container.get("args") or [])
    if not command:
        return False

    parts = command + args
    if len(parts) >= 3 and posixpath.basename(str(parts[0])) in SHELLS and parts[1] == "-c":
        # Shell form (`sh -c <script>`, split across command/args in any way): prefix the script
        new_script = f"{script} && {parts[2]}"
        if len(command) > 2:
            command[2] = new_script
        else:
            args[2 - len(command)] = new_script
        container["command"] = command
        if args:
            container["args"] = args
        return True

    # Exec form: wrap in a shell and exec the original command line, safely quoted
    container["command"] = ["sh", "-c"]
    container["args"] = [f"{script} && exec {shlex.join(str(p) for p in parts)}"]
    return True


def _pod_spec(doc: dict):
    """Returns the pod spec of a Deployment/Pod document, else None."""
    if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "Pod"):
        return None
    spec = doc.get("spec") or {}
    pod_spec = (spec.get("template") or {}).get("spec") if doc["kind"] == "Deployment" else spec
    return pod_spec if isinstance(pod_spec, dict) else None


def _all_containers(pod_spec: dict) -> list:
    return [c for c in (pod_spec.get("initContainers") or []) + (pod_spec.get("containers") or [])
            if isinstance(c, dict)]


def _path_re(path: str):
    """Matches `path` as a whole path (or a prefix of a longer path), not as part of another path."""
    return re.compile(r"(?<![A-Za-z0-9_.-])" + re.escape(path.rstrip("/")) + r"(?![A-Za-z0-9_.-])")


def _rewrite_strings(node, replacements: list, skip_keys=()):
    """In-place: applies [(compiled_regex, new_path)] to every string in a nested structure."""
    if isinstance(node, dict):
        items = [(k, v) for k, v in node.items() if k not in skip_keys]
    elif isinstance(node, list):
        items = list(enumerate(node))
    else:
        return
    for k, v in items:
        if isinstance(v, str):
            for regex, new in replacements:
                v = regex.sub(new, v)
            node[k] = v
        else:
            _rewrite_strings(v, replacements)


def _referenced_config(pod_spec: dict) -> set:
    """(kind, name) of every ConfigMap/Secret a pod uses through volumes, envFrom or env valueFrom."""
    refs = set()
    for v in pod_spec.get("volumes") or []:
        if not isinstance(v, dict):
            continue
        if isinstance(v.get("configMap"), dict):
            refs.add(("ConfigMap", v["configMap"].get("name")))
        if isinstance(v.get("secret"), dict):
            refs.add(("Secret", v["secret"].get("secretName")))
        for src in ((v.get("projected") or {}).get("sources") or []):
            if isinstance(src.get("configMap"), dict):
                refs.add(("ConfigMap", src["configMap"].get("name")))
            if isinstance(src.get("secret"), dict):
                refs.add(("Secret", src["secret"].get("name")))
    for c in _all_containers(pod_spec):
        for ef in c.get("envFrom") or []:
            if isinstance(ef.get("configMapRef"), dict):
                refs.add(("ConfigMap", ef["configMapRef"].get("name")))
            if isinstance(ef.get("secretRef"), dict):
                refs.add(("Secret", ef["secretRef"].get("name")))
        for e in c.get("env") or []:
            vf = (e or {}).get("valueFrom") or {}
            if isinstance(vf.get("configMapKeyRef"), dict):
                refs.add(("ConfigMap", vf["configMapKeyRef"].get("name")))
            if isinstance(vf.get("secretKeyRef"), dict):
                refs.add(("Secret", vf["secretKeyRef"].get("name")))
    return refs


def relocate_etc_data_mounts(documents: list, etc_mount_prefix: str) -> list:
    """
    Limitation ID 14: moves writable volumes (hostPath, PVC, emptyDir, ...) mounted under /etc to
    <etc_mount_prefix>/..., and rewrites every reference to the old path instead of symlinking it back:
      - mounts at or below the moved path (in every container of the pod) move with it;
      - container command/args/env/probes of that pod;
      - ConfigMap data / Secret stringData used only by pods that moved the same path.
    Nothing is written under /etc at runtime, so this works with readOnlyRootFilesystem.
    Secret/configMap mounts under /etc are left where they are.
    """
    if not etc_mount_prefix:
        return documents
    prefix = etc_mount_prefix.rstrip("/")

    def new_path(path: str) -> str:
        return prefix + path[len("/etc"):]

    pod_roots = {}  # id(doc) -> [root path]
    for doc in documents:
        pod_spec = _pod_spec(doc)
        if not pod_spec:
            continue
        volume_types = {v.get("name"): next((k for k in v if k != "name"), None)
                        for v in pod_spec.get("volumes") or [] if isinstance(v, dict)}
        writable = sorted({
            m["mountPath"].rstrip("/") for c in _all_containers(pod_spec) for m in c.get("volumeMounts") or []
            if isinstance(m, dict) and str(m.get("mountPath", "")).startswith("/etc/")
            and volume_types.get(m.get("name")) not in READ_ONLY_VOLUME_TYPES
        })
        roots = [p for p in writable if not any(_is_inside(p, other) for other in writable)]
        if not roots:
            continue
        pod_roots[id(doc)] = roots
        replacements = [(_path_re(r), new_path(r)) for r in roots]
        owner = f"{doc['kind']}/{doc.get('metadata', {}).get('name', '?')}"

        for c in _all_containers(pod_spec):
            moved = False
            for m in c.get("volumeMounts") or []:
                mp = str(m.get("mountPath", "")) if isinstance(m, dict) else ""
                for r in roots:
                    if mp.rstrip("/") == r or _is_inside(mp, r):
                        m["mountPath"] = new_path(r) + mp[len(r):]
                        moved = True
                        break
            _rewrite_strings(c, replacements, skip_keys=("volumeMounts",))
            if moved and not c.get("command"):
                print(f"  WARNING: {owner} container '{c.get('name', '?')}' has no explicit command; if its image "
                      f"uses {', '.join(roots)} internally (not via the manifest), it will not find the moved data")
        print(f"  {owner}: moved {', '.join(f'{r} -> {new_path(r)}' for r in roots)} (references rewritten)")

    # ConfigMaps / Secrets: rewrite a root only if every pod using the object moved that same root
    consumers = {}
    for doc in documents:
        pod_spec = _pod_spec(doc)
        if pod_spec:
            for ref in _referenced_config(pod_spec):
                consumers.setdefault(ref, []).append(pod_roots.get(id(doc), []))
    for doc in documents:
        if not isinstance(doc, dict) or doc.get("kind") not in ("ConfigMap", "Secret"):
            continue
        key = (doc["kind"], doc.get("metadata", {}).get("name"))
        users = consumers.get(key)
        if not users:
            continue
        candidate_roots = {r for roots in users for r in roots}
        field = "data" if doc["kind"] == "ConfigMap" else "stringData"
        payload = doc.get(field)
        if not isinstance(payload, dict):
            continue
        for r in sorted(candidate_roots):
            regex = _path_re(r)
            if not any(isinstance(v, str) and regex.search(v) for v in payload.values()):
                continue
            if all(r in roots for roots in users):
                _rewrite_strings(payload, [(regex, new_path(r))])
            else:
                print(f"  WARNING: {key[0]}/{key[1]} mentions {r} but is shared with a pod that keeps that path; "
                      f"left unchanged")
    return documents


# --- Kubernetes variable expansion in command/args ---
_K8S_VAR_RE = re.compile(r"\$\$|\$\(([A-Za-z_][A-Za-z0-9_]*)\)")


def expand_kubernetes_variables(documents: list) -> list:
    """
    Applies the expansion Kubernetes performs on container command/args before running them
    (Podman does not): `$$` -> `$`, and `$(VAR)` -> the value of env var VAR when it has a literal
    value in that container. Anything else, e.g. `$(wget ...)`, is left unchanged.
    """
    for doc in documents:
        pod_spec = _pod_spec(doc)
        if not pod_spec:
            continue
        for c in _all_containers(pod_spec):
            env = {e.get("name"): str(e["value"]) for e in c.get("env") or []
                   if isinstance(e, dict) and "value" in e}

            def expand(m):
                if m.group(0) == "$$":
                    return "$"
                return env.get(m.group(1), m.group(0))

            for field in ("command", "args"):
                values = c.get(field)
                if isinstance(values, list):
                    for i, v in enumerate(values):
                        if isinstance(v, str):
                            values[i] = _K8S_VAR_RE.sub(expand, v)
    return documents


READ_ONLY_VOLUME_TYPES = {"configMap", "secret", "downwardAPI", "projected"}


def _is_inside(child: str, parent: str) -> bool:
    """True if path `child` is strictly inside directory `parent`."""
    parent_dir = parent.rstrip("/") + "/"
    return child.rstrip("/") != parent.rstrip("/") and child.startswith(parent_dir)


def _link_command(src: str, target: str, create_src: bool) -> str:
    """
    Shell snippet that points `target` at `src`. Never deletes data: an existing empty directory
    at `target` is removed with rmdir; a non-empty one makes rmdir fail, stopping the container.
    """
    parts = []
    if create_src:
        parts.append(f"mkdir -p {src}")  # a subPath directory K8s would have created
    parts.append(f"mkdir -p {posixpath.dirname(target.rstrip('/'))}")
    parts.append(f"if [ -d {target} ] && [ ! -L {target} ]; then rmdir {target}; fi")
    parts.append(f"ln -sfn {src} {target}")
    return " && ".join(parts)


def _copy_command(src: str, target: str) -> str:
    """
    Shell snippet that copies `src` (file or directory, following symlinks) to `target`, so the copy
    belongs to the running user and can be chmod'ed (e.g. a private key that must be 0600). A stale
    symlink at `target` is replaced; a non-empty directory where a file should go stops the container.
    """
    return " && ".join([
        f"mkdir -p {posixpath.dirname(target.rstrip('/'))}",
        f"if [ -L {target} ]; then rm -f {target}; fi",
        f"if [ -d {src} ]; then mkdir -p {target} && cp -RfL {src}/. {target}/; "
        f"else if [ -d {target} ]; then rmdir {target}; fi && cp -fL {src} {target}; fi",
    ])


def _resolve_container_nested_mounts(container: dict, volume_types: dict, staging_root: str, owner: str):
    """
    Replaces every mount nested inside another mount of the same container with:
      - one staging mount per volume at <staging_root>/<volume> (whole volume, no subPath), and
      - a startup step that puts <staging_root>/<volume>/<subPath> at the original mountPath:
          * a Secret nested in an emptyDir is COPIED, so the copy belongs to the running user and can be
            chmod'ed (private keys that must be 0600); emptyDir is ephemeral, so no key reaches disk;
          * everything else is SYMLINKED (configMaps, writable subPath dirs, and Secrets nested in
            persistent volumes, so private keys are never copied into a host folder).
    The links/copies live inside the (writable) parent volume, so this works with readOnlyRootFilesystem.
    """
    name = container.get("name", "?")
    mounts = [m for m in container.get("volumeMounts") or [] if isinstance(m, dict) and m.get("mountPath")]

    nested = []
    parent_type = {}  # id(mount) -> volume type of its nearest parent mount
    for m in mounts:
        parents = [p for p in mounts if p is not m and _is_inside(m["mountPath"], p["mountPath"])]
        if not parents:
            continue
        nearest = max(parents, key=lambda p: len(p["mountPath"]))
        if volume_types.get(nearest.get("name")) in READ_ONLY_VOLUME_TYPES or nearest.get("readOnly"):
            print(f"  WARNING: {owner} container '{name}': '{m['mountPath']}' is nested in read-only mount "
                  f"'{nearest['mountPath']}'; cannot link into it, left as-is")
            continue
        nested.append(m)
        parent_type[id(m)] = volume_types.get(nearest.get("name"))

    if not nested:
        return
    if not container.get("command"):
        print(f"  WARNING: {owner} container '{name}': {len(nested)} nested mount(s) left as-is, because the "
              f"container has no explicit command to prepend the link script to (image ENTRYPOINT unknown)")
        return
    for m in mounts:
        if _is_inside(staging_root, m["mountPath"]):
            raise DPMCError(f"{owner} container '{name}': staging root '{staging_root}' is inside mount "
                            f"'{m['mountPath']}'. Set storage.shadow_mount_prefix to a path outside all mounts.")

    staging_mounts = {}
    commands = []
    for m in sorted(nested, key=lambda m: m["mountPath"].rstrip("/").count("/")):  # parents first
        vol = m["name"]
        staging = f"{staging_root}/{vol}"
        if vol not in staging_mounts:
            staging_mounts[vol] = {"name": vol, "mountPath": staging, "readOnly": True}
        if not m.get("readOnly"):
            staging_mounts[vol]["readOnly"] = False
        src = f"{staging}/{m['subPath'].strip('/')}" if m.get("subPath") else staging
        target = m["mountPath"].rstrip("/")
        if volume_types.get(vol) == "secret" and parent_type[id(m)] == "emptyDir":
            commands.append(_copy_command(src, target))
        else:
            writable = volume_types.get(vol) not in READ_ONLY_VOLUME_TYPES
            commands.append(_link_command(src, target, create_src=writable and bool(m.get("subPath"))))

    nested_ids = {id(m) for m in nested}
    container["volumeMounts"] = [m for m in container["volumeMounts"] if id(m) not in nested_ids]
    for sm in staging_mounts.values():
        if not sm["readOnly"]:
            del sm["readOnly"]
        container["volumeMounts"].append(sm)

    prepend_command_to_container(container, " && ".join(commands))  # command presence checked above


def resolve_overlapping_mounts(documents: list, staging_root: str = "/dpmc-staging") -> list:
    """
    Resolves nested/overlapping volume mounts (Limitation ID 13) in every container and
    initContainer, by staging the nested volumes and symlinking them into place at startup.
    """
    staging_root = staging_root.rstrip("/")
    for doc in documents:
        if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "Pod"):
            continue
        spec = doc.get("spec", {})
        pod_spec = spec.get("template", {}).get("spec", {}) if doc["kind"] == "Deployment" else spec
        if not pod_spec:
            continue

        # Flatten remaining projected volumes (token volumes were removed in the RBAC step)
        _flatten_projected_volumes(pod_spec)

        volume_types = {
            v.get("name"): next((k for k in v if k != "name"), None)
            for v in pod_spec.get("volumes") or [] if isinstance(v, dict)
        }
        owner = f"{doc['kind']}/{doc.get('metadata', {}).get('name', '?')}"
        for container in (pod_spec.get("initContainers") or []) + (pod_spec.get("containers") or []):
            if isinstance(container, dict):
                _resolve_container_nested_mounts(container, volume_types, staging_root, owner)

    return documents

def _flatten_projected_volumes(pod_spec: dict):
    """
    Expands projected volume specifications into standard secret/configMap mappings.
    """
    volumes = pod_spec.get("volumes", [])
    for volume in volumes:
        if not isinstance(volume, dict):
            continue
        projected = volume.get("projected")
        if projected and isinstance(projected, dict):
            del volume["projected"]
            sources = projected.get("sources", [])
            if sources:
                src = sources[0]
                if "secret" in src:
                    volume["secret"] = src["secret"]
                elif "configMap" in src:
                    volume["configMap"] = src["configMap"]

# --- Purge RBAC & Service Accounts (Limitation ID 4) ---
def purge_rbac_and_service_accounts(documents: list) -> list:
    """
    Purges ServiceAccounts, Roles, and RoleBindings. Strips serviceAccountName 
    references and eliminates serviceAccountToken projected volumes.
    """
    rbac_kinds = {
        "ServiceAccount", "Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding"
    }
    
    filtered_docs = []
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        if doc.get("kind") in rbac_kinds:
            continue
        if doc.get("kind") == "Secret" and doc.get("type") == "kubernetes.io/service-account-token":
            continue
        filtered_docs.append(doc)

    for doc in filtered_docs:
        kind = doc.get("kind")
        if kind in ["Deployment", "Pod"]:
            spec = doc.get("spec", {})
            pod_spec = spec.get("template", {}).get("spec", {}) if kind == "Deployment" else spec
            
            if not pod_spec:
                continue

            # Strip serviceAccount parameters
            if "serviceAccountName" in pod_spec:
                del pod_spec["serviceAccountName"]
            if "automountServiceAccountToken" in pod_spec:
                del pod_spec["automountServiceAccountToken"]

            # Remove projected volumes carrying a ServiceAccount token. Their other sources
            # (kube-root-ca.crt ConfigMap, downwardAPI namespace) are cluster API access
            # material that does not exist under Podman either.
            volumes = pod_spec.get("volumes", [])
            vols_to_delete = []
            for volume in volumes:
                if not isinstance(volume, dict):
                    continue
                projected = volume.get("projected")
                if isinstance(projected, dict):
                    sources = projected.get("sources") or []
                    if any(isinstance(src, dict) and "serviceAccountToken" in src for src in sources):
                        vols_to_delete.append(volume.get("name"))

            # Remove token volume definitions
            pod_spec["volumes"] = [v for v in volumes if v.get("name") not in vols_to_delete]

            # Remove container volumeMounts referencing deleted volumes
            if vols_to_delete:
                containers = pod_spec.get("containers", [])
                init_containers = pod_spec.get("initContainers", [])
                for container in (containers + init_containers):
                    if isinstance(container, dict) and "volumeMounts" in container:
                        container["volumeMounts"] = [
                            vm for vm in container["volumeMounts"] if vm.get("name") not in vols_to_delete
                        ]

    return filtered_docs

# --- Sanitize Metadata (Limitation ID 2) ---
def sanitize_metadata(documents: list) -> list:
    """
    Strips namespaces and cluster telemetry tracking properties.
    Label/annotation filtering is done once, at the end, by post_sanitize_labels_and_annotations.
    """
    for doc in documents:
        if not isinstance(doc, dict):
            continue

        metadata = doc.get("metadata", {})
        if isinstance(metadata, dict):
            for k in list(metadata.keys()):
                if k.lower() == "namespace":
                    del metadata[k]
            for field in ["creationTimestamp", "uid", "resourceVersion", "generation", "ownerReferences"]:
                if field in metadata:
                    del metadata[field]

        if "status" in doc:
            del doc["status"]

    return documents

# --- Bridge Network & External Port Exposure (Limitation ID 10 & 15) ---
def _find_container_port(containers: list, target_port):
    """Returns the first container port entry matching a Service targetPort (number or name), or None."""
    for container in containers:
        for cp in container.get("ports") or []:
            if not isinstance(cp, dict):
                continue
            if (isinstance(target_port, int) and cp.get("containerPort") == target_port) or \
               (isinstance(target_port, str) and cp.get("name") == target_port):
                return cp
    return None


def inject_network_and_host_ports(documents: list, network_name: str) -> list:
    """
    Binds all workloads to a shared Podman network annotation and exposes matching Service ports
    locally via container hostPorts.
    """
    services = []
    workloads = []

    for doc in documents:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind == "Service":
            services.append(doc)
        elif kind in ["Deployment", "Pod"]:
            workloads.append(doc)

    # 1. Apply shared network annotation to workloads
    for wl in workloads:
        metadata = wl.get("metadata", {})
        if "annotations" not in metadata or metadata["annotations"] is None:
            metadata["annotations"] = {}
        metadata["annotations"]["io.podman.kube.network"] = network_name

        if wl.get("kind") == "Deployment":
            template = wl.get("spec", {}).get("template", {})
            t_metadata = template.get("metadata", {})
            if "annotations" not in t_metadata or t_metadata["annotations"] is None:
                t_metadata["annotations"] = {}
            t_metadata["annotations"]["io.podman.kube.network"] = network_name

    # 2. Correlate Service ports to workload container ports to map hostPorts
    for svc in services:
        spec = svc.get("spec", {})
        selector = spec.get("selector")
        ports = spec.get("ports", [])
        
        if not selector or not ports:
            continue

        for wl in workloads:
            wl_kind = wl.get("kind")
            wl_metadata = wl.get("metadata", {})
            wl_labels = wl_metadata.get("labels", {})
            
            if wl_kind == "Deployment":
                template = wl.get("spec", {}).get("template", {})
                wl_labels = template.get("metadata", {}).get("labels", {})
                pod_spec = template.get("spec", {})
            else:
                pod_spec = wl.get("spec", {})

            if not pod_spec:
                continue

            # Verify if selector matches workload labels
            is_match = True
            for sel_key, sel_val in selector.items():
                if wl_labels.get(sel_key) != sel_val:
                    is_match = False
                    break
            
            if not is_match:
                continue

            # Port mapping: expose each Service port on the one container that declares it.
            # Containers in a pod share one network namespace, so declaring it on more than one
            # container (e.g. a health sidecar) would duplicate the host port binding.
            containers = [c for c in pod_spec.get("containers", []) if isinstance(c, dict)]
            if not containers:
                continue

            for svc_port_def in ports:
                port_val = svc_port_def.get("port")
                target_port = svc_port_def.get("targetPort", port_val)
                protocol = svc_port_def.get("protocol", "TCP")

                cp = _find_container_port(containers, target_port)
                if cp is not None:
                    cp["hostPort"] = port_val
                    cp["protocol"] = protocol
                elif isinstance(target_port, int):
                    # No container declares it: add it to the first container only
                    if not containers[0].get("ports"):
                        containers[0]["ports"] = []
                    containers[0]["ports"].append({
                        "containerPort": target_port,
                        "hostPort": port_val,
                        "protocol": protocol
                    })

    return documents

# --- DNS Service Name Resolution ---
def inject_dns_service_aliases(documents: list, gateway_ip: str) -> list:
    """
    Extracts all Service names and registers standard K8s FQDN aliases
    as hostAliases in Pods/Deployments pointing to the bridge gateway IP.
    """
    services_dns = []
    for doc in documents:
        if isinstance(doc, dict) and doc.get("kind") == "Service":
            name = doc.get("metadata", {}).get("name")
            if name:
                services_dns.extend([
                    name,
                    f"{name}.default",
                    f"{name}.default.svc",
                    f"{name}.default.svc.cluster.local"
                ])

    if not services_dns:
        return documents

    # Deduplicate and sort
    services_dns = sorted(list(set(services_dns)))
    host_alias_entry = {
        "ip": gateway_ip,
        "hostnames": services_dns
    }

    for doc in documents:
        if not isinstance(doc, dict):
            continue
        
        kind = doc.get("kind")
        if kind in ["Deployment", "Pod"]:
            spec = doc.get("spec", {})
            pod_spec = spec.get("template", {}).get("spec", {}) if kind == "Deployment" else spec
            
            if not pod_spec:
                continue

            if "hostAliases" not in pod_spec:
                pod_spec["hostAliases"] = []

            exists = False
            for entry in pod_spec["hostAliases"]:
                if isinstance(entry, dict) and entry.get("ip") == gateway_ip:
                    cur_hosts = entry.get("hostnames", [])
                    entry["hostnames"] = sorted(list(set(cur_hosts + services_dns)))
                    exists = True
                    break

            if not exists:
                pod_spec["hostAliases"].append(host_alias_entry)

    return documents

# --- RHEL 8 Security Context Cascading & fsGroup (Limitation ID 11 & 12) ---
def cascade_security_contexts(documents: list) -> list:
    """
    Cascades runAsUser/runAsGroup from Pod securityContext to container level.
    Replaces fsGroup with recursive ':U' Podman volume mount annotations.
    """
    for doc in documents:
        if not isinstance(doc, dict):
            continue

        kind = doc.get("kind")
        if kind in ["Deployment", "Pod"]:
            metadata = doc.get("metadata", {})
            spec = doc.get("spec", {})
            
            is_deployment = (kind == "Deployment")
            pod_metadata = metadata
            if is_deployment:
                template = spec.get("template", {})
                pod_metadata = template.get("metadata", {})
                pod_spec = template.get("spec", {})
            else:
                pod_spec = spec

            if not pod_spec:
                continue

            pod_sc = pod_spec.get("securityContext", {})
            if isinstance(pod_sc, dict):
                run_as_user = pod_sc.get("runAsUser")
                run_as_group = pod_sc.get("runAsGroup")
                fs_group = pod_sc.get("fsGroup")

                # Cascade runAsUser/runAsGroup to containers
                if run_as_user is not None or run_as_group is not None:
                    containers = pod_spec.get("containers", [])
                    init_containers = pod_spec.get("initContainers", [])
                    for container in (containers + init_containers):
                        if not isinstance(container, dict):
                            continue
                        if "securityContext" not in container:
                            container["securityContext"] = {}
                        
                        container_sc = container["securityContext"]
                        if isinstance(container_sc, dict):
                            if run_as_user is not None and "runAsUser" not in container_sc:
                                container_sc["runAsUser"] = run_as_user
                            if run_as_group is not None and "runAsGroup" not in container_sc:
                                container_sc["runAsGroup"] = run_as_group

                # Translate fsGroup to volume.podman.io/mount-options
                if fs_group is not None:
                    if "fsGroup" in pod_sc:
                        del pod_sc["fsGroup"]
                    
                    volumes = pod_spec.get("volumes", [])
                    vol_names = [v.get("name") for v in volumes if isinstance(v, dict) and "name" in v]
                    
                    if vol_names:
                        mount_options_val = ",".join([f"{v}:U" for v in vol_names])
                        if "annotations" not in pod_metadata or pod_metadata["annotations"] is None:
                            pod_metadata["annotations"] = {}
                        pod_metadata["annotations"]["volume.podman.io/mount-options"] = mount_options_val

    return documents

# --- Post-Sanitize Labels and Annotations (Limitation ID 6 & 7) ---
ALLOWED_ANNOTATION_PREFIXES = ("io.podman.", "volume.podman.io/", "prometheus.io/")


def _is_unwanted_label(key, value=None) -> bool:
    k = str(key).lower()
    return (
        "consul" in k or "kubernetes" in k or "k8s" in k or "helm" in k or "cert" in k
        or k in ("heritage", "chart", "release", "namespace")
    )


def _is_unwanted_annotation(key, value) -> bool:
    k = str(key).lower()
    return (
        not str(key).startswith(ALLOWED_ANNOTATION_PREFIXES)
        or "consul" in k or "kubernetes" in k or "k8s" in k or "helm" in k
        or "cert" in k or "tls" in k or "truststore" in k or "keystore" in k
        # HTTPS scraping relies on certificate chains that do not exist locally
        or (k == "prometheus.io/scheme" and "https" in str(value).lower())
        or k == "namespace"
    )


def _prune(parent: dict, field: str, is_unwanted) -> None:
    """Removes unwanted entries from parent[field], and drops the field if it ends up empty."""
    mapping = parent.get(field)
    if not isinstance(mapping, dict):
        return
    for key in [k for k, v in mapping.items() if is_unwanted(k, v)]:
        del mapping[key]
    if not mapping:
        del parent[field]


def post_sanitize_labels_and_annotations(documents: list) -> list:
    """
    Cleans third-party, kubernetes, helm, consul, and cert-manager/certificate-related
    labels and annotations from all metadata, spec selectors, and pod templates.
    Annotations are additionally restricted to ALLOWED_ANNOTATION_PREFIXES.
    """
    for doc in documents:
        if not isinstance(doc, dict):
            continue

        metadata = doc.get("metadata", {})
        if isinstance(metadata, dict):
            _prune(metadata, "annotations", _is_unwanted_annotation)
            _prune(metadata, "labels", _is_unwanted_label)

        spec = doc.get("spec", {})
        if not isinstance(spec, dict):
            continue

        selector = spec.get("selector")
        if isinstance(selector, dict):
            _prune(selector, "matchLabels", _is_unwanted_label)
            if "matchLabels" not in selector:
                # Service-style selector (plain key/value map)
                _prune(spec, "selector", _is_unwanted_label)

        template = spec.get("template", {})
        if isinstance(template, dict):
            t_metadata = template.get("metadata", {})
            if isinstance(t_metadata, dict):
                _prune(t_metadata, "annotations", _is_unwanted_annotation)
                _prune(t_metadata, "labels", _is_unwanted_label)

    return documents


# --- Remove Wholly Unsupported Podman Attributes ---
def _clean_pod_spec(pod_spec: dict):
    if not isinstance(pod_spec, dict):
        return

    # 1. Remove affinity
    if "affinity" in pod_spec:
        del pod_spec["affinity"]

    # 2. Remove imagePullSecrets
    if "imagePullSecrets" in pod_spec:
        del pod_spec["imagePullSecrets"]

    # 3. Clean pod securityContext
    sec_ctx = pod_spec.get("securityContext")
    if isinstance(sec_ctx, dict):
        if "fsGroupChangePolicy" in sec_ctx:
            del sec_ctx["fsGroupChangePolicy"]
        if "seccompProfile" in sec_ctx:
            del sec_ctx["seccompProfile"]
        if not sec_ctx:
            del pod_spec["securityContext"]

    # 4. Clean container-level securityContext
    for container_key in ["containers", "initContainers"]:
        containers = pod_spec.get(container_key)
        if isinstance(containers, list):
            for container in containers:
                if isinstance(container, dict):
                    c_sec_ctx = container.get("securityContext")
                    if isinstance(c_sec_ctx, dict):
                        if "seccompProfile" in c_sec_ctx:
                            del c_sec_ctx["seccompProfile"]
                        if not c_sec_ctx:
                            del container["securityContext"]

    # 5. Clean emptyDir sizeLimit in volumes
    volumes = pod_spec.get("volumes")
    if isinstance(volumes, list):
        for volume in volumes:
            if isinstance(volume, dict):
                empty_dir = volume.get("emptyDir")
                if isinstance(empty_dir, dict):
                    if "sizeLimit" in empty_dir:
                        del empty_dir["sizeLimit"]


# Cluster-internal hostnames, e.g. tessera-int-lb.gcp-ghrunner-default.svc.cluster.local or quorum.default.svc
CLUSTER_FQDN_RE = re.compile(r"\b[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*\.svc(?:\.cluster\.local)?\b",
                             re.IGNORECASE)


def _shorten_fqdns_in(text: str) -> str:
    """Replaces only the cluster hostname inside `text` with the short app name; the rest is kept."""
    def short(m):
        host = m.group(0).lower()
        if "tessera" in host:
            return "tessera"
        if "quorum" in host:
            return "quorum"
        return m.group(0)
    return CLUSTER_FQDN_RE.sub(short, text)


def _clean_fqdns(data, in_host_aliases=False):
    """Shortens cluster FQDNs in every string value, except inside hostAliases."""
    if isinstance(data, dict):
        items = list(data.items())
    elif isinstance(data, list):
        items = list(enumerate(data))
    else:
        return
    for k, v in items:
        if k == "hostAliases":
            continue
        if isinstance(v, str):
            if not in_host_aliases:
                data[k] = _shorten_fqdns_in(v)
        else:
            _clean_fqdns(v, in_host_aliases)


def remove_unsupported_podman_attributes(documents: list) -> list:
    """
    Removes attributes from K8s manifests that are wholly unsupported or ignored
    by Podman play kube to prevent schema validation warning messages or unmarshaling issues.
    """
    for doc in documents:
        if not isinstance(doc, dict):
            continue

        # Clean FQDN names in-place
        _clean_fqdns(doc)

        kind = doc.get("kind")

        # Handle Pod specs in Pods or workloads
        if kind == "Pod":
            pod_spec = doc.get("spec")
            if isinstance(pod_spec, dict):
                _clean_pod_spec(pod_spec)
        elif kind in ("Deployment", "DaemonSet", "StatefulSet", "Job"):
            spec = doc.get("spec")
            if isinstance(spec, dict):
                template = spec.get("template")
                if isinstance(template, dict):
                    pod_spec = template.get("spec")
                    if isinstance(pod_spec, dict):
                        _clean_pod_spec(pod_spec)

        # Handle Secrets
        elif kind == "Secret":
            if "immutable" in doc:
                del doc["immutable"]

    return documents


# --- Deterministic Resource Reordering ---
def sort_documents(documents: list, sorting_config: dict) -> list:
    """
    Rearranges the sequence of manifests according to sorting_config.
    - sequence of app (app_sequence): high level sequence for components/apps (e.g. tessera before quorum).
    - sequence of resource (kind_sequence): high level sequence for kinds (e.g. secret, configmap, service before deployment).
    """
    if not isinstance(sorting_config, dict):
        return documents

    app_sequence = sorting_config.get("app_sequence", [])
    kind_sequence = sorting_config.get("kind_sequence", [])

    def get_app_index(doc: dict) -> int:
        if not isinstance(doc, dict):
            return len(app_sequence)
        
        name = doc.get("metadata", {}).get("name", "").lower()
        labels = doc.get("metadata", {}).get("labels", {})
        
        # Convert labels to string representation for easy matching, or match values directly
        label_values = [str(v).lower() for v in labels.values()] if isinstance(labels, dict) else []
        label_keys = [str(k).lower() for k in labels.keys()] if isinstance(labels, dict) else []

        for idx, app in enumerate(app_sequence):
            pattern = ""
            if isinstance(app, dict):
                pattern = app.get("pattern", app.get("name", "")).lower()
            elif isinstance(app, str):
                pattern = app.lower()

            if not pattern:
                continue

            # Match pattern in metadata name
            if pattern in name:
                return idx
            
            # Match pattern in label keys or values
            if any(pattern in l_val for l_val in label_values) or any(pattern in l_key for l_key in label_keys):
                return idx
                
        return len(app_sequence)

    def get_kind_index(doc: dict) -> int:
        if not isinstance(doc, dict):
            return len(kind_sequence)
        
        kind = doc.get("kind", "")
        for idx, k in enumerate(kind_sequence):
            if k.lower() == kind.lower():
                return idx
        return len(kind_sequence)

    def sort_key(doc):
        if not isinstance(doc, dict):
            return (999, 999, "")
        app_idx = get_app_index(doc)
        kind_idx = get_kind_index(doc)
        name = doc.get("metadata", {}).get("name", "")
        return (app_idx, kind_idx, name)

    return sorted(documents, key=sort_key)


# --- Startup Script Syntax Check ---
def _shell_script(container: dict):
    """Returns the script of a `sh -c <script>` container (however split across command/args), else None."""
    parts = list(container.get("command") or []) + list(container.get("args") or [])
    if len(parts) >= 3 and posixpath.basename(str(parts[0])) in SHELLS and parts[1] == "-c":
        return str(parts[2])
    return None


def check_shell_scripts(documents: list, shell: str = "sh") -> int:
    """
    Runs `sh -n` (parse only, nothing is executed) on every `sh -c` startup script. Kubernetes
    `$$` / `$(VAR)` expansion has already been applied by expand_kubernetes_variables.
    Raises DPMCError listing every script with a syntax error. Returns the number of scripts checked.
    """
    sh = shutil.which(shell)
    if not sh:
        print(f"  WARNING: '{shell}' not found; startup script syntax check skipped")
        return 0

    checked, errors = 0, []
    for doc in documents:
        if not isinstance(doc, dict) or doc.get("kind") not in ("Deployment", "Pod"):
            continue
        spec = doc.get("spec", {})
        pod_spec = spec.get("template", {}).get("spec", {}) if doc["kind"] == "Deployment" else spec
        for kind in ("initContainers", "containers"):
            for container in (pod_spec or {}).get(kind) or []:
                script = _shell_script(container) if isinstance(container, dict) else None
                if script is None:
                    continue
                checked += 1
                result = subprocess.run([sh, "-n"], input=script,
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    errors.append(f"{doc['kind']}/{doc.get('metadata', {}).get('name', '?')} "
                                  f"{kind[:-1]} '{container.get('name', '?')}': {result.stderr.strip()}")
    if errors:
        raise DPMCError("Startup script syntax check failed (`sh -n`):\n  " + "\n  ".join(errors))
    return checked


# --- Podman Field Support Report ---
def load_support_tables(path: str) -> dict:
    """Parses the pinned Podman support doc into {section heading: [(field path, support text)]}."""
    sections, current = {}, None
    with open(path) as f:
        for line in f:
            heading = re.match(r"^##\s+(.+?)\s*$", line)
            if heading:
                current = heading.group(1)
                continue
            row = re.match(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$", line)
            if current and row and row.group(1) != "Field" and not set(row.group(1)) <= set("-"):
                sections.setdefault(current, []).append((row.group(1).replace("\\.", "."), row.group(2)))
    return sections


def _values_at(node, parts: list) -> list:
    """Values at a dotted field path, looking through lists (e.g. ports.hostIP on every port)."""
    if not parts:
        return [node]
    if isinstance(node, list):
        return [v for item in node for v in _values_at(item, parts)]
    if isinstance(node, dict) and parts[0] in node:
        return _values_at(node[parts[0]], parts[1:])
    return []


def find_unsupported_fields(documents: list, tables: dict) -> dict:
    """
    Returns {"Kind/name": ["field [container, ...]", ...]} for every field present in the output
    that the Podman support tables mark "no" or "N/A".
    """
    unsupported = {section: [field for field, support in rows if support.lower().startswith(("no", "n/a"))]
                   for section, rows in tables.items()}

    def present(node, field):
        return any(v is not None for v in _values_at(node, field.split(".")))

    report = {}
    for doc in documents:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        owner = f"{kind}/{doc.get('metadata', {}).get('name', '?')}"
        found = []
        if kind == "ConfigMap":
            found += [f for f in unsupported.get("ConfigMap Fields", []) if present(doc, f)]
        if kind in ("PersistentVolumeClaim", "Deployment", "DaemonSet", "Job"):
            found += [f for f in unsupported.get(f"{kind} Fields", []) if present(doc.get("spec") or {}, f)]
        if kind in ("Pod", "Deployment", "DaemonSet", "Job"):
            spec = doc.get("spec") or {}
            pod_spec = spec if kind == "Pod" else (spec.get("template") or {}).get("spec") or {}
            found += [f for f in unsupported.get("Pod Fields", []) if present(pod_spec, f)]
            per_field = {}
            for c in _all_containers(pod_spec):
                for f in unsupported.get("Container Fields", []):
                    if present(c, f):
                        per_field.setdefault(f, []).append(c.get("name", "?"))
            found += [f"{f} [{', '.join(names)}]" for f, names in per_field.items()]
        if found:
            report[owner] = found
    return report


# --- Configuration (base + per-chart overrides) ---
def deep_merge(base, override):
    """Merges `override` into `base`: mappings merge key by key; anything else (incl. lists) is replaced."""
    if isinstance(base, dict) and isinstance(override, dict):
        merged = dict(base)
        for key, value in override.items():
            merged[key] = deep_merge(base[key], value) if key in base else value
        return merged
    return override


def load_config(override_paths: list = None, base_path: str = DEFAULT_BASE_CONFIG) -> dict:
    """
    Loads the base config shipped with the tool, then each override file in order.
    A missing or unreadable file is an error: a silently ignored chart override would compile
    the chart with the wrong settings.
    """
    yaml = YAML()
    config = {}
    for path in [base_path] + list(override_paths or []):
        if os.path.abspath(path) == os.path.abspath(base_path) and config:
            continue  # base passed explicitly as an override too
        if not os.path.exists(path):
            raise DPMCError(f"Config file '{path}' does not exist.")
        try:
            with open(path, "r") as f:
                loaded = yaml.load(f) or {}
        except Exception as e:
            raise DPMCError(f"Failed to load config '{path}': {e}")
        if not isinstance(loaded, dict):
            raise DPMCError(f"Config '{path}' must be a YAML mapping.")
        config = deep_merge(config, loaded)
        print(f"Loaded configuration from '{path}'")
    return config


# --- Compiler Driver ---
class DPMCCompiler:
    def __init__(self, config=None):
        self.yaml = YAML()
        self.yaml.preserve_quotes = True
        self.yaml.indent(mapping=2, sequence=4, offset=2)
        self.yaml.width = 4096
        self.config = config or {}

    def compile(self, manifest_path: str, secrets_path: str, output_path: str,
                placeholder_paths_file: str = None, validation_output_path: str = None,
                support_doc_path: str = DEFAULT_SUPPORT_DOC):
        documents = []

        # 1. Read manifest multi-document stream (can be a file or a directory)
        if os.path.isdir(manifest_path):
            yaml_files = []
            for root, _, files in os.walk(manifest_path):
                for file in files:
                    if file.endswith((".yaml", ".yml")):
                        yaml_files.append(os.path.join(root, file))
            yaml_files.sort()
            for filepath in yaml_files:
                with open(filepath, "r") as f:
                    try:
                        loaded = list(self.yaml.load_all(f))
                        documents.extend([doc for doc in loaded if doc is not None])
                    except Exception as e:
                        raise DPMCError(f"Failed to parse source manifest YAML '{filepath}': {e}")
        else:
            with open(manifest_path, "r") as f:
                try:
                    documents.extend(list(self.yaml.load_all(f)))
                except Exception as e:
                    raise DPMCError(f"Failed to parse source manifest YAML: {e}")

        # 2. Read optional secrets stream
        if secrets_path:
            with open(secrets_path, "r") as f:
                try:
                    secrets = list(self.yaml.load_all(f))
                    for sec in secrets:
                        if not sec:
                            continue
                        # Unpack wraps
                        if isinstance(sec, dict) and sec.get("kind") == "List":
                            documents.extend(sec.get("items", []))
                        else:
                            documents.append(sec)
                except Exception as e:
                    raise DPMCError(f"Failed to parse secrets YAML: {e}")

        # Exclude empty objects
        documents = [d for d in documents if d is not None]

        # 3. Transformation pipeline (order matters; documented in doc/dpmc_design_plan.md)
        storage_config = self.config.get("storage", {})
        network_config = self.config.get("network", {})

        # 3.1  Keep only the last definition of each kind/name (secrets file overrides Helm)
        documents = deduplicate_resources(documents)
        # 3.2  Abort on hostPath mounts into /etc
        check_system_overlays(documents)
        # 3.3  StatefulSet -> Deployment, volumeClaimTemplates -> hostPath / PVC (before kind filtering)
        documents = convert_statefulsets_and_setup_storage(documents, storage_config)
        # 3.4  Drop kinds not in manifests.allowed_kinds
        documents = filter_allowed_kinds(documents, self.config.get("manifests", {}).get("allowed_kinds"))
        # 3.5  Remove ServiceAccounts / RBAC / token volumes (before projected volumes are flattened in 3.8)
        documents = purge_rbac_and_service_accounts(documents)
        # 3.6  Kubernetes $$ / $(VAR) expansion in command/args (Podman does not do it)
        documents = expand_kubernetes_variables(documents)
        # 3.7  Move writable /etc mounts to etc_mount_prefix and rewrite references to them
        documents = relocate_etc_data_mounts(documents, storage_config.get("etc_mount_prefix"))
        # 3.8  Nested mounts -> staging mounts + startup symlinks
        documents = resolve_overlapping_mounts(documents, storage_config.get("shadow_mount_prefix", "/dpmc-staging"))
        # 3.9  Strip namespace and cluster telemetry fields
        documents = sanitize_metadata(documents)
        # 3.10 Shared network annotation + Service ports -> hostPorts
        documents = inject_network_and_host_ports(documents, network_config.get("name", "shared-poc-net"))
        # 3.11 Service DNS names -> hostAliases on the gateway IP
        documents = inject_dns_service_aliases(documents, network_config.get("gateway_ip", "10.88.0.1"))
        # 3.12 Cascade runAsUser/runAsGroup; fsGroup -> ':U' mount options
        documents = cascade_security_contexts(documents)
        # 3.13 Remove attributes Podman ignores or rejects; shorten cluster FQDNs
        documents = remove_unsupported_podman_attributes(documents)
        # 3.14 Remove k8s/Helm/Consul/cert labels and non-allow-listed annotations
        documents = post_sanitize_labels_and_annotations(documents)
        # 3.15 Sort by app_sequence, kind_sequence, name
        documents = sort_documents(documents, self.config.get("sorting", {}))
        # 3.16 Syntax-check every `sh -c` startup script (sh -n)
        checked = check_shell_scripts(documents)
        print(f"Startup scripts: {checked} passed `sh -n` syntax check")
        # 3.17 Report fields Podman does not support (warning only; per the pinned upstream support tables)
        if support_doc_path and os.path.exists(support_doc_path):
            unsupported = find_unsupported_fields(documents, load_support_tables(support_doc_path))
            if unsupported:
                print(f"  WARNING: fields marked 'no'/'N/A' in {os.path.basename(support_doc_path)} "
                      f"(not supported by podman kube play; may be ignored):")
                for owner, fields in unsupported.items():
                    print(f"    {owner}: {', '.join(fields)}")
        elif support_doc_path:
            print(f"  WARNING: Podman support tables '{support_doc_path}' not found; unsupported-field report skipped")

        # 4. '__TBU:<path>__' placeholders (see placeholders.py)
        found = scan_placeholders(documents)
        if has_bare_marker(documents):
            print(f"  WARNING: bare '{MARKER}' (without a path) found in output - "
                  f"it came from a file that was not annotated (e.g. the chart's own values.yaml)")
        if found or placeholder_paths_file:
            print(f"Placeholders: {len(found)} distinct '__TBU:...__' path(s) in the output")
        if placeholder_paths_file:
            with open(placeholder_paths_file) as f:
                expected = [line.strip() for line in f if line.strip()]
            for p in expected:
                if p not in found:
                    print(f"  WARNING: placeholder '__TBU:{p}__' not found in output "
                          f"(value unused by the chart, or transformed by a template function such as b64enc/int)")

        if validation_output_path:
            # Deployable copy for `podman kube play` validation: placeholders -> dummy values
            validation_docs = copy.deepcopy(documents)
            apply_dummy_values(validation_docs)
            with open(validation_output_path, "w") as f:
                try:
                    self.yaml.dump_all(validation_docs, f)
                except Exception as e:
                    raise DPMCError(f"Failed to write validation YAML: {e}")
            print(f"Validation copy (placeholders -> dummy values) written to '{validation_output_path}'")

        # 5. Dump formatted stream
        with open(output_path, "w") as f:
            try:
                self.yaml.dump_all(documents, f)
            except Exception as e:
                raise DPMCError(f"Failed to write compiled YAML: {e}")
        
        print(f"Compilation complete: Compiled {len(documents)} resources into '{output_path}'")

# --- Command Line Interface ---
def main():
    parser = argparse.ArgumentParser(
        description="Deterministic Podman Manifest Compiler (DPMC) - Converts Helm manifests to Podman."
    )
    parser.add_argument(
        "--manifest",
        required=True,
        help="Path to the input multi-document manifest YAML."
    )
    parser.add_argument(
        "--secrets",
        required=False,
        help="Path to local secrets YAML to merge."
    )
    parser.add_argument(
        "--output",
        default="podman-ready.yaml",
        help="Output destination path (default: podman-ready.yaml)."
    )
    parser.add_argument(
        "--placeholder-paths",
        required=False,
        help="Placeholder path list from placeholders.py; warns about any path missing from the output."
    )
    parser.add_argument(
        "--validation-output",
        required=False,
        help="Also write a copy with '__TBU:...__' placeholders replaced by dummy values, for podman validation."
    )
    parser.add_argument(
        "--support",
        default=DEFAULT_SUPPORT_DOC,
        help="Pinned Podman kube play support tables (default: doc/podman-kube-play-support.md)."
    )
    parser.add_argument(
        "--config",
        action="append",
        default=[],
        help="Per-chart config override, merged on top of the base config shipped with the tool "
             f"({os.path.relpath(DEFAULT_BASE_CONFIG, TOOL_ROOT)}). Repeatable; later files win."
    )

    args = parser.parse_args()

    if not os.path.exists(args.manifest):
        print(f"Error: Manifest file '{args.manifest}' does not exist.", file=sys.stderr)
        sys.exit(1)

    if args.placeholder_paths and not os.path.exists(args.placeholder_paths):
        print(f"Error: Placeholder paths file '{args.placeholder_paths}' does not exist.", file=sys.stderr)
        sys.exit(1)

    if args.secrets and not os.path.exists(args.secrets):
        print(f"Error: Secrets file '{args.secrets}' does not exist.", file=sys.stderr)
        sys.exit(1)

    # Load Config settings: base shipped with the tool + per-chart overrides
    try:
        config_dict = load_config(args.config)
    except DPMCError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    # Run compilation
    compiler = DPMCCompiler(config=config_dict)
    try:
        compiler.compile(
            manifest_path=args.manifest,
            secrets_path=args.secrets,
            output_path=args.output,
            placeholder_paths_file=args.placeholder_paths,
            validation_output_path=args.validation_output,
            support_doc_path=args.support
        )
    except DPMCError as e:
        print(f"\nDPMC Compilation Failed:\n{e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"\nUnexpected Error during compilation:\n{e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
