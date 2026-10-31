"""Desliga o ambiente da AWS quando ninguém usa (stack fiapgames-auto-off).

Roda a cada poucos minutos pelo EventBridge Scheduler. Conta como uso: requisição
pelo Kong (fora health checks e rotas inexistentes), imagem nova no ECR ou um
toque do infra/aws.sh. Ocioso por IDLE_MINUTES, apaga as stacks do ambiente, um
passo por execução, sem esperar nenhuma terminar.

Evento {"dryRun": true} só informa o que faria.
"""
import base64
import json
import os
import re
import ssl
import tempfile
import time
import urllib.request

import boto3
from botocore.exceptions import ClientError

P = os.environ["PREFIX"]
CLUSTER = os.environ["CLUSTER"]
NAMESPACE = os.environ["NAMESPACE"]
IDLE = int(os.environ["IDLE_MINUTES"]) * 60
STATE = f"/{P}/auto-off/state"
TOUCH = f"/{P}/auto-off/last-activity"
REQUESTS = f"/{P}/auto-off/kong-requests"
PAUSED = f"/{P}/auto-off/paused"
# Um "ligar" leva ~50 min com esperas longas sem tocar no contador; enquanto ele
# roda, nada é apagado. Se ele morrer no meio, o ambiente volta a ser vigiado depois disso.
STARTING_GRACE = 2 * 3600
# Cada stack só sai depois das que importam valores dela.
DEPS = {
    f"{P}-github": [],
    f"{P}-opensearch": [],
    f"{P}-eks": [f"{P}-github", f"{P}-opensearch"],
    f"{P}-network": [f"{P}-eks"],
}

cf, ssm, ecr, elb, ec2, eks = (boto3.client(s) for s in ("cloudformation", "ssm", "ecr", "elb", "ec2", "eks"))


def status(stack):
    try:
        return cf.describe_stacks(StackName=stack)["Stacks"][0]["StackStatus"]
    except ClientError:
        return None


def get(name):
    try:
        return ssm.get_parameter(Name=name)["Parameter"]["Value"]
    except ClientError:
        return ""


def put(name, value):
    ssm.put_parameter(Name=name, Value=str(value), Type="String", Overwrite=True)


def eks_token():
    sts = boto3.client("sts")
    events = sts.meta.events
    events.register("provide-client-params.sts.GetCallerIdentity",
                    lambda params, context, **_: context.update({"cluster": params.pop("ClusterName")}))
    events.register("before-sign.sts.GetCallerIdentity",
                    lambda request, **_: request.headers.__setitem__("x-k8s-aws-id", request.context["cluster"]))
    url = sts.generate_presigned_url("get_caller_identity", Params={"ClusterName": CLUSTER},
                                     ExpiresIn=60, HttpMethod="GET")
    return "k8s-aws-v1." + base64.urlsafe_b64encode(url.encode()).decode().rstrip("=")


def kong_requests():
    """Requisições roteadas pelo Kong, sem health checks; None se o cluster não responde."""
    try:
        info = eks.describe_cluster(name=CLUSTER)["cluster"]
        with tempfile.NamedTemporaryFile("wb", suffix=".pem", delete=False) as ca:
            ca.write(base64.b64decode(info["certificateAuthority"]["data"]))
        req = urllib.request.Request(
            f"{info['endpoint']}/api/v1/namespaces/{NAMESPACE}/services/kong:8100/proxy/metrics",
            headers={"Authorization": f"Bearer {eks_token()}"})
        body = urllib.request.urlopen(req, context=ssl.create_default_context(cafile=ca.name), timeout=10).read().decode()
    except Exception as e:  # cluster subindo, Kong fora do ar, rede
        print(f"métricas do Kong indisponíveis: {e}")
        return None
    return sum(int(float(line.rsplit(" ", 1)[1])) for line in body.splitlines()
               if line.startswith("kong_http_requests_total")
               and re.search(r'route="[^"]+"', line) and "health" not in line)


def usage():
    """Motivo pelo qual o ambiente está em uso, ou "" se está ocioso."""
    now = time.time()
    count = kong_requests()
    if count is not None and str(count) != get(REQUESTS):
        put(REQUESTS, count)
        put(TOUCH, int(now))
        return f"requisições no gateway ({count})"
    if now - float(get(TOUCH) or 0) < IDLE:
        return "uso recente"
    for repo in ("catalog-api", "users-api", "payments-api"):
        images = ecr.describe_images(repositoryName=f"{P}/{repo}").get("imageDetails", [])
        if any(now - i["imagePushedAt"].timestamp() < IDLE for i in images):
            return f"deploy recente de {repo}"
    return ""


def remove_k8s_load_balancers(vpc):
    """O load balancer do Kong é criado pelo Kubernetes, não por stack, e trava a VPC."""
    for lb in elb.describe_load_balancers()["LoadBalancerDescriptions"]:
        if lb["VPCId"] == vpc:
            elb.delete_load_balancer(LoadBalancerName=lb["LoadBalancerName"])
    groups = ec2.describe_security_groups(Filters=[{"Name": "vpc-id", "Values": [vpc]},
                                                   {"Name": "group-name", "Values": ["k8s-elb-*"]}])
    for group in groups["SecurityGroups"]:
        try:
            ec2.delete_security_group(GroupId=group["GroupId"])
        except ClientError as e:  # ainda preso ao load balancer; sai na próxima execução
            print(f"{group['GroupId']}: {e}")


def handler(event, _context):
    dry = bool((event or {}).get("dryRun"))
    if get(PAUSED) == "true":
        return log("pausado: infra/aws.sh resume volta a vigiar")
    alive = {s: st for s in DEPS if (st := status(s)) and st != "DELETE_COMPLETE"}
    if not alive:
        if not dry:
            put(STATE, "off")
        return log("desligado")
    if any(st.endswith("IN_PROGRESS") for st in alive.values()):
        return log(f"operação em andamento: {alive}")

    state = get(STATE)
    if state == "starting" and time.time() - float(get(TOUCH) or 0) < STARTING_GRACE:
        return log("ligando: espera o fim do up")
    if state != "tearing-down":
        reason = usage()
        if reason:
            return log(f"em uso: {reason}")
        if dry:
            return log("ocioso: seria desligado agora")
        put(STATE, "tearing-down")
    if dry:
        return log("desligando")

    started = []
    for stack, deps in DEPS.items():
        if stack in alive and not any(d in alive for d in deps):
            if stack == f"{P}-network":
                outputs = cf.describe_stacks(StackName=stack)["Stacks"][0].get("Outputs", [])
                vpc = next((o["OutputValue"] for o in outputs if o["OutputKey"] == "VpcId"), "")
                if vpc:
                    remove_k8s_load_balancers(vpc)
            cf.delete_stack(StackName=stack)
            started.append(stack)
    return log(f"apagando {', '.join(started)}")


def log(message):
    print(json.dumps({"auto-off": message}, ensure_ascii=False))
    return message
