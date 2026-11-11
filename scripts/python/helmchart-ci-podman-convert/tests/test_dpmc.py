from dpmc import (
    filter_allowed_kinds,
    convert_statefulsets_and_setup_storage,
    resolve_overlapping_mounts,
    relocate_etc_data_mounts,
    expand_kubernetes_variables,
    purge_rbac_and_service_accounts,
    sanitize_metadata,
    post_sanitize_labels_and_annotations,
    inject_network_and_host_ports,
    inject_dns_service_aliases,
    cascade_security_contexts,
    remove_unsupported_podman_attributes,
    sort_documents,
    deduplicate_resources,
    check_shell_scripts,
    load_support_tables,
    find_unsupported_fields,
    DEFAULT_SUPPORT_DOC,
    DEFAULT_BASE_CONFIG,
    deep_merge,
    load_config,
    DPMCError,
)

def test_filter_allowed_kinds():
    allowed = ["Pod", "Deployment"]
    docs = [
        {"kind": "Pod", "metadata": {"name": "pod1"}},
        {"kind": "Service", "metadata": {"name": "svc1"}},
        {"kind": "Deployment", "metadata": {"name": "dep1"}}
    ]
    res = filter_allowed_kinds(docs, allowed)
    assert len(res) == 2
    kinds = [d["kind"] for d in res]
    assert "Pod" in kinds
    assert "Deployment" in kinds
    assert "Service" not in kinds


def test_convert_statefulset_to_deployment_local_volume():
    docs = [
        {
            "apiVersion": "apps/v1",
            "kind": "StatefulSet",
            "metadata": {"name": "db"},
            "spec": {
                "replicas": 3,
                "volumeClaimTemplates": [
                    {
                        "metadata": {"name": "data"},
                        "spec": {
                            "storageClassName": "premium-rwo",
                            "accessModes": ["ReadWriteOnce"]
                        }
                    }
                ],
                "template": {
                    "spec": {
                        "containers": [{"name": "postgres", "image": "postgres:15"}]
                    }
                }
            }
        }
    ]
    
    # Run conversion with local_volume mode
    res = convert_statefulsets_and_setup_storage(docs, {"mode": "local_volume"})
    
    # Should produce 2 docs: 1 Deployment and 1 PersistentVolumeClaim
    assert len(res) == 2
    
    deploy = res[0]
    pvc = res[1]
    
    assert pvc["kind"] == "PersistentVolumeClaim"
    assert pvc["metadata"]["name"] == "data-db-0"
    assert "storageClassName" not in pvc["spec"]
    
    assert deploy["kind"] == "Deployment"
    assert deploy["spec"]["replicas"] == 1
    
    volumes = deploy["spec"]["template"]["spec"]["volumes"]
    assert len(volumes) == 1
    assert volumes[0]["name"] == "data"
    assert volumes[0]["persistentVolumeClaim"]["claimName"] == "data-db-0"


def test_convert_statefulset_to_deployment_host_path():
    docs = [
        {
            "apiVersion": "apps/v1",
            "kind": "StatefulSet",
            "metadata": {"name": "db"},
            "spec": {
                "replicas": 2,
                "serviceName": "db",
                "podManagementPolicy": "OrderedReady",
                "updateStrategy": {"type": "RollingUpdate", "rollingUpdate": {"partition": 0}},
                "persistentVolumeClaimRetentionPolicy": {"whenDeleted": "Retain"},
                "revisionHistoryLimit": 3,
                "volumeClaimTemplates": [
                    {
                        "metadata": {"name": "data"},
                        "spec": {"accessModes": ["ReadWriteOnce"]}
                    }
                ],
                "template": {
                    "spec": {
                        "containers": [{"name": "postgres", "image": "postgres:15"}]
                    }
                }
            }
        },
        {
            "apiVersion": "v1",
            "kind": "PersistentVolumeClaim",
            "metadata": {"name": "existing-claim"}
        }
    ]
    
    # Run conversion with host_path mode
    res = convert_statefulsets_and_setup_storage(
        docs, 
        {"mode": "host_path", "host_root_dir": "/opt/podman-storage"}
    )
    
    # StatefulSet should demote to Deployment, and the PVC is ignored in host_path mode
    assert len(res) == 1
    
    deploy = res[0]
    assert deploy["kind"] == "Deployment"
    assert deploy["spec"]["replicas"] == 1
    # StatefulSet-only fields are dropped; fields valid on a Deployment are kept
    for field in ("serviceName", "podManagementPolicy", "updateStrategy", "persistentVolumeClaimRetentionPolicy"):
        assert field not in deploy["spec"]
    assert deploy["spec"]["revisionHistoryLimit"] == 3

    volumes = deploy["spec"]["template"]["spec"]["volumes"]
    assert len(volumes) == 1
    assert volumes[0]["name"] == "data"
    assert volumes[0]["hostPath"]["path"] == "/opt/podman-storage/data-db-0"
    assert volumes[0]["hostPath"]["type"] == "DirectoryOrCreate"


def _tessera_like_pod(command=("sh", "-c", "exec tessera")):
    """Mount layout taken from the real tessera StatefulSet (after /etc remap)."""
    container = {
        "name": "tessera",
        "volumeMounts": [
            {"name": "eph", "mountPath": "/mnt/etc/quorum/qdata", "subPath": "quorum-node"},
            {"name": "eph", "mountPath": "/mnt/etc/quorum/qdata/tm", "subPath": "quorum-node-tm"},
            {"name": "eph", "mountPath": "/mnt/etc/quorum/qdata/logs", "subPath": "quorum-node-logs"},
            {"name": "keystore-tm", "mountPath": "/mnt/etc/quorum/qdata/tm/tm.pub", "subPath": "tm.pub"},
            {"name": "keystore-tm", "mountPath": "/mnt/etc/quorum/qdata/tm/tm.key", "subPath": "tm.key"},
            {"name": "tessera-config", "mountPath": "/mnt/etc/quorum/qdata/tm/logback.xml", "subPath": "logback.xml"},
            {"name": "certs", "mountPath": "/mnt/etc/tessera-certs/p2p"},
            {"name": "tmp", "mountPath": "/tmp"},
        ],
    }
    if command:
        container["command"] = list(command)
    return {
        "kind": "Deployment", "metadata": {"name": "tessera"},
        "spec": {"template": {"spec": {
            "containers": [container],
            "volumes": [
                {"name": "eph", "emptyDir": {}},
                {"name": "keystore-tm", "secret": {"secretName": "tm"}},
                {"name": "tessera-config", "configMap": {"name": "tessera-config"}},
                {"name": "certs", "secret": {"secretName": "certs"}},
                {"name": "tmp", "emptyDir": {}},
            ],
        }}},
    }


def test_resolve_overlapping_mounts_stages_every_nested_mount():
    docs = resolve_overlapping_mounts([_tessera_like_pod()], "/dpmc-staging")
    pod_spec = docs[0]["spec"]["template"]["spec"]
    c = pod_spec["containers"][0]
    paths = sorted(m["mountPath"] for m in c["volumeMounts"])

    # No mount is left inside another mount
    for p in paths:
        assert not any(p != q and p.startswith(q.rstrip("/") + "/") for q in paths), p
    assert paths == [
        "/dpmc-staging/eph", "/dpmc-staging/keystore-tm", "/dpmc-staging/tessera-config",
        "/mnt/etc/quorum/qdata", "/mnt/etc/tessera-certs/p2p", "/tmp",
    ]
    staging = {m["mountPath"]: m for m in c["volumeMounts"] if m["mountPath"].startswith("/dpmc-staging")}
    assert all("subPath" not in m for m in staging.values())
    assert "initContainers" not in pod_spec  # no generated resolver container

    script = c["command"][2]
    # Same-volume subPath dirs are symlinked to the right subdirectory (created if missing)
    assert "mkdir -p /dpmc-staging/eph/quorum-node-tm" in script
    assert "ln -sfn /dpmc-staging/eph/quorum-node-tm /mnt/etc/quorum/qdata/tm" in script
    assert "ln -sfn /dpmc-staging/eph/quorum-node-logs /mnt/etc/quorum/qdata/logs" in script
    # Secret files nested in an emptyDir are copied (so the chart's `chmod 600` works), not linked
    assert "cp -fL /dpmc-staging/keystore-tm/tm.pub /mnt/etc/quorum/qdata/tm/tm.pub" in script
    assert "cp -fL /dpmc-staging/keystore-tm/tm.key /mnt/etc/quorum/qdata/tm/tm.key" in script
    assert "ln -sfn /dpmc-staging/keystore-tm/" not in script
    # ConfigMap files are linked; the source of a read-only volume is never created
    assert "ln -sfn /dpmc-staging/tessera-config/logback.xml /mnt/etc/quorum/qdata/tm/logback.xml" in script
    assert "mkdir -p /dpmc-staging/keystore-tm/" not in script
    # Parent directory is linked before the files inside it
    assert script.index("/mnt/etc/quorum/qdata/tm &&") < script.index("/mnt/etc/quorum/qdata/tm/tm.pub")
    # Never deletes data recursively; original command still runs
    assert "rm -rf" not in script
    assert script.endswith("&& exec tessera")


def test_resolve_overlapping_mounts_handles_init_containers_and_skips_unsafe_cases(capsys):
    pod = _tessera_like_pod(command=None)  # no explicit command -> cannot prepend safely
    pod_spec = pod["spec"]["template"]["spec"]
    pod_spec["initContainers"] = [{
        "name": "init", "command": ["sh", "-c", "echo init"],
        "volumeMounts": [
            {"name": "pvc", "mountPath": "/mnt/etc/quorum/qdata", "subPath": "quorum-node"},
            {"name": "contracts", "mountPath": "/mnt/etc/quorum/qdata/contracts-tmp"},
            {"name": "nodekey", "mountPath": "/mnt/etc/quorum/qdata/dd/geth/nodekey0.txt", "subPath": "nodekey0.txt"},
            {"name": "contracts", "mountPath": "/genesis"},
            {"name": "inside-ro", "mountPath": "/genesis/extra"},
        ],
    }]
    pod_spec["volumes"] += [{"name": "pvc", "hostPath": {"path": "/x"}},
                            {"name": "nodekey", "secret": {"secretName": "enode-creds"}},
                            {"name": "contracts", "configMap": {"name": "c"}},
                            {"name": "inside-ro", "emptyDir": {}}]

    resolve_overlapping_mounts([pod], "/dpmc-staging")
    init = pod_spec["initContainers"][0]
    assert "ln -sfn /dpmc-staging/contracts /mnt/etc/quorum/qdata/contracts-tmp" in init["command"][2]
    # A Secret nested in a persistent volume is linked, never copied onto disk
    assert "ln -sfn /dpmc-staging/nodekey/nodekey0.txt /mnt/etc/quorum/qdata/dd/geth/nodekey0.txt" in init["command"][2]
    assert "cp " not in init["command"][2]
    assert {"name": "contracts", "mountPath": "/dpmc-staging/contracts", "readOnly": True} not in init["volumeMounts"]
    assert {"name": "contracts", "mountPath": "/dpmc-staging/contracts"} in init["volumeMounts"]
    # Nested inside a read-only configMap mount: left alone with a warning
    assert {"name": "inside-ro", "mountPath": "/genesis/extra"} in init["volumeMounts"]

    main = pod_spec["containers"][0]
    assert "command" not in main and len(main["volumeMounts"]) == 8  # untouched
    out = capsys.readouterr().out
    assert "nested in read-only mount '/genesis'" in out
    assert "no explicit command" in out


def test_resolve_overlapping_mounts_rejects_staging_inside_a_mount():
    import pytest
    with pytest.raises(DPMCError, match="staging root '/tmp/dpmc' is inside mount '/tmp'"):
        resolve_overlapping_mounts([_tessera_like_pod()], "/tmp/dpmc")


def test_purge_rbac_and_service_accounts():
    docs = [
        {"kind": "ServiceAccount", "metadata": {"name": "test-sa"}},
        {"kind": "Secret", "metadata": {"name": "sa-token-secret"}, "type": "kubernetes.io/service-account-token"},
        {
            "kind": "Pod",
            "metadata": {"name": "app-pod"},
            "spec": {
                "serviceAccountName": "test-sa",
                "automountServiceAccountToken": True,
                "containers": [{"name": "app", "image": "nginx"}]
            }
        }
    ]
    
    res = purge_rbac_and_service_accounts(docs)
    assert len(res) == 1
    pod = res[0]
    assert "serviceAccountName" not in pod["spec"]
    assert "automountServiceAccountToken" not in pod["spec"]


def test_sanitize_metadata():
    docs = [
        {
            "kind": "Deployment",
            "metadata": {
                "name": "app-deploy",
                "namespace": "my-ns",
                "uid": "12345",
                "generation": 2,
            },
            "status": {"replicas": 1}
        }
    ]

    res = sanitize_metadata(docs)
    deploy = res[0]
    metadata = deploy["metadata"]
    
    assert "namespace" not in metadata
    assert "uid" not in metadata
    assert "generation" not in metadata
    assert "status" not in deploy


def test_post_sanitize_labels_and_annotations():
    docs = [
        {
            "kind": "Deployment",
            "metadata": {
                "name": "app-deploy",
                "labels": {
                    "app": "my-app",
                    "heritage": "Helm",
                    "chart": "my-chart-1.0.0",
                    "release": "my-release",
                    "app.kubernetes.io/name": "my-app-k8s",
                    "consul.hashicorp.com/service-ignore": "true",
                    "namespace": "my-ns"
                },
                "annotations": {
                    "io.podman.kube.network": "my-net",
                    "prometheus.io/scrape": "true",
                    "meta.helm.sh/release": "release"
                }
            },
            "spec": {
                "selector": {
                    "matchLabels": {
                        "app": "my-app",
                        "release": "my-release",
                        "app.kubernetes.io/name": "my-app-k8s",
                        "namespace": "my-ns"
                    }
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "my-app",
                            "release": "my-release",
                            "app.kubernetes.io/name": "my-app-k8s",
                            "namespace": "my-ns"
                        },
                        "annotations": {
                            "prometheus.io/scrape": "true",
                            "prometheus.io/scheme": "https",
                            "consul.hashicorp.com/connect-inject": "true",
                            "namespace": "my-ns"
                        }
                    }
                }
            }
        }
    ]
    
    res = post_sanitize_labels_and_annotations(docs)
    deploy = res[0]
    
    # Check top-level labels
    labels = deploy["metadata"]["labels"]
    assert "app" in labels
    assert "heritage" not in labels
    assert "chart" not in labels
    assert "release" not in labels
    assert "app.kubernetes.io/name" not in labels
    assert "consul.hashicorp.com/service-ignore" not in labels
    assert "namespace" not in labels

    # Check top-level annotations (allow-listed prefixes only)
    annotations = deploy["metadata"]["annotations"]
    assert "io.podman.kube.network" in annotations
    assert "prometheus.io/scrape" in annotations
    assert "meta.helm.sh/release" not in annotations

    # Check selector matchLabels
    match_labels = deploy["spec"]["selector"]["matchLabels"]
    assert "app" in match_labels
    assert "release" not in match_labels
    assert "app.kubernetes.io/name" not in match_labels
    assert "namespace" not in match_labels
    
    # Check template labels
    t_labels = deploy["spec"]["template"]["metadata"]["labels"]
    assert "app" in t_labels
    assert "release" not in t_labels
    assert "app.kubernetes.io/name" not in t_labels
    assert "namespace" not in t_labels
    
    # Check template annotations
    t_annotations = deploy["spec"]["template"]["metadata"]["annotations"]
    assert "prometheus.io/scrape" in t_annotations
    assert "prometheus.io/scheme" not in t_annotations  # removed since value is 'https'
    assert "consul.hashicorp.com/connect-inject" not in t_annotations
    assert "namespace" not in t_annotations



def test_inject_network_and_host_ports():
    docs = [
        {
            "kind": "Service",
            "metadata": {"name": "web-svc"},
            "spec": {
                "selector": {"app": "web"},
                "ports": [{"port": 80, "targetPort": 8080}]
            }
        },
        {
            "kind": "Deployment",
            "metadata": {"name": "web-deploy"},
            "spec": {
                "template": {
                    "metadata": {"labels": {"app": "web"}},
                    "spec": {
                        "containers": [
                            {
                                "name": "nginx",
                                "image": "nginx",
                                "ports": [{"containerPort": 8080, "name": "http"}]
                            }
                        ]
                    }
                }
            }
        }
    ]
    
    res = inject_network_and_host_ports(docs, "test-bridge-net")
    deploy = res[1]
    
    assert deploy["metadata"]["annotations"]["io.podman.kube.network"] == "test-bridge-net"
    assert deploy["spec"]["template"]["metadata"]["annotations"]["io.podman.kube.network"] == "test-bridge-net"
    
    container_port = deploy["spec"]["template"]["spec"]["containers"][0]["ports"][0]
    assert container_port["hostPort"] == 80


def test_inject_dns_service_aliases():
    docs = [
        {"kind": "Service", "metadata": {"name": "svc1"}},
        {"kind": "Service", "metadata": {"name": "svc2"}},
        {
            "kind": "Pod",
            "metadata": {"name": "app-pod"},
            "spec": {
                "containers": [{"name": "app", "image": "nginx"}]
            }
        }
    ]
    
    res = inject_dns_service_aliases(docs, "10.88.0.1")
    pod = res[2]
    
    aliases = pod["spec"]["hostAliases"][0]["hostnames"]
    assert "svc1" in aliases
    assert "svc1.default" in aliases
    assert "svc2.default.svc.cluster.local" in aliases


def test_cascade_security_contexts():
    docs = [
        {
            "kind": "Pod",
            "metadata": {"name": "sec-pod"},
            "spec": {
                "securityContext": {
                    "runAsUser": 5000,
                    "fsGroup": 6000
                },
                "volumes": [{"name": "storage"}],
                "containers": [{"name": "app", "image": "nginx"}]
            }
        }
    ]
    
    res = cascade_security_contexts(docs)
    pod = res[0]
    pod_spec = pod["spec"]
    
    assert "fsGroup" not in pod_spec["securityContext"]
    assert pod_spec["containers"][0]["securityContext"]["runAsUser"] == 5000
    assert pod["metadata"]["annotations"]["volume.podman.io/mount-options"] == "storage:U"


def test_remove_unsupported_podman_attributes():
    docs = [
        {
            "kind": "Secret",
            "metadata": {"name": "my-secret"},
            "immutable": True,
            "data": {"foo": "bar"}
        },
        {
            "kind": "Deployment",
            "metadata": {"name": "my-deployment"},
            "spec": {
                "template": {
                    "spec": {
                        "affinity": {
                            "podAntiAffinity": {}
                        },
                        "imagePullSecrets": [{"name": "regcred"}],
                        "securityContext": {
                            "fsGroup": 1000,
                            "fsGroupChangePolicy": "Always",
                            "seccompProfile": {"type": "RuntimeDefault"}
                        },
                        "containers": [
                            {
                                "name": "web",
                                "securityContext": {
                                    "seccompProfile": {"type": "Localhost"}
                                }
                            }
                        ],
                        "volumes": [
                            {
                                "name": "scratch",
                                "emptyDir": {
                                    "medium": "Memory",
                                    "sizeLimit": "1Gi"
                                }
                            }
                        ],
                        "hostAliases": [
                            {
                                "ip": "10.88.0.1",
                                "hostnames": ["tessera-int-lb.default.svc.cluster.local"]
                            }
                        ]
                    }
                }
            }
        },
        {
            "kind": "Pod",
            "metadata": {
                "name": "fqdn-pod",
                "annotations": {
                    "prometheus.io/hostname": "tessera-int-lb.default.svc.cluster.local"
                }
            }
        }
    ]

    res = remove_unsupported_podman_attributes(docs)
    assert len(res) == 3

    # Check Secret
    secret = res[0]
    assert "immutable" not in secret
    assert secret["kind"] == "Secret"

    # Check Deployment
    deployment = res[1]
    pod_spec = deployment["spec"]["template"]["spec"]

    # Affinity and imagePullSecrets should be stripped
    assert "affinity" not in pod_spec
    assert "imagePullSecrets" not in pod_spec

    # securityContext fsGroupChangePolicy and seccompProfile should be stripped
    sec_ctx = pod_spec["securityContext"]
    assert "fsGroup" in sec_ctx
    assert "fsGroupChangePolicy" not in sec_ctx
    assert "seccompProfile" not in sec_ctx

    # container-level securityContext seccompProfile should be stripped
    container = pod_spec["containers"][0]
    assert "securityContext" not in container  # because seccompProfile was the only key and was cleaned up

    # emptyDir sizeLimit should be stripped
    volume = pod_spec["volumes"][0]
    assert "sizeLimit" not in volume["emptyDir"]
    assert volume["emptyDir"]["medium"] == "Memory"

    # Host aliases FQDN should remain UNTOUCHED
    host_alias = pod_spec["hostAliases"][0]
    assert host_alias["hostnames"][0] == "tessera-int-lb.default.svc.cluster.local"

    # Other annotations FQDN should be shortened to app name
    fqdn_pod = res[2]
    assert fqdn_pod["metadata"]["annotations"]["prometheus.io/hostname"] == "tessera"



def test_sort_documents():
    sorting_config = {
        "app_sequence": [
            {"name": "tessera", "pattern": "tessera"},
            {"name": "quorum", "pattern": "quorum"}
        ],
        "kind_sequence": [
            "Secret",
            "ConfigMap",
            "Service",
            "Deployment"
        ]
    }

    docs = [
        {"kind": "Deployment", "metadata": {"name": "quorum-deploy"}},
        {"kind": "Secret", "metadata": {"name": "quorum-secret"}},
        {"kind": "ConfigMap", "metadata": {"name": "tessera-config"}},
        {"kind": "Deployment", "metadata": {"name": "tessera-deploy"}},
        {"kind": "Service", "metadata": {"name": "tessera-service"}},
        {"kind": "Service", "metadata": {"name": "quorum-service"}}
    ]

    res = sort_documents(docs, sorting_config)
    assert len(res) == 6

    # Expected order:
    # 1. tessera app (ConfigMap -> Service -> Deployment)
    #    - tessera-config
    #    - tessera-service
    #    - tessera-deploy
    # 2. quorum app (Secret -> Service -> Deployment)
    #    - quorum-secret
    #    - quorum-service
    #    - quorum-deploy
    
    assert res[0]["metadata"]["name"] == "tessera-config"
    assert res[1]["metadata"]["name"] == "tessera-service"
    assert res[2]["metadata"]["name"] == "tessera-deploy"
    
    assert res[3]["metadata"]["name"] == "quorum-secret"
    assert res[4]["metadata"]["name"] == "quorum-service"
    assert res[5]["metadata"]["name"] == "quorum-deploy"




def test_host_ports_only_on_declaring_container():
    """A sidecar in the same pod must not get the main container's ports (shared network namespace)."""
    docs = [
        {"kind": "Service", "metadata": {"name": "tessera-p2p"},
         "spec": {"selector": {"app": "tessera"}, "ports": [{"port": 9001, "targetPort": "p2p"}]}},
        {"kind": "Service", "metadata": {"name": "tessera-int"},
         "spec": {"selector": {"app": "tessera"}, "ports": [{"port": 9080, "targetPort": 9080}]}},
        {"kind": "Service", "metadata": {"name": "health"},
         "spec": {"selector": {"app": "tessera"}, "ports": [{"port": 4567, "targetPort": 4567}]}},
        {"kind": "Service", "metadata": {"name": "undeclared"},
         "spec": {"selector": {"app": "tessera"}, "ports": [{"port": 7000, "targetPort": 7000}]}},
        {"kind": "Deployment", "metadata": {"name": "tessera"}, "spec": {"template": {
            "metadata": {"labels": {"app": "tessera"}},
            "spec": {"containers": [
                {"name": "health", "ports": [{"containerPort": 4567, "name": "health"}]},
                {"name": "tessera", "ports": [{"containerPort": 9001, "name": "p2p"},
                                              {"containerPort": 9080, "name": "tp"}]},
                {"name": "no-ports"},
            ]}}}},
    ]
    res = inject_network_and_host_ports(docs, "net")
    health, tessera, no_ports = res[4]["spec"]["template"]["spec"]["containers"]

    assert [(p["containerPort"], p.get("hostPort")) for p in health["ports"]] == [(4567, 4567), (7000, 7000)]
    assert [(p["containerPort"], p.get("hostPort")) for p in tessera["ports"]] == [(9001, 9001), (9080, 9080)]
    assert "ports" not in no_ports


def test_purge_removes_projected_volume_with_any_service_account_token():
    docs = [{
        "kind": "Deployment", "metadata": {"name": "quorum"},
        "spec": {"template": {"spec": {
            "containers": [{"name": "quorum", "volumeMounts": [
                {"name": "quorum-sa-token", "mountPath": "/var/run/secrets/tokens"},
                {"name": "config", "mountPath": "/config"},
            ]}],
            "volumes": [
                {"name": "quorum-sa-token", "projected": {"sources": [
                    {"serviceAccountToken": {"path": "token"}},
                    {"configMap": {"name": "kube-root-ca.crt"}},
                    {"downwardAPI": {"items": []}},
                ]}},
                {"name": "config", "projected": {"sources": [{"configMap": {"name": "app-config"}}]}},
            ],
        }}},
    }]
    pod_spec = purge_rbac_and_service_accounts(docs)[0]["spec"]["template"]["spec"]
    assert [v["name"] for v in pod_spec["volumes"]] == ["config"]
    assert [m["name"] for m in pod_spec["containers"][0]["volumeMounts"]] == ["config"]


def test_deduplicate_resources_keeps_last_definition(capsys):
    docs = [
        {"kind": "Secret", "metadata": {"name": "quorum-account-key"}, "stringData": {"key": ""}},
        {"kind": "ConfigMap", "metadata": {"name": "quorum-account-key"}},
        {"kind": "Secret", "metadata": {"name": "other"}},
        {"kind": "Secret", "metadata": {"name": "quorum-account-key"}, "data": {"key": "ZWQz"}},
    ]
    res = deduplicate_resources(docs)
    assert [(d["kind"], d["metadata"]["name"]) for d in res] == [
        ("ConfigMap", "quorum-account-key"), ("Secret", "other"), ("Secret", "quorum-account-key")]
    assert res[2]["data"] == {"key": "ZWQz"}
    assert "Secret/quorum-account-key is defined more than once" in capsys.readouterr().out



def test_prepend_command_forms():
    from dpmc import prepend_command_to_container
    # sh in command, -c and script in args (tessera init form): script prefixed in place, not re-quoted
    c = {"command": ["sh"], "args": ["-c", 'echo "$JAVA_HOME"; run']}
    assert prepend_command_to_container(c, "setup")
    assert c == {"command": ["sh"], "args": ["-c", 'setup && echo "$JAVA_HOME"; run']}
    # exec form: original command line is shell-quoted
    c = {"command": ["/bin/app"], "args": ["--name", "it's"]}
    assert prepend_command_to_container(c, "setup")
    assert c["args"] == ["setup && exec /bin/app --name 'it'\"'\"'s'"]
    # no command (image ENTRYPOINT): refused, unchanged
    c = {"args": ["-listen=:4567"]}
    assert not prepend_command_to_container(c, "setup")
    assert c == {"args": ["-listen=:4567"]}



def test_fqdn_shortening_keeps_the_rest_of_the_string():
    script = ("until wget https://quorum-int-lb-0.gcp-ghrunner-default.svc.cluster.local:8545; do sleep 1; done\n"
              "geth --ptm.url https://tessera-int-lb.gcp-ghrunner-default.svc.cluster.local:9081 --other x.svc.example\n")
    docs = [{"kind": "Deployment", "metadata": {"name": "quorum0"}, "spec": {"template": {"spec": {
        "hostAliases": [{"ip": "10.88.0.1", "hostnames": ["tessera.default.svc.cluster.local"]}],
        "containers": [{"name": "quorum", "command": ["sh", "-c"], "args": [script]}]}}}},
        {"kind": "ConfigMap", "metadata": {"name": "tessera"}, "data": {
            "cfg.json": '{"serverAddress": "https://tessera-int-lb.ns.svc.cluster.local:9081", "other": "db.example.com"}',
            "plain": "https://unrelated-svc.ns.svc.cluster.local"}}]
    res = remove_unsupported_podman_attributes(docs)
    pod = res[0]["spec"]["template"]["spec"]
    assert pod["containers"][0]["args"][0] == (
        "until wget https://quorum:8545; do sleep 1; done\n"
        "geth --ptm.url https://tessera:9081 --other x.svc.example\n")
    assert pod["hostAliases"][0]["hostnames"] == ["tessera.default.svc.cluster.local"]
    assert res[1]["data"]["cfg.json"] == '{"serverAddress": "https://tessera:9081", "other": "db.example.com"}'
    assert res[1]["data"]["plain"] == "https://unrelated-svc.ns.svc.cluster.local"


def _pod_with_scripts(*scripts):
    return [{"kind": "Deployment", "metadata": {"name": "app"}, "spec": {"template": {"spec": {
        "initContainers": [{"name": "init", "command": ["sh"], "args": ["-c", scripts[0]]}],
        "containers": [{"name": f"c{i}", "command": ["sh", "-c", sc]} for i, sc in enumerate(scripts[1:])]
                      + [{"name": "entrypoint-only", "args": ["-listen=:4567"]}],
    }}}}]


def test_check_shell_scripts_passes_valid_scripts_and_kubernetes_dollar_escape():
    docs = _pod_with_scripts(
        "until $(wget -q http://x); do sleep 1; done",
        "V=$(/tessera/bin/tessera version); echo $V",
        "ln -sfn /a /b && \nupdate-ca-trust; exec geth",
    )
    assert check_shell_scripts(docs) == 3


def test_check_shell_scripts_reports_every_broken_script():
    docs = _pod_with_scripts("echo ok", "if [ -f x ]; then echo", "echo ok")
    import pytest
    with pytest.raises(DPMCError) as err:
        check_shell_scripts(docs)
    assert "Deployment/app container 'c0'" in str(err.value)
    assert "init" not in str(err.value) and "'c1'" not in str(err.value)


def _quorum_like_docs():
    """Layout from the real quorum0 / tessera pods (paths before relocation)."""
    quorum = {"kind": "Deployment", "metadata": {"name": "quorum0"}, "spec": {"template": {"spec": {
        "initContainers": [{"name": "init", "command": ["sh", "-c", "mkdir -p $QHOME/dd && cp /x /etc/quorum/qdata/dd/"],
                            "env": [{"name": "QHOME", "value": "/etc/quorum/qdata"}],
                            "volumeMounts": [{"name": "quorum-pvc", "mountPath": "/etc/quorum/qdata", "subPath": "quorum-node"},
                                             {"name": "contracts", "mountPath": "/etc/quorum/qdata/contracts-tmp"}]}],
        "containers": [
            {"name": "quorum", "command": ["sh", "-c", "geth --datadir /etc/quorum/qdata/dd --x /etc/quorum/qdata2 "
                                                       "--cert /etc/quorum-certs/int/tls.crt --already /mnt/etc/quorum/qdata"],
             "env": [{"name": "QUORUM_DATA_DIR", "value": "/etc/quorum/qdata/dd"},
                     {"name": "QUORUM_PLUGIN_DIR", "value": "/etc/plugins"}],
             "readinessProbe": {"exec": {"command": ["cat", "/etc/quorum/qdata/ready"]}},
             "volumeMounts": [{"name": "quorum-pvc", "mountPath": "/etc/quorum/qdata", "subPath": "quorum-node"},
                              {"name": "certs", "mountPath": "/etc/quorum-certs/int"},
                              {"name": "plugin", "mountPath": "/etc/plugins/plugin.json", "subPath": "plugin.json"}]},
            {"name": "sidecar", "volumeMounts": [{"name": "quorum-pvc", "mountPath": "/etc/quorum/qdata/logs"}]},
        ],
        "volumes": [{"name": "quorum-pvc", "hostPath": {"path": "/srv/quorum-pvc"}},
                    {"name": "contracts", "configMap": {"name": "contracts"}},
                    {"name": "certs", "secret": {"secretName": "quorum-int-tls"}},
                    {"name": "plugin", "configMap": {"name": "quorum-config"}}],
    }}}}
    tessera = {"kind": "Deployment", "metadata": {"name": "tessera"}, "spec": {"template": {"spec": {
        "containers": [{"name": "tessera", "command": ["sh", "-c", "run"],
                        "volumeMounts": [{"name": "creds", "mountPath": "/etc/tessera-creds/db"}]}],
        "volumes": [{"name": "creds", "secret": {"secretName": "db"}},
                    {"name": "shared", "configMap": {"name": "shared"}}],
    }}}}
    own_cm = {"kind": "ConfigMap", "metadata": {"name": "quorum-config"},
              "data": {"cfg.toml": 'DataDir = "/etc/quorum/qdata/dd"\nPlugins = "/etc/plugins"'}}
    shared_cm = {"kind": "ConfigMap", "metadata": {"name": "shared"}, "data": {"x": "/etc/quorum/qdata/tm"}}
    quorum["spec"]["template"]["spec"]["volumes"].append({"name": "shared", "configMap": {"name": "shared"}})
    return [quorum, tessera, own_cm, shared_cm]


def test_relocate_etc_data_mounts_moves_writable_mounts_and_rewrites_references(capsys):
    quorum, tessera, own_cm, shared_cm = relocate_etc_data_mounts(_quorum_like_docs(), "/mnt/etc")
    ps = quorum["spec"]["template"]["spec"]
    init, main, sidecar = ps["initContainers"][0], ps["containers"][0], ps["containers"][1]

    # The writable hostPath moves, and mounts nested under it move with it
    assert [m["mountPath"] for m in init["volumeMounts"]] == ["/mnt/etc/quorum/qdata", "/mnt/etc/quorum/qdata/contracts-tmp"]
    assert sidecar["volumeMounts"][0]["mountPath"] == "/mnt/etc/quorum/qdata/logs"
    # Secret / configMap mounts under /etc stay where they are
    assert [m["mountPath"] for m in main["volumeMounts"]] == [
        "/mnt/etc/quorum/qdata", "/etc/quorum-certs/int", "/etc/plugins/plugin.json"]

    # References are rewritten; whole paths only; idempotent; untouched paths stay
    assert init["env"][0]["value"] == "/mnt/etc/quorum/qdata"
    assert init["command"][2] == "mkdir -p $QHOME/dd && cp /x /mnt/etc/quorum/qdata/dd/"
    assert main["command"][2] == ("geth --datadir /mnt/etc/quorum/qdata/dd --x /etc/quorum/qdata2 "
                                  "--cert /etc/quorum-certs/int/tls.crt --already /mnt/etc/quorum/qdata")
    assert main["env"] == [{"name": "QUORUM_DATA_DIR", "value": "/mnt/etc/quorum/qdata/dd"},
                           {"name": "QUORUM_PLUGIN_DIR", "value": "/etc/plugins"}]
    assert main["readinessProbe"]["exec"]["command"] == ["cat", "/mnt/etc/quorum/qdata/ready"]

    # ConfigMap used only by the moved pod is rewritten; one shared with a pod that keeps the path is not
    assert own_cm["data"]["cfg.toml"] == 'DataDir = "/mnt/etc/quorum/qdata/dd"\nPlugins = "/etc/plugins"'
    assert shared_cm["data"]["x"] == "/etc/quorum/qdata/tm"
    # Pod with only secret mounts under /etc is untouched
    assert tessera["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0]["mountPath"] == "/etc/tessera-creds/db"

    out = capsys.readouterr().out
    assert "ConfigMap/shared mentions /etc/quorum/qdata but is shared" in out
    assert "container 'sidecar' has no explicit command" in out
    # Nothing is written under /etc at runtime
    assert "ln -s" not in str(quorum) and "rm -rf" not in str(quorum)


def test_relocate_etc_data_mounts_disabled_with_empty_prefix():
    docs = _quorum_like_docs()
    assert relocate_etc_data_mounts(docs, "")[0]["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0][
        "mountPath"] == "/etc/quorum/qdata"


def test_expand_kubernetes_variables():
    docs = [{"kind": "Deployment", "metadata": {"name": "t"}, "spec": {"template": {"spec": {"containers": [{
        "name": "tessera",
        "env": [{"name": "DDIR", "value": "/app/tm"}, {"name": "SECRET", "valueFrom": {"secretKeyRef": {"name": "s"}}}],
        "command": ["sh", "-c"],
        "args": ["V=$$(/tessera/bin/tessera version); cfg=$${DDIR}/x.json; d=$(DDIR); s=$(SECRET); "
                 "until $(wget -q x); do :; done; echo $$$$"],
    }]}}}}]
    c = expand_kubernetes_variables(docs)[0]["spec"]["template"]["spec"]["containers"][0]
    assert c["args"][0] == ("V=$(/tessera/bin/tessera version); cfg=${DDIR}/x.json; d=/app/tm; s=$(SECRET); "
                            "until $(wget -q x); do :; done; echo $$")


def test_support_tables_parse_pinned_doc():
    tables = load_support_tables(DEFAULT_SUPPORT_DOC)
    assert set(tables) == {"Pod Fields", "Container Fields", "PersistentVolumeClaim Fields", "ConfigMap Fields",
                           "Deployment Fields", "DaemonSet Fields", "Job Fields"}
    container = dict(tables["Container Fields"])
    assert container["volumeMounts.subPath"] == "✅" and container["readinessProbe"] == "no"
    assert dict(tables["Pod Fields"])["affinity.nodeAffinity"] == "N/A"


def test_find_unsupported_fields_reports_only_no_and_na_fields():
    tables = load_support_tables(DEFAULT_SUPPORT_DOC)
    docs = [
        {"kind": "Deployment", "metadata": {"name": "quorum0"}, "spec": {
            "replicas": 1, "revisionHistoryLimit": 3, "strategy": {"type": "Recreate"},
            "template": {"spec": {
                "securityContext": {"runAsUser": 10001},
                "affinity": {"nodeAffinity": {}},
                "initContainers": [{"name": "init", "securityContext": {"runAsNonRoot": True}}],
                "containers": [
                    {"name": "quorum", "readinessProbe": {"exec": {}}, "securityContext": {"runAsNonRoot": True,
                     "readOnlyRootFilesystem": True}, "ports": [{"containerPort": 8545, "hostPort": 8545}],
                     "volumeMounts": [{"name": "v", "mountPath": "/x", "subPath": "a"}]},
                    {"name": "health", "livenessProbe": {}},
                ]}}}},
        {"kind": "ConfigMap", "metadata": {"name": "cfg"}, "data": {"a": "b"}, "immutable": True},
        {"kind": "Service", "metadata": {"name": "svc"}, "spec": {"ports": []}},
    ]
    assert find_unsupported_fields(docs, tables) == {
        "Deployment/quorum0": ["strategy.type", "revisionHistoryLimit", "affinity.nodeAffinity",
                               "securityContext.runAsNonRoot [init, quorum]", "readinessProbe [quorum]"],
        "ConfigMap/cfg": ["immutable"],
    }


def test_deep_merge_mappings_merge_lists_replace():
    base = {"network": {"name": "net", "gateway_ip": "10.88.0.1"},
            "sorting": {"app_sequence": [], "kind_sequence": ["Secret", "Deployment"]},
            "manifests": {"allowed_kinds": ["Pod", "Deployment"]}}
    override = {"network": {"name": "chart-net"}, "sorting": {"app_sequence": [{"pattern": "db"}]},
                "manifests": {"allowed_kinds": ["Deployment"]}}
    merged = deep_merge(base, override)
    assert merged == {"network": {"name": "chart-net", "gateway_ip": "10.88.0.1"},
                      "sorting": {"app_sequence": [{"pattern": "db"}], "kind_sequence": ["Secret", "Deployment"]},
                      "manifests": {"allowed_kinds": ["Deployment"]}}
    assert base["network"]["name"] == "net"  # base not mutated


def test_load_config_base_then_overrides(tmp_path):
    override = tmp_path / "chart.yaml"
    override.write_text("sorting:\n  app_sequence:\n    - pattern: tessera\n")
    config = load_config([str(override)])
    assert config["sorting"]["app_sequence"] == [{"pattern": "tessera"}]
    assert config["storage"]["etc_mount_prefix"] == "/mnt/etc"          # still from the base
    assert load_config([])["sorting"]["app_sequence"] == []              # base is chart-neutral
    assert load_config([DEFAULT_BASE_CONFIG]) == load_config([])          # base passed again is harmless


def test_load_config_missing_override_is_an_error(tmp_path):
    import pytest
    with pytest.raises(DPMCError, match="does not exist"):
        load_config([str(tmp_path / "typo.yaml")])


def test_cli_runs_from_any_working_directory(tmp_path):
    """The controller repo calls the tool from its own workspace: bundled files must resolve."""
    import subprocess, sys, os
    manifest = tmp_path / "m.yaml"
    manifest.write_text("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: c\n  namespace: x\ndata:\n  a: b\n")
    dpmc = os.path.join(os.path.dirname(DEFAULT_BASE_CONFIG), "dpmc.py")
    result = subprocess.run([sys.executable, dpmc, "--manifest", "m.yaml", "--output", "out.yaml"],
                            cwd=tmp_path, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert f"Loaded configuration from '{DEFAULT_BASE_CONFIG}'" in result.stdout
    assert "namespace" not in (tmp_path / "out.yaml").read_text()
